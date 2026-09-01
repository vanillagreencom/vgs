package mimeapps

import (
	"encoding/json"
	"fmt"
	"log/slog"
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"vshell/backend/internal/server"
)

type Manager struct {
	srv *server.Server
	log *slog.Logger
}

type defaultParams struct {
	MimeType      string   `json:"mimeType"`
	MimeTypes     []string `json:"mimeTypes"`
	DesktopFileID string   `json:"desktopFileId"`
}

type openParams struct {
	Target      string   `json:"target"`
	URL         string   `json:"url"`
	MimeType    string   `json:"mimeType"`
	RequestType string   `json:"requestType"`
	Categories  []string `json:"categories"`
}

func Register(srv *server.Server, log *slog.Logger) (*Manager, error) {
	if log == nil {
		log = slog.Default()
	}
	m := &Manager{srv: srv, log: log}
	srv.Register("mime", "mime.getDefault", m.handleGetDefault)
	srv.Register("mime", "mime.setDefault", m.handleSetDefault)
	srv.Register("mime", "mime.setDefaults", m.handleSetDefaults)
	srv.Register("mime", "mime.appsForMime", m.handleAppsForMime)
	srv.Register("mime", "mime.queryDefaults", m.handleQueryDefaults)
	srv.Register("mime", "mime.invalidate", m.handleInvalidate)
	srv.Register("mime", "browser.open", m.handleBrowserOpen)
	srv.Register("mime", "apppicker.open", m.handleAppPickerOpen)
	return m, nil
}

func (m *Manager) Close() {}

func (m *Manager) handleGetDefault(params json.RawMessage) (any, error) {
	var p defaultParams
	if err := json.Unmarshal(params, &p); err != nil {
		return nil, err
	}
	mimeType, err := validateMimeType(p.MimeType)
	if err != nil {
		return nil, err
	}
	id, err := queryDefault(mimeType, m.log)
	if err != nil {
		return nil, err
	}
	return map[string]any{"mimeType": mimeType, "desktopFileId": id}, nil
}

func (m *Manager) handleSetDefault(params json.RawMessage) (any, error) {
	var p defaultParams
	if err := json.Unmarshal(params, &p); err != nil {
		return nil, err
	}
	mimeType, err := validateMimeType(p.MimeType)
	if err != nil {
		return nil, err
	}
	desktopID, err := validateDesktopID(p.DesktopFileID)
	if err != nil {
		return nil, err
	}
	if err := setDefault(desktopID, []string{mimeType}, m.log); err != nil {
		return nil, err
	}
	return map[string]any{"success": true}, nil
}

func (m *Manager) handleSetDefaults(params json.RawMessage) (any, error) {
	var p defaultParams
	if err := json.Unmarshal(params, &p); err != nil {
		return nil, err
	}
	desktopID, err := validateDesktopID(p.DesktopFileID)
	if err != nil {
		return nil, err
	}
	mimeTypes, err := validateMimeTypes(p.MimeTypes)
	if err != nil {
		return nil, err
	}
	if err := setDefault(desktopID, mimeTypes, m.log); err != nil {
		return nil, err
	}
	return map[string]any{"success": true}, nil
}

func (m *Manager) handleAppsForMime(params json.RawMessage) (any, error) {
	var p defaultParams
	if err := json.Unmarshal(params, &p); err != nil {
		return nil, err
	}
	mimeType, err := validateMimeType(p.MimeType)
	if err != nil {
		return nil, err
	}
	return map[string]any{"mimeType": mimeType, "appIds": appsForMime(mimeType)}, nil
}

func (m *Manager) handleQueryDefaults(params json.RawMessage) (any, error) {
	var p defaultParams
	if err := json.Unmarshal(params, &p); err != nil {
		return nil, err
	}
	mimeTypes, err := validateMimeTypes(p.MimeTypes)
	if err != nil {
		return nil, err
	}
	defaults := map[string]string{}
	for _, mt := range mimeTypes {
		id, err := queryDefault(mt, m.log)
		if err != nil {
			return nil, err
		}
		defaults[mt] = id
	}
	return map[string]any{"defaults": defaults}, nil
}

