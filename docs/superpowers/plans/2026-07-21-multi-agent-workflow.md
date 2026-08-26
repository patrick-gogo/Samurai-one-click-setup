# Multi-agent dev workflow isolation — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make every `samurai_cart_v3` ticket start in its own git worktree by default, and give backend `pytest` runs a per-worktree isolated Postgres database, so concurrent Claude Code sessions on different tickets stop colliding on branches and on the shared `samurai_cart_test` schema.

**Architecture:** Two independent personal-tooling changes sharing one naming convention (`{KEY}` from the ticket branch `{prefix}/{KEY}-{slug}`). (1) `~/.claude/commands/start-ticket.md` — a user-level Claude Code command, not part of the `samurai_cart_v3` repo — switches its branch-creation step from `git checkout -b` in place to `git worktree add` at `Desktop\wt-{KEY}-{slug}`. (2) Two new PowerShell scripts in `~/scripts` (its own separate git repo) derive a per-ticket test database name (`samurai_cart_test_{key}`) and wrap `pytest`/cleanup around it, without touching `backend/tests/conftest.py` or CI.

**Tech Stack:** Markdown (Claude Code command file), PowerShell 7 (`pwsh`), git worktrees, Docker (`samurai_cart_v3-api:latest` image, `samurai_cart_db` container), PostgreSQL 16.

## Global Constraints

- **Nothing here touches the `samurai_cart_v3` repo.** `backend/tests/conftest.py` and CI stay exactly as they are — confirmed during design that `_ensure_test_db_exists()` there is hardcoded to the literal `samurai_cart_test` name, so nothing needs to change or could accidentally regress there.
- **Commit only when the user explicitly confirms**, task by task — do not auto-commit through the whole plan unattended (standing preference, applies here same as in `samurai_cart_v3`).
- **No AI attribution in commit messages** — plain, direct messages, no "Generated with Claude" / co-author lines.
- **PowerShell scripts follow the existing `~/scripts` convention** established by `samurai-dash.ps1`/`samurai-dash.Tests.ps1`: a `param([switch]$NoRun, ...)` header, all logic as functions, a single guarded entry-point call (`if (-not $NoRun) { ... }`) at the bottom, and a dependency-free `Assert`-based test harness (not Pester) that dot-sources the script and tests only pure functions — side-effecting functions that shell out to `git`/`docker` are validated manually, matching how `Get-RepoInfo`/`Get-DockerInfo` are handled today.
- **Worktree naming:** `C:\Users\John Patrick Mandal\Desktop\wt-{KEY}-{slug}`, mirroring branch `{prefix}/{KEY}-{slug}` with the prefix dropped.
- **Test DB naming:** `samurai_cart_test_{key}`, where `{key}` is the ticket key lowercased with `-` replaced by `_` (e.g. `V3-1193` → `v3_1193`).
- **DB container:** `samurai_cart_db` (user `samurai` / password `samurai_dev_password`, per `docker-compose.yml`). **API image:** `samurai_cart_v3-api:latest`. **Network:** `samurai_cart_network`.

---

## File Structure

| File | Repo | Responsibility |
|---|---|---|
| `~/scripts/samurai-testdb-lib.ps1` | `~/scripts` | Pure helpers: ticket-key ↔ DB-name derivation, DB existence/create/drop against `samurai_cart_db`. Dot-sourced by both scripts below. |
| `~/scripts/samurai-testdb-lib.Tests.ps1` | `~/scripts` | Assert-based unit tests for the pure functions in the lib. |
| `~/scripts/samurai-test.ps1` | `~/scripts` | CLI entry point: resolve ticket key from cwd, ensure its test DB exists, run `pytest` inside the api image against it. |
| `~/scripts/samurai-cleanup-ticket.ps1` | `~/scripts` | CLI entry point: remove a ticket's worktree and drop its test DB together. |
| `C:\Users\John Patrick Mandal\Documents\PowerShell\profile.ps1` | n/a (PowerShell profile) | Wires `samurai-test` / `samurai-cleanup-ticket` as callable functions, same pattern as existing `samurai` / `dash`. |
| `~/.claude/commands/start-ticket.md` | `~/.claude` | Steps 6/7/11 + References + Safety bullets updated to create a worktree instead of branching in place. |

---

## Task 1: Shared test-DB helper library

**Files:**
- Create: `C:\Users\John Patrick Mandal\scripts\samurai-testdb-lib.ps1`
- Create: `C:\Users\John Patrick Mandal\scripts\samurai-testdb-lib.Tests.ps1`

**Interfaces:**
- Consumes: nothing (leaf module).
- Produces (used by Tasks 2 and 3): `ConvertTo-TestDbSuffix([string]$Key) -> [string]`, `Get-TicketKeyFromFolderName([string]$FolderName) -> [string]|$null`, `Get-TicketKeyFromBranch([string]$Branch) -> [string]|$null`, `Test-TestDbExists([string]$DbName) -> [bool]`, `New-TestDb([string]$DbName) -> void`, `Remove-TestDb([string]$DbName) -> void`.

