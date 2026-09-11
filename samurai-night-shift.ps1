<#
.SYNOPSIS
    Runs /night-prep once per queued ticket, unattended, verifies each dossier actually landed on
    disk, and appends one line per run to a human-readable history file.

.DESCRIPTION
    Wrapper for the Windows Task Scheduler job "Samurai Night Shift". Launches Claude Code in print
    mode once per ticket in the night-shift queue, each ticket as its own process, so a crash or
    timeout on one ticket does not lose the rest of the night.

    Exit code is NOT taken from claude.exe alone. `claude -p` can exit 0 having produced nothing, so
    success for a ticket means "a dossier for today's JST date exists on disk, was written by this
    run, and ends with the dossier's own completion sentinel". That is the only signal worth waking
    up to. A dossier that exists but is missing `<!-- dossier-end -->` was killed mid-write and is
    treated the same as no dossier at all.

    The queue is read straight off disk: `night-shift\queue.md` in the vault, no git involved. The
    user edits this file directly in Obsidian on this machine, which is the normal case by a wide
    margin, and an uncommitted edit is exactly what this run is meant to see. Reading a committed
    copy from the remote instead would mean a run silently used stale content and ignored what was
    actually typed, with no visible symptom, so there is no git fetch and no fallback here at all.

    Two logs, on purpose:
      - night-shift-<jst-date>.log   verbose, everything claude printed per ticket, 30 days retained
      - night-shift-history.txt      one line per RUN (not per ticket), appended forever

    TIMEZONE: this machine runs Singapore time (UTC+8) but dossiers are dated in JST (UTC+9). Every
    date here is computed as JST explicitly. Never substitute Get-Date for a date that names a file.
    The scheduled trigger fires on LOCAL time and is deliberately set to 19:00 SGT, which is 20:00
    JST, so a normal night's log lines and history entry are stamped 20:00 JST. Read a trigger time
    as local and a log time as JST; they are an hour apart by design, not by mistake.

    This wrapper never commits and never pushes anything. Dossiers are left on disk for the user to
    read the next morning.

    At the end of every real run (success, partial, total failure, or a wrapper crash) it sends one
    Chatwork message summarizing the night, so the user knows from home whether it ran and how it
    went, without opening a laptop. This goes through a second, tiny `claude -p` pass, because there
    is no Chatwork API token on this machine, only the Composio connection Claude Code already has.
    That pass reads night-notify-scheduled.settings.json, which allows nothing but `Read` and the
    Composio tools, and can only read one message file and post one message. The message always goes
    to Chatwork room 442797406, the user's own private room. It must NEVER go to 404861709, the
    shared V3 team room `open-pr.md` forbids auto-posting to; the room ID is a named constant for
    exactly this reason. A run held up by another run's lock (a `SKIP`) does not notify, since that
    other run will send the real notification when it finishes; a dry run never notifies either. A
    failed send is logged and never fails the underlying run.

    The laptop's idle-sleep timer counts from the user's last keyboard or mouse input, not from when
    this script started, and a background process does not stop Windows sleeping on its own. A run
    slept mid-way leaves a half-written dossier, which is worse than not running at all. So a real run
    takes a `SetThreadExecutionState` power hold (`ES_SYSTEM_REQUIRED`, screen left free to sleep) the
    moment the lock is acquired, and releases it unconditionally in the `finally` block, on every exit
    path including a crash, so a broken run can never leave the machine permanently unable to sleep.

    Every ticket's claude process runs against a pinned, detached worktree at `ns-master`
    (`<worktrees folder>\ns-master`), refreshed to the tip of `origin/master` at the start of every
    run, never against the user's main checkout. The main checkout sits on whatever feature branch he
    is mid-work on, with uncommitted edits, and a dossier's `file:line` citations need to still be
    true tomorrow, which a feature branch cannot promise. This is a deliberate exception to the normal
    house rule of working tickets in the main checkout: `ns-master` holds no branch (detached HEAD
    only, never checked out to one), is never opened in an editor, and exists purely so the citations
    are pinned to a tree that still exists in the morning. If fetching, creating, or refreshing it
    fails for any reason, the whole run aborts as a `CRASH` rather than silently falling back to the
    main checkout, since a dossier citing the wrong tree while looking normal is worse than no run.

.PARAMETER MaxTickets
    How many queued tickets to run this session. Default 2. Tickets past the cap are left in the
    queue for the next run.

.PARAMETER DryRun
    Read the queue, print what would run for each ticket up to the cap, and start nothing. Writes no
    log file and no history line, and sends no Chatwork notification.

.PARAMETER NoNotify
    Run normally but skip the end-of-run Chatwork notification. For manual testing, so a test run
    doesn't page the user.

.EXAMPLE
    .\samurai-night-shift.ps1
    .\samurai-night-shift.ps1 -DryRun
    .\samurai-night-shift.ps1 -MaxTickets 1
    .\samurai-night-shift.ps1 -NoNotify
