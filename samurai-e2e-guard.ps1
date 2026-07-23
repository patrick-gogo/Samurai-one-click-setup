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

if (-not $NoRun) {
    # Main entrypoint lands in Task 4 — placeholder guard so a bare invocation before
    # this script is complete fails loudly instead of silently doing nothing.
    Write-Host 'samurai-e2e-guard: not yet fully implemented (Task 4 pending).' -ForegroundColor Yellow
}
