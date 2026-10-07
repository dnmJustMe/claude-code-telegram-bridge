$ErrorActionPreference = "SilentlyContinue"
. (Join-Path $PSScriptRoot "telegram-bridge-lib.ps1")

function Convert-MarkdownToTelegramHtml {
    param([string]$Text)

    # 1) Escape HTML special chars first so literal <, >, & from the source
    #    survive, and so our own inserted tags below are the only real tags.
    $t = $Text -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;'

    # 2) Protect fenced code blocks / inline code from later formatting passes.
    $codeBlocks = New-Object System.Collections.Generic.List[string]
    $t = [regex]::Replace($t, '```[a-zA-Z0-9]*\r?\n([\s\S]*?)```', {
        param($m)
        $codeBlocks.Add($m.Groups[1].Value.TrimEnd())
        "{{CODEBLOCK$($codeBlocks.Count - 1)}}"
    })

    $inlineCode = New-Object System.Collections.Generic.List[string]
    $t = [regex]::Replace($t, '`([^`\r\n]+)`', {
        param($m)
        $inlineCode.Add($m.Groups[1].Value)
        "{{INLINECODE$($inlineCode.Count - 1)}}"
    })

    # 3) Headers -> bold line
    $t = [regex]::Replace($t, '(?m)^#{1,6}\s*(.+)$', '<b>$1</b>')

    # 4) Bold / italic
    $t = [regex]::Replace($t, '\*\*([^\*\r\n]+)\*\*', '<b>$1</b>')
    $t = [regex]::Replace($t, '__([^_\r\n]+)__', '<b>$1</b>')
    $t = [regex]::Replace($t, '(?<!\*)\*([^\*\r\n]+)\*(?!\*)', '<i>$1</i>')
    $t = [regex]::Replace($t, '(?<!_)_([^_\r\n]+)_(?!_)', '<i>$1</i>')

    # 5) Links [text](url)
    $t = [regex]::Replace($t, '\[([^\]]+)\]\(([^\)]+)\)', '<a href="$2">$1</a>')

    # 6) Bullets and horizontal rules
    $t = [regex]::Replace($t, '(?m)^\s*[\-\*]\s+', '• ')
    $t = [regex]::Replace($t, '(?m)^\s*[\-\*_]{3,}\s*$', '')

    # 7) Restore protected spans
    $t = [regex]::Replace($t, '\{\{INLINECODE(\d+)\}\}', {
        param($m)
        "<code>$($inlineCode[[int]$m.Groups[1].Value])</code>"
    })
    $t = [regex]::Replace($t, '\{\{CODEBLOCK(\d+)\}\}', {
        param($m)
        "<pre>$($codeBlocks[[int]$m.Groups[1].Value])</pre>"
    })

    return $t.Trim()
}

# Parte el texto (markdown, antes de pasarlo a HTML) en trozos que quepan en un
# mensaje de Telegram, cortando de preferencia entre párrafos. Si un corte cae
# dentro de un bloque ``` lo cierra y lo reabre en el trozo siguiente.
function Split-TelegramMarkdown {
    param([string]$Text, [int]$Max = 3200, [int]$MaxParts = 10)
    $chunks = New-Object System.Collections.Generic.List[string]
    $rest = $Text
    $carryFence = $false
    while ($rest.Length -gt 0) {
        $prefix = if ($carryFence) { "``````n" } else { "" }
        $room = $Max - $prefix.Length
        if ($rest.Length -le $room -or $chunks.Count -eq $MaxParts - 1) {
            $piece = $rest
            if ($piece.Length -gt $room) { $piece = $piece.Substring(0, $room) + "`n`n_(…respuesta recortada: era demasiado larga)_" }
            $rest = ""
        } else {
            $cut = $rest.LastIndexOf("`n`n", $room)
            if ($cut -lt [int]($room * 0.5)) { $cut = $rest.LastIndexOf("`n", $room) }
            if ($cut -lt [int]($room * 0.3)) { $cut = $room }
            $piece = $rest.Substring(0, $cut)
            $rest = $rest.Substring($cut).TrimStart("`r", "`n")
        }
        $chunk = $prefix + $piece
        $open = ([regex]::Matches($chunk, '(?m)^```')).Count % 2 -eq 1
        if ($open -and $rest.Length -gt 0) { $chunk += "`n``````"; $carryFence = $true } else { $carryFence = $false }
        $chunks.Add($chunk)
    }
    if ($chunks.Count -eq 0) { $chunks.Add("") }
    return $chunks.ToArray()
}

$parts = @()

