# samurai-greeting.ps1 — colorful tech boot intro for the Samurai dev launcher.
# Time-aware. ASCII-ONLY so it renders the same under Windows PowerShell 5.1 and pwsh 7
# (non-ASCII in a no-BOM script mojibakes on 5.1). No palette forcing — keeps your terminal
# theme/transparency; just colorful text.

try { Clear-Host } catch { }

function Write-Type([string]$Text, [string]$Color = 'Gray', [int]$Delay = 12) {
    foreach ($ch in $Text.ToCharArray()) {
        Write-Host -NoNewline $ch -ForegroundColor $Color
        Start-Sleep -Milliseconds $Delay
    }
    Write-Host ''
}

# --- brief digital rain (cool multi-color) -------------------------------------------------
$rain = 'Cyan', 'DarkCyan', 'Blue', 'Magenta', 'DarkMagenta'
for ($r = 0; $r -lt 8; $r++) {
    $line = -join (1..64 | ForEach-Object { '01'[(Get-Random -Maximum 2)] })
    Write-Host "  $line" -ForegroundColor $rain[(Get-Random -Maximum $rain.Count)]
    Start-Sleep -Milliseconds 30
}

# --- brand ---------------------------------------------------------------------------------
Write-Host ''
Write-Host '  +============================================+' -ForegroundColor DarkCyan
Write-Host '    SAMURAI CART ' -NoNewline -ForegroundColor Cyan
Write-Host '// '             -NoNewline -ForegroundColor Magenta
Write-Host 'V3'              -NoNewline -ForegroundColor Yellow
Write-Host '      ::   DEV ENVIRONMENT'  -ForegroundColor Cyan
Write-Host '  +============================================+' -ForegroundColor DarkCyan
Write-Host ''

# --- startup lines -------------------------------------------------------------------------
# Real pre-flight: show each tool's version (green) or 'missing' (red) instead of a fake 'ok'.
function Write-Boot([string]$Label, [string]$Value, [string]$TagColor) {
    $dots = '.' * [Math]::Max(3, 12 - $Label.Length)
    Write-Host '  [' -NoNewline -ForegroundColor DarkGray
    Write-Host '*' -NoNewline -ForegroundColor $TagColor
    Write-Host '] ' -NoNewline -ForegroundColor DarkGray
    Write-Host "$Label " -NoNewline -ForegroundColor Gray
    Write-Host "$dots " -NoNewline -ForegroundColor DarkGray
    if ($Value) { Write-Host $Value -ForegroundColor Green }
    else        { Write-Host 'missing' -ForegroundColor Red }
}
Write-Boot 'pwsh' $PSVersionTable.PSVersion.ToString() 'Cyan'
Write-Boot 'node' (node -v 2>$null) 'Magenta'
Write-Boot 'git'  (((git --version 2>$null) -replace 'git version ', '')) 'Blue'
Write-Host ''

# --- time-aware greeting -------------------------------------------------------------------
$h = (Get-Date).Hour
$sub = if     ($h -lt 5)  { 'Working late, Patrick' }
       elseif ($h -lt 12) { 'Good morning, Patrick' }
       elseif ($h -lt 18) { 'Good afternoon, Patrick' }
       elseif ($h -lt 22) { 'Good evening, Patrick' }
       else               { 'Good night, Patrick' }
Write-Type "  > $sub" 'Yellow' 14
Write-Host "  > $((Get-Date).ToString('ddd dd MMM yyyy  -  HH:mm'))" -ForegroundColor DarkCyan
Write-Host ''
