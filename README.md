# ClaudeCX

ClaudeCX is a Codex skill that hands scoped implementation work to Claude Code through a guarded PowerShell bridge.

- **Codex is the orchestrator.** It scopes the task, writes the brief, reviews the diff, and runs the checks itself.
- **Claude Code is the implementation worker.** It edits files in your repository and returns a structured report.

You invoke it explicitly with `$claudecx`. Codex never uses it on its own.

## Trust boundary

The bridge runs Claude Code in `--safe-mode` with a per-run role prompt, a settings file used only by the bridge, a strict empty MCP configuration, auto-memory and background tasks disabled, structured JSON output, a preassigned session UUID, a turn limit, a timeout, and a USD budget limit. Claude is told not to commit, push, deploy, publish, release, call Codex or Claude, or write anywhere outside the repository, and the bridge settings deny the common commands for those actions.

> **Warning:** ClaudeCX is defense in depth, **not a host sandbox**. Claude runs as your Windows user, with your file-system and network access. Permission deny rules match command text, so a determined or confused agent can get around them. Repository build and test scripts (`npm test`, `make`, `pytest`, and so on) can run arbitrary code. Use ClaudeCX only on repositories whose scripts you trust or have read. See [SECURITY.md](SECURITY.md).

## Supported platform and prerequisites

**Windows v1 only.** macOS and Linux are not supported or tested.

| Requirement | Check |
| --- | --- |
| Windows 10 or 11 | |
| PowerShell 7.2 or later (`pwsh`) | `pwsh --version` |
| Git | `git --version` |
| Codex (CLI, IDE extension, or app with skills support) | `codex --version` |
| Claude Code, signed in (subscription or API key) | `claude --version` and `claude auth status` |

Claude Code must support `--safe-mode` and the `auto` permission mode for your account.

## Quick start

```powershell
git clone https://github.com/Jadessz/ClaudeCX.git
cd ClaudeCX
pwsh -NoProfile -File .\install.ps1
```

The installer checks the packaged skill and copies it to `<CodexHome>\skills\claudecx`. Codex home is the `-CodexHome` value if you pass one, otherwise `CODEX_HOME`, otherwise `%USERPROFILE%\.codex`. When it finishes, it prints the next step.

To verify the repository itself (no network access, and your real configuration is not touched):

```powershell
pwsh -NoProfile -File .\scripts\test-static.ps1
pwsh -NoProfile -File .\scripts\test-install.ps1
```

Then **open a new Codex chat** (restart Codex if it was already running) so it picks up the skill.

### Optional: turn off Claude attribution globally

The bridge already turns off commit, PR, and session-URL attribution for its own runs. To turn it off for your interactive Claude sessions too:

```powershell
pwsh -NoProfile -File .\install.ps1 -DisableClaudeAttribution
```

This changes only `attribution.commit`, `attribution.pr`, and `attribution.sessionUrl` in `%USERPROFILE%\.claude\settings.json` (or `CLAUDE_CONFIG_DIR\settings.json`, or the file you pass with `-ClaudeSettingsPath`). All other keys are kept, and the original is saved as `settings.json.claudecx-backup-<timestamp>` first. The file must be strict JSON. Without this switch, the installer never touches Claude settings.

## Using `$claudecx`

In a Codex chat opened at a clean Git repository:

```text
$claudecx Add server-side validation for the email and password fields in
src/routes/signup.ts, return 400 with a field-level error map, and add unit
tests in tests/signup.test.ts. Run `npm test` afterwards.
```

Codex then:

1. reads the repository instructions and writes a brief outside the repository;
2. runs `invoke-claude.ps1`, which starts Claude Code with the guarded flags;
3. reads Claude's structured report, then checks `git status`, the full diff, and `HEAD` itself;
4. runs the relevant tests itself and resumes the same Claude session with a follow-up brief if fixes are needed;
5. tells you what changed, what it verified, and what risks remain.

Use only one writer at a time. Don't edit the repository while a bridge run is active.

## Live progress window

While Claude works, the bridge opens a separate PowerShell window titled `ClaudeCX - <repository>`. It shows one short line per phase or tool action, for example `Tool Edit: src\routes\signup.ts` or `Tool Bash: running npm`, followed by the final result. Shell details are hidden: a shell command is shown only as `running command`, or as `running <program>` when the command starts with a plain, well-known program name such as `npm`, `git`, or `pwsh`. Arguments, quoted strings, redirections, inline scripts, environment assignments, and URLs inside commands are never shown. The raw command is kept only in `claude-events.jsonl`.

