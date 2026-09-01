#!/usr/bin/env python3
"""Keep one-shot backend output reads on execbound."""

from __future__ import annotations

from dataclasses import dataclass
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

REPO_ROOT = Path(os.environ.get("VGS_EXECBOUND_REPO_ROOT", Path(__file__).resolve().parents[1])).resolve()

# Raw os/exec sites that intentionally start a process whose lifecycle outlives
# a single output read. Every entry needs the process reason, because an
# unreasoned raw exec site is exactly what hides a bypass.
ALLOWED_RAW_EXECS = {
    'backend/internal/services/clipboard/wayland.go::wlCopy exec.Command("wl-copy", args...)':
        "wl-copy serves the Wayland clipboard after the RPC returns; wlCopy starts it, "
        "waits only for startup failure, then reaps it in a goroutine.",
    'backend/internal/services/clipboard/wayland.go::watch exec.CommandContext(ctx, "wl-paste", "--watch", "echo")':
        "wl-paste --watch is the single clipboard watcher owned by the backend.",
    'backend/internal/services/cloudsync/rcd.go::start exec.Command(d.binary, "rcd", "--rc-addr", '
    '"127.0.0.1:"+strconv.Itoa(port), "--rc-web-gui=false", "--log-level", "NOTICE")':
        "rclone rcd is the cloudsync control daemon; cloudsync supervises it and owns its endpoint.",
    'backend/internal/services/cloudsync/remotes.go::beginOAuth exec.Command(m.binary, "authorize", '
    'providerType, "--auth-no-open-browser")':
        "rclone authorize runs the browser OAuth flow and streams the token through pipes the service reads.",
    'backend/internal/services/gamma/gamma.go::applyGammaLocked exec.Command(m.binary, "-t", '
    'strconv.Itoa(lowTemp), "-T", strconv.Itoa(highTemp), "-g", strconv.FormatFloat(state.Config.Gamma, '
    "'f', 3, 64))":
        "wlsunset is the Niri gamma adapter process; gamma starts it and watches its exit.",
    'backend/internal/services/gamma/gamma.go::applyGammaLocked exec.Command(m.binary, "--temperature", '
    'strconv.Itoa(state.CurrentTemp), "--gamma", strconv.Itoa(gammaPercent))':
        "hyprsunset is the Hyprland gamma adapter process; gamma starts it and watches its exit.",
    'backend/internal/services/networkmanager/networkmanager.go::monitor exec.CommandContext(ctx, "nmcli", "monitor")':
        "nmcli monitor is the backend-owned NetworkManager watcher.",
    'backend/internal/services/sysupdate/sysupdate.go::handleUpgrade exec.Command(argv[0], argv[1:]...)':
        "the terminal updater is an interactive upgrade process; sysupdate starts it and watches completion.",
    'backend/internal/services/tailscale/watch.go::runWatch exec.CommandContext(ctx, m.tailscale, "debug", '
    '"watch-ipn")':
        "tailscale debug watch-ipn is the backend-owned ipn bus watcher.",
    'backend/internal/runner/runner.go::runQuickshell exec.Command("qs", append(baseArgs, qsArgs...)...)':
        "the runner starts the shell process and waits for its session lifetime.",
    'backend/internal/runner/supervise.go::superviseBackend exec.Command(exe, "serve")':
        "the runner supervises the backend serve child with restart and crash-loop handling.",
}


