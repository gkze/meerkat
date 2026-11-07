//! Compacts safe one-return arrow blocks while preserving syntax, comments
//! and ASI safety: `const read = () => { return value; };` becomes
//! `const read = () => value;`. Port of tsmono's `compact-arrow-returns`.

use oxc::ast::AstKind;
use oxc::ast::ast::{ArrowFunctionBody, Expression, ForStatementInit, ForStatementLeft, Statement};
use oxc::semantic::NodeId;
use oxc::span::{GetSpan, Span};

use crate::source::{Context, Edit, Finding, LINE_WIDTH, has_line_break, width};

const MESSAGE: &str = "Compact arrow function return.";

pub fn check(context: &Context<'_, '_>) -> Vec<Finding> {
    let mut findings = Vec::new();
    for node in context.nodes().iter() {
        let AstKind::ArrowFunctionExpression(arrow) = node.kind() else { continue };
        let ArrowFunctionBody::FunctionBody(body) = &arrow.body else { continue };
        if !body.directives.is_empty() || body.statements.len() != 1 || context.has_comment_inside(body.span) {
            continue;
        }
        let Statement::ReturnStatement(statement) = &body.statements[0] else { continue };
        let Some(expression) = &statement.argument else { continue };

        let expression_span = expression.span();
        let expression_text = context.slice(expression_span);
        let parenthesize = needs_parentheses(expression, expression_text);
        let terminate = needs_terminator(context, node.id(), arrow.span);
        let body_text = if parenthesize { format!("({expression_text})") } else { expression_text.to_owned() };
        let line_text = format!("{body_text}{}", if terminate { ";" } else { "" });
        if !fits(context, body.span, &line_text) {
            continue;
        }
        findings.push(Finding {
            message: MESSAGE,
            offset: body.span.start,
            edit: Some(Edit::around(
                context.text,
                body.span,
                expression_span,
                if parenthesize { "(" } else { "" },
                &format!("{}{}", if parenthesize { ")" } else { "" }, if terminate { ";" } else { "" }),
            )),
        });
    }
    findings
}

/// A concise body cannot start with `{`, which the grammar reads as a block
/// whatever follows: the object literal may be only the leftmost operand
/// (`{ value } as const`, `{ a: 1 }.a`), so the test is the expression's
/// first token, which is its text's first character (the body has no
/// comments). A sequence would end the body at its first comma, also under a
/// type wrapper.
fn needs_parentheses(expression: &Expression<'_>, text: &str) -> bool {
    text.starts_with('{') || is_sequence(expression)
}

fn is_sequence(expression: &Expression<'_>) -> bool {
    match expression {
        Expression::SequenceExpression(_) => true,
        Expression::TSAsExpression(it) => is_sequence(&it.expression),
        Expression::TSNonNullExpression(it) => is_sequence(&it.expression),
        Expression::TSSatisfiesExpression(it) => is_sequence(&it.expression),
        Expression::TSTypeAssertion(it) => is_sequence(&it.expression),
        _ => false,
    }
}

/// Whether the result still fits on one line. A multi-line expression is
/// left to the formatter.
fn fits(context: &Context<'_, '_>, body: Span, replacement: &str) -> bool {
    if has_line_break(replacement) {
        return true;
    }
    let text = context.text;
    let start = body.start as usize;
    let end = body.end as usize;
    let line =
        format!("{}{replacement}{}", &text[line_start_lf(text, start)..start], &text[end..line_end_lf(text, end)]);
    width(&line) <= LINE_WIDTH
}

// tsmono's rule measures this line by `\n` only; the port keeps that.
fn line_start_lf(text: &str, offset: usize) -> usize {
    text[..offset].rfind('\n').map_or(0, |index| index + 1)
}

fn line_end_lf(text: &str, offset: usize) -> usize {
    text[offset..].find('\n').map_or(text.len(), |index| offset + index)
}

/// Whether the arrow ends the statement it is in, so the block's closing
/// brace was what ended it and a concise body needs a `;` instead.
fn needs_terminator(context: &Context<'_, '_>, arrow: NodeId, span: Span) -> bool {
    let nodes = context.nodes();
    for ancestor in nodes.ancestors(arrow).skip(1) {
        if ancestor.kind().span().end != span.end {
            return false;
        }
        match ancestor.kind() {
            AstKind::ExportDefaultDeclaration(_)
            | AstKind::ExpressionStatement(_)
            | AstKind::ReturnStatement(_)
            | AstKind::ThrowStatement(_)
            | AstKind::TSExportAssignment(_) => return true,
            AstKind::VariableDeclaration(declaration) if !is_for_header(context, ancestor.id(), declaration.span) => {
                return true;
            }
            _ => {}
        }
    }
    false
}

