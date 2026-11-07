//! Reports a `rule()` call from "meerkat" whose result is thrown away.
//! `rule()` returns the rule and only rules an entry file exports run, so
//! `rule({ ... });` as a statement defines nothing. The daemon rejects a file
//! that creates rules and exports none; this catches it while editing. It
//! replaces the JS rule `js/oxlint-plugin/rule-exported.ts`, since removed.
//! No fix.

use std::collections::HashSet;

use oxc::ast::AstKind;
use oxc::ast::ast::{Expression, ImportDeclarationSpecifier, ModuleExportName, Statement};

use crate::source::{Context, Finding};

const MESSAGE: &str = "rule() returns the rule; export it from a rule file to run it.";

pub fn check(context: &Context<'_, '_>) -> Vec<Finding> {
    // Local names bound to the `rule` export of "meerkat", by name only (a
    // local that shadows one still counts), as the JS rule matched them.
    let mut names = HashSet::new();
    for statement in &context.nodes().program().body {
        let Statement::ImportDeclaration(import) = statement else { continue };
        if import.source.value != "meerkat" {
            continue;
        }
        for specifier in import.specifiers.iter().flatten() {
            if let ImportDeclarationSpecifier::ImportSpecifier(it) = specifier
                && matches!(&it.imported, ModuleExportName::IdentifierName(name) if name.name == "rule")
            {
                names.insert(it.local.name.as_str());
            }
        }
    }
    if names.is_empty() {
        return Vec::new();
    }
    context
        .nodes()
        .iter()
        .filter_map(|node| {
            let AstKind::ExpressionStatement(statement) = node.kind() else { return None };
            let Expression::CallExpression(call) = &statement.expression else { return None };
            let Expression::Identifier(callee) = &call.callee else { return None };
            names.contains(callee.name.as_str()).then_some(Finding {
                message: MESSAGE,
                offset: statement.span.start,
                edit: None,
            })
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use crate::source::testing::lines;

    const RULE: &str = "rule-exported";

    #[test]
    fn reports_a_discarded_rule() {
        let source = "import { rule } from \"meerkat\";\nrule({ name: \"x\" });\n";
        assert_eq!(lines(RULE, "discarded.ts", source), [2]);
    }

    #[test]
    fn follows_an_alias() {
        let source = "import { rule as r } from \"meerkat\";\nr({ name: \"x\" });\n";
        assert_eq!(lines(RULE, "alias.ts", source), [2]);
    }

    #[test]
    fn leaves_kept_and_other_calls() {
        let cases = [
            "import { rule } from \"meerkat\";\nexport const x = rule({ name: \"x\" });\n",
            "import { rule } from \"meerkat\";\nexport const all = [rule({ name: \"x\" })];\n",
            "import * as sp from \"meerkat\";\nsp.rule({ name: \"x\" });\n",
            "import { rule } from \"elsewhere\";\nrule({ name: \"x\" });\n",
            "import { other } from \"meerkat\";\nother({ name: \"x\" });\n",
            "import { \"rule\" as r } from \"meerkat\";\nr({ name: \"x\" });\n",
        ];
        for source in cases {
            assert_eq!(lines(RULE, "kept.ts", source), Vec::<usize>::new(), "{source}");
        }
    }
}
