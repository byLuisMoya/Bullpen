# Bullpen — plan maestro de una app nativa macOS para orquestar agentes de código en worktrees

> Nombre: **Bullpen** (prefijo de módulos `BP`, CLI `bp`).
> Fecha del plan: 2026-10-12 · Revisado: 2026-10-12 (decisiones de Luis, ver §20) · Autor: Luis + Claude
> **Open source** (licencia propuesta: MIT, ver §14.1).

---

## 0. Resumen en 30 segundos

Una app **100 % nativa de macOS** (Swift + SwiftUI/AppKit, binario **Universal** arm64 + x86_64) que hace lo que hace Orca —crear worktrees de git y lanzar en cada uno un agente de código (Claude Code, Codex, Gemini CLI, OpenCode, Cursor CLI, Aider, modelos locales…)— pero:

1. **Mucho más ligera y estable** que una app Electron: sin Chromium, terminal nativa con Metal, un único daemon de sesiones versionado.
2. **Estado de agente fiable**: detección en capas (hooks oficiales de cada CLI → secuencias OSC → heurística de proceso/salida), con una máquina de estados explícita. Es el punto donde Orca más falla según sus issues.
3. **"El Edificio"**: **cada proyecto es una oficina 2D** y **cada worktree una persona** en su mesa; las oficinas se apilan como plantas. De un vistazo: quién trabaja, quién espera permiso, quién terminó y quién duerme. Sin worktrees, la oficina está apagada.
4. **Resuelve los dolores reales de los usuarios de Orca**: recursos compartidos entre worktrees (puertos, BBDD), conflictos semánticos entre ramas, coste/límites de uso, cuello de botella de revisión, notificaciones que se acumulan, limpieza segura de worktrees y falta de un registro durable de lo que hizo cada agente.

---

## 1. Investigación: qué es Orca y qué se le critica

### 1.1 Qué ofrece Orca hoy (v1.4.223 instalada en este Mac)

Orca (stablyai/orca, MIT, Electron) es un "ADE" (Agent Development Environment):

| Área | Funcionalidad |
|---|---|
| Worktrees | Un worktree por tarea/agente, worktrees hijos, base ref por repo, worktrees por SSH |
| Agentes | Cualquier CLI de terminal (Claude Code, Codex, OpenCode, Cursor CLI, Pi, Devin…), cuentas múltiples, selector de cuentas, uso y reset de rate limits |
| Fan-out | Un prompt → varios agentes → comparar resultados |
| Terminal | Splits infinitos, WebGL, scrollback que sobrevive reinicios, daemon de terminales |
| Revisión | Diffs con anotaciones por línea que se reenvían al agente, PRs, CI, preview de markdown/PDF |
| Editor | Editor basado en VS Code (Monaco), quick open, drag & drop de imágenes |
| Navegador | Pestañas Chromium, "Design Mode" (manda HTML/CSS/captura de un elemento al prompt), perfiles |
| Integraciones | GitHub, Linear, automations programadas, skills |
| Orquestación | Runs, mailbox entre agentes, tasks, dispatch, workers supervisados, decision gates |
| Otros | CLI `orca` muy completo (lo usan los propios agentes), computer use, emulador iOS, app móvil, `orca serve` headless |

### 1.2 Críticas de reviews (vibecodinghub, apidog, braindetox, besthub)

- **No dice qué diff es correcto** en el fan-out: multiplica la salida pero no la capacidad de juicio → la gente acaba mergeando "el diff más bonito".
- **El cuello de botella se desplaza a la revisión**; las anotaciones hacen la revisión más cómoda pero no reducen su volumen.
- **Worktrees solo aíslan ficheros**: puertos de dev server, BBDD locales, cachés y cuotas de APIs siguen compartidos → fallos confusos.
- **Conflictos semánticos silenciosos**: dos ramas que mergean limpias y rompen en runtime.
- **Trabajo duplicado** (dos agentes arreglando lo mismo) = doble gasto y doble revisión.
- **Se llega antes a los límites** de suscripción.
- **Sin registro durable**: "los prompts no son un registro"; un compañero no puede ver qué hicieron los agentes.
- **Pensado para un solo operador**, mal encaje cuando otra persona necesita visibilidad.
- **Producto que cambia cada día**, estabilidad "beta".
- Un portátil sufre con builds en paralelo.

### 1.3 Issues reales en GitHub (muestra relevante)

| Problema | Ejemplos de issues |
|---|---|
| Memoria / rendimiento | `orca-terminal-daemon` crece a 300–400 MB por proceso y no libera; **las actualizaciones dejan generaciones antiguas del daemon vivas para siempre** (13 comentarios); GPU crece linealmente con pestañas de navegador (~4 GB con 10); renderer crece sin límite con salida de error multilínea; **"macOS M1 Pro se congela y reinicia con dos agentes en paralelo"**; cambiar de pestaña cada vez más lento |
| Estado de agentes | "Killed Claude helpers can still appear Working"; "Dead terminals can remain Working after restart"; "Running indicator misses active agents" (medido sobre ~7k observaciones); `tui-idle` que nunca se cumple o se cumple a los 2 s y se pierde el prompt; automations que dicen `completed` con el agente aún trabajando |
| Notificaciones | No se pueden borrar tras 5 min o reinicio y se apilan por panel; sonido "System" silencioso; notificaciones de worktrees ya borrados; piden silenciar por sesión, personalizar y añadir el icono del proyecto |
| Worktrees | `worktree rm` borra worktrees con terminal viva o PR abierta sin guardia; atajos de navegación que dejan de funcionar con foco en editor; restos de config (Codex trust) tras borrar |
| Petición recurrente | Estados manuales/personalizados en el tablero de agentes; "Status = done ⇒ punto gris, no verde"; filtrar por estado |

### 1.4 Otras referencias del ecosistema

- **Conductor** (Mac, Claude Code/Codex en paralelo con worktrees): UX simple, buena referencia de onboarding.
- **cmux** (terminal nativa macOS sobre libghostty con pestañas verticales y avisos de agente): demuestra que lo nativo + Ghostty da rendimiento brutal.
- **Claude Squad** (TUI), **Vibe Kanban** (tablero), **Pixel Agents** (extensión VS Code con agentes como personajes pixel-art en una oficina): referencia directa para "El Edificio".
- **App de Codex para macOS** (OpenAI, feb 2026): agentes por proyecto con worktrees aislados; competidor directo, pero ligado a un solo proveedor.

**Conclusión**: la oportunidad no es copiar todas las features de Orca, sino hacer **lo esencial nativo, estable y legible**, y atacar los cinco dolores: rendimiento, estado fiable, recursos compartidos, revisión/veredicto y visibilidad.

---

## 2. Principios de producto

1. **Nativo de verdad**: arranca en < 1 s, < 150 MB en reposo con 10 worktrees, sin ventiladores en un Intel de 2019.
2. **El estado nunca miente**: si no estamos seguros, mostramos "desconocido", no "trabajando".
3. **El humano es el recurso escaso**: la app optimiza la atención (qué necesita de mí ahora), no el número de agentes.
4. **Bring your own agent / bring your own key**: no revendemos tokens; todo local, claves en Keychain.
5. **Agente-operable**: todo lo que hace la UI lo puede hacer un agente por CLI/MCP.
6. **No es un IDE**: visor de ficheros de **solo lectura** + terminal integrada. Nada de editor, nada de navegador interno.
7. **Divertido pero útil**: los personajes son información, no decoración.

---

## 3. Plataformas y compatibilidad (M1–M5 e Intel)