ANALYZER = r'''
package main

import (
	"encoding/json"
	"fmt"
	"go/ast"
	"go/importer"
	"go/parser"
	"go/token"
	"go/types"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

type finding struct {
	Rel        string `json:"rel"`
	Line       int    `json:"line"`
	Function   string `json:"function"`
	Expression string `json:"expression"`
	Key        string `json:"key,omitempty"`
	Receiver   string `json:"receiver,omitempty"`
}

type report struct {
	FilesChecked int       `json:"files_checked"`
	RawCalls     []finding `json:"raw_calls"`
	OutputReads  []finding `json:"output_reads"`
	References   []finding `json:"references"`
	ParseErrors  []string  `json:"parse_errors"`
}

type functionRange struct {
	name       string
	start, end token.Pos
}

type analyzer struct {
	root, moduleDir, modulePath string
	fset                        *token.FileSet
	sources                     map[string][]byte
	std                         types.Importer
	pkgs                        map[string]*types.Package
	loading                     map[string]bool
	report                      report
}

func main() {
	if len(os.Args) != 2 {
		fmt.Fprintln(os.Stderr, "usage: execbound-analyzer REPO_ROOT")
		os.Exit(2)
	}
	root, err := filepath.Abs(os.Args[1])
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
	a := &analyzer{
		root:       root,
		moduleDir:  filepath.Join(root, "backend"),
		modulePath: modulePath(filepath.Join(root, "backend", "go.mod")),
		fset:       token.NewFileSet(),
		sources:    map[string][]byte{},
		std:        importer.Default(),
		pkgs:       map[string]*types.Package{},
		loading:    map[string]bool{},
	}
	a.walk()
	sortFindings(a.report.RawCalls)
	sortFindings(a.report.OutputReads)
	sortFindings(a.report.References)
	if err := json.NewEncoder(os.Stdout).Encode(a.report); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
}

func modulePath(path string) string {
	body, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	for _, line := range strings.Split(string(body), "\n") {
		fields := strings.Fields(line)
		if len(fields) >= 2 && fields[0] == "module" {
			return fields[1]
		}
	}
	return ""
}

func sortFindings(findings []finding) {
	sort.Slice(findings, func(i, j int) bool {
		if findings[i].Rel != findings[j].Rel {
			return findings[i].Rel < findings[j].Rel
		}
		if findings[i].Line != findings[j].Line {
			return findings[i].Line < findings[j].Line
		}
		return findings[i].Expression < findings[j].Expression
	})
}

func (a *analyzer) walk() {
	root := filepath.Join(a.root, "backend", "internal")
	if _, err := os.Stat(root); err != nil {
		if !os.IsNotExist(err) {
			a.report.ParseErrors = append(a.report.ParseErrors, fmt.Sprintf("%s: %v", a.rel(root), err))
		}
		return
	}
	groups := map[string][]*ast.File{}
	err := filepath.WalkDir(root, func(path string, entry fs.DirEntry, err error) error {
		if err != nil {
			a.report.ParseErrors = append(a.report.ParseErrors, fmt.Sprintf("%s: %v", a.rel(path), err))
			return nil
		}
		if entry.IsDir() && a.skips(path) {
			return filepath.SkipDir
		}
		if entry.IsDir() || filepath.Ext(path) != ".go" {
			return nil
		}
		file := a.parse(path)
		if file == nil {
			return nil
		}
		key := filepath.Dir(path) + "\x00" + file.Name.Name
		groups[key] = append(groups[key], file)
		a.report.FilesChecked++
		return nil
	})
	if err != nil {
		a.report.ParseErrors = append(a.report.ParseErrors, err.Error())
	}
	keys := make([]string, 0, len(groups))
	for key := range groups {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	for _, key := range keys {
		a.checkPackage(strings.Split(key, "\x00")[0], groups[key])
	}
}

func (a *analyzer) parse(path string) *ast.File {
	source, err := os.ReadFile(path)
	if err != nil {
		a.report.ParseErrors = append(a.report.ParseErrors, fmt.Sprintf("%s: %v", a.rel(path), err))
		return nil
	}
	file, err := parser.ParseFile(a.fset, path, source, parser.AllErrors)
	if err != nil {
		a.report.ParseErrors = append(a.report.ParseErrors, err.Error())
		return nil
	}
	a.sources[path] = source
	return file
}

func (a *analyzer) checkPackage(dir string, files []*ast.File) {
	info := &types.Info{
		Types:      map[ast.Expr]types.TypeAndValue{},
		Uses:       map[*ast.Ident]types.Object{},
		Selections: map[*ast.SelectorExpr]*types.Selection{},
	}
	_, _ = (&types.Config{Importer: a, Error: func(error) {}}).Check(a.importPath(dir), a.fset, files, info)
	for _, file := range files {
		a.scanFile(file, info)
	}
}

func (a *analyzer) Import(path string) (*types.Package, error) {
	if pkg, ok := a.pkgs[path]; ok {
		return pkg, nil
	}
	if a.modulePath != "" && (path == a.modulePath || strings.HasPrefix(path, a.modulePath+"/")) {
		dir := filepath.Join(a.moduleDir, filepath.FromSlash(strings.TrimPrefix(strings.TrimPrefix(path, a.modulePath), "/")))
		return a.importLocal(path, dir)
	}
	if pkg, err := a.std.Import(path); err == nil {
		return pkg, nil
	}
	return types.NewPackage(path, filepath.Base(path)), nil
}

func (a *analyzer) importLocal(path string, dir string) (*types.Package, error) {
	if a.loading[path] {
		return types.NewPackage(path, filepath.Base(path)), nil
	}
	a.loading[path] = true
	defer delete(a.loading, path)
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil, err
	}
	var files []*ast.File
	for _, entry := range entries {
		name := entry.Name()
		if entry.IsDir() || filepath.Ext(name) != ".go" || strings.HasSuffix(name, "_test.go") {
			continue
		}
		if file := a.parse(filepath.Join(dir, name)); file != nil {
			files = append(files, file)
		}
	}
	pkg, _ := (&types.Config{Importer: a, Error: func(error) {}}).Check(path, a.fset, files, nil)
	if pkg == nil {
		pkg = types.NewPackage(path, filepath.Base(path))
	}
	a.pkgs[path] = pkg
	return pkg, nil
}

func (a *analyzer) scanFile(file *ast.File, info *types.Info) {
	parents := parentMap(file)
	functions := functionRanges(file)
	ast.Inspect(file, func(node ast.Node) bool {
		switch n := node.(type) {
		case *ast.CallExpr:
			if sel, ok := n.Fun.(*ast.SelectorExpr); ok && isReader(sel.Sel.Name) {
				a.recordOutputRead(n, sel, functions, info)
			}
			if isExecBuilder(objectOf(n.Fun, info)) {
				a.report.RawCalls = append(a.report.RawCalls, a.finding(n, functions, a.source(n), "", ""))
			}
		case *ast.Ident:
			if isExecBuilder(info.Uses[n]) && !calledDirectly(n, parents) {
				ref := referenceNode(n, parents)
				a.report.References = append(a.report.References, a.finding(ref, functions, a.source(ref), "", ""))
			}
		}
		return true
	})
}

func (a *analyzer) recordOutputRead(call *ast.CallExpr, sel *ast.SelectorExpr, functions []functionRange, info *types.Info) {
	receiverType := info.Types[sel.X].Type
	if selection := info.Selections[sel]; selection != nil && isExecCmd(selection.Recv()) {
		receiverType = selection.Recv()
	}
	if isExecCmd(receiverType) {
		a.report.OutputReads = append(a.report.OutputReads, a.finding(call, functions, a.source(call), "", "*os/exec.Cmd"))
		return
	}
	if receiverType == nil && !a.isExecboundChain(sel.X, info) {
		a.report.OutputReads = append(a.report.OutputReads, a.finding(call, functions, a.source(call), "", "unknown receiver"))
	}
}

func (a *analyzer) finding(node ast.Node, functions []functionRange, expr string, key string, receiver string) finding {
	pos := a.fset.Position(node.Pos())
	if key == "" {
		key = fmt.Sprintf("%s::%s %s", a.rel(pos.Filename), functionAt(functions, node.Pos()), expr)
	}
	return finding{
		Rel:        a.rel(pos.Filename),
		Line:       pos.Line,
		Function:   functionAt(functions, node.Pos()),
		Expression: expr,
		Key:        key,
		Receiver:   receiver,
	}
}

func (a *analyzer) isExecboundChain(expr ast.Expr, info *types.Info) bool {
	for {
		call, ok := expr.(*ast.CallExpr)
		if !ok {
			return false
		}
		if isExecboundCommand(objectOf(call.Fun, info), a.modulePath) {
			return true
		}
		sel, ok := call.Fun.(*ast.SelectorExpr)
		if !ok || sel.Sel.Name != "WithLogger" {
			return false
		}
		expr = sel.X
	}
}

func (a *analyzer) source(node ast.Node) string {
	file := a.fset.File(node.Pos())
	if file == nil {
		return ""
	}
	source := a.sources[file.Name()]
	start := file.Offset(node.Pos())
	end := file.Offset(node.End())
	if start < 0 || end > len(source) || start >= end {
		return ""
	}
	expr := strings.Join(strings.Fields(string(source[start:end])), " ")
	return strings.ReplaceAll(expr, ", )", ")")
}

func (a *analyzer) rel(path string) string {
	rel, err := filepath.Rel(a.root, path)
	if err != nil {
		return filepath.ToSlash(path)
	}
	return filepath.ToSlash(rel)
}

func (a *analyzer) skips(path string) bool {
	rel := a.rel(path)
	return rel == "backend/internal/execbound" || strings.HasPrefix(rel, "backend/internal/execbound/") ||
		rel == "backend/vendor" || strings.HasPrefix(rel, "backend/vendor/")
}

func (a *analyzer) importPath(dir string) string {
	if a.modulePath == "" {
		return ""
	}
	rel, err := filepath.Rel(a.moduleDir, dir)
	if err != nil || rel == "." {
		return a.modulePath
	}
	return a.modulePath + "/" + filepath.ToSlash(rel)
}

func objectOf(expr ast.Expr, info *types.Info) types.Object {
	switch n := expr.(type) {
	case *ast.Ident:
		return info.Uses[n]
	case *ast.SelectorExpr:
		return info.Uses[n.Sel]
	default:
		return nil
	}
}

func isExecBuilder(obj types.Object) bool {
	return objectFromPackage(obj, "os/exec", "Command") || objectFromPackage(obj, "os/exec", "CommandContext")
}

func isExecboundCommand(obj types.Object, modulePath string) bool {
	pkg := modulePath + "/internal/execbound"
	return objectFromPackage(obj, pkg, "Command") || objectFromPackage(obj, pkg, "CommandWithDelay")
}

func objectFromPackage(obj types.Object, pkg string, name string) bool {
	return obj != nil && obj.Name() == name && obj.Pkg() != nil && obj.Pkg().Path() == pkg
}

func isExecCmd(t types.Type) bool {
	if t == nil {
		return false
	}
	t = types.Unalias(t)
	if pointer, ok := t.(*types.Pointer); ok {
		t = types.Unalias(pointer.Elem())
	}
	named, ok := t.(*types.Named)
	if !ok || named.Obj() == nil || named.Obj().Pkg() == nil {
		return false
	}
	return named.Obj().Name() == "Cmd" && named.Obj().Pkg().Path() == "os/exec"
}

func isReader(name string) bool {
	return name == "Output" || name == "CombinedOutput"
}

func parentMap(root ast.Node) map[ast.Node]ast.Node {
	parents := map[ast.Node]ast.Node{}
	var stack []ast.Node
	ast.Inspect(root, func(node ast.Node) bool {
		if node == nil {
			stack = stack[:len(stack)-1]
			return false
		}
		if len(stack) > 0 {
			parents[node] = stack[len(stack)-1]
		}
		stack = append(stack, node)
		return true
	})
	return parents
}

func calledDirectly(id *ast.Ident, parents map[ast.Node]ast.Node) bool {
	parent := parents[id]
	if sel, ok := parent.(*ast.SelectorExpr); ok && sel.Sel == id {
		if call, ok := parents[sel].(*ast.CallExpr); ok {
			return call.Fun == sel
		}
	}
	if call, ok := parent.(*ast.CallExpr); ok {
		return call.Fun == id
	}
	return false
}

func referenceNode(id *ast.Ident, parents map[ast.Node]ast.Node) ast.Node {
	if sel, ok := parents[id].(*ast.SelectorExpr); ok && sel.Sel == id {
		return sel
	}
	return id
}

func functionRanges(file *ast.File) []functionRange {
	var ranges []functionRange
	for _, decl := range file.Decls {
		if fn, ok := decl.(*ast.FuncDecl); ok {
			ranges = append(ranges, functionRange{name: fn.Name.Name, start: fn.Pos(), end: fn.End()})
		}
	}
	return ranges
}

func functionAt(functions []functionRange, pos token.Pos) string {
	for _, fn := range functions {
		if fn.start <= pos && pos <= fn.end {
			return fn.name
		}
	}
	return "<top-level>"
}
'''


