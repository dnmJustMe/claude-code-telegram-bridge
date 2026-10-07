<#
.SYNOPSIS
    Desinstala claude-code-telegram-bridge.

.DESCRIPTION
    Detiene y elimina la tarea programada, quita los hooks del puente de
    ~/.claude/settings.json (con respaldo previo) y borra los scripts de
    ~/.claude/hooks. Con -Purge borra también ~/.claude/telegram-bridge
    (config con el token, registro de sesiones y logs).

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\uninstall.ps1
    powershell -ExecutionPolicy Bypass -File .\uninstall.ps1 -Purge
#>
param([switch]$Purge)

$ErrorActionPreference = "Stop"
$ClaudeDir = Join-Path $env:USERPROFILE ".claude"
$HooksDir = Join-Path $ClaudeDir "hooks"
$BridgeDir = Join-Path $ClaudeDir "telegram-bridge"
$SettingsPath = Join-Path $ClaudeDir "settings.json"
$TaskName = "Claude Telegram Bridge"

Write-Host "Deteniendo el puente..." -ForegroundColor Cyan
if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
}
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -like "*telegram-bridge.ps1*" -or $_.CommandLine -like "*telegram-inbox-wait.ps1*" } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

Write-Host "Quitando hooks de settings.json..." -ForegroundColor Cyan
if (Test-Path -LiteralPath $SettingsPath) {
    $backup = "$SettingsPath.bak-$(Get-Date -Format yyyyMMdd-HHmmss)"
    Copy-Item $SettingsPath $backup
    Write-Host "Respaldo: $backup"
    $settings = Get-Content -LiteralPath $SettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($settings.PSObject.Properties["hooks"] -and $settings.hooks) {
        foreach ($prop in @($settings.hooks.PSObject.Properties)) {
            $groups = @()
            foreach ($g in @($prop.Value)) {
                $kept = @($g.hooks | Where-Object { $_.command -notlike "*\.claude\hooks\telegram-*" })
                if ($kept.Count -gt 0) { $g.hooks = $kept; $groups += $g }
            }
            if ($groups.Count -gt 0) { $settings.hooks.($prop.Name) = $groups }
            else { $settings.hooks.PSObject.Properties.Remove($prop.Name) }
        }
    }
    [IO.File]::WriteAllText($SettingsPath, ($settings | ConvertTo-Json -Depth 20), (New-Object Text.UTF8Encoding $false))
}

Write-Host "Borrando scripts de hooks..." -ForegroundColor Cyan
Get-ChildItem -LiteralPath $HooksDir -Filter "telegram-*.ps1" -ErrorAction SilentlyContinue | Remove-Item -Force

if ($Purge) {
    if (Test-Path -LiteralPath $BridgeDir) { Remove-Item -LiteralPath $BridgeDir -Recurse -Force }
    Write-Host "Borrado $BridgeDir (config, sesiones y logs)."
} else {
    Write-Host "Se conservó $BridgeDir (config con el token y logs). Usa -Purge para borrarlo."
}
Write-Host "Desinstalado." -ForegroundColor Green
