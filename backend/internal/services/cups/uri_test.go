package cups

import "testing"

func TestValidateDeviceURIAcceptsCUPSBonjourHosts(t *testing.T) {
	for _, uri := range []string{
		"dnssd://Brother%20HL-L2460DW._ipp._tcp.local/?uuid=e3248000-80ce-11db-8000-94ddf8e120ec",
		"ipps://Brother%20HL-L2460DW._ipps._tcp.local/",
		"ipp://printer.local/ipp/print",
		"ipp://192.168.1.20:631/ipp/print",
		"ipp://[2001:db8::1]:631/ipp/print",
		"usb://Brother/HL-L2460DW%20series?serial=ABC",
		"socket://192.168.1.20:9100",
		"parallel:/dev/lp0",
	} {
		if err := validateDeviceURI(uri); err != nil {
			t.Fatalf("validateDeviceURI(%q) = %v", uri, err)
		}
	}
}

func TestValidateDeviceURIRejectsUnsafeValues(t *testing.T) {
	cases := map[string]string{
		"empty":        "",
		"no scheme":    "printer.local/ipp",
		"space":        "dnssd://Brother HL-L2460DW._ipp._tcp.local/",
		"credentials":  "ipp://u:p@printer.local/ipp",
		"scheme":       "ftp://printer.local/ipp",
		"port":         "ipp://printer.local:70000/ipp",
		"control":       "ipp://printer.local/ipp\n",
		"encoded nl":    "ipp://printer%0A.local/ipp",
		"bad escape":    "ipp://Brother%ZZ._ipp._tcp.local/",
		"encoded slash": "ipp://printer%2Flocal/ipp",
		"missing host":  "ipp://",
	}
	for name, uri := range cases {
		if err := validateDeviceURI(uri); err == nil {
			t.Fatalf("%s: validateDeviceURI(%q) = nil", name, uri)
		}
	}
}

func TestSanitizeURIStripsCredentialsWithoutRFCParse(t *testing.T) {
	got := sanitizeURI("ipp://user:secret@Brother%20HL-L2460DW.local/ipp")
	if got != "ipp://Brother%20HL-L2460DW.local/ipp" {
		t.Fatalf("sanitizeURI = %q", got)
	}
	if got := sanitizeURI("ipp://printer.local/ipp"); got != "ipp://printer.local/ipp" {
		t.Fatalf("sanitizeURI unchanged = %q", got)
	}
}

func TestValidatePPDNameAcceptsCatalogAndDriverless(t *testing.T) {
	for _, name := range []string{
		"everywhere",
		"sample.ppd",
		"foomatic:Brother-DCP-7010-ljet4.ppd",
		"gutenprint.5.3://pcl-apple-4100/expert",
		"drv:///cupsfilters.drv/pwgrast.ppd",
		"driverless:ipps://Brother%20HL-L2460DW._ipps._tcp.local/",
	} {
		if err := validatePPDName(name); err != nil {
			t.Fatalf("validatePPDName(%q) = %v", name, err)
		}
	}
}

func TestValidatePPDNameRejectsUnsafeValues(t *testing.T) {
	cases := map[string]string{
		"empty":        "",
		"dotdot":       "../sample.ppd",
		"space":        "sample ppd",
		"newline":      "sample.ppd\n",
		"credentials":  "driverless:ipp://u:p@printer.local/ipp",
		"scheme":       "driverless:ftp://printer.local/ipp",
		"encoded slash": "driverless:ipp://printer%2Flocal/ipp",
		"missing host": "driverless:ipp://",
	}
	for name, ppd := range cases {
		if err := validatePPDName(ppd); err == nil {
			t.Fatalf("%s: validatePPDName(%q) = nil", name, ppd)
		}
	}
}

func TestExtractHostDecodesBonjourInstance(t *testing.T) {
	got := extractHost("dnssd://Brother%20HL-L2460DW._ipp._tcp.local/?uuid=abc")
	if got != "Brother HL-L2460DW._ipp._tcp.local" {
		t.Fatalf("extractHost = %q", got)
	}
	if got := extractHost("ipp://[2001:db8::1]:631/ipp"); got != "2001:db8::1" {
		t.Fatalf("extractHost ipv6 = %q", got)
	}
}

func TestDeviceInstanceNameStripsBonjourService(t *testing.T) {
	got := deviceInstanceName("dnssd://Brother%20HL-L2460DW._ipp._tcp.local/?uuid=abc")
	if got != "Brother HL-L2460DW" {
		t.Fatalf("deviceInstanceName = %q", got)
	}
	if got := deviceInstanceName("ipps://Brother%20HL-L2460DW._ipps._tcp.local/"); got != "Brother HL-L2460DW" {
		t.Fatalf("deviceInstanceName ipps = %q", got)
	}
}

func TestIsBareProtocolURI(t *testing.T) {
	for _, uri := range []string{"ipp", "ipp:", "ipps://", "socket", "dnssd://"} {
		if !isBareProtocolURI(uri) {
			t.Fatalf("isBareProtocolURI(%q) = false", uri)
		}
	}
	if isBareProtocolURI("ipp://printer.local/ipp/print") {
		t.Fatal("full ipp URI treated as bare")
	}
}

func TestIsVirtualBackendURI(t *testing.T) {
	if !isVirtualBackendURI("file", "cups-pdf:/") {
		t.Fatal("cups-pdf not treated as virtual")
	}
	if isVirtualBackendURI("network", "dnssd://Brother%20HL-L2460DW._ipp._tcp.local/") {
		t.Fatal("bonjour treated as virtual")
	}
}

func TestBuildManualDeviceURI(t *testing.T) {
	got, err := buildManualDeviceURI("ipp", "printer.local", 631)
	if err != nil {
		t.Fatal(err)
	}
	if got != "ipp://printer.local:631/ipp/print" {
		t.Fatalf("buildManualDeviceURI = %q", got)
	}
	got, err = buildManualDeviceURI("socket", "192.168.1.20", 0)
	if err != nil {
		t.Fatal(err)
	}
	if got != "socket://192.168.1.20:9100" {
		t.Fatalf("socket default port = %q", got)
	}
}

func TestSchemeTransportLabel(t *testing.T) {
	if got := schemeTransportLabel("ipps"); got != "Secure IPP" {
		t.Fatalf("schemeTransportLabel(ipps) = %q", got)
	}
	if got := schemeTransportLabel("ipp"); got != "Network IPP" {
		t.Fatalf("schemeTransportLabel(ipp) = %q", got)
	}
}
