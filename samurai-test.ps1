# samurai-test.ps1 — run backend pytest against a per-ticket isolated test database.
# Derives the ticket key from the current worktree folder (wt-{KEY}-{slug}) or branch name,
# ensures samurai_cart_test_{key} exists, and runs pytest inside the shared api image with
# TEST_DATABASE_URL pointed at it — so concurrent test runs from different worktrees never
# race on the same schema. Dot-source with -NoRun for tests.
#
# Usage: samurai-test [-Ticket V3-XXXX] [pytest args...]
# Deliberately has no [Parameter(...)] attributes beyond nothing at all (a plain/simple
# function) — pytest's own flags (-k, -v, -m, ...) must never collide with a declared
# PowerShell parameter or an auto-added common parameter (-Verbose, -Debug, ...), which is
# exactly what happens the moment a script gains any [Parameter(...)] attribute.
param(
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

function Split-SamuraiTestArgs([string[]]$InputArgs) {
    $ticket = $null
    $rest = New-Object System.Collections.Generic.List[string]
    $i = 0
    while ($i -lt $InputArgs.Count) {
        if ($InputArgs[$i] -eq '-Ticket' -and ($i + 1) -lt $InputArgs.Count) {
            $ticket = $InputArgs[$i + 1]
            $i += 2
        } else {
            $rest.Add($InputArgs[$i])
            $i++
        }
    }
    return [pscustomobject]@{ Ticket = $ticket; PytestArgs = $rest.ToArray() }
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
        Write-Host "Could not determine a ticket key from '$repoRoot' or its branch. Pass -Ticket V3-XXXX explicitly." -ForegroundColor Red
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

if (-not $NoRun) {
    $parsed = Split-SamuraiTestArgs $args
    Invoke-SamuraiTest -Key $parsed.Ticket -PytestArgs $parsed.PytestArgs
}
