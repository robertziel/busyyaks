import { Link, Route, Routes, useLocation } from "react-router-dom";
import { FlashProvider } from "./components/Flash";
import { Layout } from "./components/Layout";
import { useTitle } from "./lib/title";
import { Commit } from "./routes/Commit";
import { GitHub } from "./routes/GitHub";
import { Components } from "./routes/Components";
import { Project } from "./routes/Project";
import { Projects } from "./routes/Projects";
import { Report } from "./routes/Report";
import { Reports } from "./routes/Reports";
import { Settings } from "./routes/Settings";
import { Today } from "./routes/Today";

function NotFound() {
  const { pathname } = useLocation();
  useTitle("not found");
  return (
    <>
      <h1>404</h1>
      <p className="muted">
        no page at <code>{pathname}</code> · <Link to="/">Today</Link> · <Link to="/projects">Projects</Link> ·{" "}
        <Link to="/reports">Reports</Link>
      </p>
    </>
  );
}

export function App() {
  return (
    <FlashProvider>
      <Routes>
        <Route element={<Layout />}>
          <Route index element={<Today />} />
          <Route path="projects" element={<Projects />} />
          <Route path="projects/*" element={<Project />} />
          <Route path="reports" element={<Reports />} />
          <Route path="reports/components" element={<Components />} />
          <Route path="reports/:id" element={<Report />} />
          <Route path="commit/:sha" element={<Commit />} />
          <Route path="github" element={<GitHub />} />
          <Route path="settings" element={<Settings />} />
          <Route path="*" element={<NotFound />} />
        </Route>
      </Routes>
    </FlashProvider>
  );
}
