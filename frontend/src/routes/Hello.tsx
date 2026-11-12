// /hello — the first-run hello screen. A boot screen (the trotting yak + every check GET /api/setup ran,
// each ticked in turn), then three steps: Projects (the host dir, read-only — .env), Agents (which allowlisted commands
// become launchers, and the default — a new agent settings revision) and Done (POST /api/setup/complete). The shell
// opens it while <meta name="setup"> is "pending"; the settings cog reopens it any time. Every step carries the note
// "ask your agent to set it up for you" with a prompt to copy: the host-only parts are its job, never this page's.
import { useEffect, useMemo, useState } from "react";
import { Link, useNavigate } from "react-router-dom";
import { ApiError, apiPost, invalidate, useResource } from "../api";
import { CopyChip } from "../components/Copy";
import { ErrorState } from "../components/States";
import { YakLoader } from "../components/YakLoader";
import { invocationLine, type AgentSettingsData } from "../lib/agentSettings";
import {
  agentPrompt,
  applyRows,
  defaultFrom,
  rowsError,
  rowsFrom,
  typeChanges,
  type Check,
  type Row,
  type SetupData,
} from "../lib/hello";
import { markSetupDone } from "../lib/setupGate";
import { useTitle } from "../lib/title";

const KEY = "/api/setup";
const STEPS = ["Welcome", "Projects", "Agents", "Done"] as const;
const TICK_MS = 420; // one boot check revealed per tick

function Boot({ checks, onNext }: { checks: Check[] | null; onNext: () => void }) {
  const [shown, setShown] = useState(0);
  const total = checks?.length ?? 0;
  useEffect(() => {
    if (!checks || shown >= total) return;
    const t = window.setTimeout(() => setShown((n) => n + 1), TICK_MS);
    return () => window.clearTimeout(t);
  }, [checks, shown, total]);
  const doneBooting = !!checks && shown >= total;
  const failed = checks?.filter((c) => !c.ok).length ?? 0;
  return (
    <div className="hello-boot">
      <div className="hello-yak">
        <YakLoader variant="a" />
      </div>
      <h1 className="hello-brand">
        busy<span>yaks</span>
      </h1>
      <div className={`hello-dots${doneBooting ? " still" : ""}`} aria-hidden="true">
        {[0, 1, 2, 3, 4].map((i) => (
          <i
            key={i}
            style={{ animationDelay: `${i * 0.18}s` }}
            className={i < Math.ceil((shown / Math.max(total, 1)) * 5) ? "on" : ""}
          />
        ))}
      </div>
      <ul className="hello-checks" aria-live="polite">
        {(checks ?? []).slice(0, shown).map((c) => (
          <li key={c.key} className={c.ok ? "ok" : "bad"}>
            <span className="hello-mark">{c.ok ? "✓" : "✗"}</span>
            <b>{c.label}</b>
            <span className="muted">{c.detail}</span>
          </li>
        ))}
        {checks && shown < total && (
          <li className="pending">
            <span className="hello-mark">·</span>
            <b>{checks[shown]!.label}</b>
          </li>
        )}
      </ul>
      {doneBooting && (
        <div className="hello-actions">
          <span className="muted">
            {total - failed}/{total} ok{failed > 0 && <b className="hello-bad"> · {failed} failed</b>}
          </span>
          <button type="button" className="btn primary" onClick={onNext} autoFocus>
            {failed > 0 ? "Continue anyway" : "Start setup"}
          </button>
        </div>
      )}
    </div>
  );
}

function AskAgent({ data }: { data: SetupData }) {
  const prompt = agentPrompt(data.projects, data.agents.commands, window.location.origin);
  return (
    <aside className="hello-ask">
      <b>Ask your agent to set it up for you</b>
      <span className="muted">paste into Claude Code, hermes or any agent on this host</span>
      <pre>{prompt}</pre>
      <CopyChip text={prompt} title="Copy the prompt">
        <span className="btn small">Copy prompt</span>
      </CopyChip>
    </aside>
  );
}

