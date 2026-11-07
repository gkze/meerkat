//! `notices`: writes `THIRD_PARTY_NOTICES`, the name, version, license and
//! license text of every third-party component in Meerkat.app.
//!
//!     notices MANIFEST.json OUTPUT
//!     notices bundled-crates OUTPUT.bzl CARGO.LOCK...
//!
//! MANIFEST is written by `third_party_notices` (buck2/rules/notices.bzl) from
//! what the bundle's parts depend on, with each download's fetched path.
//! Everything here is read from those downloads, so the output follows the
//! pins. Exit status: 0 written, 1 failed; a component that needs a standard
//! text the manifest lacks, a pin the manifest's tables disagree with, or a
//! license the policy does not allow without a recorded exception is a
//! failure, because the file would be wrong or the app should not ship.
//!
//! `bundled-crates` writes `Tools/Notices/bundled_crates.bzl`, the crates.io
//! packages in the Cargo.lock files of the Rust programs the app bundles
//! prebuilt (`//Tools/Notices:regenerate`); the notices fail while it differs
//! from those lockfiles.

// The output is one string built in memory, where `write!` could only add an
// unreachable error path to every line.
#![allow(clippy::format_push_string)]

mod license;

use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::path::{Path, PathBuf};
use std::process::ExitCode;

use serde::Deserialize;

use license::{Expr, identify};

/// Where the grammar container's own pins are, inside `CodeEditLanguages`.
const CONTAINER_PINS: &str = "CodeLanguages-Container/CodeLanguages-Container.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved";

/// The package that holds the prebuilt grammar container.
const CONTAINER_PACKAGE: &str = "codeeditlanguages";

/// Directories of a source archive that do not reach a binary.
const UNSHIPPED_DIRECTORIES: [&str; 11] = [
    ".github",
    "bench",
    "benches",
    "example",
    "examples",
    "fuzz",
    "node_modules",
    "target",
    "test",
    "testdata",
    "tests",
];

/// Extensions of source files that share a license file's name (`license.rs`).
const SOURCE_EXTENSIONS: [&str; 24] = [
    "am", "bzl", "c", "cc", "cmake", "cpp", "css", "go", "h", "hpp", "in", "java", "js", "json", "m", "mjs", "py",
    "rs", "s", "sh", "swift", "toml", "ts", "yml",
];

#[derive(Deserialize)]
struct Manifest {
    crates: Vec<PathBuf>,
    swift: BTreeMap<String, PathBuf>,
    npm: Vec<Npm>,
    grammars: Vec<Grammar>,
    prebuilt: Vec<Prebuilt>,
    standard: BTreeMap<String, PathBuf>,
    resolved: PathBuf,
    lockfiles: Vec<Lockfile>,
    /// `name@version` of each crates.io package in `lockfiles`, unpacked.
    bundled: BTreeMap<String, PathBuf>,
    /// cargo-deny's configuration, whose `[licenses] allow` every component
    /// is held to.
    policy: PathBuf,
    /// `name@version` of a component shipped although its license is not
    /// one `policy` allows or one this tool can name, and why.
    exceptions: BTreeMap<String, String>,
}

/// The Cargo.lock of the release a prebuilt Rust program was built from.
#[derive(Deserialize)]
struct Lockfile {
    path: PathBuf,
    /// The programs built from it, as the notes say.
    programs: String,
    /// `name@version` of the shipped components it is the lockfile of.
    tracks: Vec<String>,
}

#[derive(Deserialize)]
struct Npm {
    package: PathBuf,
    note: String,
}

#[derive(Deserialize)]
struct Grammar {
    repository: String,
    revision: String,
    texts: BTreeMap<String, PathBuf>,
}

#[derive(Deserialize)]
struct Prebuilt {
    name: String,
    version: String,
    license: String,
    source: String,
    note: String,
    /// `crate@version`: the crate this component moves with.
    tracks: Option<String>,
    texts: BTreeMap<String, PathBuf>,
}

#[derive(Deserialize)]
struct CargoManifest {
    package: CargoPackage,
}

#[derive(Deserialize)]
struct CargoPackage {
    name: String,
    version: String,
    license: Option<String>,
    repository: Option<String>,
    #[serde(default)]
    authors: Vec<String>,
}

/// Package.resolved: version 2 and later have `pins` at the top, version 1
/// (the grammar container's may be either) under `object`.
#[derive(Deserialize)]
struct Resolved {
    pins: Option<Vec<Pin>>,
    object: Option<Box<Resolved>>,
}

impl Resolved {
    fn read(path: &Path) -> Result<Vec<Pin>, String> {
        let resolved: Self = serde_json::from_slice(&read(path)?).map_err(|error| describe(path, &error))?;
        resolved
            .pins
            .or(resolved.object.and_then(|object| object.pins))
            .ok_or_else(|| format!("{}: no pins", path.display()))
    }
}

#[derive(Deserialize)]
struct Pin {
    identity: Option<String>,
    #[serde(alias = "repositoryURL")]
    location: String,
    state: PinState,
}

