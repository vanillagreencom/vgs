package main

import (
	"encoding/json"
	"fmt"
	"go/ast"
	"go/importer"
	"go/types"
	"io"
	"os"
	osexec "os/exec"
	"path/filepath"
	"strings"
)

type moduleImporter struct {
	analyzer *analyzer
	exporter types.Importer
	exports  map[string]string
	packages map[string]*types.Package
}

func (m *moduleImporter) Import(path string) (*types.Package, error) {
	if pkg := m.packages[path]; pkg != nil {
		return pkg, nil
	}
	if m.analyzer.modulePath != "" &&
		(path == m.analyzer.modulePath || strings.HasPrefix(path, m.analyzer.modulePath+"/")) {
		return m.importSource(path)
	}
	pkg, err := m.exportImporter().Import(path)
	if err == nil {
		m.packages[path] = pkg
	}
	return pkg, err
}

func (m *moduleImporter) exportImporter() types.Importer {
	if m.exporter == nil {
		m.exporter = importer.ForCompiler(m.analyzer.fset, "gc", m.lookupExport)
	}
	return m.exporter
}

func (m *moduleImporter) lookupExport(path string) (io.ReadCloser, error) {
	if export := m.exports[path]; export != "" {
		return os.Open(export)
	}
	export, err := m.goListExport(path)
	if err != nil {
		return nil, err
	}
	m.exports[path] = export
	return os.Open(export)
}

type listedPackage struct {
	Export string
	Error  *struct{ Err string }
}

func (m *moduleImporter) goListExport(path string) (string, error) {
	cmd := osexec.Command("go", "list", "-export", "-json", path)
	cmd.Dir = filepath.Join(m.analyzer.root, "backend")
	output, err := cmd.CombinedOutput()
	if err != nil {
		return "", fmt.Errorf("go list -export %s: %v: %s", path, err, strings.TrimSpace(string(output)))
	}
	var pkg listedPackage
	if err := json.Unmarshal(output, &pkg); err != nil {
		return "", err
	}
	if pkg.Error != nil {
		return "", fmt.Errorf("%s", pkg.Error.Err)
	}
	if pkg.Export == "" {
		return "", fmt.Errorf("go list -export %s returned no export data", path)
	}
	return pkg.Export, nil
}

func (m *moduleImporter) importSource(path string) (*types.Package, error) {
	dir := filepath.Join(
		m.analyzer.root,
		"backend",
		filepath.FromSlash(strings.TrimPrefix(strings.TrimPrefix(path, m.analyzer.modulePath), "/")),
	)
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil, err
	}
	files := []*ast.File{}
	m.packages[path] = types.NewPackage(path, filepath.Base(path))
	for _, entry := range entries {
		if entry.IsDir() || filepath.Ext(entry.Name()) != ".go" || strings.HasSuffix(entry.Name(), "_test.go") {
			continue
		}
		file := m.analyzer.parse(filepath.Join(dir, entry.Name()))
		if file != nil {
			files = append(files, file)
		}
	}
	if len(files) == 0 {
		return nil, fmt.Errorf("no source files for %s", path)
	}
	conf := types.Config{Importer: m, Error: m.analyzer.recordTypeError}
	pkg, err := conf.Check(path, m.analyzer.fset, files, nil)
	if pkg != nil {
		m.packages[path] = pkg
	}
	return pkg, err
}

func (a *analyzer) typeInfo(dir string, files []*ast.File) *types.Info {
	info := &types.Info{
		Types:      map[ast.Expr]types.TypeAndValue{},
		Defs:       map[*ast.Ident]types.Object{},
		Uses:       map[*ast.Ident]types.Object{},
		Selections: map[*ast.SelectorExpr]*types.Selection{},
	}
	imp := a.moduleImporter()
	conf := types.Config{Importer: imp, Error: a.recordTypeError}
	importPath := a.importPath(dir)
	pkg, _ := conf.Check(importPath, a.fset, files, info)
	if pkg != nil {
		imp.packages[importPath] = pkg
	}
	return info
}

func (a *analyzer) moduleImporter() *moduleImporter {
	if a.importer == nil {
		a.importer = &moduleImporter{analyzer: a, exports: map[string]string{}, packages: map[string]*types.Package{}}
	}
	return a.importer
}

