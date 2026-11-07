// Logs every file that appears in or leaves ~/Downloads, with what created it
// when the process can be found. One module can export any number of rules;
// each export that is a rule runs, and other exports are ignored. Watching a
// folder is reading it, so each rule declares fs.read for what it watches.
import { rule } from "meerkat";

import { describeChange } from "./lib/describe";

const paths = ["~/Downloads"];
const capabilities = { fs: { read: paths } };

export const newFiles = rule({
  name: "new-files",
  on: "fs.change",
  params: { paths, latency: 0.5 },
  capabilities,
  match: { itemType: "file", changes: { includesAny: ["created", "renamed"] } },
  handle(event, ctx) {
    ctx.log(describeChange(event));
  },
});

export const removedFiles = rule({
  name: "removed-files",
  on: "fs.change",
  params: { paths, latency: 0.5 },
  capabilities,
  match: { itemType: "file", changes: { includes: "removed" } },
  handle(event, ctx) {
    ctx.log(describeChange(event));
  },
});
