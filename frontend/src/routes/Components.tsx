// The live gallery of report components: each tl:* example rendered (server-side) beside its source.
import { useResource } from "../api";
import { Html } from "../components/Html";
import { ErrorState, Loading } from "../components/States";
import { useTitle } from "../lib/title";
import type { ComponentsData } from "../types";

export function Components() {
  useTitle("report components");
  const { data, error, loading, reload } = useResource<ComponentsData>("/api/reports/components");
  if (loading) return <Loading what="component gallery" />;
  if (error && !data) return <ErrorState error={error} what="component gallery" retry={reload} />;
  if (!data) return null;
  return (
    <>
      <h1>Report components · {data.components.length}</h1>
      <p className="muted">
        Fenced block <code>```tl:&lt;name&gt;</code> + YAML · inline <code>repo:slug</code> <code>ok:</code>{" "}
        <code>warn:</code> <code>bad:</code> <code>info:</code> · MCP tool <code>report_components</code>
      </p>
      <nav className="gallery-intro" aria-label="Components">
        {data.components.map((c) => (
          <a key={c.name} href={`#tl-${c.name}`}>
            tl:{c.name}
          </a>
        ))}
      </nav>
      <section className="card gallery-item">
        <div>
          <h3>inline tokens</h3>
          <p className="schema">code spans inside any text</p>
          <Html html={data.inline.html} />
        </div>
        <pre>{data.inline.source}</pre>
      </section>
      {data.components.map((c) => (
        <section className="card gallery-item" id={`tl-${c.name}`} key={c.name}>
          <div>
            <h3>tl:{c.name}</h3>
            <p className="schema">
              <b>{c.summary}</b> · {c.schema}
            </p>
            <Html html={c.html} />
          </div>
          <pre>{c.source}</pre>
        </section>
      ))}
    </>
  );
}
