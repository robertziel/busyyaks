// A project's own icon (its favicon / app icon from the repo, served by /api/icons), or — when the repo has
// none, or the file fails to load — a monogram tile that is visibly a placeholder (initials on a hue from the slug).
import { useState } from "react";

function hue(s: string): number {
  let h = 0;
  for (let i = 0; i < s.length; i++) h = (h * 31 + s.charCodeAt(i)) % 360;
  return h;
}

// the placeholder's initials: the first letter of the slug's last part's first `letters` words ("?" for none)
export function monogram(slug: string, letters = 2): string {
  const name = slug.split("/").pop() || slug;
  return (
    name
      .replace(/[^A-Za-z0-9]+/g, " ")
      .trim()
      .split(" ")
      .slice(0, letters)
      .map((w) => w[0])
      .join("")
      .toUpperCase() || "?"
  );
}

// letters: how many initials a monogram shows (1 where avatars overlap, e.g. the waiting widget's stack)
export function ProjectIcon({
  slug,
  icon,
  size = 18,
  letters = 2,
}: {
  slug: string;
  icon: string | null | undefined;
  size?: number;
  letters?: number;
}) {
  const [broken, setBroken] = useState(false);
  const style = { width: size, height: size, borderRadius: Math.round(size * 0.24) };
  if (icon && !broken) {
    return (
      <img
        className="picon"
        src={icon}
        alt=""
        width={size}
        height={size}
        style={style}
        loading="lazy"
        decoding="async"
        onError={() => setBroken(true)}
      />
    );
  }
  const initials = monogram(slug, letters);
  return (
    <span
      className="picon mono"
      aria-hidden="true"
      title={icon ? "icon failed to load" : "no icon file in this repo"}
      style={{ ...style, fontSize: Math.max(8, Math.round(size * 0.42)), background: `hsl(${hue(slug)} 45% 50%)` }}
    >
      {initials}
    </span>
  );
}
