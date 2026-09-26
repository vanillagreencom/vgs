package bluez

import (
	"errors"
	"io"
	"log/slog"
	"testing"

	"vshell/backend/internal/server"
)

// newStubManager builds a Manager through the shipped constructor with a stub
// object sweep, so the registered snapshot path runs without a system bus.
func newStubManager(sweep func() (State, error)) *Manager {
	// A real server with no listener: Broadcast reaches no subscriber, which is
	// what a kick in these tests should do.
	return newManager(server.New(0, nil), nil, slog.New(slog.NewTextHandler(io.Discard, nil)), sweep)
}

// A Manager is never assembled field by field: its D-Bus signal goroutine kicks
// the refresh service, and a Manager without one panics on the first org.bluez
// property change, which bluetoothd emits within microseconds of the match
// being installed.
func TestNewManagerAlwaysBuildsItsRefreshService(t *testing.T) {
	m := newStubManager(func() (State, error) { return State{}, nil })
	if m.state == nil {
		t.Fatal("newManager left the refresh service nil")
	}
	// The signal goroutine's entry point, which must be safe the moment a
	// Manager exists.
	m.broadcastSoon()
}

// An unswept adapter must not reach the shell as "powered off, no devices":
// the Bluetooth popout would show that until the refresh sweep lands.
func TestCachedStateBeforeTheFirstSweepReportsNothing(t *testing.T) {
	m := newStubManager(func() (State, error) { return State{}, errors.New("no system bus") })
	if got := m.state.Cached(); got != nil {
		t.Fatalf("cached state before the first sweep = %v, want nothing to send", got)
	}
	if _, err := m.GetStateChecked(); err == nil {
		t.Fatal("GetStateChecked returned no error for a failing sweep")
	}
	if got := m.state.Cached(); got != nil {
		t.Fatalf("a failed sweep cached %v; an empty adapter must not become the shell's truth", got)
	}
}

// The method path records into the source subscribe reads, so a getState call
// warms what the next subscribe serves.
func TestGetStateCheckedWarmsTheRegisteredSource(t *testing.T) {
	want := State{Powered: true, Devices: []Device{{Address: "AA:BB:CC:DD:EE:FF"}}}
	m := newStubManager(func() (State, error) { return want, nil })

	if _, err := m.GetStateChecked(); err != nil {
		t.Fatalf("GetStateChecked: %v", err)
	}
	got, ok := m.state.Cached().(State)
	if !ok {
		t.Fatalf("cached state is %T, want State", m.state.Cached())
	}
	if !got.Powered || len(got.Devices) != 1 {
		t.Fatalf("cached state = %+v, want the recorded sweep", got)
	}
}