- [ ] **Step 1: Create the empty lib file (header only, no functions yet)**

```powershell
# samurai-testdb-lib.ps1 — shared helpers for deriving a per-ticket isolated Postgres test
# database name, and for talking to the samurai_cart_db container. Dot-sourced by
# samurai-test.ps1 and samurai-cleanup-ticket.ps1 — no side effects on load.
```

Save as `C:\Users\John Patrick Mandal\scripts\samurai-testdb-lib.ps1`.

- [ ] **Step 2: Write the failing tests**

Create `C:\Users\John Patrick Mandal\scripts\samurai-testdb-lib.Tests.ps1`:

```powershell
# Dependency-free tests. Run: pwsh -NoProfile -File samurai-testdb-lib.Tests.ps1
. "$PSScriptRoot\samurai-testdb-lib.ps1"

$script:fails = 0
$script:ran = 0
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

# --- ConvertTo-TestDbSuffix ---
Assert 'suffix: uppercase key'    { (ConvertTo-TestDbSuffix 'V3-1193') -eq 'v3_1193' }
Assert 'suffix: lowercase input'  { (ConvertTo-TestDbSuffix 'v3-1193') -eq 'v3_1193' }
Assert 'suffix: invalid key throws' {
    try { ConvertTo-TestDbSuffix 'not-a-key'; $false } catch { $true }
}

# --- Get-TicketKeyFromFolderName ---
Assert 'folder: wt- prefix match'  { (Get-TicketKeyFromFolderName 'wt-V3-1193-category-duplicate-name-guard') -eq 'V3-1193' }
Assert 'folder: no match -> null'  { $null -eq (Get-TicketKeyFromFolderName 'samurai_cart_v3') }

# --- Get-TicketKeyFromBranch ---
Assert 'branch: bugfix prefix'     { (Get-TicketKeyFromBranch 'bugfix/V3-1193-category-duplicate-name-guard') -eq 'V3-1193' }
Assert 'branch: feature prefix'    { (Get-TicketKeyFromBranch 'feature/V3-295-newsletter-guard') -eq 'V3-295' }
Assert 'branch: master -> null'    { $null -eq (Get-TicketKeyFromBranch 'master') }

Write-Host ''
if ($script:ran -eq 0) { Write-Host 'NO TESTS RAN' -ForegroundColor Red; exit 1 }
if ($script:fails) { Write-Host "$($script:fails)/$($script:ran) FAILED" -ForegroundColor Red; exit 1 } else { Write-Host "ALL $($script:ran) PASS" -ForegroundColor Green }
```

- [ ] **Step 3: Run the tests and verify they fail**

Run: `pwsh -NoProfile -File "C:\Users\John Patrick Mandal\scripts\samurai-testdb-lib.Tests.ps1"`
Expected: errors like `The term 'ConvertTo-TestDbSuffix' is not recognized...` — the functions don't exist yet in the lib file from Step 1.

- [ ] **Step 4: Implement the functions**

Replace the contents of `C:\Users\John Patrick Mandal\scripts\samurai-testdb-lib.ps1` with:

```powershell
# samurai-testdb-lib.ps1 — shared helpers for deriving a per-ticket isolated Postgres test
# database name, and for talking to the samurai_cart_db container. Dot-sourced by
# samurai-test.ps1 and samurai-cleanup-ticket.ps1 — no side effects on load.

function ConvertTo-TestDbSuffix([string]$Key) {
    if ($Key -notmatch '^[A-Za-z][A-Za-z0-9]*-\d+$') {
        throw "'$Key' is not a valid ticket key (expected e.g. V3-1193)"
    }
    return ($Key.ToLower() -replace '-', '_')
}

function Get-TicketKeyFromFolderName([string]$FolderName) {
    if ($FolderName -match '^wt-([A-Za-z][A-Za-z0-9]*-\d+)-') { return $Matches[1] }
    return $null
}

function Get-TicketKeyFromBranch([string]$Branch) {
    if ($Branch -match '^(?:feature|fix|bugfix|chore)/([A-Za-z][A-Za-z0-9]*-\d+)-') { return $Matches[1] }
    return $null
}

function Test-TestDbExists([string]$DbName) {
    $result = docker exec samurai_cart_db psql -U samurai -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname='$DbName'" 2>$null
    return (($result | Out-String).Trim() -eq '1')
}

function New-TestDb([string]$DbName) {
    docker exec samurai_cart_db psql -U samurai -d postgres -c "CREATE DATABASE $DbName OWNER samurai" 2>$null | Out-Null
}

function Remove-TestDb([string]$DbName) {
    docker exec samurai_cart_db psql -U samurai -d postgres -c "DROP DATABASE IF EXISTS $DbName WITH (FORCE)" 2>$null | Out-Null
}
```

- [ ] **Step 5: Run the tests and verify they pass**

Run: `pwsh -NoProfile -File "C:\Users\John Patrick Mandal\scripts\samurai-testdb-lib.Tests.ps1"`
Expected: `ALL 7 PASS`

