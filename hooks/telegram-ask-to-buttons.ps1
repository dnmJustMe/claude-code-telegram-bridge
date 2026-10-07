# Hook PreToolUse (matcher AskUserQuestion): en turnos pedidos desde Telegram
# nadie puede contestar el diálogo de la PC, así que manda cada pregunta al bot
# con un botón por opción y bloquea la herramienta. Claude termina el turno y
# las respuestas llegan después a la sesión como un mensaje de Telegram (las
# arma telegram-bridge.ps1 cuando se contestan todas).
# En turnos escritos en VS Code no hace nada y el diálogo sale como siempre.

$ErrorActionPreference = "SilentlyContinue"
. (Join-Path $PSScriptRoot "telegram-bridge-lib.ps1")

try {
    $payload = Read-HookPayload
    if (-not $payload -or $payload.tool_name -ne "AskUserQuestion" -or -not $payload.session_id) { exit 0 }

    $entry = Get-TgSessionById $payload.session_id
    $remote = ($env:CLAUDE_TG_REMOTE -eq "1") -or (Test-TgRemoteTurn $entry)
    if (-not $remote) { exit 0 }

    $questions = @($payload.tool_input.questions)
    if ($questions.Count -eq 0) { exit 0 }

    $batchId = [guid]::NewGuid().ToString("N").Substring(0, 8)
    $project = if ($entry -and $entry.project) { $entry.project } else { Split-Path -Path $payload.cwd -Leaf }
    $tag = Get-TgSessionTag $payload.session_id
    $total = $questions.Count

    $batchQuestions = @()
    for ($i = 0; $i -lt $total; $i++) {
        $q = $questions[$i]
        $labels = @($q.options | ForEach-Object { [string]$_.label })
        $multi = [bool]$q.multiSelect

        $lines = @()
        $num = if ($total -gt 1) { " ($($i + 1)/$total)" } else { "" }
        $head = if ($q.header) { ConvertTo-TgHtml $q.header } else { "Pregunta" }
        $lines += "$(Get-TgSessionBadge $payload.session_id) <b>$(ConvertTo-TgHtml $project)</b> · ❓ <b>$head</b>$num  $tag"
        $lines += ""
        $lines += ConvertTo-TgHtml $q.question
        $lines += ""
        foreach ($opt in $q.options) {
            $desc = if ($opt.description) { ": " + (ConvertTo-TgHtml $opt.description) } else { "" }
            $lines += "• <b>$(ConvertTo-TgHtml $opt.label)</b>$desc"
        }
        $lines += ""
        $hint = if ($multi) { "<i>Puedes marcar varias y luego tocar «Enviar». </i>" } else { "" }
        $lines += $hint + "<i>Para otra respuesta, contesta a este mensaje con texto.</i>"
        $html = $lines -join "`n"

        $rows = @()
        for ($j = 0; $j -lt $labels.Count; $j++) {
            $rows += , @(@{ text = $labels[$j]; callback_data = "q|$batchId|$i|$j" })
        }
        if ($multi) { $rows += , @(@{ text = "✔️ Enviar selección"; callback_data = "q|$batchId|$i|ok" }) }

        $mid = Send-TgMessage -Text $html -Html -ReplyMarkup @{ inline_keyboard = $rows }

        $batchQuestions += [pscustomobject]@{
            question = [string]$q.question
            header = [string]$q.header
            multiSelect = $multi
            options = $labels
            html = $html
            messageId = $mid
            selected = @()
            done = $false
        }
    }

    Save-TgQuestionBatch ([pscustomobject]@{
        batchId = $batchId
        sessionId = $payload.session_id
        project = $project
        created = (Get-Date).ToString("o")
        questions = $batchQuestions
    })

    $reason = "El usuario está en Telegram y no puede contestar este diálogo en la PC. " +
              "Ya se le enviaron las preguntas con botones. Termina el turno ahora, sin hacer nada más, " +
              "con una sola línea: «📨 Te mandé la pregunta a Telegram, toca una opción.» " +
              "Sus respuestas llegarán como un nuevo mensaje de Telegram y ahí continúas."
    $out = @{
        hookSpecificOutput = @{
            hookEventName = "PreToolUse"
            permissionDecision = "deny"
            permissionDecisionReason = $reason
        }
    }
    [Console]::OutputEncoding = [Text.Encoding]::UTF8
    [Console]::Out.Write(($out | ConvertTo-Json -Depth 5 -Compress))
} catch {}

exit 0
