# Repository instructions for Codex

This repository packages **ClaudeCX**, a Windows-only (v1) Codex skill that delegates implementation to Claude Code through a guarded bridge.

## Layout

- `skill/claudecx/`: the skill and bridge (source of truth). `scripts/invoke-claude.ps1` is the bridge.
- `install.ps1`, `uninstall.ps1`: install to and remove from `<CodexHome>\skills\claudecx`.
- `scripts/ClaudeCX.Common.psm1`: shared helpers. `scripts/test-*.ps1`: validation.
- `docs/ARCHITECTURE.md`, `SECURITY.md`: design and threat model. Keep them in sync with the code.

## Rules

- Keep the one-writer contract. Never edit the repository while a Claude bridge run is active. New bridge runs require a clean tree, including untracked files.
- Do not weaken bridge invariants: `--safe-mode`, the role prompt on initial and resumed calls, bridge-only settings, strict empty MCP config, auto-memory and background tasks off, structured output, a preassigned UUID, turn, budget, and timeout limits, resume repository, `HEAD`, and fingerprint checks, and fail-closed handling of exit code, `is_error`, and `subtype`.
- The skill name stays lowercase `claudecx`. `agents/openai.yaml` keeps `allow_implicit_invocation: false` and a default prompt mentioning `$claudecx`.
- Use structured PowerShell. Never build shell command strings and never use `Invoke-Expression`. Keep JSON strict. Use UTF-8 without BOM and LF line endings.
- Do not commit user-specific paths, emails, session IDs, or secrets.
- Tests must never touch the real Codex or Claude configuration.

## After every change, run

```powershell
pwsh -NoProfile -File .\scripts\test-static.ps1
pwsh -NoProfile -File .\scripts\test-install.ps1
```

`scripts\test-live.ps1` contacts Claude and uses up account usage. Run it only when the user explicitly asks.
