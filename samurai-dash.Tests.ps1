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

# --- Format-DockerLine ---
Assert 'docker: line format'    { (Format-DockerLine ([pscustomobject]@{Service='api';State='running';Status='Up 2 hours (healthy)'})) -match '^api\s+Up 2 hours \(healthy\)$' }

# --- Get-CiState ---
Assert 'ci: no checks'          { (Get-CiState @()) -eq 'none' }
Assert 'ci: all success'        { (Get-CiState @([pscustomobject]@{conclusion='SUCCESS'}, [pscustomobject]@{conclusion='SUCCESS'})) -eq 'ok' }
Assert 'ci: one failure'        { (Get-CiState @([pscustomobject]@{conclusion='SUCCESS'}, [pscustomobject]@{conclusion='FAILURE'})) -eq 'x' }
Assert 'ci: pending'            { (Get-CiState @([pscustomobject]@{conclusion='SUCCESS'}, [pscustomobject]@{status='IN_PROGRESS'})) -eq '~' }
Assert 'ci: statusContext'      { (Get-CiState @([pscustomobject]@{state='SUCCESS'})) -eq 'ok' }

# --- Format-PrLine ---
Assert 'pr: number'             { (Format-PrLine ([pscustomobject]@{Number=169;Title='feat: legal pages';Ci='ok';Draft=$false;Mergeable='MERGEABLE'})) -match '^#169 ' }
Assert 'pr: ci ok'              { (Format-PrLine ([pscustomobject]@{Number=169;Title='feat: legal pages';Ci='ok';Draft=$false;Mergeable='MERGEABLE'})) -match 'CI ok' }
Assert 'pr: ready'              { (Format-PrLine ([pscustomobject]@{Number=169;Title='feat';Ci='ok';Draft=$false;Mergeable='MERGEABLE'})) -match 'ready' }
Assert 'pr: draft+conflicts'    { (Format-PrLine ([pscustomobject]@{Number=1;Title='x';Ci='x';Draft=$true;Mergeable='CONFLICTING'})) -match 'draft . conflicts' }

# --- ConvertFrom-GhPr null/empty (gh '[]' parses to $null in pwsh; must NOT yield a blank PR) ---
Assert 'pr: null input -> 0 rows'  { @(ConvertFrom-GhPr $null).Count -eq 0 }
Assert 'pr: empty input -> 0 rows' { @(ConvertFrom-GhPr @()).Count -eq 0 }

# --- Resolve-PrUrl ---
Assert 'resolvepr: found'       { (Resolve-PrUrl @([pscustomobject]@{Number=169;Url='u169'}, [pscustomobject]@{Number=12;Url='u12'}) 12) -eq 'u12' }
Assert 'resolvepr: not found'   { $null -eq (Resolve-PrUrl @([pscustomobject]@{Number=169;Url='u169'}) 999) }

# --- Parse-DockerCmd ---
Assert 'dockercmd: valid'       { $c = (Parse-DockerCmd 'restart api'); ($c.Action -eq 'restart') -and ($c.Service -eq 'api') }
Assert 'dockercmd: bad action'  { $null -eq (Parse-DockerCmd 'frobnicate api') }
Assert 'dockercmd: no service'  { $null -eq (Parse-DockerCmd 'restart') }

Write-Host ''
if ($script:ran -eq 0) { Write-Host 'NO TESTS RAN' -ForegroundColor Red; exit 1 }
if ($script:fails) { Write-Host "$($script:fails)/$($script:ran) FAILED" -ForegroundColor Red; exit 1 } else { Write-Host "ALL $($script:ran) PASS" -ForegroundColor Green }
