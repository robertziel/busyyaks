// /hello — the setup wizard (card #315; re-enterable settings + harness detection, card 520). Five steps, any of them
// reachable from the stepper and named in the URL (?step=checks|skin|projects|agents|summary): Checks (every check
// GET /api/setup ran; first run: the trotting yak ticks them in), Skin (this browser's skin, applied live), Projects
// (the host dir, read-only — .env), Agents (the agent CLIs the launcher finds on the host — GET /api/setup/harnesses —
// and which allowlisted commands become launchers + the default: a new agent settings revision) and Summary (the
// current values, an Edit per row). Two modes from GET /api/setup's `completed`: a FIRST RUN (the shell opens /hello
// while <meta name="setup"> is "pending"; Skip setup / Open busyyaks POST /api/setup/complete) and a REOPEN from the
// settings cog (lands on Summary, Close / Done write nothing). The Agents draft lives here, so jumping steps keeps
// it; leaving with it unsaved brings you back to Agents. Every step carries "ask your agent to set it up for you"
// with a prompt to copy: the host-only parts (.env, the launch.commands allowlist) are its job, never this page's.
import { useEffect, useMemo, useRef, useState } from "react";
import { Link, useNavigate, useSearchParams } from "react-router-dom";
import { ApiError, apiPost, invalidate, useResource } from "../api";
import { CopyChip } from "../components/Copy";
import { SkinSwitch, skinName } from "../components/Skin";
import { ErrorState } from "../components/States";
import { YakLoader } from "../components/YakLoader";
import { type AgentSettingsData, type Invocation } from "../lib/agentSettings";
import {
  RESTART_BOTH,
  STEP_KEYS,
  STEP_LABELS,
  agentPrompt,
  applyRows,
  defaultFrom,
  draftDirty,
  harnessLine,
  harnessState,
  keepDefault,
  rowsError,
  rowsFrom,
  stepFrom,
  typeChanges,
  usedMissing,
  type Check,
  type Harness,
  type HarnessesData,
  type Resolved,
  type Row,
  type SetupData,
  type StepKey,
} from "../lib/hello";
import { markSetupDone } from "../lib/setupGate";
import { useTitle } from "../lib/title";

const KEY = "/api/setup";
const HARNESSES = "/api/setup/harnesses";
export const STEPS = STEP_KEYS.map((k) => STEP_LABELS[k]);
const TICK_MS = 420; // one boot check revealed per tick (first run)
const reducedMotion = () =>
  typeof window !== "undefined" && !!window.matchMedia?.("(prefers-reduced-motion: reduce)").matches;
const clock = (epoch: number) => new Date(epoch * 1000).toLocaleTimeString([], { hour12: false });
const day = (epoch: number) => new Date(epoch * 1000).toISOString().slice(0, 10);
const plural = (n: number, w: string) => `${n} ${w}${n === 1 ? "" : "s"}`;
const why = (e: unknown) => (e instanceof ApiError ? `${e.status} · ${e.message}` : String(e));
// the boot animation plays once per tab (a reload or a deep link to Checks does not replay it)
const BOOTED = "busyyaks.hello-booted";
const readBooted = () => {
  try {
    return window.sessionStorage.getItem(BOOTED) === "1";
  } catch {
    return false;
  }
};
const writeBooted = () => {
  try {
    window.sessionStorage.setItem(BOOTED, "1");
  } catch {
    // storage refused (private window): the animation may play again, nothing else depends on it
  }
};

function RestartBoth() {
  return (
    <>
      {RESTART_BOTH.map((c) => (
        <CopyChip key={c} text={c} title={`Copy: ${c}`}>
          <code>{c}</code>
        </CopyChip>
      ))}
    </>
  );
}

function CheckRows({ checks }: { checks: Check[] }) {
  return (
    <>
      {checks.map((c) => (
        <li key={c.key} className={c.ok ? "ok" : "bad"}>
          <span className="hello-mark">{c.ok ? "✓" : "✗"}</span>
          <b>{c.label}</b>
          <span className="muted">{c.detail}</span>
        </li>
      ))}
    </>
  );
}

// first run: the boot screen, the checks ticking in
function Boot({ checks, onNext }: { checks: Check[] | null; onNext: () => void }) {
  const [shown, setShown] = useState(() => (reducedMotion() ? Infinity : 0));
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
            className={i < Math.ceil((Math.min(shown, total) / Math.max(total, 1)) * 5) ? "on" : ""}
          />
        ))}
      </div>
      <ul className="hello-checks" aria-live="polite">
        <CheckRows checks={(checks ?? []).slice(0, shown)} />
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

