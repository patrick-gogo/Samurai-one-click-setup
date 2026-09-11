<#
.SYNOPSIS
    Runs the /open-tickets module census unattended, verifies it actually produced a report, and
    appends one line per run to a human-readable history file.

.DESCRIPTION
    Wrapper for the Windows Task Scheduler job "Samurai Open Tickets Census". Launches Claude Code
    in print mode against the samurai_cart_v3 checkout, with a permission scope narrow enough that
    the run can only read Jira/GitHub and write the vault report plus its Notion mirror.

    Exit code is NOT taken from claude.exe alone. `claude -p` can exit 0 having produced nothing
    useful, so success here means "a report file for today's JST date exists and was written by
    this run". That is the only signal worth waking up to.

    Two logs, on purpose:
      - open-tickets-<jst-date>.log  verbose, everything claude printed, 30 days retained
      - open-tickets-history.txt     one line per run, appended forever, the file to actually read

    TIMEZONE: this machine runs Singapore time (UTC+8) but the reports are dated in JST (UTC+9).
    Every date here is computed as JST explicitly. Never substitute Get-Date, and remember the
    scheduled trigger fires on LOCAL time, so a 08:00 JST run is a 07:00 SGT trigger.

.PARAMETER ChatOnly
    Pass --chat-only to the command: no vault write, no Notion mirror. Skips the report check.

.PARAMETER DryRun
    Print the exact claude.exe invocation and exit without running it.

.EXAMPLE
    .\samurai-open-tickets.ps1
    .\samurai-open-tickets.ps1 -DryRun
#>
[CmdletBinding()]
param(
    [switch]$ChatOnly,
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ClaudeExe    = 'C:\Users\john\.local\bin\claude.exe'
$RepoDir      = 'C:\Users\john\Desktop\samurai_cart_v3'
$VaultReports = 'C:\Users\john\Documents\Patrick Obsidian\Patrick\reports'
$SettingsFile = 'C:\Users\john\scripts\open-tickets-scheduled.settings.json'
$LogDir       = 'C:\Users\john\scripts\logs'
$LockFile     = Join-Path $env:TEMP 'samurai-open-tickets.lock'
$LogRetention = 30

# Reports are dated JST regardless of this machine's Singapore clock.
$JstNow  = [System.TimeZoneInfo]::ConvertTimeBySystemTimeZoneId([DateTime]::UtcNow, 'Tokyo Standard Time')
$JstDate = $JstNow.ToString('yyyy-MM-dd')

if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
$LogFile     = Join-Path $LogDir "open-tickets-$JstDate.log"
$HistoryFile = Join-Path $LogDir 'open-tickets-history.txt'

# Filled in as the run progresses; written to the history file on every exit path, including a crash.
$script:Outcome     = 'CRASH'
$script:Detail      = 'script exited before reaching an outcome'
$script:OpenTotal   = '-'
$script:WithPr      = '-'
$script:HistoryDone = $false
$RunStartJst = $JstNow

function Get-JstNow {
    [System.TimeZoneInfo]::ConvertTimeBySystemTimeZoneId([DateTime]::UtcNow, 'Tokyo Standard Time')
}

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = "[$((Get-JstNow).ToString('HH:mm:ss')) JST] [$Level] $Message"
    Write-Output $line
    Add-Content -Path $LogFile -Value $line -Encoding utf8
}

# Reads the last run that recorded a ticket total, so the history can show a day-over-day delta.
function Get-PreviousTotal {
    if (-not (Test-Path $HistoryFile)) { return $null }
    $prev = $null
    foreach ($line in Get-Content $HistoryFile) {
        if ($line -match '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}\s+\S+\s+\S+\s+(\d+)\s') { $prev = [int]$Matches[1] }
    }
    return $prev
}

# Pulls the headline numbers straight out of the report the run just wrote, so the history line says
# what the census found rather than only that it finished.
function Read-ReportFacts {
    param([string]$Path)
    try {
        $text = Get-Content $Path -Raw -Encoding utf8
        if ($text -match '\*\*(\d+) open tickets\*\*')                       { $script:OpenTotal = $Matches[1] }
        if ($text -match '\|\s*\*\*Has an open PR\*\*\s*\|\s*\*\*(\d+)\*\*') { $script:WithPr    = $Matches[1] }
    } catch {
        Write-Log "Could not parse headline numbers out of the report: $($_.Exception.Message)" 'WARN'
    }
}