#>
[CmdletBinding()]
param(
    [int]$MaxTickets = 2,
    [switch]$DryRun,
    [switch]$NoNotify
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ClaudeExe            = 'C:\Users\john\.local\bin\claude.exe'
# The user's main checkout. Used ONLY as the source for `git fetch` and `git worktree add`; never as
# the tree any claude process reads or is started in. It sits on whatever feature branch the user is
# mid-work on, with uncommitted edits, and must be byte-identical before and after every run.
$RepoDir              = 'C:\Users\john\Desktop\samurai_cart_v3'
# A pinned, detached worktree checked out to origin/master, refreshed at the start of every run. Every
# ticket's claude process runs here (see Enter-NsMasterWorktree), so a dossier's file:line citations
# point at a tree that still exists tomorrow instead of the user's feature branch. `ns-` distinguishes
# it from the `wt-` ticket worktrees and `rv-` review worktrees already in the same parent folder.
$NsMasterDir          = 'C:\Users\john\Desktop\samurai_cart_v3 worktrees\ns-master'
$VaultRoot            = 'C:\Users\john\Documents\Patrick Obsidian\Patrick'
$QueueLocalFile       = Join-Path $VaultRoot 'night-shift\queue.md'
$VaultNightShift      = Join-Path $VaultRoot 'night-shift'
$SettingsFile         = 'C:\Users\john\scripts\night-prep-scheduled.settings.json'
$NotifySettingsFile   = 'C:\Users\john\scripts\night-notify-scheduled.settings.json'
$LogDir               = 'C:\Users\john\scripts\logs'
$LockFile             = Join-Path $env:TEMP 'samurai-night-shift.lock'
$LogRetention         = 30
$TicketTimeoutMinutes = 25
$NotifyTimeoutMinutes = 2

# The user's own private "Draft Outbox" room. NEVER 404861709: that is the shared V3 team room, and
# open-pr.md explicitly forbids auto-posting there. Hard-coded here on purpose so nobody swaps it.
$ChatworkNotifyRoomId = '442797406'

# ES_CONTINUOUS (0x80000000), for SetThreadExecutionState. Built via [Convert]::ToUInt32, not a bare
# [uint32]0x80000000 literal: that cast throws "value was either too large or too small for a
# UInt32" on this machine, because the hex literal parses as a negative Int32 before the cast ever
# runs, and PowerShell's [uint32] cast is checked. Convert.ToUInt32 parses the hex text directly as
# unsigned and sidesteps the whole problem.
$EsContinuous = [Convert]::ToUInt32('80000000', 16)
$EsSystemRequired = [uint32]0x00000001

# Dossiers are dated JST regardless of this machine's Singapore clock.
$JstNow  = [System.TimeZoneInfo]::ConvertTimeBySystemTimeZoneId([DateTime]::UtcNow, 'Tokyo Standard Time')
$JstDate = $JstNow.ToString('yyyy-MM-dd')

if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
$LogFile     = Join-Path $LogDir "night-shift-$JstDate.log"
$HistoryFile = Join-Path $LogDir 'night-shift-history.txt'

# Filled in as the run progresses; written to the history file on every exit path, including a crash.
$script:Outcome     = 'CRASH'
$script:Detail      = 'script exited before reaching an outcome'
$script:HistoryDone = $false
$script:Attempted   = 0
$script:Prepped     = 0
$script:Skipped     = 0
$script:Failed      = 0
$script:TimedOut    = 0
$script:TicketResults = @()
$RunStartJst = $JstNow

function Get-JstNow {
    [System.TimeZoneInfo]::ConvertTimeBySystemTimeZoneId([DateTime]::UtcNow, 'Tokyo Standard Time')
}

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = "[$((Get-JstNow).ToString('HH:mm:ss')) JST] [$Level] $Message"
    # Write-Host, not Write-Output: this function is called from inside Get-QueueContent and
    # Get-ParsedTickets, whose own return values are captured by the caller. Write-Output would
    # join that captured pipeline and silently corrupt the real return value with log lines.
    Write-Host $line
    # A dry run must start nothing, including a log file, so it only ever prints to the console.
    if (-not $DryRun) { Add-Content -Path $LogFile -Value $line -Encoding utf8 }
}

# Keeps the system out of idle sleep for the duration of a real run, via SetThreadExecutionState
# (kernel32.dll). ES_SYSTEM_REQUIRED only, never ES_DISPLAY_REQUIRED: the screen is free to sleep,
# only the system must stay up. Never throws; a failure to take the hold is a warning, not a reason
# to abort the run.
function Enter-PowerHold {
    try {
        if (-not ('NightShift.PowerUtil' -as [type])) {
            Add-Type -Namespace NightShift -Name PowerUtil -MemberDefinition @'
[DllImport("kernel32.dll", SetLastError = true)]
public static extern uint SetThreadExecutionState(uint esFlags);
'@
        }
        $previous = [NightShift.PowerUtil]::SetThreadExecutionState($EsContinuous -bor $EsSystemRequired)
        if ($previous -eq 0) {
            Write-Log 'SetThreadExecutionState returned failure. Continuing without the power hold; the machine may sleep mid-run.' 'WARN'
        } else {
            Write-Log 'Power hold taken (ES_SYSTEM_REQUIRED): the system will not idle-sleep for the duration of this run. Display sleep is unaffected.'
        }
    } catch {
        Write-Log "Could not take the power hold: $($_.Exception.Message). Continuing without it; the machine may sleep mid-run." 'WARN'
    }
}

