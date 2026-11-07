# meerkat-lint

The `meerkat/*` lint rules, as a native binary. Meerkat.app ships Oxc's standalone Oxlint, which
has no JavaScript plugin host and silently skips JS plugins (no warning, exit 0), so these rules
run here, next to it. The repository's `bun run lint` runs both too, so rule code is checked the
same way in this repository and in every rules folder.

| Rule                                  | Fix | Rewrites or reports                                                      |
| ------------------------------------- | --- | ------------------------------------------------------------------------ |
| `meerkat/const-arrow-functions`      | yes | `function read() {}` to `const read = () => {}` where the semantics hold |
| `meerkat/compact-arrow-returns`      | yes | `() => { return value; }` to `() => value`                               |
| `meerkat/compact-control-statements` | yes | `if (ready) { return value; }` to `if (ready) return value;`             |
| `meerkat/rule-exported`              | no  | `rule({ ... });` whose result is thrown away, so the rule never runs     |

```text
meerkat-lint [--fix] PATH...
```

Directories are searched for `.ts`, `.tsx`, `.mts`, `.cts`, `.js`, `.jsx`, `.mjs` and `.cjs`
files, skipping hidden directories, `node_modules` and declaration files. Findings print in
Oxlint's `unix` format. `--fix` applies fixes until none apply (at most 10 passes); formatting is
left to Oxfmt. Exit status: 0 clean, 1 findings, 2 bad arguments or an unreadable path. A file that
does not parse is named on stderr and skipped, since Oxlint and the compiler report its errors.

All four rules always run; Oxlint configuration is not read.
`policy/` holds the Oxlint and Oxfmt policy these rules complete: the root `.oxlintrc.json` extends
`policy/oxlintrc.json`, and the daemon copies both files into each rules folder.

## Behaviour

Each fixing rule leaves code unchanged when the rewrite could change meaning or lose a comment.
`const-arrow-functions` converts only top-level function declarations in modules, and anonymous
function expressions that directly initialize a `const`. It never converts an exported function,
and keeps any function that uses `this`, `arguments`, `super`, `new.target` or the `this` type, is
a generator, has a `this` parameter, an overload or a namespace merge, is referenced before its
declaration or from inside another function declaration (which is hoisted, so may call it before its
line), or is used other than by a direct call. `compact-arrow-returns` parenthesizes a returned
expression whose first token is `{`, not only an object literal. The two compact rules fire only
when the result fits 100 columns, Oxfmt's default, which this repository uses.

`rule-exported` follows `import { rule } from "meerkat"`, aliases included, by name. The daemon is
the authoritative check (it fails a file that creates rules and exports none); this rule catches the
mistake while editing.

## Provenance

The three fixing rules are ports of `const-arrow-functions`, `compact-arrow-returns` and
`compact-control-statements` from [gkze/tsmono](https://github.com/gkze/tsmono)
`packages/oxlint-plugin/src`, as of its working tree on top of commit `24cc8d9` on 2026-10-24.
Their tests are tsmono's test cases. Two fixes have been made here since and are not yet in tsmono:
`const-arrow-functions` keeps a function called from inside another function declaration, and
`compact-arrow-returns` tests the returned expression's first token for `{`.

The port was checked against those JS rules running in npm Oxlint 1.89.0, one rule at a time, on
1,796 TypeScript and JavaScript files from tsmono, several other TypeScript codebases and this
repository: `--fix` output was byte-identical for every file, and every finding had the same
file and line. To port a change from tsmono, port its test cases into the rule's tests first.

The AST comes from `oxc` 0.155.0 (exact pin), parsed without parenthesized-expression nodes, as in
the AST Oxlint gives JS plugins.
