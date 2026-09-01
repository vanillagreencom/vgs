package main

import (
	"go/ast"
	"go/token"
	"go/types"
)

func (a *analyzer) markTreeProvenance() {
	if a.paramOrigins == nil {
		a.paramOrigins = map[string]map[int]bool{}
		a.resultOrigins = map[string]bool{}
	}
	for {
		changed := false
		for _, pkg := range a.packages {
			for _, file := range pkg.files {
				s := fileScanner{
					analyzer: a,
					imports:  importAliases(file, a.modulePath),
					info:     pkg.info,
					origins:  map[*ast.Object]bool{},
				}
				s.recordOrigins(file)
				if s.markFuncProvenance(file) {
					changed = true
				}
			}
		}
		if !changed {
			return
		}
	}
}

func (s fileScanner) markFuncProvenance(file *ast.File) bool {
	changed := false
	for _, decl := range file.Decls {
		fn, ok := decl.(*ast.FuncDecl)
		if !ok || fn.Body == nil {
			continue
		}
		current := funcKey(s.info.Defs[fn.Name])
		ast.Inspect(fn.Body, func(node ast.Node) bool {
			switch n := node.(type) {
			case *ast.CallExpr:
				if key := funcKey(s.calledFunc(n)); key != "" {
					for i, arg := range n.Args {
						if s.exprCanOriginateFromCmd(arg) {
							changed = s.markParamOrigin(key, i) || changed
						}
					}
				}
			case *ast.ReturnStmt:
				for _, result := range n.Results {
					if current != "" && s.exprCanOriginateFromCmd(result) && !s.analyzer.resultOrigins[current] {
						s.analyzer.resultOrigins[current] = true
						changed = true
					}
				}
			}
			return true
		})
	}
	return changed
}

func (s fileScanner) markParamOrigin(key string, index int) bool {
	if s.analyzer.paramOrigins[key] == nil {
		s.analyzer.paramOrigins[key] = map[int]bool{}
	}
	if s.analyzer.paramOrigins[key][index] {
		return false
	}
	s.analyzer.paramOrigins[key][index] = true
	return true
}

func (s fileScanner) recordParamOrigins(file *ast.File) {
	for _, decl := range file.Decls {
		fn, ok := decl.(*ast.FuncDecl)
		origins := map[int]bool{}
		if ok && fn.Type.Params != nil {
			origins = s.analyzer.paramOrigins[funcKey(s.info.Defs[fn.Name])]
		}
		if len(origins) == 0 {
			continue
		}
		index := 0
		for _, field := range fn.Type.Params.List {
			if len(field.Names) == 0 {
				index++
				continue
			}
			for _, name := range field.Names {
				if origins[index] && name.Obj != nil {
					s.origins[name.Obj] = true
				}
				index++
			}
		}
	}
}

func (s fileScanner) calledFunc(call *ast.CallExpr) types.Object {
	switch fun := unparen(call.Fun).(type) {
	case *ast.Ident:
		return s.info.Uses[fun]
	case *ast.SelectorExpr:
		if selection := s.info.Selections[fun]; selection != nil {
			return selection.Obj()
		}
		return s.info.Uses[fun.Sel]
	default:
		return nil
	}
}

func funcKey(obj types.Object) string {
	fn, ok := obj.(*types.Func)
	if !ok || fn.Pkg() == nil {
		return ""
	}
	return fn.FullName()
}

func originIdent(expr ast.Expr) *ast.Ident {
	switch n := unparen(expr).(type) {
	case *ast.Ident:
		if n.Name == "_" {
			return nil
		}
		return n
	case *ast.SelectorExpr:
		return originIdent(n.X)
	case *ast.IndexExpr:
		return originIdent(n.X)
	case *ast.StarExpr:
		return originIdent(n.X)
	default:
		return nil
	}
}

func (s fileScanner) aggregateCanOriginateFromCmd(expr ast.Expr) bool {
	switch n := unparen(expr).(type) {
	case *ast.CompositeLit:
		return s.compositeCanOriginateFromCmd(n)
	case *ast.IndexExpr:
		return s.exprCanOriginateFromCmd(n.X)
	case *ast.SelectorExpr:
		return s.exprCanOriginateFromCmd(n.X)
	case *ast.StarExpr:
		return s.exprCanOriginateFromCmd(n.X)
	case *ast.UnaryExpr:
		return n.Op == token.AND && s.exprCanOriginateFromCmd(n.X)
	default:
		return false
	}
}

func (s fileScanner) compositeCanOriginateFromCmd(lit *ast.CompositeLit) bool {
	for _, elt := range lit.Elts {
		if pair, ok := elt.(*ast.KeyValueExpr); ok {
			elt = pair.Value
		}
		expr, ok := elt.(ast.Expr)
		if ok && s.exprCanOriginateFromCmd(expr) {
			return true
		}
	}
	return false
}
