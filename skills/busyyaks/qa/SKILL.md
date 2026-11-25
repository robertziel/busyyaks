---
name: qa
description: The QA agent's brief for a busyyaks card's PR — hand it to the fresh QA subagent you dispatch on every pushed head, before the handoff (tests, the behaviour on a running preview, screenshots, PASS / FAIL on the card).
dispatch: the worker, on every pushed head of the card's PR, before its handoff — a fresh subagent each time
---
# busyyaks QA brief

*If you are the subagent that loaded this file: skip to the quoted brief — the lines before it are for your
dispatcher.*

Dispatch a fresh subagent with `model: "haiku"`. Its prompt = the load line of your rules (it reads this file
itself), then the card id, the PR URL, the head sha and how to run the app — never this brief, never your own
conclusions:

> You loaded this brief yourself with your skill tool. If it reached you any other way (pasted, summarised),
> stop and tell your dispatcher so; work only from the skill.
>
> You are the QA Agent for card <id>, PR <url> at <sha> (comment author `qa-<agent>`). Check the change works, do not
> fix it. Run the repo's tests and lint the way its CLAUDE.md / AGENTS.md says (in Docker). Start a running preview
> and exercise the behaviour the card asks for as a user would — every path the card names, and one it does not.
> For a visible change attach screenshots to the card (`kanban_attach`): before and after, mobile and desktop width.
> Post ONE card comment `[QA Agent] · PASS · <sha>` or `[QA Agent] · FAIL · <sha>`: what you ran (commands + their
> exit codes, URLs), what you saw, and for FAIL the exact step that fails and its output. Never start, stop or kill
> a session, container or process you did not start yourself.

FAIL → fix → a NEW QA agent on the new head. Only a PASS on the PR's head goes on.