@dataclass(frozen=True)
class Finding:
    rel: str
    line: int
    function: str
    expression: str
    key: str = ""
    receiver: str = ""


def run_analyzer() -> dict[str, object] | None:
    go = shutil.which("go")
    if go is None:
        print("check-execbound-adoption: FAIL: go is required for Go type checking", file=sys.stderr)
        return None
    with tempfile.TemporaryDirectory(prefix="vgs-execbound-analyzer-") as tmp:
        analyzer = Path(tmp) / "main.go"
        analyzer.write_text(ANALYZER, encoding="utf-8")
        result = subprocess.run([go, "run", str(analyzer), str(REPO_ROOT)], text=True, capture_output=True, check=False)
    if result.returncode != 0:
        print("check-execbound-adoption: FAIL: Go analyzer failed:", file=sys.stderr)
        print(result.stdout + result.stderr, file=sys.stderr)
        return None
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError as exc:
        print(f"check-execbound-adoption: FAIL: Go analyzer returned invalid JSON: {exc}", file=sys.stderr)
        print(result.stdout + result.stderr, file=sys.stderr)
        return None


def findings(report: dict[str, object], key: str) -> list[Finding]:
    rows = report.get(key)
    if not isinstance(rows, list):
        return []
    return [Finding(**row) for row in rows]