| Decisión | Valor | Motivo |
|---|---|---|
| Arquitecturas | **Universal 2** (`arm64` + `x86_64`) | Un solo `.app`; Sparkle sirve el mismo binario |
| Deployment target | **macOS 14 Sonoma** | Soporta Intel desde 2018 (MBP 2018+, iMac 2019+, Mac mini 2018+) y permite `@Observable`, SwiftData/GRDB moderno, `SettingsLink`, mejoras de SwiftUI |
| Lenguaje | Swift 6 (strict concurrency) | Seguridad en hilos para PTYs y watchers |
| GPU | Metal (todas las GPUs soportadas: Apple Silicon, Intel Iris/UHD, AMD) | Terminal y escena de personajes |
| No usar | Neural Engine, MLX, APIs solo-ARM | Intel no los tiene; IA local va vía Ollama/LM Studio (que ya resuelven ambas arquitecturas) |
| Rendimiento Intel | Modo "bajo consumo" automático: personajes a 15 fps o estáticos, terminal sin efectos, throttle de watchers | Intel con iGPU y 8 GB es el peor caso |
| Pruebas | **Solo en local**: este Mac (Apple Silicon) y, en momentos concretos (antes de cada release), un Mac Intel con `make test` y `make bench`. **Ninguna prueba en GitHub** | Validar ambos slices de verdad, no solo compilarlos |

Compilación universal: `ARCHS = arm64 x86_64`, `ONLY_ACTIVE_ARCH = NO` en Release. Dependencias binarias (p. ej. libghostty si se usa) deben distribuirse como XCFramework universal; lo verificamos con `lipo -info` en CI.

---

## 4. Arquitectura

### 4.1 Procesos

```
┌──────────────────────────── Bullpen.app (UI, SwiftUI + AppKit) ───────────────────────────┐
│  Sidebar repos/worktrees · Terminales · Diff/Review · Edificio · Ajustes · Command palette    │
│        │ XPC (async, Codable)                     │ Unix socket JSON-RPC                     │
└────────┼──────────────────────────────────────────┼─────────────────────────────────────────┘
         ▼                                          ▼
┌───────────────────────────┐            ┌─────────────────────────────┐
│ BPSessionDaemon (LaunchAgent│          │ bp  (CLI)  ·  bp mcp (MCP)   │  ← lo usan humanos y agentes
│  propio, ver §4.4)          │          └─────────────────────────────┘
│ - PTYs (forkpty)            │
│ - buffer/scrollback en disco│◄── hooks de agentes (bp hook …) ── Claude Code / Codex / …
│ - StatusEngine              │
│ - proceso-árbol (libproc)   │
│ - versión + handshake       │
└───────────────────────────┘
```

- **App** y **daemon** separados: cerrar o actualizar la app no mata a los agentes.
- **Un solo daemon versionado** (soluciona el bug de Orca de generaciones acumuladas):
  - El daemon expone `protocolVersion` y `buildID`.
  - Al actualizar, la app nueva arranca el daemon nuevo, le pide al viejo un **handoff** de sesiones (pasar file descriptors de los PTY por `SCM_RIGHTS` sobre socket Unix) y el viejo termina. Si el handoff falla, las sesiones quedan en el viejo marcado como "legacy" y se muestra en UI con botón "terminar cuando acaben", **nunca invisible**.
  - Registro de PIDs en SQLite + barrido al arrancar: cualquier proceso huérfano nuestro aparece en "Diagnóstico".
- **CLI `bp`** habla con la app/daemon por socket Unix en `~/Library/Application Support/Bullpen/run/bp.sock` (permisos 0600).

### 4.2 Módulos (Swift Package local, un target por módulo)

| Módulo | Responsabilidad |
|---|---|
| `BPCore` | Modelos de dominio (Repo, Worktree, AgentSession, Task, Run), IDs, errores, logging (`os.Logger`) |
| `BPPersistence` | SQLite con **GRDB** (migraciones, observación reactiva). Nada de Core Data |
| `BPGit` | Wrapper del **CLI de git** (worktree add/remove/list --porcelain, status --porcelain=v2, diff, log, merge-tree). FSEvents para cambios. libgit2 no cubre bien worktrees |
| `BPTerminal` | Vista de terminal. Protocolo `TerminalEngine` con 2 implementaciones: **SwiftTerm** (MVP, puro Swift, universal) y **libghostty** (fase 2, Metal, más rápido) |
| `BPSessionDaemon` | PTY, scrollback persistente (ring buffer + fichero mmap), handoff, árbol de procesos |
| `BPAgents` | Perfiles de agente (declarativos), instalación de hooks, parsers de estado, reanudación de sesiones |
| `BPStatus` | **StatusEngine**: fusiona señales → máquina de estados por sesión |
| `BPProviders` | Clientes de APIs de modelos (Anthropic, OpenAI, Google, OpenRouter, Ollama, LM Studio, endpoint OpenAI-compatible) para funciones internas |
| `BPReview` | Diff viewer nativo, anotaciones, comparador de fan-out, veredictos |
| `BPEnv` | Recursos por worktree: puertos, `.env`, BBDD, scripts de setup/teardown |
| `BPIntegrations` | GitHub (via `gh` o API REST + token), Linear, GitLab más adelante |
| `BPHabitat` | "El Edificio": oficinas por proyecto, personajes 2D (Core Animation), animaciones, bocadillos |
| `BPNotify` | `UNUserNotificationCenter` con identificadores/agrupación, sonidos, dock badge, menú de barra |
| `BPCLI` | Ejecutable `bp` + servidor MCP |
| `BPUI` | Vistas SwiftUI y puentes AppKit (`NSViewRepresentable` para terminal y capas del Edificio) |

### 4.3 Stack y dependencias (mínimas, todas MIT/Apache/BSD)

- UI: SwiftUI + AppKit (NSSplitView, NSToolbar, NSWindow tabs donde SwiftUI se queda corto).
- Terminal: **SwiftTerm** → **libghostty** (evaluar en fase 2).
- Visor de código: **CodeEditSourceEditor** + tree-sitter (resaltado) o **STTextView**, en modo **solo lectura**.
- Markdown: `swift-markdown` + render propio; PDF: PDFKit; imágenes: nativo.
- BBDD: **GRDB**.
- Actualizaciones: **Sparkle 2** (EdDSA, appcast en GitHub Releases; ver §4.5).
- Atajos globales: `KeyboardShortcuts` (sindresorhus).
- Tests: Swift Testing + XCTest UI + snapshot tests (`swift-snapshot-testing`).

### 4.4 Distribución: solo GitHub, sin cuenta de Apple Developer

**Decisión (2026-10-12):** Bullpen se distribuye **únicamente por GitHub Releases**. No hay cuenta de Apple Developer, así que **no hay firma Developer ID ni notarización**, ni Mac App Store, ni Homebrew cask oficial (Homebrew está retirando los casks sin firmar).

**Qué se publica en cada release:**
- `Bullpen-<versión>-universal.zip` (creado con `ditto -c -k --keepParent`, conserva atributos y enlaces de frameworks): app Universal + CLI `bp` dentro del bundle (`Contents/Resources/bin/bp`).
- `appcast.xml` para Sparkle (ver §4.5).
- `SHA256SUMS.txt`.

**Firma sin Developer ID:**
- En local: firma ad-hoc (`codesign -s -`).
- En CI de release: **certificado autofirmado estable** (creado una vez, guardado como secreto del repo). Gatekeeper sigue sin confiar en él, pero da una identidad de código **constante entre versiones**, de modo que macOS no trata cada actualización como una app nueva: el Llavero no vuelve a pedir permiso para las claves guardadas, ni se pierden las aprobaciones de notificaciones o de ítems en segundo plano. Con firma ad-hoc esas aprobaciones se romperían en cada versión.
- Hardened Runtime activado igualmente.

**Primera instalación (documentada en el README):**
1. Descargar el zip de la release y mover `Bullpen.app` a `/Applications`.
2. Abrirla: macOS la bloquea por no estar notarizada → Ajustes del Sistema › Privacidad y seguridad › **"Abrir igualmente"** (en macOS 15+ ya no vale clic derecho › Abrir).
3. Alternativa para quien prefiera terminal: `xattr -dr com.apple.quarantine /Applications/Bullpen.app`.
4. Opcional: `Bullpen › Instalar herramienta de línea de comandos` crea el enlace `/usr/local/bin/bp`.