fn is_for_header(context: &Context<'_, '_>, declaration: NodeId, span: Span) -> bool {
    match context.nodes().parent_kind(declaration) {
        AstKind::ForStatement(it) => {
            matches!(&it.init, Some(ForStatementInit::VariableDeclaration(d)) if d.span == span)
        }
        AstKind::ForInStatement(it) => matches!(&it.left, ForStatementLeft::VariableDeclaration(d) if d.span == span),
        AstKind::ForOfStatement(it) => matches!(&it.left, ForStatementLeft::VariableDeclaration(d) if d.span == span),
        _ => false,
    }
}

#[cfg(test)]
mod tests {
    use crate::source::testing::{fixed, lines, unchanged};

    const RULE: &str = "compact-arrow-returns";

    #[test]
    fn reports_a_block_arrow_with_one_return() {
        assert_eq!(
            lines(RULE, "compact.ts", "export const double = (value: number): number => { return value * 2; };\n"),
            [1]
        );
    }

    #[test]
    fn keeps_the_exact_return_expression() {
        assert_eq!(
            fixed(RULE, "compact.ts", "export const double = (value: number): number => {\n  return value  * 2;\n};\n"),
            "export const double = (value: number): number => value  * 2;\n"
        );
    }

    #[test]
    fn terminates_before_an_asi_sensitive_statement() {
        assert_eq!(
            fixed(
                RULE,
                "semicolonless-member.ts",
                "declare function make(): number;\nexport const selected = () => {\n  return make()\n}\n[0];\n"
            ),
            "declare function make(): number;\nexport const selected = () => make();\n[0];\n"
        );
    }

    #[test]
    fn keeps_a_for_header_delimiter() {
        assert_eq!(
            fixed(RULE, "for-initializer.ts", "for (let callback = () => { return true }; callback(); ) break;\n"),
            "for (let callback = () => true; callback(); ) break;\n"
        );
    }

    #[test]
    fn parenthesizes_objects_and_sequences() {
        assert_eq!(
            fixed(RULE, "object.ts", "export const make = (value: number) => { return { value }; };\n"),
            "export const make = (value: number) => ({ value });\n"
        );
        assert_eq!(
            fixed(
                RULE,
                "sequence.ts",
                "declare const first: () => number;\ndeclare const second: () => number;\nexport const run = () => { return first(), second(); };\n"
            ),
            "declare const first: () => number;\ndeclare const second: () => number;\nexport const run = () => (first(), second());\n"
        );
        assert_eq!(
            fixed(
                RULE,
                "typed-object.ts",
                "export const makeReadonly = (value: number) => { return { value } as const; };\n"
            ),
            "export const makeReadonly = (value: number) => ({ value } as const);\n"
        );
    }

    #[test]
    fn parenthesizes_an_object_that_only_starts_the_expression() {
        assert_eq!(
            fixed(RULE, "object-member.ts", "export const read = () => { return { a: 1 }.a; };\n"),
            "export const read = () => ({ a: 1 }.a);\n"
        );
        assert_eq!(
            fixed(RULE, "object-call.ts", "export const keys = () => { return { a: 1 }.toString(); };\n"),
            "export const keys = () => ({ a: 1 }.toString());\n"
        );
    }

    #[test]
    fn leaves_ineligible_bodies() {
        let long = format!("very{}", "LongValue".repeat(12));
        unchanged(RULE, "bare.ts", "export const bare = (): void => { return; };\n");
        unchanged(
            RULE,
            "comment.ts",
            "export const commented = (): number => {\n  // keep this comment\n  return 1;\n};\n",
        );
        unchanged(RULE, "concise.ts", "export const concise = (): number => 1;\n");
        unchanged(RULE, "multiple.ts", "export const multiple = (): number => { const value = 1; return value; };\n");
        unchanged(
            RULE,
            "over-width.ts",
            &format!("const {long}: number = 1;\nexport const overWidth = (): number => {{\n  return {long};\n}};\n"),
        );
    }

    #[test]
    fn leaves_directive_bodies() {
        unchanged(RULE, "directive.ts", "export const strict = (): number => { \"use strict\"; return 1; };\n");
    }
}
