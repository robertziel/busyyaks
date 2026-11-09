// What a report says at a glance (the server's digest of its tl:* blocks): headline figures with their change,
// the headline risk, and counters (needs you · high actions · flags · repos · broken blocks).
import { authorParts, digestCounters, figureChange } from "../lib/report";
import type { ReportDigest } from "../types";

export function Figures({ digest, max = 6 }: { digest: ReportDigest; max?: number }) {
  if (digest.figures.length === 0) return null;
  return (
    <ul className="rd-figs">
      {digest.figures.slice(0, max).map((f) => {
        const c = figureChange(f);
        return (
          <li key={f.label} className={`t-${f.tone}`}>
            <b>{f.value}</b>
            {c && <span className={`rd-chg ${c.dir} ${c.feel}`}>{c.text}</span>}
            <span className="rd-label">{f.label}</span>
          </li>
        );
      })}
    </ul>
  );
}

export function Headline({ digest }: { digest: ReportDigest }) {
  if (!digest.headline) return null;
  return (
    <p className={`rd-headline t-${digest.headline.tone}`}>
      <i className="tl-dot" />
      <span>{digest.headline.text}</span>
    </p>
  );
}

export function Counters({ digest }: { digest: ReportDigest }) {
  const cs = digestCounters(digest);
  if (cs.length === 0) return null;
  return (
    <span className="rd-counters">
      {cs.map((c) => (
        <span key={c.key} className={`rd-count ${c.tone}`}>
          <b>{c.n}</b> {c.label}
        </span>
      ))}
    </span>
  );
}

export function Author({ author }: { author: string }) {
  const a = authorParts(author);
  return (
    <span className="rd-author" title={author}>
      <span className="tag">{a.name}</span>
      {a.detail && <span className="rd-model">{a.detail}</span>}
    </span>
  );
}
