# DiskMap Fase 1 — Plan de implementación

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** App nativa de macOS "DiskMap" con Mapa (treemap animado), Limpieza (catálogo + borrado seguro) y Asistente IA (informe + chat vía Claude Code), empaquetada como `.app` con icono propio.

**Architecture:** Paquete SwiftPM con una librería `DiskMapCore` sin UI (escáner, catálogo, clasificación de riesgo, treemap, limpieza, IA, persistencia), totalmente probada con Swift Testing, y un ejecutable `DiskMap` en SwiftUI que solo presenta y anima. Todo efecto externo (procesos, apps abiertas, sistema de archivos de la Papelera) pasa por protocolos para poder probarse con dobles.

**Tech Stack:** Swift 6.4 (Command Line Tools, sin Xcode), SwiftPM, SwiftUI + AppKit, Swift Testing (`import Testing`), `Canvas` para el treemap, Claude Code CLI 2.1.x.

**Spec:** `docs/superpowers/specs/2026-10-20-diskmap-design.md`

## Global Constraints

- Interfaz 100 % en **español de España**; tamaños con `ByteCountFormatter` `.file` y locale `es_ES` ("1,5 GB").
- Compilar solo con `swift build` / `swift test`; nada de Xcode. `swift-tools-version: 6.4`, plataforma mínima `.macOS(.v15)`.
- Archivos y carpetas → **Papelera** (`FileManager.trashItem`), nunca borrado definitivo, salvo el botón "Vaciar Papelera" pulsado por el usuario.
- Cachés de herramientas → **su comando oficial**; nunca borrar a mano sus carpetas.
- Confirmación antes de cualquier borrado, mostrando qué y cuánto.
- Lo enviado a la Papelera **no** cuenta como liberado hasta vaciarla ("En la Papelera: X GB").
- Tamaños = **espacio asignado** (`st_blocks * 512`), hard links contados una vez, sin seguir enlaces simbólicos.
- A la IA solo van rutas, tamaños, fechas, tipos y fichas del catálogo; **nunca contenido de archivos**. Claude se invoca con `--tools ""`.
- La IA solo puede proponer acciones del catálogo cerrado (`trash(path)`, `runCatalogCommand(id)`); si IA y catálogo discrepan, **gana el riesgo más estricto**.
- Nunca "sin riesgo": archivos personales (`~/Documents`, `~/Desktop`, `~/Pictures`, `~/Movies`, `~/Music`, `~/Downloads`, `~/orca`, `~/Projects`), volúmenes de Docker (siempre "No tocar"), runtimes en uso (`codex-primary-runtime`), `/System`.
- No limpiar la caché de una app abierta; pedir cerrarla.
- Animaciones: muelle de zoom `.spring(response: 0.45, dampingFraction: 0.82)`; entrada escalonada 12 ms por bloque, máximo 0,6 s total; objetivo 120 fps.
- Paleta por tipo (oscuro/claro iguales en tono): vídeo `#FF375F`, imágenes `#FF9F0A`, apps `#BF5AF2`, código `#0A84FF`, cachés `#30D158`, modelos IA `#64D2FF`, contenedores/VM `#5E5CE6`, documentos `#FFD60A`, sistema `#8E8E93`, otros `#AC8E68`.
- Fase 2 (Desinstalador, Grandes y viejos, Duplicados, Tipos de archivo) aparece en la barra lateral **deshabilitada con la etiqueta "Próximamente"** (decisión del constructor ya tomada aquí).
- Bundle ID `local.diskmap.DiskMap`; datos en `~/Library/Application Support/DiskMap`.

## Review Focus

1. **Firmlinks y enlaces:** analizar `/` en APFS no debe contar dos veces `/Users` (también visible como `/System/Volumes/Data/Users`) ni seguir enlaces simbólicos en bucle → total ≈ espacio usado que reporta el volumen. Test en Task 2 (`skipsSymlinkLoops`, `excludesSystemVolumesPrefix`).
2. **Rutas con espacios, tildes y ñ** (`Application Support`, `Música`, `diseño`) en comandos y en prompts → siempre `Process` con array de argumentos, nunca cadena de shell; JSON bien escapado. Test en Task 6 (`commandArgumentsAreNotShellInterpolated`) y Task 7 (`contextKeepsUnicodePaths`).
3. **Claude ausente, lento o con JSON inválido** → el resto de la app funciona; el asistente muestra un estado claro y un botón "Reintentar"; tiempo máximo 120 s. Test en Task 7 (`reportFailsGracefullyOnInvalidJSON`, `reportTimesOut`).
4. **Archivos que desaparecen o sin permiso a mitad del análisis** → se omiten, se cuentan como inaccesibles y el análisis termina. Test en Task 2 (`unreadableDirectoryIsReportedNotFatal`).
5. **Carpetas con decenas de miles de archivos pequeños** (`node_modules`, `.git`) → el mapa agrupa lo diminuto en "Otros (N elementos)" y sigue fluido; la RAM del índice se mantiene acotada. Test en Task 2 (`prunesSmallChildrenIntoAggregate`) y Task 4 (`groupsTinyEntriesIntoOthers`).

---

## Estructura de archivos

```
DiskMap/
  Package.swift
  Sources/DiskMapCore/
    Model/FileNode.swift            nodo del árbol + ContentKind + Risk
    Model/Formatting.swift          formato de bytes y fechas en español
    Scan/DiskScanner.swift          escáner paralelo
    Scan/FileKindClassifier.swift   tipo por extensión/ruta
    Catalog/Catalog.swift           modelo y carga del catálogo
    Catalog/RiskPolicy.swift        reglas de riesgo y "el más estricto gana"
    Layout/Treemap.swift            squarified + agrupación "Otros"
    Persistence/IndexStore.swift    índice del último análisis + historial
    System/CommandRunner.swift      ejecutar procesos, PATH de login
    System/SystemProbes.swift       apps abiertas, Acceso total al disco, snapshots, Papelera
    Cleanup/CleanupScanner.swift    detecta elementos de limpieza
    Cleanup/CleanupExecutor.swift   ejecuta limpiezas
    Cleanup/ReferenceChecker.swift  "¿lo usa otro proyecto?"
    AI/ClaudeLocator.swift
    AI/AIContextBuilder.swift
    AI/AIAssistant.swift            informe + chat
  Sources/DiskMapCore/Resources/catalog.json
  Sources/DiskMap/                  app SwiftUI (Task 8–11)
  Tests/DiskMapCoreTests/...
  scripts/make-icon.swift
  scripts/build-app.sh
  Resources/Info.plist
```

