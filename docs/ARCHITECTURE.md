# ClaudeCX architecture

ClaudeCX connects two agents with a narrow, auditable interface. Codex plans and reviews. Claude Code implements. A PowerShell bridge sits between them and enforces the process-level controls.

## Components

| Component | Location | Role |
| --- | --- | --- |
| Skill instructions | `skill/claudecx/SKILL.md` | Tell Codex when and how to delegate: explicit invocation only, clean tree, how to write a brief, how to verify independently. |
| Skill metadata | `skill/claudecx/agents/openai.yaml` | Display name `ClaudeCX`, a default prompt that mentions `$claudecx`, and `allow_implicit_invocation: false`. |
| Bridge | `skill/claudecx/scripts/invoke-claude.ps1` | Checks the Git state, takes the per-repository lock, records handoff state, starts Claude Code with fixed flags, enforces the timeout, and fails closed. |
| Progress module | `skill/claudecx/scripts/ClaudeCX.Progress.psm1` | Parses Claude's stream-json events, keeps the raw event log, applies the fail-closed result checks, extracts the structured report, and writes sanitized progress lines. |
| Dashboard module | `skill/claudecx/scripts/ClaudeCX.Dashboard.psm1` | Dashboard metadata, stop marker, fixed read-only API (state, changes, report, prompts), bounded loopback HTTP handler, server launch, browser launch, and the Dashboard → Window → Console fallback. |
| Dashboard server | `skill/claudecx/scripts/show-dashboard.ps1`, `skill/claudecx/dashboard/` | Hidden PowerShell process serving the packaged page and API on `127.0.0.1`; exits after completion, when the bridge disappears, or at its lifetime limit. |
| Dashboard source | `dashboard-src/`, `package.json` | React UI built by Vite into the three fixed files in `skill/claudecx/dashboard/`. Contributor build tooling only: installation and runtime never run Node or npm. |
| Settings module | `skill/claudecx/scripts/ClaudeCX.Settings.psm1`, `scripts/claudecx-settings.ps1` | The user's settings (`%USERPROFILE%\.claudecx\settings.json`), strict validation, the committed `.claudecx.json`, effective limits, protected-path matching, log-folder discovery (including packaged-app redirects), run ids, and pruning. The script shows and changes settings for people and for Codex. |
| Control center | `skill/claudecx/scripts/ClaudeCX.ControlCenter.psm1`, `show-control-center.ps1`, `start-control-center.ps1` | Always-on loopback server for the same page in control-center mode: live run, history across every log folder, settings, health, and pruning. Started from the Start menu shortcut the installer creates. |
| Progress monitor | `skill/claudecx/scripts/watch-progress.ps1` | Read-only window that tails `progress.log` and exits on the completion marker or when the bridge process disappears. |
| Bridge settings | `skill/claudecx/assets/bridge-settings.json` | Settings passed with `--settings`: hooks and auto-memory off, attribution off, deny rules for commit, push, publish, deploy, cloud, network-shell, recursion, secret reads, and MCP. |
| Role prompt | `skill/claudecx/assets/claude-role-prompt.md` | Appended to Claude's system prompt on every call with `--append-system-prompt-file`. |
| Report schema | `skill/claudecx/assets/report-schema.json` | The JSON Schema passed to `--json-schema`. Claude must return this structured report. |
| Empty MCP config | `skill/claudecx/assets/empty-mcp.json` | Used with `--strict-mcp-config` so no MCP server is loaded. |
| Live smoke test | `skill/claudecx/scripts/test-claude-bridge.ps1` | End-to-end check against the real Claude CLI (opt-in, uses account usage). |
| Installer / uninstaller | `install.ps1`, `uninstall.ps1` | Copy the skill into `<CodexHome>\skills\claudecx` (unblocking the copy), or remove it, with backups. The installer then runs the setup check. |
| Setup check | `doctor.ps1` | Read-only checks of Windows, PowerShell, blocked downloads, Git, Claude Code (found, options, sign-in), Codex home, the installed skill, the run-log folder, and a default browser; each problem has a fix. `-Json` gives agents a machine-readable report. Agents follow `docs/AGENT-SETUP.md`. |
| Shared helpers | `scripts/ClaudeCX.Common.psm1` | Skill validation, Codex-home resolution, tree hashing, the strict-JSON attribution merge. |
| Offline tests | `scripts/test-static.ps1`, `scripts/test-install.ps1`, `scripts/test-progress.ps1`, `scripts/test-dashboard.ps1`, `scripts/test-doctor.ps1`, `scripts/test-control-center.ps1` | Static invariants, sandboxed install tests, and the progress, dashboard, setup-check, and settings/control-center suites (run by `test-static.ps1`). |

