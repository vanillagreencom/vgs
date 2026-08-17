package cups

import (
	"encoding/json"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"

	"vshell/backend/internal/server"
)

func TestParsePrinters(t *testing.T) {
	printers := parsePrinters(
		[]byte("device for Office: ipp://printer.local/ipp/print\n"),
		[]byte("printer Office is idle.  enabled since Thu Jul  9 08:00:00 2026\n"),
		[]byte("Office accepting requests since Thu Jul  9 08:00:00 2026\n"),
	)
	if len(printers) != 1 {
		t.Fatalf("len(printers) = %d, want 1", len(printers))
	}
	p := printers[0]
	if p.Name != "Office" || p.URI != "ipp://printer.local/ipp/print" || p.State != "idle" || !p.Accepting {
		t.Fatalf("unexpected printer: %#v", p)
	}
}

func TestParseJobs(t *testing.T) {
	jobs := parseJobs([]byte("Office-42 method 1024 Thu Jul  9 08:00:00 2026\n"))
	if len(jobs) != 1 {
		t.Fatalf("len(jobs) = %d, want 1", len(jobs))
	}
	job := jobs[0]
	if job.ID != "42" || job.Printer != "Office" || job.User != "method" || job.Size != 1024 {
		t.Fatalf("unexpected job: %#v", job)
	}
}

func TestHandleTestConnectionReturnsURI(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	port := ln.Addr().(*net.TCPAddr).Port
	m, _ := fakeManager(t)
	got, err := m.handleTestConnection(mustJSON(t, testParams{Host: "127.0.0.1", Port: port, Protocol: "ipp"}))
	if err != nil {
		t.Fatal(err)
	}
	out, ok := got.(map[string]any)
	if !ok {
		t.Fatalf("result type %T", got)
	}
	wantURI, err := buildManualDeviceURI("ipp", "127.0.0.1", port, "")
	if err != nil {
		t.Fatal(err)
	}
	if out["reachable"] != true || out["uri"] != wantURI {
		t.Fatalf("reachable result = %#v, want uri %q", out, wantURI)
	}
	got, err = m.handleTestConnection(mustJSON(t, testParams{Host: "127.0.0.1", Port: port, Protocol: "lpd", Queue: "rawq"}))
	if err != nil {
		t.Fatal(err)
	}
	out, ok = got.(map[string]any)
	if !ok {
		t.Fatalf("lpd result type %T", got)
	}
	if out["reachable"] != true || out["uri"] != "lpd://127.0.0.1:"+strconv.Itoa(port)+"/rawq" {
		t.Fatalf("lpd queue result = %#v", out)
	}
	_ = ln.Close()
	got, err = m.handleTestConnection(mustJSON(t, testParams{Host: "127.0.0.1", Port: port, Protocol: "ipp"}))
	if err != nil {
		t.Fatal(err)
	}
	out, ok = got.(map[string]any)
	if !ok {
		t.Fatalf("closed result type %T", got)
	}
	if out["reachable"] != false || out["uri"] != wantURI {
		t.Fatalf("closed result = %#v, want uri %q", out, wantURI)
	}
}

func TestParsePrinterDisabledAndRejecting(t *testing.T) {
	printers := parsePrinters(
		[]byte("device for Office: ipp://user:secret@printer.local/ipp/print\n"),
		[]byte("printer Office disabled since Thu Jul  9 08:00:00 2026 - paused\n"),
		[]byte("Office not accepting requests since Thu Jul  9 08:00:00 2026\n"),
	)
	if len(printers) != 1 {
		t.Fatalf("len(printers) = %d, want 1", len(printers))
	}
	p := printers[0]
	if p.State != "stopped" || p.Accepting || strings.Contains(p.URI, "secret") {
		t.Fatalf("unexpected printer: %#v", p)
	}
}

