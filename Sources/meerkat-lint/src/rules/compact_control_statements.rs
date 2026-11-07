//! Removes braces from safe single-statement control blocks under the line
//! width: `if (ready) { return value; }` becomes `if (ready) return value;`.
//! Port of tsmono's `compact-control-statements`; the layout arithmetic
//! follows it step for step, so its fixtures hold unchanged.

use oxc::ast::AstKind;
use oxc::ast::ast::{BlockStatement, Statement};
use oxc::span::GetSpan;

use crate::source::{Context, Edit, Finding, LINE_WIDTH, has_line_break, line_end, line_indent, line_start, width};

const MESSAGE: &str = "Compact single-statement control block.";
const INDENT: &str = "  ";

pub fn check(context: &Context<'_, '_>) -> Vec<Finding> {
    let mut findings = Vec::new();
    for node in context.nodes().iter() {
        let AstKind::BlockStatement(block) = node.kind() else { continue };
        let parent = context.nodes().parent_kind(node.id());
        if !is_compactable(context, block, parent) {
            continue;
        }
        let Some(replacement) = replacement(context, block, parent) else { continue };
        // Offsets come from oxc spans, which are u32.
        let Ok(start) = u32::try_from(replacement.start) else { continue };
        let statement = block.body[0].span();
        findings.push(Finding {
            message: MESSAGE,
            offset: block.span.start,
            edit: Some(Edit::around(
                context.text,
                oxc::span::Span::new(start, block.span.end),
                statement,
                &replacement.prefix,
                replacement.suffix,
            )),
        });
    }
    findings
}

struct Replacement {
    prefix: String,
    start: usize,
    suffix: &'static str,
    text: String,
}

fn is_directly_controlled(block: &BlockStatement<'_>, parent: AstKind<'_>) -> bool {
    let is_block = |statement: &Statement<'_>| statement.span() == block.span;
    match parent {
        AstKind::IfStatement(it) => is_block(&it.consequent) || it.alternate.as_ref().is_some_and(is_block),
        AstKind::DoWhileStatement(it) => is_block(&it.body),
        AstKind::ForInStatement(it) => is_block(&it.body),
        AstKind::ForOfStatement(it) => is_block(&it.body),
        AstKind::ForStatement(it) => is_block(&it.body),
        AstKind::WhileStatement(it) => is_block(&it.body),
        _ => false,
    }
}

fn is_compactable(context: &Context<'_, '_>, block: &BlockStatement<'_>, parent: AstKind<'_>) -> bool {
    block.body.len() == 1
        && matches!(
            block.body[0],
            Statement::BreakStatement(_)
                | Statement::ContinueStatement(_)
                | Statement::DebuggerStatement(_)
                | Statement::ExpressionStatement(_)
                | Statement::ReturnStatement(_)
                | Statement::ThrowStatement(_)
        )
        && is_directly_controlled(block, parent)
        && !context.has_comment_inside(parent.span())
}

fn is_alternate(block: &BlockStatement<'_>, parent: AstKind<'_>) -> bool {
    matches!(parent, AstKind::IfStatement(it) if it.alternate.as_ref().is_some_and(|a| a.span() == block.span))
}

/// Where the header that controls `block` starts: the `else` keyword for an
/// alternate, the statement otherwise.
fn header_start(context: &Context<'_, '_>, block: &BlockStatement<'_>, parent: AstKind<'_>) -> usize {
    let parent_start = parent.span().start as usize;
    if !is_alternate(block, parent) {
        return parent_start;
    }
    let before = context.text[..block.span.start as usize].trim_end();
    if before.ends_with("else") { before.len() - "else".len() } else { parent_start }
}

