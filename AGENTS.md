# Instructions for AI agents

This repository packages **ClaudeCX**, a Windows-only (v1) Codex skill that delegates implementation to Claude Code through a guarded bridge. The user types `$claudecx <request>` in Codex; Codex writes a brief, a PowerShell bridge starts Claude Code with fixed safety settings, Claude edits the project, and Codex reviews the real diff. A local dashboard shows the run live.

## Setting ClaudeCX up for a user

If the user asked you to install or set up this tool, follow **[docs/AGENT-SETUP.md](docs/AGENT-SETUP.md)** step by step. In short:

1. Check for Git, PowerShell 7 (`pwsh`), Claude Code (`claude`), and Codex; install what is missing.
2. Have the user sign in to Claude Code (`claude auth login`) and to Codex.
3. Run `pwsh -NoProfile -File .\install.ps1`.
4. Run `pwsh -NoProfile -File .\doctor.ps1 -Json` until it reports `"ready": true`, applying each `fix` it gives.
5. Tell the user to restart Codex and type `$claudecx` in a clean Git project.

Do not modify the repository while setting it up.

## Working on this repository

### Layout

- `skill/claudecx/`: the skill and bridge (source of truth). `scripts/invoke-claude.ps1` is the bridge.
- `install.ps1`, `uninstall.ps1`: install to and remove from `<CodexHome>\skills\claudecx`. `doctor.ps1`: read-only setup checks.
- `scripts/ClaudeCX.Common.psm1`: shared helpers. `scripts/test-*.ps1`: validation.
- `dashboard-src/`: React source of the dashboard; the built files in `skill/claudecx/dashboard/` are checked in.
- `docs/ARCHITECTURE.md`, `SECURITY.md`: design and threat model. `docs/AGENT-SETUP.md`: setup runbook for agents. Keep them in sync with the code.

### Rules

- Keep the one-writer contract. Never edit the repository while a Claude bridge run is active. New bridge runs require a clean tree, including untracked files.
- Do not weaken bridge invariants: `--safe-mode`, the role prompt on initial and resumed calls, bridge-only settings, strict empty MCP config, auto-memory and background tasks off, structured output, a preassigned UUID, turn, budget, and timeout limits, resume repository, `HEAD`, and fingerprint checks, and fail-closed handling of exit code, `is_error`, and `subtype`.
- The skill name stays lowercase `claudecx`. `agents/openai.yaml` keeps `allow_implicit_invocation: false` and a default prompt mentioning `$claudecx`.
- Use structured PowerShell. Never build shell command strings and never use `Invoke-Expression`. Keep JSON strict. Use UTF-8 without BOM and LF line endings.
- Do not commit user-specific paths, emails, session IDs, or secrets.
- Tests must never touch the real Codex or Claude configuration.

### After every change, run

```powershell
pwsh -NoProfile -File .\scripts\test-static.ps1
pwsh -NoProfile -File .\scripts\test-install.ps1
```

`scripts\test-live.ps1` contacts Claude and uses up account usage. Run it only when the user explicitly asks.
