# Dependency-free tests. Run: pwsh -NoProfile -File samurai-testdb-lib.Tests.ps1
. "$PSScriptRoot\samurai-testdb-lib.ps1"

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

# --- ConvertTo-TestDbSuffix ---
Assert 'suffix: uppercase key'    { (ConvertTo-TestDbSuffix 'V3-1193') -eq 'v3_1193' }
Assert 'suffix: lowercase input'  { (ConvertTo-TestDbSuffix 'v3-1193') -eq 'v3_1193' }
Assert 'suffix: invalid key throws' {
    try { ConvertTo-TestDbSuffix 'not-a-key'; $false } catch { $true }
}

# --- Get-TicketKeyFromFolderName ---
Assert 'folder: wt- prefix match'  { (Get-TicketKeyFromFolderName 'wt-V3-1193-category-duplicate-name-guard') -eq 'V3-1193' }
Assert 'folder: no match -> null'  { $null -eq (Get-TicketKeyFromFolderName 'samurai_cart_v3') }

# --- Get-TicketKeyFromBranch ---
Assert 'branch: bugfix prefix'     { (Get-TicketKeyFromBranch 'bugfix/V3-1193-category-duplicate-name-guard') -eq 'V3-1193' }
Assert 'branch: feature prefix'    { (Get-TicketKeyFromBranch 'feature/V3-295-newsletter-guard') -eq 'V3-295' }
Assert 'branch: master -> null'    { $null -eq (Get-TicketKeyFromBranch 'master') }

Write-Host ''
if ($script:ran -eq 0) { Write-Host 'NO TESTS RAN' -ForegroundColor Red; exit 1 }
if ($script:fails) { Write-Host "$($script:fails)/$($script:ran) FAILED" -ForegroundColor Red; exit 1 } else { Write-Host "ALL $($script:ran) PASS" -ForegroundColor Green }