#[derive(Deserialize)]
struct PinState {
    revision: String,
    version: Option<String>,
}

/// What is read of a Cargo.lock: every package and where it came from.
#[derive(Deserialize)]
struct CargoLock {
    #[serde(default)]
    package: Vec<LockedPackage>,
}

#[derive(Deserialize)]
struct LockedPackage {
    name: String,
    version: String,
    /// None for the workspace's own packages, whose license is the
    /// program's.
    source: Option<String>,
    checksum: Option<String>,
}

/// Where a locked package comes from, as far as its license is concerned.
enum LockedSource {
    /// crates.io, with the archive's SHA-256.
    Registry(String),
    /// A Git repository's `<url>/tree/<revision>`, which PREBUILT must list.
    Git(String),
    Workspace,
}

impl LockedPackage {
    fn key(&self) -> String {
        format!("{}@{}", self.name, self.version)
    }

    fn origin(&self, lockfile: &Path) -> Result<LockedSource, String> {
        let Some(source) = &self.source else { return Ok(LockedSource::Workspace) };
        if source == "registry+https://github.com/rust-lang/crates.io-index" {
            let checksum = self
                .checksum
                .clone()
                .ok_or_else(|| format!("{}: {} has no checksum", lockfile.display(), self.key()))?;
            return Ok(LockedSource::Registry(checksum));
        }
        if let Some(git) = source.strip_prefix("git+")
            && let Some((location, revision)) = git.split_once('#')
        {
            let repository = location.split('?').next().unwrap_or(location).trim_end_matches(".git");
            return Ok(LockedSource::Git(format!("{repository}/tree/{revision}")));
        }
        Err(format!("{}: {} comes from {source}, which this tool cannot list", lockfile.display(), self.key()))
    }
}

/// cargo-deny's configuration, as far as the license policy goes.
#[derive(Deserialize)]
struct Policy {
    licenses: PolicyLicenses,
}

#[derive(Deserialize)]
struct PolicyLicenses {
    allow: BTreeSet<String>,
}

#[derive(Deserialize)]
struct PackageJson {
    name: String,
    version: String,
    license: Option<String>,
}

#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
enum Group {
    Prebuilt,
    Tool,
    Swift,
    Grammar,
    Crate,
}

impl Group {
    const fn title(self) -> &'static str {
        match self {
            Self::Prebuilt => "Linked prebuilt libraries and the Rust standard library",
            Self::Tool => "TypeScript tools",
            Self::Swift => "Swift packages",
            Self::Grammar => "Tree-sitter grammars in CodeLanguagesContainer.xcframework",
            Self::Crate => "Rust crates",
        }
    }
}

/// What can be said about a component's license.
enum Licensing {
    Declared(Expr),
    /// Has license files, but none this tool can name.
    Unrecognized,
    /// No license file and no declaration in what upstream published.
    Unpublished,
}

impl Licensing {
    fn label(&self) -> String {
        match self {
            Self::Declared(expression) => expression.to_string(),
            Self::Unrecognized => "not recognized (see its license files)".to_string(),
            Self::Unpublished => "no license published at this revision".to_string(),
        }
    }
}

/// A component's identity and metadata, as its package states them.
struct About {
    group: Group,
    name: String,
    version: String,
    source: String,
    repository: Option<String>,
    authors: Vec<String>,
    note: String,
}

impl About {
    const fn new(group: Group, name: String, version: String, source: String) -> Self {
        Self { group, name, version, source, repository: None, authors: Vec::new(), note: String::new() }
    }
}

struct Component {
    about: About,
    licensing: Licensing,
    /// Path inside the component, and the file's text as published.
    texts: Vec<(String, String)>,
    /// Licenses it takes from the shared standard texts.
    standard: BTreeSet<String>,
}

fn main() -> ExitCode {
    let arguments: Vec<_> = std::env::args().skip(1).collect();
    let result = match arguments.as_slice() {
        [mode, output, lockfiles @ ..] if mode == "bundled-crates" && !lockfiles.is_empty() => {
            write_bundled_crates(Path::new(output), lockfiles)
        }
        [manifest, output] => run(Path::new(manifest), Path::new(output)),
        _ => {
            eprintln!("usage: notices MANIFEST.json OUTPUT\n       notices bundled-crates OUTPUT.bzl CARGO.LOCK...");
            return ExitCode::FAILURE;
        }
    };
    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("notices: {error}");
            ExitCode::FAILURE
        }
    }
}

fn run(manifest: &Path, output: &Path) -> Result<(), String> {
    let manifest: Manifest = serde_json::from_slice(&read(manifest)?).map_err(|error| describe(manifest, &error))?;
    let mut components = collect(&manifest)?;
    let policy = String::from_utf8(read(&manifest.policy)?).map_err(|error| describe(&manifest.policy, &error))?;
    let policy: Policy = toml::from_str(&policy).map_err(|error| describe(&manifest.policy, &error))?;
    check_policy(&mut components, &policy.licenses.allow, &manifest.exceptions)?;
    let standard = standard_texts(&manifest, &components)?;
    fs::write(output, render(&components, &standard)).map_err(|error| describe(output, &error))
}

