<#
.SYNOPSIS
    Runs /fix-conflicts unattended against the open PRs that master has broken, resolving only the
    mechanically safe conflicts and stopping short of the push.

.DESCRIPTION
    Wrapper for the Windows Task Scheduler job "Samurai Fix Conflicts". Separate from the night
    shift on purpose: its own lock, its own log, its own failure domain, and a later trigger so the
    two never contend for the same worktrees.

    WHY THIS NEVER PUSHES. `/fix-conflicts` states the rule itself, at fix-conflicts.md:35: "The
    push is the gate, not the fix... Show the resolution diff and wait for a typed yes before each
    push. Auto-approve does not satisfy this." These branches carry approved PRs, and a push
    changes a tree a reviewer already signed off on. So the night does the work and leaves the
    push, which is the ten-second half, for the morning. That rule is enforced twice over: the
    prompt passes --no-push, and the permission profile denies Bash(git push:*) outright, so an
    instruction being misread cannot turn into a push that happened.

    NO CONFLICTS MEANS NO RUN. The conflicting PRs are surveyed here, in PowerShell, with a plain
    `gh` call before claude.exe is launched at all. A quiet night therefore costs nothing and
    writes no report, rather than spending a session to discover there was nothing to do.

    Both repos are surveyed, not just the admin one, because an unrun check that reads as a clean
    result is the failure this house style exists to avoid. Known limitation: if BOTH repos have
    conflicts on the same day, the second pass overwrites the first's report, since /fix-conflicts
    names it by date alone. That case is logged loudly rather than silently tolerated.

    Two logs, on purpose:
      - fix-conflicts-<jst-date>.log  verbose, everything claude printed, 30 days retained
      - fix-conflicts-history.txt     one line per run, appended forever, the file to actually read

    TIMEZONE: this machine runs Singapore time (UTC+8) but reports are dated JST (UTC+9). Every
    date here is computed as JST explicitly. Never substitute Get-Date, and remember the scheduled
    trigger fires on LOCAL time, so a 10pm JST run is a 9pm SGT trigger.

.PARAMETER DryRun
    Survey the conflicts, print the exact claude.exe invocation, and exit without running it.
    Writes no log and no history line.

.PARAMETER NoRun
    Dot-source the functions without executing. For the tests.

.EXAMPLE
    .\samurai-fix-conflicts.ps1
    .\samurai-fix-conflicts.ps1 -DryRun
