# Samurai one-click setup

PowerShell tooling that wraps my day-to-day workflow on the Samurai Cart V3
codebase — launching the dev environment, running tests against isolated
per-ticket databases, managing git worktrees, and driving a few unattended
overnight passes.

These are personal developer scripts, not a product. They assume my machine's
layout (`C:\Users\john\Desktop\samurai_cart_v3` and friends) and are published
mainly as a reference for anyone building similar automation.

## Requirements

- Windows 11, PowerShell 7 (`pwsh`) — a few scripts also tolerate Windows PowerShell 5.1
- Windows Terminal
- Docker Desktop (the backend, Postgres and Alembic all run in containers)
- Git 2.30+ (worktree support)
- Node.js (for `agent-hook.js` and the frontend)
- [Pester](https://pester.dev/) 5.x to run the test suite

## Layout

The scripts expect two sibling checkouts on the Desktop, plus a worktrees folder:

```
Desktop/
  samurai_cart_v3/                 # backend + admin frontend
  samurai_cart_v3_frontend/        # standalone storefront
  samurai_cart_v3 worktrees/       # per-ticket worktrees (wt-{KEY}-{slug})
```

Put this repo on your `PATH` so the scripts are callable by name from anywhere.

## Scripts

### Daily driver

| Script | What it does |
|---|---|
| `samurai-dev.ps1` | Opens the whole dev environment in one Windows Terminal window — venv + API logs in one tab, admin frontend + storefront in another. |
| `samurai-dash.ps1` | Keypress-refresh TUI command center: branch, dirty/unpushed counts and migration drift for both repos, plus a command bar. |
| `samurai-greeting.ps1` | The boot intro the launcher prints. Cosmetic. |
| `samurai-dashboard-autostart.ps1` | Starts the [command-center dashboard](https://github.com/patrick-gogo/samurai-patrick-command-center) production build. |

### Tests and migrations

| Script | What it does |
|---|---|
| `samurai-test.ps1` | Runs backend pytest against a **per-ticket** database (`samurai_cart_test_{key}`), derived from the worktree folder or branch name, so concurrent runs from different worktrees never race on one schema. Passes pytest flags straight through. |
| `samurai-alembic.ps1` | Runs Alembic using the **current directory's** code rather than whatever checkout the long-running `api` container was started from — a throwaway `docker run --rm` bind-mounting where you stand, on the same network as the `db` container. |
| `samurai-testdb-lib.ps1` | Shared helpers for deriving and provisioning the per-ticket test DB. |
| `samurai-migration-lib.ps1` | Detects when the shared dev DB's Alembic stamp has drifted from the migrations on disk. |

### Worktrees

| Script | What it does |
|---|---|
| `samurai-sync-frontend-deps.ps1` | Provisions a worktree's `frontend/node_modules` by linking it to the main checkout's store instead of reinstalling. |
| `samurai-junction-lib.ps1` | NTFS directory-junction primitives the worktree tooling shares. |
| `samurai-cleanup-ticket.ps1` | Removes a finished ticket's worktree *and* its isolated test DB in one step. Manual/opt-in. |

### Unattended passes

Overnight automation driven by Windows scheduled tasks. Each pass runs Claude Code
under a restricted permission profile (the `*-scheduled.settings.json` files), loaded
with `--settings` so interactive sessions are unaffected. None of them are
`bypassPermissions`.

| Script | What it does |
|---|---|
| `samurai-night-shift.ps1` | The overnight wrapper: runs the configured passes, then posts a short summary. |
| `samurai-night-shift-watchdog.ps1` / `.psm1` | Watches the night run and recovers or reports if it stalls. |
| `samurai-night-validate.ps1` | Pre-flight validation before a night run starts. |
| `samurai-night-build-lib.ps1` | Pure helpers shared by the night shift and night build. |
| `samurai-night-build-probe.ps1` | Probe used to verify the night build's assumptions still hold. |
| `samurai-fix-conflicts.ps1` | Unattended `/fix-conflicts` run. Commits resolutions locally but **never pushes** — the push is the human gate. |
| `samurai-open-tickets.ps1` | Unattended open-ticket census. |

### Other

| File | What it does |
|---|---|
| `agent-hook.js` | `PreToolUse` hook forwarder — POSTs Claude Code's hook payload to the dashboard's local sidecar (port 3005) so its Agents panel shows live activity. |

## Permission profiles

`fix-conflicts-scheduled.settings.json`, `night-notify-scheduled.settings.json`,
`night-prep-scheduled.settings.json` and `open-tickets-scheduled.settings.json` each
scope one unattended pass. Every one carries a `$comment` explaining why each allow
and deny is there — worth reading before editing, since several rules are load-bearing
in non-obvious ways (for example, permission patterns match a command *prefix*, so a
`git push` deny does not catch `git -C <dir> push`; a `PreToolUse` hook covers the rest).

## Tests

Pester suites live beside the scripts they cover (`*.Tests.ps1`). Scripts that would
otherwise execute on load accept `-NoRun` so they can be dot-sourced for testing:

```powershell
Invoke-Pester .
```

## Docs

`docs/superpowers/` holds the design specs, plans and handoffs behind the larger pieces
of this tooling.
