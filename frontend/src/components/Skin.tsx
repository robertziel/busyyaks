// The skin switch in the header: Light (the default) · Dark · Auto (follow the system) over public/static/skin.js,
// which owns the choice (this browser's localStorage) and puts the skin on <html data-skin> before first paint. This
// only drives it.
import { useEffect, useState } from "react";
import { Select } from "./Select";

export type SkinChoice = "auto" | "light" | "dark";
type SkinApi = { choices: SkinChoice[]; get(): SkinChoice; set(c: SkinChoice): void };

declare global {
  interface Window {
    busyyaksSkin?: SkinApi;
  }
}

const LABELS: Record<SkinChoice, string> = { auto: "Auto", light: "Light", dark: "Dark" };

function api(): SkinApi {
  const a = window.busyyaksSkin;
  if (!a) throw new Error("busyyaks: /static/skin.js did not load — the skin switch has nothing to drive");
  return a;
}

export function SkinSwitch() {
  const skin = api();
  const [choice, setChoice] = useState<SkinChoice>(skin.get());
  useEffect(() => {
    const on = (e: Event) => setChoice((e as CustomEvent<{ choice: SkinChoice }>).detail.choice);
    document.addEventListener("busyyaks:skin", on);
    return () => document.removeEventListener("busyyaks:skin", on);
  }, []);
  return (
    <Select
      ariaLabel="Skin"
      align="end"
      className="sel-btn skin-switch"
      value={choice}
      options={skin.choices.map((c) => ({ value: c, label: LABELS[c] }))}
      onChange={(v) => skin.set(v as SkinChoice)}
    />
  );
}
