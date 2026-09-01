package cups

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"

	"vshell/backend/internal/execbound"
	"vshell/backend/internal/server"
)

const timeout = 20 * time.Second

var (
	nameRe        = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$`)
	jobIDRe       = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$`)
	ppdRe         = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._/+:-]{0,255}$`)
	errorPolicies = map[string]bool{
		"abort-job":         true,
		"retry-job":         true,
		"retry-current-job": true,
		"stop-printer":      true,
	}
	holdValues = map[string]bool{
		"hold":         true,
		"indefinite":   true,
		"no-hold":      true,
		"restart":      true,
		"resume":       true,
		"immediate":    true,
		"day-time":     true,
		"evening":      true,
		"night":        true,
		"second-shift": true,
		"third-shift":  true,
		"weekend":      true,
	}
)

type Manager struct {
	srv  *server.Server
	cmds map[string]string
}

type Printer struct {
	Name        string `json:"name"`
	URI         string `json:"uri"`
	State       string `json:"state"`
	StateReason string `json:"stateReason"`
	Location    string `json:"location"`
	Info        string `json:"info"`
	MakeModel   string `json:"makeModel"`
	Accepting   bool   `json:"accepting"`
}

type Job struct {
	ID          string `json:"id"`
	Name        string `json:"name"`
	State       string `json:"state"`
	Printer     string `json:"printer"`
	User        string `json:"user"`
	Size        int64  `json:"size"`
	TimeCreated string `json:"timeCreated"`
}

type Device struct {
	URI       string `json:"uri"`
	Class     string `json:"class"`
	Info      string `json:"info"`
	MakeModel string `json:"makeModel"`
	ID        string `json:"id"`
	Location  string `json:"location"`
	IP        string `json:"ip"`
}

type PPD struct {
	Name            string `json:"name"`
	NaturalLanguage string `json:"naturalLanguage"`
	MakeModel       string `json:"makeModel"`
	DeviceID        string `json:"deviceId"`
	Product         string `json:"product"`
	PSVersion       string `json:"psVersion"`
	Type            string `json:"type"`
}

type Class struct {
	Name     string   `json:"name"`
	URI      string   `json:"uri"`
	State    string   `json:"state"`
	Members  []string `json:"members"`
	Location string   `json:"location"`
	Info     string   `json:"info"`
}

type printerParams struct {
	PrinterName string `json:"printerName"`
}

type jobParams struct {
	PrinterName string `json:"printerName"`
	JobID       string `json:"jobID"`
	DestPrinter string `json:"destPrinter"`
	HoldUntil   string `json:"holdUntil"`
}

type createParams struct {
	Name        string `json:"name"`
	DeviceURI   string `json:"deviceURI"`
	PPD         string `json:"ppd"`
	Shared      *bool  `json:"shared"`
	Location    string `json:"location"`
	Information string `json:"information"`
	ErrorPolicy string `json:"errorPolicy"`
}

type testParams struct {
	Host     string `json:"host"`
	Port     int    `json:"port"`
	Protocol string `json:"protocol"`
	Queue    string `json:"queue"`
}

type sharedParams struct {
	PrinterName string `json:"printerName"`
	Shared      bool   `json:"shared"`
}

type locationParams struct {
	PrinterName string `json:"printerName"`
	Location    string `json:"location"`
}

type infoParams struct {
	PrinterName string `json:"printerName"`
	Info        string `json:"info"`
}

type classParams struct {
	ClassName   string `json:"className"`
	PrinterName string `json:"printerName"`
}

func Register(srv *server.Server, log *slog.Logger) (*Manager, error) {
	required := []string{"lpstat", "lpinfo", "lpadmin", "cancel", "lp"}
	cmds := map[string]string{}
	for _, name := range append(required, "cupsaccept", "cupsreject", "cupsenable", "cupsdisable", "lpmove") {
		if path, err := exec.LookPath(name); err == nil {
			cmds[name] = path
		}
	}
	for _, name := range required {
		if cmds[name] == "" {
			return nil, fmt.Errorf("%s not found", name)
		}
	}
	m := &Manager{srv: srv, cmds: cmds}
	srv.Register("cups", "cups.getPrinters", m.handleGetPrinters)
	srv.Register("cups", "cups.getJobs", m.handleGetJobs)
	srv.Register("cups", "cups.pausePrinter", m.handlePausePrinter)
	srv.Register("cups", "cups.resumePrinter", m.handleResumePrinter)
	srv.Register("cups", "cups.cancelJob", m.handleCancelJob)
	srv.Register("cups", "cups.purgeJobs", m.handlePurgeJobs)
	srv.Register("cups", "cups.getDevices", m.handleGetDevices)
	srv.Register("cups", "cups.getPPDs", m.handleGetPPDs)
	srv.Register("cups", "cups.getClasses", m.handleGetClasses)
	srv.Register("cups", "cups.testConnection", m.handleTestConnection)
	srv.Register("cups", "cups.createPrinter", m.handleCreatePrinter)
	srv.Register("cups", "cups.deletePrinter", m.handleDeletePrinter)
	srv.Register("cups", "cups.acceptJobs", m.handleAcceptJobs)
	srv.Register("cups", "cups.rejectJobs", m.handleRejectJobs)
	srv.Register("cups", "cups.setPrinterShared", m.handleSetPrinterShared)
	srv.Register("cups", "cups.setPrinterLocation", m.handleSetPrinterLocation)
	srv.Register("cups", "cups.setPrinterInfo", m.handleSetPrinterInfo)
	srv.Register("cups", "cups.printTestPage", m.handlePrintTestPage)
	srv.Register("cups", "cups.moveJob", m.handleMoveJob)
	srv.Register("cups", "cups.restartJob", m.handleRestartJob)
	srv.Register("cups", "cups.holdJob", m.handleHoldJob)
	srv.Register("cups", "cups.addPrinterToClass", m.handleAddPrinterToClass)
	srv.Register("cups", "cups.removePrinterFromClass", m.handleRemovePrinterFromClass)
	srv.Register("cups", "cups.deleteClass", m.handleDeleteClass)
	srv.RegisterSnapshot("cups", func() any {
		printers, err := m.printers()
		if err != nil {
			return map[string]any{"printers": []any{}, "error": err.Error()}
		}
		return map[string]any{"printers": printers}
	})
	return m, nil
}

func (m *Manager) Close() {}

func (m *Manager) handleGetPrinters(json.RawMessage) (any, error) { return m.printers() }

func (m *Manager) handleGetJobs(params json.RawMessage) (any, error) {
	var p printerParams
	_ = json.Unmarshal(params, &p)
	return m.jobs(p.PrinterName)
}

func (m *Manager) handlePausePrinter(params json.RawMessage) (any, error) {
	var p printerParams
	if err := json.Unmarshal(params, &p); err != nil {
		return nil, err
	}
	return m.simplePrinter("cupsdisable", p.PrinterName)
}

func (m *Manager) handleResumePrinter(params json.RawMessage) (any, error) {
	var p printerParams
	if err := json.Unmarshal(params, &p); err != nil {
		return nil, err
	}
	return m.simplePrinter("cupsenable", p.PrinterName)
}

func (m *Manager) handleCancelJob(params json.RawMessage) (any, error) {
	var p jobParams
	if err := json.Unmarshal(params, &p); err != nil {
		return nil, err
	}
	if p.JobID == "" {
		return nil, fmt.Errorf("jobID required")
	}
	if err := validateJobID(p.JobID); err != nil {
		return nil, err
	}
	return m.ok(m.run("cancel", p.JobID))
}

func (m *Manager) handlePurgeJobs(params json.RawMessage) (any, error) {
	var p printerParams
	if err := json.Unmarshal(params, &p); err != nil {
		return nil, err
	}
	if p.PrinterName == "" {
		return nil, fmt.Errorf("printerName required")
	}
	if err := validateName("printerName", p.PrinterName); err != nil {
		return nil, err
	}
	return m.ok(m.run("cancel", "-a", p.PrinterName))
}

func (m *Manager) handleGetDevices(json.RawMessage) (any, error) {
	out, err := m.outputAllowEmpty("lpinfo", "-v")
	if err != nil {
		return nil, err
	}
	return parseDevices(out), nil
}

func (m *Manager) handleGetPPDs(json.RawMessage) (any, error) {
	out, err := m.outputAllowEmpty("lpinfo", "-m")
	if err != nil {
		return nil, err
	}
	return parsePPDs(out), nil
}

func (m *Manager) handleGetClasses(json.RawMessage) (any, error) {
	out, err := m.outputAllowEmpty("lpstat", "-c")
	if err != nil {
		return nil, err
	}
	return parseClasses(out), nil
}

func (m *Manager) handleTestConnection(params json.RawMessage) (any, error) {
	var p testParams
	if err := json.Unmarshal(params, &p); err != nil {
		return nil, err
	}
	if p.Host == "" {
		return nil, fmt.Errorf("host required")
	}
	if err := validateHost(p.Host); err != nil {
		return nil, err
	}
	if err := validateProtocol(p.Protocol); err != nil {
		return nil, err
	}
	if p.Port <= 0 {
		p.Port = defaultPort(p.Protocol)
	}
	if p.Port <= 0 || p.Port > 65535 {
		return nil, fmt.Errorf("port out of range")
	}
	uri, err := buildManualDeviceURI(p.Protocol, p.Host, p.Port, p.Queue)
	if err != nil {
		return nil, err
	}
	conn, err := net.DialTimeout("tcp", net.JoinHostPort(p.Host, strconv.Itoa(p.Port)), 3*time.Second)
	if err != nil {
		return map[string]any{"ok": false, "reachable": false, "host": p.Host, "port": p.Port, "uri": uri, "error": err.Error()}, nil
	}
	_ = conn.Close()
	return map[string]any{"ok": true, "reachable": true, "host": p.Host, "port": p.Port, "uri": uri}, nil
}

func (m *Manager) handleCreatePrinter(params json.RawMessage) (any, error) {
	var p createParams
	if err := json.Unmarshal(params, &p); err != nil {
		return nil, err
	}
	if p.Name == "" || p.DeviceURI == "" || p.PPD == "" {
		return nil, fmt.Errorf("name, deviceURI, and ppd are required")
	}
	if err := validateName("name", p.Name); err != nil {
		return nil, err
	}
	if err := validateDeviceURI(p.DeviceURI); err != nil {
		return nil, err
	}
	if err := validatePPDName(p.PPD); err != nil {
		return nil, err
	}
	if err := validateText("location", p.Location, 256); err != nil {
		return nil, err
	}
	if err := validateText("information", p.Information, 256); err != nil {
		return nil, err
	}
	if p.ErrorPolicy != "" && !errorPolicies[p.ErrorPolicy] {
		return nil, fmt.Errorf("invalid errorPolicy")
	}
	if err := m.validatePPDAvailable(p.PPD); err != nil {
		return nil, err
	}
	args := []string{"-p", p.Name, "-E", "-v", p.DeviceURI, "-m", p.PPD}
	if p.Location != "" {
		args = append(args, "-L", p.Location)
	}
	if p.Information != "" {
		args = append(args, "-D", p.Information)
	}
	if p.Shared != nil {
		args = append(args, "-o", fmt.Sprintf("printer-is-shared=%t", *p.Shared))
	}
	if p.ErrorPolicy != "" {
		args = append(args, "-o", "printer-error-policy="+p.ErrorPolicy)
	}
	return m.ok(m.run("lpadmin", args...))
}

func (m *Manager) handleDeletePrinter(params json.RawMessage) (any, error) {
	var p printerParams
	if err := json.Unmarshal(params, &p); err != nil {
		return nil, err
	}
	return m.simplePrinter("lpadmin", p.PrinterName, "-x")
}

func (m *Manager) handleAcceptJobs(params json.RawMessage) (any, error) {
	var p printerParams
	if err := json.Unmarshal(params, &p); err != nil {
		return nil, err
	}
	return m.simplePrinter("cupsaccept", p.PrinterName)
}

func (m *Manager) handleRejectJobs(params json.RawMessage) (any, error) {
	var p printerParams
	if err := json.Unmarshal(params, &p); err != nil {
		return nil, err
	}
	return m.simplePrinter("cupsreject", p.PrinterName)
}

func (m *Manager) handleSetPrinterShared(params json.RawMessage) (any, error) {
	var p sharedParams
	if err := json.Unmarshal(params, &p); err != nil {
		return nil, err
	}
	if p.PrinterName == "" {
		return nil, fmt.Errorf("printerName required")
	}
	if err := validateName("printerName", p.PrinterName); err != nil {
		return nil, err
	}
	return m.ok(m.run("lpadmin", "-p", p.PrinterName, "-o", fmt.Sprintf("printer-is-shared=%t", p.Shared)))
}

func (m *Manager) handleSetPrinterLocation(params json.RawMessage) (any, error) {
	var p locationParams
	if err := json.Unmarshal(params, &p); err != nil {
		return nil, err
	}
	if p.PrinterName == "" {
		return nil, fmt.Errorf("printerName required")
	}
	if err := validateName("printerName", p.PrinterName); err != nil {
		return nil, err
	}
	if err := validateText("location", p.Location, 256); err != nil {
		return nil, err
	}
	return m.ok(m.run("lpadmin", "-p", p.PrinterName, "-L", p.Location))
}

func (m *Manager) handleSetPrinterInfo(params json.RawMessage) (any, error) {
	var p infoParams
	if err := json.Unmarshal(params, &p); err != nil {
		return nil, err
	}
	if p.PrinterName == "" {
		return nil, fmt.Errorf("printerName required")
	}
	if err := validateName("printerName", p.PrinterName); err != nil {
		return nil, err
	}
	if err := validateText("info", p.Info, 256); err != nil {
		return nil, err
	}
	return m.ok(m.run("lpadmin", "-p", p.PrinterName, "-D", p.Info))
}

func (m *Manager) handlePrintTestPage(params json.RawMessage) (any, error) {
	var p printerParams
	if err := json.Unmarshal(params, &p); err != nil {
		return nil, err
	}
	if p.PrinterName == "" {
		return nil, fmt.Errorf("printerName required")
	}
	if err := validateName("printerName", p.PrinterName); err != nil {
		return nil, err
	}
	testFile := firstExisting("/usr/share/cups/data/testprint", "/usr/share/cups/data/default-testpage.pdf")
	var cleanup func()
	if testFile == "" {
		file, err := os.CreateTemp("", "vshell-cups-test-*.txt")
		if err != nil {
			return nil, err
		}
		_, _ = file.WriteString("VGS printer test page\n")
		_ = file.Close()
		testFile = file.Name()
		cleanup = func() { _ = os.Remove(testFile) }
	}
	if cleanup != nil {
		defer cleanup()
	}
	out, err := m.output("lp", "-d", p.PrinterName, testFile)
	if err != nil {
		return nil, err
	}
	return map[string]any{"ok": true, "output": strings.TrimSpace(string(out))}, nil
}

func (m *Manager) handleMoveJob(params json.RawMessage) (any, error) {
	var p jobParams
	if err := json.Unmarshal(params, &p); err != nil {
		return nil, err
	}
	if p.JobID == "" || p.DestPrinter == "" {
		return nil, fmt.Errorf("jobID and destPrinter required")
	}
	if err := validateJobID(p.JobID); err != nil {
		return nil, err
	}
	if err := validateName("destPrinter", p.DestPrinter); err != nil {
		return nil, err
	}
	return m.ok(m.run("lpmove", p.JobID, p.DestPrinter))
}

func (m *Manager) handleRestartJob(params json.RawMessage) (any, error) {
	var p jobParams
	if err := json.Unmarshal(params, &p); err != nil {
		return nil, err
	}
	if p.JobID == "" {
		return nil, fmt.Errorf("jobID required")
	}
	if err := validateJobID(p.JobID); err != nil {
		return nil, err
	}
	return m.ok(m.run("lp", "-i", p.JobID, "-H", "restart"))
}

func (m *Manager) handleHoldJob(params json.RawMessage) (any, error) {
	var p jobParams
	if err := json.Unmarshal(params, &p); err != nil {
		return nil, err
	}
	if p.JobID == "" {
		return nil, fmt.Errorf("jobID required")
	}
	if err := validateJobID(p.JobID); err != nil {
		return nil, err
	}
	hold := p.HoldUntil
	if hold == "" {
		hold = "hold"
	}
	if !holdValues[hold] {
		return nil, fmt.Errorf("invalid holdUntil")
	}
	return m.ok(m.run("lp", "-i", p.JobID, "-H", hold))
}

func (m *Manager) handleAddPrinterToClass(params json.RawMessage) (any, error) {
	var p classParams
	if err := json.Unmarshal(params, &p); err != nil {
		return nil, err
	}
	if p.ClassName == "" || p.PrinterName == "" {
		return nil, fmt.Errorf("className and printerName required")
	}
	if err := validateName("className", p.ClassName); err != nil {
		return nil, err
	}
	if err := validateName("printerName", p.PrinterName); err != nil {
		return nil, err
	}
	return m.ok(m.run("lpadmin", "-p", p.PrinterName, "-c", p.ClassName))
}

func (m *Manager) handleRemovePrinterFromClass(params json.RawMessage) (any, error) {
	var p classParams
	if err := json.Unmarshal(params, &p); err != nil {
		return nil, err
	}
	if p.ClassName == "" || p.PrinterName == "" {
		return nil, fmt.Errorf("className and printerName required")
	}
	if err := validateName("className", p.ClassName); err != nil {
		return nil, err
	}
	if err := validateName("printerName", p.PrinterName); err != nil {
		return nil, err
	}
	return m.ok(m.run("lpadmin", "-p", p.PrinterName, "-r", p.ClassName))
}

func (m *Manager) handleDeleteClass(params json.RawMessage) (any, error) {
	var p classParams
	if err := json.Unmarshal(params, &p); err != nil {
		return nil, err
	}
	if p.ClassName == "" {
		return nil, fmt.Errorf("className required")
	}
	if err := validateName("className", p.ClassName); err != nil {
		return nil, err
	}
	return m.ok(m.run("lpadmin", "-x", p.ClassName))
}

func (m *Manager) printers() ([]Printer, error) {
	urisOut, err := m.outputAllowEmpty("lpstat", "-v")
	if err != nil {
		return nil, err
	}
	stateOut, err := m.outputAllowEmpty("lpstat", "-p")
	if err != nil {
		return nil, err
	}
	acceptOut, err := m.outputAllowEmpty("lpstat", "-a")
	if err != nil {
		return nil, err
	}
	printers := parsePrinters(urisOut, stateOut, acceptOut)
	if printers == nil {
		printers = []Printer{}
	}
	return printers, nil
}

func (m *Manager) jobs(printerName string) ([]Job, error) {
	args := []string{"-o"}
	if printerName != "" {
		if err := validateName("printerName", printerName); err != nil {
			return nil, err
		}
		args = append(args, printerName)
	}
	out, err := m.outputAllowEmpty("lpstat", args...)
	if err != nil {
		return nil, err
	}
	return parseJobs(out), nil
}

func (m *Manager) simplePrinter(cmdName, printer string, mode ...string) (any, error) {
	if printer == "" {
		return nil, fmt.Errorf("printerName required")
	}
	if err := validateName("printerName", printer); err != nil {
		return nil, err
	}
	if cmdName == "lpadmin" && len(mode) == 1 && mode[0] == "-x" {
		return m.ok(m.run("lpadmin", "-x", printer))
	}
	return m.ok(m.run(cmdName, printer))
}

func (m *Manager) ok(err error) (any, error) {
	if err != nil {
		return nil, err
	}
	m.srv.Broadcast("cups", map[string]any{"changed": true})
	return map[string]bool{"ok": true}, nil
}

func (m *Manager) output(cmdName string, args ...string) ([]byte, error) {
	cmdPath := m.cmds[cmdName]
	if cmdPath == "" {
		return nil, fmt.Errorf("%s not found", cmdName)
	}
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	res, err := execbound.Command(ctx, cmdPath, args...).Output()
	out := res.Out
	if err != nil {
		if errors.Is(err, execbound.ErrTimeout) {
			return nil, fmt.Errorf("%s timed out", cmdName)
		}
		if ee, ok := err.(*exec.ExitError); ok {
			msg := strings.TrimSpace(string(ee.Stderr))
			if msg == "" {
				msg = strings.TrimSpace(string(out))
			}
			if msg != "" {
				return out, fmt.Errorf("%s", msg)
			}
		}
		return out, err
	}
	return out, nil
}

func (m *Manager) outputAllowEmpty(cmdName string, args ...string) ([]byte, error) {
	out, err := m.output(cmdName, args...)
	if err == nil {
		return out, nil
	}
	msg := strings.ToLower(err.Error())
	if strings.Contains(msg, "no destinations") || strings.Contains(msg, "no printers") || strings.Contains(msg, "no active jobs") {
		return []byte{}, nil
	}
	return out, err
}

func (m *Manager) run(cmdName string, args ...string) error {
	_, err := m.output(cmdName, args...)
	return err
}

func parsePrinters(urisOut, stateOut, acceptOut []byte) []Printer {
	byName := map[string]*Printer{}
	scanner := bufio.NewScanner(bytes.NewReader(urisOut))
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if !strings.HasPrefix(line, "device for ") {
			continue
		}
		rest := strings.TrimPrefix(line, "device for ")
		name, uri, ok := strings.Cut(rest, ": ")
		if !ok {
			continue
		}
		byName[name] = &Printer{Name: name, URI: sanitizeURI(uri), State: "idle", StateReason: "none", Accepting: true}
	}
	scanner = bufio.NewScanner(bytes.NewReader(stateOut))
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if !strings.HasPrefix(line, "printer ") {
			continue
		}
		fields := strings.Fields(line)
		if len(fields) < 3 {
			continue
		}
		name := fields[1]
		p := ensurePrinter(byName, name)
		switch fields[2] {
		case "is":
			p.State = "idle"
		case "now":
			// lpstat reports an actively printing queue as
			// "printer <name> now printing <job>."
			p.State = "printing"
		case "disabled":
			p.State = "stopped"
			p.StateReason = "paused"
		default:
			p.State = fields[2]
		}
	}
	scanner = bufio.NewScanner(bytes.NewReader(acceptOut))
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		fields := strings.Fields(line)
		if len(fields) < 2 {
			continue
		}
		p := ensurePrinter(byName, fields[0])
		p.Accepting = fields[1] == "accepting"
	}
	names := make([]string, 0, len(byName))
	for name := range byName {
		names = append(names, name)
	}
	sortStrings(names)
	printers := make([]Printer, 0, len(names))
	for _, name := range names {
		printers = append(printers, *byName[name])
	}
	return printers
}

func ensurePrinter(byName map[string]*Printer, name string) *Printer {
	if p, ok := byName[name]; ok {
		return p
	}
	p := &Printer{Name: name, State: "idle", StateReason: "none", Accepting: true}
	byName[name] = p
	return p
}

func parseJobs(out []byte) []Job {
	var jobs []Job
	scanner := bufio.NewScanner(bytes.NewReader(out))
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" {
			continue
		}
		fields := strings.Fields(line)
		if len(fields) < 3 {
			continue
		}
		printer, id := splitJobID(fields[0])
		size, _ := strconv.ParseInt(fields[2], 10, 64)
		jobs = append(jobs, Job{ID: id, Name: fields[0], State: "pending", Printer: printer, User: fields[1], Size: size, TimeCreated: strings.Join(fields[3:], " ")})
	}
	if jobs == nil {
		return []Job{}
	}
	return jobs
}

func parsePPDs(out []byte) []PPD {
	var ppds []PPD
	scanner := bufio.NewScanner(bytes.NewReader(out))
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" {
			continue
		}
		name, desc, ok := strings.Cut(line, " ")
		if !ok {
			desc = name
		}
		ppds = append(ppds, PPD{Name: name, MakeModel: strings.TrimSpace(desc)})
	}
	if ppds == nil {
		return []PPD{}
	}
	return ppds
}

func parseClasses(out []byte) []Class {
	var classes []Class
	scanner := bufio.NewScanner(bytes.NewReader(out))
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if !strings.HasPrefix(line, "members of class ") {
			continue
		}
		rest := strings.TrimPrefix(line, "members of class ")
		name, membersRaw, ok := strings.Cut(rest, ":")
		if !ok {
			continue
		}
		members := strings.Fields(strings.TrimSpace(membersRaw))
		classes = append(classes, Class{Name: name, URI: "ipp://localhost/classes/" + name, State: "idle", Members: members})
	}
	if classes == nil {
		return []Class{}
	}
	return classes
}

func validateName(field, value string) error {
	value = strings.TrimSpace(value)
	if !nameRe.MatchString(value) {
		return fmt.Errorf("invalid %s", field)
	}
	return nil
}

func validateJobID(value string) error {
	value = strings.TrimSpace(value)
	if !jobIDRe.MatchString(value) {
		return fmt.Errorf("invalid jobID")
	}
	return nil
}

func (m *Manager) validatePPDAvailable(name string) error {
	if name == "everywhere" || strings.HasPrefix(name, "driverless:") {
		return nil
	}
	out, err := m.outputAllowEmpty("lpinfo", "-m")
	if err != nil {
		return err
	}
	for _, ppd := range parsePPDs(out) {
		if ppd.Name == name {
			return nil
		}
	}
	return fmt.Errorf("ppd not available")
}

func validateProtocol(protocol string) error {
	switch strings.ToLower(strings.TrimSpace(protocol)) {
	case "", "ipp", "ipps", "socket", "jetdirect", "lpd", "http", "https":
		return nil
	default:
		return fmt.Errorf("invalid protocol")
	}
}

func validateText(field, value string, maxLen int) error {
	if len(value) > maxLen || strings.ContainsAny(value, "\r\n\t") {
		return fmt.Errorf("invalid %s", field)
	}
	return nil
}

func splitJobID(raw string) (string, string) {
	idx := strings.LastIndex(raw, "-")
	if idx <= 0 || idx == len(raw)-1 {
		return "", raw
	}
	return raw[:idx], raw[idx+1:]
}

func defaultPort(protocol string) int {
	switch strings.ToLower(protocol) {
	case "socket", "jetdirect":
		return 9100
	case "lpd":
		return 515
	default:
		return 631
	}
}

func firstExisting(paths ...string) string {
	for _, path := range paths {
		if st, err := os.Stat(path); err == nil && !st.IsDir() {
			return path
		}
	}
	matches, _ := filepath.Glob("/usr/share/cups/data/*test*")
	for _, path := range matches {
		if st, err := os.Stat(path); err == nil && !st.IsDir() {
			return path
		}
	}
	return ""
}

func sortStrings(values []string) {
	for i := 1; i < len(values); i++ {
		for j := i; j > 0 && values[j] < values[j-1]; j-- {
			values[j], values[j-1] = values[j-1], values[j]
		}
	}
}
