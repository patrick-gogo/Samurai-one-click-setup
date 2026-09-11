# Dependency-free tests. Run: pwsh -NoProfile -File samurai-migration-lib.Tests.ps1
. "$PSScriptRoot\samurai-migration-lib.ps1"

$script:fails = 0
$script:ran = 0
function Assert([string]$Msg, [scriptblock]$Cond) {
    $script:ran++
    $old = $ErrorActionPreference; $ErrorActionPreference = 'Stop'
    try {
        if (& $Cond) { Write-Host "PASS: $Msg" -ForegroundColor Green }
        else { $script:fails++; Write-Host "FAIL: $Msg" -ForegroundColor Red }
    } catch {
        $script:fails++; Write-Host "FAIL: $Msg -- $($_.Exception.Message)" -ForegroundColor Red
    } finally { $ErrorActionPreference = $old }
}

# --- Get-RevisionId: the three quoting styles that actually occur in backend/alembic/versions ---
Assert 'revision: plain double-quoted' {
    (Get-RevisionId 'revision = "20260626_recaptcha_language"') -eq '20260626_recaptcha_language'
}
Assert 'revision: typed `str` form' {
    (Get-RevisionId 'revision: str = "v3_1247_add_subscription_cancelled_by_id"') -eq 'v3_1247_add_subscription_cancelled_by_id'
}
Assert 'revision: single-quoted' {
    (Get-RevisionId "revision = 'b6c9dc57ac9c'") -eq 'b6c9dc57ac9c'
}
Assert 'revision: absent -> null' {
    $null -eq (Get-RevisionId 'down_revision = "x"')
}
Assert 'revision: down_revision line must not be mistaken for revision' {
    $null -eq (Get-RevisionId 'down_revision: Union[str, None] = "v3_1151_add_subscription_pause_metadata"')
}

# --- Get-DownRevisionIds: single, none, and the tuple form used by merge points ---
Assert 'down: single parent' {
    (Get-DownRevisionIds 'down_revision = "20260624_amazon_checkout_uq"') -join ',' -eq '20260624_amazon_checkout_uq'
}
Assert 'down: typed Union form' {
    (Get-DownRevisionIds 'down_revision: Union[str, None] = "v3_1151_add_subscription_pause_metadata"') -join ',' -eq 'v3_1151_add_subscription_pause_metadata'
}
Assert 'down: None -> empty' {
    (Get-DownRevisionIds 'down_revision = None').Count -eq 0
}
Assert 'down: merge point tuple -> both parents' {
    (Get-DownRevisionIds 'down_revision = ("3fc861132c3c", "b6c9dc57ac9c")') -join ',' -eq '3fc861132c3c,b6c9dc57ac9c'
}
# Real merge points in this repo write the tuple across lines. Missing these leaves their
# parents unclaimed, which invents phantom heads and makes `behind` unreliable.
Assert 'down: MULTI-LINE merge tuple -> both parents' {
    $src = "down_revision: Union[str, Sequence[str], None] = (`n    `"628b3b948b29`",`n    `"20260617_lp_starters`",`n)`n"
    (Get-DownRevisionIds $src) -join ',' -eq '628b3b948b29,20260617_lp_starters'
}
Assert 'down: multi-line tuple does not swallow later revision lines' {
    $src = "down_revision: Union[str, Sequence[str], None] = (`n    `"a`",`n    `"b`",`n)`n`nrevision = `"zzz`"`n"
    (Get-DownRevisionIds $src) -join ',' -eq 'a,b'
}
# A real file has docstring PROSE starting with `down_revision:` and no `=` on that line. If the
# annotation group is allowed to span newlines it runs on to the next `=` and captures the
# revision as its own parent, which silently orphans the true parent.
$docstringTrap = "`"`"`"Seed templates.`n`ndown_revision: V3-830's migration landed first, so`nthis one rebases onto it.`n`"`"`"`nrevision: str = `"20260617_lp_starters`"`ndown_revision: Union[str, None] = `"20260617_coupon_redemptions`"`n"
Assert 'trap: docstring prose does not hijack down_revision' {
    (Get-DownRevisionIds $docstringTrap) -join ',' -eq '20260617_coupon_redemptions'
}
Assert 'trap: revision still parses correctly alongside the prose' {
    (Get-RevisionId $docstringTrap) -eq '20260617_lp_starters'
}
Assert 'trap: a file never lists itself as its own parent' {
    (Get-DownRevisionIds $docstringTrap) -notcontains (Get-RevisionId $docstringTrap)
}

# --- Get-MigrationHeads: a head is a revision nobody lists as their parent ---
$graph = @(
    [pscustomobject]@{ Revision = 'a'; Parents = @() }
    [pscustomobject]@{ Revision = 'b'; Parents = @('a') }
    [pscustomobject]@{ Revision = 'c'; Parents = @('b') }
)
Assert 'heads: linear chain -> single leaf' {
    (Get-MigrationHeads $graph) -join ',' -eq 'c'
}
$merged = @(
    [pscustomobject]@{ Revision = 'a'; Parents = @() }
    [pscustomobject]@{ Revision = 'b'; Parents = @('a') }
    [pscustomobject]@{ Revision = 'c'; Parents = @('a') }
    [pscustomobject]@{ Revision = 'm'; Parents = @('b', 'c') }
)
Assert 'heads: merge point collapses two branches to one head' {
    (Get-MigrationHeads $merged) -join ',' -eq 'm'
}

# --- Get-MigrationState: the classification the dashboard renders ---
Assert 'state: stamp missing from tree -> wedged' {
    (Get-MigrationState -Stamped 'v3_1247_orphan' -Known @('a', 'b') -Heads @('b')) -eq 'wedged'
}
Assert 'state: stamp is the head -> ok' {
    (Get-MigrationState -Stamped 'b' -Known @('a', 'b') -Heads @('b')) -eq 'ok'
}
Assert 'state: stamp known but not head -> behind' {
    (Get-MigrationState -Stamped 'a' -Known @('a', 'b') -Heads @('b')) -eq 'behind'
}
Assert 'state: no stamp at all -> unknown' {
    (Get-MigrationState -Stamped '' -Known @('a', 'b') -Heads @('b')) -eq 'unknown'
}
Assert 'state: no migration files readable -> unknown, never a false wedged' {
    (Get-MigrationState -Stamped 'a' -Known @() -Heads @()) -eq 'unknown'
}

Write-Host ''
if ($script:ran -eq 0) { Write-Host 'NO TESTS RAN' -ForegroundColor Red; exit 1 }
if ($script:fails) { Write-Host "$($script:fails)/$($script:ran) FAILED" -ForegroundColor Red; exit 1 } else { Write-Host "ALL $($script:ran) PASS" -ForegroundColor Green }
