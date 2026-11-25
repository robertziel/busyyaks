// The git host cards: one per provider of GET /api/settings/git-hosts — GitHub connected (login · token
// hint · since · the collector's last run · Disconnect, confirmed in the page) or a token to paste + Connect; GitLab
// the same card, disabled, "coming soon". Rendered by Settings → Git hosts and the /hello wizard's Git host step.
// The token lives only in this component's state until the POST, and is cleared whatever the answer.
import { useState, type FormEvent } from "react";
import { Link } from "react-router-dom";
import { ApiError, apiDelete, apiPost, invalidate, useResource } from "../api";
import { at } from "../lib/format";
import {
  GIT_HOSTS_KEY,
  GIT_HOSTS_PATH,
  cardState,
  collectorLine,
  connectRefusal,
  failure,
  offParts,
  testedLine,
  type GitHostConnection,
  type GitHostProvider,
  type GitHostsData,
  type GitHostTest,
} from "../lib/gitHosts";
import { ErrorState, Loading } from "./States";

// every read that depends on the connection
const DEPENDENT = [GIT_HOSTS_KEY, "/api/today", "/api/github", "/api/setup"];

type Failure = { key: string; text: string; mayApply: boolean };

export type CardProps = {
  provider: GitHostProvider;
  data: GitHostsData;
  token: string;
  onToken: (v: string) => void;
  busy: boolean;
  failed: Failure | null;
  confirming: boolean;
  onConnect: () => void;
  onAskDisconnect: () => void;
  onDisconnect: () => void;
  onCancel: () => void;
  onReload: () => void;
  // Test connection: the stored token asked again (POST …/test); its answer, or null before any test
  onTest: () => void;
  tested: string | null;
  now?: number;
};

export function ProviderCard(p: CardProps) {
  const { provider, data } = p;
  const state = cardState(provider, data.current);
  const id = `gith-${provider.key}`;
  const failed = p.failed && p.failed.key === provider.key ? p.failed : null;
  return (
    <section className={`card gith-host ${state}`} aria-labelledby={`${id}-h`}>
      <div className="gith-host-head">
        <h2 id={`${id}-h`}>{provider.label}</h2>
        {state === "connected" && <span className="gith-badge ok">connected</span>}
        {state === "open" && <span className="gith-badge">not connected</span>}
        {state === "soon" && <span className="gith-badge soon">{provider.note ?? "coming soon"}</span>}
      </div>
      {state === "connected" && data.current && (
        <Connected
          current={data.current}
          data={data}
          busy={p.busy}
          confirming={p.confirming}
          onAsk={p.onAskDisconnect}
          onDisconnect={p.onDisconnect}
          onCancel={p.onCancel}
          onTest={p.onTest}
          tested={p.tested}
          now={p.now}
        />
      )}
      {state !== "connected" && (
        <TokenForm
          id={id}
          provider={provider}
          disabled={state === "soon"}
          token={state === "soon" ? "" : p.token}
          onToken={p.onToken}
          refusal={
            state === "soon"
              ? (provider.note ?? "coming soon")
              : connectRefusal(p.token, p.busy, data.current, provider.key)
          }
          busy={p.busy}
          onConnect={p.onConnect}
        />
      )}
      {failed && (
        <div className="gith-fail" role="alert">
          <span>{failed.text}</span>
          {failed.mayApply && (
            <>
              <span>the change may still apply</span>
              <button type="button" className="btn small" onClick={p.onReload}>
                Reload
              </button>
            </>
          )}
        </div>
      )}
    </section>
  );
}

function Connected({
  current,
  data,
  busy,
  confirming,
  onAsk,
  onDisconnect,
  onCancel,
  onTest,
  tested,
  now,
}: {
  current: GitHostConnection;
  data: GitHostsData;
  busy: boolean;
  confirming: boolean;
  onAsk: () => void;
  onDisconnect: () => void;
  onCancel: () => void;
  onTest: () => void;
  tested: string | null;
  now?: number;
}) {
  const col = collectorLine(data.collector, now);
  return (
    <>
      <dl className="gith-facts">
        <dt>login</dt>
        <dd>
          Connected as <b>{current.login}</b>
        </dd>
        <dt>token</dt>
        <dd className="mono">{current.token_hint}</dd>
        <dt>since</dt>
        <dd>
          {at(current.at)} · {current.author}
        </dd>
        <dt>collector</dt>
        <dd className={`gith-${col.tone}`}>{col.text}</dd>
      </dl>
      <div className="gith-bar">
        {confirming ? (
          <>
            <span className="gith-warn" role="status">
              Disconnect {current.label}? Collection and PR reads stop; the token is deleted.
            </span>
            <button type="button" className="btn gith-danger" aria-disabled={busy || undefined} onClick={onDisconnect}>
              {busy ? "Disconnecting…" : "Disconnect"}
            </button>
            <button type="button" className="btn" aria-disabled={busy || undefined} onClick={onCancel}>
              Cancel
            </button>
          </>
        ) : (
          <>
            <button type="button" className="btn" aria-disabled={busy || undefined} onClick={onTest}>
              {busy ? "Testing…" : "Test connection"}
            </button>
            <button type="button" className="btn" onClick={onAsk}>
              Disconnect
            </button>
          </>
        )}
      </div>
      {tested && (
        <p className="gith-ok" role="status">
          {tested}
        </p>
      )}
    </>
  );
}

