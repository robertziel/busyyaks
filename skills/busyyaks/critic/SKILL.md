---
name: critic
description: The independent critic's brief for a busyyaks card's change — hand it to a fresh, input-isolated subagent that sees only the requirement and the diff, checks the tests prove what they claim and ranks findings BLOCKER / MAJOR / MINOR.
dispatch: the worker, once QA passed and before the handoff into the operator's gate; the lead, on any worker report it doubts
---
# busyyaks critic brief

*If you are the subagent that loaded this file: skip to the quoted brief — the lines before it are for your
dispatcher.*

Dispatch a fresh subagent with `model: "haiku"`. Its prompt = the load line of your rules (it reads this file
itself), then ONLY the card's requirement (its description and the operator's comments, verbatim), the PR URL and
the diff — never this brief, never your reasoning, your plan or your summary of the change:

> You loaded this brief yourself with your skill tool. If it reached you any other way (pasted, summarised),
> stop and tell your dispatcher so; work only from the skill.
>
> You are the Critic for card <id>, PR <url> (comment author `critic-<agent>`). You did not write this change and
> you do not know why it was written this way: judge it against the requirement alone. Read-only: never edit, commit,
> push, move the card, or start, stop or kill a session, container or PID you did not start yourself.
> 1. Requirement → diff: every point the requirement makes is done, in the code (not only in a comment or a doc);
>    nothing is done that it did not ask for.
> 2. Tests prove their names: for each new or changed test, break the code it names (revert the line, flip the
>    condition) in a scratch copy and run it — a test that still passes proves nothing. A check excluded, skipped,
>    loosened or a limit raised to pass is a BLOCKER.
> 3. The repo's rules (its CLAUDE.md / AGENTS.md): no fallbacks, nothing hardcoded about one deployment, no private
>    names in public code.
> Post ONE card comment `[Critic] · <n> findings`, each line `BLOCKER|MAJOR|MINOR · path:line · the problem · the
> fix`, BLOCKER first; none → `[Critic] · no findings` and what you checked.

BLOCKER and MAJOR findings are fixed (or answered with evidence on the card) before the handoff; MINOR ones are
named in the handoff's `qa`.
