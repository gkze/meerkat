//! `meerkat-runtime-bindgen`: writes the Swift side of what meerkatd's Rust
//! exports (the runtime's host protocol) from the UniFFI metadata in the
//! static library meerkatd links, or checks that the checked-in copy is
//! current.
//!
//!     meerkat-runtime-bindgen [--check] LIBRARY
//!
//! Buck's targets pass LIBRARY (`//Sources/meerkat-runtime:meerkat_runtime[staticlib]`).
//! The outputs are `OUTPUTS` below: a C header and a Swift file, in
//! `Sources/meerkat-runtime`.
//! Exit status: 0 written or current, 1 stale (`--check`), 2 failed.

use std::path::{Path, PathBuf};
use std::process::ExitCode;

use camino::Utf8PathBuf;
use uniffi::deps::anyhow::{Result, anyhow};
use uniffi_bindgen::bindings::{SwiftBindingsOptions, generate_swift_bindings};

/// Generated file name to where it is checked in, relative to the repository.
const OUTPUTS: [(&str, &str); 2] = [
    ("meerkat_runtime.h", "Sources/meerkat-runtime/CMeerkatRuntime/include/meerkat_runtime.h"),
    ("MeerkatRuntimeBindings.swift", "Sources/meerkat-runtime/MeerkatRuntimeBindings/MeerkatRuntimeBindings.swift"),
];

const USAGE: &str = "usage: meerkat-runtime-bindgen [--check] LIBRARY";

fn repository() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../..")
}

fn main() -> ExitCode {
    let mut check = false;
    let mut library = None;
    for argument in std::env::args().skip(1) {
        match argument.as_str() {
            "--check" => check = true,
            _ if library.is_none() && !argument.starts_with('-') => library = Some(PathBuf::from(argument)),
            _ => {
                eprintln!("{USAGE}");
                return ExitCode::from(2);
            }
        }
    }
    let Some(library) = library else {
        eprintln!("{USAGE}");
        return ExitCode::from(2);
    };
    match run(&library, check) {
        Ok(stale) if stale.is_empty() => ExitCode::SUCCESS,
        Ok(stale) => {
            for path in stale {
                eprintln!("{path} is stale; regenerate with: buck2 run //Sources/meerkat-runtime/bindgen:regenerate");
            }
            ExitCode::from(1)
        }
        Err(error) => {
            eprintln!("meerkat-runtime-bindgen: {error:#}");
            ExitCode::from(2)
        }
    }
}

/// Generates into a scratch directory, then writes each output or, with
/// `check`, returns the ones that differ.
fn run(library: &Path, check: bool) -> Result<Vec<&'static str>> {
    let scratch = std::env::temp_dir().join(format!("meerkat-runtime-bindgen-{}", std::process::id()));
    let utf8 =
        |path: PathBuf| Utf8PathBuf::from_path_buf(path).map_err(|path| anyhow!("not UTF-8: {}", path.display()));
    let generated = generate_swift_bindings(SwiftBindingsOptions {
        generate_swift_sources: true,
        generate_headers: true,
        source: utf8(library.to_path_buf())?,
        out_dir: utf8(scratch.clone())?,
        config: Some(utf8(Path::new(env!("CARGO_MANIFEST_DIR")).join("uniffi.toml"))?),
        ..Default::default()
    });
    let result = generated.and_then(|()| {
        let mut stale = Vec::new();
        for (name, destination) in OUTPUTS {
            let text = std::fs::read_to_string(scratch.join(name))?;
            // `buck2 run //:fix` formats Sources/ recursively; generated Swift
            // must stay as UniFFI wrote it, or the staleness check fails.
            let swift = Path::new(name).extension().is_some_and(|extension| extension.eq_ignore_ascii_case("swift"));
            let text = if swift { format!("// swift-format-ignore-file\n{text}") } else { text };
            let path = repository().join(destination);
            if std::fs::read_to_string(&path).ok().as_deref() == Some(text.as_str()) {
                continue;
            }
            if check {
                stale.push(destination);
            } else {
                std::fs::create_dir_all(path.parent().expect("a file in a directory"))?;
                std::fs::write(&path, text)?;
            }
        }
        Ok(stale)
    });
    let _ = std::fs::remove_dir_all(&scratch);
    result
}
