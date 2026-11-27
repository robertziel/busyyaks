// Loading / error / empty states that say what is missing. No placeholder data, ever.
import type { ApiError } from "../api";
import { sceneFor } from "../lib/mascot";
import { Mascot } from "./Mascot";
import { YakLoader } from "./YakLoader";

// inline: a loader inside a section (a row, no reserved height) instead of one standing in for the whole page
export function Loading({ what, inline = false }: { what: string; inline?: boolean }) {
  return (
    <p className={`state loading${inline ? " inline" : ""}`} role="status" aria-live="polite">
      <YakLoader /> loading {what}…
    </p>
  );
}

// retry = a Resource's reload, which never rejects (revalidate keeps a failure as the entry's error, shown here).
// The yak says what kind of failure it is (card 672): 404 lost, status 0 offline, any other answer broken.
export function ErrorState({ error, what, retry }: { error: ApiError; what: string; retry?: () => Promise<unknown> }) {
  return (
    <div className="state error" role="alert">
      <Mascot scene={sceneFor(error.status)} title={what} size="card">
        <p className="mascot-detail">
          {error.status ? `${error.status} · ` : ""}
          {error.message}
        </p>
        {retry && (
          <button type="button" className="btn small" onClick={() => void retry()}>
            Retry
          </button>
        )}
      </Mascot>
    </div>
  );
}

// a refresh that failed while the last good data is still on the page: one slim bar over it, no yak (the page is not
// empty, and the down banner already carries the offline yak when the server is gone)
export function RefreshError({ error, retry }: { error: ApiError; retry?: () => Promise<unknown> }) {
  return (
    <div className="flash bad" role="alert">
      <i className="dot bad" />
      <span>
        refresh: {error.status ? `${error.status} · ` : ""}
        {error.message}
      </span>
      {retry && (
        <button type="button" className="btn small" onClick={() => void retry()}>
          Retry
        </button>
      )}
    </div>
  );
}

export function Empty({ text }: { text: string }) {
  return <p className="muted">{text}</p>;
}
