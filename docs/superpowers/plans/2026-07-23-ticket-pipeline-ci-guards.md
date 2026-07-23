# Ticket-Pipeline CI Guards Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wire the existing per-ticket test-DB isolation fix into `/ship-ticket`'s actual TDD loop, and add a local pre-merge guard script that mirrors `samurai_cart_v3`'s real CI checks (PR-title/branch format + the full `e2e-smoke` sequence) so a broken PR is caught before it burns GitHub Actions minutes.

**Architecture:** Two independent components. Component 1 is a text edit to `~/.claude/commands/ship-ticket.md` (no new code — it just makes an existing script the specified command). Component 2 is a new PowerShell script (`~/scripts/samurai-e2e-guard.ps1`) that dot-sources the existing `samurai-testdb-lib.ps1` for per-ticket DB isolation, runs the same migrate→seed→build→test sequence as CI's `e2e-smoke` job against an isolated database and alternate ports (so it can run alongside a normal local dev session without colliding), then gets wired into `~/.claude/commands/open-pr.md` as a new pre-flight step.

**Tech Stack:** PowerShell 7+ (pwsh), Docker (existing `samurai_cart_v3-api:latest` image + `samurai_cart_db` container + `samurai_cart_network`), Node/npm/Next.js/Playwright (frontend), pytest/alembic (backend, via the same Docker image).

## Global Constraints

- Dependency-free tests only — this repo's convention (`samurai-testdb-lib.Tests.ps1`, `samurai-dash.Tests.ps1`) uses a hand-rolled `Assert` scriptblock harness, not Pester. Match it exactly; do not introduce Pester.
- Scripts are dot-sourceable with a `-NoRun` switch so their pure functions can be tested without triggering side effects (existing pattern in `samurai-test.ps1`, `samurai-dash.ps1`).
- Never silently fall back or silently skip a check — every fallback/skip must print why, per this project's established "flag unknowns, don't guess" posture.
- The e2e guard must not collide with a normal already-running local dev session (`samurai_cart_api` on :8000, frontend dev server) — use alternate ports (backend :8099, frontend :3099) and an isolated database, never the shared dev DB.
- Backend commands run via `docker run` against the pre-built `samurai_cart_v3-api:latest` image with the worktree's `backend/` mounted as a volume (matches `samurai-test.ps1`'s exact pattern) — never assume a local Python venv exists outside Docker.
- Frontend commands (`npm test`, `npm run build`, `next start`, `playwright`) run natively on the host from the worktree's `frontend/` directory — confirmed no Docker-based frontend workflow exists locally (`docker-compose.yml`'s frontend service is commented out).

---

### Task 1: Branch-name and PR-title convention checks (TDD)

**Files:**
- Create: `C:\Users\John Patrick Mandal\scripts\samurai-e2e-guard.ps1`
- Create: `C:\Users\John Patrick Mandal\scripts\samurai-e2e-guard.Tests.ps1`

**Interfaces:**
- Produces: `Test-BranchNameConvention([string]$Branch) -> bool`, `Test-PrTitleConvention([string]$Title) -> bool` — later tasks (Task 4) call both.

- [ ] **Step 1: Write the failing tests**

Create `C:\Users\John Patrick Mandal\scripts\samurai-e2e-guard.Tests.ps1`:

