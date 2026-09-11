# samurai-sync-frontend-deps.ps1 — provision a worktree's frontend/node_modules by linking it
# to the main checkout's shared store via an NTFS directory junction (near-instant, no copy).
# node_modules is gitignored, so `git worktree add` never populates it, and a full network
# install is slow and prone to interruption/corruption on Windows (antivirus file-locking
# mid-extraction, huge packages like @mui/icons-material). Compares git's own committed blob
# hash for package-lock.json between the source repo and the worktree (NOT raw filesystem
# content — a partial/broken install can leave a dirty working-copy lockfile that would
# falsely look "different" even when the actual dependency set is identical). Whenever the
# lock hashes don't provably match, falls back to a private `npm ci` install in that worktree
# instead of linking. Dot-source with -NoRun for tests.
# NOTE: WorktreePath is deliberately NOT [Parameter(Mandatory)] -- mandatory binding fires on
# dot-source, so `. this.ps1 -NoRun` would prompt for it and hang a non-interactive test run.
# Validated inside Invoke-SamuraiSyncFrontendDeps instead.
param(
    [string]$WorktreePath,
    [switch]$Reclaim,
    [switch]$NoRun
)

. "$PSScriptRoot\samurai-junction-lib.ps1"

$script:MainRepo = 'C:\Users\john\Desktop\samurai_cart_v3'

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

function Invoke-NpmCi([string]$WorktreePath) {
    Write-Host "Running npm ci in $WorktreePath\frontend -- this worktree's dependency set differs from the main checkout, so it needs its own store. Expect several minutes." -ForegroundColor Cyan
    # Structural guard, not per-caller: npm must never write through the shared-store junction.
    $nm = "$WorktreePath\frontend\node_modules"
    if (Test-IsJunction $nm) {
        Write-Host 'Unlinking the shared-store junction before npm ci (npm must never write through it).' -ForegroundColor Yellow
        Remove-JunctionLink -Path $nm
    }
    Push-Location "$WorktreePath\frontend" -ErrorAction Stop
    # npm ci's stdout (progress, deprecation notices, postinstall output) must never join this
    # function's own output stream -- an unredirected native command's stdout would land in the
    # array that `exit (Invoke-NpmCi ...)` receives, and `exit` given an array always yields 0.
    # Out-Host sends it straight to the console instead, so the only pipeline-visible value left
    # is the `return` below. $LASTEXITCODE is read immediately after, before anything else can run.
    try { npm ci 2>&1 | Out-Host; $code = $LASTEXITCODE } finally { Pop-Location }
    if ($code -ne 0) {
        Write-Host "npm ci failed (exit $code) -- frontend deps are NOT ready in this worktree." -ForegroundColor Red
        return 1
    }
    Write-Host 'Frontend deps installed (private store).' -ForegroundColor Green
    return 0
}

function Invoke-SamuraiSyncFrontendDeps {
    param([string]$WorktreePath, [switch]$Reclaim)

    # Every terminal path sets an explicit exit code: 0 = provisioned OR a safe intentional
    # skip, 1 = a real error -- so any future caller can branch on it (no consumer does yet).
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

    # WorktreePath is hand-typed and a prefix of every worktree path under the same Desktop
    # folder -- tab completion can offer the main checkout itself. -Reclaim there would recurse
    # -delete the one shared store every worktree junctions into.
    if ([System.IO.Path]::GetFullPath($destStore).TrimEnd('\') -eq [System.IO.Path]::GetFullPath($sourceStore)) {
        Write-Host "WorktreePath resolves to the main checkout -- refusing to operate on the shared store itself." -ForegroundColor Red
        exit 1
    }

    $sourceHash = Get-CommittedBlobHash $script:MainRepo 'frontend/package-lock.json'
    $targetHash = Get-CommittedBlobHash $WorktreePath 'frontend/package-lock.json'
    if (-not $sourceHash -or -not $targetHash) {
        Write-Host "Could not read package-lock.json's committed blob hash from one side -- can't prove the dependency sets match, so falling back to a private install." -ForegroundColor Yellow
        exit (Invoke-NpmCi $WorktreePath)
    }

    $lockMatch     = ($sourceHash -eq $targetHash)
    $sourceHealthy = Test-SourceNodeModulesHealthy $script:MainRepo

    # Any reparse point (junction, symlink, ...) counts as a link, never 'realdir' --
    # 'realdir' is the only state -Reclaim is allowed to recurse-delete.
    $destItem  = if (Test-Path -LiteralPath $destStore) { Get-Item -LiteralPath $destStore -Force -ErrorAction SilentlyContinue } else { $null }
    $destState = if (-not $destItem)      { 'absent' }
                 elseif ($destItem.LinkType) { 'junction' }
                 else                     { 'realdir' }

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

if (-not $NoRun) { Invoke-SamuraiSyncFrontendDeps -WorktreePath $WorktreePath -Reclaim:$Reclaim }
