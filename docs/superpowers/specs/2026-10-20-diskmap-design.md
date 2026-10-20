# DiskMap — Diseño

Fecha: 2026-10-20
Estado: listo para aprobación

## 1. Qué es y por qué

DiskMap es una app nativa de macOS que analiza el disco del usuario, lo enseña como un **mapa de bloques interactivo** (treemap) y le ayuda a **liberar espacio de verdad**: explica en lenguaje sencillo qué es cada cosa, recomienda con IA qué borrar y qué no, y lo borra ella misma de forma segura.

Nace de una sesión de limpieza manual (20-10-2026) en la que se recuperaron ~60 GB borrando modelos de IA olvidados, cachés de Docker/uv/cargo/Homebrew/conda/Spotify/Brave, apps desinstaladas a medias (Ollama, Whisky) y restos de apps. Cada paso exigió saber **qué era cada carpeta, si algo la usaba y cómo borrarla bien**. DiskMap debe hacer ese trabajo automáticamente.

**Usuario:** el dueño del Mac (perfil técnico, desarrollador: Docker, Python/Anaconda, Rust, Node, herramientas de IA). Habla español; toda la interfaz va en **español de España**.

**Éxito:** el usuario abre DiskMap, en segundos ve qué ocupa espacio, entiende qué es cada cosa sin buscar en Google, y libera varios GB con unos pocos clics sin miedo a romper nada. Y la app es tan bonita que apetece abrirla.

## 2. Objetivos

1. **Mapa de bloques** (treemap "squarified") de todo el disco o de una carpeta, interactivo:
   - Al terminar el análisis los bloques entran con animación escalonada.
   - Clic en un bloque → zoom animado hacia dentro (el bloque crece hasta llenar el mapa y aparecen sus hijos). Ruta de navegación (breadcrumb) arriba para volver; también atrás con gesto/tecla.
   - Color por **tipo de contenido** (vídeo, imágenes, apps, código/proyectos, cachés, modelos de IA, contenedores/VM, documentos, sistema, otros), con leyenda.
   - Al pasar el ratón: nombre, tamaño, % del padre, fecha de último uso y **explicación en lenguaje sencillo** de qué es.
   - Debe seguir fluido con miles de bloques.
2. **Secciones** (barra lateral, estilo apps de limpieza tipo CleanMyMac/AppCleaner):
   1. **Mapa** — el treemap.
   2. **Limpieza** — cachés, logs y restos detectados automáticamente, cada uno con explicación, tamaño y riesgo. Casos mínimos (todos vistos en la sesión): caché de compilación de Docker, Homebrew, pip, uv, pnpm, npm, cargo (registry/git), conda pkgs, Hugging Face hub, Ollama models, `~/.cache/whisper`, Playwright, cachés de navegadores (Brave/Chrome/Safari), Spotify, Xcode DerivedData/simuladores si existen, logs, instalaciones a medias (p. ej. `codex-runtime-install-*`).
   3. **Desinstalador** — lista de apps con su **tamaño real** (app + restos en `~/Library`: Application Support, Caches, Containers, Preferences, Saved Application State, HTTPStorages, Logs, LaunchAgents) y borrado completo sin dejar restos. También detecta **restos huérfanos** de apps ya desinstaladas (como Whisky u Ollama) y enlaces rotos en `/usr/local/bin`.
   4. **Grandes y viejos** — archivos más grandes y los que llevan meses sin abrirse, ordenables y filtrables.
   5. **Duplicados** — archivos idénticos (mismo contenido) agrupados, eligiendo cuál conservar.
   6. **Tipos de archivo** — cuánto ocupa cada tipo (vídeo, fotos, código, modelos de IA…), con gráfico animado y acceso a los archivos de cada tipo.
   7. **Asistente IA** — dos modos:
      - **Informe**: revisa el análisis y clasifica en **Borrar sin riesgo / Depende de ti / No tocar**, con el porqué de cada cosa y el espacio total recuperable. Desde el informe se puede borrar directamente.
      - **Chat**: preguntas libres sobre el disco ("¿qué es esta carpeta?", "¿puedo borrar esto?"), con el análisis como contexto. El chat puede proponer acciones que el usuario confirma con un botón.
