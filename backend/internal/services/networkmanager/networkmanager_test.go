package networkmanager

import (
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
