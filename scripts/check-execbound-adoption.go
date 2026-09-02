package main

import (
	"encoding/json"
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"io/fs"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

type finding struct {
	Rel        string `json:"rel"`
	Line       int    `json:"line"`
	Function   string `json:"function"`
	Expression string `json:"expression"`
	Key        string `json:"key,omitempty"`
}

type report struct {
	FilesChecked int       `json:"files_checked"`
	RawCalls     []finding `json:"raw_calls"`
	OutputReads  []finding `json:"output_reads"`
	ParseErrors  []string  `json:"parse_errors"`
}

type functionRange struct {
	name       string
	start, end token.Pos
	body       *ast.BlockStmt
}

type imports map[string]bool

type analyzer struct {
	root    string
	fset    *token.FileSet
	sources map[string][]byte
	report  report
}

type fileScanner struct {
	analyzer  *analyzer
	imports   imports
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
	a := &analyzer{root: root, fset: token.NewFileSet(), sources: map[string][]byte{}}
	a.walk()
	if err := json.NewEncoder(os.Stdout).Encode(a.report); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
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
		if entry.IsDir() {
			if a.skips(path) {
				return filepath.SkipDir
			}
			return nil
		}
		if filepath.Ext(path) == ".go" {
			if file := a.parse(path); file != nil {
				a.report.FilesChecked++
				a.scanFile(file)
			}
		}
		return nil
	})
	if err != nil {
		a.report.ParseErrors = append(a.report.ParseErrors, err.Error())
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

func (a *analyzer) scanFile(file *ast.File) {
	s := fileScanner{analyzer: a, imports: importAliases(file), functions: functionRanges(file)}
	ast.Inspect(file, func(node ast.Node) bool {
		call, ok := node.(*ast.CallExpr)
		if !ok {
			return true
		}
		if s.isRawBuilder(unparen(call.Fun)) {
			a.report.RawCalls = append(a.report.RawCalls, s.finding(call))
		}
		if s.isOutputRead(call) {
			a.report.OutputReads = append(a.report.OutputReads, s.finding(call))
		}
		return true
	})
}

func importAliases(file *ast.File) imports {
	aliases := imports{}
	for _, spec := range file.Imports {
		path, err := strconv.Unquote(spec.Path.Value)
		if err != nil || path != "os/exec" {
			continue
		}
		name := "exec"
		if spec.Name != nil {
			name = spec.Name.Name
		}
		if name != "_" && name != "." {
			aliases[name] = true
		}
	}
	return aliases
}

func (s fileScanner) isOutputRead(call *ast.CallExpr) bool {
	sel, ok := unparen(call.Fun).(*ast.SelectorExpr)
	if !ok || !isOutputReadName(sel.Sel.Name) {
		return false
	}
	switch recv := unparen(sel.X).(type) {
	case *ast.CallExpr:
		return s.isRawBuilder(unparen(recv.Fun))
	case *ast.Ident:
		return s.identHasRawBuilder(recv, call.Pos())
	}
	return false
}

func (s fileScanner) identHasRawBuilder(id *ast.Ident, end token.Pos) bool {
	fn := s.functionAt(end)
	if fn.body == nil {
		return false
	}
	found := false
	ast.Inspect(fn.body, func(node ast.Node) bool {
		stmt, ok := node.(*ast.AssignStmt)
		if !ok {
			return true
		}
		for i, lhs := range stmt.Lhs {
			lhsID, ok := unparen(lhs).(*ast.Ident)
			if !ok || !sameIdent(lhsID, id) || lhsID.Pos() >= end || i >= len(stmt.Rhs) {
				continue
			}
			call, ok := unparen(stmt.Rhs[i]).(*ast.CallExpr)
			found = ok && s.isRawBuilder(unparen(call.Fun))
		}
		return true
	})
	return found
}

func (s fileScanner) isRawBuilder(expr ast.Expr) bool {
	sel, ok := expr.(*ast.SelectorExpr)
	if !ok || !isBuilderName(sel.Sel.Name) {
		return false
	}
	id, ok := unparen(sel.X).(*ast.Ident)
	return ok && id.Obj == nil && s.imports[id.Name]
}

func (s fileScanner) finding(node ast.Node) finding {
	pos := s.analyzer.fset.Position(node.Pos())
	expr := s.analyzer.source(node)
	fn := s.functionAt(node.Pos()).name
	return finding{Rel: s.analyzer.rel(pos.Filename), Line: pos.Line, Function: fn, Expression: expr, Key: s.analyzer.rel(pos.Filename) + "::" + fn + " " + expr}
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
	return strings.ReplaceAll(strings.Join(strings.Fields(string(source[start:end])), " "), ", )", ")")
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
	return rel == "backend/internal/execbound" || strings.HasPrefix(rel, "backend/internal/execbound/")
}

func functionRanges(file *ast.File) []functionRange {
	var ranges []functionRange
	for _, decl := range file.Decls {
		if fn, ok := decl.(*ast.FuncDecl); ok {
			ranges = append(ranges, functionRange{name: fn.Name.Name, start: fn.Pos(), end: fn.End(), body: fn.Body})
		}
	}
	return ranges
}

func (s fileScanner) functionAt(pos token.Pos) functionRange {
	for _, fn := range s.functions {
		if fn.start <= pos && pos <= fn.end {
			return fn
		}
	}
	return functionRange{name: "<top-level>"}
}

func sameIdent(a, b *ast.Ident) bool {
	if a.Obj != nil || b.Obj != nil {
		return a.Obj != nil && a.Obj == b.Obj
	}
	return a.Name == b.Name
}

func unparen(expr ast.Expr) ast.Expr {
	for {
		paren, ok := expr.(*ast.ParenExpr)
		if !ok {
			return expr
		}
		expr = paren.X
	}
}

func isBuilderName(name string) bool { return name == "Command" || name == "CommandContext" }

func isOutputReadName(name string) bool { return name == "Output" || name == "CombinedOutput" }
