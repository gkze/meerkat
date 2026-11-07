// The JavaScript half of meerkatd's rule runtime: rule definition and
// discovery, invocation, effects and logging, on top of Deno's own globals.
//
// Every rule file runs in a worker of its own, so the unit of isolation is
// the file: code in one file cannot reach another file's rules, contexts or
// pending effects. This module is an extension module, evaluated before any
// rule code, and uses primordials, so a rule that patches `Map.prototype` or
// `JSON` changes only its own behaviour.
//
// Rule code reaches this module only through `import { rule } from
// "meerkat"` and the context each handler receives. `start` runs once, after
// Deno's bootstrap and before the first rule file loads, and removes itself.
//
// Rule code runs first and can change `Object.prototype`, so the objects this
// module fills by assignment have no prototype: an inherited property must
// not be read as one of ours, nor a setter run in place of our write.

import { core, primordials } from "ext:core/mod.js";

// `ext:core/ops` lists the snapshot's ops; this extension is not in the
// snapshot, so its ops are read from `core.ops`.
const {
  op_meerkat_begin_invocation,
  op_meerkat_done,
  op_meerkat_effect,
  op_meerkat_end_segment,
  op_meerkat_loaded,
  op_meerkat_log,
  op_meerkat_next,
} = core.ops;

const {
  ArrayIsArray,
  ArrayPrototypeJoin,
  ArrayPrototypePush,
  ArrayPrototypeSome,
  Error,
  ErrorPrototype,
  JSONParse,
  JSONStringify,
  ObjectDefineProperty,
  ObjectEntries,
  ObjectFreeze,
  ObjectPrototypeIsPrototypeOf,
  Promise,
  PromisePrototypeThen,
  PromiseReject,
  PromiseResolve,
  ReflectDeleteProperty,
  SafeArrayIterator,
  SafeMap,
  SafeSet,
  SafeWeakSet,
  String,
  StringPrototypeEndsWith,
  StringPrototypeSlice,
  SymbolFor,
  TypeError,
} = primordials;

const START = SymbolFor("meerkat.start");
const API = SymbolFor("meerkat.api");

/** The file's name as the host gives it (`<entry>.ts`), once it loads. */
let file = null;
/** The rule whose handler runs synchronously right now, for `console`. */
let consoleRule = null;
/** Every value `rule()` returned in this worker; nothing else is a rule. */
const rules = new SafeWeakSet();
/**
 * Rules `rule()` created while the file loads, in creation order, with their
 * declarative definition and handler; null otherwise.
 */
let created = null;
const handlers = new SafeMap();
const pending = new SafeMap();
let nextCall = 1;
let inspect = String;

const isError = (value) => ObjectPrototypeIsPrototypeOf(ErrorPrototype, value);
const show = (value) => (typeof value === "string" ? value : inspect(value));
/**
 * A failure as the host reads it. Nothing thrown, its getters included, can
 * make this throw.
 */
const describe = (error) => {
  try {
    return JSONStringify({
      __proto__: null,
      message: isError(error) ? `${error.name}: ${error.message}` : show(error),
      stack: isError(error) && typeof error.stack === "string" ? error.stack : null,
    });
  } catch {
    return JSONStringify({
      __proto__: null,
      message: "a value that could not be described",
      stack: null,
    });
  }
};

// Deno's console, printing to the daemon's rule log instead of stdout.
// Its levels: 0 debug, 1 log and info, 2 warn, 3 and up error.
const LEVELS = ["debug", "info", "warn", "error"];
const print = (rule) => (message, level) => {
  const text = StringPrototypeEndsWith(message, "\n")
    ? StringPrototypeSlice(message, 0, -1)
    : message;
  op_meerkat_log(rule() ?? file, LEVELS[level] ?? "error", text);
};

// ------------------------------------------------------------------ effects

const effect = (invocation, rule, request) =>
  new Promise((resolve, reject) => {
    const call = nextCall;
    nextCall += 1;
    let text;
    try {
      text = JSONStringify(request);
      if (text === undefined) throw new TypeError("an effect request must be a JSON object");
      op_meerkat_effect(call, invocation, rule, text);
    } catch (error) {
      reject(error);
      return;
    }
    pending.set(call, { resolve, reject });
  });