func TestParsePPDsAndClasses(t *testing.T) {
	ppds := parsePPDs([]byte("everywhere IPP Everywhere\nsample.ppd Sample Printer\ndriverless:ipps://Brother%20HL-L2460DW._ipps._tcp.local/ Brother HL-L2460DW, driverless\n"))
	if len(ppds) != 3 || ppds[1].Name != "sample.ppd" || ppds[1].MakeModel != "Sample Printer" {
		t.Fatalf("unexpected ppds: %#v", ppds)
	}
	if ppds[2].Name != "driverless:ipps://Brother%20HL-L2460DW._ipps._tcp.local/" {
		t.Fatalf("unexpected driverless ppd: %#v", ppds[2])
	}
	classes := parseClasses([]byte("members of class Lab: Office Shipping\n"))
	if len(classes) != 1 || classes[0].Name != "Lab" || strings.Join(classes[0].Members, ",") != "Office,Shipping" {
		t.Fatalf("unexpected classes: %#v", classes)
	}
}

func TestCupsWriteHandlersValidateAndInvokeExpectedCommands(t *testing.T) {
	m, logPath := fakeManager(t)
	shared := true

	if _, err := m.handleCreatePrinter(mustJSON(t, createParams{
		Name:        "Office",
		DeviceURI:   "ipp://printer.local/ipp/print",
		PPD:         "sample.ppd",
		Shared:      &shared,
		Location:    "Lab",
		Information: "Office printer",
		ErrorPolicy: "retry-job",
	})); err != nil {
		t.Fatal(err)
	}
	if _, err := m.handleCancelJob(mustJSON(t, jobParams{JobID: "Office-42"})); err != nil {
		t.Fatal(err)
	}
	if _, err := m.handleMoveJob(mustJSON(t, jobParams{JobID: "Office-42", DestPrinter: "Shipping"})); err != nil {
		t.Fatal(err)
	}
	if _, err := m.handleHoldJob(mustJSON(t, jobParams{JobID: "Office-42", HoldUntil: "indefinite"})); err != nil {
		t.Fatal(err)
	}
	if _, err := m.handleAddPrinterToClass(mustJSON(t, classParams{ClassName: "Lab", PrinterName: "Office"})); err != nil {
		t.Fatal(err)
	}
	if _, err := m.handlePurgeJobs(mustJSON(t, printerParams{PrinterName: "Office"})); err != nil {
		t.Fatal(err)
	}
	if _, err := m.handleSetPrinterShared(mustJSON(t, sharedParams{PrinterName: "Office", Shared: false})); err != nil {
		t.Fatal(err)
	}
	if _, err := m.handleSetPrinterLocation(mustJSON(t, locationParams{PrinterName: "Office", Location: "Front Desk"})); err != nil {
		t.Fatal(err)
	}
	if _, err := m.handleSetPrinterInfo(mustJSON(t, infoParams{PrinterName: "Office", Info: "Shared laser"})); err != nil {
		t.Fatal(err)
	}
	if _, err := m.handlePrintTestPage(mustJSON(t, printerParams{PrinterName: "Office"})); err != nil {
		t.Fatal(err)
	}
	if _, err := m.handleRestartJob(mustJSON(t, jobParams{JobID: "Office-42"})); err != nil {
		t.Fatal(err)
	}
	if _, err := m.handleRemovePrinterFromClass(mustJSON(t, classParams{ClassName: "Lab", PrinterName: "Office"})); err != nil {
		t.Fatal(err)
	}
	if _, err := m.handleDeleteClass(mustJSON(t, classParams{ClassName: "Lab"})); err != nil {
		t.Fatal(err)
	}

	log := readLog(t, logPath)
	for _, want := range []string{
		"lpinfo -m",
		"lpadmin -p Office -E -v ipp://printer.local/ipp/print -m sample.ppd -L Lab -D Office printer -o printer-is-shared=true -o printer-error-policy=retry-job",
		"cancel Office-42",
		"lpmove Office-42 Shipping",
		"lp -i Office-42 -H indefinite",
		"lpadmin -p Office -c Lab",
		"cancel -a Office",
		"lpadmin -p Office -o printer-is-shared=false",
		"lpadmin -p Office -L Front Desk",
		"lpadmin -p Office -D Shared laser",
		"lp -d Office ",
		"lp -i Office-42 -H restart",
		"lpadmin -p Office -r Lab",
		"lpadmin -x Lab",
	} {
		if !strings.Contains(log, want) {
			t.Fatalf("command log missing %q\n%s", want, log)
		}
	}
}

