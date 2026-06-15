# samurai-dash.ps1 — Samurai command-center dashboard (keypress-refresh TUI).
# Watch-only: 'r' re-renders, 'q' quits. ASCII-only output. Dot-source with -NoRun for tests.
param([switch]$NoRun)

$script:Admin = 'C:\Users\John Patrick Mandal\Desktop\samurai_cart_v3'
$script:Store = 'C:\Users\John Patrick Mandal\Desktop\samurai_cart_v3_frontend'

function Get-RepoInfo([string]$Name, [string]$Repo) {
    $branch = (git -C $Repo rev-parse --abbrev-ref HEAD 2>$null)
    if (-not $branch) { return [pscustomobject]@{ Name = $Name; Ok = $false } }
    $dirty    = @(git -C $Repo status --porcelain 2>$null).Count
    $unpushed = [int](git -C $Repo rev-list '@{u}..HEAD' --count 2>$null)
    $behind   = [int](git -C $Repo rev-list 'HEAD..@{u}' --count 2>$null)
    [pscustomobject]@{ Name = $Name; Branch = $branch; Dirty = $dirty; Unpushed = $unpushed; Behind = $behind; Ok = $true }
}

function Format-RepoLine($i) {
    if (-not $i.Ok) { return ('{0,-7} n/a' -f $i.Name) }
    $bits = @()
    if ($i.Dirty -gt 0) { $bits += "$($i.Dirty) uncommitted" } else { $bits += 'clean' }
    if ($i.Unpushed -gt 0) { $bits += "$($i.Unpushed) unpushed" }
    $behind = if ($i.Behind -gt 0) { "  [behind $($i.Behind)]" } else { '' }
    '{0,-7} {1}  ({2}){3}' -f $i.Name, $i.Branch, ($bits -join ', '), $behind
}

function Get-DockerInfo {
    $raw = docker compose -f "$script:Admin\docker-compose.yml" ps --format json 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $raw) { return $null }   # engine down / compose missing
    $text = ($raw -join "`n").Trim()
    if ($text.StartsWith('[')) { $objs = $text | ConvertFrom-Json }
    else { $objs = $text -split "`n" | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json } }
    foreach ($o in @($objs)) {
        [pscustomobject]@{ Service = $o.Service; State = $o.State; Status = $o.Status }
    }
}

function Format-DockerLine($c) {
    '{0,-16} {1}' -f $c.Service, $c.Status
}

function Invoke-Dashboard {
    while ($true) {
        Clear-Host
        Write-Host ''
        Write-Host '  +=================== SAMURAI COMMAND CENTER ===================+' -ForegroundColor DarkCyan
        Write-Host ('    refreshed ' + (Get-Date).ToString('ddd HH:mm:ss')) -ForegroundColor DarkGray
        Write-Host '  == Repos ==' -ForegroundColor Cyan
        foreach ($r in @((Get-RepoInfo 'admin' $script:Admin), (Get-RepoInfo 'store' $script:Store))) {
            $color = if (-not $r.Ok) { 'Red' } elseif ($r.Dirty -or $r.Unpushed) { 'Yellow' } else { 'Green' }
            Write-Host ('  ' + (Format-RepoLine $r)) -ForegroundColor $color
        }
        Write-Host '  == Docker ==' -ForegroundColor Cyan
        try {
            $dock = Get-DockerInfo
            if ($null -eq $dock) { Write-Host '  engine down' -ForegroundColor Red }
            else {
                $up = @($dock | Where-Object { $_.State -eq 'running' }).Count
                Write-Host ("  ($up/$(@($dock).Count) up)") -ForegroundColor DarkGray
                foreach ($c in $dock) {
                    $col = if ($c.State -eq 'running') { 'Green' } else { 'Red' }
                    Write-Host ('  ' + (Format-DockerLine $c)) -ForegroundColor $col
                }
            }
        } catch { Write-Host "  docker error: $($_.Exception.Message)" -ForegroundColor Red }
        Write-Host ''
        Write-Host '  [r] refresh   [q] quit' -ForegroundColor DarkGray
        $k = [Console]::ReadKey($true)
        if ($k.Key -eq [ConsoleKey]::Q) { Clear-Host; break }
        # any other key (incl. r) loops -> re-render
    }
}

if (-not $NoRun) { Invoke-Dashboard }