- [ ] **Step 6: Commit**

```bash
cd "C:\Users\John Patrick Mandal\scripts"
git add samurai-testdb-lib.ps1 samurai-testdb-lib.Tests.ps1
git commit -m "Add per-ticket test-DB name derivation helpers"
```

---

## Task 2: `samurai-test.ps1` — per-worktree isolated pytest runner

**Files:**
- Create: `C:\Users\John Patrick Mandal\scripts\samurai-test.ps1`
- Modify: `C:\Users\John Patrick Mandal\Documents\PowerShell\profile.ps1` (deferred to Task 4 — not touched here)

**Interfaces:**
- Consumes (from Task 1): `ConvertTo-TestDbSuffix`, `Get-TicketKeyFromFolderName`, `Get-TicketKeyFromBranch`, `Test-TestDbExists`, `New-TestDb`.
- Produces: `samurai-test.ps1` callable as `pwsh -File samurai-test.ps1 [-Key V3-XXXX] [pytest args...]`; internally defines `Resolve-TicketKey([string]$ExplicitKey, [string]$RepoRoot) -> [string]|$null` and `Invoke-SamuraiTest([string]$Key, [string[]]$PytestArgs) -> void`.

No new pure functions beyond Task 1's lib — `Resolve-TicketKey` and `Invoke-SamuraiTest` both shell out to `git`/`docker`, so per the Global Constraints they're validated manually (Step 3 below), not with `Assert` tests, matching how `samurai-dash.ps1`'s own git/docker-calling functions are handled.

- [ ] **Step 1: Write the script**

Create `C:\Users\John Patrick Mandal\scripts\samurai-test.ps1`:

```powershell
# samurai-test.ps1 — run backend pytest against a per-ticket isolated test database.
# Derives the ticket key from the current worktree folder (wt-{KEY}-{slug}) or branch name,
# ensures samurai_cart_test_{key} exists, and runs pytest inside the shared api image with
# TEST_DATABASE_URL pointed at it — so concurrent test runs from different worktrees never
# race on the same schema. Dot-source with -NoRun for tests.
param(
    [string]$Key,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$PytestArgs,
    [switch]$NoRun
)

. "$PSScriptRoot\samurai-testdb-lib.ps1"

function Resolve-TicketKey([string]$ExplicitKey, [string]$RepoRoot) {
    if ($ExplicitKey) { return $ExplicitKey }
    $folderKey = Get-TicketKeyFromFolderName (Split-Path -Leaf $RepoRoot)
    if ($folderKey) { return $folderKey }
    $branch = git -C $RepoRoot rev-parse --abbrev-ref HEAD 2>$null
    return (Get-TicketKeyFromBranch $branch)
}

function Invoke-SamuraiTest {
    param([string]$Key, [string[]]$PytestArgs)

    $repoRoot = (git rev-parse --show-toplevel 2>$null) -replace '/', '\'
    if (-not $repoRoot) {
        Write-Host 'Not inside a git repository.' -ForegroundColor Red
        return
    }

    $ticketKey = Resolve-TicketKey -ExplicitKey $Key -RepoRoot $repoRoot
    if (-not $ticketKey) {
        Write-Host "Could not determine a ticket key from '$repoRoot' or its branch. Pass -Key V3-XXXX explicitly." -ForegroundColor Red
        return
    }

    $dbName = "samurai_cart_test_$(ConvertTo-TestDbSuffix $ticketKey)"

    if (-not (Test-TestDbExists $dbName)) {
        Write-Host "Creating test database $dbName ..." -ForegroundColor Cyan
        New-TestDb $dbName
    }

    $testDbUrl = "postgresql+asyncpg://samurai:samurai_dev_password@db:5432/$dbName"
    Write-Host "Running tests for $ticketKey against $dbName ..." -ForegroundColor Cyan

    docker run --rm --network samurai_cart_network `
        -v "${repoRoot}\backend:/app" `
        -e "TEST_DATABASE_URL=$testDbUrl" `
        -w /app `
        samurai_cart_v3-api:latest `
        pytest @PytestArgs
}

