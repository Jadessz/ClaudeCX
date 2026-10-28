# Contributing to ClaudeCX

## Ground rules

- `skill/claudecx/` is the source of truth for the bridge. Keep changes small and focused. Do not replace the architecture described in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) without discussing it first.
- Preserve the safety invariants: safe mode, the role prompt on initial **and** resumed calls, bridge-only settings, strict empty MCP config, auto-memory and background tasks off, structured output, a preassigned UUID, turn, budget, and timeout limits, clean-tree and resume checks, and fail-closed result handling.
- Windows v1 only. Do not claim support for other platforms unless it is implemented and tested.
- Use structured PowerShell and .NET operations (`-LiteralPath`, `ProcessStartInfo.ArgumentList`, argument arrays). Never build shell command strings, and never use `Invoke-Expression`.
- Keep JSON strict (no comments, no trailing commas). Text files are UTF-8 without BOM, with LF line endings (enforced by `.gitattributes`).
- No user-specific paths, emails, session IDs, or machine assumptions in committed files.
- Static and installer tests must not need a package-manager install, network access, or real user configuration.
- Installed users never need Node or npm. React and Vite are contributor build tools only; the built dashboard is checked in.

## Dashboard source and build

The dashboard UI lives in `dashboard-src/` (React, built with Vite). The production build writes exactly three stable files to `skill/claudecx/dashboard/`: `index.html`, `app.js`, and `styles.css`, with no source maps, no inline script or style, and no external resources. The PowerShell server serves only those fixed files. Never edit the built files by hand.

After changing anything in `dashboard-src/`, rebuild and check (Node 20 or later):

```powershell
npm ci
npm run dashboard:build
npm run dashboard:check
```

`dashboard:check` runs deterministic static and design checks: stable asset names, no source maps, no external URLs (XML namespace identifiers React needs for SVG are allowed; they are never fetched), no inline script or style, no `dangerouslySetInnerHTML` or other HTML injection, a single `fetch` call site with fixed routes, reduced-motion support, system fonts only, no emoji, glassmorphism, or purple accents. The build is deterministic; commit the rebuilt assets together with the source change. `test-static.ps1` also checks the built assets, but it does not run Node.

For an optional Impeccable source scan (requires network access and is not a project dependency), run `npx --yes impeccable@latest detect dashboard-src/src`. Its source scan catches known UI anti-patterns; rendered-page checks such as contrast still require a running dashboard URL. The deterministic `dashboard:check` remains the offline project gate.

## Workflow

You need PowerShell 7.2 or later (`pwsh`) to run the scripts. If `pwsh` is not found, install it with `winget install --id Microsoft.PowerShell -e --source winget`. The Codex desktop app's bundled copy does not put `pwsh` on your own terminal's path.

1. Create a branch.
2. Make your change.
3. Run the offline suites:

   ```powershell
   pwsh -NoProfile -File .\scripts\test-static.ps1
   pwsh -NoProfile -File .\scripts\test-install.ps1
   ```

   `test-install.ps1` runs entirely in a temporary sandbox. Pass `-KeepSandbox` to inspect the result.
4. If you changed `invoke-claude.ps1`, the bridge assets, or anything that affects how Claude is started, also consider running the live test (see below).
5. Update `README.md`, `docs/ARCHITECTURE.md`, and `SECURITY.md` when behavior changes. `test-static.ps1` checks some documentation consistency.
6. Open a pull request that describes the change and which suites you ran.

## Live tests are opt-in

`scripts\test-live.ps1` contacts Claude and uses up account usage. It never runs automatically, and it refuses to start without `-AcknowledgeUsage` and a fresh scratch path outside the repository:

```powershell
pwsh -NoProfile -File .\scripts\test-live.ps1 -ScratchRoot "$env:TEMP\claudecx-live-01" -AcknowledgeUsage -MaxBudgetUsd 1
```

Do not add live Claude calls to `test-static.ps1` or `test-install.ps1`.