- The window is a **read-only observer**. Claude itself still runs non-interactively under the bridge. Anything you type in the window is not sent to Claude.
- Closing the window **does not stop Claude** and does not fail the run. The full progress stays in `progress.log`.
- It closes a few seconds after a successful run. After a failure it stays open for five minutes (or until you press a key) so you can read the error.
- It never shows file contents, tool output, model thinking, the brief, environment variables, or raw JSON. Search tools appear as `Tool Grep: searching src` or `Tool Grep: searching` without the pattern, and URL tools as `Tool WebFetch: requesting URL` without the host. Prompts, queries, and other free-form tool inputs are never shown.
- What remains on screen is tool and phase names, generic activity labels, and shortened paths. A file or folder name can still reveal something sensitive, so treat the window like a terminal that someone could see over your shoulder.

For terminals without a desktop, or for CI, choose another mode:

```powershell
# Progress lines on stderr; stdout still carries only the final JSON line.
pwsh -NoProfile -File "<skill-root>\scripts\invoke-claude.ps1" -ProjectPath . -BriefPath brief.md -ProgressMode Console

# No live display; logs are still written.
pwsh -NoProfile -File "<skill-root>\scripts\invoke-claude.ps1" -ProjectPath . -BriefPath brief.md -ProgressMode None
```

If the window cannot be opened, the bridge prints a one-line warning on stderr and continues in `Console` mode. This only changes where progress is shown. Claude's flags, permissions, and limits stay the same.

## Lifecycle: clean tree, new runs, and resumes

- **New run.** The working tree must be completely clean, including untracked files. Commit, stash, or move unrelated changes first. The bridge records `HEAD` and a fingerprint of the working tree, then starts Claude with a new UUID.
- **Resume.** Codex passes the session UUID from the previous run. The bridge refuses to resume if you are in a different repository, if `HEAD` moved, or if the working tree changed since Claude's last successful turn. If that happens, start a new run from a clean tree. The role prompt and every safety flag are sent again on each resume.
- **Fail closed.** A non-zero exit code, `is_error: true`, any subtype other than `success`, a timeout, a malformed stream-json line, a missing result event or structured report, or a moved `HEAD` all count as failures.
- Only one bridge run per repository can hold `active.lock` at a time.

## Inspecting results and handoff logs

Handoff state is kept outside your repositories:

```text
%LOCALAPPDATA%\CodexClaude\handoffs\<repo-key>\
  active.lock                      # present only while a run is active
  <session-uuid>\
    session.json                   # repository, initial HEAD, created_at
    last-state.sha256              # working-tree fingerprint after the last success
    <yyyyMMdd-HHmmssfff>\           # one folder per turn
      brief.md
      status-before.txt / status-after.txt
      claude-events.jsonl          # raw Claude stream-json events, one per line
      claude-result.json           # the final stream-json result event
      claude-stderr.txt
      progress.log                 # sanitized, human-readable progress (what the window shows)
      progress.done                # completion marker for the progress window
      report.json                  # structured report (success only)
      failure.json                 # failure reason (failure only)
```

`<repo-key>` is the first 24 hex characters of the SHA-256 of the lowercase repository path. On success the bridge prints one line of JSON with `session_id`, `run_directory`, `report_path`, `events_path`, and `progress_log_path`. The report is a hint. The real evidence is `git status`, `git diff`, and your own test runs.

Logs are never deleted automatically. Remove old session folders yourself when you no longer need them. They can contain brief text and Claude output.

## Updating, reinstalling, and uninstalling

```powershell
git pull
pwsh -NoProfile -File .\install.ps1 -Force
```

`-Force` first moves the existing installation to `<CodexHome>\claudecx-backups\skill-<timestamp>`, then installs the new copy and verifies it. Without `-Force`, the installer refuses to overwrite. Restart Codex afterwards.

```powershell
pwsh -NoProfile -File .\uninstall.ps1 -Yes              # move to <CodexHome>\claudecx-backups\uninstalled-<timestamp>
pwsh -NoProfile -File .\uninstall.ps1 -Yes -Permanent   # delete outright
```

Uninstall removes only `<CodexHome>\skills\claudecx`, and only if its `SKILL.md` is named `claudecx`. Without `-Yes` it asks for confirmation, and in a non-interactive session it fails. It does not touch handoff logs, Claude settings, or other skills. To restore an uninstall backup, move the folder back to `<CodexHome>\skills\claudecx`. Both scripts accept `-CodexHome`.

## Troubleshooting

