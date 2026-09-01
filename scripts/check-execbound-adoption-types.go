package main

import (
	"go/ast"
	"go/importer"
	"go/types"
	"path/filepath"
)

func (a *analyzer) typeInfo(dir string, files []*ast.File) *types.Info {
	info := &types.Info{
		Types:      map[ast.Expr]types.TypeAndValue{},
		Selections: map[*ast.SelectorExpr]*types.Selection{},
	}
	conf := types.Config{Importer: importer.Default(), Error: func(error) {}}
	_, _ = conf.Check(a.importPath(dir), a.fset, files, info)
	return info
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
	if sel.Sel.Name != "Output" && sel.Sel.Name != "CombinedOutput" {
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
		if ok && funcReceiverIsExecCmd(fn) {
			return true
		}
	}
	return typeIsExecCmd(s.info.TypeOf(sel.X))
}

func funcReceiverIsExecCmd(fn *types.Func) bool {
	sig, ok := fn.Type().(*types.Signature)
	return ok && sig.Recv() != nil && typeIsExecCmd(sig.Recv().Type())
}

func typeIsExecCmd(typ types.Type) bool {
	ptr, ok := typ.(*types.Pointer)
	if !ok {
		return false
	}
	named, ok := ptr.Elem().(*types.Named)
	return ok && named.Obj().Pkg() != nil && named.Obj().Pkg().Path() == "os/exec" && named.Obj().Name() == "Cmd"
}

func (s fileScanner) recordOrigins(file *ast.File) {
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
		}
		return true
	})
}

func (s fileScanner) recordOrigin(lhs ast.Expr, rhs ast.Expr) {
	id, ok := unparen(lhs).(*ast.Ident)
	if ok && id.Obj != nil && s.exprCanOriginateFromCmd(rhs) {
		s.origins[id.Obj] = true
	}
}

func (s fileScanner) exprCanOriginateFromCmd(expr ast.Expr) bool {
	if typeIsExecCmd(s.info.TypeOf(expr)) || s.isOSExecBuilderCall(expr) || s.isExecboundProduced(expr) {
		return true
	}
	id, ok := unparen(expr).(*ast.Ident)
	return ok && id.Obj != nil && s.origins[id.Obj]
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
