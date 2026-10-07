# Registra (o actualiza) la tarea programada que arranca el puente de Telegram
# al iniciar sesión en Windows, oculto, y lo reinicia si se cae.
#   Desinstalar: Unregister-ScheduledTask -TaskName "Claude Telegram Bridge" -Confirm:$false
$ErrorActionPreference = "Stop"

$taskName = "Claude Telegram Bridge"
$script = Join-Path $env:USERPROFILE ".claude\telegram-bridge\telegram-bridge.ps1"
$user = "$env:USERDOMAIN\$env:USERNAME"

$action = New-ScheduledTaskAction -Execute "powershell.exe" `
    -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$script`""
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) `
    -MultipleInstances IgnoreNew -StartWhenAvailable
$principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited

Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings `
    -Principal $principal -Description "Puente Telegram -> Claude Code (claude-code-telegram-bridge)" -Force | Out-Null

Start-ScheduledTask -TaskName $taskName
"Tarea '$taskName' registrada e iniciada."