---

### Task 1: Paquete, modelo y formato

**Files:**
- Create: `Package.swift`, `Sources/DiskMapCore/Model/FileNode.swift`, `Sources/DiskMapCore/Model/Formatting.swift`, `Sources/DiskMap/DiskMapApp.swift` (ventana vacía "DiskMap"), `Tests/DiskMapCoreTests/ModelTests.swift`

**Interfaces:**
- Produces:
  - `public enum ContentKind: String, Codable, CaseIterable, Sendable { case video, images, apps, code, caches, aiModels, containers, documents, system, other }` con `public var title: String` ("Vídeo", "Imágenes", "Apps", "Código y proyectos", "Cachés", "Modelos de IA", "Contenedores y VM", "Documentos", "Sistema", "Otros").
  - `public enum Risk: Int, Codable, Comparable, Sendable { case safe = 0, yourCall = 1, doNotTouch = 2 }` con `title` ("Borrar sin riesgo", "Depende de ti", "No tocar") y `public static func strictest(_ a: Risk, _ b: Risk) -> Risk`.
  - `public final class FileNode: @unchecked Sendable, Identifiable` con `id: Int`, `name: String`, `weak parent`, `children: [FileNode]`, `isDirectory: Bool`, `allocatedSize: Int64`, `lastModified: Date?`, `kind: ContentKind`, `kindBytes: [Int64]` (10 posiciones, índice = `ContentKind.allCases`), `descendantCount: Int`, `aggregatedCount: Int` (>0 si el nodo es el agregado "Otros"), `var path: String` (calculada subiendo por `parent`), `var dominantKind: ContentKind`.
  - `public enum Format { static func bytes(_: Int64) -> String; static func relativeDate(_: Date?) -> String }`.

- [ ] **Step 1: Crear `Package.swift`** con productos: librería `DiskMapCore` (recurso `catalog.json` con `.process`), ejecutable `DiskMap` (depende de `DiskMapCore`), test `DiskMapCoreTests`.
- [ ] **Step 2: Tests que fallan** en `ModelTests.swift`:
  - `strictestPicksHigher`: `Risk.strictest(.safe, .doNotTouch) == .doNotTouch`, `Risk.strictest(.yourCall, .safe) == .yourCall`.
  - `pathJoinsParents`: raíz `/` → `Users` → `ana` ⇒ `path == "/Users/ana"`.
  - `dominantKindUsesKindBytes`: `kindBytes` con vídeo 10, código 30 ⇒ `.code`.
  - `formatsSpanishBytes`: `Format.bytes(1_500_000_000) == "1,5 GB"`.
- [ ] **Step 3:** `swift test` → FAIL (tipos no definidos).
- [ ] **Step 4:** Implementar los tipos.
- [ ] **Step 5:** `swift test` → PASS; `swift build` → compila el ejecutable.
- [ ] **Step 6:** `git add -A && git commit -m "feat: paquete y modelo base"`

---

### Task 2: Escáner paralelo

**Files:**
- Create: `Sources/DiskMapCore/Scan/DiskScanner.swift`, `Sources/DiskMapCore/Scan/FileKindClassifier.swift`, `Tests/DiskMapCoreTests/ScannerTests.swift`

**Interfaces:**
- Consumes: `FileNode`, `ContentKind`.
- Produces:
  - `public struct ScanOptions: Sendable { roots: [URL]; excludedPrefixes: [String] = ["/System/Volumes", "/dev", "/Volumes", "/private/var/vm", "/.Spotlight-V100", "/.fseventsd"]; pruneThreshold: Int64 = 1_048_576 }` (si un `root` está dentro de `/Volumes`, ese prefijo no se excluye para él).
  - `public struct ScanProgress: Sendable { filesScanned: Int; bytesScanned: Int64; currentPath: String }`
  - `public struct ScanResult: Sendable { root: FileNode; inaccessible: [String]; duration: TimeInterval }`
  - `public final class DiskScanner: Sendable { init(options: ScanOptions); func scan(progress: @escaping @Sendable (ScanProgress) -> Void) async throws -> ScanResult }` — cancelable con `Task.cancel()`; `progress` como máximo cada 100 ms.
  - `public enum FileKindClassifier { static func kind(forFileNamed: String) -> ContentKind; static func kind(forDirectoryPath: String) -> ContentKind? }`

Enfoque: `opendir/readdir` + `lstat` (no seguir enlaces); tamaño `st_blocks * 512`; hard links con `st_nlink > 1` deduplicados por `(st_dev, st_ino)` en un conjunto protegido por lock; recorrido con `TaskGroup` de anchura `ProcessInfo.activeProcessorCount * 2`; no cruzar a otro `st_dev` distinto del de la raíz salvo que sea otra raíz. Al cerrar cada directorio: hijos `< pruneThreshold` se funden en un hijo agregado "Otros" (`aggregatedCount = n`), conservando `kindBytes`.

Clasificación por extensión: vídeo (`mp4 mov mkv avi m4v webm`), imágenes (`jpg jpeg png heic gif tiff raw cr2 psd webp`), código (`swift py js ts rs go java c cpp h json lock`), modelos IA (`gguf safetensors pt pth bin ckpt onnx mlmodel npz ort`), contenedores (`raw` dentro de `com.docker.docker`, `vmdk qcow2 img dmg iso`), documentos (`pdf doc docx xls xlsx ppt pptx key pages numbers txt md`). Por carpeta: `*.app` → apps, `node_modules`/`.git`/`.venv`/`target`/`.build` → code, `Caches`/`.cache`/`DerivedData` → caches, `huggingface`/`.ollama`/`whisper` → aiModels, `com.docker.docker` → containers, `/System` `/usr` `/private` `/Library` → system.

- [ ] **Step 1: Tests que fallan** (cada uno crea un árbol temporal con `FileManager` en `FileManager.default.temporaryDirectory`):
  - `sumsAllocatedSizes`: dos archivos de 3 MB ⇒ `root.allocatedSize` entre 6 MB y 6,1 MB.
  - `countsHardLinkOnce`: archivo de 5 MB + hard link ⇒ total < 5,1 MB.
  - `sparseFileUsesAllocatedSize`: `ftruncate` a 1 GB sin escribir ⇒ < 1 MB.
  - `skipsSymlinkLoops`: enlace `a/loop -> ..` ⇒ el escaneo termina y no hay nodo bajo `loop`.
  - `excludesSystemVolumesPrefix`: `excludedPrefixes` contiene la ruta de una subcarpeta ⇒ esa subcarpeta no aparece.
  - `unreadableDirectoryIsReportedNotFatal`: subcarpeta con `chmod 000` ⇒ `inaccessible` la contiene y el resultado incluye a sus hermanas.
  - `prunesSmallChildrenIntoAggregate`: 500 archivos de 1 KB + uno de 2 MB ⇒ 2 hijos, uno con `aggregatedCount == 500`.
  - `classifiesKinds`: `kind(forFileNamed: "peli.MOV") == .video`, `kind(forDirectoryPath: "/x/Foo.app") == .apps`, `kind(forFileNamed: "m.gguf") == .aiModels`.
