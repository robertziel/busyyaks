// Formatting shared by every view (the ERB helpers, ported).
const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
const DAYS = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];

export const now = () => Math.floor(Date.now() / 1000);

export function ago(ts: number | null | undefined, at = now()): string {
  if (ts == null) return "—";
  const d = at - ts;
  if (d < 60) return `${d}s`;
  if (d < 3600) return `${Math.floor(d / 60)}m`;
  if (d < 86400) return `${Math.floor(d / 3600)}h`;
  return `${Math.floor(d / 86400)}d`;
}

const pad = (n: number) => String(n).padStart(2, "0");

export function at(ts: number | null | undefined): string {
  if (ts == null) return "—";
  const d = new Date(ts * 1000);
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}`;
}

export function hm(ts: number): string {
  const d = new Date(ts * 1000);
  return `${pad(d.getHours())}:${pad(d.getMinutes())}`;
}

export const num = (n: number | null | undefined) => (n == null ? "—" : String(n));

export function dayLabel(d: Date): string {
  return `${MONTHS[d.getMonth()]} ${d.getDate()}, ${d.getFullYear()}`;
}

// local calendar day of a unix timestamp, as YYYY-MM-DD
export function dayKey(ts: number): string {
  const d = new Date(ts * 1000);
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
}

export function longDate(iso: string): string {
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(iso);
  if (!m) return iso;
  const d = new Date(Number(m[1]), Number(m[2]) - 1, Number(m[3]));
  return `${DAYS[d.getDay()]}, ${MONTHS[d.getMonth()]} ${d.getDate()}, ${d.getFullYear()}`;
}

export const projectPath = (slug: string) => "/projects/" + slug.split("/").map(encodeURIComponent).join("/");

export function initials(name: string): string {
  const s = name
    .split(/[\s._-]+/)
    .filter(Boolean)
    .slice(0, 2)
    .map((w) => w[0])
    .join("")
    .toUpperCase();
  return s || "?";
}

export function hue(email: string): number {
  let sum = 0;
  for (const b of new TextEncoder().encode(email)) sum += b;
  return (sum * 47) % 360;
}