3. **Borrado por la propia app** (decisión del usuario):
   - Archivos y carpetas → **Papelera** (recuperables), nunca borrado definitivo directo.
   - Cachés de herramientas → **su comando oficial** cuando existe (`docker builder prune -a -f`, `brew cleanup --prune=all -s`, `uv cache clean`, `pnpm store prune`, `pip cache purge`, `conda clean --all -y`, `ollama rm`…), porque borrar a mano sus carpetas puede dejarlas inconsistentes.
   - Lo que exige permisos de administrador (p. ej. enlaces de root en `/usr/local/bin`) → diálogo de contraseña del sistema.
   - Siempre **confirmación** antes de borrar, mostrando qué se borra y cuánto se libera; después, animación con el espacio recuperado y el total liberado acumulado.
4. **Explicaciones** para todo lo que se ve: un **catálogo local** de rutas y patrones conocidos (qué es, quién lo crea, si se regenera, riesgo de borrarlo) cubre lo habitual sin IA ni red; la IA explica lo que el catálogo no conoce.
5. **Ligera y rápida**: binario pequeño, poco consumo de RAM en reposo, análisis en paralelo aprovechando todos los núcleos, resultados que aparecen progresivamente mientras analiza.

## 3. No-objetivos

- No es antivirus, ni optimizador de RAM/batería, ni "acelerador" del Mac.
- No sincroniza nada en la nube ni tiene cuentas de usuario.
- No es multiplataforma (solo macOS).
- No hace falta distribuirla en la App Store (uso personal; firma ad-hoc vale).

## 4. Anti-objetivos (fracaso aunque "funcione")

- **Borrar algo importante.** Nunca proponer como "sin riesgo" ni borrar sin aviso:
  - Documentos, fotos, proyectos y archivos personales del usuario (siempre "Depende de ti").
  - **Volúmenes de Docker** (contienen bases de datos de proyectos: `*_pgdata`, `*_datos_db`…) → "No tocar" salvo petición explícita.
  - Modelos o datos que **use otro proyecto**: antes de recomendar borrar un modelo/caché compartida, comprobar referencias (como se hizo con los blobs compartidos de Hugging Face).
  - Lo que esté **en uso**: no limpiar la caché de una app abierta (Spotify, Brave, ChatGPT…); pedir cerrarla primero o hacerlo por el usuario si acepta. No tocar runtimes en uso (p. ej. `codex-primary-runtime`).
  - Nada de `/System`, ni rutas protegidas por SIP; manejar con elegancia los errores "Operation not permitted" (p. ej. metadatos de `~/Library/Containers`).
- **Enviar contenido de archivos a internet.** A la IA solo van nombres de rutas, tamaños, fechas y tipos; nunca el contenido.
- **Verse genérica** o "de plantilla": tiene que parecer una app de Apple de primera (nivel app de ChatGPT para Mac), no una herramienta de desarrollador.
- **Ir a tirones**: el zoom y las transiciones deben ir a 60–120 fps (ProMotion).
- **Mentir con números**: los tamaños deben ser espacio real en disco (bloques asignados, sin contar dos veces hard links ni archivos dispersos tipo `Docker.raw` por su tamaño aparente).

## 5. Restricciones

- **Equipo:** MacBook con Apple M4 Pro, 24 GB RAM, macOS 27.0.1, disco de 460 GB.
- **No hay Xcode instalado**, solo Command Line Tools con **Swift 6.4**. El proyecto debe compilarse con **Swift Package Manager** y un script que empaquete el `.app` (Info.plist, icono `.icns` con `iconutil`, firma ad-hoc con `codesign -s -`). Si en algún punto Xcode resultara imprescindible, avisar antes.
- **Acceso total al disco:** para ver `~/Library/Containers`, Mail, etc. hace falta que el usuario dé permiso de "Acceso total al disco" a DiskMap. La app debe detectarlo y guiar al usuario para concederlo, y funcionar (con aviso) sin él.
- **IA vía Claude Code ya instalado** (`claude`, versión 2.1.x), en modo no interactivo (`claude -p` con salida JSON / streaming), sin pedir claves de API nuevas. Ojo: el `claude` del PATH actual es un shim de cmux; la app debe localizar el ejecutable real (rutas habituales, `~/.claude/local`, npm global, Homebrew) o permitir elegirlo en Ajustes. Si no está disponible, las secciones sin IA funcionan igual y el asistente explica cómo activarlo.

## 6. Decisiones tomadas