function TokenForm({
  id,
  provider,
  disabled,
  token,
  onToken,
  refusal,
  busy,
  onConnect,
}: {
  id: string;
  provider: GitHostProvider;
  disabled: boolean;
  token: string;
  onToken: (v: string) => void;
  refusal: string | null;
  busy: boolean;
  onConnect: () => void;
}) {
  const submit = (e: FormEvent) => {
    e.preventDefault();
    if (!refusal) onConnect();
  };
  return (
    <form className="gith-form" onSubmit={submit} noValidate>
      <label htmlFor={`${id}-token`}>{provider.label} token</label>
      <input
        id={`${id}-token`}
        type="password"
        value={token}
        onChange={(e) => onToken(e.target.value)}
        disabled={disabled}
        readOnly={busy}
        autoComplete="off"
        spellCheck={false}
        aria-describedby={`${id}-hint ${id}-why`}
      />
      <p className="gith-hint" id={`${id}-hint`}>
        a read-only token is enough: <code>gh auth token</code>, or a fine-grained token with no repository access
      </p>
      <div className="gith-bar">
        {disabled ? (
          <button type="button" className="btn primary" disabled>
            Connect
          </button>
        ) : (
          // aria-disabled, not disabled: Connect stays in the Tab order and says why it is off
          <button type="submit" className="btn primary" aria-disabled={!!refusal || undefined}>
            {busy ? "Connecting…" : "Connect"}
          </button>
        )}
        <span className="gith-why muted" id={`${id}-why`} aria-live="polite">
          {refusal ?? ""}
        </span>
      </div>
    </form>
  );
}

// the loaded cards: GET /api/settings/git-hosts, Connect = POST {provider, token}, Disconnect = DELETE
export function GitHosts() {
  const { data, error, loading, reload } = useResource<GitHostsData>(GIT_HOSTS_KEY);
  const [tokens, setTokens] = useState<Record<string, string>>({});
  const [busy, setBusy] = useState(false);
  const [failed, setFailed] = useState<Failure | null>(null);
  const [confirming, setConfirming] = useState(false);
  const [tested, setTested] = useState<string | null>(null);

  if (loading) return <Loading what="git hosts" />;
  if (error && !data) return <ErrorState error={error} what="git hosts" retry={reload} />;
  if (!data) return null;

  const fail = (key: string, e: unknown) => {
    const f = e instanceof ApiError ? failure(e.status, e.message) : failure(0, String(e));
    setFailed({ key, ...f });
  };
  const done = () => DEPENDENT.forEach((k) => invalidate(k));

  const connect = async (key: string) => {
    const token = tokens[key] ?? "";
    if (busy || connectRefusal(token, busy, data.current, key)) return;
    setBusy(true);
    setFailed(null);
    setTokens((t) => ({ ...t, [key]: "" })); // never kept past the save, whatever the answer
    try {
      await apiPost(GIT_HOSTS_KEY, { provider: key, token });
      done();
    } catch (e) {
      fail(key, e);
    } finally {
      setBusy(false);
    }
  };
  const test = async (key: string) => {
    if (busy) return;
    setBusy(true);
    setFailed(null);
    setTested(null);
    try {
      setTested(testedLine(await apiPost<GitHostTest>(`${GIT_HOSTS_KEY}/test`, {})));
    } catch (e) {
      fail(key, e);
    } finally {
      setBusy(false);
    }
  };
  const disconnect = async (key: string) => {
    if (busy) return;
    setBusy(true);
    setFailed(null);
    try {
      await apiDelete(GIT_HOSTS_KEY);
      setConfirming(false);
      done();
    } catch (e) {
      fail(key, e);
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="gith-hosts">
      {error && <ErrorState error={error} what="refresh" retry={reload} />}
      {data.providers.map((p) => (
        <ProviderCard
          key={p.key}
          provider={p}
          data={data}
          token={tokens[p.key] ?? ""}
          onToken={(v) => {
            setTokens((t) => ({ ...t, [p.key]: v }));
            setFailed(null);
          }}
          busy={busy}
          failed={failed}
          confirming={confirming}
          onConnect={() => void connect(p.key)}
          onAskDisconnect={() => {
            setConfirming(true);
            setFailed(null);
          }}
          onDisconnect={() => void disconnect(p.key)}
          onTest={() => void test(p.key)}
          tested={tested}
          onCancel={() => setConfirming(false)}
          onReload={() => {
            setFailed(null);
            done();
          }}
        />
      ))}
    </div>
  );
}

// "GitHub not connected — Settings → Git hosts" with its last part linking to the page (Today, /github)
export function GitHostOff({ text, className = "muted" }: { text: string; className?: string }) {
  const { lead, link } = offParts(text);
  return (
    <p className={`gith-off ${className}`}>
      <i className="dot" /> {lead}
      <Link to={GIT_HOSTS_PATH}>{link}</Link>
    </p>
  );
}
