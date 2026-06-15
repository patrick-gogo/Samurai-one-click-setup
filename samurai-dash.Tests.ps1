# Dependency-free tests. Run: pwsh -NoProfile -File samurai-dash.Tests.ps1
. "$PSScriptRoot\samurai-dash.ps1" -NoRun

$script:fails = 0
$script:ran = 0
# Scriptblock form so a THROW (e.g. undefined function) counts as FAIL, not a silent skip.
# Errors are made terminating locally so the catch sees them; the asserted code is pure (no native cmds).
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

# --- Format-RepoLine ---
Assert 'repo: clean'            { (Format-RepoLine ([pscustomobject]@{Name='admin';Branch='master';Dirty=0;Unpushed=0;Behind=0;Ok=$true})) -eq 'admin   master  (clean)' }
Assert 'repo: dirty+unpushed'   { (Format-RepoLine ([pscustomobject]@{Name='store';Branch='feat/x';Dirty=2;Unpushed=1;Behind=0;Ok=$true})) -eq 'store   feat/x  (2 uncommitted, 1 unpushed)' }
Assert 'repo: behind'           { (Format-RepoLine ([pscustomobject]@{Name='admin';Branch='m';Dirty=0;Unpushed=0;Behind=3;Ok=$true})) -match '\(clean\)  \[behind 3\]' }
Assert 'repo: n/a'              { (Format-RepoLine ([pscustomobject]@{Name='x';Ok=$false})) -match '^x\s+n/a$' }

Write-Host ''
if ($script:ran -eq 0) { Write-Host 'NO TESTS RAN' -ForegroundColor Red; exit 1 }
if ($script:fails) { Write-Host "$($script:fails)/$($script:ran) FAILED" -ForegroundColor Red; exit 1 } else { Write-Host "ALL $($script:ran) PASS" -ForegroundColor Green }
