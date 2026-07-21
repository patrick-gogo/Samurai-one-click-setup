# samurai-testdb-lib.ps1 — shared helpers for deriving a per-ticket isolated Postgres test
# database name, and for talking to the samurai_cart_db container. Dot-sourced by
# samurai-test.ps1 and samurai-cleanup-ticket.ps1 — no side effects on load.

function ConvertTo-TestDbSuffix([string]$Key) {
    if ($Key -notmatch '^[A-Za-z][A-Za-z0-9]*-\d+$') {
        throw "'$Key' is not a valid ticket key (expected e.g. V3-1193)"
    }
    return ($Key.ToLower() -replace '-', '_')
}

function Get-TicketKeyFromFolderName([string]$FolderName) {
    if ($FolderName -match '^wt-([A-Za-z][A-Za-z0-9]*-\d+)-') { return $Matches[1] }
    return $null
}

function Get-TicketKeyFromBranch([string]$Branch) {
    if ($Branch -match '^(?:feature|fix|bugfix|chore)/([A-Za-z][A-Za-z0-9]*-\d+)-') { return $Matches[1] }
    return $null
}

function Test-TestDbExists([string]$DbName) {
    $result = docker exec samurai_cart_db psql -U samurai -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname='$DbName'" 2>$null
    return (($result | Out-String).Trim() -eq '1')
}

function New-TestDb([string]$DbName) {
    docker exec samurai_cart_db psql -U samurai -d postgres -c "CREATE DATABASE $DbName OWNER samurai" 2>$null | Out-Null
}

function Remove-TestDb([string]$DbName) {
    docker exec samurai_cart_db psql -U samurai -d postgres -c "DROP DATABASE IF EXISTS $DbName WITH (FORCE)" 2>$null | Out-Null
}