/// Fails unless every component's license is one `allowed` permits, or the
/// component is in `exceptions`, whose reason then becomes part of its
/// note. An exception that no component needs fails too, so none outlives
/// its reason: a component that publishes a license, or moves to another
/// version, has to be reviewed again.
fn check_policy(
    components: &mut [Component],
    allowed: &BTreeSet<String>,
    exceptions: &BTreeMap<String, String>,
) -> Result<(), String> {
    let mut problems = Vec::new();
    let mut used = BTreeSet::new();
    for component in components.iter_mut() {
        if matches!(&component.licensing, Licensing::Declared(expression) if expression.allowed_by(allowed)) {
            continue;
        }
        let about = &mut component.about;
        let key = format!("{}@{}", about.name, about.version);
        if let Some(reason) = exceptions.get(&key) {
            let exception = format!("Shipped by a recorded exception (EXCEPTIONS in Tools/Notices/BUCK): {reason}");
            about.note = if about.note.is_empty() { exception } else { format!("{} {exception}", about.note) };
            used.insert(key);
        } else {
            problems.push(format!("{key}: {}", component.licensing.label()));
        }
    }
    problems.extend(
        exceptions
            .keys()
            .filter(|key| !used.contains(*key))
            .map(|key| format!("{key}: an exception no component needs")),
    );
    if problems.is_empty() {
        Ok(())
    } else {
        Err(format!(
            "the license policy ([licenses] allow in buck2/third_party/rust/check/deny.toml, EXCEPTIONS in Tools/Notices/BUCK) fails:\n  {}",
            problems.join("\n  ")
        ))
    }
}

fn collect(manifest: &Manifest) -> Result<Vec<Component>, String> {
    let mut components = Vec::new();
    for directory in &manifest.crates {
        components.push(crate_component(directory)?);
    }
    let pins = Resolved::read(&manifest.resolved)?;
    for (identity, directory) in &manifest.swift {
        let pin = pins
            .iter()
            .find(|pin| pin.identity.as_ref() == Some(identity))
            .ok_or_else(|| format!("{identity}: built by Buck, not in Package.resolved"))?;
        components.push(swift_component(identity, directory, pin)?);
    }
    for package in &manifest.npm {
        components.push(npm_component(package)?);
    }
    let container = manifest
        .swift
        .get(CONTAINER_PACKAGE)
        .ok_or_else(|| format!("{CONTAINER_PACKAGE} is not in the shipped set"))?;
    check_grammars(&manifest.grammars, &Resolved::read(&container.join(CONTAINER_PINS))?)?;
    for grammar in &manifest.grammars {
        components.push(grammar_component(grammar)?);
    }
    for prebuilt in &manifest.prebuilt {
        if let Some(tracks) = &prebuilt.tracks {
            check_tracks(&components, &prebuilt.name, tracks)?;
        }
        components.push(prebuilt_component(prebuilt)?);
    }
    components.extend(bundled_components(manifest, &components)?);
    components.sort_by_key(|component| {
        let about = &component.about;
        (about.group, about.name.to_lowercase(), about.version.clone())
    });
    Ok(components)
}

/// The crates.io packages the prebuilt Rust programs were built from, which
/// are not already listed as Meerkat's own: each lockfile must be the one
/// of the program version that ships (`tracks`), every package it locks must
/// have been downloaded (`bundled`, from `bundled_crates.bzl`) and nothing
/// else, and every Git source must be a PREBUILT component.
fn bundled_components(manifest: &Manifest, listed: &[Component]) -> Result<Vec<Component>, String> {
    let mut programs: BTreeMap<String, BTreeSet<&str>> = BTreeMap::new();
    for lockfile in &manifest.lockfiles {
        for tracks in &lockfile.tracks {
            check_tracks(listed, &lockfile.programs, tracks)?;
        }
        for package in read_lockfile(&lockfile.path)? {
            match package.origin(&lockfile.path)? {
                LockedSource::Registry(_) => {
                    programs.entry(package.key()).or_default().insert(&lockfile.programs);
                }
                LockedSource::Git(source) => {
                    if !manifest.prebuilt.iter().any(|prebuilt| prebuilt.source == source) {
                        return Err(format!(
                            "{} is built from {source} ({}), which PREBUILT in Tools/Notices/BUCK does not list",
                            lockfile.programs,
                            package.key()
                        ));
                    }
                }
                LockedSource::Workspace => {}
            }
        }
    }
    let locked: BTreeSet<_> = programs.keys().collect();
    let downloaded: BTreeSet<_> = manifest.bundled.keys().collect();
    if locked != downloaded {
        let differing: Vec<_> = locked.symmetric_difference(&downloaded).map(|key| key.as_str()).collect();
        return Err(format!(
            "Tools/Notices/bundled_crates.bzl differs from the lockfiles in {}; run buck2 run //Tools/Notices:regenerate",
            differing.join(", ")
        ));
    }
    let mut components = Vec::new();
    for (key, directory) in &manifest.bundled {
        let mut component = crate_component(directory)?;
        let about = &mut component.about;
        if format!("{}@{}", about.name, about.version) != *key {
            return Err(format!("{}: is {}@{}, not {key}", directory.display(), about.name, about.version));
        }
        if listed.iter().any(|other| {
            other.about.group == Group::Crate && other.about.name == about.name && other.about.version == about.version
        }) {
            continue;
        }
        let names: Vec<_> = programs[key].iter().copied().collect();
        about.note = format!("Compiled into {}, as their release's Cargo.lock locks it.", names.join(" and "));
        components.push(component);
    }
    Ok(components)
}