# Unconditional release, called from the finally block on every exit path including a crash. Calling
# this even when Enter-PowerHold never ran, or failed, is harmless: SetThreadExecutionState(ES_
# CONTINUOUS) alone just clears whichever hold (if any) this thread was holding.
function Exit-PowerHold {
    try {
        if (-not ('NightShift.PowerUtil' -as [type])) {
            Add-Type -Namespace NightShift -Name PowerUtil -MemberDefinition @'
[DllImport("kernel32.dll", SetLastError = true)]
public static extern uint SetThreadExecutionState(uint esFlags);
'@
        }
        [NightShift.PowerUtil]::SetThreadExecutionState($EsContinuous) | Out-Null
        Write-Log 'Power hold released.'
    } catch {
        Write-Log "Could not release the power hold: $($_.Exception.Message)" 'WARN'
    }
}

function Write-History {
    if ($script:HistoryDone) { return }
    $script:HistoryDone = $true

    if (-not (Test-Path $HistoryFile)) {
        @(
            '# /night-prep run history. One line per RUN (not per ticket), newest at the bottom. Safe to delete.',
            '# Written by samurai-night-shift.ps1. Full per-ticket output: night-shift-<jst-date>.log',
            '#',
            '# OK      = every attempted ticket was prepped or cleanly skipped',
            '# PARTIAL = some tickets prepped or skipped, some failed or timed out',
            '# FAIL    = every attempted ticket failed or timed out',
            '# SKIP    = another run held the lock          CRASH = the wrapper itself broke',
            '#',
            '# The trailing notify=... field is filled in after the run, once the Chatwork send has been',
            '# attempted (or skipped). A line stuck on notify=pending means the wrapper died before it could',
            '# record the result; a stuck notify=pending is itself worth noticing.',
            '#',
            '# started (JST)     outcome   mins  attempt  prepped  skipped  failed  timeout  detail'
        ) | Set-Content -Path $HistoryFile -Encoding utf8
    }

    $mins = [int]((Get-JstNow) - $RunStartJst).TotalMinutes
    $line = '{0,-19} {1,-7} {2,4} {3,7} {4,7} {5,7} {6,6} {7,7}  {8}  notify=pending' -f `
        $RunStartJst.ToString('yyyy-MM-dd HH:mm'), $script:Outcome, $mins,
        $script:Attempted, $script:Prepped, $script:Skipped, $script:Failed, $script:TimedOut, $script:Detail
    Add-Content -Path $HistoryFile -Value $line.TrimEnd() -Encoding utf8
}

# The notification is sent AFTER the history line is written (so a crash mid-send never costs the
# line itself), then this patches that same line's trailing notify=pending with the real outcome.
# Only ever touches the very last line, which this run just appended.
function Set-HistoryNotifyStatus {
    param([string]$Status)
    try {
        if (-not (Test-Path $HistoryFile)) { return }
        $content = @(Get-Content -Path $HistoryFile -Encoding utf8)
        if ($content.Count -eq 0) { return }
        $lastIndex = $content.Count - 1
        $content[$lastIndex] = $content[$lastIndex] -replace 'notify=pending$', "notify=$Status"
        Set-Content -Path $HistoryFile -Value $content -Encoding utf8
    } catch {
        Write-Log "Could not record the notification status in the history file: $($_.Exception.Message)" 'WARN'
    }
}

# Checks the dossier's own completion sentinel, not just its presence. A run killed mid-write can
# leave a file at the right path with a fresh timestamp; only the last non-blank line being the
# literal `<!-- dossier-end -->` marker means the write actually finished.
function Test-DossierComplete {
    param([string]$Path)
    try {
        $lines = Get-Content -Path $Path -Encoding utf8
    } catch {
        return $false
    }
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        $t = $lines[$i].Trim()
        if ($t -eq '') { continue }
        return ($t -eq '<!-- dossier-end -->')
    }
    return $false
}

# Pulls the two headline numbers out of a dossier's own YAML frontmatter, for the notification. Both
# come back $null if the file can't be read or the fields aren't there, so the caller decides how to
# render a missing number rather than this function guessing.
function Get-DossierFrontmatterCounts {
    param([string]$Path)
    $ledger = $null
    $blocked = $null
    try {
        $text = Get-Content -Path $Path -Raw -Encoding utf8
        if ($text -match '(?m)^ledger_entries:\s*(\d+)\s*$') { $ledger = [int]$Matches[1] }
        if ($text -match '(?m)^blocked_on_ruling:\s*(\d+)\s*$') { $blocked = [int]$Matches[1] }
    } catch {
        # Leave both $null; the caller renders that as "?" rather than a false zero.
    }
    [PSCustomObject]@{ LedgerEntries = $ledger; BlockedOnRuling = $blocked }
}

# Composes the Chatwork message body from the counters and per-ticket results this run already
# tracked, plus each prepped dossier's ledger/ruling counts. Reads $script:* state directly, the same
# way Write-History does, rather than threading everything through parameters.
function Build-NotificationText {
    $mins = [int]((Get-JstNow) - $RunStartJst).TotalMinutes
    $lines = @("[info][title]Night Shift $JstDate[/title]")

    if ($script:Detail -eq 'queue empty, nothing to prep') {
        $lines += 'OK - queue empty, nothing to prep'
    } elseif ($script:TicketResults -and $script:TicketResults.Count -gt 0) {
        $overallOk = ($script:Outcome -eq 'OK')
        $failedForMessage = $script:Failed + $script:TimedOut
        $lines += "$($script:Outcome) - $($script:Prepped) prepped, $($script:Skipped) skipped, $failedForMessage failed, $mins min"
        $lines += ''

        $totalBlocked = 0
        foreach ($t in $script:TicketResults) {
            switch ($t.Result) {
                'PREPPED' {
                    $ledger  = $t.LedgerEntries
                    $blocked = $t.BlockedOnRuling
                    if ($null -eq $ledger)  { $ledger = '?' }
                    if ($null -eq $blocked) { $blocked = 0 } else { $totalBlocked += $blocked }
                    $needWord = if ($blocked -eq 1) { 'needs' } else { 'need' }
                    $prefix   = if ($overallOk) { '' } else { 'ok, ' }
                    $lines += "$($t.Key)  $prefix$ledger questions, $blocked $needWord a ruling"
                }
                'TIMEOUT' { $lines += "$($t.Key)  timed out after $TicketTimeoutMinutes min" }
                'SKIPPED' { $lines += "$($t.Key)  skipped, a precondition was already satisfied" }
                default   {
                    $suffix = if ($null -ne $t.ExitCode) { " (exit $($t.ExitCode))" } else { '' }
                    $lines += "$($t.Key)  failed$suffix"
                }
            }
        }

        $lines += ''
        if ($totalBlocked -gt 0) {
            $itemWord = if ($totalBlocked -eq 1) { 'item' } else { 'items' }
            $verbWord = if ($totalBlocked -eq 1) { 'needs' } else { 'need' }
            $lines += "$totalBlocked $itemWord $verbWord a ruling from sir Sat."
        }
        if ($overallOk) {
            $lines += "$VaultNightShift\tickets\"
        } else {
            $lines += (Split-Path $LogFile -Leaf)
        }
    } else {
        # SKIP never reaches here (it doesn't notify at all). This covers CRASH and anything else
        # with no per-ticket data to report.
        $lines += "$($script:Outcome) - $($script:Detail)"
    }

    $lines += '[/info]'
    return ($lines -join "`n")
}

