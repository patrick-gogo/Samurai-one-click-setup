# Samurai Dashboard Web App — Design

Date: 2026-06-29
Status: Approved (pending spec review)

## Context

The "Samurai Dev" desktop shortcut (`Samurai Dev.lnk`) runs `scripts/samurai-dev.ps1`,
which boots the full dev environment (Docker, the compose stack, VS Code) and opens a
Windows Terminal window with several tabs. One of those tabs ("Dashboard", created on
`samurai-dev.ps1:127`) runs `scripts/samurai-dash.ps1` — a keypress-refresh TUI showing
live REPOS / DOCKER / HEALTH status with a single-key command bar
(`[r]efresh [o]pen-PR [d]ocker [a]claude [g]ithub [c]ode [j]ira [l]ocalhost [w]gogo [q]uit`).

The single-key TUI works but is fiddly: every action is a hidden keystroke followed by a
text prompt (e.g. press `o`, then type `a`/`s`, then type a PR number). The goal is to
replace that TUI with a **local web app** offering the same live status and the same
actions as visible, clickable controls — no memorized keys, no chained text prompts.

Out of scope: the `.lnk` shortcut and the rest of `samurai-dev.ps1` (Docker boot, compose
up, VS Code, the Servers/Claude tabs) are unchanged. Only the Dashboard tab's behavior
changes.

## Goals / Success criteria

- Every capability of `samurai-dash.ps1` is reachable from the web UI (status + all actions).
- Status auto-refreshes; no manual keypress needed to see current state.
- Launching is unchanged for the user: double-click `Samurai Dev.lnk`; the dashboard now
  appears in the browser instead of a terminal tab.
- The TUI script remains on disk as an untouched fallback.

## Decisions (locked)

- **Stack:** Node.js using the **built-in `http` module — zero dependencies**. No
  `npm install`, no `node_modules`. Matches the dependency-free ethos of the existing
  `samurai-dash.Tests.ps1`.
- **Port / binding:** listens on **`127.0.0.1:7777`** only. Localhost-only is a hard
  requirement because action endpoints execute local shell commands; they must not be
  reachable from the network.
- **Relationship to TUI:** **Replace.** The Dashboard tab runs the web server instead of
  the TUI. `samurai-dash.ps1` stays on disk, unused, as a fallback.
- **UI scope:** **Minimal single page** — one `index.html`, vanilla JS, inline CSS.

## Architecture

New folder in the existing `scripts` git repo: `scripts/samurai-dash-web/`

```
samurai-dash-web/
  server.js          # http server: serves the page, /api/status, /api/* action routes
  lib.js             # pure logic, no I/O — unit-testable without HTTP
  public/
    index.html       # single page: status cards + action controls (vanilla JS, inline CSS)
  test.js            # dependency-free unit tests for lib.js (node test.js)
  package.json       # { "scripts": { "start": "node server.js", "test": "node test.js" } }
```

Separation of concerns mirrors how `samurai-dash.ps1` already splits pure helpers
(`Resolve-Repo`, `Parse-DockerCmd`, `Format-RepoLine`, `Get-GogoSites`, …) from the
side-effecting loop:

- **`lib.js` (pure, no shell, no network):** repo config (admin/store paths + GitHub
  slugs), `resolveRepo(key)`, `buildPrUrl(repo, n)`, `buildGithubUrl(repo)`,
  `validatePrNumber(s)`, `gogoSites()`, `parseDockerPs(rawJson)`,
  `formatRepoLine(info)` / status-shaping helpers, and the static URLs (Jira, localhost,
  GOGO). These are the functions `test.js` covers.
- **`server.js` (I/O):** maps HTTP requests to (a) reads that call the pure parsers over
  command output, or (b) actions that shell out. Reuses the *exact* commands the TUI runs.

### Repo / command constants (ported from the PS scripts)

- admin repo: `C:\Users\John Patrick Mandal\Desktop\samurai_cart_v3` (slug `samurai_cart_v3`)
- store repo: `C:\Users\John Patrick Mandal\Desktop\samurai_cart_v3_frontend` (slug `samurai_cart_v3_frontend`)
- GitHub owner: `f-i-d` → PR URL `https://github.com/f-i-d/<slug>/pull/<n>`, repo URL `https://github.com/f-i-d/<slug>`
- Jira: `https://f-i-d.atlassian.net/jira/software/projects/V3/list`
- localhost: `http://localhost:3000`, `http://localhost:3001`
- GOGO sites: the 3 entries from `Get-GogoSites` (Sprout Employee Dashboard, GOGO Monthly Shift, Conference Room Calendar) — copy URLs verbatim.

## API

