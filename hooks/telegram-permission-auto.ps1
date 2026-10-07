# Hook PermissionRequest: si el turno en curso lo pidió Telegram (remoteTurn en
# sessions.json) y el puente está configurado con permissionMode
# bypassPermissions, aprueba la herramienta sin preguntar: desde Telegram nadie
# puede contestar el diálogo de la PC. En turnos escritos en VS Code no hace
# nada y el diálogo sale como siempre.

$ErrorActionPreference = "SilentlyContinue"
. (Join-Path $PSScriptRoot "telegram-bridge-lib.ps1")

try {
    $cfg = Get-TgConfig
    if ($cfg.permissionMode -ne "bypassPermissions") { exit 0 }

    $payload = Read-HookPayload
    if (-not $payload -or -not $payload.session_id) { exit 0 }

    $entry = Get-TgSessionById $payload.session_id
    if (-not (Test-TgRemoteTurn $entry)) { exit 0 }

    $out = @{
        hookSpecificOutput = @{
            hookEventName = "PermissionRequest"
            decision = @{ behavior = "allow" }
        }
    }
    [Console]::OutputEncoding = [Text.Encoding]::UTF8
    [Console]::Out.Write(($out | ConvertTo-Json -Depth 5 -Compress))
} catch {}

exit 0
