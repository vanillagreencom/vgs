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
	return id != nil && s.assignedBuilderHasLifecycle(id, call.Pos())
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

func (s fileScanner) assignedBuilderHasLifecycle(id *ast.Ident, after token.Pos) bool {
	body := s.functionBody(after)
	if body == nil {
		return false
	}
	ctx := s.rawBuilderContext(after)
	foundLifecycle, invalid := false, false
	ast.Inspect(body, func(node ast.Node) bool {
		if invalid {
			return false
		}
		use, ok := node.(*ast.Ident)
		if !ok || use.Pos() <= after || !sameIdent(use, id) {
			return true
		}
		if s.identIsAssignedBuilderWrite(use) {
			invalid = true
			return false
		}
		allowed, lifecycle := s.assignedBuilderUseAllowed(use, foundLifecycle, ctx)
		if !allowed {
			invalid = true
			return false
		}
		if lifecycle {
			foundLifecycle = true
		}
		return true
	})
	return foundLifecycle && !invalid
}

func (s fileScanner) identIsAssignedBuilderWrite(id *ast.Ident) bool {
	assign, ok := s.parentAfterParens(id).(*ast.AssignStmt)
	if !ok {
		return false
	}
	for _, lhs := range assign.Lhs {
		if assigned := assignedIdent(lhs); assigned != nil && sameIdent(assigned, id) {
			return true
		}
	}
	return false
}

func (s fileScanner) rawBuilderContext(pos token.Pos) string {
	file := s.analyzer.fset.Position(pos).Filename
	return s.analyzer.rel(file) + "::" + functionAt(s.functions, pos)
}

func (s fileScanner) assignedBuilderUseAllowed(id *ast.Ident, lifecycleSeen bool, ctx string) (bool, bool) {
	sel := s.selectorForIdentReceiver(id)
	if sel != nil {
		if isRawLifecycleName(sel.Sel.Name) {
			called := s.selectorCalledDirectly(sel)
			return called, called
		}
		if !lifecycleSeen && isRawBuilderConfigFieldName(sel.Sel.Name) {
			return true, false
		}
		if !lifecycleSeen && isRawBuilderPipeName(sel.Sel.Name) {
			return s.selectorCalledDirectly(sel), false
		}
		if lifecycleSeen && isRawBuilderFollowupName(sel.Sel.Name) {
			return sel.Sel.Name == "Process" || sel.Sel.Name == "ProcessState" || s.selectorCalledDirectly(sel), false
		}
		return false, false
	}
	return lifecycleSeen && s.allowedRawBuilderFollowupUse(id, ctx), false
}

func (s fileScanner) selectorForIdentReceiver(id *ast.Ident) *ast.SelectorExpr {
	var node ast.Node = id
	for {
		parent := s.parents[node]
		if paren, ok := parent.(*ast.ParenExpr); ok && paren.X == node {
			node = paren
			continue
		}
		sel, ok := parent.(*ast.SelectorExpr)
		if !ok || sel.X != node {
			return nil
		}
		return sel
	}
}

func isRawBuilderConfigFieldName(name string) bool {
	switch name {
	case "Cancel", "Dir", "Env", "ExtraFiles", "Stderr", "Stdin", "Stdout", "SysProcAttr", "WaitDelay":
		return true
	default:
		return false
	}
}

func isRawBuilderPipeName(name string) bool {
	return name == "StderrPipe" || name == "StdinPipe" || name == "StdoutPipe"
}

func isRawBuilderFollowupName(name string) bool {
	return name == "Process" || name == "ProcessState" || name == "Wait"
}

func (s fileScanner) allowedRawBuilderFollowupUse(id *ast.Ident, ctx string) bool {
	if call := s.callForArgument(id); call != nil {
		switch ctx + "::" + callName(call.Fun) {
		case "backend/internal/runner/runner.go::runQuickshell::exitCode",
			"backend/internal/services/cloudsync/rcd.go::start::kill",
			"backend/internal/services/cloudsync/rcd.go::start::wait",
			"backend/internal/services/gamma/gamma.go::applyGammaLocked::watchLocked",
			"backend/internal/services/sysupdate/sysupdate.go::handleUpgrade::waitUpgrade":
			return true
		}
	}
	if assign, ok := s.parentAfterParens(id).(*ast.AssignStmt); ok {
		for i, rhs := range assign.Rhs {
			if i >= len(assign.Lhs) || !exprIsNode(rhs, id) {
				continue
			}
			sel, selOK := unparen(assign.Lhs[i]).(*ast.SelectorExpr)
			if !selOK {
				continue
			}
			recv, recvOK := unparen(sel.X).(*ast.Ident)
			if recvOK {
				switch ctx + "::" + recv.Name + "." + sel.Sel.Name {
				case "backend/internal/services/cloudsync/rcd.go::start::d.cmd",
					"backend/internal/services/gamma/gamma.go::applyGammaLocked::m.cmd":
					return true
				}
			}
		}
	}
	kv, ok := s.parentAfterParens(id).(*ast.KeyValueExpr)
	if !ok {
		return false
	}
	key, keyOK := unparen(kv.Key).(*ast.Ident)
	lit, litOK := s.parents[kv].(*ast.CompositeLit)
	if !litOK {
		return false
	}
	typ, typOK := unparen(lit.Type).(*ast.Ident)
	return keyOK && typOK && key.Name == "cmd" && typ.Name == "oauthSession" &&
		ctx == "backend/internal/services/cloudsync/remotes.go::beginOAuth"
}

func (s fileScanner) callForArgument(id *ast.Ident) *ast.CallExpr {
	call, ok := s.parentAfterParens(id).(*ast.CallExpr)
	if !ok {
		return nil
	}
	for _, arg := range call.Args {
		if exprIsNode(arg, id) {
			return call
		}
	}
	return nil
}

func callName(expr ast.Expr) string {
	switch n := unparen(expr).(type) {
	case *ast.Ident:
		return n.Name
	case *ast.SelectorExpr:
		return n.Sel.Name
	default:
		return ""
	}
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
