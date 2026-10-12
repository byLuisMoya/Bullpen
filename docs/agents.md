# Agentes

Bullpen trae estos perfiles: Claude Code, Codex, Gemini CLI, OpenCode, Cursor CLI, GitHub Copilot
CLI, Aider, Goose y Amp. Solo Claude Code y Codex dan estado preciso (hooks); el resto se sigue
por el proceso en primer plano y la actividad de la terminal.

## Cómo reciben el prompt inicial

| Forma | Agentes | Qué hace Bullpen |
|---|---|---|
| Argumento | Claude Code, Codex, Cursor CLI | `agente "prompt"` |
| Opción | Gemini CLI (`-i`), OpenCode (`--prompt`) | `agente -i "prompt"` |
| Escrito | Copilot, Aider, Goose, Amp | Arranca el agente, espera a que se quede quieto y escribe el prompt |

Al escribir, si el programa activó el pegado entre corchetes (bracketed paste) se envía tal cual
con sus saltos de línea; si no, en una sola línea para que un salto no lo envíe a medias.

## Agentes propios

Un fichero `.toml` por agente en `~/Library/Application Support/Bullpen/agents/custom/`.
Un `id` igual al de un agente incluido lo sustituye.

```toml
id = "mi-agente"
name = "Mi agente"
command = "/opt/homebrew/bin/mi-agente --rapido"
prompt = "flag:--task"      # "positional", "flag:<opción>" o "type"
model_flag = "--model"       # opcional
```
