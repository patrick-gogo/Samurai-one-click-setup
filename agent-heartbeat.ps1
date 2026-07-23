# Invoked by Claude Code's PostToolUse and Stop hooks in samurai_cart_v3 and
# samurai_cart_v3_frontend. Reads the hook's JSON payload from stdin and writes/updates a
# per-session heartbeat file that the samurai-patrick-command-center dashboard polls.

$ErrorActionPreference = 'Stop'

try {
    $raw = [Console]::In.ReadToEnd()
    $payload = $raw | ConvertFrom-Json

    $statusDir = Join-Path $env:USERPROFILE '.claude\agent-status'
    if (-not (Test-Path $statusDir)) {
        New-Item -ItemType Directory -Path $statusDir -Force | Out-Null
    }

    $statusFile = Join-Path $statusDir "$($payload.session_id).json"
    $updatedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')

    if ($payload.hook_event_name -eq 'PostToolUse') {
        $toolName = $payload.tool_name
        $lastAction = switch -Regex ($toolName) {
            '^(Edit|Write)$' { "Editing $($payload.tool_input.file_path)" }
            '^Read$'         { "Reading $($payload.tool_input.file_path)" }
            '^Bash$'         { "Running: $($payload.tool_input.command)" }
            default          { $toolName }
        }

        $heartbeat = @{
            sessionId  = $payload.session_id
            cwd        = $payload.cwd
            status     = 'active'
            lastAction = $lastAction
            updatedAt  = $updatedAt
        }
        $heartbeat | ConvertTo-Json | Set-Content -Path $statusFile -Encoding utf8
    }
    elseif ($payload.hook_event_name -eq 'Stop') {
        $lastAction = 'no actions yet'
        if (Test-Path $statusFile) {
            $existing = Get-Content -Path $statusFile -Raw | ConvertFrom-Json
            if ($existing.lastAction) { $lastAction = $existing.lastAction }
        }

        $heartbeat = @{
            sessionId  = $payload.session_id
            cwd        = $payload.cwd
            status     = 'idle'
            lastAction = $lastAction
            updatedAt  = $updatedAt
        }
        $heartbeat | ConvertTo-Json | Set-Content -Path $statusFile -Encoding utf8
    }
}
catch {
    # Best-effort telemetry only — never let a heartbeat failure block the agent's turn
    # or surface an error.
    exit 0
}