// reopen: the checks at once, failed first, re-readable
function Checks({ checks, onRecheck, rechecking }: { checks: Check[]; onRecheck: () => void; rechecking: boolean }) {
  const failed = checks.filter((c) => !c.ok);
  return (
    <section className="hello-step">
      <StepHeading>Checks</StepHeading>
      <p className="muted">
        {checks.length - failed.length}/{checks.length} ok
        {failed.length > 0 && <b className="hello-bad"> · {failed.length} failed</b>}
      </p>
      <ul className="hello-checks">
        <CheckRows checks={[...failed, ...checks.filter((c) => c.ok)]} />
      </ul>
      <div className="hello-actions">
        <span />
        <button type="button" className="btn" aria-busy={rechecking} disabled={rechecking} onClick={onRecheck}>
          {rechecking ? "Checking…" : "Re-check"}
        </button>
      </div>
    </section>
  );
}

// the step's heading takes the focus when the step changes (a screen reader hears where it is)
function StepHeading({ children }: { children: React.ReactNode }) {
  const ref = useRef<HTMLHeadingElement>(null);
  useEffect(() => ref.current?.focus({ preventScroll: true }), []);
  return (
    <h2 ref={ref} tabIndex={-1}>
      {children}
    </h2>
  );
}

function AskAgent({ prompt, open }: { prompt: string; open: boolean }) {
  return (
    <details className="hello-ask" open={open || typeof window === "undefined" || window.innerWidth > 760}>
      <summary>
        <b>Ask your agent to set it up for you</b>
      </summary>
      <span className="muted">paste into Claude Code, hermes or any agent on this host</span>
      <pre>{prompt}</pre>
      <CopyChip text={prompt} title="Copy prompt">
        <span className="btn small">Copy prompt</span>
      </CopyChip>
    </details>
  );
}

export function Skin() {
  const [, bump] = useState(0);
  useEffect(() => {
    const on = () => bump((n) => n + 1);
    document.addEventListener("busyyaks:skin", on);
    return () => document.removeEventListener("busyyaks:skin", on);
  }, []);
  return (
    <section className="hello-step">
      <StepHeading>Skin</StepHeading>
      <div className="hello-skin">
        <SkinSwitch />
      </div>
      <p className="muted hello-host">
        current: {skinName()} · stored in this browser · settings cog → Skin · more: <code>skins/&lt;key&gt;.yml</code>{" "}
        (host, restart)
      </p>
    </section>
  );
}

function Projects({ data }: { data: SetupData }) {
  const p = data.projects;
  const scan = data.checks.find((c) => c.key === "scanner");
  return (
    <section className="hello-step">
      <StepHeading>Projects</StepHeading>
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
          <b className={p.repos === 0 ? "hello-bad" : ""}>
            {p.repos}
            {p.repos === 0 && ` repos under ${p.host_root}`}
          </b>
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
        {scan && (
          <>
            <dt>scan</dt>
            <dd className={scan.ok ? "muted" : "hello-bad"}>
              {scan.ok ? "✓" : "✗"} {scan.detail}
            </dd>
          </>
        )}
      </dl>
      <p className="muted hello-host">
        change (host only): <code>.env</code>{" "}
        <CopyChip text="PROJECTS_ROOT=/path/to/projects" title="Copy: PROJECTS_ROOT=/path/to/projects">
          <code>PROJECTS_ROOT=/path/to/projects</code>
        </CopyChip>{" "}
        →{" "}
        <CopyChip text="docker compose up -d" title="Copy: docker compose up -d">
          <code>docker compose up -d</code>
        </CopyChip>
      </p>
    </section>
  );
}

type Detect = { data: HarnessesData | undefined; error: ApiError | undefined; checking: boolean; recheck: () => void };

const commandWords = (c: Invocation) => [c.command, ...c.args].join(" ") + (c.via_shell ? " (via shell)" : "");
// an existing launcher's own invocation (one no allowlist entry matches: its row still names what it runs)
const launcherWords = (agents: AgentSettingsData, key: string) => {
  const l = agents.doc.launchers.find((x) => x.key === key);
  return l ? commandWords(l) : key;
};