```powershell
# Dependency-free tests. Run: pwsh -NoProfile -File samurai-e2e-guard.Tests.ps1
. "$PSScriptRoot\samurai-e2e-guard.ps1" -NoRun

$script:fails = 0
$script:ran = 0
# Scriptblock form so a THROW (e.g. undefined function) counts as FAIL, not a silent skip.
function Assert([string]$Msg, [scriptblock]$Cond) {
    $script:ran++
    $old = $ErrorActionPreference; $ErrorActionPreference = 'Stop'
    try {
        if (& $Cond) { Write-Host "PASS: $Msg" -ForegroundColor Green }
        else { $script:fails++; Write-Host "FAIL: $Msg" -ForegroundColor Red }
    } catch {
        $script:fails++; Write-Host "FAIL: $Msg -- $($_.Exception.Message)" -ForegroundColor Red
    } finally { $ErrorActionPreference = $old }
}

# --- Test-BranchNameConvention ---
Assert 'branch: bugfix/ ok'        { Test-BranchNameConvention 'bugfix/V3-1193-category-duplicate-name-guard' }
Assert 'branch: feature/ ok'       { Test-BranchNameConvention 'feature/V3-295-newsletter-guard' }
Assert 'branch: hotfix/ ok'        { Test-BranchNameConvention 'hotfix/urgent-thing' }
Assert 'branch: master rejected'   { -not (Test-BranchNameConvention 'master') }
Assert 'branch: no-slash rejected' { -not (Test-BranchNameConvention 'bugfix-no-slash') }
Assert 'branch: empty-after-slash rejected' { -not (Test-BranchNameConvention 'bugfix/') }

# --- Test-PrTitleConvention ---
Assert 'title: fix ok'             { Test-PrTitleConvention 'fix(V3-1193): resolve duplicate name guard' }
Assert 'title: feat no-scope ok'   { Test-PrTitleConvention 'feat: add new thing' }
Assert 'title: chore ok'           { Test-PrTitleConvention 'chore(deps): bump uv.lock' }
Assert 'title: bad-type rejected'  { -not (Test-PrTitleConvention 'update: something') }
Assert 'title: no-colon rejected'  { -not (Test-PrTitleConvention 'fix this thing') }
Assert 'title: no-space-after-colon rejected' { -not (Test-PrTitleConvention 'fix:nothing') }

Write-Host ''
if ($script:ran -eq 0) { Write-Host 'NO TESTS RAN' -ForegroundColor Red; exit 1 }
if ($script:fails) { Write-Host "$($script:fails)/$($script:ran) FAILED" -ForegroundColor Red; exit 1 } else { Write-Host "ALL $($script:ran) PASS" -ForegroundColor Green }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -NoProfile -File "C:\Users\John Patrick Mandal\scripts\samurai-e2e-guard.Tests.ps1"`
Expected: FAIL — `samurai-e2e-guard.ps1` doesn't exist yet, dot-source errors out (`The term ... is not recognized` or file-not-found).

- [ ] **Step 3: Write minimal implementation**

Create `C:\Users\John Patrick Mandal\scripts\samurai-e2e-guard.ps1`:

```powershell
# samurai-e2e-guard.ps1 — local pre-merge guard mirroring samurai_cart_v3's real CI checks
# (pr-checks.yml's pr-validation job + e2e-smoke.yml's e2e-smoke job), so a broken PR is
# caught before it burns GitHub Actions minutes. Derives an isolated per-ticket e2e database
# via samurai-testdb-lib.ps1 (same pattern as samurai-test.ps1) since this script seeds real
# state (admin user, tenant, product data) that would otherwise collide across worktrees.
# Runs its own backend (:8099) and frontend (:3099) on alternate ports so it never collides
# with an already-running local dev session on the default :8000/:3000-3001.
#
# Usage: samurai-e2e-guard [-Ticket V3-XXXX] [-PrTitle "fix(v3-xxx): ..."]
# Dot-source with -NoRun for tests.
param(
    [switch]$NoRun,
    [string]$Ticket,
    [string]$PrTitle
)

. "$PSScriptRoot\samurai-testdb-lib.ps1"

function Test-BranchNameConvention([string]$Branch) {
    return $Branch -match '^(feature|bugfix|hotfix|release|chore)/.+'
}

function Test-PrTitleConvention([string]$Title) {
    return $Title -match '^(feat|fix|docs|style|refactor|test|chore)(\(.+\))?: .+'
}

if (-not $NoRun) {
    # Main entrypoint lands in Task 4 — placeholder guard so a bare invocation before
    # this script is complete fails loudly instead of silently doing nothing.
    Write-Host 'samurai-e2e-guard: not yet fully implemented (Task 4 pending).' -ForegroundColor Yellow
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pwsh -NoProfile -File "C:\Users\John Patrick Mandal\scripts\samurai-e2e-guard.Tests.ps1"`
Expected: `ALL 12 PASS`

- [ ] **Step 5: Commit**

```bash
cd "C:\Users\John Patrick Mandal\scripts"
git add samurai-e2e-guard.ps1 samurai-e2e-guard.Tests.ps1
git commit -m "feat: add branch-name and PR-title convention checks to samurai-e2e-guard"
```

---

### Task 2: Isolated e2e database — migrate + seed

**Files:**
- Modify: `C:\Users\John Patrick Mandal\scripts\samurai-e2e-guard.ps1`