fn read_lockfile(path: &Path) -> Result<Vec<LockedPackage>, String> {
    let text = String::from_utf8(read(path)?).map_err(|error| describe(path, &error))?;
    Ok(toml::from_str::<CargoLock>(&text).map_err(|error| describe(path, &error))?.package)
}

/// Writes `bundled_crates.bzl`: each crates.io package the lockfiles lock, by
/// `name@version`, with its archive's SHA-256, for Tools/Notices/BUCK to
/// download.
fn write_bundled_crates(output: &Path, lockfiles: &[String]) -> Result<(), String> {
    let mut crates = BTreeMap::new();
    for lockfile in lockfiles.iter().map(Path::new) {
        for package in read_lockfile(lockfile)? {
            if let LockedSource::Registry(checksum) = package.origin(lockfile)?
                && let Some(other) = crates.insert(package.key(), checksum.clone())
                && other != checksum
            {
                return Err(format!("{} is locked with two checksums", package.key()));
            }
        }
    }
    let mut text = String::from(
        "# @generated from the Cargo.lock files of LOCKFILES (Tools/Notices/BUCK).\n\
         # Do not edit; run: buck2 run //Tools/Notices:regenerate\n\n\
         BUNDLED_CRATES = {\n",
    );
    for (key, checksum) in &crates {
        text.push_str(&format!("    \"{key}\": \"{checksum}\",\n"));
    }
    text.push_str("}\n");
    fs::write(output, text).map_err(|error| describe(output, &error))
}

fn crate_component(directory: &Path) -> Result<Component, String> {
    let path = directory.join("Cargo.toml");
    let text = String::from_utf8(read(&path)?).map_err(|error| describe(&path, &error))?;
    let package = toml::from_str::<CargoManifest>(&text).map_err(|error| describe(&path, &error))?.package;
    let texts = license_files(directory)?;
    let licensing = match &package.license {
        Some(license) => Licensing::Declared(Expr::parse(license)?),
        None => licensing_from(&texts),
    };
    let source = format!("https://crates.io/crates/{}/{}", package.name, package.version);
    let about = About {
        repository: package.repository,
        authors: package.authors,
        ..About::new(Group::Crate, package.name, package.version, source)
    };
    Ok(finished(about, licensing, texts))
}

fn swift_component(identity: &str, directory: &Path, pin: &Pin) -> Result<Component, String> {
    let texts = license_files(directory)?;
    let url = pin.location.trim_end_matches(".git");
    let version = pin.state.version.clone().unwrap_or_else(|| pin.state.revision.chars().take(12).collect());
    let source = format!("{url}/tree/{}", pin.state.revision);
    let about = About::new(Group::Swift, identity.to_string(), version, source);
    Ok(finished(about, licensing_from(&texts), texts))
}

fn npm_component(package: &Npm) -> Result<Component, String> {
    let path = package.package.join("package.json");
    let json: PackageJson = serde_json::from_slice(&read(&path)?).map_err(|error| describe(&path, &error))?;
    let texts = license_files(&package.package)?;
    let licensing = match &json.license {
        Some(license) => Licensing::Declared(Expr::parse(license)?),
        None => licensing_from(&texts),
    };
    let source = format!("https://www.npmjs.com/package/{}/v/{}", json.name, json.version);
    let about = About { note: package.note.clone(), ..About::new(Group::Tool, json.name, json.version, source) };
    Ok(finished(about, licensing, texts))
}

fn grammar_component(grammar: &Grammar) -> Result<Component, String> {
    let texts = fetched_texts(&grammar.texts)?;
    let name = grammar.repository.rsplit('/').next().unwrap_or(&grammar.repository).to_string();
    let version = grammar.revision.chars().take(12).collect();
    let source = format!("https://github.com/{}/tree/{}", grammar.repository, grammar.revision);
    Ok(finished(About::new(Group::Grammar, name, version, source), licensing_from(&texts), texts))
}

fn prebuilt_component(prebuilt: &Prebuilt) -> Result<Component, String> {
    let about = About {
        note: prebuilt.note.clone(),
        ..About::new(Group::Prebuilt, prebuilt.name.clone(), prebuilt.version.clone(), prebuilt.source.clone())
    };
    Ok(finished(about, Licensing::Declared(Expr::parse(&prebuilt.license)?), fetched_texts(&prebuilt.texts)?))
}

