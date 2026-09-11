# Dependency-free tests. Run: pwsh -NoProfile -File samurai-night-validate.Tests.ps1
. "$PSScriptRoot\samurai-night-validate.ps1" -NoRun

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

$sandbox = Join-Path $env:TEMP "night-validate-tests-$PID"
if (Test-Path $sandbox) { Remove-Item -LiteralPath $sandbox -Recurse -Force }
New-Item -ItemType Directory $sandbox -Force | Out-Null

function New-Dossier {
    param([hashtable]$Override = @{})
    $fm = [ordered]@{
        key = 'V3-1895'; title_en = 'Refund cap'; type = 'dossier'; ratified = 'false'
        generated_at = '2026-09-08T02:14:00+09:00'; generated_by = '/night-prep'
        depth = 'deep'; base_repo = 'C:/x'; base_sha = '416e973'; base_branch = 'origin/master'
        ledger_entries = '1'; blocked_on_ruling = '1'; collisions = '0'; verify_failed = '[]'
    }
    foreach ($k in $Override.Keys) { $fm[$k] = $Override[$k] }
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine('---')
    foreach ($k in $fm.Keys) { if ($null -ne $fm[$k]) { [void]$sb.AppendLine("${k}: $($fm[$k])") } }
    [void]$sb.AppendLine('---')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('> **UNRATIFIED.** Machine-generated overnight.')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('## Blocked on ruling')
    [void]$sb.AppendLine('### B1. Does a partial refund reopen the window?')
    [void]$sb.AppendLine('## Decision ledger')
    [void]$sb.AppendLine('### L1. Per-item or per-order cap?')
    [void]$sb.AppendLine('## Ticket')
    [void]$sb.AppendLine('body')
    [void]$sb.AppendLine('## Prior art')
    [void]$sb.AppendLine('None found, searched refund')
    [void]$sb.AppendLine('## How it works today')
    [void]$sb.AppendLine('app/services/refund.py:41 does the thing')
    [void]$sb.AppendLine('## Likely files to touch')
    [void]$sb.AppendLine('| path | why | confidence | in open PR |')
    [void]$sb.AppendLine('## Collisions with your open PRs')
    [void]$sb.AppendLine('None')
    [void]$sb.AppendLine('## What I did not verify')
    [void]$sb.AppendLine('- the storefront mirror')
    [void]$sb.AppendLine('## Morning handoff')
    [void]$sb.AppendLine('paste me')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('<!-- dossier-end -->')
    $p = Join-Path $sandbox ("d-" + [guid]::NewGuid().ToString('N') + ".md")
    [System.IO.File]::WriteAllText($p, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))
    return $p
}

try {
    Assert 'valid dossier passes' { (Test-Dossier -Path (New-Dossier)).Ok }

    Assert 'missing file fails' {
        $r = Test-Dossier -Path (Join-Path $sandbox 'nope.md')
        (-not $r.Ok) -and ($r.Errors -join ' ') -match 'not found'
    }

    Assert 'ratified true is rejected' {
        $r = Test-Dossier -Path (New-Dossier @{ ratified = 'true' })
        (-not $r.Ok) -and ($r.Errors -join ' ') -match 'ratified'
    }

    Assert 'missing frontmatter key is reported by name' {
        $r = Test-Dossier -Path (New-Dossier @{ base_sha = $null })
        (-not $r.Ok) -and ($r.Errors -join ' ') -match 'base_sha'
    }

    Assert 'missing section is reported by name' {
        $p = New-Dossier
        $t = [System.IO.File]::ReadAllText($p).Replace('## Prior art', '## Prior artz')
        [System.IO.File]::WriteAllText($p, $t, (New-Object System.Text.UTF8Encoding($false)))
        $r = Test-Dossier -Path $p
        (-not $r.Ok) -and ($r.Errors -join ' ') -match 'Prior art'
    }

    Assert 'out-of-order sections are rejected' {
        $p = New-Dossier
        $t = [System.IO.File]::ReadAllText($p)
        $t = $t.Replace("## Blocked on ruling`r`n### B1.", "## ZZTEMP`r`n### B1.")
        $t = $t.Replace('## Morning handoff', "## Blocked on ruling`r`n## Morning handoff")
        [System.IO.File]::WriteAllText($p, $t, (New-Object System.Text.UTF8Encoding($false)))
        $r = Test-Dossier -Path $p
        -not $r.Ok
    }

    Assert 'empty "what I did not verify" is rejected' {
        $p = New-Dossier
        $t = [System.IO.File]::ReadAllText($p).Replace('- the storefront mirror', '')
        [System.IO.File]::WriteAllText($p, $t, (New-Object System.Text.UTF8Encoding($false)))
        $r = Test-Dossier -Path $p
        (-not $r.Ok) -and ($r.Errors -join ' ') -match 'did not verify'
    }

    Assert 'missing sentinel is rejected as truncated' {
        $p = New-Dossier
        $t = [System.IO.File]::ReadAllText($p).Replace('<!-- dossier-end -->', '')
        [System.IO.File]::WriteAllText($p, $t, (New-Object System.Text.UTF8Encoding($false)))
        $r = Test-Dossier -Path $p
        (-not $r.Ok) -and ($r.Errors -join ' ') -match 'truncated'
    }

    Assert 'ledger_entries must match the L-heading count' {
        $r = Test-Dossier -Path (New-Dossier @{ ledger_entries = '4' })
        (-not $r.Ok) -and ($r.Errors -join ' ') -match 'ledger_entries'
    }

    Assert 'blocked_on_ruling must match the B-heading count' {
        $r = Test-Dossier -Path (New-Dossier @{ blocked_on_ruling = '9' })
        (-not $r.Ok) -and ($r.Errors -join ' ') -match 'blocked_on_ruling'
    }

    Assert 'B and L headings must be numbered from 1 with no gaps' {
        $p = New-Dossier
        $t = [System.IO.File]::ReadAllText($p).Replace('### L1.', '### L3.')
        [System.IO.File]::WriteAllText($p, $t, (New-Object System.Text.UTF8Encoding($false)))
        $r = Test-Dossier -Path $p
        -not $r.Ok
    }

    Assert 'duplicate section heading is rejected' {
        $p = New-Dossier
        $t = [System.IO.File]::ReadAllText($p).Replace(
            '<!-- dossier-end -->',
            "## Ticket`r`nduplicate ticket section`r`n<!-- dossier-end -->"
        )
        [System.IO.File]::WriteAllText($p, $t, (New-Object System.Text.UTF8Encoding($false)))
        $r = Test-Dossier -Path $p
        (-not $r.Ok) -and ($r.Errors -join ' ') -match 'Ticket'
    }

    Assert 'html-comment-only "what I did not verify" is rejected' {
        $p = New-Dossier
        $t = [System.IO.File]::ReadAllText($p).Replace('- the storefront mirror', '<!-- nothing to see here -->')
        [System.IO.File]::WriteAllText($p, $t, (New-Object System.Text.UTF8Encoding($false)))
        $r = Test-Dossier -Path $p
        (-not $r.Ok) -and ($r.Errors -join ' ') -match 'did not verify'
    }
}
finally {
    Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "$($script:ran - $script:fails)/$($script:ran) passed"
exit ($(if ($script:fails -gt 0) { 1 } else { 0 }))
