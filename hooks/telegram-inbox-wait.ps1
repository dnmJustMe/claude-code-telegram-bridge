# Hook Stop con asyncRewake: tras cada turno se queda escuchando en segundo
# plano el buzón de la sesión (inbox\<session_id>\). Cuando el puente de
# Telegram deja un mensaje, lo toma, lo escribe en stderr y sale con código 2:
# Claude Code despierta la sesión abierta (aunque esté inactiva) y Claude lo
# procesa ahí mismo, a la vista en VS Code.
#
# Solo un hook escucha por sesión: cada Stop arranca uno nuevo que reemplaza al
# anterior (waiter.json lleva el guid del vigente). También se retira si muere
# el claude.exe de su sesión o si SessionEnd borra waiter.json.

$ErrorActionPreference = "SilentlyContinue"
. (Join-Path $PSScriptRoot "telegram-bridge-lib.ps1")

# Las ejecuciones de respaldo (claude -p del puente) no escuchan: terminan solas.
if ($env:CLAUDE_TG_REMOTE -eq "1") { exit 0 }

$payload = Read-HookPayload
if (-not $payload -or -not $payload.session_id) { exit 0 }
$sessionId = $payload.session_id

$dir = Get-TgInboxDir $sessionId
if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
$waiterPath = Join-Path $dir "waiter.json"
$guid = [guid]::NewGuid().ToString()

# claude.exe dueño de esta sesión: el primer ancestro que se llame claude*.
$claudePid = $null
$p = $PID
for ($i = 0; $i -lt 6 -and $p; $i++) {
    $w = Get-CimInstance Win32_Process -Filter "ProcessId=$p"
    if (-not $w) { break }
    if ($i -gt 0 -and $w.Name -like "claude*") { $claudePid = [int]$w.ProcessId; break }
    $p = $w.ParentProcessId
}

function Write-Waiter {
    $data = [pscustomobject]@{
        guid = $guid
        pid = $PID
        claudePid = $claudePid
        heartbeat = (Get-Date).ToString("o")
    }
    [IO.File]::WriteAllText($waiterPath, ($data | ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding $false))
}

function Test-StillMine {
    if (-not (Test-Path -LiteralPath $waiterPath)) { return $false }
    try { $w = Get-Content -LiteralPath $waiterPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $true }
    return ($w.guid -eq $guid)
}

Write-Waiter
$lastBeat = Get-Date
# Un poco antes del timeout del hook (86400 s en settings.json).
$deadline = (Get-Date).AddHours(23.5)

while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 1500

    if (-not (Test-StillMine)) { exit 0 }
    if ($claudePid -and -not (Get-Process -Id $claudePid -ErrorAction SilentlyContinue)) {
        Remove-Item -LiteralPath $waiterPath -Force
        exit 0
    }

    $taken = @()
    foreach ($f in @(Get-ChildItem -LiteralPath $dir -Filter "msg-*.txt" | Sort-Object Name)) {
        $dest = [IO.Path]::ChangeExtension($f.FullName, ".taken")
        try {
            [IO.File]::Move($f.FullName, $dest)
            $taken += [IO.File]::ReadAllText($dest, [Text.Encoding]::UTF8)
        } catch {}
    }

    if ($taken.Count -gt 0) {
        # Nadie escucha hasta el próximo Stop; el puente encola mientras tanto.
        Remove-Item -LiteralPath $waiterPath -Force
        try { Update-TgSession -SessionId $sessionId -Busy $true -RemoteTurn $true | Out-Null } catch {}

        $text = ($taken | ForEach-Object { $_.Trim() }) -join "`n`n---`n`n"
        # VS Code no muestra este texto como mensaje del usuario, así que se le
        # pide a Claude que lo cite al inicio de su respuesta (el hook de aviso
        # quita la cita antes de mandarla a Telegram).
        $quote = "> 📱 **Telegram:** " + (($text -split "\r?\n") -join "`n> ")
        $intro = "📱 Mensaje del usuario enviado desde Telegram (vía el puente de Claude Code). " +
                 "Trátalo exactamente como si lo hubiera escrito aquí y respóndelo; " +
                 "tu respuesta final le llegará a Telegram por el hook de aviso. " +
                 "Para que el usuario vea su mensaje en VS Code, EMPIEZA tu respuesta copiando " +
                 "literalmente este bloque de cita y luego una línea en blanco:"
        [Console]::OutputEncoding = [Text.Encoding]::UTF8
        [Console]::Error.WriteLine("$intro`n`n$quote`n`nMensaje:`n$text")
        exit 2
    }

    if (((Get-Date) - $lastBeat).TotalSeconds -ge 5) {
        Write-Waiter
        $lastBeat = Get-Date
    }
}

if (Test-StillMine) { Remove-Item -LiteralPath $waiterPath -Force }
exit 0