/// Licenses a component takes from the shared texts: what its declaration
/// asks for that its own license files do not cover.
fn finished(about: About, licensing: Licensing, texts: Vec<(String, String)>) -> Component {
    let standard = match &licensing {
        Licensing::Declared(expression) => {
            let found = own_texts(&texts).flat_map(|(_, text)| identify(text)).collect();
            expression.missing(&found)
        }
        Licensing::Unrecognized | Licensing::Unpublished => BTreeSet::new(),
    };
    Component { about, licensing, texts, standard }
}

/// The license of a package that declares none, from its own license files.
fn licensing_from(texts: &[(String, String)]) -> Licensing {
    let root: Vec<_> = own_texts(texts).collect();
    if root.is_empty() {
        return if texts.is_empty() { Licensing::Unpublished } else { Licensing::Unrecognized };
    }
    let names: BTreeSet<_> = root.iter().flat_map(|(_, text)| identify(text)).collect();
    if names.is_empty() {
        return Licensing::Unrecognized;
    }
    let exception = names.contains("LLVM-exception") && names.contains("Apache-2.0");
    let terms = names.into_iter().filter(|name| name != "LLVM-exception").map(|name| {
        if exception && name == "Apache-2.0" {
            Expr::With(name, "LLVM-exception".to_string())
        } else {
            Expr::License(name)
        }
    });
    Licensing::Declared(Expr::all(terms.collect()))
}

/// The files that state a package's own license, both for naming it and for
/// whether they cover what it declares: those at its root and in a root
/// `LICENSES` directory. Not a NOTICE, which mentions a license without being
/// its text, and not vendored code's files, which are that code's, whether
/// in a directory of their own or gathered into a root `THIRD-PARTY-LICENSES`
/// or `LICENSE-THIRD-PARTY` file. Both are still published, as `texts`.
fn own_texts(texts: &[(String, String)]) -> impl Iterator<Item = &(String, String)> {
    texts.iter().filter(|(path, _)| {
        let own = match path.split_once('/') {
            None => true,
            Some((directory, rest)) => {
                matches!(directory.to_lowercase().as_str(), "license" | "licenses") && !rest.contains('/')
            }
        };
        let name = path.rsplit('/').next().unwrap_or(path).to_lowercase();
        own && !name.starts_with("notice") && !THIRD_PARTY.iter().any(|marker| name.contains(marker))
    })
}

/// What names the files that gather vendored code's licenses.
const THIRD_PARTY: [&str; 3] = ["third-party", "third_party", "thirdparty"];

/// License files fetched one by one, by their names upstream.
fn fetched_texts(files: &BTreeMap<String, PathBuf>) -> Result<Vec<(String, String)>, String> {
    files.iter().map(|(name, path)| Ok((name.clone(), decoded(&read(path)?)))).collect()
}

/// Every license or notice file in an unpacked source archive, by relative
/// path, sorted: the top-level ones and those of vendored code.
fn license_files(root: &Path) -> Result<Vec<(String, String)>, String> {
    let mut found = Vec::new();
    let mut pending = vec![(root.to_path_buf(), false)];
    while let Some((directory, in_licenses)) = pending.pop() {
        for entry in fs::read_dir(&directory).map_err(|error| describe(&directory, &error))? {
            let entry = entry.map_err(|error| describe(&directory, &error))?;
            let path = entry.path();
            let name = entry.file_name().to_string_lossy().to_lowercase();
            let kind = entry.file_type().map_err(|error| describe(&path, &error))?;
            if kind.is_dir() {
                if !UNSHIPPED_DIRECTORIES.contains(&name.as_str()) {
                    pending.push((path, matches!(name.as_str(), "license" | "licenses")));
                }
            } else if kind.is_file() && (in_licenses || is_license_name(&name)) {
                let relative = path.strip_prefix(root).unwrap_or(&path).to_string_lossy().to_string();
                found.push((relative, decoded(&read(&path)?)));
            }
        }
    }
    found.sort();
    Ok(found)
}

fn is_license_name(name: &str) -> bool {
    let (stem, extension) = name.rsplit_once('.').unwrap_or((name, ""));
    let prefixes = ["licen", "copying", "copyright", "notice", "unlicense"];
    prefixes.iter().chain(&THIRD_PARTY).any(|prefix| stem.starts_with(prefix))
        && !SOURCE_EXTENSIONS.contains(&extension)
}

/// A file's text: UTF-8, or else Latin-1, which some old license files are.
/// Line endings are normalized, so one text differs only in what it says.
fn decoded(bytes: &[u8]) -> String {
    let text = String::from_utf8(bytes.to_vec()).unwrap_or_else(|_| bytes.iter().copied().map(char::from).collect());
    text.replace("\r\n", "\n")
}