if (-not $NoRun) { Invoke-SamuraiTest -Key $Key -PytestArgs $PytestArgs }
```

- [ ] **Step 2: Sanity-check the script loads without errors**

Run: `pwsh -NoProfile -Command ". 'C:\Users\John Patrick Mandal\scripts\samurai-test.ps1' -NoRun; Get-Command Invoke-SamuraiTest, Resolve-TicketKey"`
Expected: both functions listed, no errors (confirms the `-NoRun` guard and dot-sourcing work before touching real worktrees/Docker).

- [ ] **Step 3: Manual validation against a real worktree**

Requires `docker compose up -d` already running in `samurai_cart_v3` (the shared `db` container must be up). From inside any existing worktree, e.g. `C:\Users\John Patrick Mandal\Desktop\wt-V3-1149` (adjust to whatever worktree currently exists):

```powershell
cd "C:\Users\John Patrick Mandal\Desktop\wt-V3-1149"
pwsh -NoProfile -File "C:\Users\John Patrick Mandal\scripts\samurai-test.ps1" tests/integration/test_regular_buy_list.py -v
```

Expected: console shows `Creating test database samurai_cart_test_v3_1149 ...` (first run only) then `Running tests for V3-1149 against samurai_cart_test_v3_1149 ...`, then pytest's normal output. Verify the DB actually exists afterward:

```powershell
docker exec samurai_cart_db psql -U samurai -d postgres -c "\l" | Select-String "samurai_cart_test_v3_1149"
```

Expected: one matching row.

- [ ] **Step 4: Commit**

```bash
cd "C:\Users\John Patrick Mandal\scripts"
git add samurai-test.ps1
git commit -m "Add samurai-test.ps1 for per-worktree isolated pytest runs"
```

---

## Task 3: `samurai-cleanup-ticket.ps1` — combined worktree + test-DB cleanup

**Files:**
- Create: `C:\Users\John Patrick Mandal\scripts\samurai-cleanup-ticket.ps1`

**Interfaces:**
- Consumes (from Task 1): `ConvertTo-TestDbSuffix`, `Remove-TestDb`.
- Produces: `samurai-cleanup-ticket.ps1` callable as `pwsh -File samurai-cleanup-ticket.ps1 -Key V3-XXXX`; internally defines `Find-TicketWorktree([string]$Key, [string]$BaseDir) -> [string]|$null` and `Invoke-SamuraiCleanupTicket([string]$Key) -> void`.

Same rationale as Task 2: `Find-TicketWorktree` and `Invoke-SamuraiCleanupTicket` shell out to the filesystem/`git`, so they're validated manually (Step 3), not with `Assert` tests.

- [ ] **Step 1: Write the script**

Create `C:\Users\John Patrick Mandal\scripts\samurai-cleanup-ticket.ps1`:

```powershell
# samurai-cleanup-ticket.ps1 — remove a finished ticket's worktree AND its isolated test DB
# in one step. Manual/opt-in — run whenever you've decided a ticket is really done (typically
# after /wrap-ticket has already flipped the vault status; /wrap-ticket itself never touches
# branches or worktrees). Dot-source with -NoRun for tests.
param(
    [Parameter(Mandatory = $true)]
    [string]$Key,
    [switch]$NoRun
)

. "$PSScriptRoot\samurai-testdb-lib.ps1"

$script:Desktop = 'C:\Users\John Patrick Mandal\Desktop'
$script:MainRepo = 'C:\Users\John Patrick Mandal\Desktop\samurai_cart_v3'

function Find-TicketWorktree([string]$Key, [string]$BaseDir) {
    $found = @(Get-ChildItem -Path $BaseDir -Directory -Filter "wt-$Key-*" -ErrorAction SilentlyContinue)
    if ($found.Count -eq 0) { return $null }
    if ($found.Count -gt 1) { throw "Multiple worktrees match wt-$Key-*: $($found.FullName -join ', ')" }
    return $found[0].FullName
}

function Invoke-SamuraiCleanupTicket {
    param([string]$Key)

    if ($Key -notmatch '^[A-Za-z][A-Za-z0-9]*-\d+$') {
        Write-Host "'$Key' is not a valid ticket key (expected e.g. V3-1193)." -ForegroundColor Red
        return
    }

    $worktreePath = Find-TicketWorktree -Key $Key -BaseDir $script:Desktop
    if (-not $worktreePath) {
        Write-Host "No worktree found matching wt-$Key-* under $script:Desktop." -ForegroundColor Yellow
    } else {
        Write-Host "Removing worktree $worktreePath ..." -ForegroundColor Cyan
        git -C $script:MainRepo worktree remove $worktreePath
        if ($LASTEXITCODE -ne 0) {
            Write-Host 'git worktree remove failed -- worktree left in place. Resolve manually (e.g. commit/stash changes) and re-run.' -ForegroundColor Red
            return
        }
        Write-Host 'Worktree removed.' -ForegroundColor Green
    }

    $dbName = "samurai_cart_test_$(ConvertTo-TestDbSuffix $Key)"
    Write-Host "Dropping test database $dbName (if present) ..." -ForegroundColor Cyan
    Remove-TestDb $dbName
    Write-Host 'Done.' -ForegroundColor Green
}

if (-not $NoRun) { Invoke-SamuraiCleanupTicket -Key $Key }
```

- [ ] **Step 2: Sanity-check the script loads without errors**

Run: `pwsh -NoProfile -Command ". 'C:\Users\John Patrick Mandal\scripts\samurai-cleanup-ticket.ps1' -Key X -NoRun; Get-Command Invoke-SamuraiCleanupTicket, Find-TicketWorktree"`
Expected: both functions listed, no errors.

- [ ] **Step 3: Manual validation against a throwaway worktree**

Create a disposable worktree and DB to prove cleanup actually removes both:

```powershell
git -C "C:\Users\John Patrick Mandal\Desktop\samurai_cart_v3" -c core.longpaths=true worktree add -b chore/V3-9999-cleanup-test "C:\Users\John Patrick Mandal\Desktop\wt-V3-9999-cleanup-test" master
docker exec samurai_cart_db psql -U samurai -d postgres -c "CREATE DATABASE samurai_cart_test_v3_9999 OWNER samurai"

