// The runtime's timers, which Deno declares only in its Node types (rule code
// gets Node's: they return Timeout objects). Sources/meerkat-runtime/build.rs appends this to
// Deno's declarations in place of the Node types it drops.

declare namespace NodeJS {
  /** What setTimeout and setInterval return. */
  interface Timeout {
    ref: () => this;
    unref: () => this;
    hasRef: () => boolean;
    refresh: () => this;
    close: () => this;
    [Symbol.toPrimitive]: () => number;
  }
}

declare function setTimeout<Args extends unknown[]>(
  callback: (...args: Args) => void,
  delay?: number,
  ...args: Args
): NodeJS.Timeout;
declare function setInterval<Args extends unknown[]>(
  callback: (...args: Args) => void,
  delay?: number,
  ...args: Args
): NodeJS.Timeout;
declare function clearTimeout(timeout: NodeJS.Timeout | number | undefined): void;
declare function clearInterval(timeout: NodeJS.Timeout | number | undefined): void;