function HarnessCard({ h, commands, resolved }: { h: Harness; commands: Invocation[]; resolved: Resolved[] }) {
  const st = harnessState(h, resolved);
  return (
    <article className={`hello-harness ${st.tone}`} aria-label={`${h.label}: ${st.badge}`}>
      <header>
        <b>{h.label}</b>
        <span className={`hello-badge ${st.tone}`}>{st.badge}</span>
        {!h.launchable && <span className="hello-badge warn">not supported yet</span>}
      </header>
      {h.found ? (
        <>
          <div className="hello-ver">
            {h.version ?? (h.type === "file" ? <span className="hello-bad">version: {h.version_error}</span> : null)}
            {h.type !== "file" && <span className="muted">shell {h.type} · version not run</span>}
          </div>
          {h.path && <code className="hello-path">{h.path}</code>}
        </>
      ) : (
        <div className="muted">
          <code>{h.command}</code> · not installed (not on PATH)
        </div>
      )}
      {h.launchable ? (
        <div className="hello-allowed">
          <span className={h.allowed.length === 0 && h.found ? "hello-warn" : "muted"}>
            {h.allowed.length === 0
              ? `no ${h.label} launcher allowed`
              : `allowed launchers of the ${h.label} kind (own name or a wrapper):`}
          </span>
          {h.allowed.map((i) => {
            const r = resolved.find((x) => x.at === i);
            return (
              <span key={i} className={r?.found === false ? "hello-bad" : r?.found ? "hello-ok" : "muted"}>
                <code>{commands[i] ? commandWords(commands[i]) : "?"}</code>{" "}
                {r && r.found !== null ? (r.found ? `✓ ${r.type}` : "✗ not found") : "unknown"}
              </span>
            );
          })}
        </div>
      ) : (
        <div className="muted">busyyaks cannot launch it yet</div>
      )}
      {h.found && h.allow_note && <div className="hello-warn">{h.allow_note}</div>}
      {h.found && h.launchable && h.allowed.length === 0 && h.allow_line && (
        <div className="hello-allow">
          <span className="muted">
            add to <code>config/busyyaks.yml</code>:
          </span>
          <pre>
            <span className="muted">{"launch:\n  commands:\n"}</span>
            {`    ${h.allow_line}`}
          </pre>
          <div className="hello-chips">
            <CopyChip text={`    ${h.allow_line}`} title="Copy line (the launch.commands item)">
              <span className="btn small">Copy line</span>
            </CopyChip>
            <span className="muted">then restart both:</span>
            <RestartBoth />
          </div>
        </div>
      )}
      {!h.found && (
        <a
          className="btn small"
          href={h.install_url}
          target="_blank"
          rel="noopener noreferrer"
          aria-label={`Install ${h.label} (opens ${new URL(h.install_url).host})`}
        >
          Install ↗
        </a>
      )}
    </article>
  );
}

function Harnesses({ detect, commands }: { detect: Detect; commands: Invocation[] }) {
  const { data, error, checking, recheck } = detect;
  const found = data?.harnesses.filter((h) => h.found).length ?? 0;
  return (
    <div className="hello-harnesses" aria-live="polite" aria-busy={checking}>
      <div className="hello-subhead">
        <b>Harnesses</b>
        <span className="muted" title={data ? `${data.elapsed_ms} ms · ${data.shell}` : undefined}>
          {checking && !data && "checking…"}
          {data && `${found}/${data.harnesses.length} found · checked ${clock(data.checked_at)}`}
        </span>
        <button type="button" className="btn small" disabled={checking} aria-busy={checking} onClick={recheck}>
          {checking ? "Checking…" : "Re-check"}
        </button>
      </div>
      {error && !checking ? (
        <div className="flash bad hello-unavailable" role="alert">
          <i className="dot bad" />
          <span title={`${error.status} · ${error.message}`}>
            {error.status === 503 // the API's own status for "launcher unreachable" (SetupAPI.harnesses)
              ? "✗ launcher not running · start it: "
              : `✗ harness check failed: ${error.message} · `}
            <CopyChip text="deploy/install-launcher.sh" title="Copy: deploy/install-launcher.sh">
              <code>deploy/install-launcher.sh</code>
            </CopyChip>
          </span>
        </div>
      ) : (
        <>
          {data && !data.allowlist_in_sync && (
            <div className="flash bad" role="alert">
              <i className="dot bad" />
              <span>
                ✗ the launcher and the dashboard read different <code>launch.commands</code> · restart both:{" "}
                <RestartBoth />
              </span>
            </div>
          )}
          <div className={`hello-harness-grid${checking && data ? " stale" : ""}`}>
            {data
              ? data.harnesses.map((h) => (
                  <HarnessCard key={h.key} h={h} commands={commands} resolved={data.commands} />
                ))
              : [0, 1, 2].map((i) => <article key={i} className="hello-harness skeleton" aria-hidden="true" />)}
          </div>
        </>
      )}
    </div>
  );
}

type Draft = { rows: Row[]; def: string };
// "2 agent types change · 1 follows the lead": the types that choose a launcher, then the ones under the lead
const changeCount = (changes: { under: string | null }[]) => {
  const own = changes.filter((c) => !c.under).length;
  const follow = changes.length - own;
  return [
    own ? `${plural(own, "agent type")} change` : "",
    follow ? `${follow} follow${follow === 1 ? "s" : ""} the lead` : "",
  ]
    .filter(Boolean)
    .join(" · ");
};

