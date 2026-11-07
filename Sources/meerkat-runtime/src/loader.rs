//! Serves the compiled rule modules from memory.
//!
//! Rules may import `"meerkat"` and relative paths inside the rules
//! directory: no URLs, files on disk, npm or JSR. A module the compiler
//! rejected fails to import with the compiler's reason.
//!
//! Deno's own `node:` modules import too: Deno resolves them before asking
//! this loader. They are part of the runtime, like the `Deno` global, and
//! the same file permissions and disabled ops bound them (worker.rs).

use std::collections::HashMap;
use std::sync::Arc;

use deno_core::{
    ModuleLoadOptions, ModuleLoadReferrer, ModuleLoadResponse, ModuleLoader, ModuleSource, ModuleSourceCode,
    ModuleSpecifier, ModuleType, ResolutionKind,
};
use deno_error::JsErrorBox;

/// The compiled rule set one host loads: module id (`lib/util`) to code, and
/// the ids that may not load, with why.
pub struct RuleModules {
    pub modules: HashMap<String, String>,
    pub rejected: HashMap<String, String>,
}

/// `import { rule } from "meerkat"`. The runtime puts the API in a slot that
/// rule code can read but not replace (see js/runtime.js).
const API_SPECIFIER: &str = "meerkat:api";
const API_SOURCE: &str = "const api = globalThis[Symbol.for(\"meerkat.api\")];\nexport const rule = api.rule;\n";

/// What a path segment cannot hold literally; ids stay readable in stack
/// traces otherwise.
const SEGMENT: &percent_encoding::AsciiSet = &percent_encoding::CONTROLS
    .add(b' ')
    .add(b'"')
    .add(b'#')
    .add(b'%')
    .add(b'<')
    .add(b'>')
    .add(b'?')
    .add(b'`')
    .add(b'{')
    .add(b'}')
    .add(b'\\')
    .add(b'^')
    .add(b'|');

pub fn module_specifier(id: &str) -> ModuleSpecifier {
    let encoded = percent_encoding::utf8_percent_encode(id, SEGMENT).to_string();
    ModuleSpecifier::parse(&format!("rules:///{encoded}.js")).expect("a rules: URL from encoded parts parses")
}

/// The module id of a `rules:` URL, if it is one.
fn module_id(specifier: &ModuleSpecifier) -> Option<String> {
    if specifier.scheme() != "rules" {
        return None;
    }
    let path = percent_encoding::percent_decode_str(specifier.path()).decode_utf8().ok()?;
    Some(path.strip_prefix('/')?.strip_suffix(".js")?.to_owned())
}

pub struct MemoryLoader {
    pub rules: Arc<RuleModules>,
}

impl MemoryLoader {
    /// Resolves `specifier` against the importing module's id, the way the
    /// compiler did: `.js`/`.ts` optional, a directory means its `index`.
    fn resolve_relative(&self, specifier: &str, referrer: &str) -> Result<String, JsErrorBox> {
        let referrer = ModuleSpecifier::parse(referrer)
            .ok()
            .and_then(|url| module_id(&url))
            .ok_or_else(|| JsErrorBox::type_error(format!("cannot import \"{specifier}\" from {referrer}")))?;
        let mut parts: Vec<&str> = referrer.split('/').collect();
        parts.pop();
        for part in specifier.split('/') {
            match part {
                "" | "." => {}
                ".." => {
                    if parts.pop().is_none() {
                        return Err(JsErrorBox::type_error(format!("\"{specifier}\" leaves the rules directory")));
                    }
                }
                part => parts.push(part),
            }
        }
        let mut id = parts.join("/");
        for extension in [".js", ".ts"] {
            if id.ends_with(extension) {
                id.truncate(id.len() - extension.len());
            }
        }
        let index = format!("{id}/index");
        if !self.rules.modules.contains_key(&id) && self.rules.modules.contains_key(&index) {
            id = index;
        }
        Ok(id)
    }
}

impl ModuleLoader for MemoryLoader {
    fn resolve(&self, specifier: &str, referrer: &str, _kind: ResolutionKind) -> Result<ModuleSpecifier, JsErrorBox> {
        if specifier == "meerkat" {
            return Ok(ModuleSpecifier::parse(API_SPECIFIER).expect("a valid URL"));
        }
        if specifier.starts_with("./") || specifier.starts_with("../") {
            return Ok(module_specifier(&self.resolve_relative(specifier, referrer)?));
        }
        // The runtime imports entries by their full URL.
        if let Ok(url) = ModuleSpecifier::parse(specifier)
            && module_id(&url).is_some()
        {
            return Ok(url);
        }
        Err(JsErrorBox::type_error(format!(
            "cannot import \"{specifier}\": rules may import \"meerkat\" and relative paths only"
        )))
    }

    fn load(
        &self,
        specifier: &ModuleSpecifier,
        _referrer: Option<&ModuleLoadReferrer>,
        _options: ModuleLoadOptions,
    ) -> ModuleLoadResponse {
        let source = |code: String| {
            Ok(ModuleSource::new(ModuleType::JavaScript, ModuleSourceCode::String(code.into()), specifier, None))
        };
        ModuleLoadResponse::Sync(if specifier.as_str() == API_SPECIFIER {
            source(API_SOURCE.to_owned())
        } else if let Some(id) = module_id(specifier) {
            if let Some(reason) = self.rules.rejected.get(&id) {
                Err(JsErrorBox::generic(format!("cannot load ./{id}: {reason}")))
            } else if let Some(code) = self.rules.modules.get(&id) {
                source(code.clone())
            } else {
                Err(JsErrorBox::generic(format!("cannot find module ./{id}")))
            }
        } else {
            Err(JsErrorBox::generic(format!("cannot load {specifier}")))
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn loader() -> MemoryLoader {
        let modules = ["a", "lib/util", "lib/paths/index", "with space"]
            .into_iter()
            .map(|id| (id.to_owned(), String::new()))
            .collect();
        let rejected = [("broken".to_owned(), "broken.ts has type errors".to_owned())].into_iter().collect();
        MemoryLoader { rules: Arc::new(RuleModules { modules, rejected }) }
    }

    fn resolve(specifier: &str, from: &str) -> Result<String, String> {
        loader()
            .resolve(specifier, module_specifier(from).as_str(), ResolutionKind::Import)
            .map(|url| module_id(&url).unwrap_or_else(|| url.to_string()))
            .map_err(|e| e.to_string())
    }

    #[test]
    fn resolves_like_the_compiler() {
        assert_eq!(resolve("./lib/util", "a").unwrap(), "lib/util");
        assert_eq!(resolve("./util.js", "lib/x").unwrap(), "lib/util");
        assert_eq!(resolve("../a.ts", "lib/x").unwrap(), "a");
        assert_eq!(resolve("./lib/paths", "a").unwrap(), "lib/paths/index");
        assert_eq!(resolve("./with space", "a").unwrap(), "with space");
        assert_eq!(resolve("meerkat", "a").unwrap(), "meerkat:api");
    }

    #[test]
    fn refuses_anything_outside_the_rules() {
        assert!(resolve("../x", "a").unwrap_err().contains("leaves the rules directory"));
        assert!(resolve("https://example.com/x.js", "a").unwrap_err().contains("relative paths only"));
        assert!(resolve("npm:left-pad", "a").unwrap_err().contains("relative paths only"));
    }
}