try {
    $payload = Read-HookPayload
    $transcriptPath = $payload.transcript_path
    $cwd = $payload.cwd
    $sessionId = $payload.session_id
    $lastText = $null

    # La sesión queda libre: el puente puede soltarle lo que tenga en cola.
    $fromTelegram = $env:CLAUDE_TG_REMOTE -eq "1"
    if ($sessionId) {
        try {
            if (Test-TgRemoteTurn (Get-TgSessionById $sessionId)) { $fromTelegram = $true }
            Update-TgSession -SessionId $sessionId -Cwd $cwd -Busy $false -RemoteTurn $false
        } catch {}
    }

    if ($transcriptPath -and (Test-Path $transcriptPath)) {
        $lines = Get-Content -LiteralPath $transcriptPath -Encoding UTF8
        for ($i = $lines.Count - 1; $i -ge 0; $i--) {
            $line = $lines[$i]
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            $entry = $null
            try { $entry = $line | ConvertFrom-Json } catch { continue }
            if ($entry.type -eq "assistant" -and $entry.message.content) {
                $textParts = @()
                foreach ($block in $entry.message.content) {
                    if ($block.type -eq "text" -and $block.text) {
                        $textParts += $block.text
                    }
                }
                if ($textParts.Count -gt 0) {
                    $lastText = ($textParts -join "`n").Trim()
                    break
                }
            }
        }
    }

    if (-not $lastText) {
        $lastText = "(sin texto de respuesta)"
    }

    # Las respuestas a mensajes de Telegram empiezan citando el mensaje para
    # que se vea en VS Code (telegram-inbox-wait.ps1); en Telegram sobra.
    $lastText = [regex]::Replace($lastText, '^\s*>\s*📱[^\n]*\n(?:>[^\n]*\n)*\s*', '')

    $projectName = "sesion"
    if ($cwd) {
        $projectName = Split-Path -Path $cwd -Leaf
    }

    # Encabezado: cuadrado de color de la sesión + proyecto + tag #s_xxxxxx
    # (respondiendo a un aviso con ese tag, el puente lo manda a esta sesión).
    $badge = Get-TgSessionBadge $sessionId
    $project = ConvertTo-TgHtml $projectName
    $tag = if ($sessionId) { "  " + (Get-TgSessionTag $sessionId) } else { "" }
    $origin = if ($fromTelegram) { " 📱" } else { "" }

    # Si el puente no está corriendo, tus respuestas desde Telegram no llegarían:
    # se intenta levantar y se avisa en el mensaje.
    $warning = ""
    if (-not (Test-TgBridgeAlive)) {
        try { Start-ScheduledTask -TaskName "Claude Telegram Bridge" } catch {}
        $warning = "`n⚠️ <i>El puente de Telegram no estaba corriendo; intenté reiniciarlo. Si no responde a tus mensajes, revisa la PC.</i>"
    }

    $chunks = @(Split-TelegramMarkdown -Text $lastText)
    $total = $chunks.Count
    $parts = @()
    for ($k = 0; $k -lt $total; $k++) {
        $n = $k + 1
        $partLabel = if ($total -gt 1) { " · parte $n/$total" } else { "" }
        $head = if ($k -eq 0) {
            "$badge <b>$project</b> · ✅ terminó$partLabel$tag$origin$warning"
        } else {
            "$badge <b>$project</b> · ⤵️ <b>continuación</b>$partLabel$tag"
        }
        $foot = if ($total -eq 1) { "" }
                elseif ($n -lt $total) { "`n`n<i>⤵️ Sigue en el siguiente mensaje (parte $($n + 1)/$total)…</i>" }
                else { "`n`n<i>✔️ Fin de la respuesta ($total partes).</i>" }
        $parts += $head + "`n`n" + (Convert-MarkdownToTelegramHtml -Text $chunks[$k]) + $foot
    }
} catch {
    $parts = @("✅ Claude terminó de responder.")
}

# Si el turno acabó porque se mandaron preguntas con botones (telegram-ask-to-
# buttons.ps1), ya llegaron a Telegram: el aviso de "terminó" sobra.
$askedJustNow = $false
try {
    if ($sessionId) {
        $askedJustNow = @(Get-TgQuestionBatches | Where-Object {
            $_.sessionId -eq $sessionId -and ((Get-Date) - [datetime]::Parse($_.created)).TotalMinutes -lt 3 -and
            @($_.questions | Where-Object { $_.done }).Count -eq 0
        }).Count -gt 0
    }
} catch {}

# Cada parte responde a la anterior, para que queden encadenadas en el chat; el
# botón "Responder" va solo en la última. Send-TgMessage cae al endpoint PHP si
# el bot falla.
if (-not $askedJustNow) {
    $prev = 0
    for ($k = 0; $k -lt $parts.Count; $k++) {
        $markup = if ($k -eq $parts.Count - 1) { Get-TgReplyMarkup $sessionId } else { $null }
        try {
            $mid = Send-TgMessage -Text $parts[$k] -Html -ReplyTo $prev -ReplyMarkup $markup
            if ($mid) { $prev = [long]$mid }
        } catch {}
    }
}