- [ ] **Step 2:** `swift test --filter ScannerTests` → FAIL.
- [ ] **Step 3:** Implementar `FileKindClassifier` y `DiskScanner`.
- [ ] **Step 4:** `swift test --filter ScannerTests` → PASS.
- [ ] **Step 5: Comprobación real:** pequeño test manual desactivado por defecto (`@Test(.enabled(if: ProcessInfo.processInfo.environment["DISKMAP_REAL"] != nil))`) que escanea `~` e imprime tiempo y total. Ejecutar `DISKMAP_REAL=1 swift test --filter realHome -c release` → anota tiempo (objetivo: carpeta personal < 60 s en el M4 Pro).
- [ ] **Step 6:** `git commit -am "feat: escáner paralelo con tamaño real"`

---

### Task 3: Catálogo y política de riesgo

**Files:**
- Create: `Sources/DiskMapCore/Catalog/Catalog.swift`, `Sources/DiskMapCore/Catalog/RiskPolicy.swift`, `Sources/DiskMapCore/Resources/catalog.json`, `Tests/DiskMapCoreTests/CatalogTests.swift`

**Interfaces:**
- Produces:
  - `public struct CatalogEntry: Codable, Sendable, Identifiable { id: String; title: String; explanation: String; whoCreatesIt: String; regenerates: Bool; risk: Risk; kind: ContentKind; paths: [String]; cleanup: CleanupMethod; mustBeClosed: [String]; referenceCheck: String? }`
    - `paths`: patrones con `~` y `*` (p. ej. `~/.cache/codex-runtimes/codex-runtime-install-*`).
    - `mustBeClosed`: bundle IDs.
    - `referenceCheck`: cadena a buscar en proyectos, con `{name}` = nombre de la carpeta encontrada.
  - `public enum CleanupMethod: Codable, Sendable { case trash; case command(executable: String, arguments: [String], sizeProbe: [String]?); case info }` (`info` = solo se muestra, sin acción).
  - `public struct Catalog: Sendable { entries: [CatalogEntry]; static func bundled() throws -> Catalog; func match(path: String, home: String) -> CatalogEntry?; func entry(id: String) -> CatalogEntry? }`
  - `public enum RiskPolicy { static func minimumRisk(forPath: String, home: String) -> Risk; static func effectiveRisk(path: String, home: String, catalog: Risk?, ai: Risk?) -> Risk }` — `effectiveRisk` = el más estricto de los tres; sin catálogo ni IA ⇒ al menos `.yourCall`.

Entradas mínimas de `catalog.json` (explicaciones en español sencillo, una o dos frases):

| id | rutas / comando | riesgo | limpieza |
|---|---|---|---|
| `docker-build-cache` | `docker builder prune -a -f`; sonda `docker system df --format {{json .}}` (fila Build Cache, Reclaimable) | safe | command |
| `docker-volumes` | `docker system df` (Local Volumes) | doNotTouch | info |
| `docker-images` | `docker system df` (Images) | yourCall | info |
| `homebrew` | `brew cleanup --prune=all -s`; ruta `~/Library/Caches/Homebrew` | safe | command |
| `pip` | `pip3 cache purge`; `~/Library/Caches/pip` | safe | command |
| `uv` | `uv cache clean`; `~/.cache/uv` | safe | command |
| `pnpm` | `pnpm store prune`; `~/Library/pnpm/store` y `~/Library/Caches/pnpm` | safe | command |
| `npm` | `npm cache clean --force`; `~/.npm/_cacache` | safe | command |
| `cargo` | `~/.cargo/registry`, `~/.cargo/git` | safe | trash |
| `conda` | `conda clean --all -y` (ejecutable `~/anaconda3/bin/conda` o `~/miniconda3/bin/conda`); `~/anaconda3/pkgs` | safe | command |
| `huggingface-model` | `~/.cache/huggingface/hub/models--*`, `datasets--*`; referenceCheck `{name}` sin el prefijo `models--`, con `--` → `/` | yourCall | trash |
| `ollama-models` | `~/.ollama/models` | yourCall | info (en fase 1 se explica `ollama rm <modelo>`) |
| `whisper-cache` | `~/.cache/whisper` | yourCall | trash |
| `playwright` | `~/Library/Caches/ms-playwright` | safe | trash |
| `brave-cache` | `~/Library/Caches/BraveSoftware`, `~/Library/Caches/com.brave.Browser`; mustBeClosed `com.brave.Browser` | safe | trash |
| `chrome-cache` | `~/Library/Caches/Google/Chrome`; mustBeClosed `com.google.Chrome` | safe | trash |
| `safari-cache` | `~/Library/Caches/com.apple.Safari`; mustBeClosed `com.apple.Safari` | safe | trash |
| `spotify-cache` | `~/Library/Caches/com.spotify.client`; mustBeClosed `com.spotify.client` | safe | trash |
| `xcode-deriveddata` | `~/Library/Developer/Xcode/DerivedData` | safe | trash |
| `xcode-simulators` | `xcrun simctl delete unavailable` | safe | command |
| `user-logs` | `~/Library/Logs/*` | safe | trash |
| `codex-stale-installs` | `~/.cache/codex-runtimes/codex-runtime-install-*` | safe | trash |
| `codex-runtime` | `~/.cache/codex-runtimes/codex-primary-runtime` | doNotTouch | info |
| `claude-vm` | `~/Library/Application Support/Claude/vm_bundles`; mustBeClosed `com.anthropic.claudefordesktop` | yourCall | trash |
| `time-machine-snapshots` | sonda `tmutil listlocalsnapshots /` | yourCall | command `tmutil thinlocalsnapshots / 999999999999 4` |