function Projects({ data }: { data: SetupData }) {
  const p = data.projects;
  return (
    <section className="hello-step">
      <h2>Projects</h2>
      <dl className="hello-facts">
        <dt>host dir</dt>
        <dd>
          <code>{p.host_root}</code>
        </dd>
        <dt>in containers</dt>
        <dd>
          <code>{p.mount}</code>
        </dd>
        <dt>roots</dt>
        <dd>
          {p.roots.map((r) => (
            <code key={r.path}>
              {r.path}
              {r.prefix && ` → ${r.prefix}`}
            </code>
          ))}{" "}
          · depth {p.search_depth}
        </dd>
        <dt>repos</dt>
        <dd>
          <b>{p.repos}</b>
          {p.sample.length > 0 && (
            <span className="hello-chips">
              {p.sample.map((s) => (
                <span key={s} className="chip">
                  {s}
                </span>
              ))}
              {p.repos > p.sample.length && <span className="muted">+{p.repos - p.sample.length}</span>}
            </span>
          )}
        </dd>
      </dl>
      <p className="muted hello-host">
        change: <code>.env</code> <code>PROJECTS_ROOT=/path/to/projects</code> → <code>docker compose up -d</code> (host
        only)
      </p>
    </section>
  );
}

function Agents({ agents, onSaved }: { agents: AgentSettingsData; onSaved: (saved: AgentSettingsData) => void }) {
  const [rows, setRows] = useState<Row[]>(() => rowsFrom(agents.doc, agents.commands));
  const [def, setDef] = useState(() => defaultFrom(agents.doc, rowsFrom(agents.doc, agents.commands)));
  const [saving, setSaving] = useState(false);
  const [saveError, setSaveError] = useState<string | null>(null);
  const problem = rowsError(rows, def);
  const set = (i: number, r: Partial<Row>) => setRows(rows.map((x, j) => (j === i ? { ...x, ...r } : x)));
  const dropped = rows.filter((r) => r.existing && r.at < 0);
  // every agent type the save rewrites, shown before Save (never a silent per-type change)
  const changes = problem ? [] : typeChanges(agents.doc, applyRows(agents.doc, agents.commands, rows, def));

  const save = async () => {
    setSaving(true);
    setSaveError(null);
    try {
      const doc = applyRows(agents.doc, agents.commands, rows, def);
      const saved = await apiPost<AgentSettingsData>("/api/settings/agents", { base: agents.revision.id, doc });
      invalidate("/api/settings/agents");
      onSaved(saved);
    } catch (e) {
      setSaveError(e instanceof ApiError ? `${e.status} · ${e.message}` : String(e));
    } finally {
      setSaving(false);
    }
  };

  return (
    <section className="hello-step">
      <h2>Agents</h2>
      <p className="muted">
        {agents.commands.length} command{agents.commands.length === 1 ? "" : "s"} allowed on this host · revision{" "}
        {agents.revision.id}
      </p>
      <table className="hello-agents">
        <thead>
          <tr>
            <th>use</th>
            <th>command</th>
            <th>key</th>
            <th>label</th>
            <th>default</th>
          </tr>
        </thead>
        <tbody>
          {rows.map((r, i) => {
            const c = r.at >= 0 ? agents.commands[r.at] : undefined;
            return (
              <tr key={`${r.key}-${i}`} className={c ? (r.use ? "on" : "") : "off"}>
                <td>
                  <input
                    type="checkbox"
                    aria-label={`use ${r.key}`}
                    checked={r.use}
                    disabled={!c}
                    onChange={(e) => set(i, { use: e.target.checked })}
                  />
                </td>
                <td>
                  {c ? <code>{invocationLine(c)}</code> : <span className="hello-bad">not allowed on this host</span>}
                </td>
                <td>
                  <input
                    value={r.key}
                    disabled={r.existing || !r.use}
                    spellCheck={false}
                    aria-label={`key of ${r.key}`}
                    onChange={(e) => {
                      if (def === r.key) setDef(e.target.value);
                      set(i, { key: e.target.value });
                    }}
                  />
                </td>
                <td>
                  <input
                    value={r.label}
                    disabled={!r.use}
                    aria-label={`label of ${r.key}`}
                    onChange={(e) => set(i, { label: e.target.value })}
                  />
                </td>
                <td>
                  <input
                    type="radio"
                    name="hello-default"
                    aria-label={`default ${r.key}`}
                    checked={def === r.key && r.use}
                    disabled={!r.use}
                    onChange={() => setDef(r.key)}
                  />
                </td>
              </tr>
            );
          })}
        </tbody>
      </table>
      {dropped.length > 0 && (
        <p className="hello-bad">removed on save (no allowlist entry): {dropped.map((r) => r.key).join(", ")}</p>
      )}
      <p className="muted hello-host">
        more commands: <code>config/busyyaks.yml</code> <code>launch.commands</code> → restart the launcher (host only)
        · every field: <Link to="/settings">Agents &amp; launchers</Link>
      </p>
      {changes.length > 0 && (
        <table className="hello-changes" aria-label="what Save changes">
          <thead>
            <tr>
              <th>agent type</th>
              <th>launchers</th>
              <th>spawn launcher</th>
            </tr>
          </thead>
          <tbody>
            {changes.map((c) => (
              <tr key={c.type}>
                <td>{c.label}</td>
                <td>
                  <code>{c.launchers[0].join(", ") || "—"}</code> → <code>{c.launchers[1].join(", ")}</code>
                </td>
                <td>
                  <code>{c.spawn[0] || "—"}</code> → <code>{c.spawn[1]}</code>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
      <div className="hello-actions">
        <span className={problem ? "hello-bad" : "muted"}>
          {problem ??
            (changes.length
              ? `default: ${def} · Save changes ${changes.length} agent type${changes.length === 1 ? "" : "s"}`
              : `default: ${def} · nothing changes`)}
        </span>
        <button type="button" className="btn primary" disabled={!!problem || saving} onClick={() => void save()}>
          {saving ? "Saving…" : "Save launchers"}
        </button>
      </div>
      {saveError && (
        <div className="flash bad" role="alert">
          <i className="dot bad" />
          <span>{saveError}</span>
        </div>
      )}
    </section>
  );
}

export function Hello() {
  useTitle("hello");
  const navigate = useNavigate();
  const { data, error, reload } = useResource<SetupData>(KEY);
  const [step, setStep] = useState(0);
  const [saved, setSaved] = useState<AgentSettingsData | null>(null);
  const [finishing, setFinishing] = useState(false);
  const [finishError, setFinishError] = useState<string | null>(null);
  const agents = saved ?? data?.agents ?? null;
  const summary = useMemo(() => {
    if (!agents) return null;
    const lead = agents.doc.agent_types.find((t) => t.key === "lead") ?? agents.doc.agent_types[0];
    return {
      launchers: agents.doc.launchers.map((l) => l.label),
      def: lead?.spawn_launcher ?? lead?.launchers[0] ?? "—",
    };
  }, [agents]);

  const finish = async () => {
    setFinishing(true);
    setFinishError(null);
    try {
      await apiPost<SetupData>("/api/setup/complete", {});
      markSetupDone();
      invalidate(KEY);
      void navigate("/");
    } catch (e) {
      setFinishError(e instanceof ApiError ? `${e.status} · ${e.message}` : String(e));
      setFinishing(false);
    }
  };

  return (
    <div className="hello">
      <header className="hello-top">
        <ol className="hello-steps">
          {STEPS.map((s, i) => (
            <li key={s} className={i === step ? "now" : i < step ? "past" : ""}>
              <span>{i + 1}</span> {s}
            </li>
          ))}
        </ol>
        <button type="button" className="btn small" disabled={finishing} onClick={() => void finish()}>
          Skip setup
        </button>
      </header>
      {error && !data && <ErrorState error={error} what="setup" retry={reload} />}
      {step === 0 && <Boot checks={data ? data.checks : null} onNext={() => setStep(1)} />}
      {step > 0 && data && agents && (
        <div className="hello-body">
          <div className="hello-main">
            {step === 1 && <Projects data={data} />}
            {step === 2 && (
              <Agents
                key={agents.revision.id}
                agents={agents}
                onSaved={(s) => {
                  setSaved(s);
                  setStep(3);
                }}
              />
            )}
            {step === 3 && summary && (
              <section className="hello-step">
                <h2>Ready</h2>
                <dl className="hello-facts">
                  <dt>repos</dt>
                  <dd>{data.projects.repos}</dd>
                  <dt>launchers</dt>
                  <dd>{summary.launchers.join(" · ")}</dd>
                  <dt>default</dt>
                  <dd>
                    <code>{summary.def}</code>
                  </dd>
                  <dt>checks</dt>
                  <dd>
                    {data.checks.filter((c) => c.ok).length}/{data.checks.length} ok
                  </dd>
                </dl>
                <div className="hello-actions">
                  <span />
                  <button type="button" className="btn primary" disabled={finishing} onClick={() => void finish()}>
                    {finishing ? "Finishing…" : "Open busyyaks"}
                  </button>
                </div>
              </section>
            )}
            <div className="hello-nav">
              <button type="button" className="btn" onClick={() => setStep(step - 1)}>
                Back
              </button>
              {step < 3 && (
                <button type="button" className="btn" onClick={() => setStep(step + 1)}>
                  {step === 2 ? "Keep current launchers" : "Next"}
                </button>
              )}
            </div>
            {finishError && (
              <div className="flash bad" role="alert">
                <i className="dot bad" />
                <span>{finishError}</span>
              </div>
            )}
          </div>
          <AskAgent data={data} />
        </div>
      )}
    </div>
  );
}
