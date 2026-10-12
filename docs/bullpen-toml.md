# `.bullpen.toml`

Fichero opcional en la raíz del repo. Se versiona con el código, así que todo el equipo comparte
cómo se prepara, se ejecuta y se comprueba cada worktree (PLAN §6.2 y §6.5).

```toml
[setup]
copy  = [".env", ".env.local"]      # ficheros ignorados que se copian del checkout principal
clone = ["node_modules", ".venv"]   # carpetas clonadas con APFS: instantáneo y sin ocupar disco extra
run   = ["pnpm install --frozen-lockfile"]   # se ejecuta en la terminal del worktree antes del agente

[env]                                # variables para todas las terminales del worktree
PORT = "{{port:web}}"                # puerto libre reservado para este worktree
API_URL = "http://localhost:{{port:api}}"
DATABASE_URL = "postgres://localhost/app_{{worktree.slug}}"

[teardown]
run = ["dropdb --if-exists app_{{worktree.slug}}"]   # al eliminar el worktree

[verify]
run = ["pnpm typecheck", "pnpm test --run"]          # botón «Verificar» en Cambios

[prompt]
default = """
Rama {{worktree.branch}} (base {{worktree.baseRef}}). Lee CLAUDE.md antes de empezar.
"""

[prompt.agents.codex]
append = "Commits pequeños."
```

## Comportamiento

- Si el fichero tiene un error, la app lo muestra al crear el worktree y no crea nada.
- `copy` y `clone` solo copian lo que existe en el checkout principal y aún no está en el worktree.
- `run` de `[setup]` va antes del agente: si falla, el agente no arranca y te quedas en una shell en
  el worktree con el error a la vista.
- Los puertos `{{port:nombre}}` son libres al crearse y distintos para cada worktree activo
  (rango 4100–4999). También quedan en `BULLPEN_PORT_<NOMBRE>`.
- El prompt se compone así: global (Ajustes) → `[prompt]` de este fichero (+ `append` del agente)
  → prompt del proyecto en la app → tarea.

## Variables

`{{project.name}}`, `{{worktree.branch}}`, `{{worktree.slug}}`, `{{worktree.baseRef}}`,
`{{worktree.path}}`, `{{task.description}}`, `{{user.name}}` y, en `[env]`, `{{port:nombre}}`.
Una variable desconocida es un error: nunca se sustituye en silencio por un texto vacío.

## TOML admitido

Tablas `[a]` y `[a.b]`, cadenas `"…"`, `'…'`, `"""…"""` y `'''…'''`, enteros, booleanos, listas
(en una o varias líneas) y comentarios `#`. Las tablas en línea `{…}` y `[[listas de tablas]]` dan
error en lugar de leerse mal.
