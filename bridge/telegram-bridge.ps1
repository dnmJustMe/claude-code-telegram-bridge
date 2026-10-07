# Puente Telegram -> Claude Code.
#
# Lee los mensajes del bot (long polling de getUpdates), y cuando el dueño
# responde a un aviso de Claude (o usa /s <id> <texto>) se lo entrega a esa
# sesión:
#   - Si la sesión está abierta (VS Code / terminal), el hook asyncRewake
#     telegram-inbox-wait.ps1 está escuchando su buzón: el mensaje se deja ahí
#     y Claude lo procesa en la sesión abierta, a la vista.
#   - Si no hay nadie escuchando (o no lo toma en 20 s), se ejecuta
#     claude -p --resume <session_id> --permission-mode <config>
#     en la carpeta de la sesión, en segundo plano.
# En ambos casos la respuesta llega sola a Telegram por el hook Stop
# (telegram-notify.ps1), como cualquier otro turno.
#
# Lo arranca la tarea programada "Claude Telegram Bridge" al iniciar sesión en
# Windows (ver install-bridge.ps1). Una sola instancia a la vez.

$ErrorActionPreference = "Stop"
. (Join-Path $env:USERPROFILE ".claude\hooks\telegram-bridge-lib.ps1")

$BridgeDir = $script:TgBridgeDir
$JobsDir = Join-Path $BridgeDir "jobs"
$LogPath = Join-Path $BridgeDir "bridge.log"
$OffsetPath = Join-Path $BridgeDir "offset.txt"

$instance = New-Object Threading.Mutex($false, "Local\ClaudeTelegramBridgeDaemon")
$owned = $false
try { $owned = $instance.WaitOne(0) } catch [Threading.AbandonedMutexException] { $owned = $true }
if (-not $owned) { exit 0 }

if (-not (Test-Path -LiteralPath $JobsDir)) { New-Item -ItemType Directory -Path $JobsDir | Out-Null }

$Cfg = Get-TgConfig
$PermissionMode = if ($Cfg.permissionMode) { $Cfg.permissionMode } else { "default" }
$MaxAgeMinutes = if ($Cfg.maxMessageAgeMinutes) { [int]$Cfg.maxMessageAgeMinutes } else { 10 }
$BusyStaleMinutes = if ($Cfg.busyStaleMinutes) { [int]$Cfg.busyStaleMinutes } else { 120 }

# Nombre del bot (para quitar la mención "@bot" que deja el botón Responder).
$BotUsername = "\w+"
try { $me = Invoke-TgApi -Method "getMe"; if ($me.ok) { $BotUsername = [regex]::Escape($me.result.username) } } catch {}

$Jobs = @{}                                   # short -> ejecución en curso
$Queue = New-Object Collections.ArrayList     # mensajes esperando a su sesión
$LastCleanup = [datetime]::MinValue

function Write-Log {
    param([string]$Message)
    try {
        if ((Test-Path -LiteralPath $LogPath) -and (Get-Item -LiteralPath $LogPath).Length -gt 1MB) {
            Move-Item -LiteralPath $LogPath -Destination "$LogPath.1" -Force
        }
        $line = "{0:yyyy-MM-dd HH:mm:ss}  {1}" -f (Get-Date), $Message
        [IO.File]::AppendAllText($LogPath, $line + "`r`n", (New-Object Text.UTF8Encoding $false))
    } catch {}
}

function Get-ClaudeExe {
    if ($Cfg.claudePath -and (Test-Path -LiteralPath $Cfg.claudePath)) { return $Cfg.claudePath }
    $candidates = @(
        (Join-Path $env:LOCALAPPDATA "nodejs\node_modules\@anthropic-ai\claude-code\bin\claude.exe"),
        (Join-Path $env:USERPROFILE ".local\bin\claude.exe")
    )
    foreach ($c in $candidates) { if (Test-Path -LiteralPath $c) { return $c } }
    $cmd = Get-Command claude.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    throw "No encontré claude.exe"
}

