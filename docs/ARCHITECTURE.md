# ClaudeCX architecture

ClaudeCX connects two agents with a narrow, auditable interface. Codex plans and reviews. Claude Code implements. A PowerShell bridge sits between them and enforces the process-level controls.

## Components

| Component | Location | Role |
| --- | --- | --- |
| Skill instructions | `skill/claudecx/SKILL.md` | Tell Codex when and how to delegate: explicit invocation only, clean tree, how to write a brief, how to verify independently. |
| Skill metadata | `skill/claudecx/agents/openai.yaml` | Display name `ClaudeCX`, a default prompt that mentions `$claudecx`, and `allow_implicit_invocation: false`. |
| Bridge | `skill/claudecx/scripts/invoke-claude.ps1` | Checks the Git state, takes the per-repository lock, records handoff state, starts Claude Code with fixed flags, enforces the timeout, and fails closed. |
| Bridge settings | `skill/claudecx/assets/bridge-settings.json` | Settings passed with `--settings`: hooks and auto-memory off, attribution off, deny rules for commit, push, publish, deploy, cloud, network-shell, recursion, secret reads, and MCP. |
| Role prompt | `skill/claudecx/assets/claude-role-prompt.md` | Appended to Claude's system prompt on every call with `--append-system-prompt-file`. |
| Report schema | `skill/claudecx/assets/report-schema.json` | The JSON Schema passed to `--json-schema`. Claude must return this structured report. |
| Empty MCP config | `skill/claudecx/assets/empty-mcp.json` | Used with `--strict-mcp-config` so no MCP server is loaded. |
| Live smoke test | `skill/claudecx/scripts/test-claude-bridge.ps1` | End-to-end check against the real Claude CLI (opt-in, uses account usage). |
| Installer / uninstaller | `install.ps1`, `uninstall.ps1` | Copy the skill into `<CodexHome>\skills\claudecx`, or remove it, with backups. |
| Shared helpers | `scripts/ClaudeCX.Common.psm1` | Skill validation, Codex-home resolution, tree hashing, the strict-JSON attribution merge. |
| Offline tests | `scripts/test-static.ps1`, `scripts/test-install.ps1` | Static invariants and sandboxed install tests. |

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
```

1. **User → Codex.** Delegation happens only when the user asks for it. Implicit invocation is turned off.
2. **Codex → bridge.** Codex passes a repository path, a brief path, and limits. The bridge does not trust Codex to have checked the Git state and checks it again itself.
3. **Bridge → Claude.** The bridge controls the command line, the environment, and the working directory. The brief is data on stdin and never becomes part of a command string. Arguments go through `ProcessStartInfo.ArgumentList`.
4. **Claude → repository.** Claude has your user's file-system and process access, limited by Claude Code's permission system and the deny rules. This boundary is **not** a sandbox. See [SECURITY.md](../SECURITY.md).
5. **Claude → Codex.** The structured report is advisory. Codex checks the diff, `HEAD`, and the tests itself.

## State layout

State is kept under `%LOCALAPPDATA%\CodexClaude\handoffs`, never inside a repository:

```text
<repo-key>/                 first 24 hex chars of SHA-256(lowercase repo root)
  active.lock               {token, pid, repository, created_at}
  <session-uuid>/
    session.json            {session_id, repository, initial_head, created_at}
    last-state.sha256       fingerprint after the last successful turn
    <turn-timestamp>/       brief.md, status-before/after, raw output, report or failure
```

The working-tree fingerprint is a SHA-256 over `git status --porcelain=v1 --untracked-files=all`, `git diff --binary HEAD`, `git diff --cached --binary HEAD`, and the content hash of every untracked file.

## New run flow

1. Refuse if `AGENT_HANDOFF_DEPTH` is set and non-zero, which means a nested call from Claude.
2. Resolve the repository root and `HEAD`.
3. Take `active.lock`. A lock held by a live PID blocks the run. A lock whose PID has exited is cleared.
4. Require an empty `git status --porcelain=v1 --untracked-files=all`.
5. Create a new session UUID. Record `session.json` (including `initial_head`) and the initial fingerprint.
6. Copy the brief and the status into a new turn folder.
7. Start `claude -p ... --safe-mode --permission-mode auto --output-format json --json-schema <schema> --max-turns N --max-budget-usd X --settings <bridge-settings> --append-system-prompt-file <role> --strict-mcp-config --mcp-config <empty> --session-id <uuid>`, with `AGENT_HANDOFF_DEPTH=1`, `CLAUDE_CODE_DISABLE_AUTO_MEMORY=1`, and `CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1`. The brief goes in as UTF-8 on stdin.
8. Wait up to `TimeoutSeconds`. On timeout, kill the whole process tree.
9. Fail closed on a non-zero exit, `is_error`, a non-`success` subtype, missing or invalid JSON, a missing structured report, or a moved `HEAD`.
10. On success, write `report.json`, update `last-state.sha256`, and print a one-line JSON summary.
11. Release the lock, but only if this run's token still owns it.

## Resume flow

Same as a new run, except:

- the session UUID must parse as a GUID and must have `session.json` and `last-state.sha256` in this repository's state folder;
- the recorded repository must match the current one (case-insensitive);
- `HEAD` must equal `initial_head`;
- the current fingerprint must equal `last-state.sha256`, so nothing changed since Claude's last successful turn;
- Claude is started with `--resume <uuid>` instead of `--session-id <uuid>`. The role prompt, settings, MCP isolation, schema, and limits are all sent again.

A failed turn does not update the fingerprint. If Claude changed files before failing, the session cannot be resumed and a new clean run is needed.

## Why safe mode instead of bare mode

Claude Code's `--bare` mode skips loading most local configuration, but it also skips OAuth and keychain credential discovery. Subscription-authenticated users (Claude Pro or Max sign-in) would then have no credentials. `--safe-mode` keeps authentication, the built-in tools, and the permission system, and turns off repository and user customizations: `CLAUDE.md` loading, skills, plugins, hooks, MCP servers, agents, output styles, workflows, and auto-memory. Because safe mode ignores repository instructions, Codex must copy every operative convention into the brief.

The bridge settings file then adds `disableAllHooks`, attribution suppression, and deny rules on top. `--strict-mcp-config` with an empty config means no MCP server can be loaded from any source.

## Platform scope

v1 targets Windows with PowerShell 7.2+. It relies on `%LOCALAPPDATA%`, Windows path conventions, and `claude.exe` discovery. Other platforms are not supported.
