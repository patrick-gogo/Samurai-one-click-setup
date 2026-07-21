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
