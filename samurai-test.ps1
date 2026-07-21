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
