// Keeps a log of when any input device starts or stops being used, which is
// what the microphone indicator in the menu bar reflects. Which apps use the
// microphone is what you are doing, so the rule names the kind it observes.
import { rule } from "meerkat";

export const log = rule({
  name: "log",
  on: "audio.inUse",
  capabilities: { observe: { allow: ["audio.inUse"] } },
  async handle(event, ctx, meta) {
    const inputs = event.running
      .filter((entry) => entry.direction === "input")
      .map((entry) => entry.device.name ?? entry.device.uid ?? "unknown");
    const previous = (await ctx.state.get<string[]>("inputs")) ?? [];
    await ctx.state.set("inputs", inputs);
    if (meta.replayed) return;
    if (inputs.length > previous.length) ctx.log("microphone in use:", inputs.join(", "));
    if (inputs.length === 0 && previous.length > 0) ctx.log("microphone released");
  },
});
