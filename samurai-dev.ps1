# samurai-dev.ps1 — open the full Samurai Cart dev environment in one Windows Terminal window.
# Tabs: Servers (venv + api logs | admin FE + storefront), + a Claude session per repo.
# The greeting prints in THIS launcher window (samurai-greeting.ps1). ASCII-only output so it
# renders the same under Windows PowerShell 5.1 and pwsh 7 (no-BOM non-ASCII mojibakes on 5.1).

# --- Win32: bring a window to the front + maximize (fixes the minimized launch) -------------
if (-not ('NativeWin' -as [type])) {
    Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class NativeWin {
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int n);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
}
"@
}

# --- helpers -------------------------------------------------------------------------------
# Two-phase status line so it reads "  [+] label .......... status".
function Write-StepStart([string]$Label) {
    $dots = '.' * [Math]::Max(3, 16 - $Label.Length)
    Write-Host '  [+] ' -NoNewline -ForegroundColor Cyan
    Write-Host "$Label " -NoNewline -ForegroundColor Gray
    Write-Host "$dots " -NoNewline -ForegroundColor DarkGray
}
function Write-StepEnd([string]$Status, [string]$Color = 'Green') { Write-Host $Status -ForegroundColor $Color }
function Write-Note([string]$Text) { Write-Host "      $Text" -ForegroundColor Yellow }

# Current branch + dirty count for a repo (local git only — no network).
function Get-GitLine([string]$Repo) {
    $branch = (git -C $Repo rev-parse --abbrev-ref HEAD 2>$null)
    if (-not $branch) { return 'n/a' }
    $dirty = @(git -C $Repo status --porcelain 2>$null).Count
    $unpushed = (git -C $Repo rev-list '@{u}..HEAD' --count 2>$null)   # local only; blank if no upstream
    $bits = @()
    if ($dirty -gt 0) { $bits += "$dirty uncommitted" } else { $bits += 'clean' }
    if ($unpushed -and [int]$unpushed -gt 0) { $bits += "$unpushed unpushed" }
    return "$branch  ($($bits -join ', '))"
}

# ASCII box with a centered title; sizes itself to the widest line.
function Write-Card([string]$Title, [string[]]$Lines) {
    $inner = 0
    foreach ($l in $Lines) { if (($l.Length + 4) -gt $inner) { $inner = $l.Length + 4 } }
    if ($inner -lt ($Title.Length + 6)) { $inner = $Title.Length + 6 }
    $cap = " $Title "
    $rem = $inner - $cap.Length
    $lft = [Math]::Floor($rem / 2)
    Write-Host ('  +' + ('-' * $lft) + $cap + ('-' * ($rem - $lft)) + '+') -ForegroundColor DarkCyan
    foreach ($l in $Lines) {
        if ($l -eq '') {
            Write-Host ('  |' + (' ' * $inner) + '|') -ForegroundColor DarkCyan
        } else {
            Write-Host '  |  ' -NoNewline -ForegroundColor DarkCyan
            Write-Host $l -NoNewline -ForegroundColor Gray
            Write-Host ((' ' * ($inner - 2 - $l.Length)) + '|') -ForegroundColor DarkCyan
        }
    }
    Write-Host ('  +' + ('-' * $inner) + '+') -ForegroundColor DarkCyan
}

# Colorful tech boot intro + time-aware greeting.
& "$PSScriptRoot\samurai-greeting.ps1"
# -------------------------------------------------------------------------------------------

$admin = 'C:\Users\John Patrick Mandal\Desktop\samurai_cart_v3'
$store = 'C:\Users\John Patrick Mandal\Desktop\samurai_cart_v3_frontend'

# Make sure the Docker engine is up — launch Docker Desktop and wait (with a spinner) if it's closed.
docker info *> $null
if ($LASTEXITCODE -ne 0) {
    Write-Note 'Docker is not running — starting Docker Desktop (this can take a minute)...'
    Start-Process 'C:\Program Files\Docker\Docker\Docker Desktop.exe'
    $deadline = (Get-Date).AddMinutes(3)
    $spin = '|', '/', '-', '\'; $si = 0
    do {
        for ($t = 0; $t -lt 18; $t++) {   # animate ~2.7s between checks (docker info is slow while the daemon boots)
            Write-Host ("`r  [" + $spin[$si++ % 4] + '] waiting for Docker engine ...   ') -NoNewline -ForegroundColor DarkGray
            Start-Sleep -Milliseconds 150
        }
        docker info *> $null
        if ($LASTEXITCODE -eq 0) { break }
        if ((Get-Date) -gt $deadline) { Write-Host "`r" -NoNewline; Write-Note 'Docker did not start within 3 min — aborting.'; return }
    } while ($true)
    Write-Host ("`r" + (' ' * 40) + "`r") -NoNewline   # wipe the spinner line
}

# Bring up the whole stack (api, db, redis, celery, flower, pgadmin…) — output suppressed,
# run as a background job so we can animate a spinner instead of a frozen line while it works.
$job = Start-Job -ScriptBlock { Set-Location $using:admin; docker compose up -d *> $null }
$spin = '|', '/', '-', '\'; $si = 0
while ($job.State -eq 'Running') {
    Write-Host ("`r  [" + $spin[$si++ % 4] + '] starting containers ...   ') -NoNewline -ForegroundColor DarkGray
    Start-Sleep -Milliseconds 150
}
Remove-Job $job -Force -ErrorAction SilentlyContinue
Write-Host ("`r" + (' ' * 36) + "`r") -NoNewline   # wipe the spinner line
Push-Location $admin
$containers = @(docker compose ps -q 2>$null).Count
Pop-Location
Write-StepStart 'docker'
Write-StepEnd "up ($containers containers)"