def print_parse_errors(errors: object) -> bool:
    if not isinstance(errors, list) or not errors:
        return False
    print("check-execbound-adoption: FAIL: could not parse backend Go file(s):", file=sys.stderr)
    for entry in errors:
        print(f"  {entry}", file=sys.stderr)
    return True


def main() -> int:
    report = run_analyzer()
    if report is None:
        return 1
    if print_parse_errors(report.get("parse_errors")):
        return 1
    if not report.get("files_checked"):
        print(
            "check-execbound-adoption: FAIL: found no Go files under backend/internal, "
            "so no backend exec sites were checked",
            file=sys.stderr,
        )
        return 1

    output_reads = findings(report, "output_reads")
    references = findings(report, "references")
    raw_calls = findings(report, "raw_calls")
    unallowed_raw = [call for call in raw_calls if call.key not in ALLOWED_RAW_EXECS]

    if references:
        print(
            "check-execbound-adoption: FAIL: os/exec command builders must be called directly "
            "so the guard can see the process lifecycle:",
            file=sys.stderr,
        )
        for reference in references:
            print(
                f"  {reference.rel}:{reference.line}: {reference.function}: "
                f"{reference.expression} referenced without a call",
                file=sys.stderr,
            )
    if output_reads:
        print(
            "check-execbound-adoption: FAIL: one-shot os/exec output reads must use "
            "backend/internal/execbound:",
            file=sys.stderr,
        )
        for read in output_reads:
            suffix = f" (receiver {read.receiver})" if read.receiver else ""
            print(f"  {read.rel}:{read.line}: {read.function}: {read.expression}{suffix}", file=sys.stderr)
    if unallowed_raw:
        print(
            "check-execbound-adoption: FAIL: raw os/exec builders outside execbound need "
            "a lifecycle reason:",
            file=sys.stderr,
        )
        for call in unallowed_raw:
            print(f"  {call.rel}:{call.line}: {call.function}: {call.expression}", file=sys.stderr)
            print(f"      allowlist key: {call.key}", file=sys.stderr)

    if references or output_reads or unallowed_raw:
        print(
            "\nUse execbound.Command for one-shot Output or CombinedOutput reads. Call "
            "raw os/exec builders directly only at long-lived process sites, and add an "
            "ALLOWED_RAW_EXECS entry when that lifecycle is owned outside execbound.",
            file=sys.stderr,
        )
        return 1

    print(f"check-execbound-adoption: ok ({len(raw_calls)} raw os/exec builders checked)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
