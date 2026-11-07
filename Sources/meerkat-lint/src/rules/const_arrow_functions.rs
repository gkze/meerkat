//! Converts eligible non-exported functions to const arrows while
//! preserving lexical semantics: a direct-call-only
//! `function read() { return value; }` becomes
//! `const read = () => { return value; };`. Port of tsmono's
//! `const-arrow-functions`.
//!
//! It never converts an exported function. Every other function keeps its
//! form unless each read of its name is a direct call after the
//! declaration, and it uses no `this`, `arguments`, `super`, `new.target` or
//! `this` type, is not a generator, has no `this` parameter, overload or
//! namespace merge, and no comment would be moved.

use std::collections::HashSet;

use oxc::ast::AstKind;
use oxc::ast::ast::{
    BindingPattern, ExportDefaultDeclarationKind, Expression, Function, FunctionType, ModuleExportName, Program,
    Statement, VariableDeclarationKind,
};
use oxc::semantic::{NodeId, SymbolId};
use oxc::span::{GetSpan, Span};

use crate::source::{Context, Edit, Finding};

const MESSAGE: &str = "Convert function to const arrow.";

pub fn check(context: &Context<'_, '_>) -> Vec<Finding> {
    let nodes = context.nodes();
    let program = nodes.program();
    let hazards = lexical_hazards(context);
    let exported = exported_names(program);
    let mut findings = Vec::new();
    for node in nodes.iter() {
        let AstKind::Function(function) = node.kind() else { continue };
        if hazards.contains(&node.id()) || !is_safe(context, function) {
            continue;
        }
        let prefix = match function.r#type {
            FunctionType::FunctionDeclaration => declaration_prefix(context, node.id(), function, program, &exported),
            FunctionType::FunctionExpression => expression_prefix(context, node.id(), function, &exported),
            _ => None,
        };
        let (Some(prefix), Some(body)) = (prefix, &function.body) else { continue };
        findings.push(Finding {
            message: MESSAGE,
            offset: function.span.start,
            edit: Some(Edit { start: function.span.start, end: body.span.start, text: prefix }),
        });
    }
    findings
}

/// Functions whose own body uses `this`, `arguments`, `super`, `new.target`
/// or the `this` type, which an arrow would take from its surroundings.
/// Arrows are transparent, so the use counts for the nearest function.
fn lexical_hazards(context: &Context<'_, '_>) -> HashSet<NodeId> {
    let nodes = context.nodes();
    let mut hazards = HashSet::new();
    for node in nodes.iter() {
        let hazard = match node.kind() {
            AstKind::ThisExpression(_) | AstKind::Super(_) | AstKind::TSThisType(_) | AstKind::NewTarget(_) => true,
            AstKind::IdentifierReference(it) => it.name == "arguments",
            AstKind::IdentifierName(it) => it.name == "arguments",
            AstKind::BindingIdentifier(it) => it.name == "arguments",
            AstKind::LabelIdentifier(it) => it.name == "arguments",
            _ => false,
        };
        if hazard && let Some(function) = nodes.ancestors(node.id()).find(|a| matches!(a.kind(), AstKind::Function(_)))
        {
            hazards.insert(function.id());
        }
    }
    hazards
}

fn is_safe(context: &Context<'_, '_>, function: &Function<'_>) -> bool {
    let Some(body) = &function.body else { return false };
    !function.generator
        && function.this_param.is_none()
        && !context.has_comment_before(function.span.start)
        && !context.has_comment_after(function.span.end)
        && !context.has_comment_inside(Span::new(function.span.start, body.span.start))
        && !context.has_comment_inside(Span::new(body.span.end, function.span.end))
}