function Reply {
    param($ChatId, [long]$ReplyTo, [string]$Html)
    try { Send-TgMessage -Text $Html -Html -ChatId $ChatId -ReplyTo $ReplyTo | Out-Null } catch { Write-Log "Error enviando respuesta: $_" }
}

function Format-Ago {
    param([string]$Iso)
    if (-not $Iso) { return "" }
    $span = (Get-Date) - [datetime]::Parse($Iso)
    if ($span.TotalMinutes -lt 1) { return "hace un momento" }
    if ($span.TotalMinutes -lt 60) { return "hace {0} min" -f [int]$span.TotalMinutes }
    if ($span.TotalHours -lt 24) { return "hace {0} h" -f [int]$span.TotalHours }
    return "hace {0} d" -f [int]$span.TotalDays
}

function Test-SessionBusy {
    param($Session)
    if (-not $Session.busy -or -not $Session.busySince) { return $false }
    $since = [datetime]::Parse($Session.busySince)
    return ((Get-Date) - $since).TotalMinutes -lt $BusyStaleMinutes
}

function Get-SessionLabel {
    param($Session)
    $badge = if ($Session.PSObject.Properties["color"] -and $Session.color) { "$($Session.color) " } else { "" }
    return "$badge<b>$(ConvertTo-TgHtml $Session.project)</b> #s_$($Session.short)"
}

function Resolve-Session {
    param([string]$Id, $ChatId, [long]$MsgId)
    $found = @(Find-TgSession $Id)
    if ($found.Count -eq 1) { return $found[0] }
    if ($found.Count -eq 0) {
        Reply $ChatId $MsgId "❓ No conozco la sesión <code>$(ConvertTo-TgHtml $Id)</code>. Mira /sesiones."
    } else {
        Reply $ChatId $MsgId "❓ <code>$(ConvertTo-TgHtml $Id)</code> coincide con varias sesiones; usa más letras del id."
    }
    return $null
}

# ---------------------------------------------------------------------------
# Ejecuciones
# ---------------------------------------------------------------------------