func TestCupsWriteHandlersRejectInvalidInput(t *testing.T) {
	m, logPath := fakeManager(t)
	cases := []struct {
		name string
		call func() (any, error)
	}{
		{"bad printer", func() (any, error) { return m.handlePausePrinter(mustJSON(t, printerParams{PrinterName: "../bad"})) }},
		{"bad uri credentials", func() (any, error) {
			return m.handleCreatePrinter(mustJSON(t, createParams{Name: "Office", DeviceURI: "ipp://u:p@printer.local/ipp", PPD: "sample.ppd"}))
		}},
		{"bad ppd", func() (any, error) {
			return m.handleCreatePrinter(mustJSON(t, createParams{Name: "Office", DeviceURI: "ipp://printer.local/ipp", PPD: "../sample.ppd"}))
		}},
		{"bad hold", func() (any, error) {
			return m.handleHoldJob(mustJSON(t, jobParams{JobID: "Office-42", HoldUntil: "soon"}))
		}},
		{"bad error policy", func() (any, error) {
			return m.handleCreatePrinter(mustJSON(t, createParams{Name: "Office", DeviceURI: "ipp://printer.local/ipp", PPD: "sample.ppd", ErrorPolicy: "shell"}))
		}},
		{"bad protocol", func() (any, error) {
			return m.handleTestConnection(mustJSON(t, testParams{Host: "printer.local", Protocol: "ssh"}))
		}},
		{"bad port", func() (any, error) {
			return m.handleTestConnection(mustJSON(t, testParams{Host: "printer.local", Port: 70000}))
		}},
		{"bad location newline", func() (any, error) {
			return m.handleSetPrinterLocation(mustJSON(t, locationParams{PrinterName: "Office", Location: "Lab\nbad"}))
		}},
		{"bad info newline", func() (any, error) {
			return m.handleSetPrinterInfo(mustJSON(t, infoParams{PrinterName: "Office", Info: "Info\nbad"}))
		}},
		{"bad class", func() (any, error) {
			return m.handleRemovePrinterFromClass(mustJSON(t, classParams{ClassName: "../Lab", PrinterName: "Office"}))
		}},
		{"bad host", func() (any, error) {
			return m.handleTestConnection(mustJSON(t, testParams{Host: "bad host", Port: 631}))
		}},
		{"bad lpd queue", func() (any, error) {
			return m.handleTestConnection(mustJSON(t, testParams{Host: "printer.local", Protocol: "lpd", Queue: "raw/q"}))
		}},
	}
	for _, tc := range cases {
		if _, err := tc.call(); err == nil {
			t.Fatalf("%s returned nil error", tc.name)
		}
	}
	if log := readLog(t, logPath); log != "" {
		t.Fatalf("invalid inputs ran commands:\n%s", log)
	}
}

func TestCreatePrinterAcceptsBonjourDeviceURI(t *testing.T) {
	m, logPath := fakeManager(t)
	if _, err := m.handleCreatePrinter(mustJSON(t, createParams{
		Name:      "Brother",
		DeviceURI: "dnssd://Brother%20HL-L2460DW._ipp._tcp.local/?uuid=e3248000-80ce-11db-8000-94ddf8e120ec",
		PPD:       "everywhere",
	})); err != nil {
		t.Fatal(err)
	}
	log := readLog(t, logPath)
	if !strings.Contains(log, "lpadmin -p Brother -E -v dnssd://Brother%20HL-L2460DW._ipp._tcp.local/?uuid=e3248000-80ce-11db-8000-94ddf8e120ec -m everywhere") {
		t.Fatalf("bonjour create missing lpadmin:\n%s", log)
	}
}