/// Names exported from the module by specifier, `export default name` or
/// `export = name`.
fn exported_names<'a>(program: &Program<'a>) -> HashSet<&'a str> {
    let mut names = HashSet::new();
    for statement in &program.body {
        match statement {
            Statement::ExportNamedDeclaration(it) => {
                for specifier in &it.specifiers {
                    match &specifier.local {
                        ModuleExportName::IdentifierName(name) => names.insert(name.name.as_str()),
                        ModuleExportName::IdentifierReference(name) => names.insert(name.name.as_str()),
                        ModuleExportName::StringLiteral(_) => false,
                    };
                }
            }
            Statement::ExportDefaultDeclaration(it) => {
                if let ExportDefaultDeclarationKind::Identifier(name) = &it.declaration {
                    names.insert(name.name.as_str());
                }
            }
            Statement::TSExportAssignment(it) => {
                if let Expression::Identifier(name) = &it.expression {
                    names.insert(name.name.as_str());
                }
            }
            _ => {}
        }
    }
    names
}

fn is_export(kind: AstKind<'_>) -> bool {
    matches!(
        kind,
        AstKind::ExportDeclaration(_)
            | AstKind::ExportNamedDeclaration(_)
            | AstKind::ExportDefaultDeclaration(_)
            | AstKind::TSExportAssignment(_)
    )
}

/// A use of the symbol anywhere inside an export, such as
/// `export default { name }`.
fn has_export_reference(context: &Context<'_, '_>, symbol: SymbolId) -> bool {
    context
        .scoping()
        .get_resolved_references(symbol)
        .any(|reference| context.nodes().ancestors(reference.node_id()).any(|ancestor| is_export(ancestor.kind())))
}

/// Anything but a direct call after the declaration: a write, a read before
/// it (the hoisted declaration would become a TDZ error), or a use as a
/// value (`new`, `instanceof`, `.prototype`, passing it on). For a function
/// declaration (`hoisted`, its node), also a call from inside any other
/// function declaration: that one is hoisted too and may run before this
/// line, however late its text comes.
fn has_unsafe_reference(
    context: &Context<'_, '_>,
    symbol: SymbolId,
    declaration_start: u32,
    hoisted: Option<NodeId>,
) -> bool {
    context.scoping().get_resolved_references(symbol).any(|reference| {
        let identifier = reference.node_id();
        !reference.is_read()
            || reference.is_write()
            || context.nodes().kind(identifier).span().start < declaration_start
            || hoisted.is_some_and(|own| is_in_other_declaration(context, identifier, own))
            || !is_direct_call(context, identifier)
    })
}