/// The table in Tools/Notices/BUCK against the pins the container was built
/// from, so a `CodeEditLanguages` update cannot leave a grammar out.
fn check_grammars(grammars: &[Grammar], pins: &[Pin]) -> Result<(), String> {
    let table: BTreeSet<_> =
        grammars.iter().map(|grammar| (grammar.repository.as_str(), grammar.revision.as_str())).collect();
    let pinned: BTreeSet<_> = pins
        .iter()
        .map(|pin| {
            let repository = pin.location.trim_start_matches("https://github.com/").trim_end_matches(".git");
            (repository, pin.state.revision.as_str())
        })
        .collect();
    let differing: Vec<_> =
        table.symmetric_difference(&pinned).map(|(name, revision)| format!("{name}@{revision}")).collect();
    if differing.is_empty() {
        Ok(())
    } else {
        Err(format!("GRAMMARS in Tools/Notices/BUCK differs from the container's pins: {}", differing.join(", ")))
    }
}

/// Fails unless a component `tracks` names (`name@version`; an npm scope
/// keeps its own `@`) ships.
fn check_tracks(components: &[Component], name: &str, tracks: &str) -> Result<(), String> {
    let found = tracks.rsplit_once('@').is_some_and(|(crate_name, version)| {
        components.iter().any(|component| component.about.name == crate_name && component.about.version == version)
    });
    if found {
        Ok(())
    } else {
        Err(format!("{name} is pinned for {tracks}, which does not ship; update Tools/Notices/BUCK"))
    }
}

fn standard_texts(manifest: &Manifest, components: &[Component]) -> Result<BTreeMap<String, String>, String> {
    let needed: BTreeSet<_> = components.iter().flat_map(|component| &component.standard).collect();
    let mut texts = BTreeMap::new();
    for name in needed {
        let path = manifest.standard.get(name).ok_or_else(|| {
            let users: Vec<_> =
                components.iter().filter(|c| c.standard.contains(name)).map(|c| c.about.name.as_str()).collect();
            format!(
                "no standard text for {name}, needed by {}; add it to STANDARD in Tools/Notices/BUCK",
                users.join(", ")
            )
        })?;
        texts.insert(name.clone(), decoded(&read(path)?));
    }
    Ok(texts)
}

fn render(components: &[Component], standard: &BTreeMap<String, String>) -> String {
    let mut output = header();
    render_counts(&mut output, components);
    render_unpublished(&mut output, components);
    render_source_availability(&mut output, components);
    let (numbers, by_number) = number_texts(components);
    render_components(&mut output, components, &numbers);
    section(&mut output, "Standard license texts");
    output.push_str(
        "Shared by the components above that name them. These are the SPDX License List's\ntexts, and carry no copyright holder.\n",
    );
    for (name, text) in standard {
        output.push_str(&format!("\n--- [{name}] standard text ---\n\n{}\n", text.trim_end()));
    }
    section(&mut output, "License files as published");
    output.push_str("Each distinct file appears once, numbered as the components above refer to it.\n");
    for (index, text) in by_number.iter().enumerate() {
        output.push_str(&format!("\n--- [{}] ---\n\n{}\n", index + 1, text.trim_end()));
    }
    output
}

fn section(output: &mut String, title: &str) {
    output.push_str(&format!("\n\n{0}\n{title}\n{0}\n\n", "=".repeat(78)));
}

fn header() -> String {
    "\
Third-party notices for Meerkat

Generated from the dependencies Meerkat.app is built from by
//Tools/Notices:notices.

Meerkat itself is under the MIT license (LICENSE). Meerkat.app also contains
the components below, each under its own license.

What is listed: everything that reaches the app bundle, found from Buck's
dependency graph of the bundle's parts. Build scripts, procedural macros, Swift
macros and test code are not, because they do not ship.

Licenses: as each component declares them, normalized to SPDX expressions. Swift
packages and grammars declare none, so theirs are named from their license
files. Where a component offers a choice (OR), every offered license is listed.

License texts: a component's own license and notice files, unchanged, appear
under \"License files as published\". A component that publishes none, or none
for a license it declares, refers to the shared standard text of that license
under \"Standard license texts\", together with the name, version, repository and
authors from its package metadata. The standard texts have no copyright line,
and none has been added.

Prebuilt programs: Oxlint, Oxfmt, tsrs and tsrslint are Rust programs bundled as
their releases' executables. The crates listed for them are those the
Cargo.lock of each release locks, which can include crates its executable does
not compile in. V8 is a prebuilt library; what it links is listed with it.

Policy: every component is under a license that
buck2/third_party/rust/check/deny.toml allows, except those whose note records
an exception.
"
    .to_string()
}

fn render_counts(output: &mut String, components: &[Component]) {
    section(output, "Components by license");
    let mut counts = BTreeMap::new();
    for component in components {
        *counts.entry(component.licensing.label()).or_insert(0_usize) += 1;
    }
    let mut counts: Vec<_> = counts.into_iter().collect();
    counts.sort_by(|left, right| right.1.cmp(&left.1).then_with(|| left.0.cmp(&right.0)));
    output.push_str(&format!("{} components\n\n", components.len()));
    for (label, count) in counts {
        output.push_str(&format!("{count:5}  {label}\n"));
    }
}