func TestCreatePrinterAcceptsDriverlessPPD(t *testing.T) {
	m, logPath := fakeManager(t)
	ppd := "driverless:ipps://Brother%20HL-L2460DW._ipps._tcp.local/"
	if _, err := m.handleCreatePrinter(mustJSON(t, createParams{
		Name:      "Brother",
		DeviceURI: "ipps://Brother%20HL-L2460DW._ipps._tcp.local/",
		PPD:       ppd,
	})); err != nil {
		t.Fatal(err)
	}
	log := readLog(t, logPath)
	want := "lpadmin -p Brother -E -v ipps://Brother%20HL-L2460DW._ipps._tcp.local/ -m " + ppd
	if !strings.Contains(log, want) {
		t.Fatalf("driverless create missing lpadmin:\n%s", log)
	}
}

func TestCreatePrinterRejectsUnavailablePPDWithoutMutation(t *testing.T) {
	m, logPath := fakeManager(t)
	_, err := m.handleCreatePrinter(mustJSON(t, createParams{Name: "Office", DeviceURI: "ipp://printer.local/ipp", PPD: "missing.ppd"}))
	if err == nil {
		t.Fatal("missing ppd returned nil error")
	}
	log := readLog(t, logPath)
	if !strings.Contains(log, "lpinfo -m") {
		t.Fatalf("missing ppd did not inspect catalog:\n%s", log)
	}
	if strings.Contains(log, "lpadmin") {
		t.Fatalf("missing ppd mutated printer state:\n%s", log)
	}
}

func TestOutputAllowEmptyOnlySwallowsKnownEmptyStates(t *testing.T) {
	m, _ := fakeManager(t)
	m.cmds["lpstat"] = fakeCommand(t, "lpstat", "", "lpstat: Scheduler is not running", 1)
	if _, err := m.outputAllowEmpty("lpstat", "-v"); err == nil {
		t.Fatal("scheduler failure was swallowed")
	}
	m.cmds["lpstat"] = fakeCommand(t, "lpstat", "", "lpstat: No destinations added.", 1)
	out, err := m.outputAllowEmpty("lpstat", "-v")
	if err != nil || len(out) != 0 {
		t.Fatalf("known empty state = %q, %v; want empty nil", out, err)
	}
}

func fakeManager(t *testing.T) (*Manager, string) {
	t.Helper()
	dir := t.TempDir()
	logPath := filepath.Join(dir, "commands.log")
	cmds := map[string]string{}
	for _, name := range []string{"lpstat", "lpinfo", "lpadmin", "cancel", "lp", "cupsaccept", "cupsreject", "cupsenable", "cupsdisable", "lpmove"} {
		cmds[name] = fakeCupsCommand(t, dir, name, logPath)
	}
	return &Manager{srv: server.New(0, nil), cmds: cmds}, logPath
}

func fakeCupsCommand(t *testing.T, dir, name, logPath string) string {
	t.Helper()
	path := filepath.Join(dir, name)
	body := "#!/bin/sh\n" +
		"printf '%s' \"" + name + "\" >> " + shellQuote(logPath) + "\n" +
		"for arg in \"$@\"; do printf ' %s' \"$arg\" >> " + shellQuote(logPath) + "; done\n" +
		"printf '\\n' >> " + shellQuote(logPath) + "\n" +
		"if [ \"" + name + "\" = lpinfo ] && [ \"$1\" = -m ]; then printf '%s\\n' 'everywhere IPP Everywhere' 'sample.ppd Sample Printer'; fi\n" +
		"exit 0\n"
	if err := os.WriteFile(path, []byte(body), 0o755); err != nil {
		t.Fatal(err)
	}
	return path
}

func fakeCommand(t *testing.T, name, stdout, stderr string, code int) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), name)
	body := "#!/bin/sh\nprintf '%s' " + shellQuote(stdout) + "\nprintf '%s' " + shellQuote(stderr) + " >&2\nexit " + strconv.Itoa(code) + "\n"
	if err := os.WriteFile(path, []byte(body), 0o755); err != nil {
		t.Fatal(err)
	}
	return path
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
