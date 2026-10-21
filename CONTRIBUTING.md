# Cómo contribuir

1. Crea una rama desde `main`: `feat/…`, `fix/…` o `docs/…`.
2. Mantén las reglas de seguridad del [README](README.md#seguridad-cómo-decide-airy-qué-se-puede-borrar).
   Toda acción destructiva pasa por `ConfirmSheet → AppModel → CleanupExecutor`.
3. Añade pruebas en `Tests/DiskMapCoreTests`. Usa carpetas temporales y procesos falsos, nunca el disco
   real.
4. Antes de abrir el PR, ejecuta `swift build` y `swift test --no-parallel`.
5. Usa mensajes de commit al estilo [Conventional Commits](https://www.conventionalcommits.org/es/v1.0.0/)
   (`feat:`, `fix:`, `perf:`, `docs:`…) y actualiza `CHANGELOG.md` en «Unreleased».
