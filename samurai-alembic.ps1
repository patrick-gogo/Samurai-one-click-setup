# samurai-alembic.ps1 — run alembic against the live dev DB using the CURRENT directory's
# code (main checkout or a worktree), instead of `docker compose exec api alembic ...`
# (which always uses whichever checkout the long-running api container's volume was
# mounted from at startup — never the worktree you're actually standing in).
#
# Mirrors samurai-test.ps1's trick: a throwaway `docker run --rm` container bind-mounting
# wherever you run this from, on the same shared network so it can still reach the real
# `db` container. Unlike samurai-test.ps1, this targets the ONE shared live dev database
# (samurai_cart) — migrations aren't per-ticket, they're one ordered history against one DB.
#
# Usage (run from inside the worktree/checkout whose migrations you want to apply):
#   samurai-alembic upgrade head
#   samurai-alembic current
#   samurai-alembic heads
#
# Caveat: because this hits the one shared dev DB regardless of which worktree you run it
# from, running migrations from two worktrees with un-merged, divergent migration chains
# back to back can leave alembic_version in a confusing state. Same risk that already
# exists with docker compose exec — just easier to actually hit now that running against
# a worktree's own migration file is simple. Coordinate before doing this from two
# unmerged branches in a row.

param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$AlembicArgs
)

$repoRoot = (git rev-parse --show-toplevel 2>$null) -replace '/', '\'
if (-not $repoRoot) {
    Write-Host 'Not inside a git repository.' -ForegroundColor Red
    return
}

Write-Host "Running alembic against the live dev DB, using code from $repoRoot\backend ..." -ForegroundColor Cyan

docker run --rm --network samurai_cart_network `
    -v "${repoRoot}\backend:/app" `
    -e "DATABASE_URL=postgresql+asyncpg://samurai:samurai_dev_password@db:5432/samurai_cart" `
    -w /app `
    samurai_cart_v3-api:latest `
    alembic @AlembicArgs
