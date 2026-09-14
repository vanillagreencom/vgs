package networkmanager

import (
	"encoding/json"
	"io"
	"log/slog"
	"reflect"
	"testing"
)

func TestSplitEscaped(t *testing.T) {
	got := splitEscaped(`Cafe\:Lab:aa\:bb\:cc:80:WPA2`, ':')
	want := []string{"Cafe:Lab", "aa:bb:cc", "80", "WPA2"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("splitEscaped() = %#v, want %#v", got, want)
	}
}

func TestFirstIP(t *testing.T) {
	if got, want := firstIP("192.168.68.67/22, 10.0.0.2/24"), "192.168.68.67"; got != want {
		t.Fatalf("firstIP() = %q, want %q", got, want)
	}
}

func TestMergeSavedWiFi(t *testing.T) {
	conns := []map[string]string{
		{"name": "Home", "type": "802-11-wireless", "autoconnect": "yes"},
		{"name": "Office", "type": "802-11-wireless", "autoconnect": "no"},
		{"name": "Wired", "type": "802-3-ethernet", "autoconnect": "yes"},
	}
	visible := []wifiNetwork{{SSID: "Home", Signal: 72}}
	got := mergeSavedWiFi(conns, visible)
	if len(got) != 2 {
		t.Fatalf("len = %d, want 2: %#v", len(got), got)
	}
	if !got[0].Autoconnect || got[0].OutOfRange {
		t.Fatalf("Home saved state wrong: %#v", got[0])
	}
	if !got[1].OutOfRange {
		t.Fatalf("Office should be out of range: %#v", got[1])
	}
}

// Before the first sweep there is no state to report. An all-empty one would
// reach the shell as "disconnected, radio off" while NetworkManager is merely
// restarting.
func TestCachedStateBeforeFirstSweepReportsNothing(t *testing.T) {
	m := &Manager{preference: "auto"}
	if got := m.cachedState(); got != nil {
		t.Fatalf("cached state before the first sweep = %+v, want nothing to send", got)
	}
}

func TestCachedStateReturnsTheLastSweep(t *testing.T) {
	m := &Manager{preference: "auto"}
	m.lastState = networkState{NetworkStatus: "wifi", WiFiSSID: "home"}
	m.hasLastState = true
	st, ok := m.cachedState().(networkState)
	if !ok {
		t.Fatalf("cached state is %T, want networkState", m.cachedState())
	}
	if st.NetworkStatus != "wifi" || st.WiFiSSID != "home" {
		t.Fatalf("cached state = %+v, want the recorded sweep", st)
	}
}

// An interactive connect that cannot read the network state must leave no
// prompt behind: nothing broadcasts a token for it, so the entry would sit in
// m.pending unreachable by a cancel for the life of the daemon.
func TestInteractiveConnectRecordsNoPromptWhenTheSweepFails(t *testing.T) {
	// An empty PATH makes every nmcli call fail, which is what a restarting
	// NetworkManager looks like to this handler.
	t.Setenv("PATH", t.TempDir())
	m := &Manager{
		log:        slog.New(slog.NewTextHandler(io.Discard, nil)),
		pending:    map[string]pendingPrompt{},
		preference: "auto",
	}
	params, err := json.Marshal(map[string]any{"ssid": "somenet", "interactive": true})
	if err != nil {
		t.Fatal(err)
	}

	if _, err := m.handleWiFiConnect(params); err == nil {
		t.Fatal("handleWiFiConnect returned no error with every nmcli call failing")
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	if len(m.pending) != 0 {
		t.Fatalf("pending prompts = %v; no broadcast carried a token for them and no cancel can reach them", m.pending)
	}
}