## Trust boundaries

```text
 User ──explicit $claudecx──▶ Codex (orchestrator, reviewer)
                                │ writes brief outside repo
                                ▼
                     invoke-claude.ps1 (bridge)
             Git checks · lock · state · fixed flags · timeout
                                │ stdin: brief
                                ▼
          Claude Code (--safe-mode, auto permission mode)
                                │ edits working tree only
                                ▼
                         Git repository

 bridge ──progress.log, progress.done──▶ watch-progress.ps1 (read-only window)
 bridge ──dashboard.json, artifacts──▶ show-dashboard.ps1 ◀──127.0.0.1 + token──▶ browser
 show-dashboard.ps1 ──stop-request.json──▶ bridge (polls, kills Claude's tree)
 settings.json, HEAD:.claudecx.json ──read once──▶ bridge (limits, model, protected paths)
 every log folder ──read──▶ show-control-center.ps1 ◀──127.0.0.1 + token──▶ browser
 show-control-center.ps1 ──settings.json, stop-request.json, pruning──▶ disk
```

1. **User → Codex.** Delegation happens only when the user asks for it. Implicit invocation is turned off.
2. **Codex → bridge.** Codex passes a repository path, a brief path, and limits. The bridge does not trust Codex to have checked the Git state and checks it again itself.
3. **Bridge → Claude.** The bridge controls the command line, the environment, and the working directory. The brief is data on stdin and never becomes part of a command string. Arguments go through `ProcessStartInfo.ArgumentList`.
4. **Claude → repository.** Claude has your user's file-system and process access, limited by Claude Code's permission system and the deny rules. This boundary is **not** a sandbox. See [SECURITY.md](../SECURITY.md).
5. **Claude → Codex.** The structured report is advisory. Codex checks the diff, `HEAD`, and the tests itself.
6. **Bridge ↔ dashboard.** The bridge writes `dashboard.json` (non-secret metadata) and starts `show-dashboard.ps1` with shell execution and a hidden window, passing the per-run token only through the environment. The server reads only fixed artifacts in the turn folder (`progress.log`, `progress.done`, `claude-result.json`, `report.json`, `failure.json`, `original-prompt.md`, `codex-brief.md`) and runs two fixed, read-only Git queries. Its only write is the atomic `stop-request.json` marker; the bridge polls for it every 250 ms while streaming and does the termination itself (`Kill($true)` on the Claude process it started), then writes `failure.json` and `progress.done` with status `stopped` and exits nonzero without updating `last-state.sha256`.
7. **Settings → bridge.** The bridge reads the user's settings and the committed `.claudecx.json` once, before it creates any state, and refuses to run if either is invalid. They can lower limits, pick a model, and add protected paths; nothing in them reaches a safety flag. After a successful report, the bridge compares the changed paths with the protected patterns and fails the run on a match.
8. **Control center ↔ bridge.** Only through files. The bridge writes `dashboard.json` for every run in every progress mode, plus `changes.json` when the run ends; if a control center is running it skips its own dashboard server. The control center discovers runs by `active.lock` and the turn folders, and can write the stop marker and settings.
9. **Bridge → progress window.** One-way, through files. The monitor only reads `progress.log` and `progress.done`. It is started with shell execution, so it inherits none of the bridge's handles and never sees Claude's stdin or stdout. Closing it has no effect on the run.

## State layout

State is kept under `%LOCALAPPDATA%\CodexClaude\handoffs`, never inside a repository:

