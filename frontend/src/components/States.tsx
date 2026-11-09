// Loading / error / empty states that say what is missing. No placeholder data, ever.
import type { ApiError } from "../api";
import { YakLoader } from "./YakLoader";

// inline: a loader inside a section (a row, no reserved height) instead of one standing in for the whole page
export function Loading({ what, inline = false }: { what: string; inline?: boolean }) {
  return (
    <p className={`state loading${inline ? " inline" : ""}`} role="status" aria-live="polite">
      <YakLoader /> loading {what}…
    </p>
  );
}

// retry = a Resource's reload, which never rejects (revalidate keeps a failure as the entry's error, shown here)
export function ErrorState({ error, what, retry }: { error: ApiError; what: string; retry?: () => Promise<void> }) {
  return (
    <div className="flash bad" role="alert">
      <i className="dot bad" />
      <span>
        {what}: {error.status ? `${error.status} · ` : ""}
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
