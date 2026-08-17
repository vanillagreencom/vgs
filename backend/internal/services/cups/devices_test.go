package cups

import (
	"strings"
	"testing"
)

func TestParseDevices(t *testing.T) {
	devices := parseDevices([]byte("network ipp://user:secret@printer.local/ipp/print\n"))
	if len(devices) != 1 {
		t.Fatalf("len(devices) = %d, want 1", len(devices))
	}
	if devices[0].Class != "network" || devices[0].IP != "printer.local" || strings.Contains(devices[0].URI, "secret") {
		t.Fatalf("unexpected device: %#v", devices[0])
	}
}

func TestParseDevicesDropsTrailingDescription(t *testing.T) {
	devices := parseDevices([]byte("network socket://printer.local:9100 \"HP LaserJet 4000\"\n"))
	if len(devices) != 1 {
		t.Fatalf("len(devices) = %d, want 1", len(devices))
	}
	if devices[0].URI != "socket://printer.local:9100" {
		t.Fatalf("URI carried the description: %q", devices[0].URI)
	}
	if err := validateDeviceURI(devices[0].URI); err != nil {
		t.Fatalf("parsed URI failed deviceURI validation: %v", err)
	}
}

func TestParseDevicesInfoUsesBonjourInstanceNotUSBHost(t *testing.T) {
	devices := parseDevices([]byte(
		"network dnssd://Brother%20HL-L2460DW._ipp._tcp.local/?uuid=abc\n" +
			"direct usb://Brother/HL-L2460DW%20series?serial=ABC\n",
	))
	if len(devices) != 2 {
		t.Fatalf("len(devices) = %d, want 2", len(devices))
	}
	if devices[0].Info != "Brother HL-L2460DW" {
		t.Fatalf("bonjour Info = %q", devices[0].Info)
	}
	if devices[1].Info == "Brother" || devices[1].Info == devices[1].IP {
		t.Fatalf("usb Info collapsed to manufacturer host: %#v", devices[1])
	}
}