```text
<repo-key>/                 first 24 hex chars of SHA-256(lowercase repo root)
  active.lock               {token, pid, repository, created_at}
  <session-uuid>/
    session.json            {session_id, repository, initial_head, created_at}
    last-state.sha256       fingerprint after the last successful turn
    <turn-timestamp>/       codex-brief.md, original-prompt.md (optional), status-before/after, report.json or failure.json,
                            claude-events.jsonl (raw stream), claude-result.json (final result event),
                            claude-stderr.txt, progress.log (sanitized), progress.done (completion marker), dashboard.json (run facts and
                            the limits used), changes.json (status and diff at the end), dashboard-endpoint.json, stop-request.json (only after Stop run)
```

The user's own files live in the ClaudeCX home, `%USERPROFILE%\.claudecx` (or `CLAUDECX_HOME`), which Windows does not redirect for packaged apps: `settings.json`, and while the control center runs, `control-center.json` and `control-center.token`.

When the bridge is started from the packaged Codex desktop app, Windows redirects `%LOCALAPPDATA%` writes to `%LOCALAPPDATA%\Packages\OpenAI.Codex_<id>\LocalCache\Local`. Processes inside the package see the normal path. Processes outside it, such as a user's own shell, find the state only under the package folder. The control center reads both locations.

The working-tree fingerprint is a SHA-256 over `git status --porcelain=v1 --untracked-files=all`, `git diff --binary HEAD`, `git diff --cached --binary HEAD`, and the content hash of every untracked file.

## New run flow

1. Refuse if `AGENT_HANDOFF_DEPTH` is set and non-zero, which means a nested call from Claude.
2. Resolve the repository root and `HEAD`. Read the brief and, when given, `-OriginalPromptPath`: each must be a file outside the repository, at most 1 MiB, and strict UTF-8 (a leading BOM is dropped), or the run fails before any state is created.
3. Read the user's settings and the committed `.claudecx.json`; refuse on any invalid value. Resolve the limits (the user's values as the ceiling, lowered by the project file and by any `-MaxTurns`, `-MaxBudgetUsd`, or `-TimeoutSeconds` Codex passed), the model, the progress mode when none was passed, and the protected paths. Prune finished turns older than `keep_logs_days` when that is set.
4. Take `active.lock`. A lock held by a live PID blocks the run. A lock whose PID has exited is cleared.
5. Require an empty `git status --porcelain=v1 --untracked-files=all`.
6. Create a new session UUID. Record `session.json` (including `initial_head`) and the initial fingerprint.
7. Atomically write `codex-brief.md` (and `original-prompt.md` when supplied) into a new turn folder, then read `codex-brief.md` back as Claude's exact input so the displayed and executed handoff cannot diverge. Resumed turns capture their own copies. Copy the status into the turn folder. Open `progress.log`, write `dashboard.json`, and start the progress display: with `-ProgressMode Dashboard` (the default), leave the run to a running control center, or else start the loopback dashboard server and open the browser; on failure, warn on stderr and try the read-only monitor window (`Window`). If the window cannot start, warn on stderr and fall back to `Console`.
8. Start `claude -p ... --safe-mode --permission-mode auto --output-format stream-json --verbose --json-schema <schema> --max-turns N --max-budget-usd X --settings <bridge-settings> --append-system-prompt-file <role> --strict-mcp-config --mcp-config <empty> [--model <name>] --session-id <uuid>`, with `AGENT_HANDOFF_DEPTH=1`, `CLAUDE_CODE_DISABLE_AUTO_MEMORY=1`, and `CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1`. The brief goes in as UTF-8 on stdin. Partial-message streaming is not enabled, so only completed messages and tool calls arrive.
9. Read stdout line by line as it arrives. Each non-empty line is appended to `claude-events.jsonl`, parsed as one JSON event, and summarized into at most a few sanitized progress lines. Unknown event types are kept in the raw log and not displayed. A malformed line kills Claude's process tree and fails the run.
10. The whole read loop and the final exit wait share one `TimeoutSeconds` budget. On timeout, kill the whole process tree.
11. Take the last `result` event (saved as `claude-result.json`) and fail closed on a missing result event, a non-zero exit, `is_error`, a non-`success` subtype, a missing structured report (`structured_output`, or a JSON `result` fallback), or a moved `HEAD`.
12. On success, write `report.json`, update `last-state.sha256`, then check protected paths: a change to one fails the run (the fingerprint is already updated, so Codex can resume to undo it). Otherwise save `changes.json` and print a one-line JSON summary on stdout. Progress never goes to stdout.
13. Save `changes.json` on failure too, and write `progress.done` on every exit path (success, failure, timeout, exception) so the monitor stops tailing. The monitor also stops on its own if the bridge process disappears.
14. Release the lock, but only if this run's token still owns it.