# Sends the end-of-run notification through a second, tiny claude -p pass, scoped by
# night-notify-scheduled.settings.json to Read plus the Composio tools only. Never throws: a failed
# send is logged and returned as a status string, so it can never fail the underlying run.
function Send-NightShiftNotification {
    if ($DryRun) { return 'off (dry run)' }
    if ($NoNotify) {
        Write-Log 'Notification suppressed by -NoNotify.'
        return 'off (-NoNotify)'
    }

    $msgFile    = $null
    $promptFile = $null
    $stdOutFile = $null
    $stdErrFile = $null
    try {
        $text = Build-NotificationText
        $msgFile = Join-Path $env:TEMP 'samurai-night-shift-notify.txt'
        Set-Content -Path $msgFile -Value $text -Encoding utf8 -NoNewline

        # The message text travels as a file path, never as command-line text: command-line
        # arguments mangle text on this machine. The claude PROMPT itself also travels on stdin, not
        # as an argument, for the same reason given in Invoke-NightPrepTicket: Start-Process
        # -ArgumentList flattens an array into one unquoted command-line string under Windows
        # PowerShell 5.1, which broke the ticket pass's --depth flag the same way it would break a
        # long prompt here.
        $notifyPrompt = "Read the file at `"$msgFile`" and post its exact contents as one Chatwork " +
            "message to room $ChatworkNotifyRoomId using the Composio Chatwork send-message tool. " +
            'Do not change, summarize, reformat, or add anything to the text. Report back in one ' +
            'short sentence whether the send succeeded.'
        $promptFile = Join-Path $env:TEMP 'samurai-night-shift-notify-prompt.txt'
        [System.IO.File]::WriteAllText($promptFile, $notifyPrompt, (New-Object System.Text.UTF8Encoding($false)))

        $notifyArgs = @(
            '-p',
            '--settings', $NotifySettingsFile,
            '--permission-mode', 'acceptEdits',
            '--permission-prompts', 'none'
        )

        $stdOutFile = Join-Path $env:TEMP 'samurai-night-shift-notify-stdout.txt'
        $stdErrFile = Join-Path $env:TEMP 'samurai-night-shift-notify-stderr.txt'
        Remove-Item $stdOutFile, $stdErrFile -Force -ErrorAction SilentlyContinue

        Write-Log "Sending the end-of-run notification to Chatwork room $ChatworkNotifyRoomId."
        $proc = Start-Process -FilePath $ClaudeExe -ArgumentList $notifyArgs -WorkingDirectory $RepoDir `
            -RedirectStandardInput $promptFile -RedirectStandardOutput $stdOutFile -RedirectStandardError $stdErrFile -NoNewWindow -PassThru
        # See Invoke-NightPrepTicket: caches the Win32 handle so .ExitCode is populated later instead
        # of reading back empty under Windows PowerShell 5.1.
        $null = $proc.Handle

        $finished = $proc.WaitForExit($NotifyTimeoutMinutes * 60 * 1000)
        if (-not $finished) {
            Write-Log "Notification pass exceeded its $NotifyTimeoutMinutes minute cap. Killing it." 'ERROR'
            try { & taskkill /PID $proc.Id /T /F 2>&1 | Out-Null } catch {}
            try { $proc.WaitForExit(5000) | Out-Null } catch {}
            return 'FAIL (timeout)'
        }

        if ($proc.ExitCode -ne 0) {
            Write-Log "Notification pass exited $($proc.ExitCode)." 'ERROR'
            return "FAIL (exit $($proc.ExitCode))"
        }

        Write-Log 'Notification pass finished.'
        return 'OK'
    } catch {
        Write-Log "Notification failed: $($_.Exception.Message)" 'ERROR'
        return 'FAIL'
    } finally {
        @($msgFile, $promptFile, $stdOutFile, $stdErrFile) | Where-Object { $_ } | ForEach-Object {
            Remove-Item $_ -Force -ErrorAction SilentlyContinue
        }
    }
}

