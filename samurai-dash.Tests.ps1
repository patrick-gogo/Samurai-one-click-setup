# Dependency-free tests. Run: pwsh -NoProfile -File samurai-dash.Tests.ps1
. "$PSScriptRoot\samurai-dash.ps1" -NoRun

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

# --- Format-RepoLine ---
Assert 'repo: clean'            { (Format-RepoLine ([pscustomobject]@{Name='admin';Branch='master';Dirty=0;Unpushed=0;Behind=0;Ok=$true})) -eq 'admin   master  (clean)' }
Assert 'repo: dirty+unpushed'   { (Format-RepoLine ([pscustomobject]@{Name='store';Branch='feat/x';Dirty=2;Unpushed=1;Behind=0;Ok=$true})) -eq 'store   feat/x  (2 uncommitted, 1 unpushed)' }
Assert 'repo: behind'           { (Format-RepoLine ([pscustomobject]@{Name='admin';Branch='m';Dirty=0;Unpushed=0;Behind=3;Ok=$true})) -match '\(clean\)  \[behind 3\]' }
Assert 'repo: n/a'              { (Format-RepoLine ([pscustomobject]@{Name='x';Ok=$false})) -match '^x\s+n/a$' }

# --- Format-DockerLine ---
Assert 'docker: line format'    { (Format-DockerLine ([pscustomobject]@{Service='api';State='running';Status='Up 2 hours (healthy)'})) -match '^api\s+Up 2 hours \(healthy\)$' }

# --- Parse-DockerCmd ---
Assert 'dockercmd: valid'       { $c = (Parse-DockerCmd 'restart api'); ($c.Action -eq 'restart') -and ($c.Service -eq 'api') }
Assert 'dockercmd: bad action'  { $null -eq (Parse-DockerCmd 'frobnicate api') }
Assert 'dockercmd: no service'  { $null -eq (Parse-DockerCmd 'restart') }

# --- Resolve-Repo (admin/store picker; defaults to admin) ---
Assert 'repo-sel: a -> admin'   { (Resolve-Repo 'a').Slug -eq 'samurai_cart_v3' }
Assert 'repo-sel: s -> store'   { (Resolve-Repo 's').Slug -eq 'samurai_cart_v3_frontend' }
Assert 'repo-sel: default'      { (Resolve-Repo '').Name -eq 'admin' }

# --- Format-HealthLine ---
Assert 'health: up'             { (Format-HealthLine ([pscustomobject]@{Name='admin FE';Url='http://localhost:3000';Up=$true})) -match 'admin FE\s+http://localhost:3000\s+up$' }
Assert 'health: down'           { (Format-HealthLine ([pscustomobject]@{Name='store FE';Url='http://localhost:3001';Up=$false})) -match 'down$' }

Write-Host ''
if ($script:ran -eq 0) { Write-Host 'NO TESTS RAN' -ForegroundColor Red; exit 1 }
if ($script:fails) { Write-Host "$($script:fails)/$($script:ran) FAILED" -ForegroundColor Red; exit 1 } else { Write-Host "ALL $($script:ran) PASS" -ForegroundColor Green }