**Interfaces:**
- Consumes: `ConvertTo-TestDbSuffix`, `Test-TestDbExists`, `New-TestDb` from `samurai-testdb-lib.ps1` (dot-sourced in Task 1); `Get-TicketKeyFromFolderName`, `Get-TicketKeyFromBranch` from the same lib.
- Produces: `Resolve-TicketKey([string]$ExplicitKey, [string]$RepoRoot) -> string`, `Invoke-E2eDbSetup([string]$TicketKey, [string]$RepoRoot) -> string` (returns the DATABASE_URL used) — Task 3/4 consume the returned URL.

No new pure-logic branch here worth a dedicated Assert test beyond what `samurai-testdb-lib.Tests.ps1` already covers (`ConvertTo-TestDbSuffix` is already tested there) — this task is Docker/DB orchestration, verified by the manual dry run at the end of Task 4 per this repo's existing precedent (`samurai-test.ps1`'s own Docker-invoking logic has no automated test either, only its pure helpers do).

- [ ] **Step 1: Add `Resolve-TicketKey` and `Invoke-E2eDbSetup`**

Insert into `samurai-e2e-guard.ps1`, after the `Test-PrTitleConvention` function and before the `if (-not $NoRun)` block:

```powershell
function Resolve-TicketKey([string]$ExplicitKey, [string]$RepoRoot) {
    if ($ExplicitKey) { return $ExplicitKey }
    $folderKey = Get-TicketKeyFromFolderName (Split-Path -Leaf $RepoRoot)
    if ($folderKey) { return $folderKey }
    $branch = git -C $RepoRoot rev-parse --abbrev-ref HEAD 2>$null
    return (Get-TicketKeyFromBranch $branch)
}

function Invoke-E2eDbSetup([string]$TicketKey, [string]$RepoRoot) {
    $dbName = "samurai_cart_e2e_$(ConvertTo-TestDbSuffix $TicketKey)"

    if (-not (Test-TestDbExists $dbName)) {
        Write-Host "Creating e2e database $dbName ..." -ForegroundColor Cyan
        New-TestDb $dbName
    } else {
        Write-Host "Reusing existing e2e database $dbName ..." -ForegroundColor Cyan
    }

    $dbUrl = "postgresql+asyncpg://samurai:samurai_dev_password@db:5432/$dbName"

    Write-Host "Running migrations against $dbName ..." -ForegroundColor Cyan
    docker run --rm --network samurai_cart_network `
        -v "${RepoRoot}\backend:/app" `
        -e "DATABASE_URL=$dbUrl" `
        -e "SECRET_KEY=e2e-guard-secret-key" `
        -e "ENVIRONMENT=development" `
        -w /app `
        samurai_cart_v3-api:latest `
        alembic upgrade head
    if ($LASTEXITCODE -ne 0) { throw "alembic upgrade head failed against $dbName" }

    Write-Host "Seeding admin superuser + default tenant ..." -ForegroundColor Cyan
    docker run --rm --network samurai_cart_network `
        -v "${RepoRoot}\backend:/app" `
        -e "DATABASE_URL=$dbUrl" `
        -e "SECRET_KEY=e2e-guard-secret-key" `
        -e "ENVIRONMENT=development" `
        -w /app `
        samurai_cart_v3-api:latest `
        python scripts/admin/create_superuser.py
    if ($LASTEXITCODE -ne 0) { throw "create_superuser.py failed against $dbName" }

    docker run --rm --network samurai_cart_network `
        -v "${RepoRoot}\backend:/app" `
        -e "DATABASE_URL=$dbUrl" `
        -e "SECRET_KEY=e2e-guard-secret-key" `
        -e "ENVIRONMENT=development" `
        -w /app `
        samurai_cart_v3-api:latest `
        python scripts/admin/seed_default_tenant.py
    if ($LASTEXITCODE -ne 0) { throw "seed_default_tenant.py failed against $dbName" }

    return $dbUrl
}
```

**Note on idempotency:** `create_superuser.py` / `seed_default_tenant.py` are the exact same scripts CI runs fresh every time against an ephemeral DB — confirm during Task 4's manual dry run that re-running this guard a second time against an *already-seeded* e2e DB doesn't error (both scripts are expected to be safely re-runnable per how CI itself would behave if it ever re-ran against a warm DB; if either turns out NOT to be idempotent in practice, wrap the two `docker run` calls in a check against whether the DB already has a superuser row before calling them, using the same `Test-TestDbExists`-style guard pattern).

- [ ] **Step 2: Syntax-check**

Run: `pwsh -NoProfile -Command "& { . 'C:\Users\John Patrick Mandal\scripts\samurai-e2e-guard.ps1' -NoRun }"`
Expected: no parse errors, exits cleanly (the `-NoRun` guard prevents the placeholder Task-1 message path from mattering here — just confirms the file parses).

- [ ] **Step 3: Re-run Task 1's tests to confirm no regression**

Run: `pwsh -NoProfile -File "C:\Users\John Patrick Mandal\scripts\samurai-e2e-guard.Tests.ps1"`
Expected: `ALL 12 PASS` (unchanged — this task added new functions, didn't touch the tested ones)

- [ ] **Step 4: Commit**

```bash
cd "C:\Users\John Patrick Mandal\scripts"
git add samurai-e2e-guard.ps1
git commit -m "feat: add isolated e2e DB setup (migrate + seed) to samurai-e2e-guard"
```

---

### Task 3: Auth-bypass guard, production build, Playwright smoke run

**Files:**
- Modify: `C:\Users\John Patrick Mandal\scripts\samurai-e2e-guard.ps1`

**Interfaces:**
- Consumes: nothing new from earlier tasks directly (takes `$RepoRoot`, `$DbUrl`, `$TicketKey` as params).
- Produces: `Invoke-E2eSmokeRun([string]$RepoRoot, [string]$DbUrl, [string]$TicketKey) -> bool` — returns `$true` only on a full pass; **throws** (does not return `$false`) on any failure, so callers must wrap it in try/catch, not just check the return value. Task 4's main entrypoint does both (belt-and-suspenders).

Orchestration/integration code (docker + npm + playwright) — no Assert-harness unit test, verified via Task 4's manual dry run, matching this repo's existing precedent for non-pure-function script logic.

- [ ] **Step 1: Add `Invoke-E2eSmokeRun`**

Insert into `samurai-e2e-guard.ps1`, after `Invoke-E2eDbSetup`:

```powershell
function Invoke-E2eSmokeRun([string]$RepoRoot, [string]$DbUrl, [string]$TicketKey) {
    $suffix = ConvertTo-TestDbSuffix $TicketKey
    $containerName = "samurai_e2e_guard_api_$suffix"
    $backendPort = 8099
    $frontendPort = 3099
    $backendUrl = "http://localhost:$backendPort"

    # Clean up any stale container from a previous interrupted run before starting fresh.
    docker rm -f $containerName 2>$null | Out-Null

    Write-Host "Starting isolated backend on :$backendPort ..." -ForegroundColor Cyan
    docker run -d --rm --name $containerName `
        --network samurai_cart_network `
        -p "${backendPort}:8000" `
        -v "${RepoRoot}\backend:/app" `
        -e "DATABASE_URL=$DbUrl" `
        -e "SECRET_KEY=e2e-guard-secret-key" `
        -e "ENVIRONMENT=development" `
        -e "AUTH_DEV_BYPASS=true" `
        -w /app `
        samurai_cart_v3-api:latest `
        uvicorn app.main:app --host 0.0.0.0 --port 8000 | Out-Null

    try {
        $ready = $false
        for ($i = 1; $i -le 30; $i++) {
            try {
                $resp = Invoke-WebRequest -Uri "$backendUrl/health" -UseBasicParsing -TimeoutSec 2
                if ($resp.StatusCode -eq 200) { $ready = $true; break }
            } catch {}
            Write-Host "Waiting for backend ($i/30) ..." -ForegroundColor DarkGray
            Start-Sleep -Seconds 2
        }
        if (-not $ready) { throw "Backend did not respond on :$backendPort within 60s" }
        Write-Host "Backend ready on :$backendPort" -ForegroundColor Green

        Push-Location "$RepoRoot\frontend"
        try {
            Write-Host 'Running auth-bypass guard jest specs ...' -ForegroundColor Cyan
            npm test -- __tests__/dev-bypass.test.ts components/auth/__tests__ components/providers/__tests__
            if ($LASTEXITCODE -ne 0) { throw 'Auth-bypass guard jest specs failed' }

            Write-Host 'Building production frontend (E2E-armed) ...' -ForegroundColor Cyan
            $env:NEXT_PUBLIC_E2E_AUTH_BYPASS = 'true'
            $env:BACKEND_URL = $backendUrl
            npm run build
            $buildExit = $LASTEXITCODE
            Remove-Item Env:\NEXT_PUBLIC_E2E_AUTH_BYPASS -ErrorAction SilentlyContinue
            Remove-Item Env:\BACKEND_URL -ErrorAction SilentlyContinue
            if ($buildExit -ne 0) { throw 'Production frontend build failed' }

            Write-Host "Starting production frontend on :$frontendPort ..." -ForegroundColor Cyan
            $frontendProc = Start-Process -FilePath 'npx' -ArgumentList 'next', 'start', '-p', $frontendPort `
                -PassThru -WindowStyle Hidden

            try {
                $feReady = $false
                for ($i = 1; $i -le 30; $i++) {
                    try {
                        $resp = Invoke-WebRequest -Uri "http://localhost:$frontendPort" -UseBasicParsing -TimeoutSec 2
                        if ($resp.StatusCode -eq 200) { $feReady = $true; break }
                    } catch {}
                    Write-Host "Waiting for frontend ($i/30) ..." -ForegroundColor DarkGray
                    Start-Sleep -Seconds 2
                }
                if (-not $feReady) { throw "Frontend did not respond on :$frontendPort within 60s" }
                Write-Host "Frontend ready on :$frontendPort" -ForegroundColor Green

                Write-Host 'Running Playwright @smoke suite ...' -ForegroundColor Cyan
                $env:CI = 'true'
                $env:E2E_ADMIN_EMAIL = 'admin@samurai-cart.com'
                $env:E2E_ADMIN_PASSWORD = 'admin123'
                $env:PLAYWRIGHT_BASE_URL = "http://localhost:$frontendPort"
                npx playwright test --grep '@smoke' --pass-with-no-tests
                $smokeExit = $LASTEXITCODE
                Remove-Item Env:\CI, Env:\E2E_ADMIN_EMAIL, Env:\E2E_ADMIN_PASSWORD, Env:\PLAYWRIGHT_BASE_URL -ErrorAction SilentlyContinue
                if ($smokeExit -ne 0) { throw 'Playwright @smoke suite failed' }

                return $true
            } finally {
                if ($frontendProc -and -not $frontendProc.HasExited) {
                    Stop-Process -Id $frontendProc.Id -Force -ErrorAction SilentlyContinue
                }
            }
        } finally {
            Pop-Location
        }
    } finally {
        Write-Host 'Stopping isolated backend ...' -ForegroundColor DarkGray
        docker stop $containerName 2>$null | Out-Null
    }
}
```

**Note on `PLAYWRIGHT_BASE_URL`:** confirm during Task 4's manual dry run that `frontend/playwright.config.ts` actually honors this env var for its `baseURL` (CI relies on `next start`'s default port matching whatever the config hardcodes or reads); if the config hardcodes a different port/env var name, adjust this step to match rather than silently running smoke tests against the wrong origin.

- [ ] **Step 2: Syntax-check**

Run: `pwsh -NoProfile -Command "& { . 'C:\Users\John Patrick Mandal\scripts\samurai-e2e-guard.ps1' -NoRun }"`
Expected: no parse errors.

- [ ] **Step 3: Re-run Task 1's tests to confirm no regression**

Run: `pwsh -NoProfile -File "C:\Users\John Patrick Mandal\scripts\samurai-e2e-guard.Tests.ps1"`
Expected: `ALL 12 PASS`

- [ ] **Step 4: Commit**

```bash
cd "C:\Users\John Patrick Mandal\scripts"
git add samurai-e2e-guard.ps1
git commit -m "feat: add jest guard + production build + Playwright smoke run to samurai-e2e-guard"
```

---

### Task 4: Main entrypoint — wire it all together

**Files:**
- Modify: `C:\Users\John Patrick Mandal\scripts\samurai-e2e-guard.ps1`

**Interfaces:**
- Consumes: `Test-BranchNameConvention`, `Test-PrTitleConvention` (Task 1), `Resolve-TicketKey`, `Invoke-E2eDbSetup` (Task 2), `Invoke-E2eSmokeRun` (Task 3).
- Produces: the script's actual CLI behavior — exit code 0 on full pass, non-zero on any failure, used by Task 6's `/open-pr` wiring.

- [ ] **Step 1: Replace the Task-1 placeholder with the real entrypoint**

In `samurai-e2e-guard.ps1`, replace:

```powershell
if (-not $NoRun) {
    # Main entrypoint lands in Task 4 — placeholder guard so a bare invocation before
    # this script is complete fails loudly instead of silently doing nothing.
    Write-Host 'samurai-e2e-guard: not yet fully implemented (Task 4 pending).' -ForegroundColor Yellow
}
```

with:

```powershell
function Invoke-SamuraiE2eGuard([string]$Key, [string]$Title) {
    $repoRoot = (git rev-parse --show-toplevel 2>$null) -replace '/', '\'
    if (-not $repoRoot) {
        Write-Host 'Not inside a git repository.' -ForegroundColor Red
        return 1
    }

    $ticketKey = Resolve-TicketKey -ExplicitKey $Key -RepoRoot $repoRoot
    if (-not $ticketKey) {
        Write-Host "Could not determine a ticket key from '$repoRoot' or its branch. Pass -Ticket V3-XXXX explicitly." -ForegroundColor Red
        return 1
    }

    $branch = git -C $repoRoot rev-parse --abbrev-ref HEAD

    Write-Host "=== samurai-e2e-guard: $ticketKey ($branch) ===" -ForegroundColor Cyan
    Write-Host ''

    # Cheap checks first — fail fast before spending minutes on the heavy sequence.
    Write-Host '--- pr-validation (branch/title format) ---' -ForegroundColor Cyan
    $branchOk = Test-BranchNameConvention $branch
    if (-not $branchOk) {
        Write-Host "FAIL: branch '$branch' does not match ^(feature|bugfix|hotfix|release|chore)/.+" -ForegroundColor Red
    } else {
        Write-Host "PASS: branch name convention" -ForegroundColor Green
    }

    $titleOk = $true
    if ($Title) {
        $titleOk = Test-PrTitleConvention $Title
        if (-not $titleOk) {
            Write-Host "FAIL: PR title '$Title' does not match ^(feat|fix|docs|style|refactor|test|chore)(\(.+\))?: .+" -ForegroundColor Red
        } else {
            Write-Host "PASS: PR title convention" -ForegroundColor Green
        }
    } else {
        Write-Host "SKIPPED: PR title convention (-PrTitle not passed — check again once a title exists)" -ForegroundColor Yellow
    }

    if (-not $branchOk -or -not $titleOk) {
        Write-Host ''
        Write-Host 'GUARD FAILED at pr-validation — fix the above before continuing.' -ForegroundColor Red
        return 1
    }

    Write-Host ''
    Write-Host '--- e2e-smoke (migrate, seed, build, Playwright @smoke) ---' -ForegroundColor Cyan
    try {
        $dbUrl = Invoke-E2eDbSetup -TicketKey $ticketKey -RepoRoot $repoRoot
        $smokePass = Invoke-E2eSmokeRun -RepoRoot $repoRoot -DbUrl $dbUrl -TicketKey $ticketKey
    } catch {
        Write-Host ''
        Write-Host "GUARD FAILED at e2e-smoke: $($_.Exception.Message)" -ForegroundColor Red
        return 1
    }

    if (-not $smokePass) {
        Write-Host ''
        Write-Host 'GUARD FAILED at e2e-smoke.' -ForegroundColor Red
        return 1
    }

    Write-Host ''
    Write-Host "ALL CHECKS PASS for $ticketKey — safe to open the PR." -ForegroundColor Green
    return 0
}

if (-not $NoRun) {
    $exitCode = Invoke-SamuraiE2eGuard -Key $Ticket -Title $PrTitle
    exit $exitCode
}
```

- [ ] **Step 2: Re-run Task 1's tests to confirm no regression**

Run: `pwsh -NoProfile -File "C:\Users\John Patrick Mandal\scripts\samurai-e2e-guard.Tests.ps1"`
Expected: `ALL 12 PASS` (the `-NoRun` guard means `Invoke-SamuraiE2eGuard` never actually runs during the test file's dot-source)

- [ ] **Step 3: Manual dry run against a real (throwaway) ticket branch**

From inside a worktree on a real feature/bugfix branch:

Run: `pwsh -NoProfile -File "C:\Users\John Patrick Mandal\scripts\samurai-e2e-guard.ps1" -PrTitle "fix(V3-XXXX): test run"`

Expected: prints the branch/title checks passing, creates/reuses `samurai_cart_e2e_v3_xxxx`, runs migrations, seeds admin+tenant, starts a backend container on :8099, runs the jest auth-bypass specs, builds the frontend, starts it on :3099, runs the Playwright `@smoke` suite, tears down the temp backend/frontend, and prints `ALL CHECKS PASS`. Confirm exit code is `0` (`echo $LASTEXITCODE` after it finishes).

Confirm the standing local dev session (`samurai_cart_api` on :8000, dev frontend) was **not** disrupted — it should still be reachable throughout.

- [ ] **Step 4: Manual dry run of a deliberate failure**

Temporarily rename `frontend/__tests__/dev-bypass.test.ts` (or break one assertion in it), re-run the same command, confirm the guard stops with `GUARD FAILED at e2e-smoke` and a non-zero exit code, and that it still tears down the temp backend container (no orphaned `samurai_e2e_guard_api_*` container left running — check with `docker ps`). Revert the temporary change afterward.

- [ ] **Step 5: Commit**

```bash
cd "C:\Users\John Patrick Mandal\scripts"
git add samurai-e2e-guard.ps1
git commit -m "feat: wire samurai-e2e-guard's main entrypoint together"
```

---

### Task 5: Wire `samurai-test` into `/ship-ticket`'s TDD loop

**Files:**
- Modify: `C:\Users\John Patrick Mandal\.claude\commands\ship-ticket.md`

**Interfaces:** none (markdown prompt-file edit, no code interfaces).

- [ ] **Step 1: Add a References entry for `samurai-test`**

In `ship-ticket.md`'s `## References` section, add a new bullet immediately after the existing `**TDD discipline (mandatory...)**` line:

```markdown
- **Test runner (backend only):** `~/scripts/samurai-test.ps1`, exposed as `samurai-test`. Derives an isolated per-ticket test database from the current worktree/branch (`samurai_cart_test_{key}`) so concurrent test runs from different worktrees never race on a shared schema. Every backend test invocation in this command's TDD loop MUST go through it — never bare `pytest` — per `2026-07-21-multi-agent-workflow-design.md`. If `samurai-test` isn't reachable (e.g. a non-interactive execution context without PowerShell), fall back to plain `pytest` and say so explicitly in the hand-off; never silently swap without flagging it.
```

- [ ] **Step 2: Update the RED step**

Find this line in the "Execute the plan" section's numbered TDD list:

```markdown
1. **RED:** Write the failing test(s) specified in the subtask's `Test first:` field. Run them. **Confirm they fail** with the expected assertion error (not an import error, not a setup error — the test must fail for the right reason). If the test passes immediately, the test isn't actually exercising the new behavior; rewrite it before continuing.
```

Replace with:

```markdown
1. **RED:** Write the failing test(s) specified in the subtask's `Test first:` field. Run them via `samurai-test -Ticket {KEY} <path/to/test.py>` (backend) — never bare `pytest` during this loop. **Confirm they fail** with the expected assertion error (not an import error, not a setup error — the test must fail for the right reason). If the test passes immediately, the test isn't actually exercising the new behavior; rewrite it before continuing.
```

- [ ] **Step 3: Update the REFACTOR step**

Find:

```markdown
3. **REFACTOR (optional):** If the subtask has a `Refactor (optional):` field, perform that refactor now. Re-run all tests. **All tests must stay green during and after refactor.** If any test breaks, the refactor changed behavior — revert and rethink.
```

Replace with:

```markdown
3. **REFACTOR (optional):** If the subtask has a `Refactor (optional):` field, perform that refactor now. Re-run all tests via `samurai-test -Ticket {KEY}`. **All tests must stay green during and after refactor.** If any test breaks, the refactor changed behavior — revert and rethink.
```

- [ ] **Step 4: Update step 3.4's "Tests pass" sanity check**

Find (in "Post-implementation sanity checks"):

```markdown
4. **Tests pass:** verify by checking the most recent test invocation captured during plan execution (§2). If you can't confidently confirm (or no test ran in the plan), ASK the user: "Did the last full test run pass? (yes/no/skip)". On `no`, stop and let them fix. On `skip`, proceed but note in the hand-off message that tests weren't verified.
```

Replace with:

```markdown
4. **Tests pass:** verify by checking the most recent `samurai-test -Ticket {KEY}` invocation captured during plan execution (§2) — not a bare `pytest` run, which wouldn't have used the isolated DB. If you can't confidently confirm (or no test ran in the plan), ASK the user: "Did the last full test run pass? (yes/no/skip)". On `no`, stop and let them fix. On `skip`, proceed but note in the hand-off message that tests weren't verified.
```

- [ ] **Step 5: Verify the edits**

Run: `grep -n "samurai-test" "C:\Users\John Patrick Mandal\.claude\commands\ship-ticket.md"`
Expected: 4 matches — the References entry, the RED step, the REFACTOR step, and step 3.4.

- [ ] **Step 6: Commit**

`~/.claude/commands` is not a git repository (confirmed — no version control there), so there is no commit step for this task. Skip directly to Task 6.

---

### Task 6: Wire `samurai-e2e-guard` into `/open-pr` as step 1b

**Files:**
- Modify: `C:\Users\John Patrick Mandal\.claude\commands\open-pr.md`

**Interfaces:** none (markdown prompt-file edit).

- [ ] **Step 1: Insert the new step 1b**

In `open-pr.md`'s `## Workflow` section, immediately after step `### 1. Resolve KEY and validate` and before `### 2. Offer a Manual Test Plan (opt-in)`, insert:

```markdown
### 1b. Pre-merge guard (mirrors CI)

Before drafting anything, run the local guard that mirrors `samurai_cart_v3`'s real CI checks (`pr-checks.yml`'s `pr-validation` job + `e2e-smoke.yml`'s `e2e-smoke` job) — no point drafting a PR body for something that's about to fail CI:

```powershell
samurai-e2e-guard -Ticket {KEY} -PrTitle "{draft PR title, once you have one — see step 3}"
```

Since a title doesn't exist yet at this point in the flow, run it once here **without** `-PrTitle` (branch-name check only; title check reports `SKIPPED`), then re-run **with** `-PrTitle` right after step 3 drafts the title, before step 5 actually opens the PR.

**On failure:** stop. Report exactly which check failed (branch name, PR title, or the specific e2e-smoke step) and the guard's own output. Do not proceed to step 2. The user fixes the underlying issue and re-runs this step — never silently skip it or proceed anyway.

**On success:** continue to step 2.
```

- [ ] **Step 2: Add a second guard checkpoint after the title is drafted**

In step `### 3. Draft the PR body`, at the very end of that section (after the PR body template, before `### 4. User checkpoint`), add:

```markdown
**Re-run the pre-merge guard now that a title exists** (step 1b was run title-less before this step):

```powershell
samurai-e2e-guard -Ticket {KEY} -PrTitle "{the title just drafted above}"
```

This re-run reuses the already-seeded e2e database (fast — no re-migration needed unless schema changed since step 1b's run) and re-checks the title specifically. On failure, stop and fix before continuing to step 4.
```

- [ ] **Step 3: Verify the edits**

Run: `grep -n "samurai-e2e-guard\|1b. Pre-merge guard" "C:\Users\John Patrick Mandal\.claude\commands\open-pr.md"`
Expected: at least 4 matches (the step 1b heading, the two `samurai-e2e-guard` invocations, and the re-run note).

- [ ] **Step 4: Read through both edited sections once more for coherence**

Confirm step numbering still reads correctly (1 → 1b → 2 → 3 → [guard re-run] → 4 → 5 → ...) and that nothing above step 1b references a PR body/title that wouldn't exist yet.

No commit step — `~/.claude/commands` is not version-controlled (same as Task 5).

**Honest scope note:** Steps 3–4 above are the mechanizable checks (grep + read-through) for a prompt-file edit — there's no shell command that "runs" `/open-pr` the way Task 4 could shell out to `samurai-e2e-guard.ps1` directly. Full behavioral confirmation (does step 1b actually block PR drafting on a guard failure, does the re-run after step 3 work) only happens the first time `/open-pr` is genuinely invoked for a real ticket. Flag this to the user rather than claiming it's fully verified before that happens.
