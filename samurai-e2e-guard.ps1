# samurai-e2e-guard.ps1 — local pre-merge guard mirroring samurai_cart_v3's real CI checks
# (pr-checks.yml's pr-validation job + e2e-smoke.yml's e2e-smoke job), so a broken PR is
# caught before it burns GitHub Actions minutes. Derives an isolated per-ticket e2e database
# via samurai-testdb-lib.ps1 (same pattern as samurai-test.ps1) since this script seeds real
# state (admin user, tenant, product data) that would otherwise collide across worktrees.
# Runs its own backend on an alternate port (:8099) so it never collides with an
# already-running local dev backend on :8000. The frontend can't be isolated the same way:
# frontend/playwright.config.ts hardcodes use.baseURL and webServer.port to :3000 and doesn't
# honor a base-URL env var, so for the smoke run Playwright starts and owns the production
# frontend itself on :3000 (via its webServer block) rather than this script starting one on
# an alternate port. If a local dev frontend already holds :3000, Playwright fails fast
# ("already used ... set reuseExistingServer") instead of silently testing against it.
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

function Invoke-E2eSmokeRun([string]$RepoRoot, [string]$DbUrl, [string]$TicketKey) {
    $suffix = ConvertTo-TestDbSuffix $TicketKey
    $containerName = "samurai_e2e_guard_api_$suffix"
    $backendPort = 8099
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
            # NEXT_PUBLIC_* vars are inlined into the client bundle by Next's webpack
            # DefinePlugin at build time only, so it's safe to drop this one now.
            Remove-Item Env:\NEXT_PUBLIC_E2E_AUTH_BYPASS -ErrorAction SilentlyContinue
            if ($buildExit -ne 0) {
                Remove-Item Env:\BACKEND_URL -ErrorAction SilentlyContinue
                throw 'Production frontend build failed'
            }

            # frontend/playwright.config.ts hardcodes `use.baseURL` and `webServer.port` to
            # http://localhost:3000 and does not read PLAYWRIGHT_BASE_URL (or any env var) for
            # baseURL, so the frontend can't be pointed at an alternate port from here.
            # Its `webServer` block (command keyed off process.env.CI, set below) starts
            # `npm run start` itself and owns that process's lifecycle, so this function does
            # not start or stop the frontend directly.
            #
            # BACKEND_URL must be set before `npm run build` (line 131 above): next.config.ts
            # rewrites() reads it at build time and bakes the /api/v1/:path* rewrite destination
            # into the build. It doesn't need to stay set through the Playwright run (the rewrite
            # is already baked in), but we keep it set for clarity. If BACKEND_URL were unset at
            # build time, the rewrite would default to 'http://localhost:8001', causing smoke tests
            # to proxy to the wrong backend instead of this run's isolated :8099 backend.
            #
            # webServer.reuseExistingServer is `!process.env.CI`, so with CI=true below it is
            # false: if :3000 is already held by a real local dev frontend, Playwright fails
            # fast ("already used ... set reuseExistingServer") rather than quietly running the
            # smoke suite against someone else's server.
            Write-Host 'Running Playwright @smoke suite (Playwright serves the frontend on :3000) ...' -ForegroundColor Cyan
            $env:CI = 'true'
            $env:E2E_ADMIN_EMAIL = 'admin@samurai-cart.com'
            $env:E2E_ADMIN_PASSWORD = 'admin123'
            npx playwright test --grep '@smoke' --pass-with-no-tests
            $smokeExit = $LASTEXITCODE
            Remove-Item Env:\BACKEND_URL, Env:\CI, Env:\E2E_ADMIN_EMAIL, Env:\E2E_ADMIN_PASSWORD -ErrorAction SilentlyContinue
            if ($smokeExit -ne 0) { throw 'Playwright @smoke suite failed' }

            return $true
        } finally {
            Pop-Location
        }
    } finally {
        Write-Host 'Stopping isolated backend ...' -ForegroundColor DarkGray
        docker stop $containerName 2>$null | Out-Null
    }
}

if (-not $NoRun) {
    # Main entrypoint lands in Task 4 — placeholder guard so a bare invocation before
    # this script is complete fails loudly instead of silently doing nothing.
    Write-Host 'samurai-e2e-guard: not yet fully implemented (Task 4 pending).' -ForegroundColor Yellow
}
