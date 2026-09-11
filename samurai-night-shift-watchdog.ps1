[CmdletBinding()]
param(
    [string]$TaskName = 'Samurai Night Shift',
    [Parameter(Mandatory)][datetime]$ExpectedRunTime,
    [string]$LogPath = 'C:\Users\john\scripts\logs\night-shift-watchdog.log'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'samurai-night-shift-watchdog.psm1') -Force

function Write-WatchdogLog {
    param([Parameter(Mandatory)][string]$Message)

    $parent = Split-Path -Parent $LogPath
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    Add-Content -LiteralPath $LogPath -Encoding utf8 -Value "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')] $Message"
}

try {
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop
    $info = Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction Stop
    $decision = Get-SamuraiNightShiftWatchdogDecision `
        -State ([string]$task.State) `
        -LastRunTime $info.LastRunTime `
        -LastTaskResult ([uint32]$info.LastTaskResult) `
        -ExpectedRunTime $ExpectedRunTime

    switch ($decision) {
        'NoOpRunning' {
            Write-WatchdogLog "NOOP: '$TaskName' is still running; its own failure-restart policy remains active."
        }
        'NoOpSucceeded' {
            Write-WatchdogLog "NOOP: '$TaskName' completed successfully after the expected $($ExpectedRunTime.ToString('yyyy-MM-dd HH:mm:ss')) run time."
        }
        'Retry' {
            Write-WatchdogLog "RETRY: '$TaskName' did not complete successfully (state=$($task.State), lastRun=$($info.LastRunTime.ToString('yyyy-MM-dd HH:mm:ss')), result=0x$('{0:X8}' -f ([uint32]$info.LastTaskResult))). Starting it once."
            Start-ScheduledTask -TaskName $TaskName -ErrorAction Stop
            Start-Sleep -Seconds 2
            $after = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop
            Write-WatchdogLog "RETRY REQUEST ACCEPTED: '$TaskName' state is now $($after.State)."
        }
        default {
            throw "Unknown watchdog decision '$decision'."
        }
    }
}
catch {
    try { Write-WatchdogLog "ERROR: $($_.Exception.Message)" } catch {}
    throw
}
