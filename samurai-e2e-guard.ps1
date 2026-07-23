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

if (-not $NoRun) {
    # Main entrypoint lands in Task 4 — placeholder guard so a bare invocation before
    # this script is complete fails loudly instead of silently doing nothing.
    Write-Host 'samurai-e2e-guard: not yet fully implemented (Task 4 pending).' -ForegroundColor Yellow
}
