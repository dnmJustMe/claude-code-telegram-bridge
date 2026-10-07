# Solución de problemas

Lo primero siempre es mirar el log del puente:

```powershell
Get-Content "$env:USERPROFILE\.claude\telegram-bridge\bridge.log" -Tail 30
```

## No me llegan avisos

1. ¿Le enviaste `/start` al bot? Un bot no puede escribirte hasta que tú le escribas primero.
2. Prueba el envío directo:
   ```powershell
   . "$env:USERPROFILE\.claude\hooks\telegram-bridge-lib.ps1"
   Send-TgMessage -Text "prueba"
   ```
   Si devuelve un número (`message_id`), el bot funciona y el problema está en el hook.
3. Revisa que `~/.claude/settings.json` tenga el hook `Stop` y que la ruta al script exista.
4. Las sesiones que ya estaban abiertas toman los hooks en su siguiente turno.

## El bot no responde a mis mensajes

1. ¿Está corriendo el puente?
   ```powershell
   Get-ScheduledTask -TaskName "Claude Telegram Bridge" | Select-Object State
   Start-ScheduledTask -TaskName "Claude Telegram Bridge"
   ```
2. Si el log dice `getUpdates falló: 409`, otro programa está leyendo el mismo bot: el plugin oficial de Telegram, otra copia del puente o un webhook. Usa un bot dedicado y comprueba que no tenga webhook (`getWebhookInfo`).
3. Si el log dice `Ignorado mensaje de from=…`, ese usuario no es `allowedUserId`.

## Mi mensaje se ejecutó "en segundo plano" en vez de en VS Code

La sesión no tenía un oyente activo. Las causas posibles:

- La sesión todavía no había terminado ningún turno desde que se abrió o se instaló el puente.
- La sesión estaba cerrada.
- La versión de Claude Code no soporta `asyncRewake`. Actualiza la extensión o la CLI.

Comprueba el oyente:

```powershell
Get-ChildItem "$env:USERPROFILE\.claude\telegram-bridge\inbox\*\waiter.json" | ForEach-Object { Get-Content $_ }
```

`heartbeat` debe tener menos de 20 s.

## "En cola… la sesión está trabajando" y nunca se envía

La sesión quedó marcada como ocupada, por ejemplo porque un turno se interrumpió con Esc (en ese caso `Stop` no se ejecuta). Usa `/forzar id`. De todos modos se libera sola tras `busyStaleMinutes`.

## Acentos o emojis rotos (Ã©, ðŸ...)

Un `.ps1` quedó guardado sin BOM. Vuelve a guardarlo como **UTF-8 con BOM**, o reinstala con `install.ps1`.

## Falló una ejecución en segundo plano

El bot te manda el error. El detalle completo está en `~/.claude/telegram-bridge/jobs/<fecha>_<id>/err.txt` y `out.txt`. Si aparece *"No conversation found"*, la sesión se abrió desde otra carpeta: `claude --resume` busca la sesión según la carpeta del proyecto.

## Quiero empezar de cero

```powershell
.\uninstall.ps1 -Purge
.\install.ps1
```
