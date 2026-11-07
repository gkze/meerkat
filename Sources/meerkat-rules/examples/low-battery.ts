// Notifies once per discharge when the battery falls below 15 %, and takes
// the notification back once the battery recovers.
import { rule } from "meerkat";

/** Warn below this charge; re-arm once it recovers to `REARM_PERCENT`. */
const WARN_PERCENT = 15;
const REARM_PERCENT = 20;

export const warn = rule({
  name: "warn",
  on: "power.source",
  match: { providing: "battery" },
  capabilities: { notify: true },
  async handle(event, ctx) {
    const battery = event.batteries[0];
    const percent = battery?.currentCapacityPercent;
    if (percent === undefined) return;
    const warned = (await ctx.state.get<boolean>("warned")) ?? false;
    if (percent < WARN_PERCENT && !warned) {
      await ctx.notify({
        id: "low-battery",
        title: "Battery low",
        body: `${percent.toFixed(0)} % remaining`,
      });
      await ctx.state.set("warned", true);
    } else if (percent >= REARM_PERCENT && warned) {
      await ctx.notify.withdraw("low-battery");
      await ctx.state.set("warned", false);
    }
  },
});
