// /settings/git-hosts — Git hosts: the git host busyyaks reads (GitHub now, GitLab coming soon). Optional:
// with none connected every page that needs one says so and links here. The cards are components/GitHosts.tsx, the
// same the /hello wizard's Git host step shows.
import { GitHosts } from "../components/GitHosts";
import { useTitle } from "../lib/title";

export function GitHostsSettings() {
  useTitle("git hosts");
  return (
    <div className="gith">
      <h1>Git hosts</h1>
      <p className="muted gith-meta">optional · stars, follows, the feed, merged PRs and PR / CI reads</p>
      <GitHosts />
    </div>
  );
}
