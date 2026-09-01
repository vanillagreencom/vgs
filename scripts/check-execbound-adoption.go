package main

import (
	"encoding/json"
	"fmt"
	"go/ast"
	"go/parser"
	"go/scanner"
	"go/token"
	"go/types"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strconv"
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
	TypeErrors   []string  `json:"type_errors"`
}

type functionRange struct {
	name       string
	start, end token.Pos
}

type imports struct {
	osExec       map[string]bool
	execbound    map[string]bool
	dotOSExec    bool
	dotExecbound bool
}

type analyzer struct {
	root, modulePath string
	fset             *token.FileSet
	sources          map[string][]byte
	importer         *moduleImporter
	paramOrigins     map[string]map[int]bool
	resultOrigins    map[string]bool
	report           report
}

type fileScanner struct {
	analyzer  *analyzer
	imports   imports
	info      *types.Info
	parents   map[ast.Node]ast.Node
	origins   map[*ast.Object]bool
	functions []functionRange
}

func main() {
	if len(os.Args) != 2 {
		fmt.Fprintln(os.Stderr, "usage: check-execbound-adoption REPO_ROOT")
		os.Exit(2)
	}
	root, err := filepath.Abs(os.Args[1])
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
	a := &analyzer{
		root:       root,
		modulePath: modulePath(filepath.Join(root, "backend", "go.mod")),
		fset:       token.NewFileSet(),
		sources:    map[string][]byte{},
	}
	a.walk()
	sortFindings(a.report.RawCalls)
	sortFindings(a.report.OutputReads)
	sortFindings(a.report.References)
	sort.Strings(a.report.ParseErrors)
	sort.Strings(a.report.TypeErrors)
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
	err := filepath.WalkDir(root, func(path string, entry fs.DirEntry, err error) error {
		if err != nil {
			a.report.ParseErrors = append(a.report.ParseErrors, fmt.Sprintf("%s: %v", a.rel(path), err))
			return nil
		}
		if entry.IsDir() && a.skips(path) {
			return filepath.SkipDir
		}
		if entry.IsDir() {
			a.scanDir(path)
		}
		return nil
	})
	if err != nil {
		a.report.ParseErrors = append(a.report.ParseErrors, err.Error())
	}
}

func (a *analyzer) scanDir(dir string) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		a.report.ParseErrors = append(a.report.ParseErrors, fmt.Sprintf("%s: %v", a.rel(dir), err))
		return
	}
	files := []*ast.File{}
	for _, entry := range entries {
		if entry.IsDir() || filepath.Ext(entry.Name()) != ".go" {
			continue
		}
		if file := a.parse(filepath.Join(dir, entry.Name())); file != nil {
			a.report.FilesChecked++
			files = append(files, file)
		}
	}
	if len(files) == 0 {
		return
	}
	info := a.typeInfo(dir, files)
	a.markPackageProvenance(files, info)
	for _, file := range files {
		a.scanFile(file, info)
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
		a.recordParseError(err)
		return nil
	}
	a.sources[path] = source
	return file
}

func (a *analyzer) recordParseError(err error) {
	if errors, ok := err.(scanner.ErrorList); ok {
		for _, entry := range errors {
			a.report.ParseErrors = append(
				a.report.ParseErrors,
				fmt.Sprintf("%s:%d:%d: %s", a.rel(entry.Pos.Filename), entry.Pos.Line, entry.Pos.Column, entry.Msg),
			)
		}
		return
	}
	a.report.ParseErrors = append(a.report.ParseErrors, err.Error())
}

func (a *analyzer) scanFile(file *ast.File, info *types.Info) {
	scanner := fileScanner{
		analyzer:  a,
		imports:   importAliases(file, a.modulePath),
		info:      info,
		parents:   parentMap(file),
		origins:   map[*ast.Object]bool{},
		functions: functionRanges(file),
	}
	scanner.recordOrigins(file)
	ast.Inspect(file, func(node ast.Node) bool {
		switch n := node.(type) {
		case *ast.CallExpr:
			if scanner.isOSExecBuilder(n.Fun) {
				a.report.RawCalls = append(a.report.RawCalls, scanner.finding(n, ""))
			}
		case *ast.SelectorExpr:
			if scanner.isOutputRead(n) {
				a.report.OutputReads = append(a.report.OutputReads, scanner.finding(scanner.outputReadNode(n), "unverified selector"))
			}
			if scanner.isOSExecBuilderSelector(n) && !scanner.selectorCalledDirectly(n) {
				a.report.References = append(a.report.References, scanner.finding(n, ""))
			}
		case *ast.Ident:
			if scanner.identIsSelectorPart(n) {
				return true
			}
			if scanner.isDotOSExecBuilderIdent(n) && !scanner.identCalledDirectly(n) {
				a.report.References = append(a.report.References, scanner.finding(n, ""))
			}
		}
		return true
	})
}

func importAliases(file *ast.File, modulePath string) imports {
	aliases := imports{
		osExec:    map[string]bool{},
		execbound: map[string]bool{},
	}
	execboundPath := modulePath + "/internal/execbound"
	for _, spec := range file.Imports {
		path, err := strconv.Unquote(spec.Path.Value)
		if err != nil {
			continue
		}
		name := filepath.Base(path)
		if spec.Name != nil {
			name = spec.Name.Name
		}
		switch {
		case path == "os/exec" && name == ".":
			aliases.dotOSExec = true
		case path == "os/exec" && name != "_":
			aliases.osExec[name] = true
		case path == execboundPath && name == ".":
			aliases.dotExecbound = true
		case path == execboundPath && name != "_":
			aliases.execbound[name] = true
		}
	}
	return aliases
}

func (s fileScanner) isOSExecBuilder(expr ast.Expr) bool {
	switch n := unparen(expr).(type) {
	case *ast.SelectorExpr:
		return s.isOSExecBuilderSelector(n)
	case *ast.Ident:
		return s.isDotOSExecBuilderIdent(n)
	default:
		return false
	}
}

func (s fileScanner) isOSExecBuilderSelector(sel *ast.SelectorExpr) bool {
	id, ok := unparen(sel.X).(*ast.Ident)
	return ok && id.Obj == nil && s.imports.osExec[id.Name] && isOSExecBuilderName(sel.Sel.Name)
}

func (s fileScanner) isDotOSExecBuilderIdent(id *ast.Ident) bool {
	return id.Obj == nil && s.imports.dotOSExec && isOSExecBuilderName(id.Name)
}

func isOSExecBuilderName(name string) bool {
	return name == "Command" || name == "CommandContext"
}

func (s fileScanner) finding(node ast.Node, receiver string) finding {
	a := s.analyzer
	pos := a.fset.Position(node.Pos())
	expr := a.source(node)
	key := fmt.Sprintf("%s::%s %s", a.rel(pos.Filename), functionAt(s.functions, node.Pos()), expr)
	return finding{
		Rel:        a.rel(pos.Filename),
		Line:       pos.Line,
		Function:   functionAt(s.functions, node.Pos()),
		Expression: expr,
		Key:        key,
		Receiver:   receiver,
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
