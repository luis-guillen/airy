# Airy — Diseño de la fase 2 (rebranding, Rendimiento, limpieza agresiva, MCP)

Fecha: 2026-10-20
Estado: listo para aprobación
Parte de: `2026-10-20-diskmap-design.md` (el diseño de la fase 1 sigue vigente salvo donde este documento lo cambia).

## 1. Qué es y por qué

DiskMap pasa a llamarse **Airy** y deja de ser solo un mapa del disco: ahora **le quita peso al Mac** en todos los sentidos — espacio en disco, memoria, swap, procesos que calientan el equipo. La idea de marca es **ligereza y viento**: lo que sobra "se lo lleva el viento".

El usuario quiere tres cosas, en este orden de importancia:
1. **El servidor MCP** (lo más importante): que Claude Code, Codex, opencode y otros agentes puedan consultar y limpiar el Mac a través de Airy.
2. **Que la app sea clara**: que diga sin rodeos qué se puede borrar y qué no, y que lo que es seguro se pueda borrar sin miedo; que el estado del Mac (memoria, swap, temperatura) se entienda sin saber leer el Monitor de Actividad.
3. **Limpieza agresiva** de cachés de desarrollo (Docker, Node, etc.) con sus prunes, con selección múltiple y "borrar todo", y una marca nueva con **muchas animaciones** de viento.

**Éxito:** el usuario abre Airy, en un vistazo sabe si el Mac va bien o qué lo está frenando, cierra lo que pesa, borra de golpe varios GB de cachés de desarrollo sin miedo, y un agente puede hacer lo mismo por MCP. Y la app es bonita y se siente "aire".

## 2. Objetivos

### 2.1 Rebranding: Airy

- **Nombre:** **Airy** (elección del usuario entre Lightweight, Brisa, Airy y Lighter).
- **Logo:** **remolino de viento con hojas** (opción C del usuario frente a "una hoja" y "tres hojas volando"). Squircle con degradado de turquesa (`#2fd0ff`) a azul índigo (`#2a3bd9`), tres arcos concéntricos de viento en blanco translúcido y hojas blancas/celestes girando. El círculo evoca un disco y un medidor.
  - Versión simplificada para tamaños pequeños (≤ 64 px: barra de menús, listas, Finder): un solo arco grueso y una hoja (en tamaño pequeño los arcos finos se pierden). *Decisión de Claude.*
  - En la app, el logo puede animarse (remolino girando despacio); el `.icns` es estático.
- **Paleta:** opción B del usuario, **"azul con acentos fríos" y contraste fuerte**:
  - La interfaz (fondos, barra lateral, botones, acentos) es azul: noche `#07112a`/`#0d2350`, azul `#2f8bff`, cielo `#5ab8ff`, texto `#f2f7ff`/secundario `#b9cdf0`.
  - El mapa de bloques usa la **gama fría completa** (azules, turquesas, violetas, índigo) para que cada tipo de contenido se distinga.
  - **Contraste fuerte** (petición del usuario): texto e indicadores con contraste WCAG AA como mínimo (4,5:1 en texto normal).
  - **Colores de seguridad** fijos aunque la app sea azul: verde `#1fdc7a` (sin problema), ámbar `#ffb020` (tú decides), rojo `#ff4d5e` (no borrar). Son señales, no decoración. *Decisión de Claude.*
  - Modo claro y oscuro (la paleta de arriba es la oscura; la clara la deriva el constructor con el mismo contraste).
- **Cambio de identidad técnica:** nombre visible, icono, `CFBundleName`, bundle id (`local.airy.Airy`), carpeta de datos (`~/Library/Application Support/Airy`, migrando la de DiskMap al primer arranque), identidad de firma ("Airy Local Signing"), esquema de URL (`airy://`), ejecutable MCP (`airy-mcp`) y `/Applications/Airy.app` (borrando el `DiskMap.app` antiguo tras instalar). El usuario tendrá que **volver a dar Acceso total al disco una vez** (macOS lo liga a la identidad); la app lo detecta y guía, como ya hace.

### 2.2 Animaciones de marca (viento)

