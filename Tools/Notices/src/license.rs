//! SPDX license expressions, as Cargo manifests declare them, and which
//! licenses a text of unknown origin carries.

use std::collections::BTreeSet;
use std::fmt;

/// A declared license, in normal form: `Any` and `All` are flat, sorted and
/// free of duplicates, so equal licenses print and count alike.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
pub enum Expr {
    License(String),
    /// `Apache-2.0 WITH LLVM-exception`.
    With(String, String),
    All(Vec<Expr>),
    Any(Vec<Expr>),
}

impl Expr {
    /// Parses SPDX syntax, and the `/` older crates write for `OR`.
    pub fn parse(text: &str) -> Result<Self, String> {
        let spaced = text.replace('(', " ( ").replace(')', " ) ").replace('/', " OR ");
        let tokens: Vec<&str> = spaced.split_whitespace().collect();
        let mut parser = Parser { tokens: &tokens, next: 0 };
        let expression = parser.any()?;
        match parser.peek() {
            None => Ok(expression),
            Some(token) => Err(format!("{text:?}: unexpected {token:?}")),
        }
    }

    pub fn all(terms: Vec<Self>) -> Self {
        Self::collect(terms, Self::All)
    }

    pub fn any(terms: Vec<Self>) -> Self {
        Self::collect(terms, Self::Any)
    }

    fn collect(terms: Vec<Self>, build: fn(Vec<Self>) -> Self) -> Self {
        let mut flat = Vec::new();
        for term in terms {
            match (term, build(Vec::new())) {
                (Self::All(inner), Self::All(_)) | (Self::Any(inner), Self::Any(_)) => flat.extend(inner),
                (other, _) => flat.push(other),
            }
        }
        flat.sort();
        flat.dedup();
        match <[Self; 1]>::try_from(flat) {
            Ok([only]) => only,
            Err(many) => build(many),
        }
    }

    /// Whether a license by this name is anywhere in the expression.
    pub fn mentions(&self, matches: fn(&str) -> bool) -> bool {
        match self {
            Self::License(name) | Self::With(name, _) => matches(name),
            Self::All(terms) | Self::Any(terms) => terms.iter().any(|term| term.mentions(matches)),
        }
    }

    /// Whether the expression lets Meerkat.app ship the component under
    /// `allowed` (cargo-deny's `[licenses] allow`): every `AND` term and one
    /// `OR` branch allowed. An exception counts only as the pair it is
    /// allowed with (`Apache-2.0 WITH LLVM-exception`), and an or-later `+`
    /// only by its own version, as cargo-deny reads them.
    pub fn allowed_by(&self, allowed: &BTreeSet<String>) -> bool {
        match self {
            Self::License(name) => allowed.contains(name.trim_end_matches('+')),
            Self::With(name, exception) => allowed.contains(&format!("{name} WITH {exception}")),
            Self::All(terms) => terms.iter().all(|term| term.allowed_by(allowed)),
            Self::Any(terms) => terms.iter().any(|term| term.allowed_by(allowed)),
        }
    }

    /// The licenses to add to `found` so that the expression is satisfied:
    /// none when one `OR` branch and every `AND` branch is covered, otherwise
    /// each license of the uncovered part. Names lose a trailing `+`.
    pub fn missing(&self, found: &BTreeSet<String>) -> BTreeSet<String> {
        let mut missing = BTreeSet::new();
        match self {
            Self::License(name) => {
                let name = name.trim_end_matches('+');
                if !found.contains(name) {
                    missing.insert(name.to_string());
                }
            }
            Self::With(name, exception) => {
                missing.extend(Self::License(name.clone()).missing(found));
                missing.extend(Self::License(exception.clone()).missing(found));
            }
            Self::All(terms) => missing.extend(terms.iter().flat_map(|term| term.missing(found))),
            Self::Any(terms) => {
                let branches: Vec<_> = terms.iter().map(|term| term.missing(found)).collect();
                if branches.iter().all(|branch| !branch.is_empty()) {
                    missing.extend(branches.into_iter().flatten());
                }
            }
        }
        missing
    }
}

