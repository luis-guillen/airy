# Changelog

Todos los cambios relevantes de Airy. El formato sigue [Keep a Changelog](https://keepachangelog.com/es-ES/1.1.0/)
y las versiones, [SemVer](https://semver.org/lang/es/).

## [Unreleased]

### Cambiado
- Airy es ahora software libre bajo **GPL-3.0-or-later**. README en inglés y español, código de conducta, política de seguridad y guía de contribución.

## [0.2.0] - 2026-10-21

### Añadido
- Nueva identidad: DiskMap pasa a llamarse **Airy**, con logo, paleta azul de acentos fríos y animaciones de viento (brisa, hojas, ráfagas).
- **Limpieza agresiva**: modos Agresivo y Prudente, etiquetas «Sin problema / Tú decides / No borrar», selección múltiple, «Borrar todo» con una sola confirmación y lo ámbar aparte.
- Limpieza de Docker, Node, Xcode y cachés de apps, y versiones duplicadas de pyenv, conda, rustup y Homebrew (la versión en uso siempre en rojo).
- Sección **Rendimiento**: memoria, CPU, temperatura y batería; cerrar apps con confirmación (y una segunda confirmación para forzar); mantenimiento reversible; «¿Por qué va lento?» con IA opcional.
- Secciones **Desinstalador** (con restos, huérfanos y enlaces rotos), **Grandes y viejos**, **Duplicados** y **Tipos de archivo**.
- Servidor **MCP** `airy-mcp` con herramientas de consulta, propuestas por `airy://` y limpieza solo de lo verde.
- Protección de los datos de navegadores (Safari, Chrome, Brave, Firefox, Arc, Opera, Edge, Vivaldi, Chromium) y de Signal.

### Cambiado
- El escáner limita los hilos de trabajo y la prioridad. La detección automática espera al índice y lo reutiliza: casi 0 % de CPU tras abrir la app.
- Las animaciones de fondo van con la frecuencia de fotogramas limitada y se pausan cuando la ventana no se ve.

### Corregido
- La ventana dejaba de responder durante un análisis completo: el anillo de progreso animaba con un muelle cada 100 ms.
- Las filas inferiores de la barra lateral no recibían clics.
- Rendimiento se cerraba por un bucle de restricciones con las casillas y botones del sistema.
- Homebrew ya no usa nunca `--zap`. Antes de desinstalar se revisa lo que hará el cask; si toca algo protegido, la app va a la Papelera.

## [0.1.0] - 2026-10-20

### Añadido
- Primera versión (DiskMap): mapa del disco, índice incremental, limpieza básica con catálogo y Papelera.

[Unreleased]: ../../compare/v0.2.0...HEAD
[0.2.0]: ../../releases/tag/v0.2.0
