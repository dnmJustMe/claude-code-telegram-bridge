# Configura el perfil del bot del puente: descripción, comandos y foto.
# Se puede volver a correr cuando cambien los textos.
$ErrorActionPreference = "Stop"
. (Join-Path $env:USERPROFILE ".claude\hooks\telegram-bridge-lib.ps1")

$description = @"
🤖 Puente entre Telegram y Claude Code en tu PC.

• Te avisa cuando una sesión de Claude termina o necesita tu aprobación.
• Responde a un aviso (o usa /s id mensaje) y tu mensaje sigue esa sesión, en su proyecto.
• /sesiones muestra las sesiones recientes y su estado.

Solo atiende a su dueño y necesita la PC encendida.
"@

$shortDescription = "Avisos de Claude Code y control de sus sesiones desde Telegram, en tu PC."

$commands = @(
    @{ command = "sesiones"; description = "Sesiones recientes y su estado" },
    @{ command = "s"; description = "Enviar a una sesión: /s id mensaje" },
    @{ command = "parar"; description = "Detener lo que corre en una sesión: /parar id" },
    @{ command = "forzar"; description = "Liberar una sesión trabada: /forzar id" },
    @{ command = "ayuda"; description = "Cómo usar el bot" }
)

$r = Invoke-TgApi -Method "setMyDescription" -Params @{ description = $description.Trim() }
"descripcion: $($r.ok) $($r.description)"
$r = Invoke-TgApi -Method "setMyShortDescription" -Params @{ short_description = $shortDescription }
"descripcion corta: $($r.ok) $($r.description)"
$r = Invoke-TgApi -Method "setMyCommands" -Params @{ commands = $commands }
"comandos: $($r.ok) $($r.description)"

# Foto de perfil (multipart): InputProfilePhotoStatic con el JPG adjunto.
$cfg = Get-TgConfig
$avatar = Join-Path $script:TgBridgeDir "avatar.jpg"
# PS 5.1 quita las comillas al pasar argumentos a un .exe: van escapadas con \".
$photoJson = '{\"type\":\"static\",\"photo\":\"attach://avatar\"}'
$out = & curl.exe -s -X POST "https://api.telegram.org/bot$($cfg.botToken)/setMyProfilePhoto" `
    -F "photo=$photoJson" -F "avatar=@$avatar;type=image/jpeg"
"foto: $out"
