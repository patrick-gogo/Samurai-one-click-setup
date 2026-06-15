# samurai-dash.ps1 — Samurai command-center dashboard (keypress-refresh TUI).
# Boxed panels + command bar of actions. ASCII-only output. Dot-source with -NoRun for tests.
param([switch]$NoRun)

$script:Admin = 'C:\Users\John Patrick Mandal\Desktop\samurai_cart_v3'
$script:Store = 'C:\Users\John Patrick Mandal\Desktop\samurai_cart_v3_frontend'
$script:W = 60          # box width
$script:Inner = $script:W - 4

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

# ---------- Health (HTTP reachability — the npm FEs aren't in Docker) ----------
function Test-Url([string]$Url) {
    try { return ((Invoke-WebRequest $Url -UseBasicParsing -TimeoutSec 2 -ErrorAction Stop).StatusCode -lt 500) }
    catch { return $false }
}

function Get-ServiceHealth {
    @(
        [pscustomobject]@{ Name = 'admin FE';  Port = 3000; Url = 'http://localhost:3000';      Up = (Test-Url 'http://localhost:3000') }
        [pscustomobject]@{ Name = 'store FE';  Port = 3001; Url = 'http://localhost:3001';      Up = (Test-Url 'http://localhost:3001') }
        [pscustomobject]@{ Name = 'admin API'; Port = 8000; Url = 'http://localhost:8000/docs'; Up = (Test-Url 'http://localhost:8000/docs') }
    )
}

function Format-HealthLine($s) { '{0,-10} :{1}' -f $s.Name, $s.Port }

# ---------- box framework (pure border/glyph builders + one Write-Host row drawer) ----------
function Get-StatusGlyph([string]$State) {
    switch ($State) {
        'ok'   { [pscustomobject]@{ Glyph = 'ok'; Color = 'Green' } }
        'warn' { [pscustomobject]@{ Glyph = '~ '; Color = 'Yellow' } }
        default { [pscustomobject]@{ Glyph = 'x '; Color = 'Red' } }   # 'down'
    }
}

function Format-PanelTop([string]$Title, [int]$Width) {
    $cap = "+- $Title "
    $cap + ('-' * [Math]::Max(3, $Width - $cap.Length - 1)) + '+'
}

function Format-PanelBottom([int]$Width) { '+' + ('-' * ($Width - 2)) + '+' }

# Draw "  | <segments> <pad> |". Segments = @(@{Text;Color}, ...) so cells keep their own colors.
function Write-PanelRow($Segments, [int]$Inner) {
    Write-Host '  | ' -NoNewline -ForegroundColor DarkCyan
    $len = 0
    foreach ($s in @($Segments)) {
        $t = [string]$s.Text
        if ($len + $t.Length -gt $Inner) { $t = $t.Substring(0, [Math]::Max(0, $Inner - $len)) }  # never overflow the box
        Write-Host $t -NoNewline -ForegroundColor $s.Color
        $len += $t.Length
    }
    Write-Host ((' ' * [Math]::Max(0, $Inner - $len)) + ' |') -ForegroundColor DarkCyan
}

function Write-PanelTop([string]$Title)    { Write-Host ('  ' + (Format-PanelTop $Title $script:W)) -ForegroundColor DarkCyan }
function Write-PanelBottom                 { Write-Host ('  ' + (Format-PanelBottom $script:W)) -ForegroundColor DarkCyan }

