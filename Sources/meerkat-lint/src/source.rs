//! One parsed file and what every rule reads from it: the AST with parents
//! and scopes, the comments, and text helpers that measure lines the way
//! tsmono's JS rules do (UTF-16 code units, every ECMAScript line
//! terminator).

use std::fs;
use std::path::Path;

use oxc::allocator::Allocator;
use oxc::ast::ast::{Comment, Expression, ObjectPropertyKind};
use oxc::parser::{ParseOptions, Parser};
use oxc::semantic::{AstNodes, Scoping, Semantic, SemanticBuilder};
use oxc::span::{SourceType, Span};

use crate::rules::Rule;

/// One rule violation. `edit`, when present, rewrites the source so the
/// rule no longer applies; every rule here except `rule-exported` has one.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Finding {
    pub message: &'static str,
    /// Byte offset of the reported node, for the line and column.
    pub offset: u32,
    pub edit: Option<Edit>,
}

/// A replacement of `text[start..end]`. A rule's fix that touches two places
/// is merged into one edit over both, as `ESLint` merges a fix array, so two
/// fixes overlap exactly when `ESLint` would treat them as overlapping.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Edit {
    pub start: u32,
    pub end: u32,
    pub text: String,
}

impl Edit {
    /// Replace `[outer_start, inner_start)` with `before` and
    /// `[inner_end, outer_end)` with `after`, keeping the text between.
    pub fn around(source: &str, outer: Span, inner: Span, before: &str, after: &str) -> Self {
        let kept = &source[inner.start as usize..inner.end as usize];
        Self { start: outer.start, end: outer.end, text: format!("{before}{kept}{after}") }
    }
}

/// What Oxfmt lays a file out to, and so the compact rules: its print
/// width and one level of indent. A rules folder's `.oxfmtrc.json` starts as
/// policy/oxfmtrc.json and is the author's from then on, so a file's layout
/// is read from the `.oxfmtrc.json` nearest it, over Oxfmt's own defaults
/// as Oxfmt reads it; a file with none above it, or one that does not
/// parse, keeps to the policy.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Layout {
    pub line_width: usize,
    pub tab_width: usize,
    pub use_tabs: bool,
}

const POLICY: &str = include_str!("../policy/oxfmtrc.json");
const CONFIGURATION: &str = ".oxfmtrc.json";

/// What Oxfmt applies where a configuration says nothing.
const OXFMT_DEFAULTS: Layout = Layout { line_width: 100, tab_width: 2, use_tabs: false };

impl Layout {
    /// policy/oxfmtrc.json's layout, which its test holds it to.
    pub fn policy() -> Layout {
        OXFMT_DEFAULTS.with(POLICY).unwrap_or(OXFMT_DEFAULTS)
    }

    /// The layout for the file at `path`. A configuration that cannot be
    /// read or parsed counts as absent: Oxfmt reports it, and the rules
    /// keep to the policy meanwhile.
    pub fn of(path: &Path) -> Layout {
        let Ok(path) = std::path::absolute(path) else { return Layout::policy() };
        path.ancestors()
            .skip(1)
            .find_map(|directory| fs::read_to_string(directory.join(CONFIGURATION)).ok())
            .and_then(|text| OXFMT_DEFAULTS.with(&text))
            .unwrap_or_else(Layout::policy)
    }

    /// These options with what `configuration`, Oxfmt's JSON, sets; none
    /// when it is not a JSON object.
    fn with(mut self, configuration: &str) -> Option<Layout> {
        let allocator = Allocator::default();
        let Ok(Expression::ObjectExpression(object)) =
            Parser::new(&allocator, configuration, SourceType::default()).parse_expression()
        else {
            return None;
        };
        // A whole number as written: Oxfmt takes no other.
        let whole = |value: &Expression| match value {
            Expression::NumericLiteral(number) => number.raw.as_ref().and_then(|raw| raw.parse::<usize>().ok()),
            _ => None,
        };
        for property in &object.properties {
            let ObjectPropertyKind::ObjectProperty(property) = property else { continue };
            let key = |name: &str| property.key.is_specific_static_name(name);
            if key("printWidth") {
                self.line_width = whole(&property.value).filter(|width| *width > 0).unwrap_or(self.line_width);
            } else if key("tabWidth") {
                self.tab_width = whole(&property.value).unwrap_or(self.tab_width);
            } else if key("useTabs")
                && let Expression::BooleanLiteral(tabs) = &property.value
            {
                self.use_tabs = tabs.value;
            }
        }
        Some(self)
    }

    /// One level of indent.
    pub fn indent(&self) -> String {
        if self.use_tabs { "\t".to_owned() } else { " ".repeat(self.tab_width) }
    }

    /// Width as Oxfmt measures it against `line_width`: JavaScript's
    /// `String.length`, which tsmono's rules count, with a tab as
    /// `tab_width` columns.
    pub fn width(&self, text: &str) -> usize {
        text.encode_utf16().map(|unit| if unit == u16::from(b'\t') { self.tab_width } else { 1 }).sum()
    }
}