Solo hay que hacerlo **una vez**: las actualizaciones posteriores llegan por Sparkle y no vuelven a pasar por Gatekeeper (Sparkle descarga sin atributo de cuarentena).

**Componentes que dependen de la firma:**
- Daemon de sesiones: en vez de `SMAppService` (pensado para apps con firma de confianza), la app lanza el daemon como **LaunchAgent propio** (`~/Library/LaunchAgents/com.byluismoya.Bullpen.daemon.plist`) o, como alternativa, como proceso hijo desacoplado (`setsid`) que sobrevive al cierre de la app. Se decide en fase 1.
- Notificaciones, Llavero y WidgetKit funcionan con el certificado autofirmado estable. El widget queda fuera de la v1.

### 4.5 Actualizaciones automáticas (Sparkle 2)

**Por qué Sparkle**: es el estándar en apps de Mac fuera de la App Store, es open source (MIT), funciona **sin Developer ID** (verifica las actualizaciones con su propia firma EdDSA, independiente de Apple) y evita que el usuario repita el paso de Gatekeeper en cada versión.

**Cómo funciona:**

```
 tag v0.3.0 ──► CI (macos-15) ──► build universal ──► firma autofirmada ──► zip
                                                                    │
                       sign_update (clave EdDSA privada, secreto) ◄─┘
                                      │
                    generate_appcast ─┴─► appcast.xml + zip + SHA256SUMS ──► GitHub Release
                                                                                  │
 Bullpen.app ── cada 24 h ── GET …/releases/latest/download/appcast.xml ◄─────────┘
      │  hay versión nueva + firma EdDSA válida
      └─► diálogo "Bullpen 0.3.0 disponible" (notas de la release) ─► descarga ─► instala ─► reinicia
```

**Detalles:**

| Aspecto | Definición |
|---|---|
| Versión | Sparkle **2.10.x** vía Swift Package Manager (XCFramework universal); `Sparkle.framework` se copia a `Contents/Frameworks` en `build-app.sh` y se firma con la app |
| Feed | `SUFeedURL = https://github.com/byLuisMoya/Bullpen/releases/latest/download/appcast.xml` (sin servidor propio; GitHub sirve siempre el de la última release) |
| Firma de updates | Claves EdDSA (ed25519) creadas una vez con `generate_keys`. Pública en `Info.plist` (`SUPublicEDKey`); **privada solo en secretos de GitHub Actions** y copia de seguridad en el Llavero del autor. Si se pierde la privada, los usuarios tendrían que reinstalar a mano |
| Frecuencia | Comprobación al arrancar y cada 24 h (`SUScheduledCheckInterval = 86400`); el usuario puede desactivarla o pedir "Buscar actualizaciones…" en el menú de la app |
| Instalación | Por defecto **pregunta** antes de instalar, con las notas de la release (markdown del release de GitHub convertido a HTML). Opción "descargar e instalar automáticamente" en Ajustes |
| Canales | **Estable** (releases normales) y **beta** (releases marcadas como *pre-release*, con `sparkle:channel="beta"` en el appcast). El usuario elige canal en Ajustes |
| Deltas | No en la v1 (la app pesará pocos MB). Se pueden añadir después con `generate_appcast` |
| Versión mínima | `sparkle:minimumSystemVersion = 14.0` en cada item del appcast |
| Agentes en marcha | Antes de reiniciar, la app avisa de cuántos agentes están trabajando. El daemon **no se reinicia** con la app: la versión nueva se conecta al daemon existente y hace el handoff de sesiones (§4.1) cuando el protocolo cambia. Opción "instalar cuando no haya agentes trabajando" |
| Privacidad | Sin envío de perfil del sistema (`SUEnableSystemProfiling = NO`); la única petición es descargar el appcast de GitHub |
| CLI `bp` | Va dentro del bundle, así que se actualiza junto con la app; el enlace de `/usr/local/bin` sigue apuntando al sitio correcto |

**Flujo de release (manual mínimo):**
1. Subir la versión en `BPCore/Bullpen.swift` y escribir las notas en `CHANGELOG.md`.
2. `git tag v0.3.0 && git push --tags` (con sufijo `-beta.N` para el canal beta).
3. El workflow `release.yml` compila, firma, genera el appcast y publica la release. Nada más.

**Pruebas:** un appcast local servido con `python3 -m http.server` y una versión inflada (`9.9.9`) para probar el diálogo, la instalación y que el daemon sobrevive a la actualización, en arm64 e Intel.

**Cuándo:** se implementa al final de la fase 1, en cuanto haya una primera versión que valga la pena actualizar.

---

## 5. Modelo de dominio

```
Repo ─┬─< Worktree ─┬─< AgentSession ──< StatusEvent
      │             ├─< TerminalSession
      │             ├── EnvAllocation (puertos, db, env)
      │             ├── Character (aspecto, nombre, nivel)
      │             └─< ReviewNote
      └─< Task ──< Run (fan-out: N worktrees) ── Verdict
Provider (API keys) · AgentProfile (cómo lanzar un CLI) · Account (cuentas por agente)
```

Campos clave:

- **Worktree**: `id`, `repoID`, `path`, `branch`, `baseRef` (siempre guardado, también para que `gh pr create --base` funcione), `parentWorktreeID`, `createdBy` (ui/cli/automation), `taskID?`, `pinned`, `archivedAt?`, `prURL?`, `labels`, `manualStatus?`.
- **AgentSession**: `profileID`, `accountID?`, `model?`, `pid`, `ptyID`, `externalSessionID` (ID de sesión de Claude/Codex para `--resume`), `state`, `stateConfidence`, `lastSignalAt`, `tokensIn/out`, `costEstimate`.
- **Run (fan-out)**: `prompt`, `worktreeIDs[]`, `verificationCommand`, `verdict?`.

---

## 6. Gestión de worktrees

### 6.1 Crear

Flujo "Nueva tarea" (⌘N):

1. Repo (o el activo) + **base ref** (por defecto la del repo, configurable; autocompleta ramas/tags remotas).
2. Descripción de la tarea (texto libre, o desde issue GitHub/Linear).
3. Nombre de rama **generado por un modelo barato** a partir de la descripción (`luis/fix-login-timeout`), editable. Prefijo configurable por repo.
4. Agente(s) + modelo + cuenta. Si se eligen N agentes → es un **fan-out Run**.
5. Opciones: worktree hijo de otro, copiar ficheros ignorados (`.env`, `node_modules` vía `clonefile`/APFS clone para que sea instantáneo y no ocupe disco), ejecutar setup script.

Detrás: `git worktree add -b <rama> <ruta> <baseRef>`; ruta por defecto `~/Bullpen/worktrees/<repo>/<rama>` (configurable, fuera del repo para no ensuciar el watcher del IDE).

**Mejora sobre Orca — APFS clones**: copiar `node_modules`, `.venv`, `Pods`, `DerivedData`, `target/` con `clonefile(2)` → worktree listo en segundos sin duplicar disco. Lista configurable por repo con presets por ecosistema.

### 6.2 Bootstrap y recursos por worktree (`BPEnv`)

Fichero opcional en el repo: **`.bullpen.toml`** (versionable, compartible con el equipo):

```toml
[setup]
copy = [".env", ".env.local"]
clone = ["node_modules", ".venv"]        # APFS clone
run = ["pnpm install --frozen-lockfile"]

[env]
PORT = "{{port:web}}"                    # puerto único reservado para este worktree
API_PORT = "{{port:api}}"
DATABASE_URL = "postgres://localhost/app_{{worktree.slug}}"
REDIS_DB = "{{index}}"

[services.web]
command = "pnpm dev --port $PORT"
ready = "http://localhost:$PORT/health"

[teardown]
run = ["dropdb --if-exists app_{{worktree.slug}}"]

[verify]                                 # usado en fan-out y antes de PR
run = ["pnpm typecheck", "pnpm test --run"]
```

