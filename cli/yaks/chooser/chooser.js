// The desktop app's server chooser (cli/yaks/chooser.rb): Local first and selected (the default), then the
// saved servers. The state comes from /events (pushed every 2 s; the open stream is also what keeps the chooser
// running). Open / Disconnect / Remove / Add are POSTs; a refusal is shown as the chooser's own words.
"use strict";

const list = document.getElementById("servers");
const error = document.getElementById("error");
const form = document.getElementById("add");
const input = document.getElementById("target");
let selected = "local";
let confirming = null;
let rows = [];
let last = null;
let first = true;

const STATE = {
  local: {
    up: ["ok", (l) => ["running · ", code(l.url)]],
    down: ["bad", (l) => ["not answering at ", code(l.url), " (is the stack up? yaks server status)"]],
    none: ["bad", (l) => [l.detail || "no local busyyaks"]],
    checking: ["wait", () => ["checking…"]],
  },
  server: {
    idle: ["", () => ["not connected"]],
    connecting: ["wait", (s) => ["connecting… ", s.detail || ""]],
    connected: ["ok", (s) => ["connected · ", s.host, " · ", code(s.url.replace(/\/\?.*$/, ""))]],
    failed: ["bad", (s) => [s.detail || "failed"]],
  },
};

function code(text) {
  const c = document.createElement("code");
  c.textContent = text;
  return c;
}

function el(tag, cls, ...kids) {
  const e = document.createElement(tag);
  if (cls) e.className = cls;
  e.append(...kids);
  return e;
}

function button(label, cls, onClick, disabled = false) {
  const b = el("button", `ch-btn ${cls}`, label);
  b.type = "button";
  b.disabled = disabled;
  b.addEventListener("click", (ev) => {
    ev.stopPropagation();
    onClick();
  });
  return b;
}

function showError(text) {
  error.textContent = text || "";
  error.hidden = !text;
}

async function post(path, server) {
  showError("");
  try {
    const res = await fetch(path, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ server }),
    });
    const body = await res.json();
    if (!res.ok) {
      showError(body.error || `refused (${res.status})`);
      return false;
    }
    render(body);
    return true;
  } catch (e) {
    showError(`the chooser did not answer: ${e.message}`);
    return false;
  }
}

function row(key, name, tag, [tone, words], acts) {
  const li = el(
    "li",
    "ch-row",
    el("span", `ch-dot ${tone}`),
    el(
      "div",
      "",
      el("div", "ch-name", name, ...(tag ? [el("span", "ch-tag", tag)] : [])),
      el("div", `ch-state ${tone === "bad" ? "bad" : ""}`, ...words),
    ),
    el("div", "ch-acts", ...acts),
  );
  li.setAttribute("role", "option");
  li.tabIndex = key === selected ? 0 : -1;
  li.setAttribute("aria-selected", String(key === selected));
  li.dataset.key = key;
  li.addEventListener("click", () => select(key, true));
  li.addEventListener("dblclick", () => void post("/api/open", key));
  return li;
}

// redrawn only when the state changed (or a Remove asks to confirm): a redraw every push would take the focus away
function render(state, force = false) {
  const json = JSON.stringify(state);
  if (!force && json === last) return;
  last = json;
  list.setAttribute("aria-busy", "false");
  const local = state.local;
  const [ltone, lwords] = STATE.local[local.state] || ["bad", () => [local.state]];
  const items = [
    row(
      "local",
      "Local",
      "default",
      [ltone, lwords(local)],
      [button("Open", "primary", () => void post("/api/open", "local"), !local.url)],
    ),
  ];
  for (const s of state.servers) {
    const [tone, words] = STATE.server[s.state] || ["bad", () => [s.state]];
    const acts = [
      button(
        s.state === "connected" ? "Open" : "Connect",
        "primary",
        () => void post("/api/open", s.target),
        s.state === "connecting",
      ),
    ];
    if (s.state === "connected" || s.state === "connecting")
      acts.push(button("Disconnect", "", () => void post("/api/disconnect", s.target)));
    acts.push(
      confirming === s.target
        ? button("Remove?", "danger", () => {
            confirming = null;
            if (selected === s.target) selected = "local";
            void post("/api/remove", s.target);
          })
        : button("Remove", "danger", () => {
            confirming = s.target;
            render(state, true);
            setTimeout(() => {
              if (confirming === s.target) {
                confirming = null;
                render(state, true);
              }
            }, 4000);
          }),
    );
    items.push(row(s.target, s.target, null, [tone, words(s)], acts));
  }
  rows = items.map((li) => li.dataset.key);
  if (!rows.includes(selected)) selected = "local";
  const focused = first || document.activeElement?.closest?.(".ch-row") != null;
  first = false;
  list.replaceChildren(...items);
  if (focused) list.querySelector(`[aria-selected="true"]`)?.focus();
  if (state.error) showError(state.error);
}

function select(key, focus) {
  selected = key;
  for (const li of list.children) {
    const on = li.dataset.key === key;
    li.setAttribute("aria-selected", String(on));
    li.tabIndex = on ? 0 : -1;
    if (on && focus) li.focus();
  }
}

list.addEventListener("keydown", (ev) => {
  const i = rows.indexOf(selected);
  if (ev.key === "ArrowDown" || ev.key === "ArrowUp") {
    ev.preventDefault();
    const next = rows[Math.max(0, Math.min(rows.length - 1, i + (ev.key === "ArrowDown" ? 1 : -1)))];
    select(next, true);
  } else if (ev.key === "Enter" && ev.target.classList.contains("ch-row")) {
    ev.preventDefault();
    void post("/api/open", selected);
  }
});

form.addEventListener("submit", async (ev) => {
  ev.preventDefault();
  const target = input.value.trim();
  if (await post("/api/add", target)) {
    input.value = "";
    selected = target;
  }
});

const events = new EventSource("/events");
events.onmessage = (ev) => {
  document.body.classList.remove("ch-gone");
  render(JSON.parse(ev.data));
};
events.onerror = () => {
  if (events.readyState === EventSource.CLOSED || !navigator.onLine) return;
  document.body.classList.add("ch-gone");
  showError("the chooser stopped (yaks desktop open ended): close this window and open busyyaks again");
};