function Write-History {
    if ($script:HistoryDone) { return }
    $script:HistoryDone = $true

    if (-not (Test-Path $HistoryFile)) {
        @(
            '# /open-tickets run history. One line per run, newest at the bottom. Safe to delete.',
            '# Written by samurai-open-tickets.ps1. Full per-run output: open-tickets-<jst-date>.log',
            '#',
            '# OK   = report written and verified   FAIL = run produced nothing usable',
            '# SKIP = another run held the lock     CRASH = the wrapper itself broke',
            '#',
            '# started (JST)     outcome  mins   open  delta   w/PR  detail'
        ) | Set-Content -Path $HistoryFile -Encoding utf8
    }

    $mins  = [int]((Get-JstNow) - $RunStartJst).TotalMinutes
    $delta = '-'
    if ($script:OpenTotal -ne '-') {
        $prev = Get-PreviousTotal
        if ($null -ne $prev) {
            $d = [int]$script:OpenTotal - $prev
            $delta = if ($d -gt 0) { "+$d" } elseif ($d -lt 0) { "$d" } else { '0' }
        } else {
            $delta = 'first'
        }
    }

    $line = '{0,-19} {1,-8} {2,4} {3,6} {4,6} {5,6}  {6}' -f `
        $RunStartJst.ToString('yyyy-MM-dd HH:mm'), $script:Outcome, $mins,
        $script:OpenTotal, $delta, $script:WithPr, $script:Detail
    Add-Content -Path $HistoryFile -Value $line.TrimEnd() -Encoding utf8
}

$prompt = if ($ChatOnly) { '/open-tickets --chat-only' } else { '/open-tickets' }
$claudeArgs = @(
    '-p', $prompt,
    '--settings', $SettingsFile,
    '--permission-mode', 'acceptEdits',
    '--permission-prompts', 'none'
)

# Before the lock check on purpose: a dry run starts nothing, so it must not care whether a real run
# is in flight, and must never leave a line in the history file.
if ($DryRun) {
    $shown = $claudeArgs | ForEach-Object { if ($_ -match '\s') { "`"$_`"" } else { $_ } }
    Write-Output "working dir : $RepoDir"
    Write-Output "report due  : $(Join-Path $VaultReports "open-tickets-by-module-$JstDate.md")"
    Write-Output "log         : $LogFile"
    Write-Output "history     : $HistoryFile"
    Write-Output "lock held   : $(Test-Path $LockFile)"
    Write-Output "command     : `"$ClaudeExe`" $($shown -join ' ')"
    $script:HistoryDone = $true   # a dry run is not a run
    exit 0
}

# A second run while the first is still going would collide on the shared Composio remote sandbox,
# where both would write /mnt/files/mex/tape.json and read back each other's rows.
if (Test-Path $LockFile) {
    $age = (Get-Date) - (Get-Item $LockFile).LastWriteTime
    if ($age.TotalHours -lt 3) {
        Write-Log "A run started $([int]$age.TotalMinutes) min ago is still holding the lock. Exiting." 'WARN'
        $script:Outcome = 'SKIP'
        $script:Detail  = "another run started $([int]$age.TotalMinutes) min ago still held the lock"
        Write-History
        exit 3
    }
    Write-Log "Clearing a stale lock ($([int]$age.TotalHours)h old)." 'WARN'
    Remove-Item $LockFile -Force
}

New-Item -ItemType File -Path $LockFile -Force | Out-Null
$started = Get-Date
$exitCode = 0

try {
    Write-Log "Starting /open-tickets for $JstDate (machine local $(Get-Date -Format 'HH:mm') SGT)."
    Push-Location $RepoDir
    try {
        & $ClaudeExe @claudeArgs 2>&1 | ForEach-Object { Add-Content -Path $LogFile -Value $_ -Encoding utf8 }
        $exitCode = $LASTEXITCODE
    } finally {
        Pop-Location
    }

    $elapsed = [int]((Get-Date) - $started).TotalMinutes
    if ($exitCode -ne 0) {
        Write-Log "claude.exe exited $exitCode after $elapsed min. See $LogFile." 'ERROR'
        $script:Outcome = 'FAIL'
        $script:Detail  = "claude exited $exitCode, see open-tickets-$JstDate.log"
        exit 1
    }
    Write-Log "claude.exe finished in $elapsed min."

    if ($ChatOnly) {
        Write-Log '--chat-only: skipping the report check.'
        $script:Outcome = 'OK'
        $script:Detail  = 'chat-only, no report written'
        exit 0
    }

    # The real success test. An exit of 0 with no fresh report means the run gave up part way.
    $report = Join-Path $VaultReports "open-tickets-by-module-$JstDate.md"
    if (-not (Test-Path $report)) {
        Write-Log "No report at $report. The run produced nothing usable." 'ERROR'
        $script:Outcome = 'FAIL'
        $script:Detail  = "no report for $JstDate was written"
        exit 2
    }
    $written = (Get-Item $report).LastWriteTime
    if ($written -lt $started) {
        Write-Log "$report exists but predates this run ($written). Treating as not written." 'ERROR'
        $script:Outcome = 'FAIL'
        $script:Detail  = "report for $JstDate predates this run, nothing was refreshed"
        exit 2
    }

    $sizeKb = [math]::Round((Get-Item $report).Length / 1KB, 1)
    Read-ReportFacts -Path $report
    Write-Log "Report written: $report ($sizeKb KB)."
    $script:Outcome = 'OK'
    $script:Detail  = "open-tickets-by-module-$JstDate.md, $sizeKb KB"
    exit 0
}
catch {
    Write-Log "Wrapper failed: $($_.Exception.Message)" 'ERROR'
    $script:Outcome = 'CRASH'
    $script:Detail  = $_.Exception.Message -replace '\s+', ' '
    exit 4
}
finally {
    Write-History
    Remove-Item $LockFile -Force -ErrorAction SilentlyContinue
    Get-ChildItem $LogDir -Filter 'open-tickets-*.log' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -Skip $LogRetention |
        Remove-Item -Force -ErrorAction SilentlyContinue
}