/**
 * The daemon's effect table (`Load.effects`, from its effect catalog): each
 * effect's wire name, its place on the context, how positional arguments
 * become request fields, and how the result comes back. Set once, before the
 * file loads.
 */
let effects = [];

/** One context method: its arguments become the request, its result the value. */
const effectMethod =
  (call, { kind, arguments: names, result }) =>
  async (...values) => {
    let fields = values[0];
    if (names !== null) {
      fields = { __proto__: null };
      for (let index = 0; index < names.length; index += 1) {
        // An argument left out is a field left out, not null.
        if (values[index] !== undefined) fields[names[index]] = values[index];
      }
    }
    const value = await call(kind, fields);
    if (result === "optional") return value.found ? value.value : undefined;
    return result === "value" ? value : undefined;
  };

/**
 * Puts one effect's method at its place under `root`, making the objects above
 * it. A method that also holds others (`notify` and `notify.withdraw`) keeps
 * the members placed before it.
 */
const placeMethod = (root, call, entry) => {
  const last = entry.method.length - 1;
  let parent = root;
  for (let index = 0; index < last; index += 1) {
    const name = entry.method[index];
    if (parent[name] === undefined) parent[name] = { __proto__: null };
    parent = parent[name];
  }
  const name = entry.method[last];
  const method = effectMethod(call, entry);
  // Defined, not assigned: a setter rule code put on `Function.prototype`
  // would otherwise take the member.
  const members = parent[name] === undefined ? [] : ObjectEntries(parent[name]);
  for (const { 0: key, 1: value } of new SafeArrayIterator(members))
    ObjectDefineProperty(method, key, {
      __proto__: null,
      value,
      writable: true,
      enumerable: true,
      configurable: true,
    });
  parent[name] = method;
};

/** The effect methods at their places on the context. */
const effectTree = (call) => {
  const root = { __proto__: null };
  for (const entry of new SafeArrayIterator(effects)) placeMethod(root, call, entry);
  const freeze = (node) => {
    for (const { 1: value } of new SafeArrayIterator(ObjectEntries(node))) freeze(value);
    return ObjectFreeze(node);
  };
  return freeze(root);
};

const makeContext = (rule, invocation, consoleClass) => {
  const call = (kind, fields) => effect(invocation, rule, { ...fields, kind });
  const log = new consoleClass(print(() => rule));
  return ObjectFreeze({
    ...effectTree(call),
    ruleId: rule,
    log: (...values) => log.log(...values),
    info: (...values) => log.info(...values),
    debug: (...values) => log.debug(...values),
    warn: (...values) => log.warn(...values),
    error: (...values) => log.error(...values),
  });
};

// -------------------------------------------------------------------- rules

/** The definition as JSON, without `handle`. */
const declarative = (definition) => {
  const copy = { __proto__: null };
  for (const { 0: key, 1: value } of new SafeArrayIterator(ObjectEntries(definition))) {
    if (key !== "handle") copy[key] = value;
  }
  return JSONParse(
    JSONStringify(copy, (key, value) => {
      if (typeof value === "function")
        throw new TypeError(`rule field "${key}" is a function; only "handle" may be`);
      if (typeof value === "bigint") throw new TypeError(`rule field "${key}" is a bigint`);
      return value;
    }),
  );
};

const api = ObjectFreeze({
  rule(definition) {
    if (created === null)
      throw new Error("rule() must be called while a rule file loads, at module top level");
    if (definition === null || typeof definition !== "object")
      throw new TypeError("rule() takes a definition object");
    if (typeof definition.name !== "string" || definition.name.length === 0)
      throw new TypeError("rule definition needs a non-empty string name");
    if (typeof definition.handle !== "function")
      throw new TypeError(`rule "${definition.name}" needs a handle function`);
    const value = ObjectFreeze({ __proto__: null, name: definition.name, on: definition.on });
    rules.add(value);
    ArrayPrototypePush(created, {
      value,
      declared: declarative(definition),
      handle: definition.handle,
    });
    return value;
  },
});

// --------------------------------------------------------------- discovery

const isRule = (value) => typeof value === "object" && value !== null && rules.has(value);

/**
 * The non-array values of a possibly nested array, depth first, each with its
 * index path (`2.0` is item 0 of item 2). An array met again, as in a cycle,
 * adds nothing.
 */
