/// The limits the daemon holds a rule's definition to: one authority for the
/// daemon's checks (`RuleDefinition`, `MatchPredicate`) and for what the rule
/// API's declarations below tell authors.
public enum RuleLimits {
    /// Longest `glob` or `regex` pattern, in UTF-16 code units. Regular
    /// expressions run in the daemon on every event; each match is
    /// time-bounded by `BoundedRegex`, and patterns and inputs are bounded in
    /// length so the work per event stays small even within that limit.
    public static let maximumPatternLength = 512
    /// Longest string a `glob` or `regex` is matched against; a longer one
    /// never matches. Both backtrack (`fnmatch` on `*`).
    public static let maximumMatchInput = 16_384
    public static let defaultTimeoutSeconds = 5.0
    public static let timeoutRange = 0.1...60.0
}

/// The hand-written part of the `meerkat` TypeScript module: the rule API.
///
/// It refers to `Events`, `EventParameters` and the payload interfaces that
/// `TypeScriptDeclarations` generates from the event catalog, and to
/// `Grants` and `Context`, which `EffectDeclarations` generates from the
/// effect catalog. The runtime implements it in
/// Sources/meerkat-runtime/js/runtime.js; the daemon enforces the same
/// shapes when it decodes a rule definition (`RuleDefinition`), so these
/// types are a convenience for authors, not the only check.
enum RuleAPIDeclarations {
    static let text = #"""
        export type EventName = keyof Events;

        /** Metadata delivered with every event. */
        export interface EventMeta<K extends EventName = EventName> {
          kind: K;
          /** Increases by one per event from the same source. */
          sequence: number;
          /** Unix epoch milliseconds when the daemon received the event. */
          time: number;
          /** "meerkat" when the daemon's own effects caused the event. */
          origin: "system" | "meerkat";
          /**
           * True when the event is a `state` event's current value rather than a
           * change seen after the rule loaded: the value a push `state` source
           * reports when it starts, or the latest value of a source that was
           * already running. Polled `state` kinds (samples) are never replayed.
           */
          replayed: boolean;
        }

        // ---------------------------------------------------------------- match

        export interface StringMatch {
          eq?: string;
          ne?: string;
          in?: readonly string[];
          /**
           * Shell-style pattern (`*` and `?`, at most \#(RuleLimits.maximumPatternLength) characters), matched
           * against the whole string. Strings longer than \#(RuleLimits.maximumMatchInput) characters never
           * match a glob.
           */
          glob?: string;
          /**
           * Regular expression (ICU syntax, at most \#(RuleLimits.maximumPatternLength) characters), matched
           * anywhere in the string. Strings longer than \#(RuleLimits.maximumMatchInput) characters never
           * match a regex.
           */
          regex?: string;
          prefix?: string;
          suffix?: string;
        }

        export interface NumberMatch {
          eq?: number;
          ne?: number;
          gt?: number;
          gte?: number;
          lt?: number;
          lte?: number;
          in?: readonly number[];
        }

        export interface ArrayMatch<E> {
          /** The array contains this element. */
          includes?: E;
          /** The array contains at least one of these. */
          includesAny?: readonly E[];
          /** The array contains all of these. */
          includesAll?: readonly E[];
          /** Matches when the array is empty (true) or not (false). */
          empty?: boolean;
        }

        /**
         * A literal compares for equality; an object applies operators. Free-form
         * JSON fields compare for equality only; record fields match per key.
         */
        export type FieldMatch<V> =
          [JSONValue] extends [V] ? JSONValue :
          [V] extends [string] ? V | (StringMatch & { eq?: V; ne?: V; in?: readonly V[] }) :
          [V] extends [number] ? V | NumberMatch :
          [V] extends [boolean] ? V :
          [V] extends [readonly (infer E)[]] ? ArrayMatch<E> :
          [V] extends [object] ? Match<V> :
          never;

