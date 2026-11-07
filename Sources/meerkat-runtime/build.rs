//! Composes the TypeScript declarations of the globals rule code runs with,
//! as `deno types` does for the Deno release the runtime embeds, into
//! `$OUT_DIR/deno.d.ts`, which lib.rs embeds and exports.
//!
//! The libraries in types/deno/ are Deno's `cli/tsc/dts/` at `DENO_VERSION`,
//! fetched unchanged by Sources/meerkat-runtime/BUCK, which owns the version
//! and each file's hash. They are written for Deno's own TypeScript, so two
//! things are changed, on the parsed source: references to libraries
//! rule code gets elsewhere are removed, and the Node types the libraries
//! name are replaced. Anything else Node-specific fails the build here rather
//! than in a rule. types/timers.d.ts is appended: the timers Deno declares
//! only in its Node types.

use std::fs;
use std::ops::Range;
use std::path::{Path, PathBuf};

use deno_ast::swc::ast::{TsEntityName, TsImportType};
use deno_ast::swc::common::comments::Comment;
use deno_ast::swc::ecma_visit::{Visit, VisitWith};
use deno_ast::{MediaType, ModuleSpecifier, ParseParams, SourceRangedForSpanned, StartSourcePos, TextChange};

/// Where types/deno/ is from: this Deno release, which the runtime reports as
/// `Deno.version.deno`.
const DENO_VERSION: &str = env!("DENO_VERSION");

/// The `deno_runtime` that release is built on (its Cargo.toml). A test in
/// worker.rs fails when the linked `deno_runtime` is another one, so the pin
/// in buck2/third_party/rust/Cargo.toml cannot move without `DENO_VERSION`.
const DENO_RUNTIME_VERSION: &str = "0.268.0";

/// What `deno types` joins (`tsc::get_types_declaration_file_text` in the
/// `deno` crate), in its order: each library's name and its file. It also
/// joins `esnext.temporal`, TypeScript's own Temporal library, which is left
/// out because TypeScript 7's `esnext` declares it.
const LIBRARIES: [(&str, &str); 16] = [
    ("deno.ns", "lib.deno.ns.d.ts"),
    ("deno.console", "lib.deno_console.d.ts"),
    ("deno.url", "lib.deno_url.d.ts"),
    ("deno.web", "lib.deno_web.d.ts"),
    ("deno.fetch", "lib.deno_fetch.d.ts"),
    ("deno.webgpu", "lib.deno_webgpu.d.ts"),
    ("deno.websocket", "lib.deno_websocket.d.ts"),
    ("deno.webstorage", "lib.deno_webstorage.d.ts"),
    ("deno.canvas", "lib.deno_canvas.d.ts"),
    ("deno.crypto", "lib.deno_crypto.d.ts"),
    ("deno.broadcast_channel", "lib.deno_broadcast_channel.d.ts"),
    ("deno.net", "lib.deno_net.d.ts"),
    ("deno.shared_globals", "lib.deno.shared_globals.d.ts"),
    ("deno.cache", "lib.deno_cache.d.ts"),
    ("deno.window", "lib.deno.window.d.ts"),
    ("deno.unstable", "lib.deno.unstable.d.ts"),
];

/// Node's types, which rule code does not get: timers.d.ts declares the part
/// of them the runtime provides.
const NODE_LIBRARY: &str = "node";

/// The Node types the libraries name, each replaced with `unknown`: the
/// socket of `Deno.serve`'s upgrade event, which rule code cannot listen for.
const OPAQUE_NODE_TYPES: [(&str, &str); 1] = [("node:net", "Socket")];

fn main() {
    let root = PathBuf::from(std::env::var("CARGO_MANIFEST_DIR").expect("CARGO_MANIFEST_DIR is set")).join("types");
    println!("cargo::rerun-if-changed={}", root.display());
    println!("cargo::rustc-env=DENO_VERSION={DENO_VERSION}");
    println!("cargo::rustc-env=DENO_RUNTIME_VERSION={DENO_RUNTIME_VERSION}");

    let mut composed = format!(
        "// Deno {DENO_VERSION}'s declarations of the globals rule code runs with, composed by\n\
         // Sources/meerkat-runtime/build.rs from Sources/meerkat-runtime/types/. Do not edit.\n\n"
    );
    let mut replaced = Vec::new();
    for (_, file) in LIBRARIES {
        composed += &library(&root.join("deno").join(file), &mut replaced);
        composed.push('\n');
    }
    for opaque in OPAQUE_NODE_TYPES {
        assert!(replaced.contains(&opaque), "no library names {opaque:?} any more; remove it from OPAQUE_NODE_TYPES");
    }
    composed += &read(&root.join("timers.d.ts"));

    let out = PathBuf::from(std::env::var_os("OUT_DIR").expect("cargo sets OUT_DIR"));
    fs::write(out.join("deno.d.ts"), composed).expect("writing deno.d.ts");
}