const leaves = (array) => {
  const into = [];
  const seen = new SafeSet();
  const visit = (items, prefix) => {
    if (seen.has(items)) return;
    seen.add(items);
    for (let index = 0; index < items.length; index += 1) {
      const value = items[index];
      const at = prefix === "" ? `${index}` : `${prefix}.${index}`;
      if (ArrayIsArray(value)) visit(value, at);
      else ArrayPrototypePush(into, { value, at });
    }
  };
  visit(array, "");
  return into;
};

/**
 * The rules among an entry's exports, `default` included: an export that is
 * a rule, or an array holding rules, nested arrays flattened. Other exports
 * (helpers, constants, arrays of anything else) are not rules and are
 * skipped; objects are not searched.
 */
const exportItems = (value) => {
  if (isRule(value)) return [{ value, at: null }];
  if (!ArrayIsArray(value)) return [];
  const items = leaves(value);
  return ArrayPrototypeSome(items, (item) => isRule(item.value)) ? items : [];
};

const exportedRules = (namespace) => {
  const byName = new SafeMap();
  const exported = new SafeSet();
  for (const { 0: exportName, 1: value } of new SafeArrayIterator(ObjectEntries(namespace))) {
    for (const { value: item, at } of new SafeArrayIterator(exportItems(value))) {
      if (!isRule(item))
        throw new TypeError(
          `export "${exportName}" mixes rules with other values: item ${at} is not a rule`,
        );
      const other = byName.get(item.name);
      // The same rule exported twice, under two names, is one rule.
      if (other !== undefined && other !== item)
        throw new Error(`rule "${item.name}" is defined twice in ${file}`);
      byName.set(item.name, item);
      exported.add(item);
    }
  }
  return exported;
};

/**
 * The definitions of the exported rules, in creation order, registering their
 * handlers. A file that creates rules and exports none fails: that is a rule
 * file written for side-effect registration, which would otherwise load and
 * silently run nothing.
 */
const register = (namespace, made) => {
  const exported = exportedRules(namespace);
  const loaded = [];
  const unexported = [];
  for (const { value, declared, handle } of new SafeArrayIterator(made)) {
    if (exported.has(value)) {
      ArrayPrototypePush(loaded, declared);
      // By name: the host routes invocations by rule id, and sends the
      // name with each.
      handlers.set(value.name, handle);
    } else {
      ArrayPrototypePush(unexported, value.name);
    }
  }
  const names = ArrayPrototypeJoin(unexported, ", ");
  if (loaded.length === 0 && unexported.length > 0)
    throw new Error(
      `${file} creates rules (${names}) but exports none; export a rule to run it, as in \`export const x = rule({ ... })\``,
    );
  if (unexported.length > 0)
    op_meerkat_log(
      file,
      "warn",
      `rules created but not exported by ${file}, so not running: ${names}`,
    );
  else if (loaded.length === 0) op_meerkat_log(file, "warn", `${file} exports no rules`);
  return loaded;
};

// --------------------------------------------------------------- dispatching

const load = (name, url) => {
  file = name;
  created = [];
  PromisePrototypeThen(
    import(url),
    (namespace) => {
      const made = created;
      created = null;
      let loaded;
      try {
        loaded = register(namespace, made);
      } catch (error) {
        op_meerkat_loaded(null, describe(error));
        return;
      }
      op_meerkat_loaded(JSONStringify(loaded), null);
    },
    (error) => {
      created = null;
      op_meerkat_loaded(null, describe(error));
    },
  );
};

const invoke = (message, consoleClass) => {
  const { invocation, rule, name, event } = message;
  const handle = handlers.get(name);
  if (handle === undefined) {
    op_meerkat_done(invocation, describe(new Error(`no rule ${rule} is loaded`)));
    return;
  }
  const meta = ObjectFreeze({
    kind: event.kind,
    sequence: event.sequence,
    time: event.time,
    origin: event.origin,
    replayed: event.replayed,
  });
  const context = makeContext(rule, invocation, consoleClass);
  // The timeout runs from here, when the handler actually starts.
  op_meerkat_begin_invocation(invocation, rule);
  let result;
  consoleRule = rule;
  try {
    result = handle(event.payload, context, meta);
  } catch (error) {
    result = PromiseReject(error);
  } finally {
    consoleRule = null;
    op_meerkat_end_segment();
  }
  PromisePrototypeThen(
    PromiseResolve(result),
    () => op_meerkat_done(invocation, null),
    (error) => op_meerkat_done(invocation, describe(error)),
  );
};

