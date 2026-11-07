//! `meerkat-lint`: the `meerkat/*` rules for files the standalone Oxlint
//! checks. That binary has no JavaScript plugin host and skips JS plugins
//! without a word, so these rules are native, and Meerkat.app and
//! `bun run lint` run this next to it.
//!
//!     meerkat-lint [--fix] PATH...
//!
//! Directories are searched for JavaScript and TypeScript sources, skipping
//! hidden directories, `node_modules` and declaration files. Findings print
//! one per line in Oxlint's `unix` format. Exit status: 0 clean, 1 findings,
//! 2 bad arguments, an unreadable path or a fix that could not be written
//! (every other file is still checked). A file that does not parse is named
//! on stderr and skipped: Oxlint and the compiler report its errors.

mod rules;
mod source;

use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::{env, fs};

use rules::RULES;
use source::{Skip, analyze, fix, position};

const USAGE: &str = "usage: meerkat-lint [--fix] PATH...";
const EXTENSIONS: [&str; 8] = ["ts", "tsx", "mts", "cts", "js", "jsx", "mjs", "cjs"];

struct Options {
    fix: bool,
    paths: Vec<PathBuf>,
}

fn parse(arguments: impl Iterator<Item = String>) -> Result<Options, String> {
    let mut options = Options { fix: false, paths: Vec::new() };
    for argument in arguments {
        match argument.as_str() {
            "--fix" => options.fix = true,
            "-h" | "--help" => return Err(String::new()),
            flag if flag.starts_with('-') => return Err(format!("unknown option {flag}")),
            _ => options.paths.push(PathBuf::from(argument)),
        }
    }
    if options.paths.is_empty() {
        return Err("no paths given".to_owned());
    }
    Ok(options)
}

fn is_source(path: &Path) -> bool {
    let name = path.file_name().and_then(|n| n.to_str()).unwrap_or_default();
    let declaration = [".d.ts", ".d.mts", ".d.cts"].iter().any(|suffix| name.ends_with(suffix));
    !declaration && path.extension().and_then(|e| e.to_str()).is_some_and(|e| EXTENSIONS.contains(&e))
}

fn collect(path: &Path, files: &mut Vec<PathBuf>) -> std::io::Result<()> {
    if !path.is_dir() {
        files.push(path.to_owned());
        return Ok(());
    }
    let mut entries: Vec<_> = fs::read_dir(path)?.collect::<Result<_, _>>()?;
    entries.sort_by_key(fs::DirEntry::file_name);
    for entry in entries {
        let child = entry.path();
        let name = entry.file_name();
        let name = name.to_string_lossy();
        // `file_type` does not follow symlinks, so a linked directory (and a
        // link loop) is not walked.
        if entry.file_type()?.is_dir() {
            if !name.starts_with('.') && name != "node_modules" {
                collect(&child, files)?;
            }
        } else if is_source(&child) {
            files.push(child);
        }
    }
    Ok(())
}

/// Replaces `file` with `text` in one rename: a reader (the daemon compiling
/// the rules) never sees a half-written file, and a failed write leaves the
/// file as it was.
fn replace(file: &Path, text: &str) -> std::io::Result<()> {
    // A linked rule file is fixed where it lives, and the link kept.
    let file = &fs::canonicalize(file)?;
    let name = file.file_name().map(|name| name.to_string_lossy().into_owned()).unwrap_or_default();
    let temporary = file.with_file_name(format!(".{name}.meerkat-lint"));
    fs::write(&temporary, text)?;
    let result = fs::metadata(file)
        .and_then(|metadata| fs::set_permissions(&temporary, metadata.permissions()))
        .and_then(|()| fs::rename(&temporary, file));
    if result.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    result
}

fn main() -> ExitCode {
    let options = match parse(env::args().skip(1)) {
        Ok(options) => options,
        Err(message) => {
            if !message.is_empty() {
                eprintln!("meerkat-lint: {message}");
            }
            eprintln!("{USAGE}");
            return ExitCode::from(2);
        }
    };
    let mut files = Vec::new();
    for path in &options.paths {
        if let Err(error) = collect(path, &mut files) {
            eprintln!("meerkat-lint: {}: {error}", path.display());
            return ExitCode::from(2);
        }
    }

    let mut found = false;
    // A file that could not be read, or a fix that could not be written.
    let mut failed = false;
    for file in &files {
        let text = match fs::read_to_string(file) {
            Ok(text) => text,
            Err(error) => {
                eprintln!("meerkat-lint: {}: {error}", file.display());
                failed = true;
                continue;
            }
        };
        let result = if options.fix {
            fix(file, &text, &RULES).and_then(|fixed| {
                // Findings are reported against what is on disk: the fixed
                // text once written, the original if the write failed.
                let on_disk = if fixed != text
                    && let Err(error) = replace(file, &fixed)
                {
                    eprintln!("meerkat-lint: {}: {error}", file.display());
                    failed = true;
                    text
                } else {
                    fixed
                };
                analyze(file, &on_disk, &RULES).map(|findings| (on_disk, findings))
            })
        } else {
            analyze(file, &text, &RULES).map(|findings| (text, findings))
        };
        match result {
            Ok((text, mut findings)) => {
                findings.sort_by_key(|(_, finding)| finding.offset);
                for (rule, finding) in findings {
                    let (line, column) = position(&text, finding.offset);
                    println!("{}:{line}:{column}: {} [Error/meerkat({rule})]", file.display(), finding.message);
                    found = true;
                }
            }
            Err(Skip::Syntax(count)) => {
                eprintln!("meerkat-lint: {}: skipped, {count} syntax error(s)", file.display());
            }
            Err(Skip::UnknownExtension) => {
                eprintln!("meerkat-lint: {}: skipped, not JavaScript or TypeScript", file.display());
            }
        }
    }
    if failed {
        ExitCode::from(2)
    } else if found {
        ExitCode::from(1)
    } else {
        ExitCode::SUCCESS
    }
}
