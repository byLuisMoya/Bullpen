# 0002 — Motor de terminal

Fecha: 2026-10-12 · Estado: pendiente (spike de fase 0)

## Opciones
- **SwiftTerm**: Swift puro, universal, MIT, fácil de integrar. Rendimiento suficiente para el MVP.
- **libghostty**: renderizado Metal, muy rápido; compilación con Zig y empaquetado universal por verificar.

## Plan
Abstraer tras un protocolo `TerminalEngine`. Medir con ambos en Apple Silicon e Intel: `cat` de 100 MB,
memoria con 10 terminales, CPU en reposo. Decidir con números.
