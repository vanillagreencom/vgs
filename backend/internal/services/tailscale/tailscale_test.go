package tailscale

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"

	"vshell/backend/internal/server"
)

const statusFixture = `{
  "Version": "1.90.0",
  "BackendState": "Running",
  "Health": ["dns warning"],
  "CurrentTailnet": { "Name": "example.ts.net", "MagicDNSSuffix": "tail.example.ts.net" },
  "User": {
    "1": { "LoginName": "method@example.com", "DisplayName": "Method" },
    "2": { "LoginName": "ops@example.com", "DisplayName": "Ops" }
  },
  "Self": {
    "ID": "self-id",
    "HostName": "laptop",
    "DNSName": "laptop.tail.example.ts.net.",
    "OS": "linux",
    "UserID": 1,
    "TailscaleIPs": ["100.64.0.1", "fd7a:115c:a1e0::1"],
    "Online": true
  },
  "Peer": {
    "peer-b": {
      "ID": "node-b",
      "HostName": "exitbox",
      "DNSName": "exitbox.tail.example.ts.net.",
      "OS": "linux",
      "UserID": 2,
      "TailscaleIPs": ["100.64.0.2"],
      "Online": true,
      "ExitNodeOption": true,
      "ExitNode": true,
      "Relay": "sfo",
      "RxBytes": 12,
      "TxBytes": 34
    },
    "peer-a": {
      "ID": "node-a",
      "HostName": "phone",
      "DNSName": "phone.tail.example.ts.net.",
      "OS": "ios",
      "UserID": 1,
      "TailscaleIPs": ["100.64.0.3"],
      "Online": false
    }
  }
}`

func TestStatusMapsFixture(t *testing.T) {
	m, _ := fakeManager(t)
	state, err := m.status()
	if err != nil {
		t.Fatal(err)
	}
	if !state.Connected || state.Version != "1.90.0" || state.MagicDNSSuffix != "tail.example.ts.net" || state.TailnetName != "example.ts.net" {
		t.Fatalf("unexpected state: %#v", state)
	}
	if state.Self == nil || state.Self.TailscaleIP != "100.64.0.1" || state.Self.TailscaleIPv6 != "fd7a:115c:a1e0::1" || state.Self.Owner != "Method" {
		t.Fatalf("unexpected self: %#v", state.Self)
	}
	if len(state.Peers) != 2 || state.Peers[0].ID != "node-a" || state.Peers[1].ID != "node-b" {
		t.Fatalf("peers not sorted/mapped: %#v", state.Peers)
	}
	if !state.Peers[1].ExitNodeOption || !state.Peers[1].ExitNode || state.Peers[1].Owner != "Ops" {
		t.Fatalf("unexpected exit peer: %#v", state.Peers[1])
	}
	if !state.AcceptRoutes || !state.ExitNodeAllowLanAccess {
		t.Fatalf("prefs not mapped: %#v", state)
	}
	if len(state.Health) != 1 || state.Health[0] != "dns warning" {
		t.Fatalf("health not mapped: %#v", state.Health)
	}
}

func TestActionsInvokeExpectedArgv(t *testing.T) {
	m, logPath := fakeManager(t)
	if _, err := m.handleConnect(nil); err != nil {
		t.Fatal(err)
	}
	if _, err := m.handleDisconnect(nil); err != nil {
		t.Fatal(err)
	}
	if _, err := m.handleSetExitNode(mustJSON(t, exitNodeParams{ID: "node-b"})); err != nil {
		t.Fatal(err)
	}
	if _, err := m.handleSetAllowLANAccess(mustJSON(t, lanParams{Enabled: true})); err != nil {
		t.Fatal(err)
	}
	if _, err := m.handleSetAcceptRoutes(mustJSON(t, lanParams{Enabled: false})); err != nil {
		t.Fatal(err)
	}
	if _, err := m.handleSetAcceptRoutes(mustJSON(t, lanParams{Enabled: true})); err != nil {
		t.Fatal(err)
	}
	if _, err := m.handleSetExitNode(mustJSON(t, exitNodeParams{ID: ""})); err != nil {
		t.Fatal(err)
	}
	log := readLog(t, logPath)
	for _, want := range []string{
		"up",
		"down",
		"set --exit-node=100.64.0.2",
		"set --exit-node-allow-lan-access=true",
		"set --accept-routes=false",
		"set --accept-routes",
		"set --exit-node=",
	} {
		if !strings.Contains(log, want) {
			t.Fatalf("log missing %q\n%s", want, log)
		}
	}
}

