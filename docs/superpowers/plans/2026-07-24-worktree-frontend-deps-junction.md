# Worktree Frontend Deps — Junction Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the 128,755-file `robocopy` that provisions `frontend/node_modules` into a git worktree with an NTFS directory junction (measured: 35 ms vs. minutes), so the `pre-push` frontend-build guard can start immediately instead of waiting out a copy.

**Architecture:** A new shared library (`samurai-junction-lib.ps1`) holds the junction primitives, following the existing `samurai-testdb-lib.ps1` pattern. `samurai-sync-frontend-deps.ps1` keeps its existing lockfile-blob safety gate but uses it to select a provisioning *mode* (link / install / relink / swap / noop / reclaim) via a pure decision function, instead of gating a single copy. `samurai-cleanup-ticket.ps1` gains an unlink-before-remove step. `robocopy` is deleted entirely.

**Tech Stack:** PowerShell 7+ (pwsh), NTFS directory junctions (`New-Item -ItemType Junction`, `System.IO.Directory::Delete`), git worktrees, npm.

**Spec:** `docs/superpowers/specs/2026-07-24-worktree-frontend-deps-junction-design.md`

## Global Constraints

- **Dependency-free tests only.** This repo uses a hand-rolled `Assert` scriptblock harness (`samurai-testdb-lib.Tests.ps1`, `samurai-dash.Tests.ps1`). Do **not** introduce Pester.
- **No `Mandatory` parameters on any script that must be dot-sourced with `-NoRun`.** Mandatory binding happens at dot-source time and prompts for the missing value, hanging a non-interactive test run. Validate inside the `Invoke-*` function instead. This is a change to both scripts' existing `param()` blocks.
- **Junction deletion is always `[System.IO.Directory]::Delete($Path, $false)`** — never `Remove-Item -Recurse`. Windows PowerShell 5.1 historically deleted *through* junctions, and the target here is the machine's only good `node_modules`.
- **`Remove-Item -Recurse` is correct only in `-Reclaim`,** where the target genuinely is a populated real directory. Branch on `LinkType`; never apply one deletion uniformly.
- **Exit-code contract:** `0` = provisioned OR a safe intentional skip; `1` = real error, kept explicit for a future caller. (No consumer reads it yet — `/start-ticket` step 7b infers the outcome from console output, not the exit code.)
- **Never silently skip or fall back** — every skip/fallback prints its reason.
- **Commit per task, on the feature branch only.** Authorized 2026-07-24: work happens on `feature/worktree-deps-junction` in `~/scripts` (branched from `master` at `563071b`). Each task ends with a real commit on that branch. **Never commit to `master`, and never merge** — the user reviews the whole branch before anything lands.
- **Stage file-scoped; never `git add -A`.** `~/scripts` carries unrelated pre-existing dirty state (`agent-hook.js`, `samurai-alembic.ps1`, `samurai-dashboard-autostart.ps1`, `autostart-test*.log`, a deleted `agent-heartbeat.ps1`, an older untracked plan doc). Stage only the files each task names.
- **Expect pre-existing changes inside this plan's own files.** `samurai-sync-frontend-deps.ps1` is untracked (never committed), and `samurai-cleanup-ticket.ps1` already carries an uncommitted worktree-root change (`$script:Desktop` → `$script:WorktreesRoot`). Both are intentional prior work — keep them, do not revert them, and do not treat them as your own task's doing.
- **Exact paths, verbatim:** main repo `C:\Users\John Patrick Mandal\Desktop\samurai_cart_v3`; worktrees root `C:\Users\John Patrick Mandal\Desktop\samurai_cart_v3 worktrees`; scripts `C:\Users\John Patrick Mandal\scripts`.

## File Structure

| File | Responsibility |
|---|---|
| `samurai-junction-lib.ps1` *(new)* | Junction primitives only: test / read target / create / unlink. No worktree or npm knowledge. |
| `samurai-junction-lib.Tests.ps1` *(new)* | Tests for the above, against real temp directories. |
| `samurai-sync-frontend-deps.ps1` *(modify)* | Provisioning decision + execution. Dot-sources the lib. |
| `samurai-sync-frontend-deps.Tests.ps1` *(new)* | Tests the pure decision function. |
| `samurai-cleanup-ticket.ps1` *(modify)* | Adds unlink-before-remove. Dot-sources the lib. |
| `samurai-cleanup-ticket.Tests.ps1` *(new)* | Tests key validation + worktree lookup (never tested before). |
| `~/.claude/commands/start-ticket.md` *(modify)* | Hand-off wording: linked / installed / skipped. |

---

### Task 1: Junction primitives library (TDD)

**Files:**
- Create: `C:\Users\John Patrick Mandal\scripts\samurai-junction-lib.ps1`
- Create: `C:\Users\John Patrick Mandal\scripts\samurai-junction-lib.Tests.ps1`

**Interfaces:**
- Produces: `Test-IsJunction([string]$Path) -> bool`, `Get-JunctionTarget([string]$Path) -> string|null`, `New-JunctionLink([string]$Path, [string]$Target) -> void`, `Remove-JunctionLink([string]$Path) -> void`. Tasks 3, 4 and 5 all call these.

- [ ] **Step 1: Write the failing tests**

Create `C:\Users\John Patrick Mandal\scripts\samurai-junction-lib.Tests.ps1`:

