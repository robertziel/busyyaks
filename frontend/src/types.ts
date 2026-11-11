// Mirrors lib/busyyaks/api.rb (the JSON the Hanami API sends).

export type TmuxSession = {
  name: string;
  created: number;
  attached: boolean;
  terminal_url: string;
  claude_url: string | null;
  ssh_attach: string;
};

export type Project = {
  slug: string;
  path: string;
  remote: string | null;
  repo_url: string | null;
  branch: string | null;
  own: boolean;
  last_commit_at: number | null;
  commits_window: number;
  mine_window: number;
  dirty: number;
  unpushed: number | null; // null = no upstream → unknown, shown "—"
  scanned_at: number;
  present: boolean;
  icon: string | null;
  sessions: TmuxSession[];
};

export type FolderNode = {
  type: "folder";
  name: string;
  path: string;
  repos: number;
  last_commit_at: number | null;
  commits_window: number;
  mine_window: number;
  dirty: number;
  unpushed: number | null;
  live: number;
  children: TreeNode[];
};
export type RepoNode = { type: "repo"; name: string; project: Project };
export type TreeNode = FolderNode | RepoNode;

export type Commit = {
  sha: string;
  subject: string;
  author: string;
  email: string;
  committed_at: number;
  mine: boolean;
  project_slug: string;
  url: string | null;
};

export type Tone = "neutral" | "accent" | "ok" | "warn" | "bad" | "info";
// the server's ReportBlocks.digest: what a report says at a glance
export type ReportFigure = {
  label: string;
  value: string;
  tone: Tone;
  delta: string | null;
  good: "up" | "down" | null;
};
export type ReportDigest = {
  figures: ReportFigure[];
  headline: { tone: string; text: string } | null;
  actions: { high: number; med: number; low: number };
  repos: number;
  flags: number;
  needs: number;
  broken: number;
};
export type ReportRow = {
  id: number;
  date: string;
  title: string;
  author: string;
  created_at: number;
  chars: number;
  excerpt: string;
  digest: ReportDigest;
};
export type TocEntry = { level: number; id: string; text: string };
export type Report = ReportRow & { html: string; toc: TocEntry[] };

export type Note = { id: number; author: string; created_at: number; body: string; html: string };
// the engine's Api#launches (agent types + who runs against the cap) — the Launch bar's data, one per page load
export type LaunchState = {
  launches: import("./vendor/agents_kanban/types").LaunchesData;
  launcher_error: string | null;
};
export type Scan = { started_at: number; finished_at: number | null; repos: number | null; error: string | null };
export type WeekActivity = { project_slug: string; commits: number; mine: number };
export type DailyCounts = Record<string, number>;
export type DayStats = { day: string; commits: number; mine: number; repos: number; prs: number | null };
export type MergedPr = {
  repo: string;
  number: number;
  title: string;
  url: string;
  merged_at: number;
  project_slug: string | null;
};
export type PrStatus = {
  ok: boolean;
  error: string | null;
  at: number;
  last_ok_at: number | null;
  since: string | null;
};

export type TodayData = LaunchState & {
  today: string;
  stats: {
    repos: number;
    active7: number;
    commits_today: number;
    dirty: number;
    unpushed: number;
    prs_today: number | null;
  };
  days: DayStats[];
  merged_prs: MergedPr[];
  merged_prs_total: number;
  pr_status: PrStatus | null;
  scan: Scan | null;
  year: DailyCounts;
  year_total: number;
  year_all: number;
  reports: Report[];
  latest: Report | null;
  today_commits: Commit[];
  week_activity: WeekActivity[];
  active_tree: TreeNode[];
  projects_total: number;
};