| Decisión | Quién la tomó |
|---|---|
| Visualización principal: mapa de bloques (treemap) | Usuario (eligió la opción A frente a anillos y burbujas: "es más clara") |
| Interfaz muy moderna, animada, estilo Apple, "lo más atractiva posible" | Usuario |
| Secciones estilo apps de limpieza/desinstalación | Usuario (lista concreta de secciones: propuesta de Claude, no objetada) |
| La app borra ella misma | Usuario |
| Borrado a la Papelera + comandos oficiales de cada herramienta | Claude |
| Nativa en **Swift + SwiftUI** | Usuario, a propuesta de Claude ("lo mejor posible", referencia: app de ChatGPT para Mac) |
| Animaciones con física de muelle de SwiftUI en lugar de GSAP (misma sensación) | Claude, aceptado por el usuario |
| IA con informe **y** chat | Usuario |
| IA a través de Claude Code local, solo metadatos | Claude |
| Nombre **DiskMap** | Usuario ("Disc Map, o algo así"); grafía "DiskMap" es elección de Claude |
| Logo personalizado y muy atractivo | Usuario |
| Ubicación `~/Desktop/Herramientas/DiskMap` | Usuario |
| Interfaz en español | Claude (el usuario habla español) |

### Decisiones del usuario tras la revisión

- **Construcción por fases** (usuario):
  - **Fase 1:** Mapa + Limpieza + Asistente IA (informe y chat), con todo el pulido visual y de animación. Incluye el escáner, el índice persistente, el catálogo de rutas conocidas, el borrado seguro, el icono y el empaquetado.
  - **Fase 2:** Desinstalador, Grandes y viejos, Duplicados, Tipos de archivo.
  - En la fase 1 las secciones de la fase 2 pueden aparecer en la barra lateral como "Próximamente" o no aparecer (decisión del constructor).
- **Papelera** (usuario): la app **no** vacía la Papelera sola; muestra "En la Papelera: X GB" y un botón "Vaciar Papelera" que pulsa el usuario.

### Decisiones de Claude tras la revisión del constructor

- **Espacio liberado honesto:** lo enviado a la Papelera se muestra como "En la Papelera: X GB" y **no** cuenta como liberado hasta que se vacía. La app ofrece un botón "Vaciar Papelera" (con confirmación) y entonces anima el espacio liberado. Si el espacio no baja por **instantáneas locales de APFS/Time Machine**, la app lo detecta (`tmutil listlocalsnapshots /`) y lo explica, ofreciendo borrarlas. Los comandos oficiales (Docker, brew…) sí liberan al momento.
- **Firma estable:** el script de empaquetado crea (una sola vez) un certificado autofirmado en el Llavero del usuario ("DiskMap Local Signing") y firma siempre con él, para que el permiso de Acceso total al disco no se pierda en cada compilación. Si falla, recurre a firma ad-hoc y avisa.
- **Alcance del análisis:** el volumen de arranque completo (incluidos `/Library`, `/Applications`, `/private/var` y el usuario actual; otros usuarios solo si hay permiso), más volúmenes externos seleccionables desde la barra lateral. Se excluyen los volúmenes de sistema de solo lectura y se muestra aparte el espacio "purgable" y del sistema que macOS reporta (`URLResourceKey.volumeAvailableCapacityForImportantUsageKey` frente a total).
- **Persistencia:** se guarda un índice del último análisis (en `~/Library/Application Support/DiskMap`), que se muestra al instante al abrir la app mientras se reanaliza en segundo plano y se actualiza progresivamente. También se guarda el total liberado acumulado y el historial de limpiezas.
- **Acciones de la IA:** el chat y el informe **solo** pueden proponer acciones del catálogo cerrado de la app (mover una ruta a la Papelera, ejecutar un comando oficial conocido, desinstalar una app con su ficha). Nunca comandos de shell libres escritos por la IA. Si la IA y el catálogo discrepan en el riesgo, **gana la valoración más estricta**.

## 7. Dirección visual

- Ventana con barra lateral translúcida (materiales/vibrancy del sistema), modo oscuro y claro, tipografía SF Pro, iconos SF Symbols.
- Treemap con bloques de esquinas redondeadas, separaciones finas, degradados sutiles por tipo y brillo al pasar el ratón; dibujado con `Canvas`/Metal para rendimiento.
- Animaciones: muelles (`spring`) para zoom y selección, entradas escalonadas, transiciones con `matchedGeometryEffect` entre secciones, números que cuentan hacia arriba, barra/anillo de progreso vivo durante el análisis, celebración sobria al liberar espacio.
- **Icono propio** estilo macOS (squircle), con el motivo de bloques del treemap en colores vivos y profundidad; generado como `.icns` en todos los tamaños.