func (m *Manager) handleInvalidate(json.RawMessage) (any, error) {
	return map[string]any{"success": true}, nil
}

func (m *Manager) handleBrowserOpen(params json.RawMessage) (any, error) {
	var p openParams
	if err := json.Unmarshal(params, &p); err != nil {
		return nil, err
	}
	target := firstNonEmpty(p.Target, p.URL)
	target, err := validateURLTarget(target)
	if err != nil {
		return nil, err
	}
	m.srv.Broadcast("browser.open_requested", map[string]any{
		"target":      target,
		"url":         target,
		"requestType": "url",
	})
	return map[string]any{"success": true}, nil
}

func (m *Manager) handleAppPickerOpen(params json.RawMessage) (any, error) {
	var p openParams
	if err := json.Unmarshal(params, &p); err != nil {
		return nil, err
	}
	target, requestType, err := validateOpenTarget(p.Target, p.RequestType)
	if err != nil {
		return nil, err
	}
	mimeType := strings.TrimSpace(p.MimeType)
	if mimeType != "" {
		mimeType, err = validateMimeType(mimeType)
		if err != nil {
			return nil, err
		}
	}
	categories, err := validateCategories(p.Categories)
	if err != nil {
		return nil, err
	}
	m.srv.Broadcast("browser.open_requested", map[string]any{
		"target":      target,
		"requestType": requestType,
		"mimeType":    mimeType,
		"categories":  categories,
	})
	return map[string]any{"success": true}, nil
}

func appsForMime(mimeType string) []string {
	seen := map[string]bool{}
	var ids []string
	for _, dir := range applicationDirs() {
		root := dir
		_ = filepath.WalkDir(root, func(path string, entry os.DirEntry, err error) error {
			if err != nil || entry.IsDir() || !strings.HasSuffix(entry.Name(), ".desktop") {
				return nil
			}
			if !desktopFileSupportsMime(path, mimeType) {
				return nil
			}
			// Per the desktop-entry spec, a file in a subdirectory gets a
			// dash-joined ID ("kde4/okular.desktop" -> "kde4-okular.desktop").
			rel, relErr := filepath.Rel(root, path)
			if relErr != nil {
				return nil
			}
			id := strings.ReplaceAll(rel, string(filepath.Separator), "-")
			if !seen[id] {
				seen[id] = true
				ids = append(ids, id)
			}
			return nil
		})
	}
	sort.Strings(ids)
	return ids
}

func desktopFileSupportsMime(path, mimeType string) bool {
	data, err := os.ReadFile(path)
	if err != nil {
		return false
	}
	inDesktopEntry := false
	for _, line := range strings.Split(string(data), "\n") {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, "[") {
			// MimeType is only meaningful in the main group, not in
			// [Desktop Action ...] sections.
			inDesktopEntry = line == "[Desktop Entry]"
			continue
		}
		if !inDesktopEntry {
			continue
		}
		key, value, ok := strings.Cut(line, "=")
		if !ok || strings.TrimSpace(key) != "MimeType" {
			continue
		}
		for _, mt := range strings.Split(strings.TrimSpace(value), ";") {
			if mt == mimeType {
				return true
			}
		}
	}
	return false
}

func applicationDirs() []string {
	var dirs []string
	if xdgDataHome := os.Getenv("XDG_DATA_HOME"); xdgDataHome != "" {
		dirs = append(dirs, filepath.Join(xdgDataHome, "applications"))
	} else if home := os.Getenv("HOME"); home != "" {
		dirs = append(dirs, filepath.Join(home, ".local/share/applications"))
	}
	xdgDataDirs := os.Getenv("XDG_DATA_DIRS")
	if xdgDataDirs == "" {
		xdgDataDirs = "/usr/local/share:/usr/share"
	}
	for _, dir := range strings.Split(xdgDataDirs, ":") {
		if dir != "" {
			dirs = append(dirs, filepath.Join(dir, "applications"))
		}
	}
	return dirs
}