/// Whether `identifier` is inside a function declaration that is neither
/// `own` nor inside it. A call from `own`'s body runs only once `own` does,
/// which is after its conversion's `const` is initialized.
fn is_in_other_declaration(context: &Context<'_, '_>, identifier: NodeId, own: NodeId) -> bool {
    let mut declared = false;
    for ancestor in context.nodes().ancestors(identifier) {
        if ancestor.id() == own {
            return false;
        }
        declared |= matches!(ancestor.kind(), AstKind::Function(f) if f.r#type == FunctionType::FunctionDeclaration);
    }
    declared
}

/// Expression wrappers that keep their inner expression's identity:
/// `(value as string)!` still refers to `value`. Returns the wrapped
/// expression's span when `node` is one. Parentheses have no node here
/// (`analyze`).
fn transparent_inner(context: &Context<'_, '_>, node: NodeId) -> Option<Span> {
    Some(match context.nodes().kind(node) {
        AstKind::ChainExpression(it) => it.expression.span(),
        AstKind::TSAsExpression(it) => it.expression.span(),
        AstKind::TSInstantiationExpression(it) => it.expression.span(),
        AstKind::TSNonNullExpression(it) => it.expression.span(),
        AstKind::TSSatisfiesExpression(it) => it.expression.span(),
        AstKind::TSTypeAssertion(it) => it.expression.span(),
        _ => return None,
    })
}

fn is_direct_call(context: &Context<'_, '_>, identifier: NodeId) -> bool {
    let nodes = context.nodes();
    let mut current = identifier;
    let mut span = nodes.kind(current).span();
    loop {
        let parent = nodes.parent_id(current);
        if parent == current || transparent_inner(context, parent) != Some(span) {
            break;
        }
        current = parent;
        span = nodes.kind(current).span();
    }
    matches!(nodes.parent_kind(current), AstKind::CallExpression(call) if call.callee.span() == span)
}

/// The next token cannot continue `const name = () => {}`: a statement
/// end, a brace, the end of the file, or a token that starts a statement.
fn has_safe_terminator(context: &Context<'_, '_>, end: u32) -> bool {
    let rest = context.text[end as usize..].trim_start();
    let Some(first) = rest.chars().next() else { return true };
    if first == '_' || first == '$' || first.is_alphanumeric() || first == '"' || first == '\'' {
        let word: String = rest.chars().take_while(|c| c.is_alphanumeric() || *c == '_' || *c == '$').collect();
        return word != "as" && word != "satisfies";
    }
    matches!(first, ';' | '{' | '}')
}

/// A top-level overload signature or namespace with the same name.
fn has_declaration_conflict(program: &Program<'_>, name: &str) -> bool {
    program.body.iter().any(|statement| match statement {
        Statement::FunctionDeclaration(f) => {
            f.r#type == FunctionType::TSDeclareFunction
                && f.body.is_none()
                && f.id.as_ref().is_some_and(|id| id.name == name)
        }
        Statement::TSNamespaceDeclaration(n) => n.id.name == name,
        _ => false,
    })
}

/// The arrow's parameters, type parameters and return type: the source from
/// `start` to the body, with `<T>` written `<T,>` so it stays a type
/// parameter list in TSX.
fn signature(context: &Context<'_, '_>, function: &Function<'_>, start: usize) -> Option<String> {
    let body = function.body.as_ref()?.span.start as usize;
    let text = context.text;
    let mut signature = text[start..body].to_owned();
    if let Some(parameters) = &function.type_parameters
        && parameters.params.len() == 1
    {
        let end = parameters.span.end as usize;
        if text.as_bytes()[end - 2] != b',' {
            signature.insert(end - start - 1, ',');
        }
    }
    Some(signature.trim().to_owned())
}

fn async_text(function: &Function<'_>) -> &'static str {
    if function.r#async { "async " } else { "" }
}

fn declaration_prefix(
    context: &Context<'_, '_>,
    node: NodeId,
    function: &Function<'_>,
    program: &Program<'_>,
    exported: &HashSet<&str>,
) -> Option<String> {
    let nodes = context.nodes();
    if !has_safe_terminator(context, function.span.end) || !program.source_type.is_module() {
        return None;
    }
    // Top-level only, and never exported.
    if !matches!(nodes.parent_kind(node), AstKind::Program(_)) {
        return None;
    }
    let id = function.id.as_ref()?;
    let symbol = id.symbol_id.get()?;
    let name = id.name.as_str();
    if exported.contains(name)
        || has_export_reference(context, symbol)
        || has_declaration_conflict(program, name)
        || has_unsafe_reference(context, symbol, function.span.start, Some(node))
    {
        return None;
    }
    let signature = signature(context, function, id.span.end as usize)?;
    Some(format!("const {name} = {}{signature} => ", async_text(function)))
}

fn expression_prefix(
    context: &Context<'_, '_>,
    node: NodeId,
    function: &Function<'_>,
    exported: &HashSet<&str>,
) -> Option<String> {
    let nodes = context.nodes();
    if function.id.is_some() {
        return None;
    }
    let declarator_id = nodes.parent_id(node);
    let AstKind::VariableDeclarator(declarator) = nodes.kind(declarator_id) else { return None };
    if declarator.init.as_ref().map(GetSpan::span) != Some(function.span) {
        return None;
    }
    let BindingPattern::BindingIdentifier(binding) = &declarator.id else { return None };
    let declaration_id = nodes.parent_id(declarator_id);
    let AstKind::VariableDeclaration(declaration) = nodes.kind(declaration_id) else { return None };
    if declaration.kind != VariableDeclarationKind::Const {
        return None;
    }
    let container = nodes.parent_kind(declaration_id);
    if is_export(container) {
        return None;
    }
    let top_level = matches!(container, AstKind::Program(_));
    let symbol = binding.symbol_id.get()?;
    let name = binding.name.as_str();
    if (top_level && exported.contains(name))
        || has_export_reference(context, symbol)
        || has_unsafe_reference(context, symbol, declarator.span.start, None)
    {
        return None;
    }
    let keyword = function.span.start as usize + context.slice(function.span).find("function")?;
    let signature = signature(context, function, keyword + "function".len())?;
    Some(format!("{}{signature} => ", async_text(function)))
}

#[cfg(test)]
mod tests {
    use crate::source::testing::{fixed, lines, unchanged};

    const RULE: &str = "const-arrow-functions";

    fn source(lines: &[&str]) -> String {
        format!("{}\n", lines.join("\n"))
    }

    #[test]
    fn converts_a_safe_local_declaration() {
        let input =
            source(&["export {};", "function local(value: string): string { return value; }", "local(\"value\");"]);
        assert_eq!(lines(RULE, "local.ts", &input), [2]);
        assert_eq!(
            fixed(RULE, "local.ts", &input),
            source(&["export {};", "const local = (value: string): string => { return value; }", "local(\"value\");"])
        );
    }

    #[test]
    fn keeps_recursive_direct_calls() {
        let body = ["  if (value === 0) return 0;", "  return countdown(value - 1);", "}", "countdown(2);"];
        let input = source(&[&["export {};", "function countdown(value: number): number {"][..], &body[..]].concat());
        let expected =
            source(&[&["export {};", "const countdown = (value: number): number => {"][..], &body[..]].concat());
        assert_eq!(fixed(RULE, "recursive.ts", &input), expected);
    }

    #[test]
    fn leaves_unsafe_declarations() {
        let cases: [(&str, &[&str]); 15] = [
            (
                "reassigned.ts",
                &[
                    "export {};",
                    "declare const replacement: () => void;",
                    "function local(): void {}",
                    "local = replacement;",
                    "local();",
                ],
            ),
            ("script.ts", &["function local(): void {}"]),
            ("hoisted.ts", &["export {};", "local();", "function local(): void {}"]),
            ("continuation-token.ts", &["export {};", "function local(): void {}", "[1].forEach((): void => {});"]),
            (
                "constructed.ts",
                &[
                    "export {};",
                    "function Constructor(): void {}",
                    "new (Constructor as unknown as new () => object)();",
                ],
            ),
            (
                "prototype.ts",
                &["export {};", "function Constructor(): void {}", "Constructor.prototype.method = (): void => {};"],
            ),
            (
                "instanceof.ts",
                &[
                    "export {};",
                    "function Constructor(): void {}",
                    "declare const value: unknown;",
                    "value instanceof Constructor;",
                ],
            ),
            (
                "aliased-constructor.ts",
                &["export {};", "function Constructor(): void {}", "const Alias = Constructor;", "new Alias();"],
            ),
            (
                "reflective-prototype.ts",
                &["export {};", "function Constructor(): void {}", "Reflect.get(Constructor, \"prototype\");"],
            ),
            (
                "escaped.ts",
                &[
                    "export {};",
                    "declare function register(value: Function): void;",
                    "function Constructor(): void {}",
                    "register(Constructor);",
                ],
            ),
            (
                "overload.ts",
                &[
                    "export {};",
                    "function parse(value: string): string;",
                    "function parse(value: string): string { return value; }",
                ],
            ),
            (
                "merged.ts",
                &["export {};", "function local(): void {}", "namespace local { export const value: number = 1; }"],
            ),
            ("generator.ts", &["export {};", "function* values(): Generator<number> { yield 1; }"]),
            (
                "lexical.ts",
                &[
                    "export {};",
                    "function local(this: object): unknown {",
                    "  if (new.target !== undefined) return new.target;",
                    "  return [this, arguments];",
                    "}",
                ],
            ),
            ("commented.ts", &["export {};", "/** Keep this declaration. */", "function local(): void {}"]),
        ];
        for (name, input) in cases {
            unchanged(RULE, name, &source(input));
        }
    }

    #[test]
    fn leaves_calls_from_other_hoisted_declarations() {
        // `first()` runs `second()` before `second`'s line: as a `const`,
        // that call would be a TDZ error.
        unchanged(
            RULE,
            "hoisted-caller.ts",
            &source(&["export {};", "first();", "function second(): void {}", "function first(): void { second(); }"]),
        );
        unchanged(
            RULE,
            "nested-hoisted-caller.ts",
            &source(&[
                "export {};",
                "function second(): void {}",
                "if (true) {",
                "  function first(): void { second(); }",
                "}",
            ]),
        );
    }

    #[test]
    fn converts_calls_from_its_own_nested_declarations() {
        let input = source(&[
            "export {};",
            "function outer(): void {",
            "  function inner(): void { outer(); }",
            "  inner();",
            "}",
            "outer();",
        ]);
        assert_eq!(
            fixed(RULE, "own-nested.ts", &input),
            source(&[
                "export {};",
                "const outer = (): void => {",
                "  function inner(): void { outer(); }",
                "  inner();",
                "}",
                "outer();",
            ])
        );
    }

    #[test]
    fn leaves_lexical_uses_one_at_a_time() {
        for line in ["  return this;", "  return arguments.length;", "  return new.target;"] {
            unchanged(
                RULE,
                "lexical-one.ts",
                &source(&["export {};", "function local(): unknown {", line, "}", "local();"]),
            );
        }
    }

    #[test]
    fn converts_a_direct_const_initializer() {
        let input = source(&["export {};", "const local = function (value: string): string { return value; };"]);
        assert_eq!(lines(RULE, "expression.ts", &input), [2]);
        assert_eq!(
            fixed(RULE, "expression.ts", &input),
            source(&["export {};", "const local = (value: string): string => { return value; };"])
        );
    }

    #[test]
    fn converts_initializers_in_local_scopes() {
        assert_eq!(
            fixed(RULE, "script-expression.ts", "const local = function (): void {};\n"),
            "const local = (): void => {};\n"
        );
        assert_eq!(
            fixed(
                RULE,
                "nested-expression.ts",
                &source(&["export {};", "if (true) {", "  const local = function (): void {};", "}"])
            ),
            source(&["export {};", "if (true) {", "  const local = (): void => {};", "}"])
        );
    }

    #[test]
    fn leaves_exported_expressions() {
        let cases: [(&str, &[&str]); 5] = [
            ("direct-export-expression.ts", &["export const direct = function (): void {};"]),
            (
                "indirect-export-expression.ts",
                &["const indirect = function (): void {};", "export { indirect as publicFunction };"],
            ),
            ("default-export-expression.ts", &["const indirect = function (): void {};", "export default indirect;"]),
            (
                "compound-export-expression.ts",
                &["const indirect = function (): void {};", "export default { indirect };"],
            ),
            (
                "namespace-export-expression.ts",
                &["export namespace scope {", "  export const nested = function (): void {};", "}"],
            ),
        ];
        for (name, input) in cases {
            unchanged(RULE, name, &source(input));
        }
    }

    #[test]
    fn leaves_exported_declarations() {
        let cases: [(&str, &[&str]); 6] = [
            ("direct-export.ts", &["export function direct(): void {}"]),
            ("indirect-export.ts", &["function indirect(): void {}", "export { indirect as publicFunction };"]),
            ("default-export.ts", &["function indirect(): void {}", "export default indirect;"]),
            ("type-export.ts", &["function indirect(): void {}", "export type { indirect };"]),
            ("compound-export.ts", &["function indirect(): void {}", "export default { indirect };"]),
            (
                "exported.ts",
                &[
                    "export function direct(value: string): string { return value; }",
                    "export const expression = function (): void {};",
                    "function indirect(): void {}",
                    "export default indirect;",
                    "export function overloaded(value: string): string;",
                    "export function overloaded(value: string): string { return value; }",
                    "export function merged(): void {}",
                    "export namespace merged { export const value: number = 1; }",
                ],
            ),
        ];
        for (name, input) in cases {
            unchanged(RULE, name, &source(input));
        }
    }

    #[test]
    fn keeps_async_and_tsx_generics() {
        let input = source(&[
            "export {};",
            "async function load<T>(value: T): Promise<T> { return value; }",
            "const identity = function<T>(value: T): T { return value; };",
        ]);
        assert_eq!(lines(RULE, "generic.tsx", &input), [2, 3]);
        assert_eq!(
            fixed(RULE, "generic.tsx", &input),
            source(&[
                "export {};",
                "const load = async <T,>(value: T): Promise<T> => { return value; }",
                "const identity = <T,>(value: T): T => { return value; };",
            ])
        );
    }
}
