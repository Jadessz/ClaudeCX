# Setting up ClaudeCX: a runbook for AI agents

This file is for an AI coding agent (Codex, Claude Code, Cursor, Copilot, or any other) that a user has handed this repository with a request such as "set this up for me". Follow it from top to bottom. When you finish, the user can type `$claudecx` in Codex and it works.

People can follow it too, but [README.md](../README.md) is the friendlier version.

## 1. What ClaudeCX is

ClaudeCX is a **Codex skill** for **Windows**. When the user types `$claudecx <request>` in a Codex chat:

1. **Codex plans.** It reads the user's project and writes a detailed task description for Claude (the *brief*).
2. **A PowerShell bridge guards the run.** `skill/claudecx/scripts/invoke-claude.ps1` checks that the project is a clean Git repository, takes a lock, and starts Claude Code with fixed safety settings: safe mode, the `auto` permission mode, bridge-only settings that block commit, push, and deploy, no MCP servers, and limits on turns, cost, and time.
3. **Claude Code builds.** It edits the files, runs the tests, and returns a structured report. It never commits, pushes, or deploys.
4. **Codex reviews.** It reads the real diff, reruns the tests, and sends fixes back to the same Claude session if needed.
5. **The user watches live.** A dashboard opens in the default browser on `127.0.0.1` with the request, the brief, every step Claude takes, the diff, the report, and a **Stop run** button.

The user commits the result themselves. Design details: [docs/ARCHITECTURE.md](ARCHITECTURE.md). Threat model and limits: [SECURITY.md](../SECURITY.md).

## 2. Rules for you, the agent

- **Windows only.** If the computer is not Windows 10 or 11, stop and tell the user ClaudeCX v1 does not support it.
- **Say what you will install before you install it.** Name each program (Git, PowerShell 7, Claude Code, Codex). If the user asked you to set everything up, that covers installing these; anything else, ask first.
- **Some steps only the user can do.** Signing in to Claude and to Codex opens a browser and needs their account. Windows may ask them to approve an installer. Start the step, tell them exactly what to click, and wait.
- **Do not weaken safety settings.** Never change the bridge's flags or settings, never use `--dangerously-skip-permissions` or `bypassPermissions`, and do not change the PowerShell execution policy unless `doctor.ps1` reports it as the problem and the user agrees.
- **Do not edit the user's Codex or Claude configuration** except through `install.ps1` as described here.
- **Never read, print, or store secrets** (API keys, tokens, `.env` files).
- **The live test costs money.** `scripts/test-live.ps1` contacts Claude and uses the user's plan. Run it only if the user asks.

## 3. How to run the commands

All commands below are **PowerShell 7** (`pwsh`), run from the ClaudeCX folder (the folder with `install.ps1`).

- If your shell is Windows PowerShell 5.1, cmd, or Git Bash, run each command as `pwsh -NoProfile -Command "<command>"`, or call the scripts with `pwsh -NoProfile -File <script>`.
- After installing a program with `winget`, your current shell does not see it yet. Reload `PATH` in PowerShell:

  ```powershell
  $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
  ```

  If a program is still not found, open a new terminal.

## 4. Steps

### Step 1: Get the repository

If you do not have it yet:

```powershell
git clone https://github.com/Jadessz/ClaudeCX.git
Set-Location ClaudeCX
```

If the user downloaded it as a ZIP instead, Windows marks every file as coming from the internet and PowerShell will refuse to run them ("is not digitally signed"). Unblock them once:

```powershell
Get-ChildItem -Recurse | Unblock-File
```

### Step 2: Check what is already there

```powershell
git --version
pwsh --version
claude --version
claude auth status
```

`pwsh --version` must print 7.2 or later. Note which commands are missing.

### Step 3: Install what is missing