# Reads the queue straight off disk. No git, no remote, no fallback: the local file IS the queue, on
# purpose, so an edit made in Obsidian on this machine is always what the run sees.
function Get-QueueContent {
    if (-not (Test-Path $QueueLocalFile)) {
        throw "Queue file not found at $QueueLocalFile"
    }
    Write-Log "Queue read from $QueueLocalFile."
    return ,(Get-Content $QueueLocalFile)
}

# Blank lines and comments are ignored silently. A line that looks like it should name a ticket but
# doesn't match the key pattern is skipped with a logged warning rather than silently dropped.
function Get-ParsedTickets {
    param([string[]]$Lines)
    $tickets = @()
    foreach ($line in $Lines) {
        $trimmed = ('' + $line).Trim()
        if ($trimmed -eq '' -or $trimmed.StartsWith('#')) { continue }
        if ($trimmed -cnotmatch '^([A-Z][A-Z0-9]*-\d+)\b') {
            Write-Log "Queue line does not start with a ticket key, skipping: $trimmed" 'WARN'
            continue
        }
        $key = $Matches[1]
        $note = $trimmed.Substring($Matches[0].Length).Trim()
        $depth = 'deep'
        if ($note -match '\bshallow\b') { $depth = 'shallow' }
        $tickets += [PSCustomObject]@{ Key = $key; Note = $note; Depth = $depth }
    }
    return ,$tickets
}

# Pins ns-master to the tip of origin/master, creating the worktree on first use and refreshing it
# otherwise. Detached HEAD only, never a branch. Throws (never falls back) on any failure of fetch,
# add, or checkout, and on anything other than a confirmed detached HEAD afterward, so the caller's
# outer try/catch turns it into a CRASH with a clear detail string rather than silently reading the
# wrong tree. Runs only `fetch` and `worktree add` against $RepoDir (the user's main checkout);
# everything else targets $NsMasterDir.
# git writes its normal progress and summary lines to STDERR even when it succeeds
# ("From https://github.com/...", "Switched to ..."). This script runs with
# $ErrorActionPreference = 'Stop', and in Windows PowerShell 5.1 the `2>` redirect on a native
# command turns each stderr line into a PowerShell error record, which under 'Stop' throws
# BEFORE $LASTEXITCODE is ever read. A completely clean fetch therefore crashed the whole run
# on 2026-09-08. Merge stderr into the output stream instead and judge by the exit code, which
# is the only signal git gives that actually means failure.
function Invoke-GitChecked {
    param(
        [Parameter(Mandatory)][string[]]$GitArgs,
        [Parameter(Mandatory)][string]$What
    )
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = (& git @GitArgs 2>&1 | Out-String)
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prev
    }
    if ($code -ne 0) { throw "$What failed (exit $code): $($output.Trim())" }
    return $output.Trim()
}