/// What a rule sees.
pub struct Context<'s, 'a> {
    pub text: &'a str,
    pub semantic: &'s Semantic<'a>,
    pub layout: &'s Layout,
}

impl<'a> Context<'_, 'a> {
    pub fn nodes(&self) -> &AstNodes<'a> {
        self.semantic.nodes()
    }

    pub fn scoping(&self) -> &Scoping {
        self.semantic.scoping()
    }

    pub fn slice(&self, span: Span) -> &'a str {
        &self.text[span.start as usize..span.end as usize]
    }

    fn comments(&self) -> &[Comment] {
        self.semantic.comments()
    }

    /// Any comment lying wholly inside `span`.
    pub fn has_comment_inside(&self, span: Span) -> bool {
        self.comments().iter().any(|c| c.span.start >= span.start && c.span.end <= span.end)
    }

    /// A comment that ends right before `offset`, with only whitespace between.
    pub fn has_comment_before(&self, offset: u32) -> bool {
        self.comments()
            .iter()
            .any(|c| c.span.end <= offset && self.text[c.span.end as usize..offset as usize].trim().is_empty())
    }

    /// A comment that starts right after `offset`, with only whitespace between.
    pub fn has_comment_after(&self, offset: u32) -> bool {
        self.comments()
            .iter()
            .any(|c| c.span.start >= offset && self.text[offset as usize..c.span.start as usize].trim().is_empty())
    }
}

pub const LINE_BREAKS: [char; 4] = ['\n', '\r', '\u{2028}', '\u{2029}'];

pub fn has_line_break(text: &str) -> bool {
    text.contains(LINE_BREAKS)
}

/// Start of the line `offset` is on: just past the last line terminator
/// before it.
pub fn line_start(text: &str, offset: usize) -> usize {
    text[..offset]
        .char_indices()
        .rev()
        .find(|(_, c)| LINE_BREAKS.contains(c))
        .map_or(0, |(index, c)| index + c.len_utf8())
}

/// The first line terminator at or after `offset`, or the end of the text.
pub fn line_end(text: &str, offset: usize) -> usize {
    text[offset..].find(LINE_BREAKS).map_or(text.len(), |index| offset + index)
}

/// The spaces and tabs that start the line `offset` is on.
pub fn line_indent(text: &str, offset: usize) -> &str {
    let line = &text[line_start(text, offset)..];
    &line[..line.len() - line.trim_start_matches([' ', '\t']).len()]
}

/// Why a file was not analyzed.
#[derive(Debug)]
pub enum Skip {
    UnknownExtension,
    Syntax(usize),
}

/// Parse `text` as the file at `path` and run `rules` on it, laying code out
/// to `layout`. Each finding comes with the id of the rule that made it.
pub fn analyze(path: &Path, text: &str, rules: &[Rule], layout: &Layout) -> Result<Vec<(&'static str, Finding)>, Skip> {
    let allocator = Allocator::default();
    let source_type = source_type(path).ok_or(Skip::UnknownExtension)?;
    // No ParenthesizedExpression nodes, as in the AST Oxlint gives JS
    // plugins: `return (\n  x\n);` compacts to `=> x`, not `=> (\n  x\n)`.
    let options = ParseOptions { preserve_parens: false, ..ParseOptions::default() };
    let parsed = Parser::new(&allocator, text, source_type).with_options(options).parse();
    if parsed.fatal_error || !parsed.diagnostics.is_empty() {
        return Err(Skip::Syntax(parsed.diagnostics.len().max(1)));
    }
    // Rules walk parents, so the node table is needed; oxc leaves it off by
    // default.
    let built = SemanticBuilder::new().with_build_nodes(true).build(&parsed.program);
    let context = Context { text, semantic: &built.semantic, layout };
    Ok(rules.iter().flat_map(|rule| (rule.check)(&context).into_iter().map(|finding| (rule.id, finding))).collect())
}

/// `.ts`, `.tsx`, `.js` and `.jsx` are modules only when they use module
/// syntax, as Oxlint reads them; `.mts`/`.mjs` are always modules and
/// `.cts`/`.cjs` never.
fn source_type(path: &Path) -> Option<SourceType> {
    let source_type = SourceType::from_path(path).ok()?;
    let extension = path.extension().and_then(|e| e.to_str()).unwrap_or_default();
    Some(if matches!(extension, "ts" | "tsx" | "js" | "jsx") {
        source_type.with_unambiguous(true)
    } else {
        source_type
    })
}