func validateMimeTypes(values []string) ([]string, error) {
	var out []string
	seen := map[string]bool{}
	for _, value := range values {
		mt, err := validateMimeType(value)
		if err != nil {
			return nil, err
		}
		if !seen[mt] {
			seen[mt] = true
			out = append(out, mt)
		}
	}
	if len(out) == 0 {
		return nil, fmt.Errorf("at least one MIME type is required")
	}
	return out, nil
}

func validateMimeType(value string) (string, error) {
	value = strings.TrimSpace(value)
	if len(value) < 3 || len(value) > 128 || strings.ContainsAny(value, " \t\r\n") {
		return "", fmt.Errorf("invalid MIME type")
	}
	if !strings.Contains(value, "/") {
		return "", fmt.Errorf("invalid MIME type")
	}
	for _, r := range value {
		if !(r == '/' || r == '+' || r == '-' || r == '.' || (r >= '0' && r <= '9') || (r >= 'A' && r <= 'Z') || (r >= 'a' && r <= 'z')) {
			return "", fmt.Errorf("invalid MIME type")
		}
	}
	return value, nil
}

func validateDesktopID(value string) (string, error) {
	value = strings.TrimSpace(value)
	if value == "" {
		return "", fmt.Errorf("desktop file id is required")
	}
	if !strings.HasSuffix(value, ".desktop") {
		value += ".desktop"
	}
	if strings.Contains(value, "/") || strings.Contains(value, "\\") || strings.ContainsAny(value, "\x00\r\n") || len(value) > 256 {
		return "", fmt.Errorf("invalid desktop file id")
	}
	return value, nil
}

func validateURLTarget(value string) (string, error) {
	value = strings.TrimSpace(value)
	if value == "" || len(value) > 4096 || strings.ContainsAny(value, "\x00\r\n") {
		return "", fmt.Errorf("invalid URL target")
	}
	u, err := url.Parse(value)
	if err != nil || u.Scheme == "" {
		return "", fmt.Errorf("invalid URL target")
	}
	switch strings.ToLower(u.Scheme) {
	case "http", "https", "vshell":
		return value, nil
	default:
		return "", fmt.Errorf("unsupported URL scheme: %s", u.Scheme)
	}
}

func validateOpenTarget(value, requestType string) (string, string, error) {
	value = strings.TrimSpace(value)
	if value == "" || len(value) > 4096 || strings.ContainsAny(value, "\x00\r\n") {
		return "", "", fmt.Errorf("invalid open target")
	}
	if strings.HasPrefix(value, "file://") {
		u, err := url.Parse(value)
		if err != nil || u.Scheme != "file" || u.Path == "" {
			return "", "", fmt.Errorf("invalid file URI")
		}
		return value, "file", nil
	}
	if filepath.IsAbs(value) {
		return value, "file", nil
	}
	if requestType == "uri" {
		u, err := url.Parse(value)
		if err != nil || u.Scheme == "" {
			return "", "", fmt.Errorf("invalid URI")
		}
		return value, "uri", nil
	}
	return "", "", fmt.Errorf("open target must be an absolute path or file URI")
}

func validateCategories(values []string) ([]string, error) {
	out := make([]string, 0, len(values))
	for _, value := range values {
		value = strings.TrimSpace(value)
		if value == "" {
			continue
		}
		if len(value) > 64 {
			return nil, fmt.Errorf("invalid category")
		}
		for _, r := range value {
			if !(r == '-' || r == '_' || (r >= '0' && r <= '9') || (r >= 'A' && r <= 'Z') || (r >= 'a' && r <= 'z')) {
				return nil, fmt.Errorf("invalid category")
			}
		}
		out = append(out, value)
	}
	return out, nil
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if strings.TrimSpace(value) != "" {
			return value
		}
	}
	return ""
}