- **Asignador de puertos** central (rango configurable, comprueba `bind` real antes de asignar, libera al borrar).
- Las variables se inyectan en el entorno de **todas** las terminales y agentes del worktree.
- Panel "Servicios" por worktree: arrancar/parar dev server, ver logs, abrir la URL en el navegador por defecto.
- Esto ataca directamente la crítica "los worktrees solo aíslan ficheros".

### 6.3 Detección temprana de solapamiento y conflictos

- **Mapa de calor de ficheros tocados**: cada X segundos (y en cada evento de "Stop" del agente) se calcula `git diff --name-only baseRef...HEAD` + cambios sin commitear por worktree.
- Si dos worktrees activos tocan el mismo fichero → aviso amarillo en ambos ("⚠︎ `auth.ts` también lo está editando *fix-login*").
- **Conflicto real**: `git merge-tree --write-tree` entre ramas activas (sin tocar el árbol de trabajo) → aviso rojo con lista de ficheros.
- **Duplicados**: al crear tarea, comparación semántica barata (embeddings locales o modelo pequeño) con tareas abiertas: "Parece igual a *fix-login-timeout* (en curso)".
- Opción de declarar **scope de ficheros** en la tarea; se añade al prompt y se avisa si el agente sale del scope.

### 6.4 Borrar y archivar (con guardias)

- `rm` bloquea si: terminal viva, agente en estado activo, PR abierta, commits sin push, cambios sin commitear. Muestra exactamente qué se perdería; requiere confirmación explícita por cada guardia (o `--force` en CLI).
- **Archivar** (por defecto en lugar de borrar): elimina el worktree del disco pero conserva rama, registro de sesión, diffs y transcript → se puede "resucitar".
- Teardown automático (puertos, BBDD, notificaciones pendientes del worktree **se retiran**, limpieza de trust de Codex/Claude que hayamos añadido).
- **Limpieza sugerida**: worktrees con PR mergeada o sin actividad en N días → bandeja "para limpiar".


### 6.5 Prompt inicial por defecto (por proyecto)

Cada proyecto puede tener un **prompt inicial** que se envía automáticamente al agente **cada vez que se crea un worktree**. Sirve para lo que siempre se repite: leer las convenciones del repo, preparar el entorno, cómo nombrar commits, qué comprobar antes de terminar…

**Niveles** (se combinan en este orden; cada uno se puede desactivar):

| Nivel | Dónde se define | Ejemplo |
|---|---|---|
| 1. Global | Ajustes de la app | "Responde en español. No hagas push sin preguntarme." |
| 2. Proyecto | Ajustes del proyecto (local) **o** `[prompt]` en `.bullpen.toml` (compartido con el equipo, versionado) | "Lee CLAUDE.md, usa pnpm, ejecuta `pnpm typecheck` antes de terminar." |
| 3. Origen de la tarea | Plantilla por integración del proyecto (Linear, GitHub, manual) | "Resuelve el ticket {{ticket.id}}: {{ticket.title}}…" |
| 4. Lo que escribe el usuario | Diálogo "Nueva tarea" | "Ojo, el bug solo pasa en Safari." |

- Si el proyecto tiene prompt local y también en `.bullpen.toml`, el local **gana** (o se concatena; configurable).
- **Variantes por agente** opcionales (p. ej. una para Claude Code y otra para Codex si cada uno necesita instrucciones distintas).
- **Vista previa** del prompt final en el diálogo de creación, editable antes de lanzar; casilla "no enviar prompt inicial" para ese worktree.
- **Plantillas con variables**: `{{project.name}}`, `{{worktree.branch}}`, `{{worktree.baseRef}}`, `{{worktree.path}}`, `{{env.PORT}}`, `{{task.description}}`, `{{ticket.id}}`, `{{ticket.title}}`, `{{ticket.description}}`, `{{ticket.url}}`, `{{ticket.labels}}`, `{{ticket.comments}}`, `{{user.name}}`. Variable desconocida → error visible, nunca se envía vacía en silencio.
- **Cuándo se envía**: cuando el StatusEngine marca el agente como listo para recibir input (no "al cabo de 2 s"), y **después** de que termine el setup del worktree (`[setup]`). Si el setup falla, no se envía y el personaje aparece en estado Error.
- **Cómo se envía**: según el perfil del agente (`prompt_delivery`: argumento, stdin o escrito en el TUI). Prompts largos se pasan como fichero (`.bullpen/prompt.md` dentro del worktree, ignorado por git) y el agente recibe "Lee .bullpen/prompt.md".
- **Contenido externo marcado**: el texto de tickets e issues se envuelve como datos no confiables (`<ticket>…</ticket>` con aviso) para que un ticket no pueda dar órdenes al agente.
- **Fan-out**: todos los agentes del run reciben el mismo prompt compuesto.
- **Historial**: el prompt final queda en el Session Log del worktree.
- CLI: `bp wt create --task "…" [--no-initial-prompt] [--prompt-file x.md]`; `bp project prompt show|edit|preview --repo web-app`.

Ejemplo en `.bullpen.toml`:

```toml
[prompt]
default = """
Estás trabajando en {{project.name}}, rama {{worktree.branch}} (base {{worktree.baseRef}}).
Lee CLAUDE.md antes de empezar. El dev server usa el puerto {{env.PORT}}.
Antes de terminar ejecuta `pnpm typecheck && pnpm test --run`.
"""

[prompt.agents.codex]
append = "Usa commits pequeños con mensajes en inglés."

[prompt.sources.linear]
template = """
Resuelve el ticket {{ticket.id}} — {{ticket.title}} ({{ticket.url}}).
<ticket>
{{ticket.description}}
</ticket>
"""

[prompt.sources.github_issue]
template = "Resuelve el issue #{{ticket.id}}: {{ticket.title}}\n<ticket>{{ticket.description}}</ticket>"
```

---

## 7. Conectar distintos modelos

Dos capas diferenciadas, porque "modelo" significa dos cosas:

### 7.1 Capa A — Agentes CLI (los que trabajan en el worktree)

**Perfiles de agente declarativos** (`~/Library/Application Support/Bullpen/agents/*.toml` + incluidos de serie):

```toml
id = "claude-code"
name = "Claude Code"
detect = ["claude --version"]
launch = "claude {{#model}}--model {{model}}{{/model}} {{#resume}}--resume {{sessionID}}{{/resume}}"
models = ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5", "claude-fable-5-1"]
prompt_delivery = "argv"            # argv | stdin | type-into-tui
status.hooks = "claude-settings"    # instalador de hooks específico
status.title_regex = "^[✳·✻✽✶✢] "   # spinner en el título como señal secundaria
session_id_source = "hook"          # el hook nos da session_id
accounts = "env:CLAUDE_CONFIG_DIR"  # cuentas múltiples vía directorio de config
character.palette = "amber"
```

De serie: Claude Code, Codex CLI, Gemini CLI, OpenCode, Cursor CLI, GitHub Copilot CLI, Aider, Goose, Amp, Pi, Qwen Code, y "Custom" (cualquier comando).

- **Detección** de CLIs instalados (PATH del login shell del usuario, no el de launchd → bug clásico de apps GUI en macOS; leemos el PATH ejecutando `$SHELL -ilc 'env'` una vez y cacheamos).
- **Instalador/actualizador** opcional (`npm i -g`, `brew`), siempre mostrando el comando.
- **Cuentas múltiples** por agente (aisladas por directorio de config/variables), selector rápido y **uso/límites** cuando el CLI lo expone (Claude `/usage`-like vía ficheros de estado, Codex rate limits en su salida de estado).
- **Reanudar**: tras reinicio del Mac, cada sesión se puede relanzar con `--resume <id>` en su worktree.

### 7.2 Capa B — Proveedores de API (funciones internas de la app)

Para tareas propias de la app (baratas y rápidas), con el modelo que elija el usuario:

| Uso interno | Modelo sugerido por defecto |
|---|---|
| Nombre de rama y título de tarea | Haiku 5.5 / modelo local |
| Resumen "qué está haciendo" para el bocadillo del personaje | Haiku 5.5 / local |
| Descripción de PR a partir de diff + transcript | Sonnet 5.5 |
| **Juez del fan-out** (comparar N diffs + resultados de verify) | Opus 5.5 |
| Detección de tareas duplicadas | embeddings locales |

