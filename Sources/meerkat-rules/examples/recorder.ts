// Records a labelled sample every five minutes into the sample store
// (~/Library/Application Support/com.gkze.meerkat/samples.db), as
// `meerkat sample --db` does.
import { rule } from "meerkat";

export const continuous = rule({
  name: "continuous",
  on: "timer",
  params: { every: 300 },
  capabilities: { store: { record: true } },
  timeoutSeconds: 40,
  async handle(_event, ctx) {
    await ctx.store.record({
      label: "continuous",
      windowSeconds: 20,
      top: 20,
      systemOnly: true,
      retain: 10_000,
    });
  },
});
