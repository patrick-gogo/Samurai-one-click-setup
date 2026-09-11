# Dependency-free tests. Run: pwsh -NoProfile -File samurai-fix-conflicts.Tests.ps1
. "$PSScriptRoot\samurai-fix-conflicts.ps1" -NoRun

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

# Get-ConflictingPrNumbers is the function that decides whether the night does anything at all,
# so it carries the "no conflicts means no resolution" requirement. Everything else in this
# wrapper is orchestration around its answer.

Assert 'picks out the CONFLICTING pull requests' {
    $json = '[{"number":570,"mergeable":"CONFLICTING"},{"number":539,"mergeable":"CONFLICTING"}]'
    $r = Get-ConflictingPrNumbers -Json $json
    ($r -join ',') -eq '570,539'
}

Assert 'ignores the mergeable ones' {
    $json = '[{"number":570,"mergeable":"CONFLICTING"},{"number":600,"mergeable":"MERGEABLE"}]'
    $r = Get-ConflictingPrNumbers -Json $json
    ($r -join ',') -eq '570'
}

Assert 'returns nothing when every PR is mergeable' {
    $json = '[{"number":600,"mergeable":"MERGEABLE"},{"number":601,"mergeable":"MERGEABLE"}]'
    $r = Get-ConflictingPrNumbers -Json $json
    $r.Count -eq 0
}

Assert 'returns nothing for an empty PR list' {
    $r = Get-ConflictingPrNumbers -Json '[]'
    $r.Count -eq 0
}

# GitHub computes mergeability asynchronously and answers UNKNOWN until it has. Treating UNKNOWN
# as a conflict would have the night resolve branches that are fine, so it is excluded on purpose.
Assert 'treats UNKNOWN as not-conflicting rather than guessing' {
    $json = '[{"number":570,"mergeable":"UNKNOWN"},{"number":539,"mergeable":"CONFLICTING"}]'
    $r = Get-ConflictingPrNumbers -Json $json
    ($r -join ',') -eq '539'
}

Assert 'returns nothing rather than throwing on malformed json' {
    $r = Get-ConflictingPrNumbers -Json 'not json at all'
    $r.Count -eq 0
}

Assert 'returns nothing on empty input' {
    $r = Get-ConflictingPrNumbers -Json ''
    $r.Count -eq 0
}

# A single-element result must still be countable. PowerShell unrolls one-element arrays, which
# would make .Count read as the number's own property and break the caller's "did we find any" test.
Assert 'a single conflicting PR still returns a countable array' {
    $r = Get-ConflictingPrNumbers -Json '[{"number":330,"mergeable":"CONFLICTING"}]'
    $r.Count -eq 1 -and $r[0] -eq 330
}

Write-Host ''
if ($script:fails -gt 0) {
    Write-Host "$($script:fails) of $($script:ran) failed." -ForegroundColor Red
    exit 1
}
Write-Host "All $($script:ran) passed." -ForegroundColor Green
exit 0
