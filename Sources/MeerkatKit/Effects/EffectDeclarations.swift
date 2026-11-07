import Foundation

/// Renders the effect catalog as the `Grants` interface and the `Context`
/// type in the generated `meerkat` module. The request and result
/// interfaces the effects name are declared with the event payloads
/// (`TypeScriptDeclarations`).
enum EffectDeclarations {
    static func lines(_ catalog: EffectCatalog) -> [String] {
        var lines = ["/** What a rule may do. The daemon refuses any effect not granted here. */"]
        lines.append("export interface Grants {")
        lines += render(grantTree(catalog.grants), indent: "  ")
        lines.append("}")
        lines.append("")

        // One property per top-level `ctx` name, each the intersection of
        // its grants' parts (at most a few), and a mapped type that drops the
        // properties no grant gives. A flat intersection of one conditional
        // per grant is simpler, but past about 16 of them TypeScript gives up
        // inferring a rule's grants (TS2590, "union type that is too complex").
        var keys: [(String, [EffectDescriptor])] = []
        for effect in catalog.effects {
            let name = effect.method[0]
            if let index = keys.firstIndex(where: { $0.0 == name }) {
                keys[index].1.append(effect)
            } else {
                keys.append((name, [effect]))
            }
        }
        lines.append("/** Every effect method by its top-level `ctx` name; `{}` where `G` grants none. */")
        lines.append("export interface ContextEffects<G extends Grants> {")
        for (name, effects) in keys {
            var parts: [String] = []
            var groups: [(String?, [EffectDescriptor])] = []
            for effect in effects {
                let key = effect.grant.grantKey
                if let index = groups.firstIndex(where: { $0.0 == key }) {
                    groups[index].1.append(effect)
                } else {
                    groups.append((key, [effect]))
                }
            }
            for (key, grouped) in groups {
                let object = valueType(name, grouped, indent: "  ")
                if let key, let grant = catalog.grant(key) {
                    parts.append("(G extends \(condition(grant)) ? \(object) : {})")
                } else {
                    parts.append(object)
                }
            }
            lines += "  \(name): \(parts.joined(separator: "\n    & "));".split(separator: "\n").map(String.init)
        }
        lines.append("}")
        lines.append("")
        lines.append("/**")
        lines.append(" * The handler's context: `BaseContext` and the effects its grants allow.")
        lines.append(" * Effects work only while this handler invocation runs: a context kept and")
        lines.append(" * used later, from a timer or a stored reference, is refused.")
        lines.append(" */")
        lines.append("export type Context<G extends Grants> = BaseContext & {")
        lines.append(
            "  [K in keyof ContextEffects<G> as {} extends ContextEffects<G>[K] ? never : K]: ContextEffects<G>[K];")
        lines.append("}")
        return lines
    }

    // MARK: Grants

    private final class GrantNode {
        var grant: GrantDescriptor?
        var children: [(String, GrantNode)] = []

        func child(_ name: String) -> GrantNode {
            if let existing = children.first(where: { $0.0 == name }) { return existing.1 }
            let node = GrantNode()
            children.append((name, node))
            return node
        }
    }

    private static func grantTree(_ grants: [GrantDescriptor]) -> GrantNode {
        let root = GrantNode()
        for grant in grants {
            var node = root
            for name in grant.path { node = node.child(name) }
            precondition(node.grant == nil && node.children.isEmpty, "grant \(grant.key) declared twice or nested")
            node.grant = grant
        }
        return root
    }

    private static func render(_ node: GrantNode, indent: String) -> [String] {
        node.children.flatMap { name, child -> [String] in
            if let grant = child.grant {
                return ["\(indent)/** \(escaped(grant.doc)) */", "\(indent)\(name)?: \(leafType(grant.shape));"]
            }
            return ["\(indent)\(name)?: {"] + render(child, indent: indent + "  ") + ["\(indent)};"]
        }
    }

    private static func leafType(_ shape: GrantDescriptor.Shape) -> String {
        switch shape {
        case .flag: "boolean"
        // `NamedEvent` is generated with the event catalog
        // (`TypeScriptDeclarations`), so a misspelt kind is a type error.
        case .allowList(.eventKind): "{ allow: readonly NamedEvent[] }"
        case .allowList: "{ allow: readonly string[] }"
        case .pathList: "readonly string[]"
        case .level(let levels): levels.map { "\"\($0)\"" }.joined(separator: " | ")
        }
    }

