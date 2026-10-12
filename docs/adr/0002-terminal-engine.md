# 0002 — Motor de terminal

Fecha: 2026-10-12 · Estado: pendiente (faltan datos de Metal y libghostty)

## Opciones
- **SwiftTerm (CoreGraphics)**: Swift puro, universal, MIT.
- **SwiftTerm (Metal)**: el mismo SwiftTerm con su renderizador Metal (desde 1.12).
- **libghostty**: renderizado Metal de Ghostty; se compila con Zig.

## Cómo se mide
`make bench` (local, nunca en GitHub). Ejecuta `Benchmarks/TerminalBench` y guarda el informe en
`docs/bench/`. Mide por motor: parseo (MB/s), coste de un frame completo, streaming de 100 MB de salida
tipo agente, memoria por terminal con 10k líneas de scroll e uso de CPU en reposo con 10 terminales.
Hay que ejecutarlo **con la sesión desbloqueada y sin tocar el Mac** (si la ventana queda tapada,
el informe lo marca y los números de render no valen). Repetir en un Mac Intel antes de decidir.

## Hallazgos (2026-10-12, M5, solo Command Line Tools)
- **Sin Xcode solo se puede medir SwiftTerm 1.11.2 con CoreGraphics.** SwiftTerm ≥ 1.12 incluye shaders
  Metal que necesitan el compilador `metal` (solo viene con Xcode), y libghostty exige Xcode completo,
  Metal Toolchain y Zig. Es decir: **cualquier motor moderno obliga a tener Xcode instalado para
  compilar Bullpen** (Xcode es gratis; no requiere cuenta de desarrollador).
- SwiftTerm CoreGraphics: parseo ~78 MB/s, 0 % CPU en reposo con 10 terminales.
- **Memoria: ~46 MB por terminal con 10k líneas** (120 columnas). Con 10 agentes serían ~460 MB, muy por
  encima del objetivo. Conclusión independiente del motor: el scroll en memoria debe limitarse
  (p. ej. 2.000 líneas) y el resto ir a disco en el daemon, como ya prevé el plan (§4.1, §15).
- Los números de render de esta primera ejecución no son fiables (pantalla bloqueada).

## Siguiente paso
Instalar Xcode, ejecutar `make bench` con las tres opciones en este Mac y en uno Intel, y decidir.
