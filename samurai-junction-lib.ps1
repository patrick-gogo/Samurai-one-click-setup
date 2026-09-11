# samurai-junction-lib.ps1 — NTFS directory-junction primitives shared by the worktree tooling.
# A junction lets a worktree's frontend/node_modules point at the main checkout's single store
# instead of holding its own ~128k-file copy. Pure helpers, no side effects on dot-source.

function Test-IsJunction([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if (-not $item) { return $false }
    return $item.LinkType -eq 'Junction'
}

function Get-JunctionTarget([string]$Path) {
    if (-not (Test-IsJunction $Path)) { return $null }
    # .Target is a collection on some PowerShell versions; normalize to one comparable string.
    $t = @((Get-Item -LiteralPath $Path -Force).Target)[0]
    if (-not $t) { return $null }
    return $t.TrimEnd('\')
}

function New-JunctionLink([string]$Path, [string]$Target) {
    if (-not (Test-Path -LiteralPath $Target)) {
        throw "Junction target does not exist: $Target"
    }
    New-Item -ItemType Junction -Path $Path -Target $Target -ErrorAction Stop | Out-Null
}

function Remove-JunctionLink([string]$Path) {
    # Hard guard: this function must never be reachable with a real directory, because the
    # only thing it is ever pointed at is the machine's single good node_modules store.
    if (-not (Test-IsJunction $Path)) {
        throw "Not a junction (refusing to delete): $Path"
    }
    # Non-recursive delete removes ONLY the link. Remove-Item -Recurse deleted *through*
    # junctions on Windows PowerShell 5.1; this call structurally cannot touch the target.
    [System.IO.Directory]::Delete($Path, $false)
}
