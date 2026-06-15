# samurai-dash.ps1 — Samurai command-center dashboard (keypress-refresh TUI).
# Watch-only: 'r' re-renders, 'q' quits. ASCII-only output. Dot-source with -NoRun for tests.
param([switch]$NoRun)

$script:Admin = 'C:\Users\John Patrick Mandal\Desktop\samurai_cart_v3'
$script:Store = 'C:\Users\John Patrick Mandal\Desktop\samurai_cart_v3_frontend'

function Invoke-Dashboard {
    while ($true) {
        Clear-Host
        Write-Host ''
        Write-Host '  +=================== SAMURAI COMMAND CENTER ===================+' -ForegroundColor DarkCyan
        Write-Host ('    refreshed ' + (Get-Date).ToString('ddd HH:mm:ss')) -ForegroundColor DarkGray
        Write-Host ''
        Write-Host '  [r] refresh   [q] quit' -ForegroundColor DarkGray
        $k = [Console]::ReadKey($true)
        if ($k.Key -eq [ConsoleKey]::Q) { Clear-Host; break }
        # any other key (incl. r) loops -> re-render
    }
}

if (-not $NoRun) { Invoke-Dashboard }