export type Root = { path: string; prefix: string };
export type Job = { url: string; path: string; status: string; exit: number | null; tail: string | null };
export type ProjectsData = LaunchState & { tree: TreeNode[]; total: number; roots: Root[]; jobs: Job[] };
export type ProjectData = LaunchState & { project: Project; year: DailyCounts; commits: Commit[]; notes: Note[] };
export type ReportsData = { reports: ReportRow[] };
export type ReportData = { report: Report; older: ReportRow | null; newer: ReportRow | null };
export type ComponentsData = {
  inline: { html: string; source: string };
  components: { name: string; summary: string; schema: string; source: string; html: string }[];
};
export type CommitData = { commit: Commit; project: Project | null };

// herdr's states, worst first: blocked = the job is stopped until a person acts (dialog / permission prompt
// on its screen, the collector's waiting_for, a card of its in the ask column) · review = a card of its waits in the
// handoff column (PR to review) · working · finished = idle and every card it owns (≥ 1) is in its board's done column
// · idle · unknown. `unread` (a flag, not a state) = its turn ended after the operator last opened it
export type AgentState = "blocked" | "review" | "working" | "finished" | "idle" | "unknown";
export type AgentReview = { id: number; slug: string; title: string; pr_url: string | null; path: string };
export type AgentDialog = {
  question: string;
  command: string | null;
  options: { key: string; label: string; free: boolean }[];
  escape: boolean;
  free_text: boolean;
  hash: string;
  answerable: boolean;
};
// a card the session owns that is not in its board's done column
export type AgentCard = {
  id: number;
  slug: string;
  title: string;
  column_label: string;
  column_type: string | null;
  // in an approval gate but not approvable now: why — it waits for CI, not for the operator
  gate_hold: string | null;
  // flagged blocked_external only: its reason — it waits for the world, not for the operator
  blocked_external: string | null;
  path: string;
};
export type AgentAsk = { id: number; slug: string; title: string; question: string; path: string };
export type AgentSession = {
  key: string;
  name: string;
  socket: string;
  terminal_url: string;
  claude_url: string | null;
  ssh_attach: string;
  attached: boolean;
  activity: number;
  state: AgentState;
  state_by: string | null;
  unread: boolean;
  cards_known: boolean;
  cards: AgentCard[];
  cards_finished: number;
  turn_ended_at: number | null;
  seen_at: number | null;
  subagents: number;
  engines: string[];
  title: string | null;
  cwd: string | null;
  model: string | null;
  waiting_for: string[];
  dialogs: AgentDialog[];
  screen_errors: string[];
  asks: AgentAsk[];
  reviews: AgentReview[];
};
export type AgentGroup = {
  label: string;
  slug: string | null;
  icon: string | null;
  state: AgentState;
  sessions: AgentSession[];
};
export type AgentsData = {
  generated_at: number;
  age_s: number;
  interval_s: number;
  collector_error: string | null;
  stale: boolean;
  totals: {
    sessions: number;
    busy: number;
    subagents: number;
    blocked: number;
    review: number;
    finished: number;
    unread: number;
    you: number;
  };
  groups: AgentGroup[];
};
export type TeamData = {
  agents: { label: string; type: string | null; state: string; mtime: number | null; model: string | null }[];
  workflows: { label: string; state: string; agents: number | null; summary: string | null; started: number | null }[];
  tasks: { label: string; state: string; mtime: number | null }[];
};

// bin/launcher's answer to the engine's start (inside the engine's LaunchResult.result): the Remote Control verdict
export type LauncherStart = {
  remote_control?: "on" | "failed" | null;
  remote_control_name?: string | null;
  reason?: string | null;
  // left = not trusted from outside the repo (launch.trusted_paths / created by the launcher): the prompt stays on screen
  trust?: "accepted" | "failed" | "left";
  trust_reason?: string;
};
export type CreateResult = { cloning: boolean; path: string; slug?: string | null };