## Progress modes

`-ProgressMode` controls only where progress is displayed. It never changes Claude's flags, permissions, or limits.

| Mode | Display | Logs |
| --- | --- | --- |
| `Dashboard` (default) | Local browser dashboard on `127.0.0.1` with Prompt journey, Work, Changes, and Report views and a confirmed Stop run control. Falls back to `Window`, then `Console`. | `progress.log`, `dashboard.json`, the server's fixed API |
| `Window` | Separate read-only PowerShell window `ClaudeCX - <repo>`. Closes about 5 seconds after success; stays open 5 minutes after a failure, or until a key is pressed. | `progress.log`, `claude-events.jsonl` |
| `Console` | `[claudecx]` lines on stderr. | same |
| `None` | Nothing. | same |

Progress lines contain the tool or phase name and at most one short, sanitized summary: a repository-relative path (tail kept when truncated) taken only from a path-shaped field (`file_path`, `notebook_path`, `path`), or a generic activity label. Free-form inputs are never shown: a tool with a `pattern` or `query` appears as `searching` (plus a safe `path` if present), a tool with a `url` appears as `requesting URL` with no host, and prompts, descriptions, and unknown fields are omitted. Shell commands are never shown: they appear as `running command`, or `running <program>` only when the single-line command starts with a bare, allowlisted program name (for example `npm`, `git`, `pwsh`). Arguments, quoted strings, redirections, inline scripts, environment assignments, and embedded paths or URLs stay in `claude-events.jsonl`, together with every other raw tool input. Control and escape characters are stripped and secret-looking values are masked. File contents, edits, tool output, thinking, prompts, and raw JSON are never displayed. Consecutive duplicate lines are suppressed.

## Resume flow

Same as a new run, except:

- the session UUID must parse as a GUID and must have `session.json` and `last-state.sha256` in this repository's state folder;
- the recorded repository must match the current one (case-insensitive);
- `HEAD` must equal `initial_head`;
- the current fingerprint must equal `last-state.sha256`, so nothing changed since Claude's last successful turn;
- Claude is started with `--resume <uuid>` instead of `--session-id <uuid>`. The role prompt, settings, MCP isolation, schema, and limits are all sent again.

A failed turn does not update the fingerprint, except a protected-path failure, which is detected after the report is saved. If Claude changed files before failing, the session cannot be resumed and a new clean run is needed.

## Why safe mode instead of bare mode

Claude Code's `--bare` mode skips loading most local configuration, but it also skips OAuth and keychain credential discovery. Subscription-authenticated users (Claude Pro or Max sign-in) would then have no credentials. `--safe-mode` keeps authentication, the built-in tools, and the permission system, and turns off repository and user customizations: `CLAUDE.md` loading, skills, plugins, hooks, MCP servers, agents, output styles, workflows, and auto-memory. Because safe mode ignores repository instructions, Codex must copy every operative convention into the brief.

The bridge settings file then adds `disableAllHooks`, attribution suppression, and deny rules on top. `--strict-mcp-config` with an empty config means no MCP server can be loaded from any source.

## Platform scope

v1 targets Windows with PowerShell 7.2+. It relies on `%LOCALAPPDATA%`, Windows path conventions, and `claude.exe` discovery. Other platforms are not supported.