/// One library, with its references and Node types changed. `replaced`
/// collects the Node types it replaced.
fn library(path: &Path, replaced: &mut Vec<(&'static str, &'static str)>) -> String {
    let file = path.file_name().unwrap().to_string_lossy();
    let parsed = deno_ast::parse_module(ParseParams {
        specifier: ModuleSpecifier::parse(&format!("file:///{file}")).unwrap(),
        text: read(path).into(),
        media_type: MediaType::Dts,
        capture_tokens: false,
        scope_analysis: false,
        maybe_syntax: None,
    })
    .unwrap_or_else(|error| panic!("{file}: {error}"));
    let text = parsed.text();
    let start = parsed.range().start;

    let mut changes = Vec::new();
    // TypeScript reads reference directives only before the first statement.
    let program = parsed.program_ref();
    let module = program.unwrap_module();
    let header_end = module.body.first().map_or(text.len(), |item| byte_range(item, start).start);
    for comment in parsed.comments().get_vec() {
        let range = byte_range(&comment, start);
        if range.end > header_end {
            break;
        }
        let Some(library) = referenced_library(&comment) else { continue };
        let composed = LIBRARIES.iter().any(|(name, _)| *name == library);
        if !composed && library != NODE_LIBRARY {
            assert!(!library.starts_with("deno."), "{file} references {library}, which LIBRARIES does not compose");
            // One of TypeScript's own libraries.
            continue;
        }
        // The directive's whole line.
        let end = range.end + usize::from(text[range.end..].starts_with('\n'));
        changes.push(TextChange { range: range.start..end, new_text: String::new() });
    }

    let mut imports = NodeImportTypes { start, found: Vec::new() };
    module.visit_with(&mut imports);
    for (specifier, qualifier, range) in imports.found {
        let name = (specifier.as_str(), qualifier.as_str());
        let opaque = OPAQUE_NODE_TYPES
            .into_iter()
            .find(|opaque| *opaque == name)
            .unwrap_or_else(|| panic!("{file} names Node's {name:?}, which OPAQUE_NODE_TYPES does not replace"));
        replaced.push(opaque);
        changes.push(TextChange { range, new_text: "unknown".into() });
    }

    deno_ast::apply_text_changes(text, changes)
}

/// The library a `/// <reference lib="…" />` directive names; None for any
/// other comment, including other reference directives.
fn referenced_library(comment: &Comment) -> Option<&str> {
    let directive = comment.text.strip_prefix('/')?.trim();
    let attribute = directive.strip_prefix("<reference")?.strip_suffix("/>")?.trim();
    attribute.strip_prefix("lib=\"")?.strip_suffix('"')
}

/// `import("node:…").Name` types: the specifier, the name and the byte range.
struct NodeImportTypes {
    start: StartSourcePos,
    found: Vec<(String, String, Range<usize>)>,
}

impl Visit for NodeImportTypes {
    fn visit_ts_import_type(&mut self, import: &TsImportType) {
        let specifier = import.arg.value.to_atom_lossy();
        if !specifier.starts_with("node:") {
            return;
        }
        let Some(TsEntityName::Ident(name)) = &import.qualifier else {
            panic!("import(\"{specifier}\") without a plain name: {:?}", import.qualifier);
        };
        self.found.push((specifier.to_string(), name.sym.to_string(), byte_range(import, self.start)));
    }
}

fn byte_range(node: &impl SourceRangedForSpanned, start: StartSourcePos) -> Range<usize> {
    node.range().as_byte_range(start)
}

fn read(path: &Path) -> String {
    fs::read_to_string(path).unwrap_or_else(|error| panic!("{}: {error}", path.display()))
}