// ── kanban: the vendored engine's shapes (frontend/src/vendor/agents_kanban/types.ts) ──────────────────
export type {
  Attachment,
  HostConfig,
  BoardData,
  BoardShapeData,
  Card,
  CardData,
  CardFull,
  ColumnKey,
  LaunchesData,
  LaunchResult,
} from "./vendor/agents_kanban/types";
// GET /api/boards: the template board's columns at the top; each board carries its OWN columns (a project's board may differ)
export type BoardsColumn = { key: string; label: string; type: string };
export type BoardsData = {
  columns: BoardsColumn[];
  columns_order: string[];
  waiting_columns: string[];
  waiting: number;
  theme: Record<string, string>;
  boards: {
    project: string;
    columns: BoardsColumn[];
    columns_order: string[];
    waiting_columns: string[];
    counts: Record<string, number>;
    total: number;
    waiting: number; // the waiting columns' cards + the needs_operator cards elsewhere (never a blocked_external-only one)
    flagged: number;
    backlog_md: boolean;
  }[];
};

// ── search (GET /api/search) ──────────────────────────────────────────────────────────────────────
export type SearchKind = "page" | "project" | "card" | "commit" | "report" | "note" | "agent";
export type SearchItem = {
  kind: SearchKind;
  title: string;
  subtitle?: string;
  snippet?: string;
  href: string;
  icon?: string | null;
  at?: number | null;
  meta?: Record<string, string | number | boolean | null>;
};
export type SearchGroup = { key: string; label: string; items: SearchItem[]; total?: number; error?: string };
export type SearchData = { q: string; groups: SearchGroup[] };

// ── reap (GET/POST /api/agents/reap) ──────────────────────────────────────────────────────────────
export type ReapCandidate = {
  name: string;
  socket: string;
  reason: string;
  activity: number;
  project: string | null;
  engines: string[];
  title: string | null;
  cards?: { id: number; title: string; project: string }[];
};
export type ReapPreview = { quiet_min: number; candidates: ReapCandidate[] };
export type ReapResult = { name: string; stopped: boolean; reason: string };

// ── GitHub network (GET /api/github?hours=) ───────────────────────────────────────────────────────
export type GithubStatus = {
  ok: boolean;
  error: string | null;
  last_run_at: number | null;
  last_ok_at: number | null;
  running_since: number | null;
  calls: number | null;
  not_modified: number | null;
  rate_remaining: number | null;
  rate_limit: number | null;
  rate_reset: number | null;
  follows_since: number | null;
  follows_partial: boolean;
};
export type GithubPerson = {
  login: string;
  name: string | null;
  bio: string | null;
  avatar: string | null;
  followers: number | null;
  public_repos: number | null;
};
export type GithubRepo = {
  repo: string;
  url: string;
  description: string | null;
  language: string | null;
  stars: number | null;
  topics: string[];
  starred_by: string[];
  last_starred_at: number;
};
export type GithubNewPerson = GithubPerson & { followed_by: string[]; first_seen_at: number; you_follow: boolean };
export type GithubData = {
  window: { hours: number; from: number; to: number };
  login: string;
  status: GithubStatus;
  followees: GithubPerson[];
  repos: GithubRepo[];
  people: GithubNewPerson[];
  feed: GithubFeed;
  html: { repos: string; people: string; feed: string };
};
// the dashboard feed part (github.com/feed = received_events)
export type GithubFeedStatus = {
  ok: boolean;
  error: string | null;
  last_run_at: number | null;
  last_ok_at: number | null;
  calls: number | null;
  not_modified: number | null;
  added: number | null;
  since: number | null;
  partial: boolean;
  gap_at: number | null;
};
export type GithubFeedRepo = {
  repo: string;
  total: number;
  last_at: number;
  types: { type: string; n: number; actors: string[] }[];
};
export type GithubFeed = {
  status: GithubFeedStatus;
  total: number;
  counts: Record<string, number>;
  items: { id: string; kind: string; actor: string; repo: string; at: number }[];
  pushes: { repo: string; pushes: number; branches: number; actors: string[]; last_at: number }[];
  by_repo: GithubFeedRepo[];
  activity: Record<string, number>;
  stars_covered: number;
};