# ---------- action helpers ----------
function Resolve-Repo([string]$Key) {
    # 'a' (or default) -> admin, 's' -> store. Returns path + GitHub slug + short name.
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

function Get-GogoSites {
    @(
        [pscustomobject]@{ Name = 'Sprout Employee Dashboard'; Url = 'https://gogoitlab.hrhub.ph/EmployeeDashboard.aspx' }
        [pscustomobject]@{ Name = 'GOGO Monthly Shift';        Url = 'https://docs.google.com/spreadsheets/d/1lpxi0-z0uDjoUmCFijgvUraBabxMEEnYwVA6Gglm9ic/edit?gid=926308299#gid=926308299' }
        [pscustomobject]@{ Name = 'Conference Room Calendar';  Url = 'https://docs.google.com/spreadsheets/d/1RYoQoczkIKbnbPFlkGP7DWC7uES3RkVpocNhLKv2BzA/edit?gid=1980583467#gid=1980583467' }
    )
}

# ---------- main loop ----------
function Invoke-Dashboard {
    while ($true) {
        # fetch once per refresh (reused by the header summary + the panels)
        $repos  = @((Get-RepoInfo 'admin' $script:Admin), (Get-RepoInfo 'store' $script:Store))
        $dock   = $null; try { $dock = Get-DockerInfo } catch {}
        $health = Get-ServiceHealth
        $dockDown   = if ($null -eq $dock) { 1 } else { @($dock | Where-Object { $_.State -ne 'running' }).Count }
        $healthDown = @($health | Where-Object { -not $_.Up }).Count
        $issues     = $dockDown + $healthDown

        Clear-Host
        Write-Host ''
        # --- header ---
        Write-PanelTop 'SAMURAI COMMAND CENTER'
        $statusText  = if ($issues -eq 0) { 'all systems go' } else { "$issues issue$(if ($issues -gt 1) { 's' })" }
        $statusColor = if ($issues -eq 0) { 'Green' } else { 'Red' }
        Write-PanelRow @(
            @{ Text = $statusText; Color = $statusColor },
            @{ Text = ('   ' + (Get-Date).ToString('ddd HH:mm:ss')); Color = 'DarkGray' }
        ) $script:Inner
        Write-PanelBottom

        # --- repos ---
        Write-PanelTop 'REPOS'
        foreach ($r in $repos) {
            $state = if (-not $r.Ok) { 'down' } elseif ($r.Dirty -or $r.Unpushed) { 'warn' } else { 'ok' }
            $g = Get-StatusGlyph $state
            Write-PanelRow @(@{ Text = ($g.Glyph + ' '); Color = $g.Color }, @{ Text = (Format-RepoLine $r); Color = 'Gray' }) $script:Inner
        }
        Write-PanelBottom

        # --- docker (compact colored grid, 3 per row) ---
        if ($null -eq $dock) {
            Write-PanelTop 'DOCKER  engine down'
            Write-PanelRow @(@{ Text = 'engine down'; Color = 'Red' }) $script:Inner
            Write-PanelBottom
        } else {
            $svcs = @($dock)
            $upCount = @($svcs | Where-Object { $_.State -eq 'running' }).Count
            Write-PanelTop "DOCKER  $upCount/$($svcs.Count) up"
            for ($i = 0; $i -lt $svcs.Count; $i += 3) {
                $rowItems = $svcs[$i..([Math]::Min($i + 2, $svcs.Count - 1))]
                $segs = @()
                foreach ($c in $rowItems) {
                    $state = if ($c.State -ne 'running') { 'down' } elseif ($c.Status -match 'unhealthy') { 'warn' } else { 'ok' }
                    $g = Get-StatusGlyph $state
                    $segs += @{ Text = ($g.Glyph + ' '); Color = $g.Color }
                    $segs += @{ Text = ('{0,-14}' -f $c.Service); Color = 'Gray' }
                }
                Write-PanelRow $segs $script:Inner
            }
            Write-PanelBottom
        }

        # --- health ---
        Write-PanelTop 'HEALTH'
        foreach ($s in $health) {
            $g = Get-StatusGlyph $(if ($s.Up) { 'ok' } else { 'down' })
            Write-PanelRow @(@{ Text = ($g.Glyph + ' '); Color = $g.Color }, @{ Text = (Format-HealthLine $s); Color = 'Gray' }) $script:Inner
        }
        Write-PanelBottom

        Write-Host ''
        Write-Host '  [r]efresh  [o]pen-PR  [d]ocker  [a]claude  [g]ithub  [c]ode  [j]ira  [l]ocalhost  [w]gogo  [q]uit' -ForegroundColor DarkGray
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
                ([ConsoleKey]::W) {
                    Write-Host ''
                    $sites = Get-GogoSites
                    for ($i = 0; $i -lt $sites.Count; $i++) { Write-Host ("  [$($i + 1)] " + $sites[$i].Name) -ForegroundColor Gray }
                    $pick = Read-Host '  open which'
                    if ($pick -match '^\d+$' -and [int]$pick -ge 1 -and [int]$pick -le $sites.Count) { Open-Url $sites[[int]$pick - 1].Url }
                    else { Write-Host '  cancelled' -ForegroundColor Yellow; Start-Sleep -Seconds 1 }
                }
                default { }   # r / any other key -> re-render
            }
        } catch { Write-Host "  action error: $($_.Exception.Message)" -ForegroundColor Red; Start-Sleep -Seconds 1 }
    }
}

if (-not $NoRun) { Invoke-Dashboard }
