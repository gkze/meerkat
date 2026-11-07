import type { FSChange } from "meerkat";

/** "created+modified ~/Downloads/a.zip" */
export const describeChange = (event: FSChange): string =>
  `${event.changes.join("+")} ${event.path.replace(/^\/Users\/[^/]+/u, "~")}`;
