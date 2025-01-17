// Copyright (c) 2019-2024 Felipe Pena All rights reserved.
// Use of this source code is governed by an MIT license that can be found in the LICENSE file.
module type_resolver

import ast
import v.token
import v.util

@[minify]
pub struct ResolverInfo {
pub mut:
	saved_type_map map[string]ast.Type

	// loop id for loop distinction
	comptime_loop_id int
	// $for
	inside_comptime_for bool
	// .variants
	comptime_for_variant_var string
	// .fields
	comptime_for_field_var   string
	comptime_for_field_type  ast.Type
	comptime_for_field_value ast.StructField
	// .values
	comptime_for_enum_var string
	// .attributes
	comptime_for_attr_var string
	// .methods
	comptime_for_method_var      string
	comptime_for_method          &ast.Fn = unsafe { nil }
	comptime_for_method_ret_type ast.Type
	// .args
	comptime_for_method_param_var string
}

// Interface for cgen / checker instance
pub interface IResolverType {
mut:
	file &ast.File
	unwrap_generic(t ast.Type) ast.Type
}

pub struct DummyResolver {
mut:
	file &ast.File = unsafe { nil }
}

fn (d DummyResolver) unwrap_generic(t ast.Type) ast.Type {
	return t
}

@[heap]
pub struct TypeResolver {
pub mut:
	resolver   IResolverType = DummyResolver{}
	table      &ast.Table    = unsafe { nil }
	info       ResolverInfo        // current info
	info_stack []ResolverInfo      // stores the values from the above on each $for loop, to make nesting them easier
	type_map   map[string]ast.Type // map for storing dynamic resolved types on checker/gen phase
}

@[inline]
pub fn TypeResolver.new(table &ast.Table, resolver &IResolverType) &TypeResolver {
	return &TypeResolver{
		table:    table
		resolver: resolver
	}
}

@[noreturn]
fn (t &TypeResolver) error(s string, pos token.Pos) {
	util.show_compiler_message('cgen error:', pos: pos, file_path: t.resolver.file.path, message: s)
	exit(1)
}

// get_type_or_default retries the comptime value if the AST node is related to comptime otherwise default_typ is returned
@[inline]
pub fn (mut t TypeResolver) get_type_or_default(node ast.Expr, default_typ ast.Type) ast.Type {
	match node {
		ast.Ident {
			if node.ct_expr {
				ctyp := t.get_type(node)
				return if ctyp != ast.void_type { ctyp } else { default_typ }
			}
		}
		ast.SelectorExpr {
			if node.expr is ast.Ident && node.expr.ct_expr {
				struct_typ := t.resolver.unwrap_generic(t.get_type(node.expr))
				struct_sym := t.table.final_sym(struct_typ)
				// Struct[T] can have field with generic type
				if struct_sym.info is ast.Struct && struct_sym.info.generic_types.len > 0 {
					if field := t.table.find_field(struct_sym, node.field_name) {
						return field.typ
					}
				}
			}
		}
		ast.ParExpr {
			return t.get_type_or_default(node.expr, default_typ)
		}
		ast.InfixExpr {
			if node.op in [.plus, .minus, .mul, .div, .mod] {
				return t.get_type_or_default(node.left, default_typ)
			}
		}
		else {
			return default_typ
		}
	}
	return default_typ
}

// get_type retrieves the actual type from a comptime related ast node
@[inline]
pub fn (mut t TypeResolver) get_type(node ast.Expr) ast.Type {
	if node is ast.Ident {
		if node.obj is ast.Var {
			return match node.obj.ct_type_var {
				.generic_param {
					// generic parameter from infoent function
					node.obj.typ
				}
				.generic_var {
					// generic var used on fn call assignment
					if node.obj.smartcasts.len > 0 {
						node.obj.smartcasts.last()
					} else {
						t.type_map['t.${node.name}.${node.obj.pos.pos}'] or { node.obj.typ }
					}
				}
				.smartcast {
					ctyp := t.type_map['${t.info.comptime_for_variant_var}.typ'] or { node.obj.typ }
					return if (node.obj as ast.Var).is_unwrapped {
						ctyp.clear_flag(.option)
					} else {
						ctyp
					}
				}
				.key_var, .value_var {
					// key and value variables from normal for stmt
					t.type_map[node.name] or { ast.void_type }
				}
				.field_var {
					// field var from $for loop
					t.info.comptime_for_field_type
				}
				else {
					ast.void_type
				}
			}
		}
	} else if node is ast.ComptimeSelector {
		// val.$(field.name)
		return t.get_comptime_selector_type(node, ast.void_type)
	} else if node is ast.SelectorExpr && t.info.is_comptime_selector_type(node) {
		return t.get_type_from_comptime_var(node.expr as ast.Ident)
	} else if node is ast.ComptimeCall {
		method_name := t.info.comptime_for_method.name
		left_sym := t.table.sym(t.resolver.unwrap_generic(node.left_type))
		f := left_sym.find_method(method_name) or {
			t.error('could not find method `${method_name}` on compile-time resolution',
				node.method_pos)
			return ast.void_type
		}
		return f.return_type
	} else if node is ast.IndexExpr && t.info.is_comptime(node.left) {
		nltype := t.get_type(node.left)
		nltype_unwrapped := t.resolver.unwrap_generic(nltype)
		return t.table.value_type(nltype_unwrapped)
	}
	return ast.void_type
}
