# samurai-migration-lib.ps1 — detect when the shared dev DB's alembic stamp no longer matches
# the migration files in the current checkout. Dot-sourced by samurai-dash.ps1 and
# samurai-dev.ps1 — no side effects on load.
#
# The failure this exists to catch: alembic_version is global to the one shared dev DB, but
# migration FILES are per-branch. Migrate while on a feature branch, switch away, and the DB is
# left stamped with a revision that no longer exists in the tree. Every alembic command then
# fails on the same lookup — current, stamp AND upgrade — so migrations silently stop applying
# and the app 500s wherever a model declares a column the DB never got. Nothing else in the dev
# setup goes red: an API healthcheck on /docs never touches the DB and stays green throughout.
#
# The orphan check is deliberately file-based rather than shelling out to alembic, so it costs
# one fast psql call and a directory read, and is cheap enough for every dashboard refresh.

# --- pure parsing / graph helpers (unit-tested) ---------------------------------------------

# Matches `revision = "x"`, `revision: str = "x"`, and the single-quoted variants, while never
# matching a down_revision line (the leading anchor plus \b does the work).
# The optional type annotation must not cross a newline. Allowing it to means a docstring line
# beginning `revision:` / `down_revision:` with no `=` runs on to the next assignment and steals
# its value — one real migration file does exactly that.
function Get-RevisionId([string]$Text) {
    if ($Text -match '(?m)^\s*revision(?:\s*:\s*[^=\r\n]+?)?\s*=\s*[''"]([^''"]+)[''"]') { return $Matches[1] }
    return $null
}

# Returns 0 parents (base), 1 (normal), or 2+ (merge point).
# Merge points in this repo write the tuple across several lines, so the parenthesised form is
# matched non-greedily up to its closing paren. Same-line values stop at the newline. Missing
# the multi-line form leaves those parents unclaimed and invents phantom heads.
function Get-DownRevisionIds([string]$Text) {
    if ($Text -notmatch '(?m)^\s*down_revision(?:\s*:\s*[^=\r\n]+?)?\s*=\s*(\([\s\S]*?\)|[^\r\n]+)') { return @() }
    $rhs = $Matches[1]
    $ids = [regex]::Matches($rhs, '[''"]([^''"]+)[''"]') | ForEach-Object { $_.Groups[1].Value }
    return @($ids)
}

# A head is a revision that nobody else claims as a parent.
function Get-MigrationHeads($Graph) {
    if (-not $Graph -or $Graph.Count -eq 0) { return @() }
    $claimed = New-Object System.Collections.Generic.HashSet[string]
    foreach ($n in $Graph) { foreach ($p in $n.Parents) { [void]$claimed.Add($p) } }
    return @($Graph | Where-Object { -not $claimed.Contains($_.Revision) } | ForEach-Object { $_.Revision })
}

# ok | behind | wedged | unknown.
# `unknown` is the deliberate fallback whenever inputs are incomplete, so a container that is
# merely down never renders as the alarming `wedged`.
function Get-MigrationState {
    param([string]$Stamped, [string[]]$Known, [string[]]$Heads)
    if ([string]::IsNullOrWhiteSpace($Stamped)) { return 'unknown' }
    if (-not $Known -or $Known.Count -eq 0)     { return 'unknown' }
    if ($Known -notcontains $Stamped)           { return 'wedged' }
    if (-not $Heads -or $Heads.Count -eq 0)     { return 'unknown' }
    if ($Heads -contains $Stamped)              { return 'ok' }
    return 'behind'
}

# --- thin I/O wrappers (not unit-tested; they only gather inputs for the pure helpers) -------

function Get-StampedRevision {
    $out = docker exec samurai_cart_db psql -U samurai -d samurai_cart -tAc `
        'SELECT version_num FROM alembic_version' 2>$null
    return (($out | Out-String).Trim())
}

function Get-MigrationGraph([string]$VersionsDir) {
    if (-not (Test-Path $VersionsDir)) { return @() }
    $nodes = foreach ($f in Get-ChildItem -Path $VersionsDir -Filter '*.py' -File) {
        $text = Get-Content -Path $f.FullName -Raw
        $rev = Get-RevisionId $text
        if ($rev) {
            [pscustomobject]@{ Revision = $rev; Parents = (Get-DownRevisionIds $text) }
        }
    }
    return @($nodes)
}

# Composed check the dashboard and startup banner both call.
function Get-MigrationHealth([string]$RepoRoot) {
    $versions = Join-Path $RepoRoot 'backend\alembic\versions'
    $graph    = Get-MigrationGraph $versions
    $stamped  = Get-StampedRevision
    $known    = @($graph | ForEach-Object { $_.Revision })
    $heads    = Get-MigrationHeads $graph
    $state    = Get-MigrationState -Stamped $stamped -Known $known -Heads $heads

    $detail = switch ($state) {
        'wedged'  { "stamp '$stamped' is not in this checkout - alembic cannot run at all" }
        'behind'  { "stamp '$stamped' is behind head '$($heads -join ",")' - run: samurai-alembic upgrade head" }
        'ok'      { "at head" }
        default   { 'could not determine (db container down?)' }
    }
    return [pscustomobject]@{ State = $state; Stamped = $stamped; Heads = $heads; Detail = $detail }
}