impl fmt::Display for Expr {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::License(name) => formatter.write_str(name),
            Self::With(name, exception) => write!(formatter, "{name} WITH {exception}"),
            Self::Any(terms) => {
                let terms: Vec<_> = terms.iter().map(ToString::to_string).collect();
                formatter.write_str(&terms.join(" OR "))
            }
            Self::All(terms) => {
                let terms: Vec<_> = terms
                    .iter()
                    .map(|term| if matches!(term, Self::Any(_)) { format!("({term})") } else { term.to_string() })
                    .collect();
                formatter.write_str(&terms.join(" AND "))
            }
        }
    }
}

struct Parser<'a> {
    tokens: &'a [&'a str],
    next: usize,
}

impl<'a> Parser<'a> {
    fn peek(&self) -> Option<&'a str> {
        self.tokens.get(self.next).copied()
    }

    fn take(&mut self, keyword: &str) -> bool {
        let found = self.peek().is_some_and(|token| token.eq_ignore_ascii_case(keyword));
        self.next += usize::from(found);
        found
    }

    fn name(&mut self) -> Result<String, String> {
        match self.peek() {
            Some(token) if !["(", ")"].contains(&token) && !is_keyword(token) => {
                self.next += 1;
                Ok(token.to_string())
            }
            token => Err(format!("expected a license name, found {token:?}")),
        }
    }

    fn any(&mut self) -> Result<Expr, String> {
        let mut terms = vec![self.all()?];
        while self.take("OR") {
            terms.push(self.all()?);
        }
        Ok(Expr::any(terms))
    }

    fn all(&mut self) -> Result<Expr, String> {
        let mut terms = vec![self.term()?];
        while self.take("AND") {
            terms.push(self.term()?);
        }
        Ok(Expr::all(terms))
    }

    fn term(&mut self) -> Result<Expr, String> {
        if self.take("(") {
            let inner = self.any()?;
            return if self.take(")") { Ok(inner) } else { Err("unclosed parenthesis".to_string()) };
        }
        let name = self.name()?;
        if self.take("WITH") { Ok(Expr::With(name, self.name()?)) } else { Ok(Expr::License(name)) }
    }
}

fn is_keyword(token: &str) -> bool {
    ["AND", "OR", "WITH"].iter().any(|keyword| token.eq_ignore_ascii_case(keyword))
}

/// The licenses whose terms `text` contains, by phrases from their bodies,
/// so a file that merely names a license (a NOTICE saying "Licensed under
/// the Apache License, Version 2.0", or Boost's one-line file header) does
/// not count as its text. A file can hold several (aws-lc's holds most of these). Used to name
/// the license of a package that declares none, and to see whether a crate's
/// own files cover its declared expression.
pub fn identify(text: &str) -> BTreeSet<String> {
    // A text written as a source comment (untrusted's LICENSE.txt) has a
    // comment marker on every line, which would split its phrases.
    let uncommented = text.lines().map(|line| line.trim_start().trim_start_matches(['/', '#', '*']));
    let text = uncommented.flat_map(str::split_whitespace).collect::<Vec<_>>().join(" ").to_lowercase();
    let has = |phrase: &str| text.contains(phrase);
    let table = [
        ("Apache-2.0", has("apache license") && has("terms and conditions for use, reproduction, and distribution")),
        (
            "BSL-1.0",
            has("the copyright notices in the software and this entire statement, including the above license grant"),
        ),
        (
            "CC0-1.0",
            has("voluntarily elects to apply cc0 to the work and publicly distribute the work under its terms"),
        ),
        (
            "CDLA-Permissive-2.0",
            has("a data recipient may use, modify, and share the data made available by data provider(s)"),
        ),
        ("LLVM-exception", has("portions of this software are embedded into an object form of such source code")),
        (
            "MPL-2.0",
            has("mozilla public license")
                && has("means the combination of the contributions of others (if any) used by a contributor"),
        ),
        (
            "Unicode-3.0",
            has("permission is hereby granted, free of charge, to any person obtaining a copy of data files"),
        ),
        ("Unlicense", has("free and unencumbered software released into the public domain")),
        ("Zlib", has("this software is provided 'as-is'")),
        ("bzip2-1.0.6", has("bzip2") && has(BSD_GRANT)),
    ];
    let named = table.into_iter().filter(|(_, present)| *present).map(|(name, _)| name);
    named.chain(grants(&text).filter_map(permissive)).map(ToString::to_string).collect()
}