const resolveEffect = ({ local, ok, payload }) => {
  const entry = pending.get(local);
  if (entry === undefined) return;
  pending.delete(local);
  if (ok) entry.resolve(payload);
  else entry.reject(new Error(payload));
};

const dispatch = (message, consoleClass) => {
  switch (message.type) {
    case "load": {
      effects = message.effects;
      load(message.file, message.url);
      break;
    }
    case "invoke": {
      invoke(message, consoleClass);
      break;
    }
    case "effectResult": {
      resolveEffect(message);
      break;
    }
    default: {
      // The host sends only the types above; anything else is ignored.
      break;
    }
  }
};

const serve = async (consoleClass) => {
  for (;;) {
    const text = await op_meerkat_next();
    if (text === null) return;
    const message = JSONParse(text);
    // One message failing, whatever rule code did to the globals it uses,
    // must not end the loop that serves every rule of the file; an
    // invocation that failed before its handler ran is reported as its
    // failure, so the daemon is not left waiting.
    try {
      dispatch(message, consoleClass);
    } catch (error) {
      if (message.type === "invoke") op_meerkat_done(message.invocation, describe(error));
      else {
        const { message: reason } = JSONParse(describe(error));
        op_meerkat_log(file, "error", `the runtime could not handle "${message.type}": ${reason}`);
      }
    }
  }
};

/**
 * Node APIs that write files without going through the worker's file system,
 * which holds every change to meerkatd's own files to their real paths
 * (protected.rs): SQLite databases and WASI's preopened folders. They are
 * native classes Deno registers whole, so no op switch reaches them, and
 * Deno's polyfills keep their own copy of `core.ops`, taken before this
 * runs. So the polyfills' exports are replaced instead, before any rule code
 * runs: each polyfill loads once per worker, and every route to it reads
 * that one object (`import`, `process.getBuiltinModule`; a dynamic
 * `import()` meets the loader, and `require` is off, worker.rs). Unix socket
 * listeners need Deno's net permission, which no rule is given.
 */
const refused = (what) =>
  function Refused() {
    throw new TypeError(
      `${what} is not available to rules: it writes files around meerkatd's protection of its own`,
    );
  };

const refuseUnguardedWrites = () => {
  const sqlite = core.loadExtScript("ext:deno_node/sqlite.ts");
  sqlite.DatabaseSync = refused("node:sqlite");
  sqlite.backup = refused("node:sqlite");
  const wasi = core.loadExtScript("ext:deno_node/wasi.ts");
  wasi.WASI = refused("node:wasi");
  wasi.default.WASI = wasi.WASI;
};

const start = () => {
  ReflectDeleteProperty(globalThis, START);
  refuseUnguardedWrites();
  const consoleModule = core.loadExtScript("ext:deno_web/01_console.js");
  inspect = consoleModule.inspect;
  ObjectDefineProperty(globalThis, "console", {
    __proto__: null,
    value: new consoleModule.Console(print(() => consoleRule)),
    writable: true,
    enumerable: false,
    configurable: true,
  });
  // Rule code reads the API from here (see the loader's "meerkat" module)
  // and cannot replace it.
  ObjectDefineProperty(globalThis, API, {
    __proto__: null,
    value: api,
    writable: false,
    enumerable: false,
    configurable: false,
  });
  // An error nothing caught, in a timer or a promise nobody awaited, is
  // logged; it does not end the file's worker.
  globalThis.addEventListener("error", (event) => {
    event.preventDefault();
    op_meerkat_log(file, "error", `uncaught ${show(event.error ?? event.message)}`);
  });
  globalThis.addEventListener("unhandledrejection", (event) => {
    event.preventDefault();
    op_meerkat_log(file, "error", `unhandled rejection: ${show(event.reason)}`);
  });
  PromisePrototypeThen(serve(consoleModule.Console), undefined, (error) => {
    op_meerkat_log(null, "error", `the runtime's dispatcher failed: ${show(error)}`);
  });
};

ObjectDefineProperty(globalThis, START, {
  __proto__: null,
  value: start,
  writable: false,
  enumerable: false,
  configurable: true,
});