// the saved default: the lead's first launcher (the Launch menu's first entry); no lead type or no launcher → "" (said
// as an issue on the Summary, never another type's launcher shown in its place)
const defaultOf = (agents: AgentSettingsData) =>
  agents.doc.agent_types.find((t) => t.key === "lead")?.launchers[0] ?? "";
type SaveState = { saving: boolean; error: ApiError | Error | null; saved: number | null };

function hostCell(r: Row, detect: Detect) {
  if (r.at < 0) return <span className="muted">—</span>;
  if (detect.error || !detect.data) return <span className="muted">{detect.checking ? "…" : "unknown"}</span>;
  const c = detect.data.commands.find((x) => x.at === r.at);
  if (!c) return <span className="muted">unknown</span>;
  if (c.found === null) return <span className="muted">unknown</span>; // the launcher has not read it yet
  return c.found ? <span className="hello-ok">✓ {c.type}</span> : <span className="hello-bad">✗ not found</span>;
}

function Agents({
  agents,
  draft,
  setDraft,
  dirty,
  edited,
  firstRun,
  save,
  discard,
  reload,
  saveState,
  detect,
  flash,
  kindLabels,
}: {
  kindLabels: Record<string, string>;
  agents: AgentSettingsData;
  draft: Draft;
  setDraft: (d: Draft) => void;
  dirty: boolean;
  edited: boolean; // the operator changed something (Discard undoes it; a stale saved launcher alone is not an edit)
  firstRun: boolean;
  save: () => void;
  discard: () => void;
  reload: () => void;
  saveState: SaveState;
  detect: Detect;
  flash: string | null;
}) {
  const { rows, def } = draft;
  const problem = rowsError(rows, def);
  const set = (i: number, r: Partial<Row>) => {
    const next = rows.map((x, j) => (j === i ? { ...x, ...r } : x));
    setDraft({ rows: next, def: keepDefault(next, def) });
  };
  const dropped = rows.filter((r) => r.existing && r.at < 0);
  const changes = problem ? [] : typeChanges(agents.doc, applyRows(agents.doc, agents.commands, rows, def));
  const missing = usedMissing(rows, detect.data?.commands ?? null);
  const kinds = useMemo(
    () =>
      [...new Set(rows.map((r) => (r.at >= 0 ? agents.commands[r.at]!.kind : "")))].map((k) => ({
        kind: k,
        label: k ? (kindLabels[k] ?? `${k} (no harness in config/harnesses.yml)`) : "not allowed on this host",
      })),
    [rows, agents.commands, kindLabels],
  );
  // the first view says what to do; an error shows red only once the operator changed something
  const pristine = !dirty && problem === "pick at least one command";
  const baseDef = defaultOf(agents);
  const defMove = def !== baseDef ? `default ${baseDef || "—"} → ${def}` : `default: ${def}`;
  const status = pristine
    ? "0 launchers in use · tick use on a command"
    : (problem ??
      (changes.length
        ? `${defMove} · ${changeCount(changes)}`
        : dirty
          ? `${defMove} · the launchers change`
          : `default: ${def} · nothing changes`));

  return (
    <section className="hello-step">
      <StepHeading>Agents</StepHeading>
      <Harnesses detect={detect} commands={agents.commands} />
      <div className="hello-subhead">
        <b>Launchers</b>
        <span className="muted">
          <span title={`revision ${agents.revision.id} · by ${agents.revision.author}`}>
            {plural(agents.commands.length, "command")} allowed on this host · saved {day(agents.revision.at)}
          </span>
        </span>
      </div>
      {agents.error && (
        <div className="flash bad" role="alert">
          <i className="dot bad" />
          <span>the saved launchers do not run: {agents.error}</span>
        </div>
      )}
      <table className="hello-agents">
        <thead>
          <tr>
            <th>use</th>
            <th>command</th>
            <th>host</th>
            <th>key</th>
            <th>label</th>
            <th>default</th>
          </tr>
        </thead>
        {kinds.map((g) => (
          <tbody key={g.kind}>
            <tr className="group">
              <th colSpan={6} scope="rowgroup">
                {g.label} ·{" "}
                {plural(rows.filter((r) => (r.at >= 0 ? agents.commands[r.at]!.kind : "") === g.kind).length, "row")}
              </th>
            </tr>
            {rows.map((r, i) => {
              const c = r.at >= 0 ? agents.commands[r.at] : undefined;
              if ((c?.kind ?? "") !== g.kind) return null;
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
                    {c ? (
                      <code>{commandWords(c)}</code>
                    ) : (
                      <>
                        <code>{launcherWords(agents, r.key)}</code>{" "}
                        <span className="hello-bad">not allowed on this host</span>
                      </>
                    )}
                  </td>
                  <td>{hostCell(r, detect)}</td>
                  <td data-label="key">
                    <input
                      value={r.key}
                      disabled={r.existing || !r.use}
                      spellCheck={false}
                      aria-label={`key of ${r.key}`}
                      onChange={(e) =>
                        setDraft({
                          rows: rows.map((x, j) => (j === i ? { ...x, key: e.target.value } : x)),
                          def: def === r.key ? e.target.value : def,
                        })
                      }
                    />
                  </td>
                  <td data-label="label">
                    <input
                      value={r.label}
                      disabled={!r.use}
                      aria-label={`label of ${r.key}`}
                      onChange={(e) => set(i, { label: e.target.value })}
                    />
                  </td>
                  <td
                    data-label="default"
                    title={r.use ? undefined : c ? "tick use first" : "not allowed on this host"}
                  >
                    <input
                      type="radio"
                      name="hello-default"
                      aria-label={`default ${r.key}${r.use ? "" : c ? " (tick use first)" : " (not allowed on this host)"}`}
                      checked={def === r.key && r.use}
                      disabled={!r.use}
                      onChange={() => setDraft({ rows, def: r.key })}
                    />
                  </td>
                </tr>
              );
            })}
          </tbody>
        ))}
      </table>
      {dropped.length > 0 && (
        <p className="hello-bad">
          removed on Save (not allowed on this host any more): {dropped.map((r) => r.key).join(", ")}
        </p>
      )}
      {missing.length > 0 && (
        <p className="hello-warn">
          {plural(missing.length, "used launcher")} not found on the host: {missing.join(", ")}
        </p>
      )}
      <p className="muted hello-host">
        more commands: <code>config/busyyaks.yml</code> <code>launch.commands</code> → restart both: <RestartBoth />
        {firstRun ? (
          " · every field: settings cog → Agents & launchers (after setup)"
        ) : (
          <>
            {" "}
            · every field: <Link to="/settings">Agents &amp; launchers</Link>
          </>
        )}
      </p>
      {changes.length > 0 && (
        <table className="hello-changes" aria-label="what Save changes">
          <thead>
            <tr>
              <th>agent type</th>
              <th>launchers now</th>
              <th>after Save</th>
            </tr>
          </thead>
          <tbody>
            {changes.map((c) => (
              <tr key={c.type} className={c.under ? "muted" : undefined}>
                <td>
                  {c.label}
                  {c.under && (
                    <span className="muted">
                      {" "}
                      · runs {agents.doc.agent_types.find((t) => t.key === c.under)?.label ?? c.under}&apos;s launcher
                    </span>
                  )}
                </td>
                <td>
                  <code>{c.launchers[0].join(", ") || "—"}</code>
                </td>
                <td>
                  <code>{c.launchers[1].join(", ")}</code>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
      <div className={`hello-actions hello-savebar${dirty ? " dirty" : ""}`} id="hello-savebar" tabIndex={-1}>
        <span className={problem && !pristine ? "hello-bad" : "muted"}>{status}</span>
        <span className="hello-chips">
          {edited && (
            <button type="button" className="btn" onClick={discard}>
              Discard
            </button>
          )}
          <button
            type="button"
            className="btn primary"
            disabled={!!problem || saveState.saving || (!dirty && !firstRun)}
            onClick={save}
          >
            {saveState.saving ? "Saving…" : firstRun ? (dirty ? "Save & continue" : "Continue") : "Save launchers"}
          </button>
        </span>
      </div>
      {flash && (
        <div className="flash warn" role="alert">
          <i className="dot warn" />
          <span>{flash}</span>
        </div>
      )}
      {saveState.saved !== null && !dirty && (
        <div className="flash ok" role="status" id="hello-saved" tabIndex={-1}>
          <i className="dot ok" />
          <span>saved · revision {saveState.saved}</span>
        </div>
      )}
      {saveState.error && (
        <div className="flash bad" role="alert">
          <i className="dot bad" />
          <span>{why(saveState.error)}</span>
          {saveState.error instanceof ApiError && saveState.error.status === 409 && (
            <button type="button" className="btn small" title="discards your edits" onClick={reload}>
              Load the newest revision
            </button>
          )}
        </div>
      )}
    </section>
  );
}

// the saved launchers, each with what stops it on this host (null = nothing found wrong)
export type Summary = { launchers: { key: string; label: string; problem: string | null }[]; def: string };

// the Summary's facts: the current skin, projects, harnesses, launchers, checks and daily report — each with its
// step to edit it (onEdit null: none, e.g. a test render)
export function ReadyFacts({
  data,
  summary,
  harnesses,
  checks = data.checks,
  firstRun = false,
  onEdit = null,
}: {
  data: SetupData;
  summary: Summary;
  harnesses?: { data?: HarnessesData; error?: ApiError } | null;
  checks?: Check[];
  firstRun?: boolean;
  onEdit?: ((s: StepKey) => void) | null;
}) {
  const edit = (s: StepKey, label = "Edit") =>
    onEdit && (
      <button type="button" className="btn small" onClick={() => onEdit(s)}>
        {label}
      </button>
    );
  const failed = checks.filter((c) => !c.ok);
  const dr = data.daily_report;
  const hd = harnesses?.data;
  return (
    <dl className="hello-facts">
      <dt>skin</dt>
      <dd>
        {skinName()}
        {edit("skin")}
      </dd>
      <dt>repos</dt>
      <dd>
        {data.projects.repos}
        {data.projects.host_root && <code>{data.projects.host_root}</code>}
        {edit("projects", "View")}
      </dd>
      {harnesses !== undefined && (
        <>
          <dt>harnesses</dt>
          <dd>
            {hd ? (
              hd.harnesses.map((h) => (
                <span key={h.key} className={h.launchable ? `hello-${harnessState(h, hd.commands).tone}` : "muted"}>
                  {harnessLine(h, hd.commands)}
                </span>
              ))
            ) : harnesses?.error ? (
              <span className="hello-bad">unavailable · {harnesses.error.message}</span>
            ) : (
              "checking…"
            )}
            {edit("agents")}
          </dd>
        </>
      )}
      <dt>launchers</dt>
      <dd>
        {summary.launchers.map((l) => (
          <span key={l.key} className={l.problem ? "hello-bad" : ""}>
            {l.problem ? `✗ ${l.label} · ${l.problem}` : l.label}
          </span>
        ))}
        {edit("agents")}
      </dd>
      <dt>default</dt>
      <dd>
        {summary.launchers.find((l) => l.key === summary.def)?.problem ? (
          <span className="hello-bad">
            ✗ <code>{summary.def}</code> · {summary.launchers.find((l) => l.key === summary.def)?.problem}
          </span>
        ) : (
          <code>{summary.def}</code>
        )}
        {edit("agents")}
      </dd>
      <dt>checks</dt>
      <dd>
        {checks.length - failed.length}/{checks.length} ok
        {failed.map((c) => (
          <span key={c.key} className="hello-bad">
            ✗ {c.label}
          </span>
        ))}
        {edit("checks", "View")}
      </dd>
      {dr && (
        <>
          <dt>daily report</dt>
          <dd>
            {dr.configured ? (
              <code>{dr.schedule}</code>
            ) : (
              <span className="hello-bad">{dr.saved ? `✗ ${dr.reason}` : "✗ not set up"}</span>
            )}
            {onEdit &&
              (firstRun ? (
                <span className="muted">after setup: settings cog → Daily report</span>
              ) : (
                <Link className="btn small" to="/settings/daily-report" aria-label="Edit the daily report settings">
                  Edit
                </Link>
              ))}
          </dd>
        </>
      )}
    </dl>
  );
}

export function Hello() {
  const navigate = useNavigate();
  const [params, setParams] = useSearchParams();
  const { data, error, reload, refreshing } = useResource<SetupData>(KEY);
  const hr = useResource<HarnessesData>(HARNESSES);
  const [saved, setSaved] = useState<AgentSettingsData | null>(null);
  const [draft, setDraftState] = useState<(Draft & { rev: number }) | null>(null);
  const [saveState, setSaveState] = useState<SaveState>({ saving: false, error: null, saved: null });
  const [flash, setFlash] = useState<string | null>(null);
  const [finishing, setFinishing] = useState(false);
  const [finishError, setFinishError] = useState<string | null>(null);
  const [booted, setBooted] = useState(readBooted);

  const firstRun = data ? data.completed === null : true;
  const step = stepFrom(params.get("step"), !firstRun);
  useTitle(`hello · ${STEP_LABELS[step]}`);

  const agents = saved && data && saved.revision.id >= data.agents.revision.id ? saved : (data?.agents ?? null);
  const base = useMemo((): Draft | null => {
    if (!agents) return null;
    const rows = rowsFrom(agents.doc, agents.commands);
    return { rows, def: defaultFrom(agents.doc, rows) };
  }, [agents]);
  const current: Draft | null = draft && agents && draft.rev === agents.revision.id ? draft : base;
  // a saved launcher no allowlist entry matches (launch.commands lost it) is a change Save makes: removing it — so the
  // page counts it as unsaved even before any edit (else Save stays disabled and the revision keeps a launcher that
  // cannot run)
  const stale = !!base?.rows.some((r) => r.existing && r.at < 0);
  const edited = !!(current && base && draftDirty(current.rows, current.def, base.rows, base.def));
  const dirty = stale || edited;
  const setDraft = (d: Draft) => {
    if (agents) setDraftState({ ...d, rev: agents.revision.id });
    setFlash(null);
  };

  const detect: Detect = {
    data: hr.error ? undefined : hr.data,
    error: hr.error,
    checking: hr.loading || hr.refreshing,
    recheck: () => void hr.reload(),
  };

  const go = (s: StepKey) => {
    const next = new URLSearchParams(params);
    next.set("step", s);
    setParams(next, { replace: true });
  };

  // leaving with an unsaved Agents draft: back to Agents, the save bar focused, said
  const guarded = (leave: () => void) => () => {
    if (dirty) {
      go("agents");
      setFlash("unsaved launchers · Save or Discard");
      window.setTimeout(() => document.getElementById("hello-savebar")?.focus(), 0);
      return;
    }
    leave();
  };

  const finish = async () => {
    setFinishing(true);
    setFinishError(null);
    try {
      await apiPost<SetupData>("/api/setup/complete", {});
      markSetupDone();
      invalidate(KEY);
      void navigate("/");
    } catch (e) {
      setFinishError(why(e));
      setFinishing(false);
    }
  };
  const close = () => void navigate("/");

  const save = async () => {
    if (!agents || !current) return;
    if (firstRun && !dirty) {
      go("summary"); // nothing changed: no new revision
      return;
    }
    setSaveState({ saving: true, error: null, saved: null });
    setFlash(null);
    try {
      const doc = applyRows(agents.doc, agents.commands, current.rows, current.def);
      const s = await apiPost<AgentSettingsData>("/api/settings/agents", { base: agents.revision.id, doc });
      invalidate("/api/settings/agents");
      setSaved(s);
      setDraftState(null);
      setSaveState({ saving: false, error: null, saved: s.revision.id });
      void reload(); // the checks (Agent launchers) read the saved revision: never show the old verdict as current
      if (firstRun) go("summary");
      else window.setTimeout(() => document.getElementById("hello-saved")?.focus(), 0);
    } catch (e) {
      setSaveState({ saving: false, error: e instanceof Error ? e : new Error(String(e)), saved: null });
    }
  };

  const reloadNewest = async () => {
    setSaved(null);
    setDraftState(null);
    setSaveState({ saving: false, error: null, saved: null });
    invalidate("/api/settings/agents");
    await reload();
  };

  const resolved = hr.error ? null : (hr.data?.commands ?? null);
  const summary = useMemo((): Summary | null => {
    if (!agents || !base) return null;
    const launchers = base.rows
      .filter((r) => r.existing)
      .map((r) => {
        const host = resolved?.find((c) => c.at === r.at);
        const problem = r.at < 0 ? "not allowed on this host" : host?.found === false ? "not found on the host" : null;
        return { key: r.key, label: r.label, problem };
      });
    return { launchers, def: defaultOf(agents) || "—" };
  }, [agents, base, resolved]);
  // the boot checks + one read from the launch shell: are the saved launchers' commands on the host
  const checks = useMemo((): Check[] => {
    if (!data) return [];
    if (!resolved || !base) return data.checks;
    const missing = usedMissing(base.rows, resolved);
    const used = base.rows.filter((r) => r.use && r.at >= 0).length;
    const host: Check = missing.length
      ? { key: "host", label: "Launchers on host", ok: false, detail: `not found: ${missing.join(", ")}` }
      : { key: "host", label: "Launchers on host", ok: true, detail: `${used}/${used} found` };
    return [...data.checks, host];
  }, [data, resolved, base]);
  const usable = summary ? summary.launchers.filter((l) => !l.problem).length : 0;
  const issues = [
    ...(summary && usable === 0 ? ["no usable launcher"] : []),
    ...(summary && summary.def === "—" ? ["no default launcher"] : []),
    ...checks.filter((c) => !c.ok).map((c) => c.label),
    ...(hr.error ? ["harness check"] : []),
    ...(hr.data && !hr.data.allowlist_in_sync ? ["launch.commands out of sync"] : []),
  ];

  const prompt = data
    ? agentPrompt(
        data.projects,
        data.agents.commands,
        window.location.origin,
        hr.error ? { error: `${hr.error.status} · ${hr.error.message}` } : hr.data ? { data: hr.data } : null,
      )
    : "";
  const marks: Partial<Record<StepKey, string>> = {};
  if (checks.some((c) => !c.ok)) marks.checks = "!";
  if (
    agents?.error ||
    hr.error ||
    (hr.data && !hr.data.allowlist_in_sync) ||
    (current && usedMissing(current.rows, resolved).length)
  )
    marks.agents = "!";
  const showBoot = firstRun && step === "checks" && !booted;
  const at = STEP_KEYS.indexOf(step);

  return (
    <div className="hello">
      <header className="hello-top">
        <nav aria-label="Setup steps">
          <ol className="hello-steps">
            {STEP_KEYS.map((s, i) => (
              <li
                key={s}
                className={[s === step ? "now" : firstRun && i < at ? "past" : "", marks[s] ? "mark" : ""]
                  .join(" ")
                  .trim()}
              >
                <button
                  type="button"
                  aria-current={s === step ? "step" : undefined}
                  aria-label={`${STEP_LABELS[s]}${marks[s] ? " · needs attention" : ""}${s === "agents" && dirty ? " · unsaved" : ""}`}
                  disabled={!data}
                  onClick={() => go(s)}
                >
                  <span>{marks[s] ?? i + 1}</span>
                  <em>{STEP_LABELS[s]}</em>
                  {s === "agents" && dirty && <i className="hello-dirty" aria-hidden="true" />}
                </button>
              </li>
            ))}
          </ol>
        </nav>
        {firstRun ? (
          <button
            type="button"
            className="btn small"
            disabled={finishing}
            title="reopen any time: settings cog → Setup"
            onClick={guarded(() => void finish())}
          >
            Skip setup
          </button>
        ) : (
          <button type="button" className="btn small" onClick={guarded(close)}>
            Close
          </button>
        )}
      </header>
      {error && !data && <ErrorState error={error} what="setup" retry={reload} />}
      {!data && !error && <Boot checks={null} onNext={() => {}} />}
      {showBoot && data && (
        <Boot
          checks={checks}
          onNext={() => {
            setBooted(true);
            writeBooted();
            go("skin");
          }}
        />
      )}
      {data && agents && current && !showBoot && (
        <div className="hello-body">
          <div className="hello-main">
            {step === "checks" && (
              <Checks
                checks={checks}
                onRecheck={() => {
                  void reload();
                  void hr.reload();
                }}
                rechecking={refreshing}
              />
            )}
            {step === "skin" && <Skin />}
            {step === "projects" && <Projects data={data} />}
            {step === "agents" && (
              <Agents
                agents={agents}
                draft={current}
                setDraft={setDraft}
                dirty={dirty}
                edited={edited}
                firstRun={firstRun}
                save={() => void save()}
                discard={() => {
                  setDraftState(null);
                  setFlash(null);
                }}
                reload={() => void reloadNewest()}
                saveState={saveState}
                detect={detect}
                flash={flash}
                kindLabels={data.kinds}
              />
            )}
            {step === "summary" && summary && (
              <section className="hello-step">
                <StepHeading>
                  {firstRun ? (issues.length ? "Not ready" : "Ready") : "Setup"}
                  {issues.length > 0 && <span className="hello-bad"> · {plural(issues.length, "issue")}</span>}
                </StepHeading>
                {issues.length > 0 && <p className="hello-bad">✗ {issues.join(" · ")}</p>}
                {data.completed && (
                  <p className="muted">
                    set up by {data.completed.author} · {day(data.completed.at)}
                  </p>
                )}
                <ReadyFacts
                  data={data}
                  summary={summary}
                  harnesses={{ data: detect.data, error: detect.error }}
                  checks={checks}
                  firstRun={firstRun}
                  onEdit={go}
                />
                <div className="hello-actions">
                  <span />
                  {firstRun ? (
                    <button
                      type="button"
                      className="btn primary"
                      disabled={finishing}
                      onClick={guarded(() => void finish())}
                    >
                      {finishing ? "Finishing…" : issues.length ? "Open anyway" : "Open busyyaks"}
                    </button>
                  ) : (
                    <button type="button" className="btn primary" onClick={guarded(close)}>
                      Done
                    </button>
                  )}
                </div>
              </section>
            )}
            <div className="hello-nav">
              {at > 0 ? (
                <button type="button" className="btn" onClick={() => go(STEP_KEYS[at - 1]!)}>
                  Back
                </button>
              ) : (
                <span />
              )}
              {at < STEP_KEYS.length - 1 && (
                <button type="button" className="btn" onClick={() => go(STEP_KEYS[at + 1]!)}>
                  Next
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
          <AskAgent prompt={prompt} open={firstRun} />
        </div>
      )}
    </div>
  );
}