- [ ] **Step 1: Tests que fallan:**
  - `bundledCatalogLoads`: `Catalog.bundled().entries.count >= 25`, ids únicos y todas las explicaciones no vacías.
  - `matchesGlob`: `match(path: home+"/.cache/codex-runtimes/codex-runtime-install-ab12", home:)?.id == "codex-stale-installs"`.
  - `primaryRuntimeIsNotStale`: `match(path: home+"/.cache/codex-runtimes/codex-primary-runtime")?.id == "codex-runtime"`.
  - `personalFoldersNeverSafe`: `effectiveRisk(path: home+"/Documents/x", catalog: .safe, ai: .safe) == .yourCall`.
  - `aiCannotLowerRisk`: `effectiveRisk(path: home+"/.ollama/models", catalog: .yourCall, ai: .safe) == .yourCall`.
  - `systemIsDoNotTouch`: `minimumRisk(forPath: "/System/Library", home:) == .doNotTouch`.
  - `unknownDefaultsToYourCall`: `effectiveRisk(path: "/opt/x", catalog: nil, ai: nil) == .yourCall`.
- [ ] **Step 2:** `swift test --filter CatalogTests` → FAIL.
- [ ] **Step 3:** Implementar y escribir `catalog.json` con todas las entradas de la tabla.
- [ ] **Step 4:** `swift test --filter CatalogTests` → PASS.
- [ ] **Step 5:** `git commit -am "feat: catálogo de rutas conocidas y política de riesgo"`

---

### Task 4: Treemap

**Files:**
- Create: `Sources/DiskMapCore/Layout/Treemap.swift`, `Tests/DiskMapCoreTests/TreemapTests.swift`

**Interfaces:**
- Produces:
  - `public struct TreemapTile: Sendable, Identifiable { id: Int; rect: CGRect; node: FileNode? ; othersCount: Int }` (`node == nil` ⇒ tesela "Otros (N elementos)").
  - `public enum Treemap { static func squarify(values: [Double], in rect: CGRect) -> [CGRect]; static func tiles(for node: FileNode, in rect: CGRect, gap: CGFloat = 2, minTileArea: CGFloat = 36) -> [TreemapTile] }`
  - `tiles` ordena hijos por tamaño, agrupa en una tesela "Otros" los que caerían por debajo de `minTileArea`, aplica `squarify` (Bruls et al.) e inserta `gap`.

- [ ] **Step 1: Tests que fallan:**
  - `areasAreProportional`: valores `[6,6,4,3,2,2,1]` en 600×400 ⇒ área de cada rect / área total = valor / suma (tolerancia 0,5 %).
  - `rectsStayInsideAndDontOverlap`: 200 valores aleatorios con semilla fija ⇒ todos dentro del rect y sin intersecciones de área > 0,01.
  - `aspectRatiosAreSquarish`: los mismos 7 valores ⇒ peor relación de aspecto < 3.
  - `groupsTinyEntriesIntoOthers`: nodo con 1 hijo de 1 GB y 5.000 hijos de 1 KB en 800×600 ⇒ ≤ 2 teselas y una con `othersCount == 5000`.
  - `emptyNodeGivesNoTiles`.
- [ ] **Step 2:** `swift test --filter TreemapTests` → FAIL.
- [ ] **Step 3:** Implementar.
- [ ] **Step 4:** `swift test --filter TreemapTests` → PASS.
- [ ] **Step 5:** `git commit -am "feat: treemap squarified"`

---

### Task 5: Persistencia del índice e historial

**Files:**
- Create: `Sources/DiskMapCore/Persistence/IndexStore.swift`, `Tests/DiskMapCoreTests/IndexStoreTests.swift`

**Interfaces:**
- Consumes: `ScanResult`, `FileNode`.
- Produces:
  - `public struct CleanupRecord: Codable, Sendable { date: Date; title: String; bytes: Int64; wentToTrash: Bool }`
  - `public final class IndexStore: Sendable { init(directory: URL); func saveScan(_: ScanResult) throws; func loadScan() throws -> ScanResult?; func append(_: CleanupRecord) throws; func history() throws -> [CleanupRecord]; func totalFreed() throws -> Int64 }`
  - `totalFreed` suma solo registros con `wentToTrash == false` más los vaciados de Papelera (que se registran como `wentToTrash == false`).

Formato: árbol aplanado en arrays paralelos (`parentIndex`, `name`, `size`, `kind`, `kindBytes`, `mtime`, `aggregatedCount`) con `PropertyListEncoder` binario y escritura atómica en `scan.plist`; historial en `history.json`.

- [ ] **Step 1: Tests que fallan:**
  - `roundTripsTree`: árbol de 3 niveles ⇒ tras guardar y cargar, rutas, tamaños y `kindBytes` iguales.
  - `missingIndexReturnsNil`.
  - `corruptIndexReturnsNilAndIsRemoved`: escribir basura en `scan.plist` ⇒ `loadScan() == nil` y el archivo ya no existe.
  - `totalFreedIgnoresTrashPending`: registros 1 GB (trash) + 2 GB (comando) ⇒ `totalFreed() == 2 GB`.
- [ ] **Step 2:** FAIL → **Step 3:** implementar → **Step 4:** PASS.
- [ ] **Step 5:** `git commit -am "feat: índice persistente e historial de limpiezas"`

---

### Task 6: Sistema, detección y ejecución de limpieza

**Files:**
- Create: `Sources/DiskMapCore/System/CommandRunner.swift`, `Sources/DiskMapCore/System/SystemProbes.swift`, `Sources/DiskMapCore/Cleanup/CleanupScanner.swift`, `Sources/DiskMapCore/Cleanup/CleanupExecutor.swift`, `Sources/DiskMapCore/Cleanup/ReferenceChecker.swift`, `Tests/DiskMapCoreTests/CleanupTests.swift`