func (a *analyzer) recordTypeError(err error) {
	if typeErr, ok := err.(types.Error); ok {
		pos := a.fset.Position(typeErr.Pos)
		a.report.TypeErrors = append(
			a.report.TypeErrors,
			fmt.Sprintf("%s:%d:%d: %s", a.rel(pos.Filename), pos.Line, pos.Column, typeErr.Msg),
		)
		return
	}
	a.report.TypeErrors = append(a.report.TypeErrors, err.Error())
}

func (a *analyzer) importPath(dir string) string {
	if a.modulePath == "" {
		return a.rel(dir)
	}
	rel, err := filepath.Rel(filepath.Join(a.root, "backend"), dir)
	if err != nil || rel == "." {
		return a.modulePath
	}
	return a.modulePath + "/" + filepath.ToSlash(rel)
}

func (s fileScanner) isOutputRead(sel *ast.SelectorExpr) bool {
	if !isOutputReadName(sel.Sel.Name) {
		return false
	}
	if s.isExecboundRun(sel.X) {
		return false
	}
	return s.selectorFromExecCmd(sel) || s.exprCanOriginateFromCmd(sel.X)
}

func (s fileScanner) selectorFromExecCmd(sel *ast.SelectorExpr) bool {
	if selection := s.info.Selections[sel]; selection != nil {
		fn, ok := selection.Obj().(*types.Func)
		if ok && s.funcReceiverIsGuardedCmd(fn) {
			return true
		}
	}
	return s.typeIsGuardedCmd(s.info.TypeOf(sel.X))
}

func (s fileScanner) funcReceiverIsGuardedCmd(fn *types.Func) bool {
	sig, ok := fn.Type().(*types.Signature)
	return ok && sig.Recv() != nil && s.typeIsGuardedCmd(sig.Recv().Type())
}

func (s fileScanner) typeIsGuardedCmd(typ types.Type) bool {
	return typeIsNamedPtr(typ, "os/exec", "Cmd") ||
		typeIsNamedPtr(typ, s.analyzer.modulePath+"/internal/execbound", "Cmd")
}

func typeIsNamedPtr(typ types.Type, pkgPath string, name string) bool {
	ptr, ok := typ.(*types.Pointer)
	if !ok {
		return false
	}
	named, ok := ptr.Elem().(*types.Named)
	return ok && named.Obj().Pkg() != nil && named.Obj().Pkg().Path() == pkgPath && named.Obj().Name() == name
}

func (s fileScanner) recordOrigins(file *ast.File) {
	s.recordParamOrigins(file)
	ast.Inspect(file, func(node ast.Node) bool {
		switch n := node.(type) {
		case *ast.AssignStmt:
			for i, rhs := range n.Rhs {
				if i < len(n.Lhs) {
					s.recordOrigin(n.Lhs[i], rhs)
				}
			}
		case *ast.ValueSpec:
			for i, rhs := range n.Values {
				if i < len(n.Names) {
					s.recordOrigin(n.Names[i], rhs)
				}
			}
		case *ast.RangeStmt:
			if s.exprCanOriginateFromCmd(n.X) {
				s.recordKnownOrigin(n.Key)
				s.recordKnownOrigin(n.Value)
			}
		}
		return true
	})
}

func (s fileScanner) recordOrigin(lhs ast.Expr, rhs ast.Expr) {
	if id := originIdent(lhs); id != nil && id.Obj != nil && s.exprCanOriginateFromCmd(rhs) {
		s.origins[id.Obj] = true
	}
}

func (s fileScanner) recordKnownOrigin(expr ast.Expr) {
	if id := originIdent(expr); id != nil && id.Obj != nil {
		s.origins[id.Obj] = true
	}
}

func (s fileScanner) exprCanOriginateFromCmd(expr ast.Expr) bool {
	if s.typeIsGuardedCmd(s.info.TypeOf(expr)) || s.isOSExecBuilderCall(expr) || s.isExecboundProduced(expr) {
		return true
	}
	if call, ok := unparen(expr).(*ast.CallExpr); ok && s.analyzer.resultOrigins[funcKey(s.calledFunc(call))] {
		return true
	}
	if s.aggregateCanOriginateFromCmd(expr) {
		return true
	}
	id, ok := unparen(expr).(*ast.Ident)
	return ok && id.Obj != nil && s.origins[id.Obj]
}

func (s fileScanner) isExecboundBuilderCall(call *ast.CallExpr) bool {
	return s.isExecboundCommand(call.Fun) || s.isExecboundDelayCommand(call.Fun)
}

