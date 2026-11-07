// Moves a process to the background band when it writes more than 50 MB/s
// for 30 seconds, and says so, with a button that moves it back.
// Background processes are throttled for CPU, disk and network; nothing is
// killed. It observes only your own processes, the only ones it may change.
import { rule } from "meerkat";

export const throttle = rule({
  name: "throttle",
  on: "process.hot",
  params: { metric: "diskWriteMBps", above: 50, sustainSeconds: 30 },
  match: { phase: "started" },
  rate: { throttleSeconds: 60 },
  capabilities: { process: { observe: "own", priority: true }, notify: true },
  async handle(event, ctx) {
    const { pid, startedAt, name } = event.process;
    await ctx.process.setPriority({ pid, startedAt }, "background");
    await ctx.notify({
      // One notification per process: throttling it again replaces it.
      id: `${pid}-${startedAt}`,
      title: `${name} moved to background`,
      body: `Wrote ${event.value.toFixed(0)} MB/s for ${event.aboveForSeconds.toFixed(0)} s.`,
      actions: [{ id: "undo", title: "Move back" }],
      data: { pid, startedAt },
    });
  },
});

// The click on "Move back" arrives here: responses reach only rules in the
// file whose rule posted the notification.
export const undo = rule({
  name: "undo",
  on: "meerkat.notification",
  match: { rule: "throttle", action: "undo" },
  capabilities: { process: { priority: true } },
  async handle(event, ctx) {
    const data = event.data;
    if (typeof data !== "object" || data === null || Array.isArray(data)) return;
    const { pid, startedAt } = data;
    if (typeof pid !== "number" || typeof startedAt !== "number") return;
    await ctx.process.setPriority({ pid, startedAt }, "normal");
  },
});
