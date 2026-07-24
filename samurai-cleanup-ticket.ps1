# samurai-cleanup-ticket.ps1 — remove a finished ticket's worktree AND its isolated test DB
# in one step. Manual/opt-in — run whenever you've decided a ticket is really done (typically
# after /wrap-ticket has already flipped the vault status; /wrap-ticket itself never touches
# branches or worktrees). Dot-source with -NoRun for tests.
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

function Find-TicketWorktree([string]$Key, [string]$BaseDir) {
    $found = @(Get-ChildItem -Path $BaseDir -Directory -Filter "wt-$Key-*" -ErrorAction SilentlyContinue)
    if ($found.Count -eq 0) { return $null }
    if ($found.Count -gt 1) { throw "Multiple worktrees match wt-$Key-*: $($found.FullName -join ', ')" }
    return $found[0].FullName
}

# Unlink before `git worktree remove`. Removing a worktree with a live junction leaves a
# dangling junction shell behind and an orphan directory to chase; unlinking first lets git
# complete cleanly. Only ever removes junctions -- a real private node_modules is left alone.
function Remove-WorktreeNodeModulesJunction([string]$WorktreePath) {
    $nm = Join-Path $WorktreePath 'frontend\node_modules'
    if (-not (Test-IsJunction $nm)) { return $false }
    Remove-JunctionLink -Path $nm
    return $true
}

function Invoke-SamuraiCleanupTicket {
    param([string]$Key)

    if ($Key -notmatch '^[A-Za-z][A-Za-z0-9]*-\d+$') {
        Write-Host "'$Key' is not a valid ticket key (expected e.g. V3-1193)." -ForegroundColor Red
        return
    }

    $worktreePath = Find-TicketWorktree -Key $Key -BaseDir $script:WorktreesRoot
    if (-not $worktreePath) {
        Write-Host "No worktree found matching wt-$Key-* under $script:WorktreesRoot." -ForegroundColor Yellow
    } else {
        $unlinked = Remove-WorktreeNodeModulesJunction $worktreePath
        if ($unlinked) {
            Write-Host 'Unlinked frontend/node_modules junction (shared store untouched).' -ForegroundColor Cyan
        }
        Write-Host "Removing worktree $worktreePath ..." -ForegroundColor Cyan
        git -C $script:MainRepo worktree remove $worktreePath
        if ($LASTEXITCODE -ne 0) {
            # Unlinking happens first, so a failure here leaves the worktree without node_modules.
            $note = if ($unlinked) { ' Its frontend/node_modules junction is already unlinked -- re-run samurai-sync-frontend-deps.ps1 if you keep working in it.' } else { '' }
            Write-Host "git worktree remove failed -- worktree left in place. Resolve manually (e.g. commit/stash changes) and re-run.$note" -ForegroundColor Red
            return
        }
        Write-Host 'Worktree removed.' -ForegroundColor Green
    }

    $dbName = "samurai_cart_test_$(ConvertTo-TestDbSuffix $Key)"
    Write-Host "Dropping test database $dbName (if present) ..." -ForegroundColor Cyan
    Remove-TestDb $dbName
    Write-Host 'Done.' -ForegroundColor Green
}

if (-not $NoRun) {
    if (-not $Key) { Write-Host 'Key is required (e.g. -Key V3-1193).' -ForegroundColor Red; exit 1 }
    Invoke-SamuraiCleanupTicket -Key $Key
}