pwsh -NoProfile -File "C:\Users\John Patrick Mandal\scripts\samurai-cleanup-ticket.ps1" -Key V3-9999
```

Expected output: `Removing worktree ...` → `Worktree removed.` → `Dropping test database samurai_cart_test_v3_9999 ...` → `Done.`

Verify both are actually gone:

```powershell
Test-Path "C:\Users\John Patrick Mandal\Desktop\wt-V3-9999-cleanup-test"    # expect: False
docker exec samurai_cart_db psql -U samurai -d postgres -c "\l" | Select-String "samurai_cart_test_v3_9999"   # expect: no output
```

Clean up the throwaway branch too (cleanup script deliberately doesn't delete branches, same as `/wrap-ticket`):

```bash
git -C "C:\Users\John Patrick Mandal\Desktop\samurai_cart_v3" branch -D chore/V3-9999-cleanup-test
```

- [ ] **Step 4: Commit**

```bash
cd "C:\Users\John Patrick Mandal\scripts"
git add samurai-cleanup-ticket.ps1
git commit -m "Add samurai-cleanup-ticket.ps1 for combined worktree+DB cleanup"
```

---

## Task 4: Wire the new commands into the PowerShell profile

**Files:**
- Modify: `C:\Users\John Patrick Mandal\Documents\PowerShell\profile.ps1`

**Interfaces:**
- Consumes (from Tasks 2/3): `samurai-test.ps1`, `samurai-cleanup-ticket.ps1` (invoked by absolute path, not by function name — no code-level coupling).
- Produces: shell functions `samurai-test` and `samurai-cleanup-ticket`, available in every new PowerShell session, following the exact pattern of the existing `samurai` / `dash` functions.

- [ ] **Step 1: Read the current profile**

Current contents of `C:\Users\John Patrick Mandal\Documents\PowerShell\profile.ps1`:

```powershell

function samurai { & 'C:\Users\John Patrick Mandal\scripts\samurai-dev.ps1' }
function dash { & 'C:\Users\John Patrick Mandal\scripts\samurai-dash.ps1' }
```

- [ ] **Step 2: Append the two new functions**

Edit `C:\Users\John Patrick Mandal\Documents\PowerShell\profile.ps1` to:

```powershell

function samurai { & 'C:\Users\John Patrick Mandal\scripts\samurai-dev.ps1' }
function dash { & 'C:\Users\John Patrick Mandal\scripts\samurai-dash.ps1' }
function samurai-test { & 'C:\Users\John Patrick Mandal\scripts\samurai-test.ps1' @args }
function samurai-cleanup-ticket { & 'C:\Users\John Patrick Mandal\scripts\samurai-cleanup-ticket.ps1' @args }
```

- [ ] **Step 3: Verify in a fresh shell**

Open a new PowerShell 7 (`pwsh`) window (profile only loads on startup, not in the current session) and run:

```powershell
Get-Command samurai-test, samurai-cleanup-ticket
```

Expected: both listed as `Function`.

Then, from inside any existing worktree:

```powershell
samurai-test tests/integration/test_regular_buy_list.py -v
```

Expected: same behavior as Task 2 Step 3, now callable by name instead of full script path.

- [ ] **Step 4: Commit**

The PowerShell profile lives outside any git repo (`Documents\PowerShell\`), so there's nothing to `git commit` here — this step is just the manual verification above. No commit action.

---

## Task 5: `/start-ticket` — create a worktree instead of branching in place

**Files:**
- Modify: `C:\Users\John Patrick Mandal\.claude\commands\start-ticket.md`

**Interfaces:**
- Consumes: nothing new (pure markdown/instruction edit).
- Produces: `/start-ticket V3-XXXX` now leaves the invoking checkout untouched on its current branch and creates `C:\Users\John Patrick Mandal\Desktop\wt-{KEY}-{slug}` on branch `{prefix}/{KEY}-{slug}`.

- [ ] **Step 1: Validate downstream commands are already cwd-relative (no hidden main-checkout path assumptions)**

Run:

```bash
grep -rn "Desktop\\\\samurai_cart_v3\b" "C:\Users\John Patrick Mandal\.claude\commands\"*.md
```

Expected: no matches referencing the main checkout as a hardcoded working directory for git/gh operations (any hits should only be things like vault/memory paths, which are intentionally absolute and unrelated to which checkout you're in). This confirms `/work-ticket`, `/open-pr`, `/ship-ticket`, `/wrap-ticket`, `/review-mine`, etc. need no changes — they already infer branch/repo from cwd (`git rev-parse --abbrev-ref HEAD`, `gh pr view` with no `--repo`). If a hit turns up a real hardcoded assumption, stop and report it before continuing — that command would need its own fix, out of scope for this task.

- [ ] **Step 2: Update step 6 (pre-flight checks) — drop the now-pointless uncommitted-changes prompt**

In `C:\Users\John Patrick Mandal\.claude\commands\start-ticket.md`, replace:

```markdown
### 6. Pre-flight checks