function Start-ClaudeRun {
    param($Item)
    $session = $Item.Session
    if (-not $session.cwd -or -not (Test-Path -LiteralPath $session.cwd)) {
        Reply $Item.ChatId $Item.MsgId "❌ La carpeta de $(Get-SessionLabel $session) ya no existe: <code>$(ConvertTo-TgHtml $session.cwd)</code>"
        return
    }

    $dir = Join-Path $JobsDir ("{0:yyyyMMdd-HHmmss}_{1}" -f (Get-Date), $session.short)
    New-Item -ItemType Directory -Path $dir | Out-Null
    $promptPath = Join-Path $dir "prompt.txt"
    $outPath = Join-Path $dir "out.txt"
    $errPath = Join-Path $dir "err.txt"
    [IO.File]::WriteAllText($promptPath, $Item.Text, (New-Object Text.UTF8Encoding $false))

    # cmd.exe hace las redirecciones a archivo: así claude.exe corre sin
    # ventana y sin que este script tenga que vaciar sus pipes.
    $exe = Get-ClaudeExe
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $env:ComSpec
    $psi.Arguments = '/d /s /c ""{0}" -p --resume {1} --permission-mode {2} < "{3}" > "{4}" 2> "{5}""' -f `
        $exe, $session.sessionId, $PermissionMode, $promptPath, $outPath, $errPath
    $psi.WorkingDirectory = $session.cwd
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.EnvironmentVariables["CLAUDE_TG_REMOTE"] = "1"
    $proc = [Diagnostics.Process]::Start($psi)

    $Jobs[$session.short] = @{
        Kind = "print"
        Proc = $proc
        Session = $session
        Dir = $dir
        Started = Get-Date
        ChatId = $Item.ChatId
        MsgId = $Item.MsgId
    }
    try { Set-TgSessionBusy -SessionId $session.sessionId -Busy $true } catch {}
    Write-Log "Iniciado #s_$($session.short) ($($session.project)) pid=$($proc.Id) dir=$dir"
}

# Deja el mensaje en el buzón de una sesión abierta; el hook que escucha lo
# toma en ~1.5 s. Update-Jobs confirma la entrega o, pasado el plazo, lo
# recupera y lo ejecuta con claude -p.
function Start-LiveDelivery {
    param($Item)
    $session = $Item.Session
    $inbox = Get-TgInboxDir $session.sessionId
    $msgPath = Join-Path $inbox ("msg-{0:yyyyMMddHHmmssfff}.txt" -f (Get-Date))
    [IO.File]::WriteAllText($msgPath, $Item.Text, (New-Object Text.UTF8Encoding $false))
    $Jobs[$session.short] = @{
        Kind = "live"
        Item = $Item
        Session = $session
        MsgPath = $msgPath
        Deadline = (Get-Date).AddSeconds(20)
        Started = Get-Date
        ChatId = $Item.ChatId
        MsgId = $Item.MsgId
    }
    Write-Log "Entregando en vivo a #s_$($session.short) ($($session.project)): $msgPath"
}

function Get-FileTail {
    param([string]$Path, [int]$Chars = 1200)
    if (-not (Test-Path -LiteralPath $Path)) { return "" }
    $t = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8).Trim()
    if ($t.Length -gt $Chars) { $t = "…" + $t.Substring($t.Length - $Chars) }
    return $t
}

function Update-Jobs {
    foreach ($short in @($Jobs.Keys)) {
        $job = $Jobs[$short]

        if ($job.Kind -eq "live") {
            $takenPath = [IO.Path]::ChangeExtension($job.MsgPath, ".taken")
            if (Test-Path -LiteralPath $takenPath) {
                $Jobs.Remove($short)
                Write-Log "Entregado en vivo a #s_$short"
                continue
            }
            if ((Get-Date) -lt $job.Deadline) { continue }
            # Nadie lo tomó: lo recuperamos (rename atómico) y va por claude -p.
            $cancelled = $false
            try { [IO.File]::Move($job.MsgPath, [IO.Path]::ChangeExtension($job.MsgPath, ".cancelled")); $cancelled = $true } catch {}
            $Jobs.Remove($short)
            if (-not $cancelled) { Write-Log "Entregado en vivo a #s_$short (justo al límite)"; continue }
            Write-Log "Sin respuesta del buzón de #s_$short; paso a claude -p"
            Reply $job.ChatId $job.MsgId "ℹ️ La sesión $(Get-SessionLabel $job.Session) no tomó el mensaje; lo ejecuto en segundo plano (no se verá en VS Code hasta reabrirla)."
            try { Start-ClaudeRun $job.Item } catch {
                Write-Log "Error iniciando #s_${short}: $_"
                Reply $job.ChatId $job.MsgId "❌ No pude iniciar Claude en $(Get-SessionLabel $job.Session): $(ConvertTo-TgHtml "$_")"
            }
            continue
        }

        if (-not $job.Proc.HasExited) { continue }
        $code = $job.Proc.ExitCode
        $Jobs.Remove($short)
        try { Set-TgSessionBusy -SessionId $job.Session.sessionId -Busy $false } catch {}
        $mins = [math]::Round(((Get-Date) - $job.Started).TotalMinutes, 1)
        Write-Log "Terminado #s_$short exit=$code ($mins min)"
        if ($code -ne 0) {
            $err = Get-FileTail (Join-Path $job.Dir "err.txt")
            $out = Get-FileTail (Join-Path $job.Dir "out.txt") 600
            $detail = (@($err, $out) | Where-Object { $_ }) -join "`n---`n"
            if (-not $detail) { $detail = "(sin salida)" }
            Reply $job.ChatId $job.MsgId ("❌ Falló la ejecución en $(Get-SessionLabel $job.Session) (código $code).`n<pre>" + (ConvertTo-TgHtml $detail) + "</pre>")
        }
    }
}

