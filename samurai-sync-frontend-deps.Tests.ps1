# Dependency-free tests. Run: pwsh -NoProfile -File samurai-sync-frontend-deps.Tests.ps1
. "$PSScriptRoot\samurai-sync-frontend-deps.ps1" -NoRun

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

# --- Get-ProvisioningMode: absent ---
Assert 'absent + match + healthy   -> link' {
    (Get-ProvisioningMode -DestState 'absent' -LockMatch $true -SourceHealthy $true -JunctionTargetOk $false) -eq 'link'
}
Assert 'absent + match + UNhealthy -> install' {
    (Get-ProvisioningMode -DestState 'absent' -LockMatch $true -SourceHealthy $false -JunctionTargetOk $false) -eq 'install'
}
Assert 'absent + differ            -> install' {
    (Get-ProvisioningMode -DestState 'absent' -LockMatch $false -SourceHealthy $true -JunctionTargetOk $false) -eq 'install'
}

# --- Get-ProvisioningMode: realdir ---
# A populated real store already satisfies its own lockfile, so main-store health is irrelevant.
Assert 'realdir + match            -> noop' {
    (Get-ProvisioningMode -DestState 'realdir' -LockMatch $true -SourceHealthy $false -JunctionTargetOk $false) -eq 'noop'
}
Assert 'realdir + differ           -> install' {
    (Get-ProvisioningMode -DestState 'realdir' -LockMatch $false -SourceHealthy $true -JunctionTargetOk $false) -eq 'install'
}

# --- Get-ProvisioningMode: junction ---
Assert 'junction + match + healthy + target ok  -> noop' {
    (Get-ProvisioningMode -DestState 'junction' -LockMatch $true -SourceHealthy $true -JunctionTargetOk $true) -eq 'noop'
}
Assert 'junction + match + healthy + wrong target -> relink' {
    (Get-ProvisioningMode -DestState 'junction' -LockMatch $true -SourceHealthy $true -JunctionTargetOk $false) -eq 'relink'
}
Assert 'junction + DIFFER                        -> swap' {
    (Get-ProvisioningMode -DestState 'junction' -LockMatch $false -SourceHealthy $true -JunctionTargetOk $true) -eq 'swap'
}
Assert 'junction + match + UNhealthy source      -> swap' {
    (Get-ProvisioningMode -DestState 'junction' -LockMatch $true -SourceHealthy $false -JunctionTargetOk $true) -eq 'swap'
}

# --- Guard: unknown state must not silently return $null ---
Assert 'unknown DestState throws' {
    try { Get-ProvisioningMode -DestState 'bogus' -LockMatch $true -SourceHealthy $true -JunctionTargetOk $true | Out-Null; $false }
    catch { $true }
}

Write-Host ''
if ($script:ran -eq 0) { Write-Host 'NO TESTS RAN' -ForegroundColor Red; exit 1 }
if ($script:fails) { Write-Host "$($script:fails)/$($script:ran) FAILED" -ForegroundColor Red; exit 1 } else { Write-Host "ALL $($script:ran) PASS" -ForegroundColor Green }
