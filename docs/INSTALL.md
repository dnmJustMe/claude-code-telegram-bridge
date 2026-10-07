# Instalación paso a paso

Esta guía cubre la instalación con el instalador (recomendada), la instalación manual y cómo verificar que todo funciona.

## 0. Antes de empezar

Necesitas:

- Windows 10/11 con **Windows PowerShell 5.1**. Compruébalo con `$PSVersionTable.PSVersion`.
- **Claude Code** instalado: la extensión de VS Code, la CLI o las dos. Para ejecutar mensajes en sesiones cerradas hace falta la CLI `claude` en el PATH. Compruébalo con `claude --version`.
- Una cuenta de **Telegram**.

## 1. Crear el bot

1. En Telegram, abre [@BotFather](https://t.me/BotFather) y envía `/newbot`.
2. Elige un nombre visible (por ejemplo *Claude Assistant*) y un usuario que termine en `bot` (por ejemplo `mi_claude_bot`).
3. BotFather te responde con el **token** (`123456789:AAH...`). Guárdalo: es la contraseña del bot.

> Usa un bot **dedicado**. El puente lee los mensajes con `getUpdates`, que no funciona si el bot tiene un webhook, y dos programas no pueden leer el mismo bot a la vez. El instalador lo comprueba.

## 2. Instalar con el instalador

```powershell
git clone https://github.com/<tu-usuario>/claude-code-telegram-bridge.git
cd claude-code-telegram-bridge
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

El instalador te guía:

| Paso | Qué pasa |
|---|---|
| 1. Requisitos | Revisa PowerShell, `claude` y `curl.exe`. |
| 2. Bot | Pega el token. Valida el bot con `getMe` y que no tenga webhook. |
| 3. Tu ID | Abre el enlace del bot, envíale `/start` y presiona Enter. El instalador detecta tu ID y te pide confirmarlo. |
| 4. Permisos | Eliges el modo para lo que se ejecute desde Telegram (ver abajo). |
| 5. Archivos | Copia `hooks/` a `~/.claude/hooks` y `bridge/` a `~/.claude/telegram-bridge`, y crea `config.json`. |
| 6. Hooks | Respalda `~/.claude/settings.json` y agrega los hooks. Si reinstalas, reemplaza las entradas en vez de duplicarlas. |
| 7. Bot y tarea | Configura descripción, comandos y foto del bot, registra la tarea programada **Claude Telegram Bridge** y te manda un mensaje de prueba. |

**Modos de permisos**

| Modo | Lo que Claude puede hacer en turnos pedidos desde Telegram |
|---|---|
| `acceptEdits` (recomendado) | Edita archivos sin preguntar. Lo demás que requiera aprobación se bloquea, y Claude te lo cuenta. |
| `bypassPermissions` | Todo, sin preguntar. Úsalo solo si tu cuenta de Telegram tiene verificación en dos pasos. |
| `default` | Todo lo que requiera aprobación se bloquea. |

Parámetros para instalar sin preguntas:

```powershell
.\install.ps1 -BotToken "123:ABC" -UserId 123456789 -PermissionMode acceptEdits
.\install.ps1 -SkipBotProfile   # no tocar descripción, comandos ni foto del bot
.\install.ps1 -SkipTask         # no registrar la tarea programada
```

## 3. Verificar

1. **Mensaje de prueba:** al terminar la instalación te llega "✅ claude-code-telegram-bridge instalado".
2. **Puente corriendo:**
   ```powershell
   Get-ScheduledTask -TaskName "Claude Telegram Bridge" | Select-Object State   # Running
   Get-Content "$env:USERPROFILE\.claude\telegram-bridge\bridge.log" -Tail 5
   ```
3. **Aviso de fin de turno:** abre o reinicia una sesión de Claude Code y pídele cualquier cosa. Al terminar te llega un aviso con color, proyecto, `#s_xxxxxx` y el botón **↩️ Responder**.
4. **Entrega en vivo:** responde a ese aviso desde Telegram. El bot contesta "▶️ Enviado a … a la sesión abierta" y en VS Code aparece tu mensaje y la respuesta de Claude.
5. **Botones:** desde Telegram, pídele a la sesión "hazme una pregunta con opciones para probar los botones". Te llega con botones y, al tocar uno, la respuesta vuelve a la sesión.

> Las sesiones que ya estaban abiertas toman los hooks nuevos en su siguiente turno. Una sesión empieza a escuchar mensajes de Telegram **después** de su primer turno.

## 4. Instalación manual (sin el instalador)

1. Copia los archivos:
   ```powershell
   $c = "$env:USERPROFILE\.claude"
   New-Item -ItemType Directory -Force "$c\hooks", "$c\telegram-bridge" | Out-Null
   Copy-Item .\hooks\*.ps1 "$c\hooks"
   Copy-Item .\bridge\*.ps1, .\assets\avatar.jpg "$c\telegram-bridge"
   Copy-Item .\config.example.json "$c\telegram-bridge\config.json"
   ```
2. Edita `~/.claude/telegram-bridge/config.json` con tu token y tu ID. Tu ID te lo da [@userinfobot](https://t.me/userinfobot).
3. Agrega los hooks a `~/.claude/settings.json`. Reemplaza `USUARIO` por tu usuario de Windows y fusiona con los hooks que ya tengas:

   ```json
   {
     "hooks": {
       "Stop": [
         {
           "hooks": [
             { "type": "command", "command": "powershell -NoProfile -ExecutionPolicy Bypass -File \"C:\\Users\\USUARIO\\.claude\\hooks\\telegram-notify.ps1\"", "timeout": 15 },
             { "type": "command", "command": "powershell -NoProfile -ExecutionPolicy Bypass -File \"C:\\Users\\USUARIO\\.claude\\hooks\\telegram-inbox-wait.ps1\"", "asyncRewake": true, "timeout": 86400 }
           ]
         }
       ],
       "Notification": [
         { "hooks": [ { "type": "command", "command": "powershell -NoProfile -ExecutionPolicy Bypass -File \"C:\\Users\\USUARIO\\.claude\\hooks\\telegram-notify-permission.ps1\"", "timeout": 15 } ] }
       ],
       "UserPromptSubmit": [
         { "hooks": [ { "type": "command", "command": "powershell -NoProfile -ExecutionPolicy Bypass -File \"C:\\Users\\USUARIO\\.claude\\hooks\\telegram-session-state.ps1\" -State busy", "timeout": 10 } ] }
       ],
       "SessionEnd": [
         { "hooks": [ { "type": "command", "command": "powershell -NoProfile -ExecutionPolicy Bypass -File \"C:\\Users\\USUARIO\\.claude\\hooks\\telegram-session-state.ps1\" -State idle", "timeout": 10 } ] }
       ],
       "PermissionRequest": [
         { "hooks": [ { "type": "command", "command": "powershell -NoProfile -ExecutionPolicy Bypass -File \"C:\\Users\\USUARIO\\.claude\\hooks\\telegram-permission-auto.ps1\"", "timeout": 10 } ] }
       ],
       "PreToolUse": [
         { "matcher": "AskUserQuestion", "hooks": [ { "type": "command", "command": "powershell -NoProfile -ExecutionPolicy Bypass -File \"C:\\Users\\USUARIO\\.claude\\hooks\\telegram-ask-to-buttons.ps1\"", "timeout": 30 } ] }
       ]
     }
   }
   ```
4. Configura el bot y registra la tarea:
   ```powershell
   & "$env:USERPROFILE\.claude\telegram-bridge\setup-bot.ps1"
   & "$env:USERPROFILE\.claude\telegram-bridge\install-bridge.ps1"
   ```

## 5. Actualizar

Descarga los cambios (`git pull`) y vuelve a correr `install.ps1`. Reemplaza los scripts y las entradas de hooks sin duplicarlas, y respalda antes `config.json` y `settings.json`.

## 6. Desinstalar

```powershell
powershell -ExecutionPolicy Bypass -File .\uninstall.ps1          # conserva config y logs
powershell -ExecutionPolicy Bypass -File .\uninstall.ps1 -Purge   # borra todo
```

Detiene y elimina la tarea programada, quita del `settings.json` solo los hooks del puente (con respaldo previo) y borra los scripts.

## Notas

- **Codificación:** los `.ps1` deben quedar en **UTF-8 con BOM**. Windows PowerShell 5.1 lee los archivos sin BOM como ANSI y rompe acentos y emojis. Si editas un script, guárdalo con BOM (en VS Code: *Save with Encoding → UTF-8 with BOM*).
- **Plugin oficial de Telegram de Claude Code:** si lo tienes activado con el mismo bot, competirá por los mensajes. Usa bots distintos o desactiva el plugin.
