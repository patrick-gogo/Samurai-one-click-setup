$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'samurai-night-shift-watchdog.psm1') -Force

$scheduled = [datetime]'2026-09-10T19:00:00'

$cases = @(
    @{ Name = 'does not retry while the task is running'; State = 'Running'; LastRun = $scheduled; Result = 267009; Expected = 'NoOpRunning' },
    @{ Name = 'does not retry a successful scheduled run'; State = 'Ready'; LastRun = $scheduled.AddMinutes(1); Result = 0; Expected = 'NoOpSucceeded' },
    @{ Name = 'retries when the scheduled run never started'; State = 'Ready'; LastRun = $scheduled.AddHours(-2); Result = 0; Expected = 'Retry' },
    @{ Name = 'retries when the scheduled run failed'; State = 'Ready'; LastRun = $scheduled.AddMinutes(1); Result = 1; Expected = 'Retry' },
    @{ Name = 'accepts unsigned Windows failure codes'; State = 'Ready'; LastRun = $scheduled.AddHours(-2); Result = [Convert]::ToUInt32('800710E0', 16); Expected = 'Retry' }
)

$failures = 0
foreach ($case in $cases) {
    $actual = Get-SamuraiNightShiftWatchdogDecision `
        -State $case.State `
        -LastRunTime $case.LastRun `
        -LastTaskResult $case.Result `
        -ExpectedRunTime $scheduled

    if ($actual -ne $case.Expected) {
        Write-Error "$($case.Name): expected '$($case.Expected)', got '$actual'" -ErrorAction Continue
        $failures++
    } else {
        Write-Host "PASS: $($case.Name)"
    }
}

if ($failures -gt 0) {
    throw "$failures watchdog test(s) failed."
}

Write-Host "PASS: all $($cases.Count) watchdog tests passed."