# Suelta de la cola lo que ya puede correr: una ejecución por sesión, y solo
# si la sesión no está ocupada (p. ej. trabajando en VS Code). Devuelve los
# elementos que arrancó.
function Invoke-Dispatch {
    $started = @()
    $sessions = Get-TgSessions
    foreach ($item in @($Queue.ToArray())) {
        $short = $item.Session.short
        if ($Jobs.ContainsKey($short)) { continue }
        $current = $sessions | Where-Object { $_.sessionId -eq $item.Session.sessionId } | Select-Object -First 1
        if ($current -and (Test-SessionBusy $current)) { continue }
        $Queue.Remove($item)
        try {
            if (Get-TgLiveWaiter $item.Session.sessionId) { Start-LiveDelivery $item } else { Start-ClaudeRun $item }
            if ($Jobs.ContainsKey($short)) { $started += $item }
        } catch {
            Write-Log "Error iniciando #s_${short}: $_"
            Reply $item.ChatId $item.MsgId "❌ No pude iniciar Claude en $(Get-SessionLabel $item.Session): $(ConvertTo-TgHtml "$_")"
        }
    }
    return $started
}

function Add-ToQueue {
    param($Session, [string]$Text, $ChatId, [long]$MsgId)
    $item = [pscustomobject]@{
        Session = $Session
        Text = $Text
        ChatId = $ChatId
        MsgId = $MsgId
        QueuedAt = Get-Date
    }
    [void]$Queue.Add($item)
    $started = @(Invoke-Dispatch)
    $label = Get-SessionLabel $Session
    if ($started -contains $item) {
        $where = if ($Jobs[$Session.short].Kind -eq "live") { "a la sesión abierta" } else { "en segundo plano (sesión cerrada)" }
        Reply $ChatId $MsgId "▶️ Enviado a $label, $where. Te aviso cuando termine."
        return
    }
    $pos = @($Queue | Where-Object { $_.Session.short -eq $Session.short }).IndexOf($item) + 1
    $why = if ($Jobs.ContainsKey($Session.short)) {
        "ya está corriendo algo que le mandaste"
    } else {
        $fresh = Find-TgSession $Session.short | Select-Object -First 1
        "está trabajando ($(Format-Ago $fresh.busySince))"
    }
    Reply $ChatId $MsgId "🕒 En cola para $label (posición $pos): la sesión $why. Se envía en cuanto termine.`nSi quedó trabada: <code>/forzar $($Session.short)</code>"
}

# ---------------------------------------------------------------------------
# Comandos
# ---------------------------------------------------------------------------

$HelpText = @"
🤖 <b>Puente Claude Code</b>