#>
[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$NoRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ClaudeExe    = 'C:\Users\john\.local\bin\claude.exe'
$RepoDir      = 'C:\Users\john\Desktop\samurai_cart_v3'
$VaultReports = 'C:\Users\john\Documents\Patrick Obsidian\Patrick\reports'
$SettingsFile = 'C:\Users\john\scripts\fix-conflicts-scheduled.settings.json'
$LogDir       = 'C:\Users\john\scripts\logs'
$LockFile     = Join-Path $env:TEMP 'samurai-fix-conflicts.lock'
$LogRetention = 30

# See the note in samurai-night-shift.ps1: a bare [uint32]0x80000000 literal throws on this
# machine because the hex parses as a negative Int32 before the checked cast runs.
$EsContinuous     = [Convert]::ToUInt32('80000000', 16)
$EsSystemRequired = [uint32]0x00000001

$Repos = @(
    [pscustomobject]@{ Name = 'admin';      Slug = 'f-i-d/samurai_cart_v3';          RepoFlag = '' }
    [pscustomobject]@{ Name = 'storefront'; Slug = 'f-i-d/samurai_cart_v3_frontend'; RepoFlag = '--repo storefront' }
)

$JstNow  = [System.TimeZoneInfo]::ConvertTimeBySystemTimeZoneId([DateTime]::UtcNow, 'Tokyo Standard Time')
$JstDate = $JstNow.ToString('yyyy-MM-dd')

if (-not $NoRun -and -not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
$LogFile     = Join-Path $LogDir "fix-conflicts-$JstDate.log"
$HistoryFile = Join-Path $LogDir 'fix-conflicts-history.txt'

$script:Outcome     = 'CRASH'
$script:Detail      = 'script exited before reaching an outcome'
$script:Found       = 0
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

# The function that decides whether the night does anything at all. GitHub computes mergeability
# asynchronously and answers UNKNOWN until it has, so UNKNOWN is excluded rather than guessed at:
# treating it as a conflict would have the run resolve branches that are perfectly fine.
# The leading comma forces an array back even for one match, so the caller's .Count is real.
function Get-ConflictingPrNumbers {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Json)
    if ([string]::IsNullOrWhiteSpace($Json)) { return ,@() }
    try {
        $parsed = $Json | ConvertFrom-Json
    } catch {
        return ,@()
    }
    if ($null -eq $parsed) { return ,@() }
    $out = @()
    foreach ($pr in @($parsed)) {
        if ($pr.PSObject.Properties.Name -contains 'mergeable' -and $pr.mergeable -eq 'CONFLICTING') {
            $out += [int]$pr.number
        }
    }
    return ,$out
}

function Get-RepoConflicts {
    param([Parameter(Mandatory)][string]$Slug)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $json = (& gh pr list --repo $Slug --author '@me' --state open --limit 100 `
                    --json number,mergeable 2>&1 | Out-String)
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $prev }
    if ($code -ne 0) {
        throw "gh pr list failed for $Slug (exit $code): $($json.Trim())"
    }
    return Get-ConflictingPrNumbers -Json $json
}

function Enter-PowerHold {
    try {
        if (-not ('FixConflicts.PowerUtil' -as [type])) {
            Add-Type -Namespace FixConflicts -Name PowerUtil -MemberDefinition @'
[DllImport("kernel32.dll", SetLastError = true)]
public static extern uint SetThreadExecutionState(uint esFlags);
'@
        }
        $previous = [FixConflicts.PowerUtil]::SetThreadExecutionState($EsContinuous -bor $EsSystemRequired)
        if ($previous -eq 0) {
            Write-Log 'SetThreadExecutionState returned failure. Continuing without the power hold; the machine may sleep mid-run.' 'WARN'
        } else {
            Write-Log 'Power hold taken (ES_SYSTEM_REQUIRED): the system will not idle-sleep for the duration of this run. Display sleep is unaffected.'
        }
    } catch {
        Write-Log "Could not take the power hold: $($_.Exception.Message). Continuing without it; the machine may sleep mid-run." 'WARN'
    }
}

function Exit-PowerHold {
    try {
        if ('FixConflicts.PowerUtil' -as [type]) {
            [FixConflicts.PowerUtil]::SetThreadExecutionState($EsContinuous) | Out-Null
        }
    } catch { }
}

function Write-History {
    if ($script:HistoryDone) { return }
    $script:HistoryDone = $true

    if (-not (Test-Path $HistoryFile)) {
        @(
            '# /fix-conflicts run history. One line per run, newest at the bottom. Safe to delete.',
            '# Written by samurai-fix-conflicts.ps1. Full output: fix-conflicts-<jst-date>.log',
            '#',
            '# OK   = conflicts found and a report was written   NOOP = no conflicting PRs, nothing run',
            '# FAIL = the run produced nothing usable            SKIP = another run held the lock',
            '# CRASH = the wrapper itself broke',
            '#',
            '# Nothing here is ever pushed. Resolutions wait in their worktrees for a typed yes.',
            '#',
            '# started (JST)     outcome  mins  found  detail'
        ) | Set-Content -Path $HistoryFile -Encoding utf8
    }

    $mins = [int]((Get-JstNow) - $RunStartJst).TotalMinutes
    $line = '{0,-19} {1,-8} {2,4} {3,6}  {4}' -f `
        $RunStartJst.ToString('yyyy-MM-dd HH:mm'), $script:Outcome, $mins, $script:Found, $script:Detail
    Add-Content -Path $HistoryFile -Value $line.TrimEnd() -Encoding utf8
}

if ($NoRun) { return }

# ---------------------------------------------------------------------------------------------
# Survey first. A quiet night must cost nothing, so this runs before the lock and before claude.
# ---------------------------------------------------------------------------------------------
$work = @()
try {
    foreach ($repo in $Repos) {
        $numbers = Get-RepoConflicts -Slug $repo.Slug
        if ($numbers.Count -gt 0) {
            $work += [pscustomobject]@{ Repo = $repo; Numbers = $numbers }
        }
    }
} catch {
    if (-not $DryRun) {
        Write-Log "Survey failed: $($_.Exception.Message)" 'ERROR'
        $script:Outcome = 'FAIL'
        $script:Detail  = "survey failed: $($_.Exception.Message -replace '\s+', ' ')"
        Write-History
    } else {
        Write-Output "survey failed: $($_.Exception.Message)"
    }
    exit 1
}

$script:Found = ($work | ForEach-Object { $_.Numbers.Count } | Measure-Object -Sum).Sum
if ($null -eq $script:Found) { $script:Found = 0 }

if ($DryRun) {
    Write-Output "working dir : $RepoDir"
    Write-Output "report due  : $(Join-Path $VaultReports "pr-conflicts-$JstDate.md")"
    Write-Output "log         : $LogFile"
    Write-Output "history     : $HistoryFile"
    Write-Output "lock held   : $(Test-Path $LockFile)"
    Write-Output "settings    : $SettingsFile"
    Write-Output ''
    if ($script:Found -eq 0) {
        Write-Output 'conflicts   : none in either repo. A real run would do nothing and write no report.'
    } else {
        Write-Output "conflicts   : $($script:Found) across $($work.Count) repo(s)"
        foreach ($w in $work) {
            $prompt = "/fix-conflicts --no-push $($w.Repo.RepoFlag)".Trim()
            Write-Output ''
            Write-Output "  repo      : $($w.Repo.Name) ($($w.Repo.Slug))"
            Write-Output "  PRs       : $($w.Numbers -join ', ')"
            Write-Output "  prompt    : $prompt"
            Write-Output "  command   : `"$ClaudeExe`" -p <prompt> --settings $SettingsFile --permission-mode acceptEdits --permission-prompts none"
        }
    }
    $script:HistoryDone = $true   # a dry run is not a run
    exit 0
}

if ($script:Found -eq 0) {
    Write-Log 'No conflicting PRs in either repo. Nothing to resolve; not starting a session.'
    $script:Outcome = 'NOOP'
    $script:Detail  = 'no conflicting PRs, nothing run'
    Write-History
    exit 0
}

if ($work.Count -gt 1) {
    Write-Log ("Both repos have conflicts. /fix-conflicts names its report by date alone, so the " +
               "second pass will overwrite the first's report. Read the log for the full picture.") 'WARN'
}

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
$failures = @()

try {
    Enter-PowerHold
    Write-Log "Starting /fix-conflicts for $JstDate (machine local $(Get-Date -Format 'HH:mm') SGT). Found $($script:Found) conflicting PR(s)."
    Write-Log 'This run never pushes. Resolutions are left in their worktrees for a typed yes in the morning.'

    foreach ($w in $work) {
        $prompt = "/fix-conflicts --no-push $($w.Repo.RepoFlag)".Trim()
        Write-Log "=== $($w.Repo.Name): PR(s) $($w.Numbers -join ', ') ==="
        Push-Location $RepoDir
        try {
            & $ClaudeExe -p $prompt --settings $SettingsFile `
                --permission-mode acceptEdits --permission-prompts none 2>&1 |
                ForEach-Object { Add-Content -Path $LogFile -Value $_ -Encoding utf8 }
            $code = $LASTEXITCODE
        } finally {
            Pop-Location
        }
        if ($code -ne 0) {
            Write-Log "$($w.Repo.Name): claude.exe exited $code." 'ERROR'
            $failures += "$($w.Repo.Name) exited $code"
        } else {
            Write-Log "$($w.Repo.Name): pass finished."
        }
    }

    $elapsed = [int]((Get-Date) - $started).TotalMinutes
    $report  = Join-Path $VaultReports "pr-conflicts-$JstDate.md"

    if (-not (Test-Path $report)) {
        Write-Log "No report at $report after $elapsed min. The run produced nothing usable." 'ERROR'
        $script:Outcome = 'FAIL'
        $script:Detail  = "no report for $JstDate was written"
        exit 2
    }
    if ((Get-Item $report).LastWriteTime -lt $started) {
        Write-Log "$report exists but predates this run. Treating as not written." 'ERROR'
        $script:Outcome = 'FAIL'
        $script:Detail  = "report for $JstDate predates this run, nothing was refreshed"
        exit 2
    }

    $sizeKb = [math]::Round((Get-Item $report).Length / 1KB, 1)
    Write-Log "Report written: $report ($sizeKb KB). Nothing was pushed."
    if ($failures.Count -gt 0) {
        $script:Outcome = 'FAIL'
        $script:Detail  = "report written but " + ($failures -join '; ')
        exit 1
    }
    $script:Outcome = 'OK'
    $script:Detail  = "pr-conflicts-$JstDate.md, $sizeKb KB, nothing pushed"
    exit 0
}
catch {
    Write-Log "Wrapper failed: $($_.Exception.Message)" 'ERROR'
    $script:Outcome = 'CRASH'
    $script:Detail  = $_.Exception.Message -replace '\s+', ' '
    exit 4
}
finally {
    Exit-PowerHold
    Write-History
    Remove-Item $LockFile -Force -ErrorAction SilentlyContinue
    Get-ChildItem $LogDir -Filter 'fix-conflicts-*.log' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -Skip $LogRetention |
        Remove-Item -Force -ErrorAction SilentlyContinue
}