/// Apply the non-overlapping edits in source order. An edit that starts at
/// or before the end of the last applied one is left for the next pass, as
/// `ESLint`'s fixer does. Returns the new text and how many edits applied.
pub fn apply(text: &str, mut edits: Vec<Edit>) -> (String, usize) {
    edits.sort_by_key(|edit| (edit.start, edit.end));
    let mut output = String::with_capacity(text.len());
    let mut position = 0;
    let mut applied = 0;
    let mut last_end: Option<u32> = None;
    for edit in edits {
        if last_end.is_some_and(|end| edit.start <= end) {
            continue;
        }
        output.push_str(&text[position..edit.start as usize]);
        output.push_str(&edit.text);
        position = edit.end as usize;
        last_end = Some(edit.end);
        applied += 1;
    }
    output.push_str(&text[position..]);
    (output, applied)
}

/// Fix passes before giving up on a file that keeps producing edits.
pub const MAX_FIX_PASSES: usize = 10;

/// Apply `rules`' fixes until none apply. Returns the fixed text, or the
/// reason the file could not be analyzed.
pub fn fix(path: &Path, text: &str, rules: &[Rule], layout: &Layout) -> Result<String, Skip> {
    let mut current = text.to_owned();
    for _ in 0..MAX_FIX_PASSES {
        let edits = analyze(path, &current, rules, layout)?.into_iter().filter_map(|(_, f)| f.edit).collect();
        let (next, applied) = apply(&current, edits);
        if applied == 0 {
            break;
        }
        current = next;
    }
    Ok(current)
}

/// 1-based line and column (in characters) of `offset`.
pub fn position(text: &str, offset: u32) -> (usize, usize) {
    let before = &text[..offset as usize];
    let line = before.matches(LINE_BREAKS).count() - before.matches("\r\n").count() + 1;
    let column = before[line_start(before, before.len())..].chars().count() + 1;
    (line, column)
}

#[cfg(test)]
mod tests {
    use std::fs;

    use super::{Layout, OXFMT_DEFAULTS, POLICY};

    /// The policy sets each layout key itself, whatever it is read over.
    #[test]
    fn the_policy_is_read_from_its_file() {
        let unlike = Layout { line_width: 1, tab_width: 9, use_tabs: true };
        assert_eq!(unlike.with(POLICY), Some(Layout { line_width: 100, tab_width: 2, use_tabs: false }));
        assert_eq!(Layout::policy().indent(), "  ");
    }

    /// A rules folder's own configuration is the author's: the nearest one
    /// above the file counts, and what it leaves out is Oxfmt's default.
    #[test]
    fn a_file_is_laid_out_to_the_nearest_configuration() {
        let root = std::env::temp_dir().join(format!("meerkat-lint-layout-{}", std::process::id()));
        let nested = root.join("rules").join("lib");
        fs::create_dir_all(&nested).unwrap();
        fs::write(root.join(".oxfmtrc.json"), r#"{ "printWidth": 120, "useTabs": true, "tabWidth": 4 }"#).unwrap();
        fs::write(root.join("rules").join(".oxfmtrc.json"), r#"{ "printWidth": 80 }"#).unwrap();

        assert_eq!(Layout::of(&nested.join("x.ts")), Layout { line_width: 80, ..OXFMT_DEFAULTS });
        let top = Layout::of(&root.join("y.ts"));
        assert_eq!(top, Layout { line_width: 120, tab_width: 4, use_tabs: true });
        assert_eq!((top.indent(), top.width("\tab")), ("\t".to_owned(), 6));

        fs::write(root.join("rules").join(".oxfmtrc.json"), "not json").unwrap();
        assert_eq!(Layout::of(&nested.join("x.ts")), Layout::policy());
        fs::remove_dir_all(&root).unwrap();
    }
}

#[cfg(test)]
pub mod testing {
    //! Run one rule the way tsmono's tests do: fix to a fixed point, and list
    //! the lines it reports.

    use std::path::Path;

    use super::{Layout, analyze, fix, position};
    use crate::rules::{RULES, Rule};

    fn rule(id: &str) -> Rule {
        *RULES.iter().find(|rule| rule.id == id).expect("known rule")
    }

    pub fn fixed(id: &str, name: &str, source: &str) -> String {
        let layout = Layout::policy();
        let fixed = fix(Path::new(name), source, &[rule(id)], &layout).expect("parses");
        assert_eq!(fix(Path::new(name), &fixed, &[rule(id)], &layout).expect("parses"), fixed, "not idempotent");
        assert!(lines(id, name, &fixed).is_empty(), "fixed output still reported:\n{fixed}");
        fixed
    }

    pub fn lines(id: &str, name: &str, source: &str) -> Vec<usize> {
        let findings = analyze(Path::new(name), source, &[rule(id)], &Layout::policy()).expect("parses");
        let mut lines: Vec<usize> = findings.iter().map(|(_, f)| position(source, f.offset).0).collect();
        lines.sort_unstable();
        lines
    }

    /// The source is reported nowhere and fixing leaves it as it is.
    pub fn unchanged(id: &str, name: &str, source: &str) {
        assert_eq!(lines(id, name, source), Vec::<usize>::new(), "{name} reported");
        assert_eq!(fixed(id, name, source), source, "{name} changed");
    }
}
