import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { BrowserRouter } from "react-router-dom";
import { App } from "./App";
import "./styles/projects.css";
import "./styles/reports.css";
import "./styles/components.css";
import "./styles/tiles.css";
import "./styles/agents.css";
import "./vendor/agents_kanban/styles/kanban.css";
import "./styles/spa.css";
import "./styles/search.css";
import "./styles/github.css";
import "./styles/waiting.css";
import "./styles/hello.css";

const root = document.getElementById("root");
if (!root) throw new Error("#root missing from the shell (app/templates/app.html.erb)");
createRoot(root).render(
  <StrictMode>
    <BrowserRouter>
      <App />
    </BrowserRouter>
  </StrictMode>,
);