```powershell
# Dependency-free tests. Run: pwsh -NoProfile -File samurai-junction-lib.Tests.ps1
. "$PSScriptRoot\samurai-junction-lib.ps1"

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

# Real-filesystem sandbox: junctions are an NTFS feature, so these can't be faked.
$sandbox = Join-Path $env:TEMP "junction-lib-tests-$PID"
if (Test-Path $sandbox) { Remove-Item -LiteralPath $sandbox -Recurse -Force }
New-Item -ItemType Directory $sandbox -Force | Out-Null
$target = Join-Path $sandbox 'target'
$link   = Join-Path $sandbox 'link'
$plain  = Join-Path $sandbox 'plain'
New-Item -ItemType Directory $target -Force | Out-Null
New-Item -ItemType Directory $plain  -Force | Out-Null
Set-Content (Join-Path $target 'canary.txt') 'must survive'

try {
    # --- Test-IsJunction ---
    Assert 'is-junction: missing path -> false'  { -not (Test-IsJunction (Join-Path $sandbox 'nope')) }
    Assert 'is-junction: plain dir -> false'     { -not (Test-IsJunction $plain) }

    New-JunctionLink -Path $link -Target $target
    Assert 'is-junction: junction -> true'       { Test-IsJunction $link }
    Assert 'new-junction: reads through link'    { Test-Path (Join-Path $link 'canary.txt') }

    # --- Get-JunctionTarget ---
    Assert 'get-target: returns target path'     { (Get-JunctionTarget $link) -eq $target.TrimEnd('\') }
    Assert 'get-target: plain dir -> null'       { $null -eq (Get-JunctionTarget $plain) }

    # --- New-JunctionLink guards ---
    Assert 'new-junction: missing target throws' {
        try { New-JunctionLink -Path (Join-Path $sandbox 'l2') -Target (Join-Path $sandbox 'ghost'); $false }
        catch { $true }
    }

    # --- Remove-JunctionLink ---
    Assert 'remove-junction: refuses a plain dir' {
        try { Remove-JunctionLink -Path $plain; $false } catch { $true }
    }
    Assert 'remove-junction: plain dir untouched' { Test-Path $plain }

    Remove-JunctionLink -Path $link
    Assert 'remove-junction: link gone'          { -not (Test-Path $link) }
    # The whole point of the non-recursive delete: the target must be untouched.
    Assert 'remove-junction: TARGET SURVIVES'    { Test-Path (Join-Path $target 'canary.txt') }
} finally {
    Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($script:ran -eq 0) { Write-Host 'NO TESTS RAN' -ForegroundColor Red; exit 1 }
if ($script:fails) { Write-Host "$($script:fails)/$($script:ran) FAILED" -ForegroundColor Red; exit 1 } else { Write-Host "ALL $($script:ran) PASS" -ForegroundColor Green }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:
```powershell
pwsh -NoProfile -File "C:\Users\John Patrick Mandal\scripts\samurai-junction-lib.Tests.ps1"
```
Expected: FAIL — the dot-source on line 2 errors because `samurai-junction-lib.ps1` does not exist yet.

- [ ] **Step 3: Write the library**

Create `C:\Users\John Patrick Mandal\scripts\samurai-junction-lib.ps1`:

```powershell
# samurai-junction-lib.ps1 — NTFS directory-junction primitives shared by the worktree tooling.
# A junction lets a worktree's frontend/node_modules point at the main checkout's single store
# instead of holding its own ~128k-file copy. Pure helpers, no side effects on dot-source.

