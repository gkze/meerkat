//! The rule registry.

mod compact_arrow_returns;
mod compact_control_statements;
mod const_arrow_functions;
mod rule_exported;

use crate::source::{Context, Finding};

#[derive(Clone, Copy)]
pub struct Rule {
    /// Without the `meerkat/` prefix.
    pub id: &'static str,
    pub check: for<'s, 'a> fn(&Context<'s, 'a>) -> Vec<Finding>,
}

pub const RULES: [Rule; 4] = [
    Rule { id: "compact-arrow-returns", check: compact_arrow_returns::check },
    Rule { id: "compact-control-statements", check: compact_control_statements::check },
    Rule { id: "const-arrow-functions", check: const_arrow_functions::check },
    Rule { id: "rule-exported", check: rule_exported::check },
];