fn replacement(context: &Context<'_, '_>, block: &BlockStatement<'_>, parent: AstKind<'_>) -> Option<Replacement> {
    let statement = block.body.first()?;
    let text = context.text;
    let block_start = block.span.start as usize;
    let block_end = block.span.end as usize;
    let replacement_start = text[..block_start].trim_end_matches([' ', '\t']).len();
    let header = header_start(context, block, parent);
    let statement_text = context.slice(statement.span());
    let suffix = if statement_text.ends_with(';') { "" } else { ";" };
    let terminated = format!("{statement_text}{suffix}");
    let inline = format!(" {terminated}");
    let line_suffix = &text[block_end..line_end(text, block_end)];
    let header_line_start = line_start(text, header);
    let mut prefix = text[header_line_start..replacement_start].to_owned();
    let mut relative_header = header - header_line_start;

    // The alternate's line also holds the consequent, which this pass
    // compacts too: measure against the consequent's compacted text.
    if let AstKind::IfStatement(it) = parent
        && is_alternate(block, parent)
        && let Statement::BlockStatement(consequent) = &it.consequent
        && is_compactable(context, consequent, parent)
        && let Some(compacted) = replacement(context, consequent, parent)
    {
        let consequent_end = consequent.span.end as usize;
        let before = &text[line_start(text, compacted.start)..compacted.start];
        prefix = format!("{before}{}{}", compacted.text, &text[consequent_end..replacement_start]);
        relative_header = before.len() + compacted.text.len() + header - consequent_end;
    }

    let prefix_line_start = line_start(&prefix, prefix.len());
    let inline_width = width(&prefix[prefix_line_start..]) + width(&inline) + width(line_suffix);
    if !has_line_break(&prefix[relative_header..]) && !has_line_break(statement_text) && inline_width <= LINE_WIDTH {
        return Some(Replacement { prefix: " ".to_owned(), start: replacement_start, suffix, text: inline });
    }

    let separator = if prefix.len() == prefix_line_start { "" } else { "\n" };
    let indent = format!("{}{INDENT}", line_indent(&prefix, relative_header));
    let last_line = &terminated[line_start(statement_text, statement_text.len())..];
    if width(&indent) + width(last_line) + width(line_suffix) > LINE_WIDTH {
        return None;
    }
    let continuation = format!("{separator}{indent}");
    Some(Replacement {
        text: format!("{continuation}{terminated}"),
        prefix: continuation,
        start: replacement_start,
        suffix,
    })
}

#[cfg(test)]
mod tests {
    use crate::source::testing::{fixed, lines, unchanged};

    const RULE: &str = "compact-control-statements";

    #[test]
    fn reports_a_single_statement_if() {
        assert_eq!(lines(RULE, "if.ts", "if (true) {\n  console.log(\"ready\");\n}\n"), [1]);
    }

    #[test]
    fn compacts_inline() {
        assert_eq!(
            fixed(RULE, "if.ts", "if (true) {\n  console.log(\"ready\");\n}\n"),
            "if (true) console.log(\"ready\");\n"
        );
    }

    #[test]
    fn terminates_a_semicolonless_statement() {
        let head = "declare const ready: boolean;\ndeclare function act(): void;\ndeclare function use(value: number): void;\n";
        assert_eq!(
            fixed(
                RULE,
                "semicolonless-next-line.ts",
                &format!("{head}if (ready) {{\n  act()\n}}\n[1].forEach(use);\n")
            ),
            format!("{head}if (ready) act();\n[1].forEach(use);\n")
        );
    }

    #[test]
    fn covers_every_control_and_statement_kind() {
        let cases = [
            ("break.ts", "for (;;) {\n  break;\n}\n", "for (;;) break;\n"),
            ("continue.ts", "for (const value of []) {\n  continue;\n}\n", "for (const value of []) continue;\n"),
            ("debugger.ts", "while (false) {\n  debugger;\n}\n", "while (false) debugger;\n"),
            (
                "expression.ts",
                "for (const key in {}) {\n  console.log(key);\n}\n",
                "for (const key in {}) console.log(key);\n",
            ),
            (
                "if-else.ts",
                "if (true) {\n  console.log(\"then\");\n} else {\n  console.log(\"else\");\n}\n",
                "if (true) console.log(\"then\"); else console.log(\"else\");\n",
            ),
            (
                "return.ts",
                "const value = (() => {\n  if (true) {\n    return 1;\n  }\n  return 0;\n})();\n",
                "const value = (() => {\n  if (true) return 1;\n  return 0;\n})();\n",
            ),
            (
                "throw.ts",
                "do {\n  throw new Error(\"stop\");\n} while (false);\n",
                "do throw new Error(\"stop\"); while (false);\n",
            ),
        ];
        for (name, source, expected) in cases {
            assert_eq!(fixed(RULE, name, source), expected, "{name}");
        }
    }

