# Dependency-free tests. Run: pwsh -NoProfile -File samurai-junction-lib.Tests.ps1
. "$PSScriptRoot\samurai-junction-lib.ps1"

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

# Real-filesystem sandbox: junctions are an NTFS feature, so these can't be faked.
$sandbox = Join-Path $env:TEMP "junction-lib-tests-$PID"
if (Test-Path $sandbox) { Remove-Item -LiteralPath $sandbox -Recurse -Force }
New-Item -ItemType Directory $sandbox -Force | Out-Null
$target = Join-Path $sandbox 'target'
$link   = Join-Path $sandbox 'link'
$plain  = Join-Path $sandbox 'plain'
New-Item -ItemType Directory $target -Force | Out-Null
New-Item -ItemType Directory $plain  -Force | Out-Null
Set-Content (Join-Path $target 'canary.txt') 'must survive'

try {
    # --- Test-IsJunction ---
    Assert 'is-junction: missing path -> false'  { -not (Test-IsJunction (Join-Path $sandbox 'nope')) }
    Assert 'is-junction: plain dir -> false'     { -not (Test-IsJunction $plain) }

    New-JunctionLink -Path $link -Target $target
    Assert 'is-junction: junction -> true'       { Test-IsJunction $link }
    Assert 'new-junction: reads through link'    { Test-Path (Join-Path $link 'canary.txt') }

    # --- Get-JunctionTarget ---
    # Normalize target to full path (Join-Path may use short names; Get-Item returns full names)
    $targetResolved = (Get-Item -LiteralPath $target -Force).FullName
    Assert 'get-target: returns target path'     { (Get-JunctionTarget $link) -eq $targetResolved.TrimEnd('\') }
    Assert 'get-target: plain dir -> null'       { $null -eq (Get-JunctionTarget $plain) }

    # --- New-JunctionLink guards ---
    Assert 'new-junction: missing target throws' {
        try { New-JunctionLink -Path (Join-Path $sandbox 'l2') -Target (Join-Path $sandbox 'ghost'); $false }
        catch { $true }
    }

    # --- Remove-JunctionLink ---
    Assert 'remove-junction: refuses a plain dir' {
        try { Remove-JunctionLink -Path $plain; $false } catch { $true }
    }
    Assert 'remove-junction: plain dir untouched' { Test-Path $plain }

    Remove-JunctionLink -Path $link
    Assert 'remove-junction: link gone'          { -not (Test-Path $link) }
    # The whole point of the non-recursive delete: the target must be untouched.
    Assert 'remove-junction: TARGET SURVIVES'    { Test-Path (Join-Path $target 'canary.txt') }
} finally {
    Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($script:ran -eq 0) { Write-Host 'NO TESTS RAN' -ForegroundColor Red; exit 1 }
if ($script:fails) { Write-Host "$($script:fails)/$($script:ran) FAILED" -ForegroundColor Red; exit 1 } else { Write-Host "ALL $($script:ran) PASS" -ForegroundColor Green }
