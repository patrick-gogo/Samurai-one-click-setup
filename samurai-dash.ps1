# samurai-dash.ps1 — Samurai command-center dashboard (keypress-refresh TUI).
# Watch-only board + a command bar of actions. ASCII-only output. Dot-source with -NoRun for tests.
param([switch]$NoRun)

$script:Admin = 'C:\Users\John Patrick Mandal\Desktop\samurai_cart_v3'
$script:Store = 'C:\Users\John Patrick Mandal\Desktop\samurai_cart_v3_frontend'

# ---------- Repos ----------
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

# ---------- Docker ----------
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

# ---------- Health (actual HTTP reachability — the npm FEs aren't in Docker) ----------
function Test-Url([string]$Url) {
    try { return ((Invoke-WebRequest $Url -UseBasicParsing -TimeoutSec 2 -ErrorAction Stop).StatusCode -lt 500) }
    catch { return $false }
}

function Get-ServiceHealth {
    @(
        [pscustomobject]@{ Name = 'admin FE';  Url = 'http://localhost:3000';      Up = (Test-Url 'http://localhost:3000') }
        [pscustomobject]@{ Name = 'store FE';  Url = 'http://localhost:3001';      Up = (Test-Url 'http://localhost:3001') }
        [pscustomobject]@{ Name = 'admin API'; Url = 'http://localhost:8000/docs'; Up = (Test-Url 'http://localhost:8000/docs') }
    )
}

function Format-HealthLine($s) {
    '{0,-10} {1,-28} {2}' -f $s.Name, $s.Url, $(if ($s.Up) { 'up' } else { 'down' })
}

# ---------- action helpers ----------
function Resolve-Repo([string]$Key) {
    # 'a' (or default) -> admin, 's' -> store. Returns its path + GitHub slug + short name.
    if ($Key -match '^[Ss]') {
        [pscustomobject]@{ Path = $script:Store; Slug = 'samurai_cart_v3_frontend'; Name = 'store' }
    } else {
        [pscustomobject]@{ Path = $script:Admin; Slug = 'samurai_cart_v3'; Name = 'admin' }
    }
}

function Parse-DockerCmd($text) {
    $parts = @(($text -split '\s+') | Where-Object { $_ })
    if ($parts.Count -lt 2) { return $null }
    $action = $parts[0].ToLower()
    if ($action -notin @('restart', 'stop', 'start')) { return $null }
    [pscustomobject]@{ Action = $action; Service = $parts[1] }
}

function Open-Url([string]$Url) { Start-Process $Url }

function Invoke-DockerCtl([string]$Action, [string]$Service) {
    docker compose -f "$script:Admin\docker-compose.yml" $Action $Service
}

function Open-ClaudeSession([string]$Repo) {
    $name = Split-Path $Repo -Leaf
    wt -w samurai new-tab --title "claude ($name)" --suppressApplicationTitle -d $Repo pwsh -NoExit -Command claude
}

# ---------- main loop ----------
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

        Write-Host '  == Health ==' -ForegroundColor Cyan
        try {
            foreach ($s in (Get-ServiceHealth)) {
                Write-Host ('  ' + (Format-HealthLine $s)) -ForegroundColor $(if ($s.Up) { 'Green' } else { 'Red' })
            }
        } catch { Write-Host "  health error: $($_.Exception.Message)" -ForegroundColor Red }

        Write-Host ''
        Write-Host '  [r]efresh  [o]pen-PR  [d]ocker  [a]claude  [g]ithub  [c]ode  [j]ira  [l]ocalhost  [q]uit' -ForegroundColor DarkGray
        $k = [Console]::ReadKey($true)
        try {
            switch ($k.Key) {
                ([ConsoleKey]::Q) { Clear-Host; return }
                ([ConsoleKey]::O) {
                    Write-Host ''
                    $repo = Resolve-Repo (Read-Host '  PR in [a]dmin / [s]tore')
                    $n = Read-Host "  $($repo.Name) PR #"
                    if ($n -match '^\d+$') { Open-Url "https://github.com/f-i-d/$($repo.Slug)/pull/$n" }
                    else { Write-Host '  not a number' -ForegroundColor Yellow; Start-Sleep -Seconds 1 }
                }
                ([ConsoleKey]::D) {
                    Write-Host ''
                    $cmd = Parse-DockerCmd (Read-Host '  docker (e.g. restart api)')
                    if ($cmd) {
                        Invoke-DockerCtl $cmd.Action $cmd.Service
                        Write-Host '  (press any key to return)' -ForegroundColor DarkGray
                        [Console]::ReadKey($true) | Out-Null
                    } else { Write-Host '  usage: <restart|stop|start> <service>' -ForegroundColor Yellow; Start-Sleep -Seconds 1 }
                }
                ([ConsoleKey]::A) {
                    Write-Host ''
                    Open-ClaudeSession (Resolve-Repo (Read-Host '  claude in [a]dmin / [s]tore')).Path
                }
                ([ConsoleKey]::G) {
                    Write-Host ''
                    $repo = Resolve-Repo (Read-Host '  GitHub [a]dmin / [s]tore')
                    Open-Url "https://github.com/f-i-d/$($repo.Slug)"
                }
                ([ConsoleKey]::C) {
                    Write-Host ''
                    code (Resolve-Repo (Read-Host '  VS Code [a]dmin / [s]tore')).Path
                }
                ([ConsoleKey]::J) { Open-Url 'https://f-i-d.atlassian.net/jira/software/projects/V3/list' }
                ([ConsoleKey]::L) { Open-Url 'http://localhost:3000'; Open-Url 'http://localhost:3001' }
                default { }   # r / any other key -> re-render
            }
        } catch { Write-Host "  action error: $($_.Exception.Message)" -ForegroundColor Red; Start-Sleep -Seconds 1 }
    }
}

if (-not $NoRun) { Invoke-Dashboard }