| Missing | Install with | Then check |
| --- | --- | --- |
| Git | `winget install --id Git.Git -e --source winget` | `git --version` |
| PowerShell 7 | `winget install --id Microsoft.PowerShell -e --source winget` | `pwsh --version` |
| Claude Code | `irm https://claude.ai/install.ps1 \| iex` (official installer; see <https://code.claude.com/docs/en/setup>) | `claude --version` |
| Codex | The Codex desktop app, the Codex CLI, or the Codex IDE extension; see <https://developers.openai.com/codex>. The CLI installs with `npm install -g @openai/codex` (needs Node.js). | The app opens, or `codex --version` |

Reload `PATH` after each install (section 3).

If `claude --version` works but `doctor.ps1` later says the version lacks options, update it: `claude update`.

### Step 4: Sign in (the user does this)

- **Claude Code:** run `claude auth login`. A browser opens; the user signs in with their Claude account (Pro, Max, Team, or Enterprise) or Anthropic Console account. Then check: `claude auth status` must show `"loggedIn": true`. (An `ANTHROPIC_API_KEY` environment variable also works; never ask the user to paste a key to you.)
- **Codex:** the user opens Codex once and signs in with their OpenAI account.

### Step 5: Install the skill

```powershell
pwsh -NoProfile -File .\install.ps1
```

This validates the skill, copies it to `%USERPROFILE%\.codex\skills\claudecx` (or `CODEX_HOME\skills\claudecx`), unblocks the copy, and then runs the setup checks. If it says ClaudeCX is already installed, add `-Force` (the old copy is backed up first).

The installer also adds a **ClaudeCX** Start menu shortcut for the control center. Add `-NoShortcut` if the user does not want it, or `-StartAtLogin` if they want the control center started whenever they sign in.

Optional, only if the user wants it: `-DisableClaudeAttribution` stops Claude from adding itself as a co-author to the user's own commits. It edits three keys in `%USERPROFILE%\.claude\settings.json` and backs the file up first. Ask before using it.

### Step 6: Confirm everything is ready

```powershell
pwsh -NoProfile -File .\doctor.ps1 -Json
```

It prints one JSON object. You are done when `"ready": true`. Otherwise every check with `"status": "fail"` has a `fix`. Act on it, then run the check again:

| Check `id` | Who fixes it | What to do |
| --- | --- | --- |
| `windows` | — | Not supported; stop. |
| `execution-policy` | You, with the user's OK | `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned` |
| `downloaded-files` | You | `Get-ChildItem -Recurse \| Unblock-File` in the ClaudeCX folder |
| `git` | You | Install Git (step 3). |
| `claude-found` | You | Install Claude Code (step 3), reload `PATH`. |
| `claude-options` | You | `claude update` |
| `claude-signin` | The user | `claude auth login` (step 4). |
| `codex-home` (warning) | The user | Install and open Codex once. Pass `-CodexHome` if they use a custom `CODEX_HOME`. |
| `skill-installed` | You | `pwsh -NoProfile -File .\install.ps1 -Force` |
| `skill-unblocked` | You | `pwsh -NoProfile -File .\install.ps1 -Force` |
| `log-folder` | The user | `%LOCALAPPDATA%\CodexClaude\handoffs` must be writable; check security software. |
| `browser` (warning) | The user | Optional. Without a default browser the bridge shows a progress window instead of the dashboard. |

Warnings (`"status": "warn"`) do not block use.

Optional offline self-test (no Claude calls, about a minute):

```powershell
pwsh -NoProfile -File .\scripts\test-static.ps1
pwsh -NoProfile -File .\scripts\test-install.ps1
```

### Step 7: Hand over to the user

Tell the user, in plain words:

1. **Restart Codex** (or open a new chat) so it loads the skill.
2. **Open a Codex chat in a Git project with at least one commit and no uncommitted changes.** ClaudeCX refuses to start on a dirty tree, so their own work is never mixed with Claude's.
3. **Type `$claudecx` and the request**, for example: `$claudecx add a dark mode toggle to the settings page and remember the choice`.
4. **Approve the bridge command if Codex asks.** It needs network access (Claude talks to Anthropic) and writes logs to `%LOCALAPPDATA%\CodexClaude\handoffs`. With the Codex CLI, a sandbox without network access blocks Claude; approve running the command outside the sandbox.
5. **Watch the run** in the browser. **ClaudeCX** in the Start menu opens the control center, which shows the live run, every past run, settings (budget, turns, time, model, protected paths), and setup health. Closing the page does not stop Claude; **Stop run** does.
6. **Review and commit.** Codex reports what changed and what it checked. Nothing is committed automatically.

## 5. Facts you may need later

- **Run logs:** `%LOCALAPPDATA%\CodexClaude\handoffs\<repo-key>\<session>\<turn>\`. When the Codex desktop app runs the bridge, Windows redirects this to `%LOCALAPPDATA%\Packages\OpenAI.Codex_<id>\LocalCache\Local\CodexClaude\handoffs\`.
- **Settings:** `pwsh -NoProfile -File "$env:USERPROFILE\.codex\skills\claudecx\scripts\claudecx-settings.ps1"` shows them; add `-Set name=value` to change one. Do not change settings the user did not ask for.
- **Update:** `git pull`, then `pwsh -NoProfile -File .\install.ps1 -Force`.
- **Uninstall:** `pwsh -NoProfile -File .\uninstall.ps1 -Yes` (moves the skill to a backup) or add `-Permanent` to delete it.
- **Problems after setup:** see the Troubleshooting section of [README.md](../README.md#12-troubleshooting).
- **Working on ClaudeCX's own code** (not setting it up): follow the rules in [AGENTS.md](../AGENTS.md#working-on-this-repository).