Propuesta de Claude aceptada por el usuario ("muchas animaciones con la marca"):
- **Arranque:** hojas que giran en remolino y forman el logo.
- **Análisis:** brisa que cruza la ventana; hojas orbitando el anillo de progreso.
- **Borrar un elemento:** el bloque o la fila se deshace en hojas que se lleva el viento; el contador de espacio liberado sube.
- **"Borrar todo":** una ráfaga grande barre la lista de izquierda a derecha.
- **Rendimiento:** el remolino gira más rápido cuanto más carga de CPU; con el Mac caliente, el azul tira a naranja; al cerrar una app, su fila sale volando como una hoja.
- **Siempre:** brisa muy suave de fondo; botones que se mecen ligeramente al pasar el ratón.
- **Límites:** respetar "Reducir movimiento" de macOS (sustituir por fundidos); 60–120 fps; **cero CPU en reposo** (la brisa de fondo se pausa cuando la ventana no está visible o activa, como ya hace el mapa).

### 2.3 Perfil de usuario ("¿Cómo usas tu Mac?") — RETIRADO

> **Decisión del usuario (20-10-2026):** se quita la pregunta del perfil ("es un poco evidente"). No hay pregunta al arrancar ni perfil en Ajustes; lo que se sugiere y preselecciona depende solo del riesgo y del modo (Agresivo/Prudente). El texto de abajo queda como histórico.


- Pregunta en el **primer arranque** (y editable en Ajustes), selección múltiple: **Programo**, **Diseño, foto o vídeo**, **Uso IA en local**, **Juego**, **Música y audio**, **Uso básico**.
- El perfil cambia **qué sugiere Airy y en qué orden** (qué entradas del catálogo se muestran destacadas, cuáles se preseleccionan, textos de explicación), p. ej.:
  - Programo → cachés de Docker, Node/pnpm/yarn/bun, uv/pip/conda, cargo, Xcode (DerivedData, simuladores antiguos, archivos de dispositivos), `node_modules`/`.venv`/`target` viejos.
  - IA en local → modelos de Ollama, LM Studio, Hugging Face que no se usan hace meses.
  - Diseño/vídeo → cachés de render y previsualizaciones (Adobe, Final Cut, DaVinci).
  - Juego → juegos y bottles (Steam, Epic, Whisky) sin abrir hace meses.
  - Música → librerías de sonidos de Logic/GarageBand no usadas.
  - Uso básico → solo lo más evidente y sin riesgo (navegadores, logs, Papelera, descargas viejas como "tú decides").
- **Regla inviolable:** el perfil **nunca** convierte en "sin problema" nada protegido (anti-objetivos de la fase 1 y §4). Solo reordena, destaca y preselecciona dentro del catálogo.

### 2.4 Claridad: qué se puede borrar y qué no

Petición del usuario: "que diga claramente qué cosas se pueden borrar y qué no, y si es seguro, que se pueda sin problema".
- Tres etiquetas de alto contraste en **toda** la app (Limpieza, Mapa, Desinstalador, Grandes y viejos, Duplicados, Asistente, MCP):
  - 🟢 **Sin problema** — se borra sin miedo; siempre dice por qué ("se vuelve a descargar sola", "Xcode la rehace").
  - 🟠 **Tú decides** — dice qué pierdes ("tendrías que volver a bajar 40 GB").
  - 🔴 **No borrar** — dice por qué; **sin botón de borrar**.
- Lista agrupada por esas tres etiquetas, verde arriba.
- Son los mismos tres niveles de riesgo de la fase 1 ("Borrar sin riesgo / Depende de ti / No tocar"), con los nuevos textos visibles. *El constructor puede renombrar los textos internos o no.*

### 2.5 Limpieza agresiva

Petición del usuario: "que sea agresivo, hay que borrar muchas cosas de las cachés de Docker, Node y todo, y sobre todo los prunes".
- **Modo por defecto: Agresivo.** Ajuste "Prudente" disponible que vuelve al comportamiento de la fase 1. *Decisión de Claude* (el usuario pidió agresivo; prudente queda como red).
- **Nuevas acciones del catálogo (comandos oficiales):**
  - Docker (si el demonio está activo): `docker builder prune -a -f`, `docker image prune -a -f` (todas las imágenes sin usar, no solo huérfanas), `docker container prune -f`, `docker network prune -f`. **Nunca** `--volumes` ni `docker volume prune`.
  - Node: `npm cache clean --force`, `pnpm store prune`, `yarn cache clean`, `bun pm cache rm`.
  - Python/otros (ya en fase 1, revisar que estén todos): `uv cache clean`, `pip cache purge`, `conda clean --all -y`, `brew cleanup --prune=all -s`, cargo registry/git.
  - Xcode: `xcrun simctl delete unavailable`, DerivedData, `~/Library/Developer/Xcode/iOS DeviceSupport` antiguos, `~/Library/Developer/CoreSimulator/Caches`.