**Interfaces:**
- Consumes: `Catalog`, `CatalogEntry`, `CleanupMethod`, `RiskPolicy`, `IndexStore`, `FileNode`.
- Produces:
  - `public struct CommandOutput: Sendable { status: Int32; stdout: String; stderr: String }`
  - `public protocol CommandRunning: Sendable { func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) async throws -> CommandOutput; func resolve(_ executable: String) async -> String? }`
  - `public struct ProcessRunner: CommandRunning`. `resolve` usa el PATH de la shell de login (`/bin/zsh -lc 'printf %s "$PATH"'`, en caché), porque las apps GUI tienen un PATH mínimo. Ejecuta `Process` con array de argumentos y mata el proceso al pasar el `timeout`.
  - `public protocol SystemProbing: Sendable { func runningBundleIDs() -> Set<String>; func hasFullDiskAccess() -> Bool; func trashSize() -> Int64; func emptyTrash() throws -> Int64; func localSnapshots() async -> [String] }`
    - `hasFullDiskAccess`: se intenta listar `~/Library/Containers/com.apple.stocks` o `~/Library/Safari`; si da `EPERM`, no hay acceso.
    - `emptyTrash`: `removeItem` de cada elemento de `~/.Trash`; si no hay permiso, recurre a AppleScript de Finder (`empty trash`).
  - `public struct CleanupItem: Sendable, Identifiable { id: String; entry: CatalogEntry; paths: [String]; bytes: Int64; risk: Risk; blockedByOpenApps: [String]; usedBy: [String] }`
  - `public struct CleanupScanner { init(catalog:, runner:, probes:, references:, home:); func findItems(scan: FileNode?) async -> [CleanupItem] }` — tamaño desde el índice si la ruta está en él, si no `lstat` recursivo de la ruta; para `command` con `sizeProbe`, se parsea su salida; omite elementos de 0 bytes; si `usedBy` no está vacío, el riesgo sube a `.doNotTouch`.
  - `public struct ReferenceChecker: Sendable { init(roots: [String]); func references(to needle: String, timeout: TimeInterval) async -> [String] }` — busca en archivos de texto < 1 MB bajo `~/Desktop`, `~/Documents`, `~/Projects`, `~/orca` (si existen), excluyendo `node_modules .git .venv venv .build target Library`. Límite de 10 s; devuelve rutas.
  - `public enum CleanupOutcome: Sendable { case freed(Int64), movedToTrash(Int64), blocked(reason: String), failed(String) }`
  - `public struct CleanupExecutor { init(runner:, probes:, store:); func execute(_ item: CleanupItem) async -> CleanupOutcome; func emptyTrash() async -> CleanupOutcome; func trashPaths(_ paths: [String], title: String) async -> CleanupOutcome }`
    - Rechaza (`blocked`) si hay apps abiertas de `mustBeClosed`, si el riesgo es `.doNotTouch` o si el método es `info`.
    - Para `command`, mide el espacio libre del volumen antes y después (`volumeAvailableCapacityForImportantUsage`) y devuelve `freed(diferencia)`.
    - Registra un `CleanupRecord` por cada ejecución.
    - Rutas que requieren administrador: `osascript -e 'do shell script "rm -f <ruta escapada con quoted form>" with administrator privileges'`, solo para enlaces rotos fuera de `$HOME`.

- [ ] **Step 1: Tests que fallan**, con `FakeRunner` (registra llamadas y devuelve salidas fijadas) y `FakeProbes`:
  - `commandArgumentsAreNotShellInterpolated`: ejecutar `uv` con `FakeRunner` ⇒ llamada registrada `("/opt/homebrew/bin/uv", ["cache","clean"])`.
  - `blocksWhenAppOpen`: entrada de Spotify con `runningBundleIDs = ["com.spotify.client"]` ⇒ `.blocked` y la carpeta sigue existiendo.
  - `trashMovesNotDeletes`: carpeta temporal ⇒ `movedToTrash(n)` con n > 0, la ruta original ya no existe y no hay `freed`.
  - `doNotTouchIsNeverExecuted`: elemento con `.doNotTouch` ⇒ `.blocked`, cero llamadas al runner.
  - `infoMethodIsNeverExecuted`.
  - `dockerProbeParsesReclaimable`: salida JSON de `docker system df` con Build Cache `"Reclaimable":"29.89GB"` ⇒ `bytes ≈ 29_890_000_000`.
  - `missingToolSkipsItem`: `resolve("uv") == nil` ⇒ no aparece `uv`.
  - `referencedModelEscalatesRisk`: `ReferenceChecker` encuentra `mlx-community/whisper-small-mlx` en un `config.toml` temporal ⇒ el elemento HF tiene `risk == .doNotTouch` y `usedBy` no vacío.
  - `recordsHistory`: tras `execute` de un comando ⇒ `store.history().count == 1`.
- [ ] **Step 2:** `swift test --filter CleanupTests` → FAIL.
- [ ] **Step 3:** Implementar.
- [ ] **Step 4:** `swift test --filter CleanupTests` → PASS.
- [ ] **Step 5:** `git commit -am "feat: detección y ejecución segura de limpiezas"`

---

### Task 7: Asistente IA (informe y chat)

**Files:**
- Create: `Sources/DiskMapCore/AI/ClaudeLocator.swift`, `Sources/DiskMapCore/AI/AIContextBuilder.swift`, `Sources/DiskMapCore/AI/AIAssistant.swift`, `Tests/DiskMapCoreTests/AITests.swift`

**Interfaces:**
- Consumes: `CommandRunning`, `FileNode`, `CleanupItem`, `Catalog`, `RiskPolicy`.
- Produces:
  - `public enum ClaudeLocator { static func candidates(home: String) -> [String]; static func locate(override: String?, runner: CommandRunning) async -> String? }`
    - Candidatos en orden: `override`, `~/.local/bin/claude`, `~/.claude/local/claude`, `/opt/homebrew/bin/claude`, `/usr/local/bin/claude`, `~/.npm-global/bin/claude`.
    - Se aceptan si `--version` contiene "Claude Code" y el archivo no contiene `cmux-claude-wrapper`.
  - `public enum AIContextBuilder { static func context(scan: FileNode?, items: [CleanupItem], catalog: Catalog, home: String, maxNodes: Int = 400) -> String }`
    - JSON con: disco (total/libre), los `maxNodes` nodos más grandes hasta profundidad 6 (ruta con `~`, bytes, tipo, último cambio, id de catálogo si coincide) y los elementos de limpieza.
    - Solo metadatos.
  - `public struct AIRecommendation: Codable, Sendable, Identifiable { id: String; path: String; verdict: Risk; reason: String; bytes: Int64; action: AIAction? }`
  - `public enum AIAction: Codable, Sendable { case trash(path: String); case runCatalogCommand(id: String) }`
  - `public struct AIReport: Codable, Sendable { summary: String; recommendations: [AIRecommendation]; reclaimableBytes: Int64 }`
  - `public enum AIError: Error { case notInstalled, timedOut, invalidResponse(String), failed(String) }`
  - `public struct AIAssistant { init(claudePath:, runner:, catalog:, home:); func report(context: String) async throws -> AIReport; func chat(history: [ChatMessage], context: String) -> AsyncThrowingStream<String, Error> }`
  - `public struct ChatMessage: Codable, Sendable { role: Role; text: String }`, con `enum Role { user, assistant }`.

