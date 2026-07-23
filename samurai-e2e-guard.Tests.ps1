# Dependency-free tests. Run: pwsh -NoProfile -File samurai-e2e-guard.Tests.ps1
. "$PSScriptRoot\samurai-e2e-guard.ps1" -NoRun

$script:fails = 0
$script:ran = 0
# Scriptblock form so a THROW (e.g. undefined function) counts as FAIL, not a silent skip.
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

# --- Test-BranchNameConvention ---
Assert 'branch: bugfix/ ok'        { Test-BranchNameConvention 'bugfix/V3-1193-category-duplicate-name-guard' }
Assert 'branch: feature/ ok'       { Test-BranchNameConvention 'feature/V3-295-newsletter-guard' }
Assert 'branch: hotfix/ ok'        { Test-BranchNameConvention 'hotfix/urgent-thing' }
Assert 'branch: master rejected'   { -not (Test-BranchNameConvention 'master') }
Assert 'branch: no-slash rejected' { -not (Test-BranchNameConvention 'bugfix-no-slash') }
Assert 'branch: empty-after-slash rejected' { -not (Test-BranchNameConvention 'bugfix/') }

# --- Test-PrTitleConvention ---
Assert 'title: fix ok'             { Test-PrTitleConvention 'fix(V3-1193): resolve duplicate name guard' }
Assert 'title: feat no-scope ok'   { Test-PrTitleConvention 'feat: add new thing' }
Assert 'title: chore ok'           { Test-PrTitleConvention 'chore(deps): bump uv.lock' }
Assert 'title: bad-type rejected'  { -not (Test-PrTitleConvention 'update: something') }
Assert 'title: no-colon rejected'  { -not (Test-PrTitleConvention 'fix this thing') }
Assert 'title: no-space-after-colon rejected' { -not (Test-PrTitleConvention 'fix:nothing') }

Write-Host ''
if ($script:ran -eq 0) { Write-Host 'NO TESTS RAN' -ForegroundColor Red; exit 1 }
if ($script:fails) { Write-Host "$($script:fails)/$($script:ran) FAILED" -ForegroundColor Red; exit 1 } else { Write-Host "ALL $($script:ran) PASS" -ForegroundColor Green }
