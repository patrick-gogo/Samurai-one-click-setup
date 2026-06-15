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

function Get-CiState($rollup) {
    if (-not $rollup -or @($rollup).Count -eq 0) { return 'none' }
    $states = foreach ($c in @($rollup)) {
        if ($c.conclusion) { $c.conclusion } elseif ($c.state) { $c.state } else { $c.status }
    }
    if ($states -contains 'FAILURE' -or $states -contains 'ERROR') { return 'x' }
    if ($states -contains 'PENDING' -or $states -contains 'IN_PROGRESS' -or $states -contains 'QUEUED') { return '~' }
    return 'ok'
}

function ConvertFrom-GhPr($prs) {
    foreach ($p in @($prs)) {
        if ($null -eq $p) { continue }   # gh '[]' parses to $null in pwsh; @($null) iterates once
        [pscustomobject]@{
            Number = $p.number; Title = $p.title; Ci = Get-CiState $p.statusCheckRollup
            Draft = [bool]$p.isDraft; Mergeable = $p.mergeable; Url = $p.url
        }
    }
}

function Format-PrLine($pr) {
    $ci = switch ($pr.Ci) { 'ok' {'CI ok'} 'x' {'CI X '} '~' {'CI ~ '} default {'CI -  '} }
    $st = if ($pr.Draft) { 'draft' } else { 'ready' }
    $mg = if ($pr.Mergeable -eq 'CONFLICTING') { 'conflicts' } else { 'mergeable' }
    $title = if ($pr.Title.Length -gt 40) { $pr.Title.Substring(0, 37) + '...' } else { $pr.Title }
    '#{0,-4} {1,-40} {2} . {3} . {4}' -f $pr.Number, $title, $ci, $st, $mg
}

function Get-PrInfo([string]$Repo, [string]$Mode) {
    $a = @('pr','list','--repo',$Repo,'--json','number,title,isDraft,mergeable,statusCheckRollup,url','--limit','15')
    if ($Mode -eq 'mine') { $a += @('--author','@me') } else { $a += @('--search','review-requested:@me') }
    $json = gh @a 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($json)) { return 'UNAVAILABLE' }   # gh failed/offline
    ConvertFrom-GhPr (ConvertFrom-Json $json)   # emits 0..N pr objects (nothing when the list is [])
}

function Resolve-PrUrl($prs, $number) {
    foreach ($p in @($prs)) { if ([string]$p.Number -eq [string]$number) { return $p.Url } }
    return $null
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
        Write-Host '  == Pull Requests ==' -ForegroundColor Cyan
        Write-Host '  fetching...' -ForegroundColor DarkGray
        $script:LastPrs = @()
        foreach ($repo in @('f-i-d/samurai_cart_v3', 'f-i-d/samurai_cart_v3_frontend')) {
            $short = $repo.Split('/')[-1] -replace '^samurai_cart_v3', 'cart'
            foreach ($mode in @('review', 'mine')) {
                try {
                    $prs = Get-PrInfo $repo $mode
                    if ($prs -is [string]) { Write-Host "  [$short/$mode] gh unavailable" -ForegroundColor Red }
                    elseif ($prs) {
                        foreach ($pr in @($prs)) {
                            $script:LastPrs += $pr
                            $col = switch ($pr.Ci) { 'x' {'Red'} '~' {'Yellow'} default {'Gray'} }
                            Write-Host ("  [$short/$mode] " + (Format-PrLine $pr)) -ForegroundColor $col
                        }
                    }
                } catch { Write-Host "  [$short/$mode] error" -ForegroundColor Red }
            }
        }
        Write-Host ''
        Write-Host '  [r]efresh  [o]pen-PR  [d]ocker  [a]claude  [g]ithub  [c]ode  [j]ira  [l]ocalhost  [q]uit' -ForegroundColor DarkGray
        $k = [Console]::ReadKey($true)
        try {
            switch ($k.Key) {
                ([ConsoleKey]::Q) { Clear-Host; return }
                ([ConsoleKey]::O) {
                    Write-Host ''
                    $n = Read-Host '  open PR #'
                    $url = Resolve-PrUrl $script:LastPrs $n
                    if ($url) { Open-Url $url } else { Write-Host "  no PR #$n on the board" -ForegroundColor Yellow; Start-Sleep -Seconds 1 }
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
                    $r = Read-Host '  claude in [a]dmin / [s]tore'
                    if ($r -match '^[Ss]') { Open-ClaudeSession $script:Store } else { Open-ClaudeSession $script:Admin }
                }
                ([ConsoleKey]::G) { Open-Url 'https://github.com/f-i-d/samurai_cart_v3'; Open-Url 'https://github.com/f-i-d/samurai_cart_v3_frontend' }
                ([ConsoleKey]::C) { code $script:Admin; code $script:Store }
                ([ConsoleKey]::J) { Open-Url 'https://f-i-d.atlassian.net/jira/software/projects/V3/list' }
                ([ConsoleKey]::L) { Open-Url 'http://localhost:3000'; Open-Url 'http://localhost:3001' }
                default { }   # r / any other key -> re-render
            }
        } catch { Write-Host "  action error: $($_.Exception.Message)" -ForegroundColor Red; Start-Sleep -Seconds 1 }
    }
}

if (-not $NoRun) { Invoke-Dashboard }