Invocación (argumentos exactos):
- Base: `-p --tools "" --strict-mcp-config --disable-slash-commands --no-session-persistence --system-prompt <prompt>`.
- Informe: base + `--output-format json --json-schema <esquema de AIReport>`; leer `structured_output` del JSON de resultado.
- Chat: base + `--output-format stream-json --verbose --include-partial-messages`; emitir el texto de los `content_block_delta`; enviar el historial completo en cada turno.
- Prompt por `stdin`. Timeout de 120 s.

Prompt de sistema (español): es el asistente de DiskMap; solo ve metadatos; clasifica en `safe/yourCall/doNotTouch`; nunca recomienda borrar archivos personales, volúmenes de Docker ni nada de `/System`; las acciones solo pueden ser `trash` de una ruta presente en el contexto o `runCatalogCommand` con un id del catálogo; explica en lenguaje sencillo, como a alguien no técnico.

Post-validación del informe, siempre en código:
- Se descartan recomendaciones cuya ruta no esté en el contexto.
- Se descartan acciones con un id que no exista en el catálogo.
- `verdict = RiskPolicy.effectiveRisk(path:, catalog:, ai: verdict)`.
- Si `verdict != .safe`, se elimina la `action` de `trash`. Queda disponible tras confirmación explícita en la UI solo para `.yourCall`.

- [ ] **Step 1: Tests que fallan** (con `FakeRunner` que devuelve JSON fijado):
  - `locatorSkipsCmuxShim`: candidato cuyo contenido contiene `cmux-claude-wrapper` ⇒ se descarta.
  - `invokesWithoutTools`: los argumentos de `report` contienen `"--tools"` seguido de `""` y `"--json-schema"`.
  - `contextHasNoFileContents`: archivo temporal con texto "SECRETO" ⇒ el contexto no contiene "SECRETO" y sí contiene su ruta.
  - `contextKeepsUnicodePaths`: carpeta `Música/diseño ñ` ⇒ aparece intacta en el JSON y este se puede parsear.
  - `contextIsBounded`: 10.000 nodos ⇒ como máximo 400 en el contexto.
  - `reportDropsUnknownPaths` y `reportDropsUnknownCatalogIds`.
  - `reportCannotLowerRisk`: la IA dice `safe` para `~/Documents/a.pdf` ⇒ `yourCall` y sin acción.
  - `reportFailsGracefullyOnInvalidJSON`: salida `"hola"` ⇒ `AIError.invalidResponse`.
  - `reportTimesOut`: el runner lanza un timeout ⇒ `AIError.timedOut`.
  - `chatStreamsDeltas`: tres líneas `stream-json` con deltas "Ho", "la", "!" ⇒ el stream emite esas tres cadenas.
- [ ] **Step 2:** `swift test --filter AITests` → FAIL.
- [ ] **Step 3:** Implementar.
- [ ] **Step 4:** `swift test --filter AITests` → PASS.
- [ ] **Step 5: Prueba real opcional:** `DISKMAP_REAL=1 swift test --filter realClaudeReport` con un contexto pequeño ⇒ devuelve un `AIReport` válido.
- [ ] **Step 6:** `git commit -am "feat: asistente IA con informe y chat seguros"`

---

### Task 8: Esqueleto de la app, estado y diseño

**Files:**
- Create: `Sources/DiskMap/DiskMapApp.swift` (sustituye la ventana vacía), `Sources/DiskMap/AppModel.swift`, `Sources/DiskMap/Design/Theme.swift`, `Sources/DiskMap/Design/Components.swift`, `Sources/DiskMap/Shell/RootView.swift`, `Sources/DiskMap/Shell/Sidebar.swift`, `Sources/DiskMap/Shell/FullDiskAccessBanner.swift`, `Sources/DiskMap/Shell/ScanProgressView.swift`, `Tests/DiskMapCoreTests/AppModelTests.swift` (el modelo de navegación vive en `DiskMapCore/UIState/MapNavigation.swift` para poder probarlo)

**Interfaces:**
- Consumes: todo `DiskMapCore`.
- Produces:
  - `@MainActor @Observable final class AppModel` con:
    - `section: Section` (`.map, .cleanup, .assistant`, más `.uninstaller, .largeOld, .duplicates, .types` deshabilitadas).
    - `scan: ScanResult?`, `progress: ScanProgress?`, `isScanning`, `cleanupItems: [CleanupItem]`, `trashBytes: Int64`, `totalFreed: Int64`, `hasFullDiskAccess: Bool`, `navigation: MapNavigation`.
    - `func startScan()`: carga primero el índice, luego reanaliza en segundo plano y guarda.
    - `func refreshCleanup()`, `func perform(_ item: CleanupItem) async -> CleanupOutcome`, `func emptyTrash() async`.
  - `public struct MapNavigation: Sendable { private(set) var stack: [FileNode]; var current: FileNode?; mutating func zoom(into: FileNode); mutating func zoomOut(); mutating func jump(to index: Int); var breadcrumb: [String] }`
  - `Theme`: colores de `ContentKind` (valores de Global Constraints), `Theme.zoomSpring`, `Theme.stagger(index:)`.
  - `Components`: `GlassCard`, `RiskBadge`, `BytesCounter` (número que cuenta hacia arriba con `contentTransition(.numericText())`), `PrimaryButton`.

Ventana:
- `NavigationSplitView` con barra lateral `.sidebar` translúcida, `.windowStyle(.hiddenTitleBar)`, tamaño mínimo 1100×720.
- La barra lateral muestra al pie una tarjeta del disco con:
  - Anillo de uso que distingue "Tus archivos", "Sistema y purgable" (total − libre − analizado; libre según `volumeAvailableCapacityForImportantUsageKey`) y "Libre".
  - "En la Papelera: X GB" y botón "Vaciar Papelera".
  - "Liberado en total: X".
- Encima, un selector de disco: "Macintosh HD" por defecto, más los volúmenes externos de `FileManager.mountedVolumeURLs(includingResourceValuesForKeys:options: [.skipHiddenVolumes])` que no sean de solo lectura. Al elegir uno se lanza `startScan()` con ese volumen como `root`; `AppModel.selectedVolume: URL`.
- Banner de Acceso total al disco con botón que abre `x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles`.
- Progreso del análisis: anillo animado + contador de archivos y GB + ruta actual en monoespaciada atenuada.

- [ ] **Step 1: Tests que fallan** para `MapNavigation`:
  - `zoomPushesAndBreadcrumb`: zoom a `Users` y luego a `ana` ⇒ `breadcrumb == ["Macintosh HD","Users","ana"]`.
  - `zoomOutAtRootIsNoop`.
  - `jumpTruncatesStack`: `jump(to: 0)` ⇒ `current` es la raíz.
