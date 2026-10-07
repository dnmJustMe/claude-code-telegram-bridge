$ErrorActionPreference = "SilentlyContinue"
. (Join-Path $PSScriptRoot "telegram-bridge-lib.ps1")

function Escape-Html {
    param([string]$Text)
    if (-not $Text) { return "" }
    return ($Text -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;')
}

function Format-ToolRequest {
    param($ToolUseBlock)

    $name = $ToolUseBlock.name
    $toolInput = $ToolUseBlock.input

    if ($name -eq "AskUserQuestion" -and $toolInput.questions) {
        $parts = @()
        foreach ($q in $toolInput.questions) {
            $lines = @()
            if ($q.header) {
                $lines += "❓ <b>$(Escape-Html $q.header)</b>"
            }
            $lines += Escape-Html $q.question
            if ($q.options) {
                foreach ($opt in $q.options) {
                    $label = Escape-Html $opt.label
                    $desc = Escape-Html $opt.description
                    if ($desc) {
                        $lines += "• <b>$label</b>: $desc"
                    } else {
                        $lines += "• <b>$label</b>"
                    }
                }
            }
            $parts += ($lines -join "`n")
        }
        return ($parts -join "`n`n")
    }

    if ($name -eq "Bash" -and $toolInput.command) {
        $cmd = Escape-Html $toolInput.command
        $desc = Escape-Html $toolInput.description
        $out = "🔧 <b>Bash</b>: <code>$cmd</code>"
        if ($desc) { $out += "`n$desc" }
        return $out
    }

    if (($name -eq "Edit" -or $name -eq "Write") -and $toolInput.file_path) {
        return "📝 <b>$name</b>: <code>$(Escape-Html $toolInput.file_path)</code>"
    }

    if ($name) {
        $inputJson = ($toolInput | ConvertTo-Json -Compress -Depth 4)
        if ($inputJson.Length -gt 300) { $inputJson = $inputJson.Substring(0, 300) + "..." }
        return "🔧 <b>$(Escape-Html $name)</b>`n<code>$(Escape-Html $inputJson)</code>"
    }

    return $null
}

$body = $null

try {
    $payload = Read-HookPayload
    $msg = $payload.message
    $cwd = $payload.cwd
    $transcriptPath = $payload.transcript_path
    $sessionId = $payload.session_id

    if ($sessionId) {
        try { Update-TgSession -SessionId $sessionId -Cwd $cwd } catch {}
    }

    $projectName = "sesion"
    if ($cwd) {
        $projectName = Split-Path -Path $cwd -Leaf
    }

    $detail = $null
    if ($transcriptPath -and (Test-Path $transcriptPath)) {
        $lines = Get-Content -LiteralPath $transcriptPath -Encoding UTF8
        for ($i = $lines.Count - 1; $i -ge 0; $i--) {
            $line = $lines[$i]
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            $entry = $null
            try { $entry = $line | ConvertFrom-Json } catch { continue }
            if ($entry.type -eq "assistant" -and $entry.message.content) {
                $toolUse = $entry.message.content | Where-Object { $_.type -eq "tool_use" } | Select-Object -Last 1
                if ($toolUse) {
                    $detail = Format-ToolRequest -ToolUseBlock $toolUse
                }
                break
            }
        }
    }

    if (-not $detail) {
        if (-not $msg) { $msg = "Claude necesita tu atención." }
        $detail = Escape-Html $msg
    }

    $tag = if ($sessionId) { "  " + (Get-TgSessionTag $sessionId) } else { "" }
    $badge = Get-TgSessionBadge $sessionId
    $body = "$badge <b>$(Escape-Html $projectName)</b> · ⏳ necesita tu aprobación$tag`n`n$detail"
} catch {
    $body = "⏳ Claude necesita tu aprobación."
}

# Send-TgMessage recorta al límite de Telegram (4096) y cae al endpoint PHP si el bot falla.
try { Send-TgMessage -Text $body -Html -ReplyMarkup (Get-TgReplyMarkup $sessionId) | Out-Null } catch {}