/// How the permissive licenses that differ only in their conditions begin.
const MIT_GRANT: &str = "permission is hereby granted, free of charge, to any person obtaining a copy of this software";
const ISC_GRANT: &str = "permission to use, copy, modify, and";
const BSD_GRANT: &str = "redistribution and use in source and binary forms";

/// Each permissive license block in `text`: from one grant to the next. Their
/// conditions are told apart within a block, as a file that holds several
/// would otherwise lend one license's clause to another.
fn grants(text: &str) -> impl Iterator<Item = &str> {
    let mut starts: Vec<usize> = [MIT_GRANT, ISC_GRANT, BSD_GRANT]
        .iter()
        .flat_map(|grant| text.match_indices(grant).map(|(start, _)| start))
        .collect();
    starts.sort_unstable();
    let ends = starts.iter().skip(1).copied().chain([text.len()]).collect::<Vec<_>>();
    starts.into_iter().zip(ends).map(move |(start, end)| &text[start..end])
}

/// The license of one block, by the conditions it sets before its
/// disclaimer ("the software is provided ..."), where the next text's
/// clauses cannot reach.
fn permissive(block: &str) -> Option<&'static str> {
    let terms = block.split("software is provided").next().unwrap_or(block);
    let has = |phrase: &str| terms.contains(phrase);
    if block.starts_with(MIT_GRANT) {
        Some(if has("the above copyright notice") { "MIT" } else { "MIT-0" })
    } else if let Some(rest) = block.strip_prefix(ISC_GRANT) {
        // ISC and 0BSD grant "this software"; HPND and its relatives "this
        // software and its documentation", and are neither.
        if !rest.trim_start_matches("/or").starts_with(" distribute this software for any purpose") {
            return None;
        }
        Some(if has("copyright notice") { "ISC" } else { "0BSD" })
    } else if has("all advertising materials") {
        Some("BSD-4-Clause")
    } else {
        Some(if has("neither the name") { "BSD-3-Clause" } else { "BSD-2-Clause" })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn found(names: &[&str]) -> BTreeSet<String> {
        names.iter().map(ToString::to_string).collect()
    }

    #[test]
    fn spellings_of_one_license_normalize_alike() {
        let spellings =
            ["MIT OR Apache-2.0", "Apache-2.0 OR MIT", "MIT/Apache-2.0", "Apache-2.0 / MIT", "(mit or Apache-2.0)"];
        let [first, rest @ ..] = spellings.map(|text| Expr::parse(text).map(|e| e.to_string().to_lowercase()));
        assert!(rest.iter().all(|other| *other == first), "{first:?} {rest:?}");
    }

    #[test]
    fn and_binds_tighter_than_or() {
        let expression = Expr::parse("MIT OR Apache-2.0 AND BSD-3-Clause").unwrap();
        assert_eq!(expression.to_string(), "MIT OR Apache-2.0 AND BSD-3-Clause");
    }

    #[test]
    fn prints_nested_choices_in_parentheses() {
        let expression = Expr::parse("(MIT OR Apache-2.0) AND Unicode-3.0").unwrap();
        assert_eq!(expression.to_string(), "Unicode-3.0 AND (Apache-2.0 OR MIT)");
    }

    #[test]
    fn rejects_what_is_not_an_expression() {
        for text in ["", "MIT OR", "(MIT", "MIT)", "AND MIT", "MIT WITH"] {
            assert!(Expr::parse(text).is_err(), "{text:?}");
        }
    }

    #[test]
    fn the_allow_list_takes_one_branch_and_every_term() {
        let allowed = found(&["MIT", "Apache-2.0 WITH LLVM-exception", "MPL-2.0"]);
        for text in ["MIT", "GPL-3.0 OR MIT", "MIT AND (GPL-3.0 OR MPL-2.0)", "Apache-2.0 WITH LLVM-exception"] {
            assert!(Expr::parse(text).unwrap().allowed_by(&allowed), "{text}");
        }
        for text in ["GPL-3.0", "MIT AND GPL-3.0", "Apache-2.0", "MIT WITH Classpath-exception-2.0"] {
            assert!(!Expr::parse(text).unwrap().allowed_by(&allowed), "{text}");
        }
    }

    #[test]
    fn one_branch_of_a_choice_is_enough() {
        let expression = Expr::parse("MIT OR Apache-2.0").unwrap();
        assert!(expression.missing(&found(&["MIT"])).is_empty());
        assert_eq!(expression.missing(&found(&[])), found(&["Apache-2.0", "MIT"]));
    }

    #[test]
    fn every_part_of_a_conjunction_is_needed() {
        let expression = Expr::parse("(MIT OR Apache-2.0) AND Unicode-3.0").unwrap();
        assert_eq!(expression.missing(&found(&["MIT"])), found(&["Unicode-3.0"]));
    }

    #[test]
    fn exceptions_and_or_later_resolve_to_their_texts() {
        let expression = Expr::parse("Apache-2.0 WITH LLVM-exception").unwrap();
        assert_eq!(expression.missing(&found(&["Apache-2.0"])), found(&["LLVM-exception"]));
        assert!(Expr::parse("MPL-2.0+").unwrap().missing(&found(&["MPL-2.0"])).is_empty());
    }

    #[test]
    fn mentions_sees_inside_choices() {
        let copyleft = |name: &str| name.starts_with("MPL");
        assert!(Expr::parse("MIT OR MPL-2.0+").unwrap().mentions(copyleft));
        assert!(!Expr::parse("MIT").unwrap().mentions(copyleft));
    }

    const MIT: &str = "Permission is hereby granted,\nfree of charge, to any person obtaining a copy of this software \
        ... The above copyright notice ... THE SOFTWARE IS PROVIDED \"AS IS\"";
    const MIT_0: &str = "Permission is hereby granted, free of charge, to any person obtaining a copy of this \
        software ... THE SOFTWARE IS PROVIDED \"AS IS\"";
    const ISC: &str = "Permission to use, copy, modify, and/or distribute this software for any purpose with or \
        without fee is hereby granted, provided that the above copyright notice and this permission notice appear \
        in all copies. THE SOFTWARE IS PROVIDED \"AS IS\"";
    const ZERO_BSD: &str = "Permission to use, copy, modify, and/or distribute this software for any purpose with \
        or without fee is hereby granted. THE SOFTWARE IS PROVIDED \"AS IS\"";
    const BSD: &str = "Redistribution and use in source and binary forms ... Redistributions of source code must \
        retain the above copyright notice ... THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS";

    #[test]
    fn identifies_licenses_across_line_breaks() {
        assert_eq!(identify(MIT), found(&["MIT"]));
        let mpl = "Mozilla Public License Version 2.0\n===\n1.2. \"Contributor Version\"\n    means the combination of \
            the Contributions of others (if any) used\n    by a Contributor";
        assert_eq!(identify(mpl), found(&["MPL-2.0"]));
        assert!(identify("All rights reserved.").is_empty());
    }

    #[test]
    fn tells_the_bsd_licenses_apart() {
        assert_eq!(identify(BSD), found(&["BSD-2-Clause"]));
        let three = BSD.replace("...", "... Neither the name of the copyright holder");
        assert_eq!(identify(&three), found(&["BSD-3-Clause"]));
        let four = BSD.replace("...", "... All advertising materials mentioning features");
        assert_eq!(identify(&four), found(&["BSD-4-Clause"]));
    }

    #[test]
    fn identifies_a_license_written_as_a_comment() {
        let commented = ISC.replace("for any purpose", "for any\n// purpose").replace("above", "above\n# ");
        assert_eq!(identify(&format!("// Copyright 2015 A.\n//\n// {commented}")), found(&["ISC"]));
    }

    #[test]
    fn a_mention_of_apache_is_not_its_text() {
        assert!(identify("Licensed under the Apache License, Version 2.0 (the \"License\")").is_empty());
        let text = "Apache License\nVersion 2.0, January 2004\n\
            TERMS AND CONDITIONS FOR USE, REPRODUCTION, AND DISTRIBUTION";
        assert_eq!(identify(text), found(&["Apache-2.0"]));
    }

    /// A sentence that names each license, as a README, a NOTICE or a file
    /// header does, is not that license's text.
    #[test]
    fn a_mention_of_a_license_is_not_its_text() {
        for mention in [
            "Distributed under the Boost Software License, Version 1.0.",
            "Dedicated to the public domain under CC0 1.0 (Creative Commons Zero).",
            "The data is under the Community Data License Agreement - Permissive, Version 2.0.",
            "Licensed under the Apache License v2.0 with LLVM Exceptions.",
            "This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.",
            "Licensed under the Mozilla Public License, Version 2.0.",
            "See the Unicode License V3 in LICENSE.",
        ] {
            assert!(identify(mention).is_empty(), "{mention}");
        }
    }

    #[test]
    fn identifies_each_license_by_its_body() {
        let bodies = [
            (
                "CC0-1.0",
                "the person associating CC0 with a Work (the \"Affirmer\") ... voluntarily elects to apply \
                CC0 to the Work and publicly distribute the Work under its terms",
            ),
            (
                "CDLA-Permissive-2.0",
                "1.1. A Data Recipient may use, modify, and share the Data made\navailable by \
                Data Provider(s) under this agreement",
            ),
            (
                "LLVM-exception",
                "As an exception, if, as a result of your compiling your source code, portions\nof \
                this Software are embedded into an Object form of such source code",
            ),
            (
                "Unicode-3.0",
                "UNICODE LICENSE V3 ... Permission is hereby granted, free of charge, to any person \
                obtaining a\ncopy of data files and any associated documentation",
            ),
        ];
        for (name, body) in bodies {
            assert_eq!(identify(body), found(&[name]), "{name}");
        }
    }

    #[test]
    fn grants_that_only_begin_alike_are_not_mit_or_isc() {
        let hpnd = "Permission to use, copy, modify, and distribute this software and its documentation for any \
            purpose and without fee is hereby granted, provided that the above copyright notice appear in all copies";
        assert!(identify(hpnd).is_empty());
        let boost = "Boost Software License ... Permission is hereby granted, free of charge, to any person or \
            organization obtaining a copy of the software ... The copyright notices in the Software and this entire \
            statement, including the above license grant";
        assert_eq!(identify(boost), found(&["BSL-1.0"]));
    }

    #[test]
    fn each_block_of_a_combined_file_keeps_its_own_conditions() {
        assert_eq!(identify(&format!("{ZERO_BSD}\n\n{BSD}")), found(&["0BSD", "BSD-2-Clause"]));
        assert_eq!(identify(&format!("{MIT_0}\n\n{ISC}")), found(&["ISC", "MIT-0"]));
        assert_eq!(identify(&format!("{ZERO_BSD} ... as the copyright notice")), found(&["0BSD"]));
        assert_eq!(identify(&format!("{MIT}\n{ZERO_BSD}")), found(&["0BSD", "MIT"]));
    }
}
