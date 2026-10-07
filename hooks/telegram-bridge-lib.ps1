# Funciones compartidas por los hooks de Telegram y por el puente
# (telegram-bridge\telegram-bridge.ps1). Se carga con dot-sourcing.

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$script:TgBridgeDir = Join-Path $env:USERPROFILE ".claude\telegram-bridge"
$script:TgRegistryPath = Join-Path $script:TgBridgeDir "sessions.json"
$script:TgConfig = $null

function Get-TgConfig {
    if (-not $script:TgConfig) {
        $path = Join-Path $script:TgBridgeDir "config.json"
        $script:TgConfig = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    return $script:TgConfig
}

# Llama a la Bot API con cuerpo JSON en UTF-8 y lee la respuesta también en
# UTF-8 (Invoke-RestMethod de PS 5.1 la decodifica como Latin-1 y rompe los
# acentos y emojis). Devuelve el objeto completo { ok, result, description }.
function Invoke-TgApi {
    param(
        [Parameter(Mandatory)][string]$Method,
        [hashtable]$Params = @{},
        [int]$TimeoutSec = 15
    )
    $cfg = Get-TgConfig
    $url = "https://api.telegram.org/bot$($cfg.botToken)/$Method"
    $json = $Params | ConvertTo-Json -Depth 10 -Compress
    $bytes = [Text.Encoding]::UTF8.GetBytes($json)

    $req = [Net.HttpWebRequest]::Create($url)
    $req.Method = "POST"
    $req.ContentType = "application/json; charset=utf-8"
    $req.Timeout = $TimeoutSec * 1000
    $req.ReadWriteTimeout = $TimeoutSec * 1000
    $stream = $req.GetRequestStream()
    $stream.Write($bytes, 0, $bytes.Length)
    $stream.Close()

    $resp = $null
    try {
        $resp = $req.GetResponse()
    } catch {
        # Telegram responde 4xx con un JSON que explica el error: lo leemos igual.
        $inner = $_.Exception.InnerException
        if ($inner -is [Net.WebException] -and $inner.Response) {
            $resp = $inner.Response
        } else {
            throw
        }
    }
    $reader = New-Object IO.StreamReader($resp.GetResponseStream(), [Text.Encoding]::UTF8)
    $body = $reader.ReadToEnd()
    $reader.Close()
    $resp.Close()
    return ($body | ConvertFrom-Json)
}

function Remove-TgHtml {
    param([string]$Text)
    $t = [regex]::Replace($Text, '<[^>]+>', '')
    return ($t -replace '&lt;', '<' -replace '&gt;', '>' -replace '&amp;', '&')
}

function ConvertTo-TgHtml {
    param([string]$Text)
    if (-not $Text) { return "" }
    return ($Text -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;')
}

# Envía un mensaje al dueño por el bot del puente. Si el HTML no valida lo
# reintenta como texto plano, y si el bot no responde (p. ej. aún no se le dio
# /start) cae al endpoint PHP de siempre para no perder el aviso.
# Devuelve el message_id enviado, o $null.
function Send-TgMessage {
    param(
        [Parameter(Mandatory)][string]$Text,
        [switch]$Html,
        [long]$ReplyTo = 0,
        $ChatId = $null,
        $ReplyMarkup = $null
    )
    $cfg = Get-TgConfig
    if (-not $ChatId) { $ChatId = $cfg.chatId }
    if ($Text.Length -gt 4000) {
        $Text = $Text.Substring(0, 4000) + "`n`n(mensaje truncado por el límite de Telegram)"
    }

    $params = @{ chat_id = $ChatId; text = $Text; disable_web_page_preview = $true }
    if ($Html) { $params.parse_mode = "HTML" }
    if ($ReplyTo -gt 0) {
        $params.reply_parameters = @{ message_id = $ReplyTo; allow_sending_without_reply = $true }
    }
    if ($ReplyMarkup) { $params.reply_markup = $ReplyMarkup }

    try {
        $r = Invoke-TgApi -Method "sendMessage" -Params $params
        if ($r.ok) { return $r.result.message_id }
        if ($Html) {
            $params.Remove("parse_mode")
            $params.text = Remove-TgHtml $Text
            $r = Invoke-TgApi -Method "sendMessage" -Params $params
            if ($r.ok) { return $r.result.message_id }
        }
    } catch {}

    if ($cfg.fallbackNotifyUrl) {
        try {
            $body = @{ message = $Text }
            if ($Html) { $body.parse_mode = "HTML" }
            Invoke-RestMethod -Uri $cfg.fallbackNotifyUrl -Method Post -Body $body -TimeoutSec 5 | Out-Null
        } catch {}
    }
    return $null
}

# ---------------------------------------------------------------------------
# Registro de sesiones: sessions.json, una entrada por sesión de Claude Code
# con su carpeta y si está ocupada. Lo escriben los hooks y lo lee el puente,
# así que todo acceso pasa por un mutex con nombre.
# ---------------------------------------------------------------------------

function Get-TgShortId {
    param([string]$SessionId)
    if (-not $SessionId) { return $null }
    return $SessionId.Replace("-", "").Substring(0, 6).ToLower()
}

function Get-TgSessionTag {
    param([string]$SessionId)
    return "#s_" + (Get-TgShortId $SessionId)
}

# Botón "Responder" de los avisos: escribe "@bot /s <id> " en la caja de texto
# del chat (switch_inline_query_current_chat); el puente quita la mención.
function Get-TgReplyMarkup {
    param([string]$SessionId)
    if (-not $SessionId) { return $null }
    $prefill = "/s $(Get-TgShortId $SessionId) "
    return @{ inline_keyboard = @(, @(@{ text = "↩️ Responder"; switch_inline_query_current_chat = $prefill })) }
}

# Ejecuta $Action($list) con el registro bloqueado. Con -Write, lo que devuelva
# $Action (la lista final) se guarda en disco; sin -Write se devuelve tal cual.
function Invoke-WithTgRegistry {
    param(
        [Parameter(Mandatory)][scriptblock]$Action,
        [switch]$Write
    )
    $mutex = New-Object Threading.Mutex($false, "Local\ClaudeTelegramBridgeRegistry")
    $acquired = $false
    try {
        try { $acquired = $mutex.WaitOne(5000) } catch [Threading.AbandonedMutexException] { $acquired = $true }
        $list = New-Object Collections.ArrayList
        if (Test-Path -LiteralPath $script:TgRegistryPath) {
            $raw = Get-Content -LiteralPath $script:TgRegistryPath -Raw -Encoding UTF8
            if ($raw) {
                # En PS 5.1 ConvertFrom-Json emite el arreglo como un solo objeto:
                # foreach lo recorre bien tanto si es arreglo como si es uno solo.
                $parsed = $raw | ConvertFrom-Json
                foreach ($e in $parsed) { if ($e) { [void]$list.Add($e) } }
            }
        }
        $result = & $Action $list
        if ($Write) {
            $items = @($result | Where-Object { $_ })
            $json = if ($items.Count -eq 0) { "[]" } else { ConvertTo-Json -InputObject $items -Depth 5 }
            if (-not (Test-Path -LiteralPath $script:TgBridgeDir)) { New-Item -ItemType Directory -Path $script:TgBridgeDir | Out-Null }
            [IO.File]::WriteAllText($script:TgRegistryPath, $json, (New-Object Text.UTF8Encoding $false))
            return
        }
        return $result
    } finally {
        if ($acquired) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

function Get-TgSessions {
    return @(Invoke-WithTgRegistry -Action { param($list) $list.ToArray() })
}

function Find-TgSession {
    param([string]$IdOrPrefix)
    $key = ($IdOrPrefix -replace '^#', '' -replace '^s_', '').ToLower()
    if ($key.Length -lt 3) { return @() }
    return @(Get-TgSessions | Where-Object { $_.short -like "$key*" -or $_.sessionId -like "$key*" })
}

# Colores de sesión: Telegram no deja colorear texto, así que cada sesión
# lleva un cuadrado de color al inicio de sus mensajes. Se asigna al
# registrarla, evitando los que usan otras sesiones de la última semana.
$script:TgPalette = @("🟦", "🟩", "🟧", "🟪", "🟥", "🟨", "🟫", "⬛", "⬜")

function Select-TgFreeColor {
    param($List, $Entry)
    $limit = (Get-Date).AddDays(-7)
    $used = @{}
    foreach ($e in $List) {
        if ($e -eq $Entry -or -not $e.PSObject.Properties["color"] -or -not $e.color) { continue }
        if ([datetime]::Parse($e.lastSeen) -lt $limit) { continue }
        $used[$e.color] = 1 + [int]$used[$e.color]
    }
    foreach ($c in $script:TgPalette) { if (-not $used.ContainsKey($c)) { return $c } }
    return ($script:TgPalette | Sort-Object { [int]$used[$_] } | Select-Object -First 1)
}

function Get-TgSessionBadge {
    param([string]$SessionId)
    if (-not $SessionId) { return "⬜" }
    $entry = Get-TgSessionById $SessionId
    if ($entry -and $entry.PSObject.Properties["color"] -and $entry.color) { return $entry.color }
    $sum = 0; foreach ($ch in $SessionId.ToCharArray()) { $sum += [int]$ch }
    return $script:TgPalette[$sum % $script:TgPalette.Count]
}

# El puente escribe heartbeat.txt en cada vuelta de su bucle; si tiene más de
# 2 minutos, el puente no está corriendo.
function Test-TgBridgeAlive {
    $path = Join-Path $script:TgBridgeDir "heartbeat.txt"
    if (-not (Test-Path -LiteralPath $path)) { return $false }
    try { $beat = [datetime]::Parse((Get-Content -LiteralPath $path -Raw).Trim()) } catch { return $false }
    return ((Get-Date) - $beat).TotalSeconds -lt 120
}

function Set-TgProp {
    param($Object, [string]$Name, $Value)
    if ($Object.PSObject.Properties[$Name]) { $Object.$Name = $Value }
    else { $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value }
}

# Crea o actualiza la entrada de una sesión. $Busy / $RemoteTurn: $true, $false
# o $null (no tocar). RemoteTurn marca que el turno en curso lo pidió Telegram.
function Update-TgSession {
    param(
        [Parameter(Mandatory)][string]$SessionId,
        [string]$Cwd,
        $Busy = $null,
        $RemoteTurn = $null
    )
    Invoke-WithTgRegistry -Write -Action {
        param($list)
        $now = (Get-Date).ToString("o")
        $entry = $list | Where-Object { $_.sessionId -eq $SessionId } | Select-Object -First 1
        if (-not $entry) {
            $entry = [pscustomobject]@{
                short = Get-TgShortId $SessionId
                sessionId = $SessionId
                cwd = $null
                project = $null
                lastSeen = $now
                busy = $false
                busySince = $null
            }
            [void]$list.Add($entry)
        }
        # La carpeta se fija en el primer registro: `claude --resume` busca la
        # sesión por la carpeta donde se abrió, aunque luego se haya hecho cd.
        if ($Cwd -and -not $entry.cwd) { $entry.cwd = $Cwd }
        if ($entry.cwd -and -not $entry.project) { $entry.project = Split-Path -Path $entry.cwd -Leaf }
        if (-not $entry.PSObject.Properties["color"] -or -not $entry.color) {
            Set-TgProp $entry "color" (Select-TgFreeColor $list $entry)
        }
        $entry.lastSeen = $now
        if ($null -ne $Busy) {
            $entry.busy = [bool]$Busy
            $entry.busySince = if ($Busy) { $now } else { $null }
        }
        if ($null -ne $RemoteTurn) {
            Set-TgProp $entry "remoteTurn" ([bool]$RemoteTurn)
            Set-TgProp $entry "remoteTurnSince" $(if ($RemoteTurn) { $now } else { $null })
        }

        # Poda: sesiones sin actividad en 21 días.
        $limit = (Get-Date).AddDays(-21)
        $kept = New-Object Collections.ArrayList
        foreach ($e in $list) {
            if ([datetime]::Parse($e.lastSeen) -ge $limit) { [void]$kept.Add($e) }
        }
        $kept.ToArray()
    }
}

# Marca ocupada / libre una sesión ya registrada (lo usa el puente).
function Set-TgSessionBusy {
    param([Parameter(Mandatory)][string]$SessionId, [bool]$Busy)
    Update-TgSession -SessionId $SessionId -Busy $Busy
}

function Get-TgSessionById {
    param([string]$SessionId)
    return (Get-TgSessions | Where-Object { $_.sessionId -eq $SessionId } | Select-Object -First 1)
}

# true si el turno en curso de la sesión lo pidió Telegram (y no es de hace
# más de una hora, por si un turno interrumpido dejó la marca puesta).
function Test-TgRemoteTurn {
    param($Entry)
    if (-not $Entry -or -not $Entry.PSObject.Properties["remoteTurn"] -or -not $Entry.remoteTurn) { return $false }
    if (-not $Entry.remoteTurnSince) { return $false }
    return ((Get-Date) - [datetime]::Parse($Entry.remoteTurnSince)).TotalMinutes -lt 60
}

# ---------------------------------------------------------------------------
# Buzón por sesión: inbox\<session_id>\. El hook asyncRewake (telegram-inbox-
# wait.ps1) deja ahí waiter.json mientras escucha; el puente deja msg-*.txt y
# el hook los toma renombrándolos (rename atómico: o los toma el hook o los
# recupera el puente, nunca los dos).
# ---------------------------------------------------------------------------

function Get-TgInboxDir {
    param([string]$SessionId)
    return (Join-Path $script:TgBridgeDir "inbox\$SessionId")
}

# Devuelve el waiter.json si hay un hook escuchando vivo en esa sesión.
function Get-TgLiveWaiter {
    param([string]$SessionId)
    $path = Join-Path (Get-TgInboxDir $SessionId) "waiter.json"
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try { $w = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $null }
    if (-not $w -or -not $w.heartbeat) { return $null }
    if (((Get-Date) - [datetime]::Parse($w.heartbeat)).TotalSeconds -gt 20) { return $null }
    if (-not (Get-Process -Id $w.pid -ErrorAction SilentlyContinue)) { return $null }
    return $w
}

# ---------------------------------------------------------------------------
# Preguntas con botones: questions\<batchId>.json. Las crea el hook PreToolUse
# de AskUserQuestion (telegram-ask-to-buttons.ps1) en turnos pedidos desde
# Telegram, y el puente las va contestando con los botones / respuestas.
#   { batchId, sessionId, project, created,
#     questions: [ { question, header, multiSelect, options: [label],
#                    html, messageId, selected: [label], done } ] }
# ---------------------------------------------------------------------------

function Get-TgQuestionsDir {
    $dir = Join-Path $script:TgBridgeDir "questions"
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    return $dir
}

function Read-TgQuestionBatch {
    param([string]$BatchId)
    $path = Join-Path (Get-TgQuestionsDir) "$BatchId.json"
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    return (Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json)
}

function Save-TgQuestionBatch {
    param($Batch)
    $path = Join-Path (Get-TgQuestionsDir) "$($Batch.batchId).json"
    [IO.File]::WriteAllText($path, ($Batch | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding $false))
}

function Remove-TgQuestionBatch {
    param([string]$BatchId)
    Remove-Item -LiteralPath (Join-Path (Get-TgQuestionsDir) "$BatchId.json") -Force -ErrorAction SilentlyContinue
}

function Get-TgQuestionBatches {
    $list = @()
    foreach ($f in @(Get-ChildItem -LiteralPath (Get-TgQuestionsDir) -Filter "*.json" -ErrorAction SilentlyContinue)) {
        try { $list += (Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json) } catch {}
    }
    return $list
}

# Lee el JSON que Claude Code le pasa al hook por stdin, en UTF-8.
function Read-HookPayload {
    [Console]::InputEncoding = [Text.Encoding]::UTF8
    $raw = [Console]::In.ReadToEnd()
    if (-not $raw) { return $null }
    return ($raw | ConvertFrom-Json)
}