- **Clasificación en modo agresivo:**
  - Verde: cachés de herramientas y su caché de compilación, imágenes Docker sin usar (se vuelven a descargar o reconstruir), redes sin uso, caches de Node/Python/Rust/Homebrew, DerivedData, simuladores no disponibles.
  - Ámbar **preseleccionado**: contenedores Docker parados (pueden guardar estado en su capa), `node_modules`/`.venv`/`target`/`.next`/`build` de proyectos sin tocar hace ≥ 3 meses (están en carpetas personales; se regeneran con `npm install` etc.). *Decisión de Claude.*
  - Rojo siempre: volúmenes de Docker, documentos, iCloud, Mail, Mensajes, Llavero, Fotos, Calendarios, Contactos, Aplicaciones, sistema, runtimes en uso. Igual que la fase 1.
- **Selección múltiple:** casillas por fila, "Seleccionar todo lo verde", "Seleccionar todo" (solo verde + ámbar; el rojo nunca se selecciona), y botón **"Borrar todo · X GB"**. **Una sola** hoja de confirmación con la lista completa, el total y qué es Papelera / qué es comando. Se ejecuta en secuencia con progreso por fila y resumen final (lo que funcionó, lo que falló y por qué).
- "Hasta X GB" para los comandos que no garantizan liberar todo (como en la fase 1).


### 2.5b Instalaciones duplicadas de desarrollo (añadido 20-10-2026, petición del usuario)

"También instalaciones duplicadas de cosas de desarrollo, dependencias y eso." Airy detecta varias versiones instaladas de la misma herramienta y propone quitar las que sobran:
- **Lenguajes y toolchains:** Python (pyenv, conda/miniconda/anaconda, Homebrew `python@3.x`, python.org en /Library/Frameworks — este último solo informativo), entornos de conda, Node (nvm, fnm, volta, asdf, Homebrew `node@x`), Ruby (rbenv, rvm, asdf), Java/JDK (`/Library/Java/JavaVirtualMachines` solo informativo; SDKMAN, Homebrew `openjdk@x`), Rust (`rustup toolchain list`), Go (varias versiones en `~/sdk`, Homebrew `go@x`), Xcode (varias `Xcode*.app`) y simuladores.
- **Dependencias duplicadas:** `node_modules` del mismo paquete repetidos entre proyectos (información + sugerir pnpm), varias copias de modelos de IA idénticos (ya cubierto por Duplicados), virtualenvs duplicados.
- **Qué versión se usa:** se marca como **en uso** (rojo, no se ofrece) la versión por defecto (PATH actual, `pyenv global`, `nvm alias default`, `rustup default`, `xcode-select -p`) y cualquier versión que pida un proyecto (`.nvmrc`, `.node-version`, `.python-version`, `.tool-versions`, `rust-toolchain(.toml)`, `.ruby-version`, `pom/gradle` toolchains si es fácil) dentro de las raíces de proyectos de §2.5.
- **Riesgo:** las demás versiones son **ámbar**; en Agresivo se preseleccionan solo si llevan ≥ 3 meses sin usarse (fecha de último acceso del ejecutable o de su carpeta) y nada las pide; nunca verde. Lo que está bajo `/Library`, `/Applications` o `/System` es solo informativo salvo `Xcode*.app` (que pasa por el Desinstalador).
- **Cómo se quita:** siempre con el comando oficial (`pyenv uninstall -f`, `conda env remove -n`, `nvm uninstall`, `fnm uninstall`, `volta uninstall`, `rbenv uninstall -f`, `rustup toolchain uninstall`, `brew uninstall` solo si `brew uses --installed` no lo necesita), o a la Papelera si la herramienta no tiene comando. Siempre por el embudo y con confirmación; el MCP solo lo lista (nunca lo ejecuta, porque es ámbar).

### 2.6 Rendimiento (sección nueva)