        /**
         * Payload filter evaluated by the daemon before JavaScript runs. Every
         * listed field must match (logical AND); an absent optional field never
         * matches.
         */
        export type Match<T> = { [P in keyof T]?: FieldMatch<Exclude<T[P], undefined>> };

        // ---------------------------------------------------------------- rate

        export interface Rate {
          /** At most one invocation per window; the first event wins. */
          throttleSeconds?: number;
          /** Invoke with the last event once no event arrived for this long. */
          debounceSeconds?: number;
          /** Drop events beyond this many invocations per rolling minute. */
          maxPerMinute?: number;
        }

        // ---------------------------------------------------------------- context

        /**
         * Always available. The effects a rule's grants allow are added to it in
         * `Context`, generated from the daemon's effect catalog below.
         */
        export interface BaseContext {
          /** The rule id, `<file>#<name>`. */
          readonly ruleId: string;
          log(...values: unknown[]): void;
          info(...values: unknown[]): void;
          debug(...values: unknown[]): void;
          warn(...values: unknown[]): void;
          error(...values: unknown[]): void;
        }

        // ---------------------------------------------------------------- rules

        /**
         * Types as `never` every field of `Given` that `Known` doesn't declare,
         * so a grant the daemon would refuse is a type error as you write it.
         */
        type OnlyGrants<Given, Known> = {
          [K in keyof Given]: K extends keyof Known
            ? NonNullable<Known[K]> extends boolean | string | { allow: readonly string[] } | readonly string[]
              ? Given[K]
              : OnlyGrants<Given[K], NonNullable<Known[K]>>
            : never;
        };

        type ParamsField<K extends EventName> =
          {} extends EventParameters[K] ? { params?: EventParameters[K] } : { params: EventParameters[K] };

        /**
         * `capabilities` is required, with its grant, for a kind that needs one to
         * be observed. That `observe.allow` names the kind itself, and that
         * `fs.read` covers what `params` watch, is checked when the rule loads.
         */
        type ObservationField<K extends EventName> =
          {} extends EventObservation[K] ? {} : { capabilities: EventObservation[K] };

        export type RuleDefinition<K extends EventName, G extends Grants> = {
          /** Unique within the entry file that exports the rule; the rule id is `<file>#<name>`. */
          name: string;
          on: K;
          match?: Match<Events[K]>;
          rate?: Rate;
          /**
           * What the rule may do, and what it may observe: `on` may need a grant
           * (`EventObservation`), and a rule without it does not load.
           */
          capabilities?: G & OnlyGrants<G, Grants>;
          /** Also receive events caused by this daemon's own effects. Default false. */
          includeOwn?: boolean;
          /**
           * Deadline per invocation, \#(timeouts) seconds, from when the handler starts.
           * Default \#(seconds(RuleLimits.defaultTimeoutSeconds)). A promise still pending then is abandoned; synchronous code
           * still running then stops the handler host.
           */
          timeoutSeconds?: number;
          handle(event: Events[K], ctx: Context<G>, meta: EventMeta<K>): void | Promise<void>;
        } & ParamsField<K> & ObservationField<K>;

        const ruleBrand: unique symbol;

        /**
         * A rule made by `rule()`. It runs only when a top-level rule file exports
         * it: as an export of its own (`default` included), or in an exported
         * array of rules, nested arrays flattened.
         */
        export type Rule<K extends EventName = EventName> = {
          readonly name: string;
          readonly on: K;
          readonly [ruleBrand]: true;
        };

        /**
         * Defines a rule. Call it while the rule files load (at module top level,
         * in any module), and export the result from a top-level rule file.
         */
        export function rule<K extends EventName, const G extends Grants = {}>(definition: RuleDefinition<K, G>): Rule<K>;
        """#

    private static let timeouts =
        "\(seconds(RuleLimits.timeoutRange.lowerBound))–\(seconds(RuleLimits.timeoutRange.upperBound))"

    /// A number of seconds as the declarations write it: `60`, not `60.0`.
    private static func seconds(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(value)
    }
}
