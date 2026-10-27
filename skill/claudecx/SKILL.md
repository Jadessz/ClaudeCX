---
name: claudecx
description: Explicitly delegate implementation work to Claude Code through the guarded ClaudeCX bridge. Use only when the user invokes $claudecx or directly asks Codex to hand coding work to Claude; Codex remains the planner and reviewer.
---

# ClaudeCX

Use Claude Code as the implementation worker while Codex owns scoping, the handoff brief, verification, and the final explanation.

## Preconditions

1. Work in a Git repository. For a new session, require a clean tracked and untracked working tree. Do not use the bridge when unrelated changes exist; ask the user to commit, stash, or move them first.
2. Read the applicable repository instructions yourself (`AGENTS.md`, and any `CLAUDE.md` or `CLAUDE.local.md`). Because the bridge runs Claude with `--safe-mode`, include every operative convention Claude needs in the brief.
3. Never invoke this skill implicitly. The user must explicitly request Claude delegation or name `$claudecx`.
4. Keep one writer. Do not edit repository files while a Claude bridge run is active.

## Prepare the brief

Write a UTF-8 Markdown brief outside the repository. Include:

- objective and non-goals;
- relevant architecture and repository conventions;
- precise files or areas in scope;
- acceptance criteria and required tests;
- known risks and edge cases;
- a ban on commits, pushes, deployments, releases, external writes, or further delegation;
- instructions to stop and report blockers instead of broadening scope.

Do not paste secrets or sensitive `.env` content. Prefer paths and symbols over large code dumps.

## Run Claude

Invoke `scripts/invoke-claude.ps1` with the repository root and brief path. Use the default `auto` permission mode. The wrapper must fail if auto mode is unavailable; never retry with a more permissive mode and never use `--dangerously-skip-permissions`.

```powershell
pwsh -NoProfile -File "<skill-root>\scripts\invoke-claude.ps1" `
  -ProjectPath "<repo-root>" `
  -BriefPath "<brief.md>" `
  -MaxTurns 60 `
  -MaxBudgetUsd 5
```

By default (`-ProgressMode Dashboard`) the wrapper opens a local dashboard in the default browser at `http://127.0.0.1:<port>/` (loopback only, per-run token in the URL fragment). It shows the sanitized activity, the current `git status --short` and diff against HEAD, and the final report or failure reason. Its only control besides Refresh and Copy is a confirmed **Stop run**, which asks the bridge (through `stop-request.json` in the turn folder) to terminate Claude; the run then fails with `status: stopped`, partial edits stay in the working tree, and you must review them like any other failure. Tell the user the dashboard is there, that closing it does not stop Claude, and that Stop run does not revert edits. If the dashboard cannot start, the wrapper warns on stderr and falls back to `-ProgressMode Window`, then `Console`, with the same Claude flags.

With `-ProgressMode Window` the wrapper opens a separate read-only PowerShell window titled `ClaudeCX - <repo>` that shows one sanitized line per phase or tool action (tool and phase names, generic activity labels, and safe repository-relative paths; shell commands appear only as `running command` or `running <program>`, searches as `searching`, and URL tools as `requesting URL`; patterns, queries, hosts, prompts, and arguments are never shown). Tell the user it is there: it is only an observer, typing in it does nothing, and closing it does not stop Claude. It closes shortly after success and stays open after a failure. Use `-ProgressMode Console` to send progress to stderr instead (stdout still carries only the final JSON line), or `-ProgressMode None` for no live display, for example in CI or headless terminals. If the window cannot open, the wrapper warns on stderr and continues in `Console` mode with the same Claude flags. Displayed paths are shortened and masked, but a file name can still be sensitive. The raw commands are kept only in `claude-events.jsonl`.

Each turn folder keeps `claude-events.jsonl` (raw stream-json events), `claude-result.json` (final result event), `claude-stderr.txt`, and `progress.log` (the sanitized progress the dashboard and window show). A stopped run writes `failure.json` with `status: stopped`. The success JSON includes `events_path` and `progress_log_path`.

The wrapper uses `--safe-mode`, a bridge-only settings file, an explicit role system prompt, strict empty MCP configuration, disabled auto-memory and background tasks, a preassigned UUID, stream-json transport with a structured final report, a timeout, a budget ceiling, and handoff state under `%LOCALAPPDATA%\CodexClaude\handoffs`. Safe mode preserves OAuth/keychain authentication; bare mode does not and is therefore unsuitable for subscription-authenticated Claude Code.

## Resume

Resume only to address review feedback or finish the same scoped implementation. Pass the reported session UUID and a new brief. The wrapper re-sends the role system prompt and all safety flags.

```powershell
pwsh -NoProfile -File "<skill-root>\scripts\invoke-claude.ps1" `
  -ProjectPath "<repo-root>" `
  -BriefPath "<follow-up.md>" `
  -ResumeSessionId "<uuid>"
```

The resume fails if the repository path differs, `HEAD` changed, or the working tree no longer matches the state recorded after Claude's previous successful turn. Start a new clean session rather than bypassing these checks.

## Verify independently

Treat Claude's report as a hint, not proof. After every successful run:

1. Inspect `git status` and the full diff.
2. Confirm `HEAD` did not move and no unexpected files appeared.
3. Run the relevant formatter, linter, type checks, tests, or build yourself.
4. Review security, error handling, compatibility, and scope.
5. If fixes are needed, write a focused follow-up brief and resume the same session.

Tell the user what Claude changed, what Codex independently verified, and any remaining risk. Do not credit Claude as a contributor or add co-author metadata.

## Safety model

The bridge is defense in depth, not a host security sandbox. `--safe-mode` disables repository instructions, skills, plugins, hooks, MCP servers, agents, output styles, workflows, and auto-memory while preserving authentication, built-in tools, and permissions. The settings file disables hooks again and denies common commit, push, deployment, publishing, cloud, network-shell, recursion, secret-read, and MCP operations. Git checks enforce a clean initial tree, a stable resume state, and an unchanged `HEAD`. For repositories you do not trust, inspect their code and build scripts before allowing Claude to run tests because repository scripts can still execute arbitrary code.
