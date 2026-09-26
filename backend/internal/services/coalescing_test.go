package services

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

// declaredCoalescing is the whole set of services whose broadcasts may replace
// a frame the peer has not read yet. A service belongs here only when every
// frame it broadcasts under that name carries the whole of its state, so the
// newest subsumes the rest.
//
// A frame that is not whole state loses the earlier one outright, with nothing
// to report it. Two names were declared and then withdrawn once their producers
// were read: a per-monitor wallpaper rotation, and a tailscale login URL no
// status frame carries. Three others never carried a declaration at all, and
// were coalesced by the earlier default that replaced every service's unread
// frame: a per-URL open request, a per-device pairing prompt, and a
// per-subscription D-Bus signal. Adding or removing a declaration is an edit
// here as well as at the call site, so it cannot be acquired by an audit that
// reads one file.
var declaredCoalescing = map[string]struct {
	file string
	why  string
}{
	"bluetooth":               {"bluez/bluez.go", "the adapter's whole device list"},
	"brightness":              {"brightnessbridge/brightnessbridge.go", "every backlight the helper enumerates"},
	"clipboard":               {"clipboard/clipboard.go", "the clipboard's current contents"},
	"cloudsync":               {"cloudsync/cloudsync.go", "every folder's status and transfers"},
	"evdev":                   {"evdev/evdev.go", "the LED state the indicator renders"},
	"freedesktop":             {"freedesktop/screensaver.go", "accounts, settings and screensaver state together"},
	"freedesktop.screensaver": {"freedesktop/screensaver.go", "the inhibitor list and whether it inhibits"},
	"gamma":                   {"gamma/gamma.go", "the whole night-mode state"},
	"location":                {"location/location.go", "the current coordinates"},
	"network":                 {"networkmanager/networkmanager.go", "the whole nmcli sweep"},
	"sysupdate":               {"sysupdate/sysupdate.go", "the package list, backends and recent log"},
	"wlroutput":               {"wlroutput/wlroutput.go", "every output the compositor reports"},
}

var coalesceCallRe = regexp.MustCompile(`CoalesceBroadcasts\("([^"]+)"\)`)

// scanDeclarations reads every declaration in the service tree, as
// service name to the file declaring it.
func scanDeclarations(t *testing.T) map[string]string {
	t.Helper()
	found := map[string]string{}
	err := filepath.WalkDir(".", func(path string, d os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() || !strings.HasSuffix(path, ".go") || strings.HasSuffix(path, "_test.go") {
			return nil
		}
		body, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		for _, m := range coalesceCallRe.FindAllStringSubmatch(string(body), -1) {
			if prior, ok := found[m[1]]; ok {
				t.Fatalf("service %q is declared in both %s and %s", m[1], prior, path)
			}
			found[m[1]] = filepath.ToSlash(path)
		}
		return nil
	})
	if err != nil {
		t.Fatalf("walk service tree: %v", err)
	}
	if len(found) == 0 {
		t.Fatal("the scan found no declarations at all, so it proves nothing about the set")
	}
	return found
}

func TestDeclaredCoalescingSetMatchesItsOwner(t *testing.T) {
	found := scanDeclarations(t)

	for service, file := range found {
		row, ok := declaredCoalescing[service]
		if !ok {
			t.Errorf("%s declares CoalesceBroadcasts(%q) with no row here; add one naming the whole state it broadcasts, or drop the declaration", file, service)
			continue
		}
		if declared := strings.TrimPrefix(file, "./"); row.file != declared {
			t.Errorf("%q is declared in %s, but its row names %s", service, declared, row.file)
		}
		if row.why == "" {
			t.Errorf("%q has no reason recorded", service)
		}
	}
	for service, row := range declaredCoalescing {
		if _, ok := found[service]; !ok {
			t.Errorf("%q has a row naming %s but nothing declares it; remove the row", service, row.file)
		}
	}
}

// TestEventShapedServicesAreNotDeclared names the services whose frames do not
// subsume one another. Each was found by reading its producer, and two of them
// carried a declaration here before.
func TestEventShapedServicesAreNotDeclared(t *testing.T) {
	found := scanDeclarations(t)
	for _, row := range []struct {
		service string
		why     string
	}{
		{"browser.open_requested", "one frame per URL the user opened"},
		{"bluetooth.pairing", "one frame per device's pairing prompt"},
		{"network.credentials", "one frame per SSID's credential prompt"},
		{"dbus", "one frame per subscription id"},
		{"cups", "a printer list and a bare changed marker share this name"},
		{"loginctl", "Locked and PreparingForSleep are edges the shell acts on"},
		{"wallpaper", "CycleSeq and Target carry one monitor's rotation"},
		{"tailscale", "an auth frame carries a login URL no status frame has"},
	} {
		if file, ok := found[row.service]; ok {
			t.Errorf("%s declares %q for coalescing, but %s", file, row.service, row.why)
		}
	}
}
