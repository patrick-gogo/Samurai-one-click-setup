function Get-SamuraiNightShiftWatchdogDecision {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$State,
        [Parameter(Mandatory)][datetime]$LastRunTime,
        [Parameter(Mandatory)][uint32]$LastTaskResult,
        [Parameter(Mandatory)][datetime]$ExpectedRunTime
    )

    if ($State -eq 'Running') {
        return 'NoOpRunning'
    }

    if ($LastRunTime -ge $ExpectedRunTime -and $LastTaskResult -eq 0) {
        return 'NoOpSucceeded'
    }

    return 'Retry'
}

Export-ModuleMember -Function Get-SamuraiNightShiftWatchdogDecision
