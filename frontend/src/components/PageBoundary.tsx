// A page that throws while rendering shows the broken yak with the error, never a blank screen (card 672). Moving to
// another path clears it (the page renders again, nothing remounted); Reload reloads this one.
import { Component, type ErrorInfo, type ReactNode } from "react";
import { Mascot } from "./Mascot";

export class PageBoundary extends Component<{ path: string; children: ReactNode }, { error: Error | null }> {
  state: { error: Error | null } = { error: null };

  static getDerivedStateFromError(error: unknown) {
    return { error: error instanceof Error ? error : new Error(String(error)) };
  }

  componentDidUpdate(prev: { path: string }) {
    if (prev.path !== this.props.path && this.state.error) this.setState({ error: null });
  }

  componentDidCatch(error: unknown, info: ErrorInfo) {
    console.error("page crashed", error, info.componentStack);
  }

  render() {
    const { error } = this.state;
    if (!error) return this.props.children;
    return <PageCrashed error={error} />;
  }
}

export function PageCrashed({ error }: { error: Error }) {
  return (
    <div role="alert">
      <Mascot scene="broken" title="This page crashed">
        <p className="mascot-detail">
          <code>{error.message || error.name}</code>
        </p>
        <p className="mascot-links">
          <button type="button" className="btn small" onClick={() => window.location.reload()}>
            Reload
          </button>
        </p>
      </Mascot>
    </div>
  );
}