Proveedores: Anthropic, OpenAI, Google Gemini, OpenRouter, Ollama, LM Studio y cualquier endpoint OpenAI-compatible. Claves en **Keychain** (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`). Todo es **opcional**: sin claves, la app funciona y esas funciones caen a heurísticas o se ocultan.

### 7.3 Presupuestos y uso

- Panel de uso por agente/cuenta/worktree/día: tokens y coste estimado (de hooks/transcripts cuando el CLI los da; si no, "n/d").
- **Límites**: máximo de agentes simultáneos (global y por repo), presupuesto diario por proveedor API, aviso al 80 % de rate limit conocido.
- **Límite por capacidad de revisión**: "máximo N worktrees en estado *Listo para revisar*"; al llegar, nuevas tareas se encolan. Idea sacada directamente de las críticas.

---

## 8. StatusEngine — saber de verdad si un agente trabaja

### 8.1 Estados

```
             ┌──────────┐ prompt enviado ┌───────────┐ tool call  ┌────────────┐
  launch ──► │ Starting │───────────────►│ Thinking  │──────────► │ Working    │
             └──────────┘                └───────────┘ ◄────────── │ (tool: X)  │
                                               │                    └────────────┘
                                   pide permiso│/pregunta                 │ stop
                                               ▼                          ▼
                                     ┌──────────────────┐        ┌───────────────┐
                                     │ NeedsYou         │        │ Done (revisar)│
                                     │ (permiso/pregunta)│       └───────────────┘
                                     └──────────────────┘                │ sin actividad N min
   cualquier estado ──► Error (exit≠0 / API error / crash)              ▼
   cualquier estado ──► Dead (proceso no existe)                 ┌───────────┐
   sin señales fiables ──► Unknown (gris, con "?")               │ Idle/Sleep│
                                                                 └───────────┘
```

Cada estado lleva **confianza** (alta = hook oficial; media = OSC/título; baja = heurística) y `since`.

### 8.2 Señales, por prioridad

1. **Hooks oficiales del CLI** (alta confianza):
   - Claude Code: hooks `SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `Notification` (permiso/espera), `Stop`, `SubagentStop`, `SessionEnd`. Los inyectamos **sin tocar la config del usuario**: fichero de settings propio pasado con `--settings` (o settings local del worktree en `.claude/settings.local.json` ignorado por git). El hook ejecuta `bp hook --session $BP_SESSION_ID --event <evento>` que lee el JSON de stdin y lo manda al daemon.
   - Codex: `notify` en su config (vía perfil/`-c`) + parsing de eventos.
   - OpenCode: plugin de eventos. Gemini CLI y otros: hooks cuando existan; si no, capas 2–3.
2. **Secuencias de terminal** (media): OSC 9 / OSC 777 (notificaciones), OSC 133 (shell integration: prompt/comando/fin), OSC 0/2 (título con spinner), y soporte de la propuesta **OSC 7501 Program Status Protocol** (pedido en issues de Orca).
3. **Proceso** (media/baja): árbol de procesos con `libproc` (`proc_listchildpids`, `proc_pidinfo`) → CPU del agente y de sus hijos (si `pnpm test` corre, está *Working* aunque el TUI esté quieto). Detección de **muerte** inmediata por `kqueue` `EVFILT_PROC NOTE_EXIT` → nunca más "Working" con el proceso muerto.
4. **Salida** (baja): bytes/seg del PTY, ignorando redibujos de spinner/cursor (normalizamos frames: si solo cambia el carácter del spinner no cuenta como actividad).

### 8.3 Reglas anti-mentira (corrigen bugs concretos de Orca)

- El proceso muerto **siempre** gana: `Dead` en < 100 ms vía kqueue.
- Tras reinicio de la app, ningún estado se restaura como activo: se reconstruye desde daemon + señales nuevas.
- Un `Done` de hook no se pisa por actividad de salida (redibujos del TUI).
- Si la última señal de alta confianza tiene > N min y no hay CPU → degradar a `Unknown`, no mantener `Working`.
- **Estado manual** opcional que el usuario fija (p. ej. "bloqueado por backend") y que no cambia solo.
- Telemetría local (opt-in) de discrepancias para depurar: "hook decía X, heurística decía Y".

### 8.4 API de readiness para orquestación

`bp wait --session S --until idle|needs-you|done|exit --timeout 600` basado en el StatusEngine (no en "pantalla quieta 3 s"), así un prompt nunca se envía a un TUI que aún no está listo.

---

## 9. "El Edificio" — una oficina por proyecto, un personaje por worktree

### 9.1 Concepto

- **Cada proyecto (repo) es una oficina.** Cada **worktree es una persona** sentada en su mesa dentro de esa oficina.
- Las oficinas se **apilan en vertical como las plantas de un edificio**: proyecto A en una planta, proyecto B en la de debajo, y así sucesivamente. Es la misma jerarquía que el menú de Orca (proyecto → worktrees debajo), pero dibujada.
- Estilo **2D en vista lateral de corte** (como una casa de muñecas o *Tiny Tower*): encaja de forma natural con plantas apiladas, se lee de un vistazo y es lo más barato de dibujar y de renderizar. **Sin 3D.**
- La oficina **crece** con los worktrees: al crear uno, entra una persona andando y se sienta en una mesa nueva; al archivarlo, recoge y se va.

```
┌──────────────────────── El Edificio ─────────────────────────┐
│ ▼ web-app-fkpi                                   4 · ✋1 · ✓1  │
│ ┌──────────────────────────────────────────────────────────┐ │
│ │ 💡     💡     💡     💡                       🪴  ☕      │ │
│ │ 🧑‍💻     🙋     🥳     😴                                │ │
│ │ ▔▔▔▔   ▔▔▔▔   ▔▔▔▔   ▔▔▔▔                               │ │
│ │ fix-   api-   docs-  refac-                             │ │
│ │ login  cache  i18n   tor                                │ │
│ └──────────────────────────────────────────────────────────┘ │
│ ▼ nova                                           1 · 🧑‍💻        │
│ ┌──────────────────────────────────────────────────────────┐ │
│ │ ░░░░░░░░░░░░░ 💡 ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░ │ │  ← solo su lámpara
│ │              🧑‍💻                                          │ │
│ └──────────────────────────────────────────────────────────┘ │
│ ▶ luz-clara                                     apagada 🌙    │  ← 0 worktrees
│ ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓ │
└──────────────────────────────────────────────────────────────┘
```

### 9.2 Iluminación y vida de la oficina

| Situación del proyecto | Cómo se ve |
|---|---|
| 0 worktrees | **Oficina apagada y vacía**: luces apagadas, nadie dentro. Planta colapsada a una franja fina |
| 1 worktree | **Una sola luz encendida**, la de la mesa de ese empleado, que aparece trabajando; el resto de la oficina a oscuras |
| ≥ 2 worktrees | **Todas las luces de esa oficina encendidas**; aparecen mesas y elementos (planta, máquina de café, pizarra) según el tamaño |
| Alguien necesita al usuario | La planta parpadea suave en el borde y sube al principio de la lista |
| Fan-out en marcha | Los personajes del run se juntan en una mesa de reuniones de esa planta |

Mesas por fila: 4–6 según el ancho; con más worktrees la planta pasa a 2 filas (máximo recomendado ~12 visibles, con scroll horizontal si hay más).

### 9.3 Estado → animación

| Estado | Animación (2–6 frames) | Extra |
|---|---|---|
| Starting | Entra andando y se sienta | — |
| Thinking | Mano en la barbilla, "…" | Bocadillo con resumen |
| Working (edit) | Teclea | Bocadillo "editando `x.ts`" |
| Working (bash/tests) | Mira la pantalla, barra de progreso | "ejecutando tests" |
| NeedsYou | **Levanta la mano**, ✋ que rebota | Máxima prioridad visual |
| Done | Celebra 🎉 y deja un papel en la bandeja | Pasa a gris tras revisarlo |
| Idle/Sleep | Cabecea, "zZ" | Tras N min |
| Error | Humo del monitor | Click → ver error |
| Dead | Silla vacía con la chaqueta | — |
| Unknown | Semitransparente con "?" | Honestidad visual |
| Solape/conflicto | ⚡ entre las mesas implicadas | Click → ver ficheros |

### 9.4 Personajes

- **Aspecto determinista** por worktree (hash del id → pelo, piel, ropa, accesorio) + **color de la camiseta según el agente** (sin logos de marcas).
- **Nombre** = nombre corto de la rama, editable.
- **Interacción**: click → terminal del worktree; doble click → diff; menú contextual → enviar mensaje, pausar, archivar.
- Progresión cosmética opcional (la mesa gana objetos con las PRs mergeadas). Desactivable.

### 9.5 Dónde aparece

- **Pestaña "Edificio"** en la ventana principal (vista completa, plantas apiladas).
- **En la propia sidebar**: cada proyecto muestra una mini-franja de su oficina (altura ~48 px) sobre su lista de worktrees, así los personajes se ven siempre sin cambiar de vista. Desactivable.
- **Barra de menús**: mini-personajes de 16 px; el icono avisa si alguien necesita al usuario.
- **Dock**: badge con NeedsYou + Done sin revisar.
- Widget y ventana flotante "pecera": fase posterior.

### 9.6 Implementación (mínimo consumo)

- **Core Animation, no SpriteKit**: cada personaje es un `CALayer` con un sprite sheet y animación de `contentsRect` por keyframes (`CAKeyframeAnimation`, `calculationMode = .discrete`). La animación la ejecuta el render server de macOS, fuera del proceso de la app → **CPU casi cero** y funciona igual en Intel con gráfica integrada. Sin bucle de juego ni 60 fps: cada sprite anima a 6–8 fps, que es lo propio del pixel art.
- Escalado `magnificationFilter = .nearest` para pixel art nítido en Retina y no Retina.
- **Pausa total** (`layer.speed = 0`) cuando la vista no se ve, la ventana está ocluida (`NSWindow.occlusionState`), la oficina está apagada o todos sus personajes llevan un rato inactivos (las luces no cambian, solo se congela la animación). Con "Reducir movimiento" activado se muestran poses fijas con iconos.
- Arte: pixel art 32×32, **por capas** (cuerpo, pelo, ropa, accesorio) para combinar sin dibujar cada personaje. Fondos de oficina por tiles de 16 px. Aseprite → PNG atlas + JSON → generados en build.
- Presupuesto: todo el arte < 2 MB; oficina visible con 10 personajes < 1 % CPU en M1 y < 3 % en Intel 2019.
- **Licencia del arte compatible con open source**: arte propio o encargado publicado con **CC BY 4.0**, o packs **CC0** (p. ej. Kenney) para el prototipo. Los packs comerciales que prohíben redistribuir **no** valen porque los sprites van en el repo público.
- Accesibilidad: cada personaje es un elemento accesible ("fix-login, Claude Code, necesita tu permiso desde hace 3 min").
- La escena **solo consume** el stream del StatusEngine; no decide estados.

---

## 10. Interfaz principal

```
┌─ toolbar: [+ Nueva tarea ⌘N] [⌘K paleta]               uso: Claude 62% · Codex 18%  ⚙︎ ─┐
├────────────────────┬────────────────────────────────────────────────────┬──────────────────┤
│ SIDEBAR            │  pestañas: Terminal · Diff · Ficheros · Log          │ INSPECTOR        │
│ ▼ web-app-fkpi     │ ┌──────────────────────────────────────────────────┐ │ Estado: Working  │
│  [🧑‍💻🙋🥳😴 mini-oficina]│ │                                                  │ │ Agente: Claude   │
│   ● fix-login      │ │        terminal integrada (splits opcionales)     │ │ Modelo: opus-5.5 │
│   ✋ api-cache      │ │                                                  │ │ Base: pre        │
│   ✓ docs-i18n      │ │                                                  │ │ Puertos: 4012    │
│   ◌ refactor       │ └──────────────────────────────────────────────────┘ │ Ficheros: 6 ⚠︎1  │
│ ▼ nova  [😴]       │  [prompt rápido al agente …………………………………… ⏎]          │ PR: —  CI: —     │
│ ▶ luz-clara 🌙     │                                                    │ Coste: $0.84     │
│ [🏢 Edificio]      │                                                    │                  │
└────────────────────┴────────────────────────────────────────────────────┴──────────────────┘
```

- **Sidebar** = proyectos (oficinas) con sus worktrees debajo, en el mismo orden que el Edificio. Dentro de cada proyecto, orden por "necesita atención" (NeedsYou > Error > Done sin revisar > Working > Idle). Filtros por estado.
- Iconos de estado coherentes: Done = **gris** tras revisar, check verde solo "listo para revisar".
- **Command palette** (⌘K); atajos entre worktrees (⌃⌥↑/↓) y entre proyectos (⌃⌥⇧↑/↓) que **funcionan con cualquier foco**.
- **Bandeja "Atención"** (⌘⇧A): cola de lo que requiere al usuario.
- **Sin editor**: la pestaña Ficheros es un **visor de solo lectura** (código con resaltado, markdown, imágenes, PDF). Para tocar código se usan el agente o la terminal integrada. No hay botones de "abrir en VS Code".
- Tema claro/oscuro, fuentes configurables, SF Symbols. Español e inglés desde el día 1 (String Catalogs), incluidas las notificaciones.

---

## 11. Revisión, veredicto y PRs

### 11.1 Diff nativo

- Vista unificada/lado a lado, por fichero, con resaltado tree-sitter, colapsado de ficheros generados (lockfiles), "visto" por fichero.
- **Anotaciones por línea** → se agrupan y se envían al agente como un único mensaje estructurado ("Revisa estas 4 notas: …").
- Diff contra `baseRef` o contra el último checkpoint (ver 11.3).

### 11.2 Fan-out con veredicto (respuesta a "no dice qué diff es correcto")

Cuando un Run termina:

1. Ejecuta `[verify]` de `.bullpen.toml` en **cada** worktree (en paralelo limitado, con sus puertos).
2. Tabla comparativa: tests ✓/✗, typecheck, lint, tamaño del diff, ficheros tocados, coste, tiempo.
3. **Juez opcional** (modelo API elegido): recibe tarea + diffs + resultados → ranking con razones y riesgos. Se muestra como opinión, nunca como merge automático.
4. Botones: "Quedarme con B", "Combinar A+C" (abre un worktree nuevo con un agente y ambas ramas como contexto), "Descartar todos". Los perdedores se archivan.
5. Recomendación anti-desperdicio: antes de lanzar fan-out, si la tarea parece bien especificada, sugerir "un solo agente".

### 11.3 Checkpoints

- En cada `Stop` del agente se crea un commit "fantasma" en una ref privada (`refs/bullpen/checkpoints/<wt>/<n>`) → timeline navegable y **rollback** a cualquier punto sin ensuciar la rama.

### 11.4 Registro durable ("los prompts no son un registro")

- Por worktree: **Session Log** = prompts, resúmenes de cada turno, herramientas usadas, comandos ejecutados, checkpoints, coste. Guardado en SQLite y exportable a Markdown.
- Al crear PR: descripción generada con causa/qué cambia/verificación + sección plegable "Bitácora del agente". Respeta preferencias del usuario (título = nombre de rama literal, `--base` = baseRef del worktree).
- Opcional: guardar la bitácora como fichero en la rama (`.bullpen/log/<rama>.md`) para que el equipo la vea.

### 11.5 Integraciones por proyecto (Linear, GitHub y más)

Cada proyecto se puede **enganchar** a una o varias fuentes de tareas. Se configura en los ajustes del proyecto (y opcionalmente en `[integrations]` de `.bullpen.toml`, sin credenciales).

| Integración | Qué se vincula | Qué permite |
|---|---|---|
| **Linear** | Equipo(s), proyecto o filtro (p. ej. "asignados a mí, estado Todo") | Ver tickets, "Nuevo worktree desde ticket", mover estado (In Progress al crear, In Review al abrir PR), comentar el enlace de la PR, crear tickets de seguimiento |
| **GitHub** | Repo remoto (detectado del `origin`) | Issues → worktree; PRs: crear, estado, checks de CI, comentarios de revisión → "enviar al agente"; enlazar issue ↔ PR (`Closes #123`) |
| **GitLab / Jira** | Fase posterior, mismo modelo de "fuente de tareas" | — |

**Flujo "Nuevo worktree desde ticket/issue"**:

1. Panel de tareas del proyecto (pestaña "Tareas" o ⌘K "ticket …") con los tickets/issues filtrados.
2. Elegir uno → se rellena el diálogo de Nueva tarea:
   - **Rama**: la que propone Linear (`branchName`) o `prefijo/<id>-<slug-del-título>` para GitHub; editable.
   - **Base ref**: la del proyecto.
   - **Prompt**: global + proyecto + **plantilla de la fuente** con los datos del ticket + lo que añada el usuario (ver §6.5).
3. Al crear: worktree + setup + agente + prompt; el ticket pasa a "In Progress" (configurable) y queda **vinculado** al worktree.
4. El personaje del Edificio muestra el ID del ticket en su mesa (`FKPI-123`).
5. Al abrir la PR: título = nombre de la rama, `--base` = baseRef, descripción con enlace al ticket; el ticket pasa a "In Review" y recibe un comentario con la PR.
6. Al mergear: opción de mover el ticket a Done y archivar el worktree.

Detalles:

- Autenticación: Linear con OAuth o API key; GitHub con `gh` si está autenticado o token propio. Todo en Keychain. Cada proyecto puede usar **una cuenta distinta** (bug de Orca: ignoraba la cuenta ligada al proyecto).
- Los cambios de estado en Linear/GitHub son **visibles y reversibles** desde el inspector; nada se mueve en silencio.
- El texto de tickets, issues y comentarios se trata siempre como **datos no confiables** al pasarlo al agente.
- La arquitectura es un protocolo `TaskSource` (listar, obtener, cambiar estado, comentar) para que añadir GitLab, Jira o Asana sea un módulo nuevo sin tocar el resto.

---

## 12. Notificaciones (bien hechas)

- `UNUserNotificationCenter` con **identificador por (worktree, evento)** y `threadIdentifier` por worktree → se reemplazan en vez de apilarse; se **retiran** al atender el worktree o al borrarlo.
- Acciones en la notificación: "Ir", "Aprobar" (si aplica), "Silenciar este worktree 1 h".
- Silenciar por sesión, por repo, modo "no molestar mientras escribo" (si el foco está en la app, sin banner, solo badge).
- Sonidos por evento elegibles, incluido el sonido del sistema (correctamente con `UNNotificationSound.default`).
- Icono/color del proyecto en la notificación (attachment).

---

## 13. CLI `bp` y MCP

Paridad con la UI para que los agentes puedan orquestar:

```
bp repo add|list
bp wt create --repo web-app --base pre --task "..." --agent claude --model opus
bp wt list|show|current --json
bp wt rm|archive [--force]
bp agent send --wt fix-login "texto"        bp agent wait --wt X --until done
bp status --json                             bp ps   # resumen tipo `orca worktree ps`
bp run create --agents claude,codex --prompt "..."   bp run verdict <id>
bp env ports --wt X                          bp svc start web --wt X
bp hook ...    (uso interno de hooks)
bp mcp         (servidor MCP stdio con las mismas operaciones)
```

- Salida `--json` estable y versionada.
- Seguridad: socket 0600; los agentes solo pueden operar sobre su repo salvo que el usuario conceda más (scopes por sesión).

---

## 14. Seguridad y privacidad

- Nada sale del Mac salvo llamadas a APIs que el usuario configure; sin telemetría por defecto (opt-in, anónima, auditable).
- Claves en Keychain; nunca en ficheros ni logs (redacción en logs).
- Contenido de issues/tickets/webs tratado como **datos no confiables** al pasarlo a agentes (marcado explícito en el prompt).
- Confirmaciones para acciones destructivas (rm de worktree, force push).
- Sin notarización (no hay cuenta de Apple Developer): firma con certificado autofirmado estable, actualizaciones verificadas con EdDSA de Sparkle, `SHA256SUMS.txt` en cada release.

---

### 14.1 Open source

- **Licencia del código: MIT** (la misma que Orca; máxima adopción y contribuciones). Alternativa: Apache-2.0 si se quiere cláusula de patentes.
- **Arte: CC BY 4.0** en `Resources/Habitat/` (permite reutilizarlo citando). Nada de assets comerciales no redistribuibles.
- Repo público en GitHub desde la fase 0: issues con plantillas (bug / feature / agente nuevo), Discussions, `CONTRIBUTING.md`, `SECURITY.md` (reporte privado). Sin tests en GitHub: se ejecutan en local.
- Los **perfiles de agente** (`.toml`) son la contribución más fácil: cualquiera puede añadir soporte para un CLI nuevo sin tocar Swift.
- Releases **solo en GitHub**, generadas por CI al crear un tag (§4.4 y §4.5); checksums publicados.
- Sin telemetría por defecto (coherente con open source y privacidad).

---

## 15. Rendimiento: presupuestos medibles

| Métrica | Objetivo (M1 8 GB) | Objetivo (Intel i5 2019 8 GB) |
|---|---|---|
| Arranque en frío a ventana usable | < 0,8 s | < 1,5 s |
| RAM app en reposo, 10 worktrees | < 150 MB | < 180 MB |
| RAM daemon por sesión | < 20 MB + scrollback en disco | igual |
| CPU en reposo (oficina oculta) | < 0,5 % | < 1 % |
| Edificio visible, 10 personajes | < 1 % CPU | < 3 % CPU |
| Cambio de worktree/pestaña | < 50 ms | < 100 ms |
| Terminal: `cat` de 100 MB | sin bloquear UI | sin bloquear UI |

- Terminales ocultas: no se renderizan; el daemon sigue leyendo el PTY → nunca se "frenan" los agentes de fondo (bug de Orca con timers del renderer).
- Scrollback limitado en memoria (p. ej. 10k líneas) y resto en disco.
- Benchmarks locales (`make bench`) en Apple Silicon y, antes de cada release, en un Mac Intel; los resultados se guardan en `docs/bench/` para comparar entre versiones (regresión > 10 % se investiga antes de publicar).
- "Diagnóstico" en la app: procesos, memoria por sesión, sesiones legacy, botón de exportar informe.

---

## 16. Estrategia de pruebas

- **Unitarias** (Swift Testing): StatusEngine con trazas grabadas de sesiones reales (fixtures de hooks + bytes de PTY) → la fuente principal de regresiones de estado.
- **Integración**: repos git temporales; crear/borrar worktrees, guardias, merge-tree, asignador de puertos.
- **Agentes falsos**: un binario `fake-agent` que simula Claude/Codex (emite hooks, OSC, spinner, pide permiso, muere) para probar todo sin gastar tokens.
- **UI**: XCUITest de flujos críticos + snapshot tests de vistas y de frames de la oficina.
- **Rendimiento**: ver §15.
- **Dónde**: todo en local. `make test` en el día a día; antes de cada release, `make test` + `make bench` también en un Mac Intel (y, si hay ocasión, en macOS 14). GitHub no ejecuta pruebas.
- **Dogfooding** desde la fase 1: desarrollar la propia app con la app.

---

## 17. Roadmap por fases

Estimación para 1 persona a tiempo parcial con ayuda de agentes; ajustable.

### Fase 0 — Cimientos (2 semanas)
- Swift Package de módulos, Universal 2, `make test` / `make app` / `make bench` en local.
- `BPCore`, `BPPersistence` (esquema inicial + migraciones), logging.
- Spike técnico: SwiftTerm vs libghostty en Intel (rendimiento + empaquetado universal) → decisión documentada (ADR).

### Fase 1 — MVP "worktree + agente + estado" (5–6 semanas)
- Añadir repo, crear/listar/borrar worktree con base ref y guardias básicas.
- Daemon de sesiones con PTY, terminal en la app, reanudar tras cerrar la app.
- Sparkle + workflow de release en GitHub (§4.5) al cerrar la fase.
- Perfiles de Claude Code y Codex (+ Custom). Detección de PATH del login shell.
- **Prompt inicial** global y por proyecto (sin integraciones aún), con vista previa y variables básicas.
- StatusEngine v1: hooks de Claude, kqueue de muerte, heurística de CPU/salida.
- Sidebar con estados, notificaciones bien hechas, barra de menús básica.
- CLI `bp` básico (`wt create/list/rm`, `status`, `hook`).
- **Criterio de salida**: uso diario propio en `web-app-fkpi` sin volver a Orca para el flujo básico.

### Fase 2 — El Edificio + revisión (4–5 semanas)
- Oficina 2D por proyecto con Core Animation, plantas apiladas, iluminación (0: apagada · 1: una luz · ≥2: todas), entrada y salida de personajes.
- Arte MVP con licencia CC0/CC BY, mapeo estado→animación, bocadillos (resumen con modelo barato), interacción.
- Mini-franja de oficina en la sidebar, mini-personajes en barra de menús, badge del Dock.
- Diff nativo + anotaciones → agente. Checkpoints.
- Crear PR (título = rama, `--base` = baseRef), estado de PR/CI.

### Fase 3 — Entornos y paralelismo serio (4 semanas)
- `.bullpen.toml`: setup, APFS clones, puertos, env, servicios, teardown, verify.
- Mapa de solapamiento + `merge-tree` + avisos en oficina.
- Fan-out Runs con tabla comparativa y juez opcional.
- Proveedores API (Anthropic, OpenAI, Gemini, Ollama, OpenRouter) + Keychain.

### Fase 4 — Pulido y ecosistema (4 semanas)
- Más perfiles de agente (Gemini CLI, OpenCode, Cursor, Copilot, Aider, Goose, Amp, Pi).
- Panel de uso/coste, presupuestos, límite por capacidad de revisión.
- Session Log exportable, bitácora en PR.
- Integraciones por proyecto: Linear y GitHub issues → worktree, plantillas de prompt por fuente, sincronización de estados y enlace con la PR. MCP server.
- Visor de ficheros de solo lectura (código, markdown, imágenes, PDF).
- Progresión cosmética de los personajes.

### Fase 5 — Más allá de v1 (backlog)
- libghostty si no entró antes; widget y ventana "pecera"; automations programadas; orquestación entre agentes (mailbox/tasks) al estilo Orca pero sobre el StatusEngine; modo equipo (compartir bitácoras/estado vía repo o servidor ligero); plugins.

**Total hasta v1.0 (fases 0–4): ~19–21 semanas.**

**Fuera de alcance (decidido):** worktrees remotos por SSH, app móvil y push al móvil, editor de código, navegador interno. Se reconsideran después de la v1.

---

## 18. Estructura del repositorio

```
bullpen/
├── App/                      # target app (Bullpen.app), Info.plist, entitlements, Assets
├── Daemon/                   # target LaunchAgent
├── CLI/                      # target `bp`
├── Packages/
│   └── BullpenKit/           # Swift Package con todos los módulos BP*
│       ├── Sources/BPCore … BPHabitat …
│       └── Tests/
├── Resources/
│   ├── Agents/               # perfiles .toml de serie
│   └── Habitat/              # .aseprite fuente + atlas generados
├── Tools/                    # fake-agent, scripts de atlas, release
├── LICENSE                   # MIT (código) · Resources/Habitat/LICENSE: CC BY 4.0 (arte)
├── CONTRIBUTING.md · CODE_OF_CONDUCT.md · SECURITY.md
├── docs/
│   ├── PLAN.md               # este documento
│   └── adr/                  # decisiones de arquitectura (0001-terminal-engine.md…)
└── .github/workflows/        # solo release.yml (compila y publica al crear un tag; sin tests)
```

---

## 19. Riesgos y mitigaciones

| Riesgo | Impacto | Mitigación |
|---|---|---|
| Cambios en hooks/formatos de los CLIs (cambian a menudo) | Estado incorrecto | Perfiles declarativos actualizables sin release; capas 2–3 de respaldo; tests con trazas grabadas |
| libghostty difícil de compilar universal / API inestable | Retraso | Abstracción `TerminalEngine`; SwiftTerm como base suficiente |
| Animaciones del Edificio en Intel antiguos | Ventiladores | Core Animation fuera de proceso, 6–8 fps, pausa por oclusión e inactividad, modo reducido |
| Arte de personajes (tiempo/licencias) | Retraso de fase 2 / no se puede publicar | Solo CC0 o CC BY (redistribuible en repo público); sistema por capas |
| App sin notarizar | Fricción en la primera instalación, desconfianza | Guía clara en README (una sola vez), código abierto, releases compiladas por GitHub desde el tag, checksums; Sparkle evita repetirlo |
| Pérdida de la clave EdDSA de Sparkle | Usuarios sin actualizaciones automáticas | Copia de seguridad fuera de GitHub; documentado en `docs/RELEASING.md` |
| Alcance infinito (Orca tiene cientos de features) | No terminar nunca | Principio "no es un IDE"; criterio de salida por fase; backlog explícito |
| Uso de marcas de terceros (logos de Claude, OpenAI…) | Legal | Colores/accesorios genéricos, sin logos |
| Seguridad del socket/CLI | Escalada local | Permisos 0600, scopes por sesión, validación de rutas |

---

## 20. Decisiones

### Tomadas (2026-10-12)

| Tema | Decisión |
|---|---|
| Licencia | **Open source** (MIT propuesta) |
| Personajes | **2D**, mínimo consumo (Core Animation, pixel art); nada de 3D |
| Nombre | **Bullpen** (CLI `bp`, config `.bullpen.toml`) |
| Oficinas | **Una oficina por proyecto**, un personaje por worktree, **plantas apiladas** en el mismo orden que la sidebar |
| Luces | 0 worktrees: apagada y vacía · 1: una luz y su empleado trabajando · ≥ 2: todas encendidas |
| Agentes del MVP | Claude Code + Codex |
| macOS mínimo | 14 Sonoma |
| Prompt inicial | Por proyecto (más global), se envía al crear cada worktree; se combina con la plantilla de Linear/GitHub (§6.5) |
| Distribución | Solo GitHub Releases, sin cuenta de Apple Developer ni notarización; actualizaciones con Sparkle (§4.4, §4.5) |
| Identificador | `com.byluismoya.Bullpen` |
| Pruebas | Solo en local (y en un Mac Intel en momentos concretos); nada de tests en GitHub |
| Integraciones | Cada proyecto se engancha a Linear y/o GitHub como fuentes de tareas (§11.5) |
| Editor | **Solo visor**; se trabaja con la terminal integrada y los agentes |
| SSH remoto y app móvil | **Fuera** de la v1 |

### Pendientes

Ninguna por ahora.

---

### Fuentes de la investigación

- [Orca review — vibecodinghub](https://vibecodinghub.org/blog/orca-review)
- [Orca parallel AI agents — Apidog](https://apidog.com/blog/orca-parallel-ai-agents/)
- [Where Parallel Coding Agents Actually Pay Off — braindetox](https://braindetox.kr/en/posts/orca_parallel_coding_agents_2026.html)
- [Orca Review: How an AI Orchestrator Manages a Fleet of Coding Agents — besthub](https://www.besthub.dev/articles/orca-review-how-an-ai-orchestrator-manages-a-fleet-of-coding-agents-1488bd9dde7c)
- [stablyai/orca en GitHub](https://github.com/stablyai/orca) y su [issue tracker](https://github.com/stablyai/orca/issues)
- CLI `orca` v1.4.223 instalado localmente (`orca --help`)