Petición del usuario: "coges toda la información del Monitor de Actividad y lo pones de manera que el usuario lo entienda; ver si el Mac está muy caliente y poder cerrar cosas". IA opcional.
- **Estado general** arriba, en una frase generada por **reglas fijas** (sin IA): "Tu Mac va bien", "Tu Mac va justo de memoria: Chrome y Docker se llevan el 60 %", "Tu Mac se está calentando y ha bajado la velocidad", etc.
- **Memoria:** usada / libre / caché de archivos, **presión de memoria** (verde/amarillo/rojo, como el Monitor de Actividad) y **swap** usada, con explicación sencilla de qué es la swap y por qué crece.
- **Temperatura:** estado térmico de macOS (normal / caliente / muy caliente / crítico) y si el sistema está **reduciendo la velocidad** para enfriarse. Sin grados en esta fase: leerlos exige interfaces privadas de Apple que pueden romperse. *Decisión de Claude.*
- **CPU y energía:** qué apps consumen más procesador y energía ahora.
- **"Lo que más pesa":** lista de **apps agrupadas con sus procesos** (Chrome + sus procesos auxiliares cuentan como Chrome; procesos sueltos como `node` o `python` aparecen con su comando/proyecto si se puede saber), ordenada por impacto (memoria, CPU), con una línea de qué es cada una (catálogo, como en el disco).
- **Cerrar:** botón **Cerrar** por fila, con la confirmación habitual (ConfirmSheet). Primero cierre normal (la app puede pedir guardar); **"Forzar cierre"** solo si no responde. Selección múltiple para cerrar varias. *Decisión de Claude.*
  - **Nunca** se ofrecen para cerrar: procesos del sistema o de otros usuarios, Finder, Dock, WindowServer, loginwindow, SystemUIServer, Control Center, el propio Airy ni su MCP. Procesos de terminal del usuario (`node`, `python`, servidores locales) sí, en ámbar ("puede que estés usándolo").
- **Sin botón mágico de "liberar RAM"** (postura de Claude, aceptada): macOS gestiona la memoria solo y esos botones no ayudan de verdad; lo que alivia es cerrar lo que más consume, y eso es lo que ofrece Airy. Este cambio sustituye el no-objetivo de la fase 1 "no es optimizador de RAM": ahora lo es, pero solo de forma honesta.
- **IA opcional:** botón "¿Por qué va lento?" que manda a Claude solo números y nombres de apps (nunca contenido), con la misma invocación cerrada que el Asistente.
- **Ligereza:** las mediciones solo se hacen mientras la sección (o el MCP) las pide; refresco cada 1–2 s con la sección visible y nada en segundo plano.

### 2.7 Secciones de la fase 2 ya diseñadas

Se construyen tal como las describe el diseño de la fase 1 (§2, puntos 3–6): **Desinstalador**, **Grandes y viejos**, **Duplicados**, **Tipos de archivo**, con las etiquetas de §2.4, selección múltiple y las animaciones de §2.2.

### 2.8 Servidor MCP (lo más importante)

Aprobado por el usuario: se construye **tal como describe §7b del diseño de la fase 1**, con estos cambios:
- Nombre del ejecutable `airy-mcp`, esquema `airy://`, ajustes en `~/Library/Application Support/Airy/agents.json`; servidor MCP registrado como `airy`.
- **"Sin riesgo" respeta el modo** (Agresivo/Prudente) que el usuario tiene en la app: `run_safe_cleanup` solo ejecuta lo que la app marca en verde con el modo actual.
- **Nuevas herramientas:**
  - `run_safe_cleanup_all`: ejecuta todos los elementos verdes no bloqueados de una vez (equivale a "Borrar todo lo verde"), con el mismo interruptor.
  - `get_performance`: memoria, presión, swap, estado térmico, top de apps por memoria/CPU (solo lectura).
  - `propose_quit_app(app)`: abre Airy con la confirmación de cierre preparada; cerrar apps **nunca** lo hace el agente sin el clic del usuario.
- La pestaña "Conectar agente" mantiene sus instrucciones de copia para Claude Code, Codex, opencode y JSON genérico, el interruptor y el registro de actividad.

### 2.9 Lo que se aprende de Mole (eficacia y capacidad)

Petición del usuario: "que sea como Mole en eficacia y capacidad". Estudio completo, de solo lectura, en `docs/superpowers/research/2026-10-20-mole-inspiracion.md`. Mole es **GPL-3.0**: se adaptan **ideas y listas de rutas**, nunca código (ni traducido línea a línea); se le cita como inspiración en "Acerca de". Se adopta (números = fila de la tabla §6 del estudio):