fn render_unpublished(output: &mut String, components: &[Component]) {
    section(output, "Components with no license published");
    output.push_str(
        "Nothing in these components' published source states a license at the revision\nused. They are listed here so that the gap is on record.\n\n",
    );
    for component in components.iter().filter(|c| matches!(c.licensing, Licensing::Unpublished)) {
        let about = &component.about;
        output.push_str(&format!(
            "{} {}: {}\n    {}\n",
            about.name,
            about.version,
            component.licensing.label(),
            about.source
        ));
    }
}

fn is_mpl(name: &str) -> bool {
    name.starts_with("MPL-")
}

fn render_source_availability(output: &mut String, components: &[Component]) {
    section(output, "Source of Mozilla Public License components");
    output.push_str(
        "These components are under the Mozilla Public License 2.0, and are used\nunmodified. Their source code is available at the addresses below.\n\n",
    );
    for component in components {
        if matches!(&component.licensing, Licensing::Declared(expression) if expression.mentions(is_mpl)) {
            output.push_str(&source_of(&component.about));
            if let Some(repository) = &component.about.repository {
                output.push_str(&format!("    repository: {repository}\n"));
            }
        }
    }
}

/// Where a component's source can be had: a crate's published archive, or
/// for the rest, which have no crate, the source they are listed with.
fn source_of(about: &About) -> String {
    let source = match about.group {
        Group::Crate => format!("https://static.crates.io/crates/{}/{}/download", about.name, about.version),
        Group::Prebuilt | Group::Tool | Group::Swift | Group::Grammar => about.source.clone(),
    };
    format!("{} {}: {source}\n", about.name, about.version)
}

/// Numbers each distinct published text in order of first use.
fn number_texts(components: &[Component]) -> (BTreeMap<&str, usize>, Vec<&str>) {
    let mut numbers = BTreeMap::new();
    let mut by_number = Vec::new();
    for (_, text) in components.iter().flat_map(|component| &component.texts) {
        numbers.entry(text.trim_end()).or_insert_with(|| {
            by_number.push(text.as_str());
            by_number.len()
        });
    }
    (numbers, by_number)
}

fn render_components(output: &mut String, components: &[Component], numbers: &BTreeMap<&str, usize>) {
    let mut group = None;
    for component in components {
        let about = &component.about;
        if group != Some(about.group) {
            group = Some(about.group);
            section(output, about.group.title());
        }
        output.push_str(&format!("{} {}\n    License: {}\n", about.name, about.version, component.licensing.label()));
        output.push_str(&format!("    Source: {}\n", about.source));
        if let Some(repository) = &about.repository {
            output.push_str(&format!("    Repository: {repository}\n"));
        }
        if !about.authors.is_empty() {
            output.push_str(&format!("    Authors: {}\n", about.authors.join(", ")));
        }
        if !about.note.is_empty() {
            output.push_str(&format!("    Note: {}\n", about.note));
        }
        let own = component.texts.iter().map(|(path, text)| format!("{path} [{}]", numbers[text.trim_end()]));
        let shared = component.standard.iter().map(|name| format!("[{name}] standard text"));
        let texts: Vec<_> = own.chain(shared).collect();
        if !texts.is_empty() {
            output.push_str(&format!("    Text: {}\n", texts.join(", ")));
        }
        output.push('\n');
    }
}

fn read(path: &Path) -> Result<Vec<u8>, String> {
    fs::read(path).map_err(|error| describe(path, &error))
}