- [ ] **Step 2:** FAIL → **Step 3:** implementar `MapNavigation`, `AppModel`, tema, componentes y estructura de la ventana → **Step 4:** PASS.
- [ ] **Step 5: Verificar a mano:** `swift run DiskMap`.
  - Se abre la ventana con la barra lateral y las secciones de la fase 2 en gris con "Próximamente".
  - Arranca el análisis con progreso animado.
  - Captura con `screencapture -l $(osascript -e 'tell app "DiskMap" to id of window 1') shot.png` o `screencapture -x`; revisar la imagen.
- [ ] **Step 6:** `git commit -am "feat: estructura de la app, tema y estado"`

---

### Task 9: Vista Mapa

**Files:**
- Create: `Sources/DiskMap/Map/MapView.swift`, `Sources/DiskMap/Map/TreemapCanvas.swift`, `Sources/DiskMap/Map/HoverCard.swift`, `Sources/DiskMap/Map/Breadcrumb.swift`, `Sources/DiskMap/Map/KindLegend.swift`

**Interfaces:**
- Consumes: `Treemap.tiles`, `MapNavigation`, `Catalog.match`, `RiskPolicy`, `Theme`, `AppModel`.

Comportamiento:
- **Dibujo:** `TreemapCanvas` dibuja con `Canvas` (+ `drawingGroup()`, que usa Metal).
  - Cada tesela es un rect redondeado (radio 8, o 4 si mide menos de 60 pt), con degradado del color del tipo (más claro arriba a la izquierda) y borde interior de 1 pt blanco al 12 %.
  - Texto (nombre + tamaño) solo si la tesela mide al menos 70×36.
  - La tesela "Otros" lleva un patrón rayado gris.