In order:

1. `git status --porcelain` — if non-empty, list the changed files and ask: **abort / stash / proceed anyway**. **Do not auto-stash.** The user keeps intentional uncommitted edits (memory `[[feedback_local_dev_hacks]]`).
2. `git rev-parse --abbrev-ref HEAD` — if not on `master`, ask whether to switch base.
3. `git fetch origin master` then check master's drift in both directions:
   - `git rev-list --count master..origin/master` → **behind count** (commits on origin we don't have)
   - `git rev-list --count origin/master..master` → **ahead count** (local commits not on origin)

   Three states:
   - **Up-to-date** (both 0): proceed silently to step 7.
   - **Behind > 0, ahead = 0:** ask whether to fast-forward local master before branching. Don't pull automatically. Record the choice — step 7 uses it.
   - **Ahead > 0** (un-pushed local commits): warn explicitly, since branching from local master means the feature starts on top of unreviewed work. Ask whether to continue or abort.
   - **Both > 0** (diverged): warn that fast-forward is no longer possible — combines the previous two warnings. Recommend the user reconcile master manually (rebase, merge, or reset) before continuing.
```

with:

```markdown
### 6. Pre-flight checks

Step 7 now creates an isolated worktree instead of branching in the current checkout, so the current checkout's branch and working-tree state are irrelevant to branch creation — nothing here touches them. Only master's freshness matters, since the new branch still needs a base ref:

`git fetch origin master` then check master's drift in both directions:
- `git rev-list --count master..origin/master` → **behind count** (commits on origin we don't have)
- `git rev-list --count origin/master..master` → **ahead count** (local commits not on origin)

Three states:
- **Up-to-date** (both 0): proceed silently to step 7.
- **Behind > 0, ahead = 0:** ask whether to fast-forward local master before branching. Don't pull automatically. Record the choice — step 7 uses it.
- **Ahead > 0** (un-pushed local commits): warn explicitly, since branching from local master means the feature starts on top of unreviewed work. Ask whether to continue or abort.
- **Both > 0** (diverged): warn that fast-forward is no longer possible — combines the previous two warnings. Recommend the user reconcile master manually (rebase, merge, or reset) before continuing.
```

- [ ] **Step 3: Rewrite step 7 to create a worktree**

Replace:

```markdown
### 7. Create the branch

Pick the base by what happened in step 6.3:

- **Local master is up-to-date OR the user chose to fast-forward:** branch from local master.
  ```
  git checkout -b {prefix}/{KEY}-{slug} master
  ```
- **Behind > 0 and the user declined to fast-forward:** branch from `origin/master` so the feature starts at the latest remote commit (not the stale local one).
  ```
  git checkout -b {prefix}/{KEY}-{slug} origin/master
  ```
- **Ahead > 0 (with or without behind > 0) and the user chose to continue:** branch from local master — that's the explicit choice to inherit the un-pushed work.

In every case, tell the user which base was used (`Branched from {master | origin/master}`) so it's not buried.
```

with:

```markdown
### 7. Create the worktree (and branch)

Every ticket gets its own isolated worktree — no exceptions, no "is the main checkout busy" judgment call. The worktree path mirrors the branch name (prefix dropped, it's a redundant git-ref namespace):

```
C:\Users\John Patrick Mandal\Desktop\wt-{KEY}-{slug}
```

**Duplicate check first.** Run `git worktree list --porcelain` and look for a `branch refs/heads/{prefix}/{KEY}-{slug}` line. If found, stop and report that worktree's path instead of creating a second one — don't error, don't overwrite (this is a second signal beyond step 1's vault/cache re-run check, in case those files were deleted while the worktree survived).

Otherwise, pick the base by what happened in step 6:

- **Local master is up-to-date OR the user chose to fast-forward:** branch from local master.
  ```bash
  git -c core.longpaths=true worktree add -b {prefix}/{KEY}-{slug} "C:/Users/John Patrick Mandal/Desktop/wt-{KEY}-{slug}" master
  ```
- **Behind > 0 and the user declined to fast-forward:** branch from `origin/master` so the feature starts at the latest remote commit (not the stale local one).
  ```bash
  git -c core.longpaths=true worktree add -b {prefix}/{KEY}-{slug} "C:/Users/John Patrick Mandal/Desktop/wt-{KEY}-{slug}" origin/master
  ```
- **Ahead > 0 (with or without behind > 0) and the user chose to continue:** branch from local master — that's the explicit choice to inherit the un-pushed work.

`-c core.longpaths=true` is belt-and-suspenders against Windows MAX_PATH on this repo's deeper frontend paths (memory `[[windows_worktree_maxpath]]`) — the short Desktop base already clears the limit on its own, this just adds margin.

In every case, tell the user which base was used (`Branched from {master | origin/master}`) so it's not buried. This works identically whether `/start-ticket` is invoked from the main checkout or from inside another worktree — worktrees of the same repo share refs (`master`, `origin/master`); only HEAD and working-tree state are per-worktree.
```

- [ ] **Step 4: Update the refresh-mode re-run handling in step 1 to account for worktrees**

Find this sentence in step 1 (`### 1. Validate the argument and detect re-run`):

```markdown
If `(a)`: proceed to step 2, but in steps 9 and 10 — use `Write` (overwrites) on the existing paths; skip step 7 (branch creation) if `git rev-parse --verify {prefix}/{KEY}-{slug}` succeeds.
```

Replace with:

```markdown
If `(a)`: proceed to step 2, but in steps 9 and 10 — use `Write` (overwrites) on the existing paths. In step 7: if the branch `{prefix}/{KEY}-{slug}` already exists (`git rev-parse --verify` succeeds) but `git worktree list` shows no worktree on it — this happens after `samurai-cleanup-ticket` removed the worktree but left the branch, matching `/wrap-ticket`'s own "never delete branches" behavior — create the worktree anchored to the existing branch instead of creating a new one: `git -c core.longpaths=true worktree add "<path>" {prefix}/{KEY}-{slug}` (no `-b`, no base ref needed). If a worktree for it already exists, skip step 7 entirely and report its path.
```

- [ ] **Step 5: Update the step 11 hand-off message**

Replace:

```markdown
### 11. Hand off

Reply to the user with:

```
✅ Branch created: {prefix}/{KEY}-{slug}
✅ Ticket cached: {cache path}
✅ Vault overview: {vault}/tickets/{KEY}/overview.md
{if translated: "🌐 Translated from Japanese."}

Next steps:
1. Invoke `superpowers:brainstorming` to explore intent, requirements, and design — required before any creative work (features, components, behavior changes).
2. Then invoke `superpowers:writing-plans` to formalize the implementation plan against {cache path}.

Skip step 1 only if the ticket's scope is already fully concrete (small refactor, clear bugfix with reproducible repro, or a checklist-style AC where the design is obvious). When in doubt, brainstorm first — it's cheap.
```
```

with:

```markdown
### 11. Hand off

Reply to the user with:

```
✅ Branch created: {prefix}/{KEY}-{slug}
✅ Worktree:       C:\Users\John Patrick Mandal\Desktop\wt-{KEY}-{slug}
✅ Ticket cached: {cache path}
✅ Vault overview: {vault}/tickets/{KEY}/overview.md
{if translated: "🌐 Translated from Japanese."}

Next steps:
1. Open the worktree in its own VS Code window / Claude Code session:
   code "C:\Users\John Patrick Mandal\Desktop\wt-{KEY}-{slug}"
2. From that session, invoke `superpowers:brainstorming` to explore intent, requirements, and design — required before any creative work (features, components, behavior changes).
3. Then invoke `superpowers:writing-plans` to formalize the implementation plan against {cache path}.

Skip step 2 only if the ticket's scope is already fully concrete (small refactor, clear bugfix with reproducible repro, or a checklist-style AC where the design is obvious). When in doubt, brainstorm first — it's cheap.
```
```

- [ ] **Step 6: Update the References section**

Find the `## References (the user's setup)` block near the top of the file and add one bullet (after the existing "Git identity" bullet):

```markdown
- **Worktree convention:** every ticket branch lives in its own worktree at `C:\Users\John Patrick Mandal\Desktop\wt-{KEY}-{slug}` (memory `[[windows_worktree_maxpath]]`) — created together with the branch in step 7, never `git checkout -b` in the current checkout. The main checkout stays parked on `master` permanently.
```

- [ ] **Step 7: Update the Safety / behavior bullets**

Find this bullet in the `## Safety / behavior` section:

```markdown
- **Never auto-stash.** Always ask before touching uncommitted work.
```

Replace with:

```markdown
- **Every ticket gets its own worktree — no exceptions.** The main checkout stays parked on `master` permanently; it never gets a feature branch again. This also means the old uncommitted-changes stash prompt is gone — worktree creation never touches the current checkout's working tree, so there's nothing to stash.
- **Never create a duplicate worktree for the same branch.** Step 7 checks `git worktree list` first; if one already exists, report its path instead of creating a second one.
```

- [ ] **Step 8: Manual end-to-end validation**

From the main checkout, run `/start-ticket` on a throwaway key (use a Jira key that's safe to no-op on, or simulate — at minimum verify the git mechanics manually):

```powershell
cd "C:\Users\John Patrick Mandal\Desktop\samurai_cart_v3"
git -c core.longpaths=true worktree add -b chore/V3-9998-plan-validation "C:/Users/John Patrick Mandal/Desktop/wt-V3-9998-plan-validation" master
```

Expected: succeeds, and the main checkout's own branch/working tree is completely unaffected:

```powershell
git -C "C:\Users\John Patrick Mandal\Desktop\samurai_cart_v3" rev-parse --abbrev-ref HEAD
```

Expected: unchanged from whatever it was before (not `chore/V3-9998-plan-validation`).

Then confirm the new worktree is independently usable — open it in VS Code and confirm Source Control shows the new branch:

```powershell
code "C:\Users\John Patrick Mandal\Desktop\wt-V3-9998-plan-validation"
```

Clean up:

```powershell
pwsh -NoProfile -File "C:\Users\John Patrick Mandal\scripts\samurai-cleanup-ticket.ps1" -Key V3-9998
git -C "C:\Users\John Patrick Mandal\Desktop\samurai_cart_v3" branch -D chore/V3-9998-plan-validation
```

Then do a real dry run of the actual `/start-ticket` command (in Claude Code) against a real throwaway/test key once available, to confirm the edited markdown produces the same result end-to-end including the vault/cache writes.

- [ ] **Step 9: Commit**

```bash
cd "C:\Users\John Patrick Mandal\.claude"
git add commands/start-ticket.md
git commit -m "Make /start-ticket create an isolated worktree per ticket"
```

(Skip this step if `~/.claude` isn't a git repo in your setup — check with `git -C "C:\Users\John Patrick Mandal\.claude" status` first; if it errors with "not a git repository," there's nothing to commit, the file edit itself is the whole deliverable.)

---

## Self-Review Notes

- **Spec coverage:** Component 1 (worktree-by-default) → Task 5. Component 2 (test-DB script) → Tasks 1–2. Combined cleanup → Task 3. Profile wiring (implied by "personal script... exposed as a function") → Task 4. All spec sections have a corresponding task.
- **Placeholder scan:** no TBD/TODO; every step has real code or exact commands with expected output.
- **Type/name consistency checked:** `ConvertTo-TestDbSuffix`, `Get-TicketKeyFromFolderName`, `Get-TicketKeyFromBranch`, `Test-TestDbExists`, `New-TestDb`, `Remove-TestDb` are defined once in Task 1 and referenced by the exact same names in Tasks 2 and 3. `samurai-test` / `samurai-cleanup-ticket` function names match between Task 4's profile wiring and the script filenames from Tasks 2/3.
- **Known open item, not blocking:** Task 5 Step 9 assumes `~/.claude` may or may not be its own git repo — the step handles both cases rather than guessing.

---

## Post-implementation: final whole-branch review findings (2026-07-21)

All 5 tasks executed and passed individual review (Task 5 needed one fix — the epic-mode hand-off was missing the worktree line, added and re-reviewed clean). The final whole-plan review then found one real defect this task-by-task process couldn't see on its own, since it only became visible when someone tried the tool exactly as documented:

**Important, fixed:** `samurai-test.ps1` as originally written in this plan's Task 2 (see that task's Step 1 code block above) crashes on its own documented invocation. `-Key` was declared as the first positional parameter, so a bare `samurai-test tests/foo.py -v` bound the pytest path to `$Key` instead of forwarding it, and having any `[Parameter(...)]` attribute promotes a PowerShell script to an "advanced function," which auto-adds common parameters (`-Verbose`, `-Debug`, ...) — so pytest's own `-v`/`-o`/`-d`/`-p` flags got silently intercepted, and `-k` (pytest's keyword filter) collided with `-Key` itself. **Fixed** by rewriting `samurai-test.ps1` to declare no `[Parameter(...)]` attributes at all (only a bare `[switch]$NoRun`), and manually splitting PowerShell's automatic `$args` into an optional `-Ticket` override plus everything else as pytest args via a new `Split-SamuraiTestArgs` function — this is the actual shipped version, not the Task 2 code block above, which is left as-written for planning history. Committed as `b408cff` in `~/scripts`, alongside a Minor fix to a vacuous unit-test assertion (`samurai-testdb-lib.Tests.ps1`'s "invalid key throws" case couldn't actually fail) and a stray broken `git worktree add` flag-ordering example in the design doc.

Also fixed (Minor, wording precision in an LLM-consumed instruction file): `start-ticket.md`'s frontmatter `description:` and opening paragraph still described the command as scaffolding "a new feature branch" with no mention of the worktree it now creates; the `--epic` path's intro still said "branch creation (step 7)" instead of "worktree/branch creation"; and a refresh-mode sentence referenced a `✅ Created:`/`🔄 Refreshed:` hand-off line pair that doesn't actually exist in the real template (pre-existing inaccuracy, reconciled while the file was open).

Left as-is (reviewer's explicit triage, not fixed): SQL/shell interpolation of the ticket key with no escaping beyond the upstream regex (safe allowlist, single-user tooling); `Find-TicketWorktree`'s multi-match case throwing a raw exception instead of the script's usual clean error style (cosmetic); a failed `git worktree remove` blocking the DB-drop half of combined cleanup too (intentional — a dirty worktree means the ticket isn't actually done, so its DB shouldn't be dropped out from under it either).