function Test-IsJunction([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if (-not $item) { return $false }
    return $item.LinkType -eq 'Junction'
}

function Get-JunctionTarget([string]$Path) {
    if (-not (Test-IsJunction $Path)) { return $null }
    # .Target is a collection on some PowerShell versions; normalize to one comparable string.
    $t = @((Get-Item -LiteralPath $Path -Force).Target)[0]
    if (-not $t) { return $null }
    return $t.TrimEnd('\')
}

function New-JunctionLink([string]$Path, [string]$Target) {
    if (-not (Test-Path -LiteralPath $Target)) {
        throw "Junction target does not exist: $Target"
    }
    New-Item -ItemType Junction -Path $Path -Target $Target -ErrorAction Stop | Out-Null
}

function Remove-JunctionLink([string]$Path) {
    # Hard guard: this function must never be reachable with a real directory, because the
    # only thing it is ever pointed at is the machine's single good node_modules store.
    if (-not (Test-IsJunction $Path)) {
        throw "Not a junction (refusing to delete): $Path"
    }
    # Non-recursive delete removes ONLY the link. Remove-Item -Recurse deleted *through*
    # junctions on Windows PowerShell 5.1; this call structurally cannot touch the target.
    [System.IO.Directory]::Delete($Path, $false)
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run:
```powershell
pwsh -NoProfile -File "C:\Users\John Patrick Mandal\scripts\samurai-junction-lib.Tests.ps1"
```
Expected: `ALL 11 PASS`

- [ ] **Step 5: Commit (feature branch only)**

Confirm you are on the feature branch, then commit these two files only:

```powershell
git -C "C:\Users\John Patrick Mandal\scripts" rev-parse --abbrev-ref HEAD
git -C "C:\Users\John Patrick Mandal\scripts" add samurai-junction-lib.ps1 samurai-junction-lib.Tests.ps1
git -C "C:\Users\John Patrick Mandal\scripts" commit -m "feat(scripts): add samurai-junction-lib for NTFS junction primitives"
```

The first command must print `feature/worktree-deps-junction`. If it prints `master`, stop and report — do not commit.

---

### Task 2: Provisioning-mode decision function (TDD)

The pure decision table from the spec, isolated from all filesystem and npm work so it can be exhaustively tested.

**Files:**
- Modify: `C:\Users\John Patrick Mandal\scripts\samurai-sync-frontend-deps.ps1` (param block + new function)
- Create: `C:\Users\John Patrick Mandal\scripts\samurai-sync-frontend-deps.Tests.ps1`

**Interfaces:**
- Produces: `Get-ProvisioningMode([string]$DestState, [bool]$LockMatch, [bool]$SourceHealthy, [bool]$JunctionTargetOk) -> string`, returning one of `'link'`, `'install'`, `'relink'`, `'swap'`, `'noop'`. Task 3 calls it.
- `$DestState` is one of `'absent'`, `'junction'`, `'realdir'`.

- [ ] **Step 1: Write the failing tests**

Create `C:\Users\John Patrick Mandal\scripts\samurai-sync-frontend-deps.Tests.ps1`:

```powershell
# Dependency-free tests. Run: pwsh -NoProfile -File samurai-sync-frontend-deps.Tests.ps1
. "$PSScriptRoot\samurai-sync-frontend-deps.ps1" -NoRun

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

# --- Get-ProvisioningMode: absent ---
Assert 'absent + match + healthy   -> link' {
    (Get-ProvisioningMode -DestState 'absent' -LockMatch $true -SourceHealthy $true -JunctionTargetOk $false) -eq 'link'
}
Assert 'absent + match + UNhealthy -> install' {
    (Get-ProvisioningMode -DestState 'absent' -LockMatch $true -SourceHealthy $false -JunctionTargetOk $false) -eq 'install'
}
Assert 'absent + differ            -> install' {
    (Get-ProvisioningMode -DestState 'absent' -LockMatch $false -SourceHealthy $true -JunctionTargetOk $false) -eq 'install'
}

# --- Get-ProvisioningMode: realdir ---
# A populated real store already satisfies its own lockfile, so main-store health is irrelevant.
Assert 'realdir + match            -> noop' {
    (Get-ProvisioningMode -DestState 'realdir' -LockMatch $true -SourceHealthy $false -JunctionTargetOk $false) -eq 'noop'
}
Assert 'realdir + differ           -> install' {
    (Get-ProvisioningMode -DestState 'realdir' -LockMatch $false -SourceHealthy $true -JunctionTargetOk $false) -eq 'install'
}

# --- Get-ProvisioningMode: junction ---
Assert 'junction + match + healthy + target ok  -> noop' {
    (Get-ProvisioningMode -DestState 'junction' -LockMatch $true -SourceHealthy $true -JunctionTargetOk $true) -eq 'noop'
}
Assert 'junction + match + healthy + wrong target -> relink' {
    (Get-ProvisioningMode -DestState 'junction' -LockMatch $true -SourceHealthy $true -JunctionTargetOk $false) -eq 'relink'
}
Assert 'junction + DIFFER                        -> swap' {
    (Get-ProvisioningMode -DestState 'junction' -LockMatch $false -SourceHealthy $true -JunctionTargetOk $true) -eq 'swap'
}
Assert 'junction + match + UNhealthy source      -> swap' {
    (Get-ProvisioningMode -DestState 'junction' -LockMatch $true -SourceHealthy $false -JunctionTargetOk $true) -eq 'swap'
}

# --- Guard: unknown state must not silently return $null ---
Assert 'unknown DestState throws' {
    try { Get-ProvisioningMode -DestState 'bogus' -LockMatch $true -SourceHealthy $true -JunctionTargetOk $true | Out-Null; $false }
    catch { $true }
}

Write-Host ''
if ($script:ran -eq 0) { Write-Host 'NO TESTS RAN' -ForegroundColor Red; exit 1 }
if ($script:fails) { Write-Host "$($script:fails)/$($script:ran) FAILED" -ForegroundColor Red; exit 1 } else { Write-Host "ALL $($script:ran) PASS" -ForegroundColor Green }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:
```powershell
pwsh -NoProfile -File "C:\Users\John Patrick Mandal\scripts\samurai-sync-frontend-deps.Tests.ps1"
```
Expected: FAIL — `Get-ProvisioningMode` is not defined. (If it instead *hangs asking for `WorktreePath`*, that is the Mandatory-parameter trap from Global Constraints; Step 3 fixes it.)

- [ ] **Step 3: Drop `Mandatory`, dot-source the lib, add the decision function**

In `C:\Users\John Patrick Mandal\scripts\samurai-sync-frontend-deps.ps1`, replace the `param()` block (currently lines 11–17, through the `$script:MainRepo` assignment) with:

```powershell
# NOTE: WorktreePath is deliberately NOT [Parameter(Mandatory)] -- mandatory binding fires on
# dot-source, so `. this.ps1 -NoRun` would prompt for it and hang a non-interactive test run.
# Validated inside Invoke-SamuraiSyncFrontendDeps instead.
param(
    [string]$WorktreePath,
    [switch]$Reclaim,
    [switch]$NoRun
)

. "$PSScriptRoot\samurai-junction-lib.ps1"

$script:MainRepo = 'C:\Users\John Patrick Mandal\Desktop\samurai_cart_v3'
```

Then add this function immediately after `Test-SourceNodeModulesHealthy`:

```powershell
# Pure decision table (see the 2026-07-24 design doc). Takes only facts, touches nothing.
function Get-ProvisioningMode {
    param(
        [string]$DestState,      # 'absent' | 'junction' | 'realdir'
        [bool]$LockMatch,
        [bool]$SourceHealthy,
        [bool]$JunctionTargetOk
    )
    switch ($DestState) {
        'absent' {
            if ($LockMatch -and $SourceHealthy) { return 'link' }
            return 'install'
        }
        'realdir' {
            # Already a self-sufficient private store; main-store health is irrelevant here.
            if ($LockMatch) { return 'noop' }
            return 'install'
        }
        'junction' {
            # Any reason the shared store is wrong for this worktree means unlink-then-install.
            if (-not $LockMatch)        { return 'swap' }
            if (-not $SourceHealthy)    { return 'swap' }
            if (-not $JunctionTargetOk) { return 'relink' }
            return 'noop'
        }
        default { throw "Unknown DestState: '$DestState'" }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run:
```powershell
pwsh -NoProfile -File "C:\Users\John Patrick Mandal\scripts\samurai-sync-frontend-deps.Tests.ps1"
```
Expected: `ALL 10 PASS`

- [ ] **Step 5: Commit (feature branch only)**

```powershell
git -C "C:\Users\John Patrick Mandal\scripts" rev-parse --abbrev-ref HEAD
git -C "C:\Users\John Patrick Mandal\scripts" add samurai-sync-frontend-deps.ps1 samurai-sync-frontend-deps.Tests.ps1
git -C "C:\Users\John Patrick Mandal\scripts" commit -m "feat(scripts): add provisioning-mode decision table for worktree frontend deps"
```

The first command must print `feature/worktree-deps-junction`. If it prints `master`, stop and report — do not commit.

Note: `samurai-sync-frontend-deps.ps1` is currently **untracked**, so this commit adds the whole file, including the parts you did not write. That is expected.

---

### Task 3: Execute the modes — replace robocopy

**Files:**
- Modify: `C:\Users\John Patrick Mandal\scripts\samurai-sync-frontend-deps.ps1` (rewrite `Invoke-SamuraiSyncFrontendDeps`, delete the robocopy block)

**Interfaces:**
- Consumes: `Get-ProvisioningMode` (Task 2); `Test-IsJunction`, `Get-JunctionTarget`, `New-JunctionLink`, `Remove-JunctionLink` (Task 1).
- Produces: `Invoke-NpmCi([string]$WorktreePath) -> int` (0 ok / 1 failed). Task 4 calls it.

There is no unit test for this step — it is pure I/O orchestration over already-tested pure functions. It is verified by the real-worktree checks in Step 3 below and by Task 6's validation.

- [ ] **Step 1: Add the npm ci helper**

Add above `Invoke-SamuraiSyncFrontendDeps`:

```powershell
function Invoke-NpmCi([string]$WorktreePath) {
    Write-Host "Running npm ci in $WorktreePath\frontend -- this worktree's dependency set differs from the main checkout, so it needs its own store. Expect several minutes." -ForegroundColor Cyan
    Push-Location "$WorktreePath\frontend"
    try { npm ci; $code = $LASTEXITCODE } finally { Pop-Location }
    if ($code -ne 0) {
        Write-Host "npm ci failed (exit $code) -- frontend deps are NOT ready in this worktree." -ForegroundColor Red
        return 1
    }
    Write-Host 'Frontend deps installed (private store).' -ForegroundColor Green
    return 0
}
```

- [ ] **Step 2: Replace the body of `Invoke-SamuraiSyncFrontendDeps`**

Replace the whole function (currently lines 29–78, from `function Invoke-SamuraiSyncFrontendDeps {` through its closing brace) with:

```powershell
function Invoke-SamuraiSyncFrontendDeps {
    param([string]$WorktreePath, [switch]$Reclaim)

    # Every terminal path sets an explicit exit code: 0 = provisioned OR a safe intentional
    # skip, 1 = a real error. /start-ticket step 7b reads this.
    if (-not $WorktreePath) {
        Write-Host 'WorktreePath is required.' -ForegroundColor Red
        exit 1
    }
    if (-not (Test-Path "$WorktreePath\frontend\package-lock.json")) {
        Write-Host "No frontend/package-lock.json in $WorktreePath -- nothing to sync." -ForegroundColor Yellow
        exit 0
    }

    $sourceStore = "$script:MainRepo\frontend\node_modules".TrimEnd('\')
    $destStore   = "$WorktreePath\frontend\node_modules"

    $sourceHash = Get-CommittedBlobHash $script:MainRepo 'frontend/package-lock.json'
    $targetHash = Get-CommittedBlobHash $WorktreePath 'frontend/package-lock.json'
    if (-not $sourceHash -or -not $targetHash) {
        Write-Host "Could not read package-lock.json's committed blob hash from one side -- can't prove the dependency sets match, so falling back to a private install." -ForegroundColor Yellow
        exit (Invoke-NpmCi $WorktreePath)
    }

    $lockMatch     = ($sourceHash -eq $targetHash)
    $sourceHealthy = Test-SourceNodeModulesHealthy $script:MainRepo

    $destState = if (-not (Test-Path -LiteralPath $destStore)) { 'absent' }
                 elseif (Test-IsJunction $destStore)           { 'junction' }
                 else                                          { 'realdir' }

    $junctionTargetOk = $false
    if ($destState -eq 'junction') {
        $junctionTargetOk = ((Get-JunctionTarget $destStore) -eq $sourceStore)
    }

    $mode = Get-ProvisioningMode -DestState $destState -LockMatch $lockMatch `
                -SourceHealthy $sourceHealthy -JunctionTargetOk $junctionTargetOk

    # -Reclaim is the ONLY way the deliberate 'realdir + match -> noop' becomes a conversion.
    # Swapping a private store for a shared one changes isolation guarantees; never implicit.
    if ($Reclaim -and $destState -eq 'realdir' -and $lockMatch -and $sourceHealthy) {
        $mode = 'reclaim'
    }

    switch ($mode) {
        'noop' {
            Write-Host "Frontend deps already provisioned ($destState) -- nothing to do." -ForegroundColor Green
            exit 0
        }
        'link' {
            Write-Host 'Linking frontend/node_modules to the main checkout (committed lockfile blobs match, source looks healthy) ...' -ForegroundColor Cyan
            New-JunctionLink -Path $destStore -Target $sourceStore
            Write-Host "Frontend deps linked -> $sourceStore" -ForegroundColor Green
            exit 0
        }
        'relink' {
            Write-Host 'Existing junction points somewhere unexpected -- re-pointing at the main checkout ...' -ForegroundColor Yellow
            Remove-JunctionLink -Path $destStore
            New-JunctionLink -Path $destStore -Target $sourceStore
            Write-Host "Frontend deps re-linked -> $sourceStore" -ForegroundColor Green
            exit 0
        }
        'swap' {
            # Unlink FIRST. Running npm ci through a live junction writes into the shared store.
            Write-Host 'Dependency set no longer matches the shared store -- unlinking, then installing privately ...' -ForegroundColor Yellow
            Remove-JunctionLink -Path $destStore
            exit (Invoke-NpmCi $WorktreePath)
        }
        'install' {
            exit (Invoke-NpmCi $WorktreePath)
        }
        'reclaim' {
            # Real directory here, NOT a junction -- so this is the one deletion that must recurse.
            Write-Host "Reclaiming: deleting this worktree's private node_modules, then linking to the main checkout. Removing ~128k files takes a while." -ForegroundColor Cyan
            Remove-Item -LiteralPath $destStore -Recurse -Force -ErrorAction Stop
            New-JunctionLink -Path $destStore -Target $sourceStore
            Write-Host "Reclaimed -- frontend deps now linked -> $sourceStore" -ForegroundColor Green
            exit 0
        }
        default {
            Write-Host "Internal error: unhandled provisioning mode '$mode'." -ForegroundColor Red
            exit 1
        }
    }
}
```

- [ ] **Step 3: Update the invocation line and verify against a real worktree**

Change the last line of the file to pass the new switch:

```powershell
if (-not $NoRun) { Invoke-SamuraiSyncFrontendDeps -WorktreePath $WorktreePath -Reclaim:$Reclaim }
```

Re-run Task 2's tests to confirm nothing regressed:
```powershell
pwsh -NoProfile -File "C:\Users\John Patrick Mandal\scripts\samurai-sync-frontend-deps.Tests.ps1"
```
Expected: `ALL 10 PASS`

Then provision a **throwaway** worktree. Do not point this at any of the four live worktrees — the user runs concurrent agent sessions in them, and provisioning work belongs in a tree nobody else is holding.

```powershell
$main  = 'C:\Users\John Patrick Mandal\Desktop\samurai_cart_v3'
$proof = 'C:\Users\John Patrick Mandal\Desktop\samurai_cart_v3 worktrees\wt-link-proof'
git -C $main -c core.longpaths=true worktree add --detach -q $proof master
Measure-Command { pwsh -File "C:\Users\John Patrick Mandal\scripts\samurai-sync-frontend-deps.ps1" -WorktreePath $proof } | Select-Object -ExpandProperty TotalSeconds
(Get-Item "$proof\frontend\node_modules" -Force).LinkType
(Get-ChildItem "$main\frontend\node_modules" -Recurse -File | Measure-Object).Count
```
Expected: `Frontend deps linked -> ...`, elapsed **under 2 seconds** (this is the whole point of the change — if it takes minutes, something is still copying), `LinkType` prints `Junction`, and the main store reads `128755` (measured 2026-07-24 — any lower number means something deleted through the link, which is a stop-everything bug).

Confirm idempotency by re-running the same `pwsh -File ...` command. Expected: `Frontend deps already provisioned (junction) -- nothing to do.`

Tear the throwaway down, unlinking first:
```powershell
$main  = 'C:\Users\John Patrick Mandal\Desktop\samurai_cart_v3'
$proof = 'C:\Users\John Patrick Mandal\Desktop\samurai_cart_v3 worktrees\wt-link-proof'
. "C:\Users\John Patrick Mandal\scripts\samurai-junction-lib.ps1"
Remove-JunctionLink -Path "$proof\frontend\node_modules"
git -C $main worktree remove --force $proof
git -C $main worktree prune
(Get-ChildItem "$main\frontend\node_modules" -Recurse -File | Measure-Object).Count
```
Expected: main store still `128755`., exit 0.

- [ ] **Step 4: Commit (feature branch only)**

```powershell
git -C "C:\Users\John Patrick Mandal\scripts" rev-parse --abbrev-ref HEAD
git -C "C:\Users\John Patrick Mandal\scripts" add samurai-sync-frontend-deps.ps1
git -C "C:\Users\John Patrick Mandal\scripts" commit -m "feat(scripts): provision worktree frontend deps by junction instead of robocopy"
```

The first command must print `feature/worktree-deps-junction`. If it prints `master`, stop and report — do not commit.

---

### Task 4: Verify the real-filesystem paths end to end

Tasks 2–3 unit-tested the *decision*; nothing has exercised the *execution* against a real worktree. This task covers the spec's validation plan for the sync script: build-through-junction, the auto-swap (the single most dangerous path — `npm ci` could write into the shared store if the unlink ordering were wrong), `-Reclaim`, and the exit-code contract.

**Files:** none modified. This is a verification task with a real filesystem.

**Interfaces:**
- Consumes: everything from Tasks 1–3.

Throughout: **128755** is the main store's file count measured 2026-07-24. Any check that returns a different number means something deleted through a junction — stop and fix before continuing.

- [ ] **Step 1: Link a throwaway worktree and confirm the build works through the junction**

```powershell
$main  = 'C:\Users\John Patrick Mandal\Desktop\samurai_cart_v3'
$drift = 'C:\Users\John Patrick Mandal\Desktop\samurai_cart_v3 worktrees\wt-swap-proof'
git -C $main -c core.longpaths=true worktree add --detach -q $drift master
pwsh -File "C:\Users\John Patrick Mandal\scripts\samurai-sync-frontend-deps.ps1" -WorktreePath $drift
"link exit code: $LASTEXITCODE"
```
Expected: `Frontend deps linked -> ...` (the `link` path), `link exit code: 0`.

Then the build — this is what the whole change exists to unblock:
```powershell
Push-Location "C:\Users\John Patrick Mandal\Desktop\samurai_cart_v3 worktrees\wt-swap-proof\frontend"
npm run build; "build exit code: $LASTEXITCODE"
Pop-Location
```
Expected: `build exit code: 0`, roughly 4 minutes, route table printed, and no `externalDir` or module-resolution error. (This was proven pre-design on a detached master worktree; re-confirming here catches any regression in how the junction gets created.)

- [ ] **Step 2: Confirm the `noop` and error exit codes**

```powershell
$drift = 'C:\Users\John Patrick Mandal\Desktop\samurai_cart_v3 worktrees\wt-swap-proof'
pwsh -File "C:\Users\John Patrick Mandal\scripts\samurai-sync-frontend-deps.ps1" -WorktreePath $drift
"noop exit code: $LASTEXITCODE"
pwsh -File "C:\Users\John Patrick Mandal\scripts\samurai-sync-frontend-deps.ps1"
"missing-arg exit code: $LASTEXITCODE"
pwsh -File "C:\Users\John Patrick Mandal\scripts\samurai-sync-frontend-deps.ps1" -WorktreePath "$env:TEMP"
"no-lockfile exit code: $LASTEXITCODE"
```
Expected: `Frontend deps already provisioned (junction) -- nothing to do.` with `noop exit code: 0`; `missing-arg exit code: 1` (real error); `no-lockfile exit code: 0` (safe intentional skip). This is the exit-code contract `/start-ticket` step 7b depends on.

- [ ] **Step 3: Force lockfile drift and record the baseline**

Commit a trivial change to `package-lock.json` inside the throwaway worktree so its *committed* blob hash differs from the main checkout's:

```powershell
$drift = 'C:\Users\John Patrick Mandal\Desktop\samurai_cart_v3 worktrees\wt-swap-proof'
Add-Content "$drift\frontend\package-lock.json" ''
git -C $drift add frontend/package-lock.json
git -C $drift -c user.email=john@gogo-it-lab.com -c user.name=patrick-gogo commit -qm 'test: force lockfile drift'
(Get-ChildItem "C:\Users\John Patrick Mandal\Desktop\samurai_cart_v3\frontend\node_modules" -Recurse -File | Measure-Object).Count
```
Expected: `128755` — the baseline to compare against after the swap.

- [ ] **Step 4: Run the swap and confirm the shared store was not touched**

```powershell
$drift = 'C:\Users\John Patrick Mandal\Desktop\samurai_cart_v3 worktrees\wt-swap-proof'
pwsh -File "C:\Users\John Patrick Mandal\scripts\samurai-sync-frontend-deps.ps1" -WorktreePath $drift
"swap exit code: $LASTEXITCODE"
(Get-Item "$drift\frontend\node_modules" -Force).LinkType
(Get-ChildItem "C:\Users\John Patrick Mandal\Desktop\samurai_cart_v3\frontend\node_modules" -Recurse -File | Measure-Object).Count
```
Expected: the `Dependency set no longer matches ... unlinking, then installing privately` message, then `npm ci` runs to completion with `swap exit code: 0`; `LinkType` prints empty (a real directory, not a junction); and the main store count is still **128755**.

A count other than 128755 means `npm ci` wrote through the junction — stop and fix the unlink ordering before going further.

- [ ] **Step 5: Verify `-Reclaim`**

The swap just left a real private `node_modules` behind — exactly the state `-Reclaim` exists to convert. Undo the drift commit so the lockfiles match again (`-Reclaim` requires a proven match), then convert:

```powershell
$drift = 'C:\Users\John Patrick Mandal\Desktop\samurai_cart_v3 worktrees\wt-swap-proof'
git -C $drift reset --hard HEAD~1
pwsh -File "C:\Users\John Patrick Mandal\scripts\samurai-sync-frontend-deps.ps1" -WorktreePath $drift
"without -Reclaim: $LASTEXITCODE"
```
Expected: `Frontend deps already provisioned (realdir) -- nothing to do.`, exit 0. This proves the no-op is deliberate — a routine sync must never silently convert a private store into a shared one.

Now the explicit conversion:
```powershell
$drift = 'C:\Users\John Patrick Mandal\Desktop\samurai_cart_v3 worktrees\wt-swap-proof'
pwsh -File "C:\Users\John Patrick Mandal\scripts\samurai-sync-frontend-deps.ps1" -Reclaim -WorktreePath $drift
"reclaim exit code: $LASTEXITCODE"
(Get-Item "$drift\frontend\node_modules" -Force).LinkType
(Get-ChildItem "C:\Users\John Patrick Mandal\Desktop\samurai_cart_v3\frontend\node_modules" -Recurse -File | Measure-Object).Count
```
Expected: the reclaim message, then `reclaim exit code: 0`, `LinkType` prints `Junction`, main store still **128755**. The delete takes a while — removing ~128k files costs about what creating them does.

- [ ] **Step 6: Tear down the throwaway worktree**

The worktree currently holds a junction, so tear it down in the order Task 5 will automate — unlink first, then remove:

```powershell
$main  = 'C:\Users\John Patrick Mandal\Desktop\samurai_cart_v3'
$drift = 'C:\Users\John Patrick Mandal\Desktop\samurai_cart_v3 worktrees\wt-swap-proof'
. "C:\Users\John Patrick Mandal\scripts\samurai-junction-lib.ps1"
Remove-JunctionLink -Path "$drift\frontend\node_modules"
git -C $main worktree remove --force $drift
git -C $main worktree prune
"leftover dir: $(Test-Path $drift)"
(Get-ChildItem "$main\frontend\node_modules" -Recurse -File | Measure-Object).Count
git -C $main worktree list
```
Expected: `leftover dir: False` (unlinking first is what avoids the dangling-junction shell), main store still **128755**, and `wt-swap-proof` gone from the list while the four real worktrees (`wt-V3-1150-*`, `wt-V3-1247-*`, `wt-V3-630-*`, and `Desktop\wt-V3-1151-*`) remain listed and untouched.

- [ ] **Step 7: Nothing to stage**

No files changed in this task. Do not run `git add`.

---

### Task 5: `samurai-cleanup-ticket.ps1` unlinks before removing (TDD)

**Files:**
- Modify: `C:\Users\John Patrick Mandal\scripts\samurai-cleanup-ticket.ps1`
- Create: `C:\Users\John Patrick Mandal\scripts\samurai-cleanup-ticket.Tests.ps1`

**Interfaces:**
- Consumes: `Test-IsJunction`, `Remove-JunctionLink` (Task 1).
- Produces: `Remove-WorktreeNodeModulesJunction([string]$WorktreePath) -> bool` (true if a junction was unlinked, false if there was nothing to do).

- [ ] **Step 1: Write the failing tests**

Create `C:\Users\John Patrick Mandal\scripts\samurai-cleanup-ticket.Tests.ps1`:

```powershell
# Dependency-free tests. Run: pwsh -NoProfile -File samurai-cleanup-ticket.Tests.ps1
. "$PSScriptRoot\samurai-cleanup-ticket.ps1" -NoRun

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

$sandbox = Join-Path $env:TEMP "cleanup-ticket-tests-$PID"
if (Test-Path $sandbox) { Remove-Item -LiteralPath $sandbox -Recurse -Force }
New-Item -ItemType Directory $sandbox -Force | Out-Null

try {
    # --- Find-TicketWorktree (previously untested) ---
    New-Item -ItemType Directory (Join-Path $sandbox 'wt-V3-999-some-slug') -Force | Out-Null
    Assert 'find: matches wt-<key>-*' {
        (Find-TicketWorktree -Key 'V3-999' -BaseDir $sandbox) -eq (Join-Path $sandbox 'wt-V3-999-some-slug')
    }
    Assert 'find: no match -> null' { $null -eq (Find-TicketWorktree -Key 'V3-000' -BaseDir $sandbox) }
    New-Item -ItemType Directory (Join-Path $sandbox 'wt-V3-999-other-slug') -Force | Out-Null
    Assert 'find: ambiguous match throws' {
        try { Find-TicketWorktree -Key 'V3-999' -BaseDir $sandbox | Out-Null; $false } catch { $true }
    }

    # --- Remove-WorktreeNodeModulesJunction ---
    $store = Join-Path $sandbox 'store'
    New-Item -ItemType Directory $store -Force | Out-Null
    Set-Content (Join-Path $store 'canary.txt') 'must survive'

    $wtLinked = Join-Path $sandbox 'wt-linked'
    New-Item -ItemType Directory (Join-Path $wtLinked 'frontend') -Force | Out-Null
    New-JunctionLink -Path (Join-Path $wtLinked 'frontend\node_modules') -Target $store

    Assert 'unlink: reports true when a junction was removed' {
        (Remove-WorktreeNodeModulesJunction $wtLinked) -eq $true
    }
    Assert 'unlink: junction is gone' { -not (Test-Path (Join-Path $wtLinked 'frontend\node_modules')) }
    Assert 'unlink: STORE SURVIVES'   { Test-Path (Join-Path $store 'canary.txt') }

    # A real node_modules must never be deleted by cleanup -- only junctions are ours to remove.
    $wtReal = Join-Path $sandbox 'wt-real'
    New-Item -ItemType Directory (Join-Path $wtReal 'frontend\node_modules') -Force | Out-Null
    Set-Content (Join-Path $wtReal 'frontend\node_modules\keep.txt') 'private store'
    Assert 'unlink: reports false for a real dir' { (Remove-WorktreeNodeModulesJunction $wtReal) -eq $false }
    Assert 'unlink: real dir untouched' { Test-Path (Join-Path $wtReal 'frontend\node_modules\keep.txt') }

    $wtNone = Join-Path $sandbox 'wt-none'
    New-Item -ItemType Directory (Join-Path $wtNone 'frontend') -Force | Out-Null
    Assert 'unlink: reports false when absent' { (Remove-WorktreeNodeModulesJunction $wtNone) -eq $false }
} finally {
    Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($script:ran -eq 0) { Write-Host 'NO TESTS RAN' -ForegroundColor Red; exit 1 }
if ($script:fails) { Write-Host "$($script:fails)/$($script:ran) FAILED" -ForegroundColor Red; exit 1 } else { Write-Host "ALL $($script:ran) PASS" -ForegroundColor Green }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:
```powershell
pwsh -NoProfile -File "C:\Users\John Patrick Mandal\scripts\samurai-cleanup-ticket.Tests.ps1"
```
Expected: FAIL — `Remove-WorktreeNodeModulesJunction` is not defined. `New-JunctionLink` will also be undefined at this point, because `samurai-cleanup-ticket.ps1` does not dot-source the junction lib until Step 3; both are expected RED failures. (If it instead *hangs asking for `Key`*, that is the Mandatory-parameter trap; Step 3 fixes it.)

- [ ] **Step 3: Drop `Mandatory`, dot-source the lib, add the function and the cleanup step**

In `C:\Users\John Patrick Mandal\scripts\samurai-cleanup-ticket.ps1`, replace the `param()` block and the dot-source (currently lines 5–14) with:

```powershell
# NOTE: Key is deliberately NOT [Parameter(Mandatory)] -- mandatory binding fires on dot-source,
# so `. this.ps1 -NoRun` would prompt for it and hang a non-interactive test run. Validated
# inside Invoke-SamuraiCleanupTicket instead.
param(
    [string]$Key,
    [switch]$NoRun
)

. "$PSScriptRoot\samurai-testdb-lib.ps1"
. "$PSScriptRoot\samurai-junction-lib.ps1"

$script:WorktreesRoot = 'C:\Users\John Patrick Mandal\Desktop\samurai_cart_v3 worktrees'
$script:MainRepo = 'C:\Users\John Patrick Mandal\Desktop\samurai_cart_v3'
```

Add this function after `Find-TicketWorktree`:

```powershell
# Unlink before `git worktree remove`. Removing a worktree with a live junction leaves a
# dangling junction shell behind and an orphan directory to chase; unlinking first lets git
# complete cleanly. Only ever removes junctions -- a real private node_modules is left alone.
function Remove-WorktreeNodeModulesJunction([string]$WorktreePath) {
    $nm = Join-Path $WorktreePath 'frontend\node_modules'
    if (-not (Test-IsJunction $nm)) { return $false }
    Remove-JunctionLink -Path $nm
    return $true
}
```

Then, inside `Invoke-SamuraiCleanupTicket`, insert the unlink immediately before the `git worktree remove` call:

```powershell
        if (Remove-WorktreeNodeModulesJunction $worktreePath) {
            Write-Host 'Unlinked frontend/node_modules junction (shared store untouched).' -ForegroundColor Cyan
        }
        Write-Host "Removing worktree $worktreePath ..." -ForegroundColor Cyan
        git -C $script:MainRepo worktree remove $worktreePath
```

Finally, update the invocation line at the bottom of the file to validate the key first:

```powershell
if (-not $NoRun) {
    if (-not $Key) { Write-Host 'Key is required (e.g. -Key V3-1193).' -ForegroundColor Red; exit 1 }
    Invoke-SamuraiCleanupTicket -Key $Key
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run:
```powershell
pwsh -NoProfile -File "C:\Users\John Patrick Mandal\scripts\samurai-cleanup-ticket.Tests.ps1"
```
Expected: `ALL 9 PASS`

Also re-run the other two suites to confirm the shared lib didn't break them:
```powershell
pwsh -NoProfile -File "C:\Users\John Patrick Mandal\scripts\samurai-junction-lib.Tests.ps1"
pwsh -NoProfile -File "C:\Users\John Patrick Mandal\scripts\samurai-testdb-lib.Tests.ps1"
```
Expected: `ALL 11 PASS` and `ALL 8 PASS`.

- [ ] **Step 5: Verify against a real junctioned worktree**

The sandbox tests use fake directories; this confirms the ordering works against real git. Exercise `Remove-WorktreeNodeModulesJunction` + `git worktree remove` directly rather than the full `Invoke-SamuraiCleanupTicket`, which would also try to drop a Postgres test DB and so needs Docker up — out of scope for verifying this change.

```powershell
$main = 'C:\Users\John Patrick Mandal\Desktop\samurai_cart_v3'
$wt   = 'C:\Users\John Patrick Mandal\Desktop\samurai_cart_v3 worktrees\wt-cleanup-proof'
git -C $main -c core.longpaths=true worktree add --detach -q $wt master
pwsh -File "C:\Users\John Patrick Mandal\scripts\samurai-sync-frontend-deps.ps1" -WorktreePath $wt
. "C:\Users\John Patrick Mandal\scripts\samurai-cleanup-ticket.ps1" -NoRun
"unlinked: $(Remove-WorktreeNodeModulesJunction $wt)"
git -C $main worktree remove --force $wt
git -C $main worktree prune
"leftover dir: $(Test-Path $wt)"
(Get-ChildItem "$main\frontend\node_modules" -Recurse -File | Measure-Object).Count
```
Expected: `unlinked: True`, `leftover dir: False`, main store still **128755**.

Then confirm the reverse ordering is what the guard protects against — removing *without* unlinking first leaves the dangling shell this task exists to prevent:
```powershell
$main = 'C:\Users\John Patrick Mandal\Desktop\samurai_cart_v3'
$wt   = 'C:\Users\John Patrick Mandal\Desktop\samurai_cart_v3 worktrees\wt-cleanup-proof2'
git -C $main -c core.longpaths=true worktree add --detach -q $wt master
pwsh -File "C:\Users\John Patrick Mandal\scripts\samurai-sync-frontend-deps.ps1" -WorktreePath $wt
git -C $main worktree remove --force $wt
"leftover dir: $(Test-Path $wt)"
(Get-ChildItem "$main\frontend\node_modules" -Recurse -File | Measure-Object).Count
```
Expected: `leftover dir: True` — the orphan shell, demonstrating why the unlink comes first. The main store must still read **128755**; git does not delete through a junction, but confirm it, because this is the failure mode that would cost the whole store.

Clean up the leftover:
```powershell
$main = 'C:\Users\John Patrick Mandal\Desktop\samurai_cart_v3'
$wt   = 'C:\Users\John Patrick Mandal\Desktop\samurai_cart_v3 worktrees\wt-cleanup-proof2'
. "C:\Users\John Patrick Mandal\scripts\samurai-junction-lib.ps1"
Remove-JunctionLink -Path "$wt\frontend\node_modules"
Remove-Item -LiteralPath $wt -Recurse -Force
git -C $main worktree prune
git -C $main worktree list
```
Expected: only the main checkout and the four real worktrees remain.

- [ ] **Step 6: Commit (feature branch only)**

```powershell
git -C "C:\Users\John Patrick Mandal\scripts" rev-parse --abbrev-ref HEAD
git -C "C:\Users\John Patrick Mandal\scripts" add samurai-cleanup-ticket.ps1 samurai-cleanup-ticket.Tests.ps1
git -C "C:\Users\John Patrick Mandal\scripts" commit -m "fix(scripts): unlink node_modules junction before removing a ticket worktree"
```

The first command must print `feature/worktree-deps-junction`. If it prints `master`, stop and report — do not commit.

Note: this file already carried an uncommitted `$script:Desktop` → `$script:WorktreesRoot` change before your task began. Keep it — it is intentional prior work and will ride along in this commit.

---

### Task 6: `/start-ticket` hand-off wording

The command currently promises `copied from main checkout`, which junctions make false.

**Files:**
- Modify: `C:\Users\John Patrick Mandal\.claude\commands\start-ticket.md`

**Interfaces:** none — documentation only.

- [ ] **Step 1: Update the References entry (line 15)**

Replace:
```markdown
- **Frontend deps fast-path:** `~/scripts/samurai-sync-frontend-deps.ps1` — copies a known-good `frontend/node_modules` into the new worktree instead of a full `npm install`, used in step 7b below.
```
with:
```markdown
- **Frontend deps fast-path:** `~/scripts/samurai-sync-frontend-deps.ps1` — links the new worktree's `frontend/node_modules` to the main checkout's store via an NTFS junction (~35 ms, no copy), falling back to `npm ci` when the worktree's dependency set differs. Used in step 7b below.
```

- [ ] **Step 2: Rewrite step 7b's rationale (lines 136–149)**

Replace the paragraph beginning `node_modules` is gitignored, so `git worktree add` never populates it — through the end of that rationale (up to, but not including, the `**Only run this when the ticket plausibly touches frontend**` paragraph) with:

```markdown
`node_modules` is gitignored, so `git worktree add` never populates it — a brand-new worktree starts with none at all. The main checkout's store is ~128,755 files / 0.66 GB, so *copying* it costs minutes (the cost is the file count, not the bytes), and a full `npm install` is slower still. Instead the script points the worktree's `frontend/node_modules` at the main checkout's store with an NTFS junction — measured at 35 ms — which is safe precisely when both sides' committed `package-lock.json` blobs match, i.e. the dependency sets are provably identical.
```

- [ ] **Step 3: Update both hand-off blocks (lines 257–258 and 374–375)**

In each block, replace the two `{if step 7b ...}` lines with these three:

```markdown
{if step 7b linked: "✅ Frontend deps: linked to the main checkout via junction (no copy, no npm install needed)."}
{if step 7b installed: "✅ Frontend deps: installed with `npm ci` (this branch's dependency set differs from master, so it has its own private store)."}
{if step 7b skipped: "⚠️ Frontend deps: not provisioned ({reason from the script's output}) — run `npm ci` in frontend/ before starting the dev server there."}
```

- [ ] **Step 4: Update the safety bullets (lines 407–409)**

Replace the bullet beginning `- **Frontend deps copy is never trusted blindly.**` with:

```markdown
- **Frontend deps linking is never trusted blindly.** `samurai-sync-frontend-deps.ps1` compares `package-lock.json`'s committed git blob hash (not raw file bytes — a prior partial install can leave that file locally dirty even when the actual dependency set is unchanged) between the main checkout and the new worktree, and checks the source store looks healthy, before linking anything. If either check fails it installs privately with `npm ci` instead, and says which path it took — never silently shares a store that might be wrong.
- **The junction is a shared store, not a copy.** Every junctioned worktree reads the *same* `node_modules`. Running a bare `npm install <pkg>` inside one mutates it for all of them. Recovery is `npm ci` in the main checkout. Lockfile *drift* is detected and auto-swapped to a private install; ad-hoc installs are not detectable.
```

Leave the `- **Frontend deps copy is conditional, not unconditional.**` bullet in place — the `frontend/`-mention trigger is unchanged — but change its first two words to `Frontend deps provisioning`.

- [ ] **Step 5: Verify no stale wording remains**

Run:
```powershell
Select-String -Path "C:\Users\John Patrick Mandal\.claude\commands\start-ticket.md" -Pattern 'copied from main checkout|copies a known-good|robocopy'
```
Expected: no matches.

- [ ] **Step 6: Nothing to stage in `~/scripts`**

`~/.claude/commands/` is not part of the `~/scripts` git repo. Report the edit in the hand-off; there is nothing to `git add`.

---

## Post-implementation (user-initiated, not part of the TDD loop)

- **Reclaim disk.** Once Tasks 1–5 are green, `wt-V3-1150-incoming-call-filter-jst-fix` and `wt-V3-630-conflict-resolve` still hold real copies with matching lockfiles (~1.3 GB). Convert on request only:
  ```powershell
  pwsh -File "C:\Users\John Patrick Mandal\scripts\samurai-sync-frontend-deps.ps1" -Reclaim -WorktreePath "C:\Users\John Patrick Mandal\Desktop\samurai_cart_v3 worktrees\wt-V3-1150-incoming-call-filter-jst-fix"
  ```
  These are live worktrees with concurrent agent sessions — ask before touching either.
- **Commits.** Every task stages only. Fire the prepared messages when instructed.
