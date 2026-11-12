// The first-run gate: while the shell's <meta name="setup"> says "pending", every page opens /hello. A
// finish in this tab (the shell is not reloaded) is remembered here.
import { setupPending } from "./hello";

let done = false;

export const markSetupDone = () => {
  done = true;
};

export const needsSetup = (): boolean =>
  setupPending(document.querySelector<HTMLMetaElement>('meta[name="setup"]')?.content ?? null, done);