func TestSetExitNodeAcceptsCliTargets(t *testing.T) {
	for _, target := range []string{"100.64.0.2", "exitbox.tail.example.ts.net.", "exitbox.tail.example.ts.net", "exitbox"} {
		m, logPath := fakeManager(t)
		if _, err := m.handleSetExitNode(mustJSON(t, exitNodeParams{ID: target})); err != nil {
			t.Fatalf("target %q rejected: %v", target, err)
		}
		if !strings.Contains(readLog(t, logPath), "set --exit-node=100.64.0.2") {
			t.Fatalf("target %q did not resolve to IP:\n%s", target, readLog(t, logPath))
		}
	}
}

func TestSetExitNodeRejectsUnavailableTarget(t *testing.T) {
	m, logPath := fakeManager(t)
	if _, err := m.handleSetExitNode(mustJSON(t, exitNodeParams{ID: "phone"})); err == nil {
		t.Fatal("non-exit peer accepted as exit node")
	}
	if strings.Contains(readLog(t, logPath), "set --exit-node") {
		t.Fatalf("invalid exit node ran set:\n%s", readLog(t, logPath))
	}
}

func TestConnectReturnsAuthURL(t *testing.T) {
	m, logPath := fakeManagerWithUp(t, "To authenticate, visit: https://login.tailscale.com/a/abc123", 1, `{"RouteAll":true,"ExitNodeAllowLANAccess":true}`, 0)
	resp, err := m.handleConnect(nil)
	if err != nil {
		t.Fatal(err)
	}
	state := resp.(State)
	if state.AuthURL != "https://login.tailscale.com/a/abc123" {
		t.Fatalf("AuthURL = %q", state.AuthURL)
	}
	if !strings.Contains(readLog(t, logPath), "up") {
		t.Fatalf("connect did not run up:\n%s", readLog(t, logPath))
	}
}

func TestStatusStillMapsWhenPrefsFail(t *testing.T) {
	m, _ := fakeManagerWithPrefs(t, "not-json", 0)
	state, err := m.status()
	if err != nil {
		t.Fatal(err)
	}
	if !state.Connected || len(state.Peers) != 2 {
		t.Fatalf("status not mapped after prefs failure: %#v", state)
	}
	if state.AcceptRoutes || state.ExitNodeAllowLanAccess {
		t.Fatalf("prefs failure should leave route prefs false: %#v", state)
	}

	m, _ = fakeManagerWithPrefs(t, "", 1)
	state, err = m.status()
	if err != nil {
		t.Fatal(err)
	}
	if !state.Connected || len(state.Peers) != 2 {
		t.Fatalf("status not mapped after prefs command error: %#v", state)
	}
}

func fakeManager(t *testing.T) (*Manager, string) {
	return fakeManagerWithUp(t, "", 0, `{"RouteAll":true,"ExitNodeAllowLANAccess":true}`, 0)
}

func fakeManagerWithPrefs(t *testing.T, prefs string, prefsExit int) (*Manager, string) {
	return fakeManagerWithUp(t, "", 0, prefs, prefsExit)
}

func fakeManagerWithUp(t *testing.T, upOutput string, upExit int, prefs string, prefsExit int) (*Manager, string) {
	t.Helper()
	dir := t.TempDir()
	logPath := filepath.Join(dir, "tailscale.log")
	path := filepath.Join(dir, "tailscale")
	body := "#!/bin/sh\n" +
		"printf '%s' \"$*\" >> " + shellQuote(logPath) + "\n" +
		"printf '\\n' >> " + shellQuote(logPath) + "\n" +
		"if [ \"$1\" = status ] && [ \"$2\" = --json ]; then cat " + shellQuote(filepath.Join(dir, "status.json")) + "; exit 0; fi\n" +
		"if [ \"$1\" = debug ] && [ \"$2\" = prefs ]; then printf '%s\\n' " + shellQuote(prefs) + "; exit " + strconv.Itoa(prefsExit) + "; fi\n" +
		"if [ \"$1\" = up ]; then printf '%s\\n' " + shellQuote(upOutput) + "; exit " + strconv.Itoa(upExit) + "; fi\n" +
		"exit 0\n"
	if err := os.WriteFile(filepath.Join(dir, "status.json"), []byte(statusFixture), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(body), 0o755); err != nil {
		t.Fatal(err)
	}
	return &Manager{srv: server.New(0, nil), tailscale: path}, logPath
}

func mustJSON(t *testing.T, value any) json.RawMessage {
	t.Helper()
	raw, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	return raw
}

func readLog(t *testing.T, path string) string {
	t.Helper()
	raw, err := os.ReadFile(path)
	if os.IsNotExist(err) {
		return ""
	}
	if err != nil {
		t.Fatal(err)
	}
	return string(raw)
}

func shellQuote(value string) string {
	return "'" + strings.ReplaceAll(value, "'", "'\\''") + "'"
}
