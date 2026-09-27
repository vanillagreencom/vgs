package launchersearch

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
)

// config is the part of a request that decides what the index holds. Two
// requests with the same key are answered from the same index.
type config struct {
	roots        []string
	ignores      ignoreRules
	ignoreMounts bool
	key          string
}

// ignoreRules is the launcherSearchIgnored setting in the form the walk tests
// against. A bare name ignores every entry of that name at any depth; any other
// value ignores one path and everything under it, either as written when it is
// absolute or joined to each root when it is not.
type ignoreRules struct {
	names    map[string]bool
	prefixes []string
}

func (r ignoreRules) ignored(path, name string) bool {
	if r.names[name] {
		return true
	}
	for _, prefix := range r.prefixes {
		if path == prefix || strings.HasPrefix(path, prefix+"/") {
			return true
		}
	}
	return false
}

// ignoredRoot reports whether a root lies inside an ignored path, or has an
// ignored name among its own components, which hides every entry under it.
func (r ignoreRules) ignoredRoot(root string) bool {
	for _, part := range strings.Split(root, "/") {
		if part != "" && r.names[part] {
			return true
		}
	}
	return r.ignored(root, filepath.Base(root))
}

var errNoRoots = errors.New("no searchable roots")

// newConfig resolves the request's roots and ignores the way the settings page
// writes them: "~" means the home directory and $NAME an environment variable.
// A root that is not a directory is dropped, and a request left with none is
// refused, as `vshell launcher-search search` refuses it.
func newConfig(rawRoots, rawIgnores []string, ignoreMounts bool) (config, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return config{}, err
	}
	if len(rawRoots) == 0 {
		rawRoots = []string{"~"}
	}
	seen := map[string]bool{}
	var roots []string
	for _, raw := range rawRoots {
		value := strings.TrimSpace(raw)
		if value == "" {
			continue
		}
		resolved, err := filepath.EvalSymlinks(expandHome(value, home))
		if err != nil {
			continue
		}
		resolved, err = filepath.Abs(resolved)
		if err != nil {
			continue
		}
		if info, err := os.Stat(resolved); err != nil || !info.IsDir() || seen[resolved] {
			continue
		}
		seen[resolved] = true
		roots = append(roots, resolved)
	}
	if len(roots) == 0 {
		return config{}, errNoRoots
	}

	rules := ignoreRules{names: map[string]bool{}}
	var ignoreKey []string
	for _, raw := range rawIgnores {
		value := strings.TrimSpace(raw)
		if value == "" {
			continue
		}
		value = expandHome(os.Expand(value, keepUnsetVariable), home)
		ignoreKey = append(ignoreKey, value)
		switch {
		case filepath.IsAbs(value):
			rules.prefixes = append(rules.prefixes, filepath.Clean(value))
		case !strings.Contains(strings.Trim(value, "/"), "/"):
			rules.names[strings.Trim(value, "/")] = true
		default:
			for _, root := range roots {
				rules.prefixes = append(rules.prefixes, filepath.Join(root, value))
			}
		}
	}

	mounts := "0"
	if ignoreMounts {
		mounts = "1"
	}
	key := strings.Join(roots, "\x00") + "\x01" + strings.Join(ignoreKey, "\x00") + "\x01" + mounts
	return config{roots: roots, ignores: rules, ignoreMounts: ignoreMounts, key: key}, nil
}

func expandHome(value, home string) string {
	if value == "~" {
		return home
	}
	if strings.HasPrefix(value, "~/") {
		return filepath.Join(home, value[2:])
	}
	return value
}

// keepUnsetVariable leaves a variable that is not set as written, so an ignore
// entry naming one keeps its literal text instead of collapsing to nothing.
func keepUnsetVariable(name string) string {
	if value, ok := os.LookupEnv(name); ok {
		return value
	}
	return "$" + name
}
