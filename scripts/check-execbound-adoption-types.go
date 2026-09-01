package main

import (
	"go/ast"
	"go/token"
)

func (s fileScanner) rawBuilderOutputRead(call *ast.CallExpr) ast.Node {
	return s.directMethodCall(call, isOutputReadName)
}

func (s fileScanner) rawBuilderHasLifecycle(call *ast.CallExpr) bool {
	if s.directMethodCall(call, isRawLifecycleName) != nil {
		return true
	}
	id := s.rawBuilderAssignedIdent(call)
	return id != nil && s.functionCallsMethod(id, call.Pos(), isRawLifecycleName)
}

func (s fileScanner) rawBuilderAssignedIdent(call *ast.CallExpr) *ast.Ident {
	parent := s.parentAfterParens(call)
	switch n := parent.(type) {
	case *ast.AssignStmt:
		for i, rhs := range n.Rhs {
			if i < len(n.Lhs) && exprIsNode(rhs, call) {
				return assignedIdent(n.Lhs[i])
			}
		}
	case *ast.ValueSpec:
		for i, value := range n.Values {
			if i < len(n.Names) && exprIsNode(value, call) {
				return assignedIdent(n.Names[i])
			}
		}
	}
	return nil
}

func assignedIdent(expr ast.Expr) *ast.Ident {
	id, ok := unparen(expr).(*ast.Ident)
	if !ok || id.Name == "_" {
		return nil
	}
	return id
}

func exprIsNode(expr ast.Expr, node ast.Node) bool {
	for {
		if expr == node {
			return true
		}
		paren, ok := expr.(*ast.ParenExpr)
		if !ok {
			return false
		}
		expr = paren.X
	}
}

func (s fileScanner) execboundDelayOutputRead(call *ast.CallExpr) ast.Node {
	if !s.isExecboundDelayCommand(call.Fun) {
		return nil
	}
	return s.execboundOutputCall(call)
}

func (s fileScanner) execboundBuilderConsumed(call *ast.CallExpr) bool {
	return s.execboundOutputCall(call) != nil
}

func (s fileScanner) execboundOutputCall(call *ast.CallExpr) ast.Node {
	sel, ok := s.parentAfterParens(call).(*ast.SelectorExpr)
	if !ok {
		return nil
	}
	if isOutputReadName(sel.Sel.Name) {
		if s.selectorCalledDirectly(sel) {
			return s.outputReadNode(sel)
		}
		return nil
	}
	if sel.Sel.Name != "WithLogger" {
		return nil
	}
	withLogger, ok := s.parentAfterParens(sel).(*ast.CallExpr)
	if !ok || withLogger.Fun != sel {
		return nil
	}
	output, ok := s.parentAfterParens(withLogger).(*ast.SelectorExpr)
	if !ok || !isOutputReadName(output.Sel.Name) || !s.selectorCalledDirectly(output) {
		return nil
	}
	return s.outputReadNode(output)
}

func (s fileScanner) directMethodCall(call *ast.CallExpr, match func(string) bool) ast.Node {
	sel, ok := s.parentAfterParens(call).(*ast.SelectorExpr)
	if !ok || !match(sel.Sel.Name) || !s.selectorCalledDirectly(sel) {
		return nil
	}
	return s.outputReadNode(sel)
}

func (s fileScanner) functionCallsMethod(id *ast.Ident, after token.Pos, match func(string) bool) bool {
	body := s.functionBody(after)
	if body == nil {
		return false
	}
	found, invalid := false, false
	ast.Inspect(body, func(node ast.Node) bool {
		if found || invalid {
			return false
		}
		if _, ok := node.(*ast.FuncLit); ok {
			return false
		}
		if assign, ok := node.(*ast.AssignStmt); ok && assign.Pos() > after {
			for _, lhs := range assign.Lhs {
				if recv := assignedIdent(lhs); recv != nil && sameIdent(recv, id) {
					invalid = true
					return false
				}
			}
		}
		call, ok := node.(*ast.CallExpr)
		if !ok || call.Pos() <= after {
			return true
		}
		sel, ok := unparen(call.Fun).(*ast.SelectorExpr)
		if !ok || !match(sel.Sel.Name) {
			return true
		}
		recv, ok := unparen(sel.X).(*ast.Ident)
		if ok && sameIdent(recv, id) {
			found = true
			return false
		}
		return true
	})
	return found && !invalid
}

func (s fileScanner) functionBody(pos token.Pos) *ast.BlockStmt {
	for _, fn := range s.functions {
		if fn.start <= pos && pos <= fn.end {
			return fn.body
		}
	}
	return nil
}

func sameIdent(a, b *ast.Ident) bool {
	if a.Obj != nil || b.Obj != nil {
		return a.Obj != nil && a.Obj == b.Obj
	}
	return a.Name == b.Name
}

func (s fileScanner) isExecboundBuilderCall(call *ast.CallExpr) bool {
	return s.isExecboundCommand(call.Fun) || s.isExecboundDelayCommand(call.Fun)
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

func isRawLifecycleName(name string) bool { return name == "Start" || name == "Run" }

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
