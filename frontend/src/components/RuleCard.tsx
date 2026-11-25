// One rules FILE as one full-width card (Settings → Agent rules, a project's Settings tab): the header is the file —
// its path, what it is, who gets it, its source, its git state, ONE size figure (the launch budget, its breakdown in the
// tooltip) — and a toggle; open, the editor (Preview = the server's render, never markdown in the client; Write = the
// file's text) with an optional slot above it (the layers a project file adds to). Collapsed state is the caller's
// (remembered per viewer).
import { useEffect, useState, type ReactNode } from "react";
import { apiPost } from "../api";
import { stripFront } from "../lib/agentRules";
import { Html } from "./Html";

export type RuleCardProps = {
  id: string;
  path: string;
  what: string;
  who: string;
  source: string;
  where: string; // where it is edited / committed, one line
  size: { n: number; max: number; tip: string };
  git: { tone: "muted" | "warn"; text: string } | null;
  value: string;
  html: string | null; // the loaded file, rendered by the server
  changed: boolean;
  refusal: string | null;
  error: string | null; // the file cannot be edited here
  readOnly: boolean;
  open: boolean;
  onToggle: () => void;
  onChange: (v: string) => void;
  children?: ReactNode; // above the editor
};

export function RuleCard(p: RuleCardProps) {
  const [tab, setTab] = useState<"preview" | "write">("preview");
  const [preview, setPreview] = useState<{ html: string } | { error: string } | null>(null);
  const over = p.size.n > p.size.max;
  // the loaded file's render comes with the page (html); an edited text, or a file the page has no render of, is
  // rendered by the server when Preview shows
  const own = !p.changed && !!p.html;
  const text = p.value;
  useEffect(() => {
    if (!p.open || tab !== "preview" || own || !text.trim()) return;
    let live = true;
    setPreview(null);
    apiPost<{ html: string }>("/api/markdown", { body: stripFront(text) }).then(
      (r) => live && setPreview(r),
      (err: unknown) => live && setPreview({ error: err instanceof Error ? err.message : String(err) }),
    );
    return () => {
      live = false;
    };
  }, [p.open, tab, own, text]);
  const body = `${p.id}-body`;
  const fill = p.size.max > 0 ? Math.min(1, p.size.n / p.size.max) : 1;
  return (
    <section
      id={p.id}
      className={`card rc${p.open ? " open" : ""}${p.changed ? " changed" : ""}${p.refusal || p.error ? " bad" : ""}`}
      aria-labelledby={`${p.id}-h`}
    >
      <header className="rc-head">
        <button
          type="button"
          className="rc-toggle"
          aria-expanded={p.open}
          aria-controls={body}
          id={`${p.id}-h`}
          onClick={p.onToggle}
        >
          <i className="rc-chev" aria-hidden="true" />
          <span className="rc-file mono">{p.path}</span>
        </button>
        <span className="rc-chips">
          <span className="tag rc-source">{p.source}</span>
          {p.changed && <span className="tag rc-changed">changed</span>}
          {p.git && <span className={`tag rc-git ${p.git.tone}`}>{p.git.text}</span>}
        </span>
        <span className="rc-what">{p.what}</span>
        <span className="rc-who">{p.who}</span>
        <span
          className={`rc-size mono${over ? " over" : ""}`}
          title={p.size.tip}
          aria-label={`${p.size.n} of ${p.size.max} bytes (${p.size.tip})`}
        >
          <span className="rc-meter" aria-hidden="true">
            <i style={{ width: `${Math.round(fill * 100)}%` }} />
          </span>
          {p.size.n.toLocaleString("en-US")} / {p.size.max.toLocaleString("en-US")} B
        </span>
      </header>
      {p.open && (
        <div className="rc-body" id={body}>
          {p.children}
          <div className="rc-tools">
            {/* two toggle buttons (a view switch, not a tab widget): the pressed one is the view shown */}
            <span className="rc-tabs" role="group" aria-label={`${p.path} view`}>
              <button type="button" aria-pressed={tab === "preview"} onClick={() => setTab("preview")}>
                Preview
              </button>
              <button type="button" aria-pressed={tab === "write"} onClick={() => setTab("write")}>
                Write
              </button>
            </span>
            <span className="rc-where">{p.where}</span>
          </div>
          {tab === "write" ? (
            <textarea
              className="rc-text mono"
              rows={Math.min(28, Math.max(6, p.value.split("\n").length + 1))}
              value={p.value}
              readOnly={p.readOnly || !!p.error}
              spellCheck={false}
              placeholder={p.error ? "" : "no file · type to make it"}
              aria-label={p.path}
              aria-invalid={!!p.refusal || undefined}
              onChange={(e) => p.onChange(e.target.value)}
            />
          ) : (
            <div className="rc-preview">
              {own ? (
                <Html html={p.html ?? ""} />
              ) : !text.trim() ? (
                <p className="muted">no file · Write to make it</p>
              ) : !preview ? (
                <p className="muted">rendering…</p>
              ) : "html" in preview ? (
                <Html html={preview.html} />
              ) : (
                <p className="rc-bad">preview failed: {preview.error}</p>
              )}
            </div>
          )}
          {(p.error ?? p.refusal) && <p className="rc-bad">{p.error ? `not editable here · ${p.error}` : p.refusal}</p>}
        </div>
      )}
    </section>
  );
}