function Enter-NsMasterWorktree {
    Write-Log "Fetching origin/master into the main checkout ($RepoDir)."
    Invoke-GitChecked -What 'git fetch origin master' `
        -GitArgs @('-C', $RepoDir, 'fetch', 'origin', 'master') | Out-Null

    if (-not (Test-Path $NsMasterDir)) {
        Write-Log "ns-master worktree not found. Creating it at $NsMasterDir."
        Invoke-GitChecked -What 'git worktree add --detach' `
            -GitArgs @('-c', 'core.longpaths=true', '-C', $RepoDir,
                       'worktree', 'add', '--detach', $NsMasterDir, 'origin/master') | Out-Null
    } else {
        Write-Log "Refreshing the existing ns-master worktree at $NsMasterDir."
        Invoke-GitChecked -What 'git checkout --detach origin/master (ns-master)' `
            -GitArgs @('-c', 'core.longpaths=true', '-C', $NsMasterDir,
                       'checkout', '--detach', 'origin/master') | Out-Null
    }

    $branch = Invoke-GitChecked -What 'git rev-parse --abbrev-ref HEAD (ns-master)' `
        -GitArgs @('-C', $NsMasterDir, 'rev-parse', '--abbrev-ref', 'HEAD')
    if ($branch -ne 'HEAD') {
        throw "ns-master is not a detached HEAD after setup (rev-parse --abbrev-ref reported '$branch'). Refusing to use it."
    }
    $sha = Invoke-GitChecked -What 'git log -1 --format=%h (ns-master)' `
        -GitArgs @('-C', $NsMasterDir, 'log', '-1', '--format=%h')
    if (-not $sha) {
        throw "Could not read the ns-master worktree's current SHA after setup."
    }

    Write-Log "ns-master pinned to origin/master at $sha (detached HEAD)."
    return $sha
}

# Runs one ticket as its own claude.exe process, enforces the per-ticket wall clock, and decides the
# outcome from the dossier on disk rather than from the exit code.
function Invoke-NightPrepTicket {
    param([Parameter(Mandatory = $true)]$Ticket)

    $prompt = "/night-prep $($Ticket.Key) --depth $($Ticket.Depth)"
    # The prompt travels on stdin, never as an argument. Start-Process -ArgumentList flattens an
    # array into ONE command-line string under Windows PowerShell 5.1 without quoting elements that
    # contain spaces (the call operator & with a splat quotes correctly, Start-Process does not), so
    # "/night-prep V3-1477 --depth deep" landed on the command line unquoted and claude's own parser
    # read "--depth" as an option of its own ("error: unknown option '--depth'"). `claude -p` reads
    # the prompt from stdin when no positional prompt is given, which removes the quoting problem
    # completely instead of escaping around it, and matches the house rule that ticket text and
    # notes travel as files, never as command-line arguments.
    $claudeArgs = @(
        '-p',
        '--settings', $SettingsFile,
        '--permission-mode', 'acceptEdits',
        '--permission-prompts', 'none'
    )

    $promptFile = Join-Path $env:TEMP "samurai-night-shift-$($Ticket.Key)-prompt.txt"
    $stdOutFile = Join-Path $env:TEMP "samurai-night-shift-$($Ticket.Key)-stdout.txt"
    $stdErrFile = Join-Path $env:TEMP "samurai-night-shift-$($Ticket.Key)-stderr.txt"
    Remove-Item $promptFile, $stdOutFile, $stdErrFile -Force -ErrorAction SilentlyContinue

    try {
        # UTF-8 without a BOM: Set-Content -Encoding utf8 writes one under Windows PowerShell 5.1,
        # which a stdin reader may not expect.
        [System.IO.File]::WriteAllText($promptFile, $prompt, (New-Object System.Text.UTF8Encoding($false)))

        Write-Log "=== $($Ticket.Key) [$($Ticket.Depth)] starting. Note: $($Ticket.Note) ==="
        $ticketStart = Get-Date
        $timedOut = $false
        $exitCode = $null

        # Runs in ns-master, never $RepoDir: this is what pins the dossier's citations to a tree that
        # still exists tomorrow instead of whatever feature branch the user is mid-work on.
        $proc = Start-Process -FilePath $ClaudeExe -ArgumentList $claudeArgs -WorkingDirectory $NsMasterDir `
            -RedirectStandardInput $promptFile -RedirectStandardOutput $stdOutFile -RedirectStandardError $stdErrFile -NoNewWindow -PassThru
        # Caches the Win32 handle immediately. Under Windows PowerShell 5.1, .ExitCode reads back
        # empty (not zero, empty) later unless the handle is dereferenced once before the process
        # exits; that showed up as "FAILED (0 min, exit , no usable dossier)" in the log.
        $null = $proc.Handle

        $finished = $proc.WaitForExit($TicketTimeoutMinutes * 60 * 1000)
        if (-not $finished) {
            Write-Log "$($Ticket.Key) exceeded the $TicketTimeoutMinutes minute cap. Killing it." 'ERROR'
            # Process.Kill(true) (kill the whole tree) is not available under Windows PowerShell 5.1's
            # older .NET, so taskkill /T is used instead. It works the same way under both engines.
            try { & taskkill /PID $proc.Id /T /F 2>&1 | Out-Null } catch {}
            $timedOut = $true
            try { $proc.WaitForExit(5000) | Out-Null } catch {}
        } else {
            $exitCode = $proc.ExitCode
        }

        $stdOutText = ''
        if (Test-Path $stdOutFile) { $stdOutText = Get-Content $stdOutFile -Raw -ErrorAction SilentlyContinue }
        $stdErrText = ''
        if (Test-Path $stdErrFile) { $stdErrText = Get-Content $stdErrFile -Raw -ErrorAction SilentlyContinue }
        if ($stdOutText) { Add-Content -Path $LogFile -Value $stdOutText -Encoding utf8 }
        if ($stdErrText) { Add-Content -Path $LogFile -Value $stdErrText -Encoding utf8 }

        $elapsedMin = [int]((Get-Date) - $ticketStart).TotalMinutes

        $dossierPath = Join-Path $VaultNightShift "tickets\$($Ticket.Key)\dossier-$JstDate.md"
        $dossierOk = $false
        if ((Test-Path $dossierPath) -and ((Get-Item $dossierPath).LastWriteTime -ge $ticketStart)) {
            if (Test-DossierComplete -Path $dossierPath) {
                $dossierOk = $true
            } else {
                Write-Log "$($Ticket.Key): dossier exists but is missing the '<!-- dossier-end -->' sentinel. Treating as not produced." 'ERROR'
            }
        }

        $result = $null
        $ledgerEntries = $null
        $blockedOnRuling = $null
        if ($dossierOk) {
            $result = 'PREPPED'
            $fm = Get-DossierFrontmatterCounts -Path $dossierPath
            $ledgerEntries = $fm.LedgerEntries
            $blockedOnRuling = $fm.BlockedOnRuling
            Write-Log "$($Ticket.Key): PREPPED ($elapsedMin min). $dossierPath"
        } elseif ($timedOut) {
            $result = 'TIMEOUT'
            Write-Log "$($Ticket.Key): TIMEOUT ($elapsedMin min, no usable dossier)." 'ERROR'
        } elseif ($stdOutText -match 'already has a brainstorm' -or $stdOutText -match 'has not been consumed') {
            # /night-prep's own preconditions stopped it cleanly (ticket already past this phase, or an
            # unconsumed dossier from a prior day). That is a skip, not a failure.
            $result = 'SKIPPED'
            Write-Log "$($Ticket.Key): SKIPPED ($elapsedMin min). A precondition in /night-prep stopped it; see the log above for the exact line."
        } else {
            $result = 'FAILED'
            Write-Log "$($Ticket.Key): FAILED ($elapsedMin min, exit $exitCode, no usable dossier)." 'ERROR'
        }

        [PSCustomObject]@{
            Key             = $Ticket.Key
            Result          = $result
            ElapsedMin      = $elapsedMin
            ExitCode        = $exitCode
            DossierPath     = $dossierPath
            LedgerEntries   = $ledgerEntries
            BlockedOnRuling = $blockedOnRuling
        }
    } finally {
        Remove-Item $promptFile, $stdOutFile, $stdErrFile -Force -ErrorAction SilentlyContinue
    }
}

