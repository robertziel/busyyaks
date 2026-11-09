// Click to copy: the text is the button. "copied ✓" for a moment; a refused clipboard (no HTTPS, denied) says so.
import { useState, type ReactNode } from "react";

export function CopyChip({
  text,
  children,
  title,
  className = "",
}: {
  text: string;
  children?: ReactNode;
  title?: string;
  className?: string;
}) {
  const [state, setState] = useState<"idle" | "done" | "fail">("idle");
  const copy = () => {
    if (!navigator.clipboard) {
      setState("fail");
      return;
    }
    navigator.clipboard.writeText(text).then(
      () => setState("done"),
      () => setState("fail"),
    );
    window.setTimeout(() => setState("idle"), 1500);
  };
  return (
    <button
      type="button"
      className={`copychip ${state} ${className}`}
      onClick={copy}
      title={title ?? `Copy: ${text}`}
      aria-label={`Copy ${text}`}
    >
      {children ?? <code>{text}</code>}
      <span className="copystate" aria-live="polite">
        {state === "done" ? "copied ✓" : state === "fail" ? "copy refused" : ""}
      </span>
    </button>
  );
}

// Copies the ssh + tmux attach command for your own terminal (iTerm): paste and you are in the session.
export function ItermCopy({ command }: { command: string }) {
  return (
    <CopyChip text={command} className="itermcopy" title={`Copy for iTerm: ${command}`}>
      <span className="termlink">iTerm ⧉</span>
    </CopyChip>
  );
}

export function ClaudeLink({ url, name }: { url: string | null; name: string }) {
  if (!url) return null; // no Remote Control session for this one (not started with --remote-control, or Hermes)
  return (
    <a
      className="termlink claudelink"
      href={url}
      target="_blank"
      rel="noopener"
      title={`Open ${name} in Claude (Remote Control)`}
    >
      Claude ↗
    </a>
  );
}

export function TerminalLink({ url, name }: { url: string; name: string }) {
  return (
    <a className="termlink" href={url} target="_blank" rel="noopener" title={`Open ${name} in the team terminal`}>
      Terminal ↗
    </a>
  );
}
