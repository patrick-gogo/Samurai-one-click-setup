# Dependency-free tests. Run: pwsh -NoProfile -File samurai-cleanup-ticket.Tests.ps1
. "$PSScriptRoot\samurai-cleanup-ticket.ps1" -NoRun

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

$sandbox = Join-Path $env:TEMP "cleanup-ticket-tests-$PID"
if (Test-Path $sandbox) { Remove-Item -LiteralPath $sandbox -Recurse -Force }
New-Item -ItemType Directory $sandbox -Force | Out-Null

try {
    # --- Find-TicketWorktree (previously untested) ---
    New-Item -ItemType Directory (Join-Path $sandbox 'wt-V3-999-some-slug') -Force | Out-Null
    Assert 'find: matches wt-<key>-*' {
        # Normalize the expected path: $env:TEMP can resolve as an 8.3 short name (JOHNPA~1)
        # while Find-TicketWorktree returns .FullName in long form.
        $expected = (Get-Item -LiteralPath (Join-Path $sandbox 'wt-V3-999-some-slug') -Force).FullName
        (Find-TicketWorktree -Key 'V3-999' -BaseDir $sandbox) -eq $expected
    }
    Assert 'find: no match -> null' { $null -eq (Find-TicketWorktree -Key 'V3-000' -BaseDir $sandbox) }
    New-Item -ItemType Directory (Join-Path $sandbox 'wt-V3-999-other-slug') -Force | Out-Null
    Assert 'find: ambiguous match throws' {
        try { Find-TicketWorktree -Key 'V3-999' -BaseDir $sandbox | Out-Null; $false } catch { $true }
    }

    # --- Remove-WorktreeNodeModulesJunction ---
    $store = Join-Path $sandbox 'store'
    New-Item -ItemType Directory $store -Force | Out-Null
    Set-Content (Join-Path $store 'canary.txt') 'must survive'

    $wtLinked = Join-Path $sandbox 'wt-linked'
    New-Item -ItemType Directory (Join-Path $wtLinked 'frontend') -Force | Out-Null
    New-JunctionLink -Path (Join-Path $wtLinked 'frontend\node_modules') -Target $store

    Assert 'unlink: reports true when a junction was removed' {
        (Remove-WorktreeNodeModulesJunction $wtLinked) -eq $true
    }
    Assert 'unlink: junction is gone' { -not (Test-Path (Join-Path $wtLinked 'frontend\node_modules')) }
    Assert 'unlink: STORE SURVIVES'   { Test-Path (Join-Path $store 'canary.txt') }

    # A real node_modules must never be deleted by cleanup -- only junctions are ours to remove.
    $wtReal = Join-Path $sandbox 'wt-real'
    New-Item -ItemType Directory (Join-Path $wtReal 'frontend\node_modules') -Force | Out-Null
    Set-Content (Join-Path $wtReal 'frontend\node_modules\keep.txt') 'private store'
    Assert 'unlink: reports false for a real dir' { (Remove-WorktreeNodeModulesJunction $wtReal) -eq $false }
    Assert 'unlink: real dir untouched' { Test-Path (Join-Path $wtReal 'frontend\node_modules\keep.txt') }

    $wtNone = Join-Path $sandbox 'wt-none'
    New-Item -ItemType Directory (Join-Path $wtNone 'frontend') -Force | Out-Null
    Assert 'unlink: reports false when absent' { (Remove-WorktreeNodeModulesJunction $wtNone) -eq $false }
} finally {
    Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($script:ran -eq 0) { Write-Host 'NO TESTS RAN' -ForegroundColor Red; exit 1 }
if ($script:fails) { Write-Host "$($script:fails)/$($script:ran) FAILED" -ForegroundColor Red; exit 1 } else { Write-Host "ALL $($script:ran) PASS" -ForegroundColor Green }
