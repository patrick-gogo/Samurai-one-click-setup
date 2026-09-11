<#
.SYNOPSIS
Checks a Night Shift dossier against the contract in {vault}/night-shift/spec.md section 7.
.EXAMPLE
pwsh -NoProfile -File samurai-night-validate.ps1 -Path "...\dossier-2026-09-08.md"
#>
param(
    [string]$Path,
    [switch]$NoRun
)

$script:RequiredFrontmatter = @(
    'key', 'type', 'ratified', 'generated_at', 'generated_by', 'depth',
    'base_sha', 'base_branch', 'ledger_entries', 'blocked_on_ruling', 'verify_failed'
)

# Order matters: the dossier must present these in exactly this sequence.
$script:RequiredSections = @(
    'Blocked on ruling',
    'Decision ledger',
    'Ticket',
    'Prior art',
    'How it works today',
    'Likely files to touch',
    'Collisions with your open PRs',
    'What I did not verify',
    'Morning handoff'
)

$script:Sentinel = '<!-- dossier-end -->'

function ConvertFrom-DossierFrontmatter {
    param([string[]]$Lines)
    $map = @{}
    if ($Lines.Count -eq 0 -or $Lines[0].Trim() -ne '---') { return $null }
    for ($i = 1; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i].Trim() -eq '---') { return $map }
        if ($Lines[$i] -match '^\s*([A-Za-z0-9_]+)\s*:\s*(.*)$') {
            $map[$Matches[1]] = $Matches[2].Trim().Trim('"')
        }
    }
    return $null   # unterminated frontmatter
}

function Get-SectionIndex {
    param([string[]]$Lines, [string]$Name)
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i].Trim() -eq "## $Name") { return $i }
    }
    return -1
}

function Get-SectionIndices {
    param([string[]]$Lines, [string]$Name)
    $result = @()
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i].Trim() -eq "## $Name") { $result += $i }
    }
    return $result
}

function Test-Dossier {
    param([Parameter(Mandatory)][string]$Path)

    $errors = New-Object System.Collections.Generic.List[string]

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        $errors.Add("file not found: $Path")
        return [pscustomobject]@{ Ok = $false; Errors = $errors.ToArray() }
    }

    $lines = [System.IO.File]::ReadAllLines($Path)

    # --- sentinel: a run killed mid-write loses its last line ---
    $lastReal = ($lines | Where-Object { $_.Trim() -ne '' } | Select-Object -Last 1)
    if ($lastReal -ne $script:Sentinel) {
        $errors.Add("truncated: file does not end with $($script:Sentinel)")
    }

    # --- frontmatter ---
    $fm = ConvertFrom-DossierFrontmatter -Lines $lines
    if ($null -eq $fm) {
        $errors.Add('frontmatter missing or unterminated')
    }
    else {
        foreach ($k in $script:RequiredFrontmatter) {
            if (-not $fm.ContainsKey($k) -or [string]::IsNullOrWhiteSpace($fm[$k])) {
                $errors.Add("frontmatter missing key: $k")
            }
        }
        if ($fm.ContainsKey('ratified') -and $fm['ratified'] -ne 'false') {
            $errors.Add("ratified must be false, got '$($fm['ratified'])'")
        }
    }

    # --- banner ---
    if (-not ($lines | Where-Object { $_ -match 'UNRATIFIED' })) {
        $errors.Add('UNRATIFIED banner missing')
    }

    # --- sections present, not duplicated, and in order ---
    $lastIdx = -1
    foreach ($name in $script:RequiredSections) {
        $idxs = Get-SectionIndices -Lines $lines -Name $name
        if ($idxs.Count -eq 0) {
            $errors.Add("section missing: $name")
            continue
        }
        if ($idxs.Count -gt 1) {
            $errors.Add("section duplicated: $name")
        }
        $idx = $idxs[0]
        if ($idx -lt $lastIdx) {
            $errors.Add("section out of order: $name")
        }
        else {
            $lastIdx = $idx
        }
    }

    # --- "What I did not verify" must carry content ---
    $wiv = Get-SectionIndex -Lines $lines -Name 'What I did not verify'
    if ($wiv -ge 0) {
        $body = @()
        for ($i = $wiv + 1; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match '^## ') { break }
            if ($lines[$i].Trim() -eq $script:Sentinel) { break }
            if ($lines[$i].Trim() -ne '') { $body += $lines[$i] }
        }
        $hasRealContent = $false
        foreach ($b in $body) {
            if ($b.Trim() -notmatch '^<!--.*-->$') { $hasRealContent = $true; break }
        }
        if ($body.Count -eq 0 -or -not $hasRealContent) {
            $errors.Add('"What I did not verify" is empty')
        }
    }

    # --- B/L headings: numbered from 1, no gaps, count matches frontmatter ---
    foreach ($pair in @(@('B', 'blocked_on_ruling'), @('L', 'ledger_entries'))) {
        $prefix = $pair[0]; $key = $pair[1]
        $nums = @()
        foreach ($l in $lines) {
            if ($l -match "^###\s+$prefix(\d+)\.\s+\S") { $nums += [int]$Matches[1] }
        }
        if ($nums.Count -gt 0) {
            # Guard the range: in PowerShell `1..0` counts DOWN and yields @(1,0).
            $expected = 1..$nums.Count
            if (Compare-Object $nums $expected -SyncWindow 0) {
                $errors.Add("$prefix headings must be numbered 1..$($nums.Count) in order, got: $($nums -join ',')")
            }
        }
        if ($null -ne $fm -and $fm.ContainsKey($key)) {
            $declared = 0
            [void][int]::TryParse($fm[$key], [ref]$declared)
            if ($declared -ne $nums.Count) {
                $errors.Add("$key says $declared but found $($nums.Count) $prefix headings")
            }
        }
    }

    return [pscustomobject]@{ Ok = ($errors.Count -eq 0); Errors = $errors.ToArray() }
}

if (-not $NoRun) {
    if ([string]::IsNullOrWhiteSpace($Path)) {
        Write-Error 'Usage: samurai-night-validate.ps1 -Path <dossier.md>'
        exit 2
    }
    $r = Test-Dossier -Path $Path
    if ($r.Ok) {
        Write-Host "OK: $Path" -ForegroundColor Green
        exit 0
    }
    Write-Host "INVALID: $Path" -ForegroundColor Red
    $r.Errors | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}