- **Seguridad del borrado (requisitos de ingeniería):**
  - **Embudo único** de borrado con validación de ruta: absoluta, sin `..` ni caracteres de control, enlaces simbólicos y ancestros resueltos, raíces críticas comparadas por inodo y sin distinguir mayúsculas, rechazo de `~` entero, e identidad del archivo comprobada otra vez justo antes de borrar (#1).
  - **Guardián de proceso en tres estados** (corriendo / parado / desconocido ⇒ saltar) por familia de limpieza, y guardián de caché viva (proceso dueño o base SQLite abierta) (#2).
  - **Lista de protecciones duras ampliada** con la de Mole (§2.15 del estudio), siempre re-aplicada encima de cualquier ajuste del usuario (#3).
  - **Presupuestos de tiempo y fallo cerrado** en cada sondeo; **honestidad de análisis** (completo / parcial / no disponible, tamaños con "+" si parcial) (#31, #32).
- **Control del usuario:**
  - **"Proteger esto"**: lista blanca de rutas/patrones del usuario, respetada por la app y el MCP (#4).
  - **Vista previa** sin borrar (también `dry_run: true` en las herramientas de acción del MCP) y **registro exportable** (JSON) con identificador de ejecución y autor (usuario o agente) (#5).
- **Más objetivos de limpieza:**
  - Instaladores `.dmg/.pkg/.mpkg/.iso/.xip` y `.zip` con instalador en Descargas/Escritorio/Documentos → ámbar; caché de Homebrew → verde (#7).
  - Catálogo de artefactos de proyecto ampliado (`Pods`, `.gradle`, `.dart_tool`, `.build`, `.turbo`, `.angular`, `.svelte-kit`, `.astro`, `.tox`, `__pycache__`, `CACHEDIR.TAG`…) con guardias: repositorio anidado, claves `*-keypair.json`, archivos rastreados por Git, `bin`/`vendor` solo si son .NET/Composer (#8). Sigue la regla de "≥ 3 meses" de Airy, más prudente que Mole.
  - Navegadores Chromium completos (todos los derivados, `Code Cache`, `GPUCache`, `ShaderCache`, Service Worker CacheStorage, versiones antiguas del framework dentro del `.app`) y heurística de caché regenerable en Application Support (#9).
  - Xcode fino: conservar las **2** versiones más recientes de DeviceSupport, XCTestDevices, DocumentationCache, `simctl runtime delete` de runtimes huérfanos, solo con Xcode y simuladores parados (#12).
  - Cola larga de cachés de desarrollo con comando oficial cuando existe (Go, Poetry, Ruff, mypy, Bundler, Composer, Gradle, Swift PM, Flutter, Expo, Electron, node-gyp, Prisma, Corepack, Terraform…) (#13).
  - Cachés de apps de usuario (comunicación, creativas, medios, juegos, utilidades, oficina), ordenadas por perfil; **nunca** cachés de Mensajes ni de Mail (#14).
  - Sistema con contraseña de administrador, en ámbar: `/Library/Logs/DiagnosticReports`, logs antiguos de `/private/var/log` y `/Library/Caches`, instaladores de macOS viejos (#15).
  - Firmware `.ipsw` → verde (#33). Versiones antiguas de agentes de IA (Claude Code, Codex, Cursor…), conservando la activa y una anterior → verde (#30).
  - Safari: compactar su base solo con Safari cerrado → ámbar (#23). Historial de privacidad (`QuarantineEventsV2`) → ámbar sin preselección (#24).
  - **Solo revisar** (sin botón de borrar automático): Xcode Archives, copias de iPhone, emuladores Android, worktrees de agentes, copias de Time Machine fallidas (#11, #28).
- **Huérfanos y desinstalador más precisos:** reglas por bundle id (inventario completo de apps o no se decide nada; 30 días sin uso; si `mdfind` falla, se asume instalada; solo Caches/Logs/Saved State; nunca Containers/Group Containers/LaunchAgents; patrones sensibles `ssh/gpg/keychain/1password…` nunca son huérfanos) (#10) y lista ampliada de ubicaciones del desinstalador, `launchctl bootout` de ayudantes, `brew uninstall --cask --zap` si vino de Homebrew, recibos `pkgutil` (#29).
- **Rendimiento más completo:**
  - **Diagnóstico por reglas** con causas reales: `syspolicyd`/WindowServer/Spotlight/CoreSimulator ≥ 25 % sostenido; swap > 50 % o libre < 15 %; VM de Docker > 2 GB sin contenedores; proceso desbocado; imágenes de disco montadas que cargan `syspolicyd` (#6).
  - **Puntuación de salud** como frase + semáforo (#20).
  - Métricas extra con APIs estables: batería (ciclos, salud), E/S de disco, red, tiempo encendido, procesos zombi, CPU por núcleos P/E (#18).
  - **Elementos de inicio** rotos (LaunchAgents sin binario), solo informe con enlace a Ajustes del Sistema (#17).
  - **Mantenimiento útil, en ámbar y reversible:** no crear `.DS_Store` en red/USB, quitar ajustes heredados dañinos, reparar `.plist` corruptos de apps, reindexar Spotlight solo tras diagnosticar (#21).
- **Rechazado:** grados y ventiladores (sensores privados, #19), optimizaciones placebo —vaciar DNS, reiniciar red, `periodic`, Launch Services, `purge`, reiniciar Dock— (#22), `VACUUM` de Mail/Mensajes (#23), vaciar la Papelera solo (#25), borrar `.DS_Store` (#26), servicios de sistema huérfanos (solo informe, #27), cachés bajo `/private/var/folders` (#16), Touch ID para sudo (#34).

## 3. No-objetivos

- Sin grados de temperatura ni lectura de sensores privados (de momento).
- Sin "liberar RAM" con `purge` ni trucos similares.
- Sin cerrar procesos del sistema ni de otros usuarios.
- Sin distribución en App Store; sigue siendo de uso personal.
- Sin cuentas, nube ni telemetría.

## 4. Anti-objetivos (fracaso aunque "funcione")

Todos los de la fase 1 siguen vigentes. Además:
- **Que el modo agresivo borre algo que no se regenera.** Agresivo solo afecta a cosas que se vuelven a descargar o reconstruir; lo personal sigue en ámbar como mínimo y lo protegido en rojo.
- **Que el perfil o la IA bajen un riesgo.** Solo pueden subirlo; el perfil solo reordena/preselecciona.
- **Que un agente cierre apps o borre algo ámbar/rojo** sin el clic del usuario en la app.
- **Cerrar una app con trabajo sin guardar** sin avisar: siempre cierre normal primero.
- **Que las animaciones hagan la app pesada:** una app que se llama Airy y consume CPU en reposo es un fracaso.
- **Perder datos de DiskMap con el cambio de nombre:** el índice, el historial y el total liberado se migran.
- **Verse azul plano y aburrido o con poco contraste:** el usuario pidió contraste fuerte.

## 5. Restricciones

Las de la fase 1 (Swift 6.4, SwiftPM, solo Command Line Tools, sin Xcode, firma autofirmada local, UI en español de España, IA vía Claude Code local con solo metadatos y la invocación cerrada actual) y:
- La rama actual `fase-1` aún no está fusionada en `master`; la fase 2 parte de ella (el constructor pregunta antes de fusionar).
- Mediciones de rendimiento con APIs públicas (`host_statistics64`, `sysctl` para swap/presión, `ProcessInfo.thermalState`, `libproc`/`proc_pid_rusage`, `NSRunningApplication`).

## 6. Decisiones tomadas

| Decisión | Quién |
|---|---|
| Fase 2 completa + Rendimiento + rebranding, ya | Usuario |
| MCP es lo más importante; visto bueno al diseño §7b | Usuario |
| Rendimiento: información del Monitor de Actividad explicada + cerrar apps; IA opcional | Usuario |
| Sin botón "liberar RAM"; cerrar lo que pesa es el alivio real | Claude, aceptado |
| Temperatura sin grados (estado térmico) | Claude, aceptado |
| Nombre **Airy** | Usuario |
| Logo **remolino con hojas** (opción C, "la que se ve en grande") | Usuario |
| Versión simplificada del logo para tamaños pequeños | Claude |
| Paleta **azul con acentos fríos**, contraste fuerte | Usuario |
| Colores de seguridad verde/ámbar/rojo se mantienen | Claude |
| Perfil "¿Cómo usas tu Mac?" con selección múltiple, ajusta lo sugerido | Usuario (idea); lista de perfiles de Claude, aceptada |
| El perfil nunca baja un riesgo | Claude |
| Limpieza **agresiva** con prunes de Docker/Node y "Borrar todo" con selección | Usuario |
| Agresivo por defecto, "Prudente" como opción | Claude |
| Volúmenes de Docker siguen en rojo en agresivo | Claude (coherente con fase 1) |
| `node_modules` viejos y contenedores parados en ámbar preseleccionado | Claude |
| Lista de animaciones de viento | Claude, aceptada |

### Decisiones de Claude tras la revisión del constructor

- **Ajustes compartidos app ↔ MCP:** modo (Agresivo/Prudente), perfil e interruptor de agentes viven en `~/Library/Application Support/Airy/settings.json` (ampliando `agents.json` o sustituyéndolo). La clasificación de riesgo efectivo (catálogo + modo + perfil + bloqueos) y el muestreo de rendimiento viven en la biblioteca común (`DiskMapCore`, renombrable), de modo que el MCP clasifica y mide igual que la app **aunque la app esté cerrada**.
- **MCP con la app cerrada:** `get_performance` mide por su cuenta (solo lectura). `propose_cleanup`, `propose_quit_app`, `show_in_app` y `rescan` abren Airy mediante `airy://…` (LaunchServices la arranca si está cerrada) y devuelven "pendiente de confirmación del usuario" / "análisis pedido".
- **"Borrar todo" y el ámbar:** en la app, "Borrar todo" borra **lo seleccionado**, incluido el ámbar preseleccionado; la hoja de confirmación única muestra el ámbar en un bloque aparte y destacado ("Revisa: esto no se regenera solo / puede tener estado") y quitarlo es un clic. Esa confirmación cuenta como la decisión del usuario. **El MCP nunca toca ámbar**: `run_safe_cleanup_all` = solo verde no bloqueado.
- **Modo Prudente:** clasificación de la fase 1 y **sin** preselección de ámbar.
- **Docker:** si el demonio no responde, las acciones de Docker aparecen bloqueadas con "Abre Docker Desktop para limpiar esto"; Airy no arranca Docker. La confirmación de `docker container prune` lista los contenedores parados por nombre.
- **"Proyecto sin tocar ≥ 3 meses":** raíz = carpeta con `package.json`, `pyproject.toml`/`requirements.txt`, `Cargo.toml` o `.git`; señal = fecha de modificación más reciente de cualquier archivo del proyecto **excluyendo** las carpetas regenerables (`node_modules`, `.venv`, `target`, `.next`, `build`, `dist`) y `.git/objects`. Se excluyen las carpetas sincronizadas con iCloud (ya protegidas).
- **Migración DiskMap → Airy:** al primer arranque Airy **copia** los datos de `Application Support/DiskMap` (índice, historial, total liberado, ajustes) y deja la carpeta antigua intacta. El script de empaquetado crea la identidad "Airy Local Signing", instala `/Applications/Airy.app` y, solo si eso fue bien, mueve `DiskMap.app` a la Papelera. El certificado antiguo de DiskMap no se toca.
- **Punto de partida:** la fase 2 se construye en una rama `fase-2` creada desde `fase-1` tal como está (245 pruebas en verde, revisión final limpia). Fusionar en `master` se pregunta al usuario aparte.
- **Perfiles:** los ejemplos de §2.3 son el **mínimo** de entradas de catálogo por perfil. El perfil afecta al orden, destacado y preselección de Limpieza y a las sugerencias del Asistente y del MCP (`list_cleanup_items` ordenado igual); **no** cambia el Mapa.

## 7. Lo que se deja al constructor

- Orden de construcción (recomendación: MCP primero, por ser lo más importante; luego rebranding, Limpieza agresiva + perfil, Rendimiento, y las cuatro secciones).
- Cómo agrupar procesos por app (app responsable, cadena de padres, ruta del bundle).
- Umbrales de las frases del estado general y de "proyecto viejo".
- Implementación de las animaciones (Canvas/TimelineView, partículas de hojas) dentro de los límites de §2.2.
- Paleta clara derivada y valores exactos de contraste.
- Detalles de migración DiskMap → Airy.
- Pruebas automáticas (al menos: clasificación agresiva/prudente, perfil que no baja riesgos, lista de procesos nunca cerrables, herramientas MCP y su rechazo de lo no verde, migración de datos).