fn describe(path: &Path, error: &dyn std::fmt::Display) -> String {
    format!("{}: {error}", path.display())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn texts(entries: &[(&str, &str)]) -> Vec<(String, String)> {
        entries.iter().map(|(path, text)| ((*path).to_string(), (*text).to_string())).collect()
    }

    const MIT: &str = "Permission is hereby granted, free of charge, to any person obtaining a copy of this \
        software ... The above copyright notice";

    fn about() -> About {
        About::new(Group::Crate, "a".to_string(), "1".to_string(), String::new())
    }

    #[test]
    fn license_names_cover_top_level_and_exclude_sources() {
        for name in
            ["license", "license-mit", "license.txt", "licence.md", "copying", "notice.txt", "copyright", "unlicense"]
        {
            assert!(is_license_name(name), "{name}");
        }
        for name in ["license.rs", "copying.c", "notice.json", "readme.md", "licensing.py"] {
            assert!(!is_license_name(name), "{name}");
        }
    }

    #[test]
    fn a_package_with_no_files_publishes_no_license() {
        assert!(matches!(licensing_from(&[]), Licensing::Unpublished));
    }

    #[test]
    fn a_license_only_in_a_vendored_directory_is_not_the_packages() {
        let vendored = texts(&[("vendor/LICENSE", MIT)]);
        assert!(matches!(licensing_from(&vendored), Licensing::Unrecognized));
    }

    #[test]
    fn a_notice_does_not_name_the_license() {
        let files = texts(&[("LICENSE", MIT), ("NOTICE.txt", "Apache License, Version 2.0")]);
        assert_eq!(licensing_from(&files).label(), "MIT");
    }

    #[test]
    fn an_unreadable_file_is_reported_as_such() {
        assert!(matches!(licensing_from(&texts(&[("LICENSE", "All rights reserved.")])), Licensing::Unrecognized));
    }

    #[test]
    fn a_crate_without_files_takes_every_declared_license_from_the_shared_texts() {
        let licensing = Licensing::Declared(Expr::parse("MIT OR Apache-2.0").unwrap());
        let component = finished(about(), licensing, vec![]);
        assert_eq!(component.standard.into_iter().collect::<Vec<_>>(), ["Apache-2.0", "MIT"]);
    }

    #[test]
    fn a_crates_own_file_replaces_the_shared_text() {
        let licensing = Licensing::Declared(Expr::parse("MIT OR Apache-2.0").unwrap());
        let files = texts(&[("LICENSE-MIT", MIT)]);
        let component = finished(about(), licensing, files);
        assert!(component.standard.is_empty());
    }

    #[test]
    fn a_notice_naming_apache_does_not_cover_it() {
        let licensing = Licensing::Declared(Expr::parse("Apache-2.0").unwrap());
        let files = texts(&[("NOTICE", "Licensed under the Apache License, Version 2.0 (the \"License\")")]);
        let component = finished(about(), licensing, files);
        assert_eq!(component.standard.into_iter().collect::<Vec<_>>(), ["Apache-2.0"]);
    }

    #[test]
    fn vendored_code_does_not_cover_the_packages_license() {
        let licensing = Licensing::Declared(Expr::parse("MIT").unwrap());
        let component = finished(about(), licensing, texts(&[("vendor/x/LICENSE", MIT)]));
        assert_eq!(component.standard.into_iter().collect::<Vec<_>>(), ["MIT"]);
    }

    #[test]
    fn a_root_third_party_file_is_vendored_codes() {
        let licensing = Licensing::Declared(Expr::parse("MIT").unwrap());
        let files =
            texts(&[("THIRD-PARTY-LICENSES.txt", MIT), ("LICENSE-THIRD-PARTY", MIT), ("LICENSES/third_party.md", MIT)]);
        let component = finished(about(), licensing, files.clone());
        assert_eq!(component.standard.into_iter().collect::<Vec<_>>(), ["MIT"]);
        assert!(matches!(licensing_from(&files), Licensing::Unrecognized));
        assert_eq!(component.texts.len(), 3);
    }

    #[test]
    fn a_root_licenses_directory_is_the_packages_own() {
        let licensing = Licensing::Declared(Expr::parse("MIT").unwrap());
        let component = finished(about(), licensing, texts(&[("LICENSES/MIT.txt", MIT)]));
        assert!(component.standard.is_empty());
    }

    #[test]
    fn only_a_crate_is_sourced_from_crates_io() {
        let about = |group| About::new(group, "a".to_string(), "1".to_string(), "https://example.com/a".to_string());
        assert_eq!(source_of(&about(Group::Crate)), "a 1: https://static.crates.io/crates/a/1/download\n");
        assert_eq!(source_of(&about(Group::Swift)), "a 1: https://example.com/a\n");
    }

    #[test]
    fn equal_texts_share_a_number() {
        let component = |text: &str| finished(about(), Licensing::Unpublished, texts(&[("LICENSE", text)]));
        let components = [component("same\n"), component("same"), component("other")];
        let (numbers, by_number) = number_texts(&components);
        assert_eq!((numbers["same"], numbers["other"], by_number.len()), (1, 2, 2));
    }

    #[test]
    fn a_license_outside_the_policy_ships_only_by_a_recorded_exception() {
        let allowed: BTreeSet<_> = ["MIT".to_string()].into();
        let unlicensed = || vec![finished(about(), Licensing::Unpublished, vec![])];
        let gpl = Licensing::Declared(Expr::parse("GPL-3.0").unwrap());
        assert!(check_policy(&mut [finished(about(), gpl, vec![])], &allowed, &BTreeMap::new()).is_err());
        assert!(check_policy(&mut unlicensed(), &allowed, &BTreeMap::new()).is_err());
        let exception: BTreeMap<_, _> = [("a@1".to_string(), "why".to_string())].into();
        let mut components = unlicensed();
        assert!(check_policy(&mut components, &allowed, &exception).is_ok());
        assert!(components[0].about.note.ends_with("why"));
        let mit = Licensing::Declared(Expr::parse("MIT").unwrap());
        let unused = check_policy(&mut [finished(about(), mit, vec![])], &allowed, &exception);
        assert!(unused.is_err_and(|error| error.contains("a@1: an exception no component needs")));
    }

    #[test]
    fn crlf_is_normalized() {
        assert_eq!(decoded(b"a\r\nb\n"), "a\nb\n");
    }

    #[test]
    fn latin1_files_decode() {
        assert_eq!(decoded(&[0x4a, 0xfc, 0x72]), "J\u{fc}r");
    }
}