• <b>Responde</b> a cualquier aviso de Claude (los que traen <code>#s_…</code>) y tu mensaje continúa esa sesión, en su proyecto.
• <code>/s id mensaje</code> — envía a la sesión <i>id</i> (las letras después de #s_).
• /sesiones — sesiones recientes y su estado.
• <code>/parar id</code> — detiene lo que esté corriendo en esa sesión y vacía su cola.
• <code>/forzar id</code> — marca la sesión como libre si quedó trabada y suelta su cola.

Si la sesión está <b>abierta</b> (VS Code), el mensaje aparece y se procesa ahí mismo. Si está <b>cerrada</b>, corre en segundo plano y lo verás al reabrirla.
Si la sesión está ocupada, tu mensaje espera en cola. Ojo: lo que mandas desde aquí corre con permisos <b>$PermissionMode</b>.
"@

function Get-SessionsText {
    param([int]$Max = 10)
    $list = @(Get-TgSessions | Sort-Object { [datetime]::Parse($_.lastSeen) } -Descending | Select-Object -First $Max)
    if ($list.Count -eq 0) { return "No hay sesiones registradas todavía. Aparecen en cuanto Claude termina un turno." }
    $lines = foreach ($s in $list) {
        $state = if ($Jobs.ContainsKey($s.short)) {
                     if ($Jobs[$s.short].Kind -eq "live") { "📨 entregando" } else { "▶️ corriendo en segundo plano" }
                 }
                 elseif (Test-SessionBusy $s) { "🔄 trabajando" }
                 elseif (Get-TgLiveWaiter $s.sessionId) { "🟢 abierta, escuchando" }
                 else { "⚪ cerrada" }
        $queued = @($Queue | Where-Object { $_.Session.short -eq $s.short }).Count
        $q = if ($queued -gt 0) { " · $queued en cola" } else { "" }
        $badge = if ($s.PSObject.Properties["color"] -and $s.color) { $s.color } else { "•" }
        "$badge <b>$(ConvertTo-TgHtml $s.project)</b> <code>$($s.short)</code> — $state$q · $(Format-Ago $s.lastSeen)"
    }
    return "🗂 <b>Sesiones recientes</b>`n`n" + ($lines -join "`n") + "`n`nResponde a un aviso o usa <code>/s id mensaje</code>."
}

function Stop-SessionRun {
    param($Session, $ChatId, [long]$MsgId)
    $short = $Session.short
    $removed = 0
    foreach ($item in @($Queue.ToArray())) {
        if ($item.Session.short -eq $short) { $Queue.Remove($item); $removed++ }
    }
    $killed = $false
    if ($Jobs.ContainsKey($short)) {
        $job = $Jobs[$short]
        if ($job.Kind -eq "live") {
            # Si el hook aún no lo tomó, se retira; si ya lo tomó, el turno
            # corre en la sesión abierta y solo se detiene desde la PC (Esc).
            try { [IO.File]::Move($job.MsgPath, [IO.Path]::ChangeExtension($job.MsgPath, ".cancelled")); $killed = $true } catch {}
        } else {
            & taskkill.exe /T /F /PID $job.Proc.Id 2>&1 | Out-Null
            $killed = $true
        }
        $Jobs.Remove($short)
    }
    try { Set-TgSessionBusy -SessionId $Session.sessionId -Busy $false } catch {}
    Write-Log "Parar #s_$short killed=$killed cola=$removed"
    $msg = if ($killed) { "⏹ Detuve lo que le mandé a $(Get-SessionLabel $Session)." } else { "ℹ️ No había nada mío corriendo en $(Get-SessionLabel $Session). Si está trabajando en la sesión abierta, solo se detiene desde la PC (Esc)." }
    if ($removed -gt 0) { $msg += " Quité $removed mensaje(s) de la cola." }
    Reply $ChatId $MsgId $msg
}

# ---------------------------------------------------------------------------
# Preguntas con botones (las crea telegram-ask-to-buttons.ps1)
# ---------------------------------------------------------------------------

function Get-QuestionKeyboard {
    param($Q, [string]$BatchId, [int]$Index)
    $rows = @()
    $opts = @($Q.options)
    $sel = @($Q.selected)
    for ($j = 0; $j -lt $opts.Count; $j++) {
        $mark = if ($sel -contains $opts[$j]) { "✅ " } else { "" }
        $rows += , @(@{ text = "$mark$($opts[$j])"; callback_data = "q|$BatchId|$Index|$j" })
    }
    if ($Q.multiSelect) { $rows += , @(@{ text = "✔️ Enviar selección"; callback_data = "q|$BatchId|$Index|ok" }) }
    return @{ inline_keyboard = $rows }
}

# Deja la pregunta respondida en el chat (texto + respuesta, sin botones).
function Close-Question {
    param($Q)
    $answer = ConvertTo-TgHtml (@($Q.selected) -join ", ")
    try {
        Invoke-TgApi -Method "editMessageText" -Params @{
            chat_id = $Cfg.chatId
            message_id = [long]$Q.messageId
            text = "$($Q.html)`n`n✅ <b>Respuesta:</b> $answer"
            parse_mode = "HTML"
        } | Out-Null
    } catch { Write-Log "No pude editar la pregunta $($Q.messageId): $_" }
}

# Con todas las preguntas del lote respondidas, se las manda a la sesión como
# un mensaje más (en vivo si está abierta, o en segundo plano).
function Complete-QuestionBatch {
    param($Batch, $ChatId, [long]$MsgId)
    $lines = foreach ($q in @($Batch.questions)) { "- $($q.question) → $(@($q.selected) -join ', ')" }
    $text = "Respuestas a tus preguntas (contestadas con los botones de Telegram):`n" + ($lines -join "`n")
    Remove-TgQuestionBatch $Batch.batchId
    Write-Log "Preguntas $($Batch.batchId) respondidas para $($Batch.sessionId)"
    $session = Get-TgSessionById $Batch.sessionId
    if (-not $session) {
        Reply $ChatId $MsgId "❌ Ya no encuentro la sesión de esas preguntas."
        return
    }
    Add-ToQueue $session $text $ChatId $MsgId
}

function Test-BatchDone {
    param($Batch)
    return (@($Batch.questions | Where-Object { -not $_.done }).Count -eq 0)
}

function Invoke-Callback {
    param($Callback)
    $toast = $null
    try {
        if ([long]$Callback.from.id -ne [long]$Cfg.allowedUserId) { return }
        $m = [regex]::Match([string]$Callback.data, '^q\|(\w{8})\|(\d+)\|(\d+|ok)$')
        if (-not $m.Success) { return }

        $batch = Read-TgQuestionBatch $m.Groups[1].Value
        if (-not $batch) { $toast = "Esta pregunta ya no está activa."; return }
        $index = [int]$m.Groups[2].Value
        $q = @($batch.questions)[$index]
        if (-not $q) { return }
        if ($q.done) { $toast = "Ya la respondiste."; return }

        $choice = $m.Groups[3].Value
        if ($choice -eq "ok") {
            if (@($q.selected).Count -eq 0) { $toast = "Marca al menos una opción."; return }
            $q.done = $true
            Close-Question $q
        } else {
            $label = @($q.options)[[int]$choice]
            if ($q.multiSelect) {
                $sel = New-Object Collections.ArrayList
                foreach ($s in @($q.selected)) { if ($s) { [void]$sel.Add($s) } }
                if ($sel -contains $label) { $sel.Remove($label) } else { [void]$sel.Add($label) }
                $q.selected = $sel.ToArray()
                Save-TgQuestionBatch $batch
                Invoke-TgApi -Method "editMessageReplyMarkup" -Params @{
                    chat_id = $Cfg.chatId
                    message_id = [long]$q.messageId
                    reply_markup = (Get-QuestionKeyboard $q $batch.batchId $index)
                } | Out-Null
                return
            }
            $q.selected = @($label)
            $q.done = $true
            Close-Question $q
            $toast = "Elegiste: $label"
        }

        Save-TgQuestionBatch $batch
        if (Test-BatchDone $batch) {
            Complete-QuestionBatch $batch $Callback.message.chat.id ([long]$Callback.message.message_id)
        }
    } finally {
        $params = @{ callback_query_id = $Callback.id }
        if ($toast) { $params.text = $toast }
        try { Invoke-TgApi -Method "answerCallbackQuery" -Params $params | Out-Null } catch {}
    }
}

# Si el mensaje responde (con texto) a una pregunta pendiente, es su respuesta
# libre. Devuelve $true si lo consumió.
function Invoke-QuestionReply {
    param([long]$RepliedId, [string]$Text, $ChatId, [long]$MsgId)
    foreach ($batch in @(Get-TgQuestionBatches)) {
        foreach ($q in @($batch.questions)) {
            if ($q.done -or [long]$q.messageId -ne $RepliedId) { continue }
            $q.selected = @($Text)
            $q.done = $true
            Close-Question $q
            Save-TgQuestionBatch $batch
            if (Test-BatchDone $batch) {
                Complete-QuestionBatch $batch $ChatId $MsgId
            } else {
                $left = @($batch.questions | Where-Object { -not $_.done }).Count
                Reply $ChatId $MsgId "📝 Anotado. Falta(n) $left pregunta(s) por responder."
            }
            return $true
        }
    }
    return $false
}

function Invoke-Message {
    param($Message)
    $chatId = $Message.chat.id
    $msgId = [long]$Message.message_id

    if ([long]$Message.from.id -ne [long]$Cfg.allowedUserId -or $Message.chat.type -ne "private") {
        Write-Log "Ignorado mensaje de from=$($Message.from.id) chat=$chatId"
        return
    }

    $sentAt = [DateTimeOffset]::FromUnixTimeSeconds([long]$Message.date).LocalDateTime
    $age = ((Get-Date) - $sentAt).TotalMinutes
    $text = if ($Message.text) { [string]$Message.text } else { [string]$Message.caption }
    # El botón "Responder" de los avisos deja "@bot /s <id> ..." en la caja de
    # texto: la mención sobra.
    if ($text) { $text = [regex]::Replace($text, "^\s*@$BotUsername\s+", "", "IgnoreCase") }
    if (-not $text) {
        Reply $chatId $msgId "Por ahora solo entiendo texto."
        return
    }
    $cmd = $null
    $rest = ""
    if ($text.StartsWith("/")) {
        $m = [regex]::Match($text, '^/(\w+)(?:@\w+)?(?:\s+([\s\S]*))?$')
        $cmd = $m.Groups[1].Value.ToLower()
        $rest = $m.Groups[2].Value.Trim()
    }

    # Lo que ejecuta algo no se corre si es viejo (la PC estaba apagada y el
    # mensaje esperó en Telegram); las consultas sí se responden.
    $readOnly = $cmd -in "start", "ayuda", "help", "sesiones"
    if ($age -gt $MaxAgeMinutes -and -not $readOnly) {
        Write-Log "Ignorado por viejo ($([int]$age) min): $text"
        Reply $chatId $msgId "⌛ No ejecuté este mensaje: es de hace $([int]$age) min (la PC o el puente estaban apagados). Reenvíalo si todavía aplica."
        return
    }

    if ($cmd) {
        switch ($cmd) {
            { $_ -in "start", "ayuda", "help" } { Reply $chatId $msgId $HelpText; return }
            "sesiones" { Reply $chatId $msgId (Get-SessionsText); return }
            "s" {
                $a = [regex]::Match($rest, '^(\S+)\s+([\s\S]+)$')
                if (-not $a.Success) { Reply $chatId $msgId "Uso: <code>/s id mensaje</code>"; return }
                $session = Resolve-Session $a.Groups[1].Value $chatId $msgId
                if ($session) { Add-ToQueue $session $a.Groups[2].Value.Trim() $chatId $msgId }
                return
            }
            "parar" {
                if (-not $rest) { Reply $chatId $msgId "Uso: <code>/parar id</code>"; return }
                $session = Resolve-Session ($rest -split '\s+')[0] $chatId $msgId
                if ($session) { Stop-SessionRun $session $chatId $msgId }
                return
            }
            "forzar" {
                if (-not $rest) { Reply $chatId $msgId "Uso: <code>/forzar id</code>"; return }
                $session = Resolve-Session ($rest -split '\s+')[0] $chatId $msgId
                if ($session) {
                    Set-TgSessionBusy -SessionId $session.sessionId -Busy $false
                    $started = @(Invoke-Dispatch)
                    Reply $chatId $msgId "🔓 Marqué $(Get-SessionLabel $session) como libre. Arrancaron $($started.Count) mensaje(s) de la cola."
                }
                return
            }
            default { Reply $chatId $msgId "No conozco <code>/$(ConvertTo-TgHtml $cmd)</code>.`n`n$HelpText"; return }
        }
    }

    # Respuesta a un aviso: la sesión sale del tag #s_xxxxxx del mensaje citado.
    $quoted = $null
    if ($Message.reply_to_message) {
        # Respuesta escrita a una pregunta con botones pendiente.
        if (Invoke-QuestionReply ([long]$Message.reply_to_message.message_id) $text $chatId $msgId) { return }
        $quoted = if ($Message.reply_to_message.text) { [string]$Message.reply_to_message.text } else { [string]$Message.reply_to_message.caption }
    }
    $tag = if ($quoted) { [regex]::Match($quoted, '#s_([0-9a-f]{6})') } else { $null }
    if ($tag -and $tag.Success) {
        $session = Resolve-Session $tag.Groups[1].Value $chatId $msgId
        if ($session) { Add-ToQueue $session $text $chatId $msgId }
        return
    }

    Reply $chatId $msgId ("¿Para qué sesión es? Responde a un aviso de Claude o usa <code>/s id mensaje</code>.`n`n" + (Get-SessionsText 5))
}

function Remove-OldJobDirs {
    $limit = (Get-Date).AddDays(-7)
    Get-ChildItem -LiteralPath $JobsDir -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt $limit } |
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    # Lotes de preguntas que nadie contestó en un día.
    foreach ($b in @(Get-TgQuestionBatches)) {
        if ($b.created -and ((Get-Date) - [datetime]::Parse($b.created)).TotalHours -gt 24) { Remove-TgQuestionBatch $b.batchId }
    }
    $inboxRoot = Join-Path $BridgeDir "inbox"
    if (Test-Path -LiteralPath $inboxRoot) {
        Get-ChildItem -LiteralPath $inboxRoot -Recurse -File -Include "*.taken", "*.cancelled" -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt $limit } |
            Remove-Item -Force -ErrorAction SilentlyContinue
        Get-ChildItem -LiteralPath $inboxRoot -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt $limit -and -not (Get-ChildItem -LiteralPath $_.FullName -Force) } |
            Remove-Item -Force -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------------------
# Bucle principal
# ---------------------------------------------------------------------------

$offset = 0
if (Test-Path -LiteralPath $OffsetPath) { [long]::TryParse((Get-Content -LiteralPath $OffsetPath -Raw).Trim(), [ref]$offset) | Out-Null }
Write-Log "Puente iniciado (pid=$PID, permisos=$PermissionMode, offset=$offset)"

# heartbeat.txt: lo revisan los hooks (Test-TgBridgeAlive) para saber si el
# puente corre. Si llevaba más de 5 min sin latir (PC apagada, caída), se avisa
# que volvió; un reinicio rápido no manda nada.
$HeartbeatPath = Join-Path $BridgeDir "heartbeat.txt"
$downSince = $null
if (Test-Path -LiteralPath $HeartbeatPath) {
    try { $downSince = [datetime]::Parse((Get-Content -LiteralPath $HeartbeatPath -Raw).Trim()) } catch {}
}
if (-not $downSince -or ((Get-Date) - $downSince).TotalMinutes -gt 5) {
    $since = if ($downSince) { " (sin servicio desde $(Format-Ago $downSince.ToString('o')))" } else { "" }
    Reply $Cfg.chatId 0 "🟢 <b>Puente activo</b> en la PC$since. Ya puedo recibir tus mensajes. /sesiones"
}

function Write-Heartbeat {
    try { [IO.File]::WriteAllText($HeartbeatPath, (Get-Date).ToString("o")) } catch {}
}
Write-Heartbeat

while ($true) {
    try {
        Write-Heartbeat
        if (((Get-Date) - $LastCleanup).TotalHours -ge 6) { Remove-OldJobDirs; $LastCleanup = Get-Date }

        Update-Jobs
        if ($Queue.Count -gt 0) { Invoke-Dispatch | Out-Null }

        # Con trabajos o cola pendientes se sondea más seguido para notarlos antes.
        $liveJobs = @($Jobs.Values | Where-Object { $_.Kind -eq "live" }).Count
        $wait = if ($liveJobs -gt 0) { 2 } elseif ($Jobs.Count -gt 0 -or $Queue.Count -gt 0) { 5 } else { 20 }
        $r = Invoke-TgApi -Method "getUpdates" -Params @{ offset = $offset; timeout = $wait; allowed_updates = @("message", "callback_query") } -TimeoutSec ($wait + 15)
        if (-not $r.ok) {
            Write-Log "getUpdates falló: $($r.error_code) $($r.description)"
            Start-Sleep -Seconds $(if ($r.error_code -eq 409) { 30 } else { 5 })
            continue
        }
        foreach ($u in @($r.result)) {
            if (-not $u) { continue }
            $offset = [long]$u.update_id + 1
            Set-Content -LiteralPath $OffsetPath -Value $offset -Encoding ASCII
            if ($u.message) {
                try { Invoke-Message $u.message } catch { Write-Log "Error procesando mensaje: $_ $($_.ScriptStackTrace)" }
            }
            if ($u.callback_query) {
                try { Invoke-Callback $u.callback_query } catch { Write-Log "Error procesando botón: $_ $($_.ScriptStackTrace)" }
            }
        }
    } catch {
        Write-Log "Error en el bucle: $_"
        Start-Sleep -Seconds 5
    }
}