# Open each repo in its own VS Code window (soft-skip if 'code' isn't found).
Write-StepStart 'vs code'
$codeOk = $true
try { code $admin 2>$null; code $store 2>$null } catch { $codeOk = $false }
if ($codeOk) { Write-StepEnd 'opened' } else { Write-StepEnd 'not found' 'Yellow' }

# Build the dev terminal. Capture existing WT processes first so we can focus the new one.
$before = @(Get-Process WindowsTerminal -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)

# Build the WHOLE window in ONE wt invocation so each split-pane attaches to the tab being built.
# (Separate `wt -w samurai` calls race on the active tab — that put the FE panes in a Claude tab.)
# The ';' array elements are wt's subcommand separators; pane commands stay ';'-free so nothing
# leaks into wt. `--suppressApplicationTitle` keeps OUR --title from being clobbered by claude/npm.
# Servers is a 2x2 quadrant: left col = backend (venv shell over api logs), right col = the two
# frontends. 'move-focus left' re-targets the left column before the api-logs split.
Write-StepStart 'dev terminal'
$wtArgs = @(
    '-w', 'samurai',
    'new-tab',    '--title', 'Servers',             '--suppressApplicationTitle', '-d', "$admin\backend",  'pwsh', '-NoExit', '-Command', '& .\venv\Scripts\Activate.ps1',
    ';', 'split-pane', '-V', '--suppressApplicationTitle', '-d', "$admin\frontend", 'pwsh', '-NoExit', '-Command', 'npm run dev',
    ';', 'split-pane', '-H', '--suppressApplicationTitle', '-d', $store,            'pwsh', '-NoExit', '-Command', 'npm run dev -- --port 3001',
    ';', 'move-focus', 'left',
    ';', 'split-pane', '-H', '--suppressApplicationTitle', '-d', $admin, 'pwsh', '-NoExit', '-Command', 'docker compose logs -f --tail=100 api',
    ';', 'new-tab', '--title', 'Claude - Admin',      '--suppressApplicationTitle', '-d', $admin,           'pwsh', '-NoExit', '-Command', 'claude',
    ';', 'new-tab', '--title', 'Claude - Storefront', '--suppressApplicationTitle', '-d', $store,           'pwsh', '-NoExit', '-Command', 'claude',
    ';', 'focus-tab', '-t', '0'   # land on the Servers tab
)
wt @wtArgs
Write-StepEnd 'ready'

# --- wait for the servers to actually answer (bounded), then report honest status -----------
# Bounded poll so "READY" isn't a lie — each service shows 'up' or 'starting' (still compiling).
function Test-Url([string]$Url) {
    try { return ((Invoke-WebRequest $Url -UseBasicParsing -TimeoutSec 2 -ErrorAction Stop).StatusCode -lt 500) }
    catch { return $false }
}
$deadline = (Get-Date).AddSeconds(20)
$spin = '|', '/', '-', '\'; $si = 0
$adminUp = $false; $storeUp = $false; $apiUp = $false
while ((Get-Date) -lt $deadline) {
    if (-not $adminUp) { $adminUp = Test-Url 'http://localhost:3000' }
    if (-not $storeUp) { $storeUp = Test-Url 'http://localhost:3001' }
    if (-not $apiUp)   { $apiUp   = Test-Url 'http://localhost:8000/docs' }
    if ($adminUp -and $storeUp -and $apiUp) { break }
    Write-Host ("`r  [" + $spin[$si++ % 4] + '] waiting for servers to answer ...   ') -NoNewline -ForegroundColor DarkGray
    Start-Sleep -Milliseconds 500
}
Write-Host ("`r" + (' ' * 44) + "`r") -NoNewline   # wipe the spinner line
function Get-State([bool]$b) { if ($b) { 'up' } else { 'starting' } }
$allUp = $adminUp -and $storeUp -and $apiUp
Write-StepStart 'servers'
Write-StepEnd ("admin $(Get-State $adminUp)  |  store $(Get-State $storeUp)  |  api $(Get-State $apiUp)") $(if ($allUp) { 'Green' } else { 'Yellow' })

# --- READY card (printed BEFORE the dev window grabs focus, so you actually see it) ---------
Write-Host ''
Write-Card 'READY' @(
    "admin   http://localhost:3000        [$(Get-State $adminUp)]",
    "store   http://localhost:3001        [$(Get-State $storeUp)]",
    "api     http://localhost:8000/docs   [$(Get-State $apiUp)]",
    '',
    "admin   $(Get-GitLine $admin)",
    "store   $(Get-GitLine $store)"
)
Write-Host ''

# Bring the freshly-created Terminal window to the front and maximize it (it tends to open behind).
Start-Sleep -Milliseconds 900
$wtProc = Get-Process WindowsTerminal -ErrorAction SilentlyContinue | Where-Object { $before -notcontains $_.Id } | Sort-Object StartTime | Select-Object -Last 1
if (-not $wtProc) { $wtProc = Get-Process WindowsTerminal -ErrorAction SilentlyContinue | Sort-Object StartTime | Select-Object -Last 1 }
if ($wtProc) {
    for ($i = 0; $i -lt 50; $i++) {
        $wtProc.Refresh()
        if ($wtProc.MainWindowHandle -ne 0) {
            [NativeWin]::ShowWindow($wtProc.MainWindowHandle, 3) | Out-Null   # 3 = maximize
            [NativeWin]::SetForegroundWindow($wtProc.MainWindowHandle) | Out-Null
            break
        }
        Start-Sleep -Milliseconds 100
    }
}

# (READY card now prints earlier — before the dev window grabs focus — see above.)
