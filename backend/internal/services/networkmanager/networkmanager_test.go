package networkmanager

import (
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"reflect"
	"testing"

	"vshell/backend/internal/refresh"
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

type noBroadcast struct{}

func (noBroadcast) Broadcast(string, any) {}

// newStubManager builds a Manager whose sweep is a stub, so the registered
// snapshot path can be exercised without nmcli.
func newStubManager(sweep func() (networkState, error)) *Manager {
	m := &Manager{
		log:        slog.New(slog.NewTextHandler(io.Discard, nil)),
		pending:    map[string]pendingPrompt{},
		preference: "auto",
	}
	m.state = refresh.NewService(noBroadcast{}, m.log, "network", 0, sweep)
	return m
}

// Before the first sweep there is no state to report. An all-empty one would
// reach the shell as "disconnected, radio off" while NetworkManager is merely
// restarting.
func TestCachedStateBeforeFirstSweepReportsNothing(t *testing.T) {
	m := newStubManager(func() (networkState, error) {
		return networkState{}, errors.New("device status: nmcli unavailable")
	})
	if got := m.state.Cached(); got != nil {
		t.Fatalf("cached state before the first sweep = %+v, want nothing to send", got)
	}
	if _, err := m.stateChecked(); err == nil {
		t.Fatal("stateChecked returned no error for a failing sweep")
	}
	if got := m.state.Cached(); got != nil {
		t.Fatalf("a failed sweep cached %+v; an all-empty state must not become truth", got)
	}
}

// The handler path records into the source subscribe reads.
func TestStateCheckedWarmsTheRegisteredSource(t *testing.T) {
	m := newStubManager(func() (networkState, error) {
		return networkState{NetworkStatus: "wifi", WiFiSSID: "home"}, nil
	})
	if _, err := m.stateChecked(); err != nil {
		t.Fatalf("stateChecked: %v", err)
	}
	st, ok := m.state.Cached().(networkState)
	if !ok {
		t.Fatalf("cached state is %T, want networkState", m.state.Cached())
	}
	if st.NetworkStatus != "wifi" || st.WiFiSSID != "home" {
		t.Fatalf("cached state = %+v, want the recorded sweep", st)
	}
}

// An interactive connect that cannot read the network state must leave no
// prompt behind: nothing broadcasts a token for it, so the entry would sit in
// m.pending unreachable by a cancel for the life of the daemon.
func TestInteractiveConnectRecordsNoPromptWhenTheSweepFails(t *testing.T) {
	// A failing sweep is what a restarting NetworkManager looks like here.
	m := newStubManager(func() (networkState, error) {
		return networkState{}, errors.New("device status: nmcli unavailable")
	})
	params, err := json.Marshal(map[string]any{"ssid": "somenet", "interactive": true})
	if err != nil {
		t.Fatal(err)
	}

	if _, err := m.handleWiFiConnect(params); err == nil {
		t.Fatal("handleWiFiConnect returned no error with a failing sweep")
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	if len(m.pending) != 0 {
		t.Fatalf("pending prompts = %v; no broadcast carried a token for them and no cancel can reach them", m.pending)
	}
}