    /// The type a rule's `G` extends when the grant is given; also what
    /// `EventObservation` requires of a kind's observers.
    static func condition(_ grant: GrantDescriptor) -> String {
        let leaf: String =
            switch grant.shape {
            case .flag: "true"
            case .allowList, .pathList, .level: leafType(grant.shape)
            }
        return grant.path.reversed().reduce(leaf) { inner, name in "{ \(name): \(inner) }" }
    }

    // MARK: Methods

    private final class MethodNode {
        var effect: EffectDescriptor?
        var children: [(String, MethodNode)] = []

        func child(_ name: String) -> MethodNode {
            if let existing = children.first(where: { $0.0 == name }) { return existing.1 }
            let node = MethodNode()
            children.append((name, node))
            return node
        }
    }

    /// The type of `ctx.<name>` holding `effects`: an object with their
    /// methods, callable when an effect sits at `ctx.<name>` itself.
    private static func valueType(_ name: String, _ effects: [EffectDescriptor], indent: String) -> String {
        let root = MethodNode()
        for effect in effects {
            var node = root
            for part in effect.method { node = node.child(part) }
            precondition(node.effect == nil, "two effects at ctx.\(effect.method.joined(separator: "."))")
            node.effect = effect
        }
        guard let top = root.children.first(where: { $0.0 == name })?.1 else { return "{}" }
        var lines: [String] = []
        if let effect = top.effect {
            lines += doc(effect, indent: indent + "  ") + ["\(indent)  \(signature(effect, indent: indent + "  "));"]
        }
        lines += members(top, indent: indent + "  ")
        return "{\n" + lines.joined(separator: "\n") + "\n\(indent)}"
    }

    private static func members(_ node: MethodNode, indent: String) -> [String] {
        node.children.flatMap { name, child -> [String] in
            if child.children.isEmpty, let effect = child.effect {
                return doc(effect, indent: indent) + ["\(indent)\(name)\(signature(effect, indent: indent));"]
            }
            var lines = ["\(indent)\(name): {"]
            if let effect = child.effect {
                lines +=
                    doc(effect, indent: indent + "  ") + ["\(indent)  \(signature(effect, indent: indent + "  "));"]
            }
            lines += members(child, indent: indent + "  ")
            lines.append("\(indent)};")
            return lines
        }
    }

    private static func doc(_ effect: EffectDescriptor, indent: String) -> [String] {
        var text = effect.summary
        if let permission = effect.permission { text += " Needs the \(permission.rawValue) permission." }
        return ["\(indent)/** \(escaped(text)) */"]
    }

    /// `<T …>(parameters): Promise<Result>`, without the method's name.
    private static func signature(_ effect: EffectDescriptor, indent: String) -> String {
        let parameters: String
        switch effect.arguments {
        case .none:
            parameters = ""
        case .request:
            parameters = "request: \(TypeScriptDeclarations.type(effect.request, indent: indent))"
        case .positional(let names):
            parameters = names.map { name in
                guard let field = effect.fields.first(where: { $0.name == name }) else {
                    preconditionFailure("\(effect.kind): argument \(name) is not a request field")
                }
                return
                    "\(name)\(field.optional ? "?" : ""): \(TypeScriptDeclarations.type(field.schema, indent: indent))"
            }.joined(separator: ", ")
        }
        switch effect.result {
        case .none:
            return "(\(parameters)): Promise<void>"
        case .value(let schema):
            return "(\(parameters)): Promise<\(TypeScriptDeclarations.type(schema, indent: indent))>"
        case .optional(_, generic: true):
            return "<T extends JSONValue = JSONValue>(\(parameters)): Promise<T | undefined>"
        case .optional(let schema, generic: false):
            return "(\(parameters)): Promise<\(TypeScriptDeclarations.type(schema, indent: indent)) | undefined>"
        }
    }

    private static func escaped(_ doc: String) -> String {
        doc.replacingOccurrences(of: "*/", with: "*\\/")
    }
}