func (s fileScanner) execboundBuilderConsumed(call *ast.CallExpr) bool {
	sel, ok := s.parentAfterParens(call).(*ast.SelectorExpr)
	if !ok {
		return false
	}
	if isOutputReadName(sel.Sel.Name) {
		return s.selectorCalledDirectly(sel)
	}
	if sel.Sel.Name != "WithLogger" {
		return false
	}
	withLogger, ok := s.parentAfterParens(sel).(*ast.CallExpr)
	if !ok || withLogger.Fun != sel {
		return false
	}
	output, ok := s.parentAfterParens(withLogger).(*ast.SelectorExpr)
	return ok && isOutputReadName(output.Sel.Name) && s.selectorCalledDirectly(output)
}

func (s fileScanner) isOSExecBuilderCall(expr ast.Expr) bool {
	call, ok := unparen(expr).(*ast.CallExpr)
	return ok && s.isOSExecBuilder(call.Fun)
}

func (s fileScanner) isExecboundProduced(expr ast.Expr) bool {
	call, ok := unparen(expr).(*ast.CallExpr)
	if !ok {
		return false
	}
	if s.isExecboundCommand(call.Fun) || s.isExecboundDelayCommand(call.Fun) {
		return true
	}
	sel, ok := unparen(call.Fun).(*ast.SelectorExpr)
	return ok && sel.Sel.Name == "WithLogger" && s.isExecboundProduced(sel.X)
}

func (s fileScanner) isExecboundRun(expr ast.Expr) bool {
	call, ok := unparen(expr).(*ast.CallExpr)
	if !ok {
		return false
	}
	if s.isExecboundCommand(call.Fun) {
		return true
	}
	sel, ok := unparen(call.Fun).(*ast.SelectorExpr)
	return ok && sel.Sel.Name == "WithLogger" && s.isExecboundRun(sel.X)
}

func (s fileScanner) isExecboundCommand(expr ast.Expr) bool {
	switch n := unparen(expr).(type) {
	case *ast.SelectorExpr:
		id, ok := unparen(n.X).(*ast.Ident)
		return ok && id.Obj == nil && s.imports.execbound[id.Name] && isExecboundBuilderName(n.Sel.Name)
	case *ast.Ident:
		return n.Obj == nil && s.imports.dotExecbound && isExecboundBuilderName(n.Name)
	default:
		return false
	}
}

func (s fileScanner) isExecboundDelayCommand(expr ast.Expr) bool {
	switch n := unparen(expr).(type) {
	case *ast.SelectorExpr:
		id, ok := unparen(n.X).(*ast.Ident)
		return ok && id.Obj == nil && s.imports.execbound[id.Name] && n.Sel.Name == "CommandWithDelay"
	case *ast.Ident:
		return n.Obj == nil && s.imports.dotExecbound && n.Name == "CommandWithDelay"
	default:
		return false
	}
}

func isExecboundBuilderName(name string) bool { return name == "Command" }

func isOutputReadName(name string) bool { return name == "Output" || name == "CombinedOutput" }

func (s fileScanner) selectorCalledDirectly(sel *ast.SelectorExpr) bool {
	call, ok := s.parents[sel].(*ast.CallExpr)
	return ok && call.Fun == sel
}

func (s fileScanner) identCalledDirectly(id *ast.Ident) bool {
	call, ok := s.parents[id].(*ast.CallExpr)
	return ok && call.Fun == id
}

func (s fileScanner) identIsSelectorPart(id *ast.Ident) bool {
	_, ok := s.parents[id].(*ast.SelectorExpr)
	return ok
}

func (s fileScanner) outputReadNode(sel *ast.SelectorExpr) ast.Node {
	if call, ok := s.parents[sel].(*ast.CallExpr); ok && call.Fun == sel {
		return call
	}
	return sel
}

func (s fileScanner) parentAfterParens(node ast.Node) ast.Node {
	for {
		parent := s.parents[node]
		if paren, ok := parent.(*ast.ParenExpr); ok && paren.X == node {
			node = paren
			continue
		}
		return parent
	}
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

func unparen(expr ast.Expr) ast.Expr {
	for {
		paren, ok := expr.(*ast.ParenExpr)
		if !ok {
			return expr
		}
		expr = paren.X
	}
}