    #[test]
    fn continues_on_an_indented_line_when_inline_does_not_fit() {
        let call = "performOperationWithDescriptiveArguments(firstArgument, secondArgument, thirdArgument);";
        let cases = [
            (
                "over-width.ts",
                format!("if (conditionWithADescriptiveName) {{\n  {call}\n}}\n"),
                format!("if (conditionWithADescriptiveName)\n  {call}\n"),
            ),
            (
                "multiline-header.ts",
                "if (\n  firstCondition &&\n  secondCondition\n) {\n  console.log(\"ready\");\n}\n".to_owned(),
                "if (\n  firstCondition &&\n  secondCondition\n)\n  console.log(\"ready\");\n".to_owned(),
            ),
            (
                "multiline-statement.ts",
                "if (true) {\n  console.log(\n    \"ready\",\n  );\n}\n".to_owned(),
                "if (true)\n  console.log(\n    \"ready\",\n  );\n".to_owned(),
            ),
            (
                "nested.ts",
                format!("while (true) {{\n  if (conditionWithADescriptiveName) {{\n    {call}\n  }}\n}}\n"),
                format!("while (true) {{\n  if (conditionWithADescriptiveName)\n    {call}\n}}\n"),
            ),
            (
                "next-line-block.ts",
                "if (true)\n{\n  console.log(\"ready\");\n}\n".to_owned(),
                "if (true)\n  console.log(\"ready\");\n".to_owned(),
            ),
            (
                "over-width-else.ts",
                format!("if (true) {{\n  console.log(\"then\");\n}} else {{\n  {call}\n}}\n"),
                format!("if (true) console.log(\"then\"); else\n  {call}\n"),
            ),
        ];
        for (name, source, expected) in cases {
            assert_eq!(fixed(RULE, name, &source), expected, "{name}");
        }
    }

    #[test]
    fn recognizes_every_line_terminator() {
        for (name, brk) in
            [("carriage-return.ts", "\r"), ("line-separator.ts", "\u{2028}"), ("paragraph-separator.ts", "\u{2029}")]
        {
            let source = format!(
                "while (true) {{{brk}  if ({brk}    firstCondition &&{brk}    secondCondition{brk}  ) {{{brk}    console.log(\"ready\");{brk}  }}{brk}}}{brk}"
            );
            let expected = format!(
                "while (true) {{{brk}  if ({brk}    firstCondition &&{brk}    secondCondition{brk}  )\n    console.log(\"ready\");{brk}}}{brk}"
            );
            assert_eq!(fixed(RULE, name, &source), expected, "{name}");
        }
    }

    #[test]
    fn leaves_comments_and_unsafe_blocks() {
        let cases = [
            ("comment-inside.ts", "if (true) {\n  // retain this comment\n  console.log(\"ready\");\n}\n"),
            ("comment-before-block.ts", "if (true) /* retain this comment */ {\n  console.log(\"ready\");\n}\n"),
            (
                "comment-between-branches.ts",
                "if (true) {\n  console.log(\"then\");\n} /* retain this comment */ else {\n  console.log(\"else\");\n}\n",
            ),
            ("empty.ts", "if (true) {}\n"),
            ("multiple.ts", "if (true) {\n  console.log(\"first\");\n  console.log(\"second\");\n}\n"),
            ("declaration.ts", "if (true) {\n  const value = 1;\n}\n"),
            ("nested-flow.ts", "while (true) {\n  if (ready) break;\n}\n"),
            ("dangling-else.ts", "if (outer) {\n  if (inner) action();\n} else fallback();\n"),
            ("standalone.ts", "{\n  console.log(\"ready\");\n}\n"),
            ("try.ts", "try {\n  console.log(\"ready\");\n} finally {\n  console.log(\"done\");\n}\n"),
            (
                "over-width-suffix.ts",
                "do {\n  performOperation();\n} while (conditionWithAnExtremelyDescriptiveNameThatNearlyFillsTheConfiguredSourceLineWidth);\n",
            ),
        ];
        for (name, source) in cases {
            unchanged(RULE, name, source);
        }
    }
}