- **Entrada:** tras un análisis o un zoom, cada tesela aparece con escala 0,85→1 y opacidad 0→1, retrasada `Theme.stagger(index:)`. El orden de aparición va del centro hacia fuera.
- **Zoom:**
  - Al hacer clic, la tesela pulsada se interpola con `Theme.zoomSpring` desde su rect hasta todo el lienzo. Mientras tanto, las demás se desvanecen y se escalan respecto a ella. Después aparecen los hijos con la entrada escalonada.
  - Para salir: Esc, Cmd+[, gesto de deslizar con dos dedos o clic en la ruta de navegación. Es la animación inversa.
- **Al pasar el ratón:**
  - La tesela se ilumina (brillo +8 %, sombra) y sigue al ratón una `HoverCard` de cristal con: nombre, ruta, tamaño, porcentaje del padre, último cambio, tipo, insignia de riesgo y explicación del catálogo o "Pregúntale al asistente".
  - Clic derecho abre un menú: "Mostrar en Finder", "Explicar con IA" (abre el chat con la pregunta) y "Mover a la Papelera…" (solo si el riesgo no es `.doNotTouch`, con confirmación).
- **Leyenda:** `KindLegend` con chips por tipo que muestran los GB del nodo actual. Al pasar el ratón por un chip, se atenúan las teselas de otros tipos.
- **Rendimiento:** el layout se calcula fuera del hilo principal y se guarda en caché por nodo y tamaño.

- [ ] **Step 1:** Implementar las vistas.
- [ ] **Step 2: Verificar a mano** con `swift run -c release DiskMap` sobre el disco real:
  - Comprobar la entrada escalonada, el zoom de ida y vuelta, la ruta de navegación, la tarjeta al pasar el ratón con explicaciones y la leyenda.
  - Hacer capturas y revisarlas.
  - Comprobar que el zoom no da tirones: en Instruments no está disponible, así que se mide con un contador de FPS de depuración (`TimelineView(.animation)`) activable con la variable de entorno `DISKMAP_FPS=1`. Objetivo: ≥ 100 fps en el M4 Pro.
- [ ] **Step 3:** `git commit -am "feat: mapa de bloques animado"`

---

### Task 10: Vista Limpieza

**Files:**
- Create: `Sources/DiskMap/Cleanup/CleanupView.swift`, `Sources/DiskMap/Cleanup/CleanupRow.swift`, `Sources/DiskMap/Cleanup/ConfirmSheet.swift`, `Sources/DiskMap/Cleanup/FreedCelebration.swift`

**Interfaces:**
- Consumes: `AppModel.cleanupItems`, `AppModel.perform`, `AppModel.emptyTrash`, `CleanupOutcome`, `Theme`, `Components`.

Comportamiento:
- **Cabecera:** "Puedes liberar X" con `BytesCounter` (solo suma los elementos `.safe`) y botón "Limpiar todo lo seguro".
- **Grupos:** "Borrar sin riesgo", "Depende de ti" y "No tocar", con tarjetas `GlassCard`. Cada fila lleva icono SF Symbol por tipo, título, explicación, quién lo crea, si se regenera, tamaño, insignia de riesgo, casilla de selección y aviso si está bloqueada ("Cierra Spotify para limpiar esto", con botón "Cerrar Spotify" que usa `NSRunningApplication.terminate()`) o si la usa un proyecto ("Lo usa: …").
- Las filas `.doNotTouch` no tienen casilla.
- **Confirmación:** antes de ejecutar se abre una hoja con la lista de lo que se hará y el método ("A la Papelera" o "Comando oficial: `docker builder prune -a -f`").
- **Tras ejecutar:**
  - Si se liberó espacio: celebración sobria (anillo que se llena + `BytesCounter` + partículas suaves durante 1,2 s) y la fila se colapsa con muelle.
  - Si fue a la Papelera: se actualiza "En la Papelera".
- **Vaciar Papelera:** desde la tarjeta de la barra lateral, con confirmación. Si después el espacio libre del volumen no sube ≥ 80 % de lo esperado y `localSnapshots()` no está vacío, se muestra un aviso explicando las instantáneas de Time Machine y ofreciendo la entrada `time-machine-snapshots`.

- [ ] **Step 1:** Implementar las vistas.
- [ ] **Step 2: Verificar a mano:**
  - Crear la carpeta falsa `~/Library/Logs/DiskMapPrueba` con un archivo de 50 MB. Debe aparecer en "Borrar sin riesgo" (`user-logs`). Al limpiarla debe ir a la Papelera y actualizarse el contador.
  - Abrir Spotify ⇒ su fila aparece bloqueada.
  - Capturas.
- [ ] **Step 3:** `git commit -am "feat: sección de limpieza con borrado seguro"`

---

### Task 11: Vista Asistente IA

**Files:**
- Create: `Sources/DiskMap/Assistant/AssistantView.swift`, `Sources/DiskMap/Assistant/ReportView.swift`, `Sources/DiskMap/Assistant/ChatView.swift`, `Sources/DiskMap/Assistant/ClaudeMissingView.swift`

**Interfaces:**
- Consumes: `AIAssistant`, `AIContextBuilder`, `ClaudeLocator`, `AIReport`, `AIAction`, `AppModel`.

Comportamiento:
- **Selector:** segmentado entre "Informe" y "Chat".
- **Informe:**
  - Botón "Analizar con IA". Mientras trabaja se muestra un brillo animado (gradiente que recorre unas tarjetas de esqueleto).
  - El resultado aparece con entrada escalonada en las tres columnas de riesgo. Arriba, el resumen y "Recuperable: X".
  - Cada recomendación tiene el botón de su acción, que pasa por la misma `ConfirmSheet` y por `AppModel.perform` o `trashPaths`.
- **Chat:**
  - Burbujas estilo Mensajes. El texto entra en streaming con un cursor parpadeante.
  - Sugerencias iniciales en chips: "¿Qué ocupa más?", "¿Qué puedo borrar sin riesgo?", "¿Qué es ~/Library/Containers?".
  - Cuando la respuesta menciona una ruta del contexto, esta aparece como chip con botón "Ver en el mapa", que cambia a `.map` y hace zoom a esa ruta.
- **Sin Claude:** `ClaudeMissingView` explica en una frase que hace falta Claude Code y ofrece "Elegir ejecutable…" (con `NSOpenPanel`; se guarda en `UserDefaults` como `claudePath`).
- **Errores:** tarjeta con mensaje claro y botón "Reintentar".

- [ ] **Step 1:** Implementar las vistas.
- [ ] **Step 2: Verificar a mano** con el disco real:
  - Generar el informe. Comprobar que nada personal aparece como "sin riesgo" y que los volúmenes de Docker salen en "No tocar".
  - Hacer dos preguntas en el chat.
  - Renombrar temporalmente `claudePath` a una ruta inexistente ⇒ aparece `ClaudeMissingView`.
  - Capturas.
- [ ] **Step 3:** `git commit -am "feat: asistente IA con informe y chat"`

---

### Task 12: Icono, empaquetado y firma estable

**Files:**
- Create: `scripts/make-icon.swift`, `scripts/build-app.sh`, `Resources/Info.plist`

**Interfaces:**
- Consumes: el ejecutable `DiskMap` en modo release.

Detalles:
- **`make-icon.swift`:** dibuja con CoreGraphics un PNG de 1024×1024.
  - Forma: squircle de macOS (margen 100 px, radio continuo ≈ 185 px).
  - Fondo: degradado profundo `#1C1C2E`→`#0B0B12`, con brillo especular sutil arriba.
  - Dentro: un treemap de 6 bloques redondeados con los colores de vídeo, código, apps, modelos IA, cachés y documentos, con degradados y una sombra interior que dé profundidad.
  - Después genera con `sips` los tamaños 16, 32, 64, 128, 256, 512 y 1024 (@1x/@2x) en `DiskMap.iconset` y ejecuta `iconutil -c icns`.
- **`Info.plist`:**
  - `CFBundleIdentifier` `local.diskmap.DiskMap`, `CFBundleName` y `CFBundleDisplayName` `DiskMap`, `CFBundleIconFile` `DiskMap`.
  - `LSMinimumSystemVersion` `15.0`, `NSHighResolutionCapable` true, `LSApplicationCategoryType` `public.app-category.utilities`.
  - `NSAppleEventsUsageDescription`: "DiskMap usa Finder para vaciar la Papelera."
- **`build-app.sh`:**
  1. `swift build -c release`.
  2. Montar `build/DiskMap.app/Contents/{MacOS,Resources}` y copiar el binario, `Info.plist`, `DiskMap.icns` y el bundle de recursos de SwiftPM (`DiskMap_DiskMapCore.bundle`).
  3. Firmar. Si no existe la identidad `DiskMap Local Signing` en `security find-identity -p codesigning`, se crea una sola vez: `openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=DiskMap Local Signing" -addext "extendedKeyUsage=codeSigning" -addext "keyUsage=digitalSignature"`, exportar a `.p12`, `security import … -k ~/Library/Keychains/login.keychain-db -T /usr/bin/codesign` y `security add-trusted-cert -r trustRoot -p codeSign` (pide la contraseña del usuario, que debe estar avisado).
  4. `codesign --force --deep --options runtime -s "DiskMap Local Signing" build/DiskMap.app`. Si falla, usar `codesign -s -` y mostrar el aviso "Firma ad-hoc: tendrás que volver a dar Acceso total al disco tras cada compilación".
  5. Opción `--install`: copia a `/Applications/DiskMap.app` (pidiendo confirmación si ya existe).

- [ ] **Step 1:** Escribir `make-icon.swift` y ejecutarlo con `swift scripts/make-icon.swift Resources/`. Abrir `Resources/DiskMap-1024.png` con Read y revisar que se ve bien a 1024 y a 32 px.
- [ ] **Step 2:** Escribir `Info.plist` y `build-app.sh`.
- [ ] **Step 3:** `bash scripts/build-app.sh`. Esperado: `build/DiskMap.app` existe, `codesign -dv build/DiskMap.app` muestra `Authority=DiskMap Local Signing` y `open build/DiskMap.app` abre la app con su icono en el Dock.
- [ ] **Step 4:** Recompilar y comprobar que la firma sigue siendo la misma identidad (el permiso de Acceso total al disco se conserva).
- [ ] **Step 5:** `git add -A && git commit -m "feat: icono propio y empaquetado firmado"`

---

### Task 13: Verificación final de la fase 1

- [ ] **Step 1:** `swift test` → todo en verde (anotar el número de tests).
- [ ] **Step 2:** Instalar con `bash scripts/build-app.sh --install` y dar Acceso total al disco a DiskMap.
- [ ] **Step 3:** Análisis completo del disco. Anotar:
  - Duración.
  - RAM en reposo tras el análisis (`ps -o rss= -p $(pgrep -x DiskMap)`). Objetivo < 300 MB.
  - Tamaño del `.app`.
  - Total analizado frente a `df` del volumen de datos: diferencia < 5 %, explicando la diferencia (sistema/purgable).
- [ ] **Step 4:** Repasar uno por uno los anti-objetivos del spec (§4) en la app real y dejar constancia en `docs/superpowers/plans/2026-10-20-diskmap-fase-1-verificacion.md` con capturas.
- [ ] **Step 5:** `git add -A && git commit -m "docs: verificación de la fase 1"`
