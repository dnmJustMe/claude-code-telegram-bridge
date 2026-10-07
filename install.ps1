<#
.SYNOPSIS
    Instala claude-code-telegram-bridge para el usuario actual de Windows.

.DESCRIPTION
    1. Revisa requisitos (PowerShell 5.1+, Claude Code, curl.exe).
    2. Valida el token del bot y que no tenga webhook.
    3. Detecta tu ID de Telegram (le mandas /start al bot).
    4. Pregunta el modo de permisos para lo que mandes desde Telegram.
    5. Copia hooks a ~/.claude/hooks y el puente a ~/.claude/telegram-bridge,
       y crea ~/.claude/telegram-bridge/config.json.
    6. Registra los hooks en ~/.claude/settings.json (con respaldo previo).
       Es idempotente: reinstalar reemplaza las entradas, no las duplica.
    7. Configura el perfil del bot (descripción, comandos, foto) y registra la
       tarea programada que arranca el puente al iniciar sesión.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\install.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\install.ps1 -BotToken "123:ABC" -UserId 123456789 -PermissionMode acceptEdits
#>
param(
    [string]$BotToken,
    [long]$UserId = 0,
    [ValidateSet("", "bypassPermissions", "acceptEdits", "default")]
    [string]$PermissionMode = "",
    [switch]$SkipBotProfile,
    [switch]$SkipTask
)

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$RepoDir = $PSScriptRoot
$ClaudeDir = Join-Path $env:USERPROFILE ".claude"
$HooksDir = Join-Path $ClaudeDir "hooks"
$BridgeDir = Join-Path $ClaudeDir "telegram-bridge"
$SettingsPath = Join-Path $ClaudeDir "settings.json"

function Write-Step {
    param([int]$N, [string]$Text)
    Write-Host ""
    Write-Host "[$N/7] $Text" -ForegroundColor Cyan
}

function Invoke-Bot {
    param([string]$Token, [string]$Method, [hashtable]$Params = @{})
    $wc = New-Object Net.WebClient
    $wc.Encoding = [Text.Encoding]::UTF8
    $wc.Headers["Content-Type"] = "application/json; charset=utf-8"
    try {
        $json = $Params | ConvertTo-Json -Depth 10 -Compress
        return ($wc.UploadString("https://api.telegram.org/bot$Token/$Method", $json) | ConvertFrom-Json)
    } catch {
        return [pscustomobject]@{ ok = $false; description = $_.Exception.Message }
    }
}

function Set-Prop {
    param($Object, [string]$Name, $Value)
    if ($Object.PSObject.Properties[$Name]) { $Object.$Name = $Value }
    else { $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value }
}

# ---------------------------------------------------------------------------
Write-Step 1 "Revisando requisitos"
if ($PSVersionTable.PSVersion.Major -lt 5) { throw "Se necesita Windows PowerShell 5.1 o superior." }
if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
    Write-Warning "No encontré 'claude' en el PATH. Los avisos funcionarán, pero para ejecutar mensajes en sesiones cerradas hace falta Claude Code CLI."
}
if (-not (Get-Command curl.exe -ErrorAction SilentlyContinue)) {
    Write-Warning "No encontré curl.exe: no se podrá subir la foto del bot (lo demás funciona)."
}
if (-not (Test-Path -LiteralPath $ClaudeDir)) { New-Item -ItemType Directory -Path $ClaudeDir | Out-Null }
Write-Host "OK" -ForegroundColor Green

# ---------------------------------------------------------------------------
Write-Step 2 "Bot de Telegram"
if (-not $BotToken) {
    Write-Host "Crea un bot con @BotFather (/newbot) y pega aquí su token."
    $BotToken = (Read-Host "Token del bot").Trim()
}
$me = Invoke-Bot $BotToken "getMe"
if (-not $me.ok) { throw "El token no es válido: $($me.description)" }
$botName = $me.result.username
Write-Host "Bot: @$botName" -ForegroundColor Green

$webhook = Invoke-Bot $BotToken "getWebhookInfo"
if ($webhook.ok -and $webhook.result.url) {
    throw "El bot tiene un webhook configurado ($($webhook.result.url)). El puente lee los mensajes con getUpdates y necesita un bot sin webhook: usa un bot dedicado."
}

# ---------------------------------------------------------------------------
Write-Step 3 "Tu ID de Telegram"
if ($UserId -le 0) {
    Write-Host "Abre https://t.me/$botName, envíale /start y luego presiona Enter aquí."
    [void](Read-Host "Enter cuando lo hayas enviado")
    $updates = Invoke-Bot $BotToken "getUpdates" @{ timeout = 0 }
    $last = @($updates.result | Where-Object { $_.message -and $_.message.chat.type -eq "private" }) | Select-Object -Last 1
    if (-not $last) {
        throw "No vi ningún mensaje privado al bot. Envíale /start y vuelve a correr el instalador (o usa -UserId; tu ID te lo da @userinfobot)."
    }
    $who = $last.message.from
    $UserId = [long]$who.id
    $answer = Read-Host "Detecté a $($who.first_name) (@$($who.username), id $UserId). ¿Es tu cuenta? [S/n]"
    if ($answer -match '^[nN]') { throw "Cancelado. Pasa tu ID con -UserId (te lo da @userinfobot)." }
}
Write-Host "Usuario autorizado: $UserId" -ForegroundColor Green

