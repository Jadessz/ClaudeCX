# Security

ClaudeCX lowers the risk of handing coding work to an autonomous agent. It does **not** remove that risk. Read this before using it on code you did not write.

## Threat model

ClaudeCX is meant to limit:

- **Scope creep and runaway work.** It sets a turn limit, a USD budget limit, a wall-clock timeout, and a scoped brief.
- **Accidental history or remote changes.** The deny rules block commit, push, tag, PR creation and merge, release, publish, and deploy commands. After each run the bridge checks that `HEAD` has not moved.
- **Configuration injection from the repository.** Safe mode ignores repository `CLAUDE.md`, skills, plugins, hooks, agents, and MCP servers. `disableAllHooks` and an empty strict MCP config add a second layer.
- **Recursive delegation.** `AGENT_HANDOFF_DEPTH` stops a nested bridge call, and deny rules cover `codex` and `claude` commands.
- **Concurrent writers and stale reviews.** The per-repository lock, the clean-tree requirement, and the resume fingerprint plus `HEAD` checks cover these.
- **Silent failure.** Any non-zero exit, `is_error`, non-`success` subtype, missing result event or report, malformed stream-json line, or timeout counts as a failure.

ClaudeCX does not protect against:

- a malicious or compromised Claude Code binary, Codex, or PowerShell;
- arbitrary code run by repository scripts (build, test, lint, package-manager lifecycle hooks);
- a model that deliberately gets around command-text rules;
- data leaving the machine through allowed tools (for example, Claude's own web tools if your account permits them, or a test suite that makes network calls);
- other processes running as your user.

## What is enforced, and how

| Control | Enforced by | Strength |
| --- | --- | --- |
| Clean tree for new runs, stable state for resumes, unchanged `HEAD` | Bridge (Git checks) | Strong. Checked outside Claude. |
| Turn, budget, and timeout limits | Claude Code flags, plus a bridge timeout that kills the process tree | Strong |
| Strict stream protocol | Bridge parses every stdout line as one JSON event and fails closed on a malformed line | Strong |
| Hooks, plugins, skills, MCP, and auto-memory off | `--safe-mode`, `disableAllHooks`, `--strict-mcp-config`, environment variables | Strong, as long as Claude Code honors its flags |
| No commit, push, publish, deploy, cloud, or network-shell commands | Permission deny rules in `bridge-settings.json` | **Partial.** See below. |
| No `.env` or `secrets/` reads | Permission deny rules on `Read` | **Partial.** They cover Claude's Read tool, not every shell command that can read a file. |
| Stay in scope, report honestly | Role prompt and brief | Advisory only |

### Limits of text-based command rules

Deny rules such as `Bash(git *commit*)` match the command text Claude sends. A command can reach the same effect in a different form: an alias, a script file, a language runtime calling Git, or a test that pushes. Treat these rules as guard rails against mistakes, not as a security boundary. The post-run `HEAD` check catches local commits. It cannot catch remote effects.

## Untrusted repositories

Before you delegate work on a repository you do not fully trust:

1. Read its build, test, and package-manager scripts (`package.json` scripts, `Makefile`, `*.ps1`, `setup.py`, CI helpers, Git hooks in `.git/hooks`).
2. Leave test commands out of the brief, or name exact commands you have reviewed.
3. Think about running the whole Codex and Claude session inside a disposable VM, Windows Sandbox, or container. ClaudeCX does not provide that isolation.
4. Do not keep credentials with write access to production systems in your environment while the bridge runs.

## Secrets

- Never put secrets or `.env` contents in a brief. Briefs are saved as plain text under `%LOCALAPPDATA%\CodexClaude\handoffs`.
- Handoff logs (`brief.md`, `claude-events.jsonl`, `claude-result.json`, `claude-stderr.txt`, `progress.log`, `report.json`) can contain fragments of source code and command output. `claude-events.jsonl` is the complete raw stream, including every tool input and tool result. Protect and clean up that folder the way you would protect the repositories themselves.

## Local dashboard

The default `-ProgressMode Dashboard` starts `show-dashboard.ps1` as a separate, hidden PowerShell process and opens the default browser at it.

- **Network exposure.** The server is a small, bounded HTTP/1.1 handler on a `TcpListener` bound to `127.0.0.1` with an OS-assigned port. It never binds `localhost`, a wildcard, IPv6, or a LAN address, and needs no admin rights or URL ACL changes. Requests whose `Host` header is not exactly `127.0.0.1:<port>` are rejected (DNS-rebinding defense). Headers are capped at 16 KiB, bodies at 4 KiB, and each connection serves one request with a 5-second read timeout.
- **Authentication.** Each run generates 256 bits of CSPRNG randomness as the token. The bridge passes it to the server only through the server's environment (cleared from the bridge immediately after start and from the server after reading); it is never placed on a command line we build, in metadata, the readiness file, logs, `failure.json`, the stop marker, Git state, or the repository. The browser receives it in the URL fragment (`#token=...`), which browsers do not send in requests or `Referer`. Note that the default browser itself receives the full URL on its command line, so another process running as the same user could see it; such a process can already read the handoff folder. The page removes the fragment with `history.replaceState`, keeps the token only in memory, and sends it as `Authorization: Bearer` on every `/api/*` call. Comparison is constant-time. Static assets (`/`, `/styles.css`, `/app.js`) are served without the token.
- **Fixed surface.** Only `GET /api/state`, `GET /api/changes`, `GET /api/report`, and `POST /api/stop` exist. There are no caller-controlled paths, commands, arguments, or URLs; unknown routes return 404 and wrong methods 405. Stop also rejects a foreign `Origin`. CORS is not enabled. `brief.md`, `claude-events.jsonl`, `claude-stderr.txt`, and raw tool payloads are never served.
- **Browser hardening.** Every response sends `Content-Security-Policy: default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'`, plus `X-Content-Type-Options: nosniff`, `X-Frame-Options: DENY`, `Referrer-Policy: no-referrer`, and `Cache-Control: no-store`. The page has no inline scripts, styles, or event handlers and renders all server content with `textContent`. JSON responses escape `<`, `>`, `&`, and quotes.
- **Git access.** The server runs only `git status --short --untracked-files=all` and `git diff --no-ext-diff --no-textconv --no-color HEAD --` against the recorded repository, through `ProcessStartInfo.ArgumentList`, with `--no-optional-locks` and `core.fsmonitor=false`, a 15-second timeout, and an output cap (2 MiB for the diff). It never writes to the repository.
- **Sensitivity.** The Activity tab carries the same sanitized lines as `progress.log`. The **Changes and Report tabs are not sanitized**: they show the real diff (which can include source code or secrets Claude wrote) and Claude's own report text. Treat the browser tab like your editor, and use `-ProgressMode Window`, `Console`, or `None` when the screen may be seen by others or recorded.
- **Control.** Stop run is the only mutation. It atomically creates `stop-request.json` (timestamp and source only) in the turn folder; the bridge, not the server, terminates Claude's process tree and records the run as stopped. Partial edits are preserved for Codex review. The server cannot touch Claude's stdin or stdout.
- **Lifetime.** Closing the browser never stops Claude. The server exits after the run completes (idle or linger timeout), when the bridge process disappears without completing, or at a hard lifetime limit.
- **Fallback.** If the dashboard cannot start or the browser cannot open, the bridge warns and falls back to `Window`, then `Console`. This never changes Claude's flags, permissions, or limits.

## Progress window

`-ProgressMode Window` opens a read-only PowerShell window that tails `progress.log`. It is an observer only:

- It is started with shell execution and inherits no handles from the bridge, so it cannot write to Claude's stdin or read Claude's stdout. Typing in it does nothing to the run, and closing it does not stop Claude.
- Progress lines show a tool or phase name and, at most, a generic activity label or a short path taken from a path-shaped field (`file_path`, `notebook_path`, `path`). Free-form inputs are never shown: search patterns and queries appear as `searching` (or `searching <path>`), URL tools appear as `requesting URL` with no host, and prompts, descriptions, and other values are omitted. Shell command text is never shown either; a command appears as `running command`, or `running <program>` when it starts with a bare, allowlisted program name. The raw inputs stay in `claude-events.jsonl` only. File contents, edits, tool output, thinking, the brief, environment variables, and raw JSON are never displayed. Control and terminal escape sequences are stripped, long values are truncated, and secret-looking values (`token=...`, `password: ...`, common API-key prefixes, URL credentials, long opaque strings) are masked.
- The remaining on-screen risk is limited to tool names, generic activity labels, and paths. A file or folder name can still be sensitive, and path masking is best effort. Treat the window and `progress.log` like terminal output, and use `-ProgressMode Console` or `-ProgressMode None` when the screen may be seen by others or recorded.
- If the window cannot be opened, the bridge falls back to `Console` (stderr). This changes only where progress is shown, never Claude's permissions or flags. Stdout stays reserved for the single final JSON line.
- The bridge never reads or copies Claude or Codex credential files. Authentication is left to Claude Code.

## Hooks and MCP isolation

Repository and user hooks are a direct code-execution path, so the bridge turns them off in two independent ways: safe mode and `disableAllHooks`. The live smoke test plants a `SessionStart` hook in a scratch repository and checks that it never runs, on both the initial call and the resume. MCP servers are turned off by safe mode and by `--strict-mcp-config` with an empty server map, and `mcp__*` tools are denied as well.

## Reporting a problem

If you find a way around a bridge control (for example, a resume that should have been refused, a hook that ran, or a commit that was not detected):

1. Stop using the bridge on sensitive repositories until the issue is understood.
2. Keep the relevant handoff folder, after removing anything sensitive.
3. Report it privately to the repository maintainers through the hosting platform's private vulnerability-reporting feature if it is enabled, or another private channel they publish. Do not open a public issue with exploit details.

If the problem is in Claude Code or Codex itself and not in this bridge, report it to that vendor as well.