| Symptom | What to do |
| --- | --- |
| **Skill not discovered** (`$claudecx` does nothing) | Open a new chat or restart Codex. Check that `<CodexHome>\skills\claudecx\SKILL.md` exists. If you use a custom `CODEX_HOME`, install with that value or pass `-CodexHome`. The skill is explicit-only, so type `$claudecx` exactly. |
| **Claude not authenticated** | Run `claude auth status`, then `claude` once interactively to sign in. The bridge uses safe mode, not bare mode, so subscription OAuth credentials keep working. |
| **Auto mode unavailable** | The bridge refuses to fall back to a more permissive mode. Update Claude Code and check that your account or organization allows `auto` permission mode. Codex may use `-PermissionMode plan` for a read-only planning run. Never use `--dangerously-skip-permissions`. |
| **"requires a clean Git working tree"** | Commit, stash, or move all changes, including untracked files (`git status --porcelain --untracked-files=all` must print nothing). |
| **"working tree changed" / "HEAD changed" on resume** | Someone edited or committed after Claude's last successful turn. Review the changes, then start a new run from a clean tree. |
| **"Another Claude bridge run is active"** (stale lock) | Make sure no `claude` or bridge `pwsh` process is still running for that repository. A lock whose PID has exited is cleared on the next run. If the PID was reused by an unrelated process, delete `%LOCALAPPDATA%\CodexClaude\handoffs\<repo-key>\active.lock` by hand. |
| **Budget or turn-limit failure** (a non-`success` `subtype` such as `error_max_turns`) | The bridge failed closed on purpose. Check `claude-result.json` and `failure.json` in the run folder. Partial edits stay in the working tree. Because the fingerprint is updated only after a successful turn, a resume is refused once Claude has changed files. Review or discard the partial work, then start a new run with a narrower brief or a higher `-MaxTurns` or `-MaxBudgetUsd`. |
| **No progress window appears** | The bridge falls back to `Console` mode and prints a warning on stderr. Read `progress.log` in the run folder, or pass `-ProgressMode Console` (or `None`) explicitly. Closing the window never affects the run. |
| **"malformed stream-json line"** | Claude Code printed something that is not a JSON event. The bridge stopped Claude and failed closed. Inspect `claude-events.jsonl` (the last line is the bad one) and `claude-stderr.txt`, and update Claude Code. |
| **Timeout** | Claude's process tree is killed after `-TimeoutSeconds` (default 3600). Review the partial changes and split the task. |
| **Hooks / MCP concerns** | Safe mode turns off repository and user hooks, plugins, skills, agents, and MCP servers. The bridge settings also set `disableAllHooks` and deny `mcp__*`, and `--strict-mcp-config` loads an empty MCP configuration. Repository build and test scripts can still run code, so read them first. |
| **Installer refuses to run** | Read the message. It refuses on an existing install without `-Force`, an invalid packaged skill, non-strict Claude settings JSON, or a symlinked or junctioned destination. Nothing is changed when it refuses. |

## Repository layout

```text
install.ps1, uninstall.ps1        installer and uninstaller
skill/claudecx/                   the Codex skill (source of truth for the bridge)
  SKILL.md                        skill instructions for Codex
  agents/openai.yaml              display metadata; implicit invocation disabled
  assets/                         bridge settings, role prompt, report schema, empty MCP config
  scripts/invoke-claude.ps1       the bridge
  scripts/ClaudeCX.Progress.psm1  stream-json parsing, result checks, progress sanitizing
  scripts/watch-progress.ps1      read-only progress window
  scripts/test-claude-bridge.ps1  deep live smoke test
scripts/
  ClaudeCX.Common.psm1            shared installer and validation helpers
  test-static.ps1                 offline static validation (also runs test-progress.ps1)
  test-progress.ps1               offline stream-json, sanitizing, and progress-window tests
  test-install.ps1                offline sandboxed installer tests
  test-live.ps1                   opt-in live smoke test wrapper
docs/ARCHITECTURE.md              design and session flow
```

## Live smoke test (opt-in)

`scripts\test-live.ps1` **contacts Claude and uses up account usage.** It sets up disposable repositories under a new scratch path and checks a real write, the commit denial, a UTF-8 round trip, resume, hook suppression, and a forced max-turns failure:

```powershell
pwsh -NoProfile -File .\scripts\test-live.ps1 -ScratchRoot "$env:TEMP\claudecx-live-01" -AcknowledgeUsage -MaxBudgetUsd 1
```

`-MaxBudgetUsd` applies to each Claude call, and the test makes several calls. The live test runs the bridge with `-ProgressMode None` by default; pass `-ProgressMode Window` to watch the progress window during the run.

## More documentation

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md): components, trust boundaries, session flow
- [SECURITY.md](SECURITY.md): threat model and limitations
- [CONTRIBUTING.md](CONTRIBUTING.md): development workflow
- [AGENTS.md](AGENTS.md): instructions for Codex contributors