# ---------------------------------------------------------------------------
Write-Step 4 "Permisos para lo que mandes desde Telegram"
if (-not $PermissionMode) {
    Write-Host "  acceptEdits        Edita archivos sin preguntar; lo demás que requiera aprobación se bloquea. (recomendado)"
    Write-Host "  bypassPermissions  Claude hace todo sin preguntar. Cómodo, pero quien acceda a tu Telegram controla tu PC."
    Write-Host "  default            Todo lo que requiera aprobación se bloquea en las ejecuciones remotas."
    $PermissionMode = (Read-Host "Modo [acceptEdits/bypassPermissions/default] (Enter = acceptEdits)").Trim()
    if (-not $PermissionMode) { $PermissionMode = "acceptEdits" }
    if ($PermissionMode -notin "bypassPermissions", "acceptEdits", "default") { throw "Modo no válido: $PermissionMode" }
}
Write-Host "Modo: $PermissionMode" -ForegroundColor Green

# ---------------------------------------------------------------------------
Write-Step 5 "Copiando archivos y creando config.json"
foreach ($d in $HooksDir, $BridgeDir) {
    if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d | Out-Null }
}
Copy-Item (Join-Path $RepoDir "hooks\*.ps1") $HooksDir -Force
Copy-Item (Join-Path $RepoDir "bridge\*.ps1") $BridgeDir -Force
Copy-Item (Join-Path $RepoDir "assets\avatar.jpg") $BridgeDir -Force

$configPath = Join-Path $BridgeDir "config.json"
if (Test-Path -LiteralPath $configPath) {
    Copy-Item $configPath "$configPath.bak-$(Get-Date -Format yyyyMMdd-HHmmss)"
}
$config = [ordered]@{
    botToken = $BotToken
    allowedUserId = $UserId
    chatId = $UserId
    permissionMode = $PermissionMode
    maxMessageAgeMinutes = 10
    busyStaleMinutes = 120
    fallbackNotifyUrl = ""
}
[IO.File]::WriteAllText($configPath, ($config | ConvertTo-Json), (New-Object Text.UTF8Encoding $false))
Write-Host "Hooks:  $HooksDir"
Write-Host "Puente: $BridgeDir"

# ---------------------------------------------------------------------------
Write-Step 6 "Registrando hooks en settings.json"
$settings = [pscustomobject]@{}
if (Test-Path -LiteralPath $SettingsPath) {
    $backup = "$SettingsPath.bak-$(Get-Date -Format yyyyMMdd-HHmmss)"
    Copy-Item $SettingsPath $backup
    Write-Host "Respaldo: $backup"
    $raw = Get-Content -LiteralPath $SettingsPath -Raw -Encoding UTF8
    if ($raw.Trim()) { $settings = $raw | ConvertFrom-Json }
}
if (-not $settings.PSObject.Properties["hooks"] -or -not $settings.hooks) { Set-Prop $settings "hooks" ([pscustomobject]@{}) }

$wanted = @(
    @{ Event = "Stop"; File = "telegram-notify.ps1"; Timeout = 15 },
    @{ Event = "Stop"; File = "telegram-inbox-wait.ps1"; Timeout = 86400; AsyncRewake = $true },
    @{ Event = "Notification"; File = "telegram-notify-permission.ps1"; Timeout = 15 },
    @{ Event = "UserPromptSubmit"; File = "telegram-session-state.ps1"; Args = " -State busy"; Timeout = 10 },
    @{ Event = "SessionEnd"; File = "telegram-session-state.ps1"; Args = " -State idle"; Timeout = 10 },
    @{ Event = "PermissionRequest"; File = "telegram-permission-auto.ps1"; Timeout = 10 },
    @{ Event = "PreToolUse"; File = "telegram-ask-to-buttons.ps1"; Matcher = "AskUserQuestion"; Timeout = 30 }
)

foreach ($w in $wanted) {
    $command = "powershell -NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $HooksDir $w.File)`"$($w.Args)"

    # Quita entradas previas de este mismo script (reinstalación) y conserva el resto.
    $groups = @()
    if ($settings.hooks.PSObject.Properties[$w.Event]) {
        foreach ($g in @($settings.hooks.($w.Event))) {
            $kept = @($g.hooks | Where-Object { -not ($_.command -like "*$($w.File)*" -and "$($_.command)" -like "*$($w.Args)") })
            if ($kept.Count -gt 0) { Set-Prop $g "hooks" $kept; $groups += $g }
        }
    }

    $hook = [ordered]@{ type = "command"; command = $command; timeout = $w.Timeout }
    if ($w.AsyncRewake) { $hook.asyncRewake = $true }
    $group = [ordered]@{}
    if ($w.Matcher) { $group.matcher = $w.Matcher }
    $group.hooks = @([pscustomobject]$hook)
    $groups += [pscustomobject]$group

    Set-Prop $settings.hooks $w.Event $groups
    Write-Host "  $($w.Event) -> $($w.File)$($w.Args)"
}
[IO.File]::WriteAllText($SettingsPath, ($settings | ConvertTo-Json -Depth 20), (New-Object Text.UTF8Encoding $false))

# ---------------------------------------------------------------------------
Write-Step 7 "Perfil del bot y tarea programada"
if (-not $SkipBotProfile) { & (Join-Path $BridgeDir "setup-bot.ps1") }
if (-not $SkipTask) { & (Join-Path $BridgeDir "install-bridge.ps1") }

$test = Invoke-Bot $BotToken "sendMessage" @{
    chat_id = $UserId
    text = "✅ claude-code-telegram-bridge instalado. Desde ahora te aviso cuando Claude Code termine un turno. Escribe /ayuda para ver los comandos."
}
if ($test.ok) { Write-Host "Mensaje de prueba enviado a Telegram." -ForegroundColor Green }
else { Write-Warning "No pude mandar el mensaje de prueba: $($test.description)" }

Write-Host ""
Write-Host "Listo. Reinicia las sesiones de Claude Code abiertas (o espera a su próximo turno) para que tomen los hooks." -ForegroundColor Green
Write-Host "Log del puente: $(Join-Path $BridgeDir 'bridge.log')"
