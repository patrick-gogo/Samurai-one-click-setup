# samurai-sync-frontend-deps.ps1 — copy a known-good frontend/node_modules into a worktree
# instead of a full npm install. node_modules is gitignored, so `git worktree add` never
# populates it — every fresh worktree otherwise pays a full network install, which on Windows
# is slow and prone to interruption/corruption (antivirus file-locking mid-extraction, huge
# packages like @mui/icons-material). Compares git's own committed blob hash for
# package-lock.json between the source repo and the worktree (NOT raw filesystem content —
# a partial/broken install can leave a dirty working-copy lockfile that would falsely look
# "different" even when the actual dependency set is identical). Falls back to leaving
# node_modules alone whenever the fast path isn't provably safe. Dot-source with -NoRun for
# tests.
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

function Get-CommittedBlobHash([string]$RepoPath, [string]$RelativePath) {
    $hash = git -C $RepoPath rev-parse "HEAD:$RelativePath" 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    return $hash.Trim()
}

function Test-SourceNodeModulesHealthy([string]$RepoPath) {
    return Test-Path "$RepoPath\frontend\node_modules\.package-lock.json"
}

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

function Invoke-SamuraiSyncFrontendDeps {
    param([string]$WorktreePath)

    # Every terminal path below sets an explicit exit code (0 = copied OR a safe, intentional
    # skip; 1 = a real error) rather than falling through with whatever exit code the last
    # internal command happened to leave -- same reasoning as the robocopy normalization below.
    if (-not (Test-Path "$WorktreePath\frontend\package-lock.json")) {
        Write-Host "No frontend/package-lock.json in $WorktreePath -- nothing to sync." -ForegroundColor Yellow
        exit 0
    }

    $sourceHash = Get-CommittedBlobHash $script:MainRepo 'frontend/package-lock.json'
    $targetHash = Get-CommittedBlobHash $WorktreePath 'frontend/package-lock.json'

    if (-not $sourceHash -or -not $targetHash) {
        Write-Host "Could not read package-lock.json's committed blob hash from one side -- skipping fast copy. Run npm ci in $WorktreePath\frontend yourself." -ForegroundColor Yellow
        exit 0
    }

    if ($sourceHash -ne $targetHash) {
        Write-Host "package-lock.json differs (different commits/dependency sets) between the main checkout and this worktree -- skipping fast copy. Run npm ci in $WorktreePath\frontend yourself." -ForegroundColor Yellow
        exit 0
    }

    if (-not (Test-SourceNodeModulesHealthy $script:MainRepo)) {
        Write-Host "Main checkout's frontend/node_modules doesn't look healthy (no .package-lock.json) -- skipping fast copy. Run npm ci in $WorktreePath\frontend yourself." -ForegroundColor Yellow
        exit 0
    }

    Write-Host "Copying frontend/node_modules from the main checkout (committed lockfile blobs match, source looks healthy) ..." -ForegroundColor Cyan
    $sourcePath = "$script:MainRepo\frontend\node_modules"
    $destPath = "$WorktreePath\frontend\node_modules"
    # /MT:16 multi-threads the copy -- node_modules is many thousands of small files, and
    # robocopy's default single-threaded mode is dramatically slower for that shape than for
    # a few large files. /R:2 /W:1 caps retries so a transiently locked file (antivirus, a
    # stray process) doesn't hang the whole copy.
    robocopy $sourcePath $destPath /E /MT:16 /NFL /NDL /NJH /NJS /R:2 /W:1 | Out-Null
    $robocopyExitCode = $LASTEXITCODE
    # robocopy's own exit codes are a bitmask where 0-7 are all success (e.g. 1 = "files
    # copied OK") and only 8+ signals a real error -- but those non-zero "success" codes leak
    # out as this script's own process exit code otherwise, which makes any ordinary caller
    # (anything checking "exit code != 0 = failure") wrongly conclude the copy failed even
    # though it worked. Normalize explicitly so this script always exits 0 on success.
    if ($robocopyExitCode -ge 8) {
        Write-Host "robocopy reported errors (exit $robocopyExitCode) -- copy may be incomplete. Run npm ci in $WorktreePath\frontend to be safe." -ForegroundColor Red
        exit 1
    }
    Write-Host "Frontend deps copied." -ForegroundColor Green
    exit 0
}

if (-not $NoRun) { Invoke-SamuraiSyncFrontendDeps -WorktreePath $WorktreePath }
