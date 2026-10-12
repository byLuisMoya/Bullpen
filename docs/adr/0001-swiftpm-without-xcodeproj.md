# 0001 — Swift Package Manager instead of an .xcodeproj

Fecha: 2026-10-12 · Estado: aceptada

## Contexto
El proyecto es open source y debe compilar como binario Universal (arm64 + x86_64) para macOS 14+.
Un `.xcodeproj` genera conflictos en PRs y obliga a tener Xcode; en la máquina de desarrollo solo
hay Command Line Tools.

## Decisión
- Todo el código vive en un único `Package.swift` (módulos `BP*`, app `BullpenApp`, CLI `bp`).
- `Scripts/build-app.sh` compila cada arquitectura por separado (`--triple`), las une con `lipo`
  y monta `Bullpen.app` con `Resources/Info.plist`. Firma ad-hoc por ahora.
- Xcode puede abrir `Package.swift` directamente cuando haga falta depurar.

## Consecuencias
- Con solo Command Line Tools hay que fijar el SDK 26.x (el 27 usa macros de SwiftUI cuyo plugin
  solo trae Xcode) y añadir la ruta del plugin de Swift Testing. Lo hace `Scripts/env.sh`.
- Para firma Developer ID, notarización y extensiones (widget, LaunchAgent con `SMAppService`)
  puede hacer falta volver a un proyecto Xcode (generado con XcodeGen/Tuist). Se revisará en fase 1.