## 7b. Servidor MCP para agentes externos (añadido 2026-10-20, fase 1)

**Por qué:** el usuario y mucha gente ya trabajan con agentes (Claude Code, la app de Claude, Codex, opencode y otras CLIs). En vez de depender solo del chat interno, DiskMap expone un **servidor MCP** para que cualquiera de esos agentes pueda consultar el disco y limpiar lo seguro. El chat interno **se mantiene** (decisión del usuario).

**Qué es:** un segundo ejecutable dentro del paquete, `DiskMap.app/Contents/MacOS/diskmap-mcp`, que habla MCP por stdio (JSON-RPC 2.0). Lo lanza el cliente del agente. Funciona aunque la app esté cerrada: lee el índice guardado (`~/Library/Application Support/DiskMap`), el catálogo y usa el mismo `CleanupScanner`/`CleanupExecutor` con todas sus comprobaciones.

**Herramientas (tools)** — nombres en inglés por convención MCP, textos de respuesta en español:
- `get_disk_summary`: total, libre, analizado, reparto por tipos, fecha del último análisis, si hay Acceso total al disco.
- `list_largest(path?, limit?)`: hijos más grandes de una carpeta del índice, con tipo, tamaño, fecha y riesgo.
- `explain_path(path)`: qué es (catálogo o diccionario de carpetas conocidas), riesgo efectivo y si se regenera.
- `list_cleanup_items`: los elementos de Limpieza con id, tamaño, riesgo, método, bloqueos y "lo usa".
- `run_safe_cleanup(item_id)`: ejecuta **solo** elementos con riesgo efectivo **Borrar sin riesgo**, no bloqueados (apps abiertas, "lo usa"), vía `CleanupExecutor` (Papelera o comando oficial). Cualquier otro riesgo ⇒ error explicativo, nada se ejecuta.
- `propose_cleanup(item_id | path, reason)`: para lo "Depende de ti": abre DiskMap (URL `diskmap://propose?...`) con la hoja de confirmación ya preparada; el usuario decide. El agente recibe "propuesta enviada; pendiente de confirmación del usuario".
- `show_in_app(path)`: abre DiskMap y hace zoom en el mapa a esa carpeta (`diskmap://show?path=`).
- `rescan`: pide a DiskMap que reanalice (`diskmap://rescan`); devuelve al terminar o indica que la app debe estar abierta.
- "No tocar" nunca tiene herramienta de acción. No hay herramienta que acepte comandos o rutas arbitrarias para borrar.

**Ajustes y visibilidad en la app** — en la sección Asistente, pestaña **"Conectar agente"**:
- Estado del servidor y ruta del ejecutable.
- Instrucciones listas para copiar (botón copiar) para Claude Code (`claude mcp add diskmap -- <ruta>`), Codex (`~/.codex/config.toml`), opencode (`opencode.json`) y configuración JSON genérica (`mcpServers`), más "Añadir a Claude Code" en un clic si `claude` está instalado.
- Interruptor **"Permitir que los agentes ejecuten limpiezas seguras"** (activado por defecto, decisión del usuario). Si está apagado, `run_safe_cleanup` responde que el usuario lo ha desactivado.
- **Registro de actividad** de los agentes: cada llamada de acción (quién/qué/cuánto/resultado) aparece en la app y en el historial de limpiezas, marcado "por un agente".
- Ajustes compartidos con el servidor en `~/Library/Application Support/DiskMap/agents.json`.

**Anti-objetivos añadidos:** el MCP nunca envía contenido de archivos (solo metadatos, como la IA); nunca ejecuta nada que no sea "Borrar sin riesgo" sin el clic del usuario en la app; el interruptor apagado bloquea toda acción.

## 8. Lo que se deja al constructor

- Algoritmo exacto de escaneo (p. ej. `getattrlistbulk`/`fts` en paralelo) y cómo contar hard links y archivos dispersos.
- Estrategia de duplicados (tamaño → hash parcial → hash completo).
- Formato del catálogo de rutas conocidas y cuántas entradas iniciales (mínimo las de la sección 2.2 y las de la sesión).
- Esquema de los prompts y del JSON que devuelve la IA.
- Diseño concreto del icono y paleta exacta, dentro de la dirección visual.
- Arquitectura interna y pruebas (con pruebas automáticas al menos para escaneo, cálculo de tamaños, clasificación de riesgo y el treemap).