| Method | Route | Purpose | Shell it runs (same as TUI) |
|--------|-------|---------|------------------------------|
| GET | `/` | serve `public/index.html` | — |
| GET | `/api/status` | `{ repos, docker, health }` | `git -C <repo> rev-parse/status/rev-list`; `docker compose -f <admin>\docker-compose.yml ps --format json`; HTTP-ping :3000 /:3001 /:8000/docs |
| POST | `/api/docker` | restart/stop/start a service | `docker compose -f <admin>\docker-compose.yml <action> <service>` |
| POST | `/api/claude` | open Claude in admin/store | `wt -w samurai new-tab --title "claude (<name>)" --suppressApplicationTitle -d <repo> pwsh -NoExit -Command claude` |
| POST | `/api/code` | open VS Code in admin/store | `code <repo>` |
| POST | `/api/open` | open a URL in the default browser | `start "" <url>` (PR / GitHub / Jira / localhost / GOGO) |

Notes:
- `/api/docker` body: `{ action: 'restart'|'stop'|'start', service }`. Server validates
  `action` against the allowlist (same guard as `Parse-DockerCmd`) and rejects anything else.
- `/api/open` body: `{ url }`. Server validates the URL against an **allowlist** built from
  `lib.js` (the known GitHub/Jira/localhost/GOGO URLs + `buildPrUrl` output) so the endpoint
  can't be coerced into opening arbitrary things. PR open = client posts `{repo, prNumber}`
  to a dedicated `/api/open-pr` (validates number, builds URL server-side) rather than a raw URL.

### Status JSON shape

```
{
  repos:  [ { name, ok, branch, dirty, unpushed, behind } , ... ],
  docker: { engineUp: bool, services: [ { service, state, status, health: 'ok'|'warn'|'down' } ] },
  health: [ { name, port, url, up } , ... ]
}
```

## UI (single page)

- **Header:** "all systems go" / "N issues" summary + clock, computed client-side from
  the status payload (same logic as the TUI header).
- **REPOS card:** per repo — name, branch, clean/dirty/unpushed/behind, colored status dot.
- **DOCKER card:** per service — name + colored dot, and **restart / stop / start** buttons
  inline on each service row.
- **HEALTH card:** admin FE / store FE / admin API with up/down dots; names link to the URL.
- **Actions bar:** Refresh; PR-open (admin/store toggle + number field); Claude→admin /
  Claude→store; VS Code→admin / →store; GitHub→admin / →store; Jira; Open localhost; and
  the 3 GOGO links.
- **Behavior:** poll `GET /api/status` every 5s and on manual Refresh. Action buttons POST,
  then show a brief inline success/error line. Vanilla `fetch`, no framework, no build step.

## Error handling

- `/api/status` degrades gracefully: docker engine down → `docker.engineUp:false` →
  UI shows "engine down" (same as TUI). A failing git read for one repo → that repo
  `ok:false` ("n/a"), others still render.
- Every action route is wrapped: on failure return HTTP 200 `{ ok:false, error }` (or 4xx
  for validation failures) and surface the message inline; the server never crashes on a
  bad action.
- Server binds `127.0.0.1` only; if `7777` is in use, log a clear message and exit non-zero
  so the Dashboard tab visibly shows the failure.

## Launcher change

`scripts/samurai-dev.ps1:127` currently:

```
';', 'new-tab', '--title', 'Dashboard', '--suppressApplicationTitle', '-d', $admin, 'pwsh', '-NoExit', '-Command', "& '$PSScriptRoot\samurai-dash.ps1'",
```

becomes a tab that runs the web server (working dir = the new folder), e.g.:

```
';', 'new-tab', '--title', 'Dashboard', '--suppressApplicationTitle', '-d', "$PSScriptRoot\samurai-dash-web", 'pwsh', '-NoExit', '-Command', 'node server.js',
```

`server.js` **auto-opens the browser** to `http://localhost:7777` on successful boot
(`start "" http://localhost:7777`). The Dashboard tab thus shows the server log and can be
Ctrl-C'd to stop it. No other line of `samurai-dev.ps1` changes.

## Testing / verification

- **Unit (`node test.js`, zero-dep):** port the coverage that `samurai-dash.Tests.ps1`
  has — `resolveRepo` (a→admin, s→store, default→admin), `buildPrUrl`/`buildGithubUrl`,
  `validatePrNumber` (rejects non-numeric), docker action allowlist, `gogoSites` (3 sites,
  correct URLs/labels), `parseDockerPs` (array vs newline-delimited JSON), repo/health line
  formatting.
- **Manual E2E:** run `node server.js`, confirm browser opens to the dashboard; verify
  status cards match `docker compose ps` / git state; click each action and confirm the
  same real effect as the TUI (docker restart actually restarts; Claude/VS Code/links open).
- **Regression:** double-click `Samurai Dev.lnk` end-to-end and confirm the Dashboard tab
  now serves the web app and the rest of the environment still comes up unchanged.

## Risks / notes

- Action endpoints execute shell commands; localhost-only binding + the `/api/open`
  URL allowlist + the docker action allowlist are the safeguards. No auth beyond
  loopback-only is needed for a single-user local dev tool.
- `wt` / `code` / `docker` / `node` are all on PATH (verified) so the spawned commands work
  from the Dashboard tab's pwsh context.
