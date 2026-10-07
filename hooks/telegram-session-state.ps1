# Hook UserPromptSubmit (-State busy) y SessionEnd (-State idle): mantiene al
# día en sessions.json si la sesión está trabajando, para que el puente de
# Telegram encole en lugar de pisar un turno en curso.
# No escribe nada en stdout: en UserPromptSubmit eso se añadiría al contexto.
param([ValidateSet("busy", "idle")][string]$State = "busy")

$ErrorActionPreference = "SilentlyContinue"
. (Join-Path $PSScriptRoot "telegram-bridge-lib.ps1")

try {
    $payload = Read-HookPayload
    if ($payload -and $payload.session_id) {
        # Un prompt escrito en VS Code (o el cierre) nunca es un turno de
        # Telegram: se quita la marca para que no se aprueben permisos solos.
        Update-TgSession -SessionId $payload.session_id -Cwd $payload.cwd -Busy ($State -eq "busy") -RemoteTurn $false | Out-Null

        # Al cerrar la sesión se retira el hook que escucha su buzón.
        if ($State -eq "idle") {
            Remove-Item -LiteralPath (Join-Path (Get-TgInboxDir $payload.session_id) "waiter.json") -Force
        }
    }
} catch {}

exit 0