# Before the lock check on purpose: a dry run starts nothing, so it must not care whether a real run
# is in flight, and must never leave a line in the history file.
if ($DryRun) {
    Write-Output "main checkout : $RepoDir (fetch/worktree-add source only, never read from)"
    Write-Output "vault         : $VaultRoot"
    Write-Output "log           : $LogFile (not created by a dry run)"
    Write-Output "history       : $HistoryFile (not written by a dry run)"
    Write-Output "lock held     : $(Test-Path $LockFile)"
    Write-Output "power hold    : none taken (skipped by -DryRun)"
    Write-Output "notify        : would notify Chatwork room $ChatworkNotifyRoomId (skipped by -DryRun)"

    # Read-only preview: a dry run creates or refreshes nothing, so this never fetches, never runs
    # `worktree add`, and never checks out anything. It only reports what a real run would see.
    Write-Output "ns-master     : $NsMasterDir"
    if (Test-Path $NsMasterDir) {
        try {
            $previewSha    = (& git -C $NsMasterDir rev-parse --short HEAD 2>&1 | Out-String).Trim()
            $previewBranch = (& git -C $NsMasterDir rev-parse --abbrev-ref HEAD 2>&1 | Out-String).Trim()
            Write-Output "              : exists, currently at $previewSha ($previewBranch). A real run refreshes it to the tip of origin/master and pins to that SHA."
        } catch {
            Write-Output "              : exists, but its current state could not be read ($($_.Exception.Message))."
        }
    } else {
        Write-Output '              : does not exist yet. A real run creates it, detached at origin/master.'
    }
    Write-Output ''

    $lines   = Get-QueueContent
    $tickets = Get-ParsedTickets -Lines $lines
    Write-Output "queue has $($tickets.Count) valid ticket(s)."
    # Wrapped in @(...): Select-Object -First 1 returns a bare object, not a one-element array, and
    # strict mode then throws the moment something does $toRun.Count or foreach's over it.
    $toRun = @($tickets | Select-Object -First $MaxTickets)

    if (-not $toRun -or $toRun.Count -eq 0) {
        Write-Output 'nothing would run this session (queue empty or every line was skipped).'
    } else {
        Write-Output "would run $($toRun.Count) of them this session (cap $MaxTickets):"
        foreach ($t in $toRun) {
            # Shown for reference only. The prompt itself is never an argv element: it travels on
            # stdin, from a temp file, so it can't be flattened onto the command line unquoted (see
            # Invoke-NightPrepTicket).
            $prompt     = "/night-prep $($t.Key) --depth $($t.Depth)"
            $claudeArgs = @('-p', '--settings', $SettingsFile, '--permission-mode', 'acceptEdits', '--permission-prompts', 'none')
            $shown      = $claudeArgs | ForEach-Object { if ($_ -match '\s') { "`"$_`"" } else { $_ } }
            $dossierDue = Join-Path $VaultNightShift "tickets\$($t.Key)\dossier-$JstDate.md"
            Write-Output ''
            Write-Output "  ticket      : $($t.Key)  (note: $($t.Note))"
            Write-Output "  dossier due : $dossierDue"
            Write-Output "  stdin       : $prompt"
            Write-Output "  command     : `"$ClaudeExe`" $($shown -join ' ')"
        }
    }
    $script:HistoryDone = $true   # a dry run is not a run
    exit 0
}

# A second run while the first is still going would collide over the same lock and could double-run
# a ticket. Threshold matches the scheduled task's own 3 hour ExecutionTimeLimit backstop.
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

try {
    Enter-PowerHold
    Write-Log "Starting the night shift for $JstDate (machine local $(Get-Date -Format 'HH:mm') SGT). Cap: $MaxTickets ticket(s)."

    $lines   = Get-QueueContent
    $tickets = Get-ParsedTickets -Lines $lines

    if (-not $tickets -or $tickets.Count -eq 0) {
        Write-Log 'Queue is empty or every line was skipped. Nothing to prep tonight.'
        $script:Outcome = 'OK'
        $script:Detail  = 'queue empty, nothing to prep'
        exit 0
    }

    # Wrapped in @(...): Select-Object -First 1 returns a bare object, not a one-element array, and
    # strict mode then throws the moment something does $toRun.Count or foreach's over it.
    $toRun = @($tickets | Select-Object -First $MaxTickets)
    if ($tickets.Count -gt $MaxTickets) {
        Write-Log "Queue has $($tickets.Count) valid ticket(s); running the first $MaxTickets (cap) and leaving the rest for next time."
    } else {
        Write-Log "Queue has $($tickets.Count) valid ticket(s); running all of them."
    }

    # Not wrapped in its own try/catch: any failure here must abort the whole run as a CRASH rather
    # than silently falling back to the main checkout, which would produce a dossier citing the wrong
    # tree while looking perfectly normal.
    $null = Enter-NsMasterWorktree

    foreach ($ticket in $toRun) {
        $script:Attempted++
        try {
            $r = Invoke-NightPrepTicket -Ticket $ticket
            $script:TicketResults += $r
            switch ($r.Result) {
                'PREPPED' { $script:Prepped++ }
                'SKIPPED' { $script:Skipped++ }
                'TIMEOUT' { $script:TimedOut++ }
                default   { $script:Failed++ }
            }
        } catch {
            # A crash on one ticket must not lose the rest of the night.
            Write-Log "$($ticket.Key): wrapper threw while running it: $($_.Exception.Message)" 'ERROR'
            $script:Failed++
        }
    }

    if ($script:Failed -eq 0 -and $script:TimedOut -eq 0) {
        $script:Outcome = 'OK'
    } elseif ($script:Prepped -eq 0 -and $script:Skipped -eq 0) {
        $script:Outcome = 'FAIL'
    } else {
        $script:Outcome = 'PARTIAL'
    }
    $script:Detail = "attempted=$($script:Attempted) prepped=$($script:Prepped) skipped=$($script:Skipped) failed=$($script:Failed) timeout=$($script:TimedOut)"
    Write-Log "Night shift finished. $($script:Detail)"

    if ($script:Outcome -eq 'OK') { exit 0 }
    elseif ($script:Outcome -eq 'PARTIAL') { exit 2 }
    else { exit 1 }
}
catch {
    Write-Log "Wrapper failed: $($_.Exception.Message)" 'ERROR'
    $script:Outcome = 'CRASH'
    $script:Detail  = $_.Exception.Message -replace '\s+', ' '
    exit 4
}
finally {
    # Unconditional and first: releasing the power hold must happen on every exit path, including a
    # crash, so a broken run can never leave the machine permanently unable to sleep.
    Exit-PowerHold
    Write-History
    # Sent after the history line so the line itself is never held up by a slow or stuck Chatwork
    # send; the trailing notify=pending it was written with gets patched with the real result once
    # this returns. SKIP exits before this finally block is ever reached, so a lock-skip never
    # notifies; the run already holding the lock will send the real notification when it finishes.
    $notifyStatus = Send-NightShiftNotification
    Set-HistoryNotifyStatus -Status $notifyStatus
    Remove-Item $LockFile -Force -ErrorAction SilentlyContinue
    Get-ChildItem $LogDir -Filter 'night-shift-*.log' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -Skip $LogRetention |
        Remove-Item -Force -ErrorAction SilentlyContinue
}
