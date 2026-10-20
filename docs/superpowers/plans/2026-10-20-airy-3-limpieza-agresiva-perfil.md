# Airy 3 de 5 — Limpieza agresiva y perfil · Plan de implementación

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Limpieza pasa a ser agresiva por defecto, con muchos objetivos nuevos (prunes de Docker, cachés de Node, Python, Xcode y otras herramientas de desarrollo, proyectos viejos, instaladores, navegadores Chromium, cachés de apps, versiones antiguas de agentes, «Solo revisar»). Las tres etiquetas «Sin problema / Tú decides / No borrar» aparecen en Limpieza y en el Mapa. La selección es múltiple, con «Borrar todo» y **una sola** confirmación. Un perfil «¿Cómo usas tu Mac?» ordena, destaca y preselecciona, y **nunca** baja un riesgo.

**Architecture:** todo lo que decide vive en `DiskMapCore`, así que app y `airy-mcp` clasifican igual:
- **Catálogo y fuentes.** El catálogo (JSON) gana campos opcionales. Hay un único punto de extensión, `CleanupTargets.source(for:)`. El escáner lo usa para **descubrir** elementos y el embudo de borrado del plan 1 lo usa para **revalidarlos** justo antes de actuar. No se duplica ninguna regla.
- **Riesgo.** El riesgo sigue saliendo solo de `RiskClassifier` (plan 1, ampliado sin bifurcarlo).
- **Interfaz.** La app solo pinta `CleanupBoard` y `RiskExplanation`, que son lógica pura y se prueban sin SwiftUI.

**Tech Stack:** Swift 6.4 (solo Command Line Tools), SwiftPM, SwiftUI + AppKit, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-10-20-airy-fase-2-design.md` (§2.3, §2.4, §2.5, §2.9 «Más objetivos de limpieza», «Decisiones de Claude tras la revisión del constructor»), `docs/superpowers/specs/2026-10-20-diskmap-design.md` (§4 anti-objetivos). Listas de rutas (solo ideas): `docs/superpowers/research/2026-10-20-mole-inspiracion.md` §2.3–2.14, §5.3, §6. Interfaces que se consumen: `docs/superpowers/plans/2026-10-20-airy-1-identidad-seguridad-mcp.md` y sus resoluciones en `.superpowers/sdd/2026-10-20-airy-1-identidad-seguridad-mcp/progress.md` (F1–F15). Tema y animaciones: `docs/superpowers/plans/2026-10-20-airy-2-marca-animaciones.md` (`Theme.Airy` con `riskInk(_:)`/`riskFill(_:)`, `RiskBadge(risk:compact:reason:)` que ya muestra `Risk.label`, `AnyTransition.leafAway`, `CleanupFlow.gust`/`batchFreed`).

**Fuera de este plan:** crear animaciones (plan 2; aquí solo se usan `.leafAway` en las filas que se van y la ráfaga `CleanupFlow.gust`, que el plan 2 dispara sola en tandas de ≥ 2); Rendimiento (plan 4); Desinstalador, huérfanos y demás secciones (plan 5).

## Global Constraints

- Swift 6.4, SwiftPM, solo Command Line Tools; `swift build` / `swift test`; `.macOS(.v15)`; el test target conserva las `unsafeFlags` del plugin de Swift Testing.
- Vistas con el alias `@ViewState` (no `@State`); **nunca** `.fixedSize(horizontal:false,vertical:true)` en `Text` multilínea en código nuevo o tocado (usar `.lineLimit(nil)` y ancho del contenedor); patrones existentes (`Theme`, `PrimaryButton`, `SectionHeader`, `GlassCard`) y los nombres del plan 2 (`Theme.Airy`, `RiskBadge(risk:compact:reason:)`, `.leafAway`); texto en color de riesgo con `Theme.Airy.riskInk(_:)`.
- Interfaz en **español de España**; nombres de herramientas y campos MCP en inglés.
- **Nunca** se envía contenido de archivos a la IA ni al MCP: solo rutas, tamaños, fechas, tipos, nombres de contenedores/redes y fichas del catálogo. Leer listados (`zipinfo -1`, `git ls-files`, `PRAGMA freelist_count`) es local y no sale de Airy.
- Ubicaciones protegidas, nunca borrables: volúmenes de Docker, iCloud, Mail, Mensajes, Llaveros, AddressBook, Calendarios, Fotos, `/Applications`, `/Library`, `/usr`, `/bin`, `/sbin`, `/private`, `/opt/homebrew`, `/System`; las carpetas personales nunca son verdes; los runtimes en uso nunca se tocan.
- Toda acción destructiva pasa por `ConfirmSheet` → `AppModel` → `CleanupExecutor` (embudo del plan 1). Sin atajos DEBUG que actúen sin confirmación: los pasos DEBUG nuevos solo abren hojas.
- La IA y el perfil **solo suben** el riesgo. El perfil reordena, destaca y preselecciona, y nunca cambia `risk`.
- El MCP solo ejecuta lo verde no bloqueado. Nunca ámbar ni rojo. Con el interruptor apagado, toda acción queda bloqueada.
- Archivos → Papelera (`trashItem`, solo en el embudo); cachés de herramientas → su comando oficial con **array de argumentos** (nunca cadena de shell, nunca `sh -c`). **Nunca** `docker volume prune` ni `--volumes` (también se rechaza en el embudo).
- En pruebas y verificación nunca se ejecutan comandos de limpieza reales ni se vacía la Papelera real. Se usan `FakeRunner` / `FakeProbes` / `FakeListing` y carpetas temporales con `AIRY_SUPPORT_DIR` propio. Contra el sistema real solo se permiten lectura y `dry_run: true`.
- Capturas DEBUG solo de ventanas propias; parar la app matando **solo su PID** (nunca `pkill -x`); no tocar la confianza del Llavero.
- Mole es GPL-3.0: se adaptan ideas y listas de rutas, **nunca código**.
- Cero CPU en reposo: los paseos por disco solo se hacen durante una detección o justo antes de actuar, siempre con presupuesto de tiempo; respetar «Reducir movimiento».
- Commits terminan con `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

1. **Docker se para entre la detección y «Borrar todo»** → cada fila de Docker termina «bloqueada: Abre Docker Desktop para limpiar esto» (no «falló»), sin ejecutar nada, y el resto de la tanda sigue. Test en Task 2 (`daemonStoppedAfterDetectionBlocksAtAct`).
2. **El usuario edita un archivo del proyecto «viejo» después de la detección** → el `node_modules` ya no se toca al confirmar. Test en Task 4 (`projectTouchedAfterDetectionIsRefused`).
3. **`node_modules` o `target` es un enlace simbólico (pnpm, monorepos, enlace a `~/Documents`)** → no se recorre ni se ofrece. Lo que hay detrás nunca se mide ni se borra. Test en Task 4 (`symlinkedArtifactIsNeitherWalkedNorOffered`).
4. **La misma ruta encaja en dos fichas** (un `.dmg` viejo en Descargas es «instalador» y «descarga vieja»; una caché de Chrome la ve también la heurística de Application Support) → aparece en una sola fila y no se cuenta dos veces en «Borrar todo · X GB». Test en Task 1 (`samePathNeverInTwoItems`).
5. **Falta el enlace de la versión activa de un agente** (`~/.local/bin/claude` roto o ausente), o hay una sesión antigua aún en marcha → no se ofrece ni se borra ninguna versión. Test en Task 5 (`missingActiveLinkOffersNothing`, `runningOldVersionIsRefused`).

## Rulings de este plan (decisiones del redactor; el controlador las confirma con el usuario si no está de acuerdo)

- **R1 — Sistema con contraseña de administrador (§2.9 #15).** `/Library/Logs/DiagnosticReports`, `/private/var/log`, `/Library/Caches` e «Instalar macOS *.app» quedan como **«Solo revisar»** (ámbar, sin botón). Motivo: `/Library`, `/private` y `/Applications` son protecciones duras de la Global Constraint, y la fase 1 prohíbe privilegios de administrador. La única vía sería una cadena de shell con `osascript … with administrator privileges`, que rompe la regla del array de argumentos. Coste: no se recupera «Datos del sistema» desde Airy.
- **R2 — Versiones antiguas del framework dentro de `/Applications/<Navegador>.app`.** Mismo motivo: van a «Solo revisar».
- **R3 — Prudente = fase 1** se cumple ficha a ficha para las 26 fichas de la fase 1, con una prueba que lo fija. Las fichas nuevas usan su `risk` en Prudente y `aggressiveRisk` en Agresivo. Con todo, Prudente nunca preselecciona ámbar.
- **R4 — Proyecto viejo.**
  - El proyecto es la carpeta **más externa** con marcador (`package.json`, `pyproject.toml`, `requirements.txt`, `Cargo.toml` o `.git`). En un monorepo, tocar cualquier paquete conserva todos los artefactos.
  - La señal es exactamente la del spec.
  - Se excluyen iCloud (`isUbiquitousItem`, `~/Library/Mobile Documents`) y también `~/Library/CloudStorage`, por prudencia.
  - Raíces de búsqueda: las que existan de `Projects, Developer, dev, Code, GitHub, Repos, src, Workspace, orca, Desktop, Documents`.
- **R5 — Preselección por perfil.** Con perfiles elegidos, una ficha etiquetada **solo** con otros perfiles no se preselecciona. Las fichas sin perfil (registros, navegadores) se preseleccionan si son verdes. Sin perfiles, el comportamiento es el del plan 1.
- **R6 — Artefactos.** Solo se preseleccionan en Agresivo los cinco del spec (`node_modules`, `.venv`, `target`, `.next`, `build`). Los del catálogo ampliado van en ámbar sin preselección.
- **R7 — Botones.** «Limpiar todo lo seguro» pasa a «Seleccionar todo lo verde»: selecciona, no confirma. Todo borrado sale de «Borrar todo · X GB» con la confirmación única.
- **R8 — Redes de Docker.** No ocupan disco: la fila dice «No ocupa espacio en disco» y lista las redes.
- **R9 — Comandos con objetivo** (`simctl runtime delete <id>`, `sqlite3 <History.db> VACUUM;`). Usan el marcador `{target}`. El objetivo se valida (UUID o ruta pasada por `PathGate`) y la fuente lo revalida en el embudo.
- **R10 — «Descargas viejas» (perfil Uso básico).** Elementos de `~/Downloads` de ≥ 50 MB sin cambios en ≥ 180 días, uno por fila, en ámbar y sin preselección.
- **R11 — Modelos de IA «sin usar hace meses».** No se filtran, porque `atime` no es fiable. Cada fila muestra «Último cambio hace X» y el perfil los destaca.

---

## Estructura de archivos

```
Sources/DiskMapCore/
  Catalog/Catalog.swift                 campos nuevos de CatalogEntry, RetentionRule, DiscoveryKind      (mod)
  Resources/catalog.json                fichas nuevas y ampliadas (Tasks 2–6)                             (mod)
  Cleanup/TreeWalk.swift                paseo acotado: bytes, último cambio, nombres vigilados            (nuevo)
  Cleanup/CleanupTargets.swift          protocolo de fuentes, StaticPatternSource, RetentionSource       (nuevo)
  Cleanup/DockerSource.swift            DockerProbe, DockerState, DockerSource                           (nuevo)
  Cleanup/SimulatorRuntimeSource.swift  runtimes de simulador sin dispositivos                          (nuevo)
  Cleanup/ProjectArtifactSource.swift   proyectos sin tocar ≥ 3 meses y guardias                         (nuevo)
  Cleanup/InstallerSource.swift         instaladores en Descargas/Escritorio/Documentos                  (nuevo)
  Cleanup/AppSupportCacheSource.swift   heurística de caché regenerable en Application Support           (nuevo)
  Cleanup/CleanupScanner.swift          descubre por fuentes; una ruta, un elemento                      (mod)
  Cleanup/CleanupExecutor.swift         revalida por fuentes, {target}, Docker, CommandPolicy            (mod)
  Safety/CommandPolicy.swift            órdenes que nunca se ejecutan (volúmenes de Docker…)             (nuevo)
  Safety/RiskClassifier.swift           `floor:` y preselección por perfil                               (mod)
  Settings/AirySettings.swift           profilePrompted                                                  (mod)
  UIState/CleanupBoard.swift            etiquetas, «Solo revisar», selección, secciones de confirmación  (mod)
  UIState/RiskExplanation.swift         «por qué» de cada etiqueta                                       (nuevo)
  Scan/ScanHonesty.swift                completo/parcial/no disponible y «+»                             (nuevo)
  AI/AIContextBuilder.swift             perfiles en el contexto                                          (mod)
  MCP/Tools/ReadTools.swift             list_cleanup_items por perfil + campos; list_largest/summary «+» (mod)
Sources/Airy/
  Cleanup/CleanupView.swift, CleanupRow.swift, ConfirmSheet.swift, CleanupFlow.swift                      (mod)
  Profile/ProfileSheet.swift            «¿Cómo usas tu Mac?»                                             (nuevo)
  Settings/SettingsView.swift           sección «Cómo usas tu Mac» (archivo del plan 1)                  (mod)
  Shell/RootView.swift, AppModel.swift, Map/HoverCard.swift, Map/MapView.swift                            (mod)
Tests/DiskMapCoreTests/
  CatalogSchemaTests, DockerTests, DevCatalogTests, ProjectArtifactTests, ExtraTargetsTests,
  AppCacheTests, ProfileTests, ScanHonestyTests (nuevos); CleanupBoardTests, MCPReadToolTests,
  CatalogTests, CleanupTests, ClassifierTests (ajustes que se citan en cada tarea)
```

**Orden del catálogo:** las fichas concretas van antes que las amplias (`installers`, `old-downloads`, `app-support-caches` al final). El escáner recorre el catálogo en orden, y una ruta pertenece a la primera ficha que la reclama.

---

### Task 1: Esquema del catálogo y fuentes de objetivos (un punto de extensión para escáner y embudo)

**Files:**
- Modify: `Sources/DiskMapCore/Catalog/Catalog.swift`, `Sources/DiskMapCore/Cleanup/CleanupScanner.swift`, `Sources/DiskMapCore/Cleanup/CleanupExecutor.swift` (paso «pertenece a los patrones de la ficha» del `plan` privado del plan 1, Task 8), `Sources/DiskMapCore/Safety/RiskClassifier.swift`
- Create: `Sources/DiskMapCore/Cleanup/TreeWalk.swift`, `Sources/DiskMapCore/Cleanup/CleanupTargets.swift`
- Test: `Tests/DiskMapCoreTests/CatalogSchemaTests.swift`; adapt `ClassifierTests.bundledCatalogDecodesWithDefaults` (ya no exige `aggressiveRisk == nil` en todas; conserva el round-trip del JSON de ejemplo y añade los campos nuevos)

**Interfaces:**
- Consumes: `CatalogEntry`, `Catalog.match`, `CleanupScanner.expand` (privado, reutilizado), `RiskClassifier.classify(entry:paths:ai:)`, `ProcessListing`, `TimeBudget`, el `plan` del embudo (plan 1 Task 8).
- Produces:
```swift
// Catalog.swift — campos guardados (resolución F4): decodeIfPresent con estos valores por defecto,
// parámetros con valor por defecto en el init público, se codifican solo si no son el valor por defecto.
public struct RetentionRule: Codable, Sendable, Equatable {
    public var keepNewest: Int          // ≥ 1, por carpeta padre; JSON "keepNewest"
    public var activeLink: String?      // "~/.local/bin/claude": la versión a la que apunta se conserva siempre
}
public enum DiscoveryKind: Codable, Sendable, Equatable {   // JSON {"type": "...", ...}; tipo desconocido ⇒ error de decodificación
    case projectArtifacts(names: [String], cachedirTag: Bool)   // Task 4
    case installers                                              // Task 5
    case simulatorRuntimes                                       // Task 3
    case appSupportCaches                                        // Task 6
    case docker                                                  // Task 2
}
extension CleanupMethod { public static let targetPlaceholder = "{target}" }   // un argumento exacto
// CatalogEntry gana:
public var shortReason: String?      // una frase: por qué es verde/rojo o qué pierdes si es ámbar
public var perMatch: Bool            // false; un elemento por ruta encontrada
public var except: [String]          // []; últimos componentes que nunca se incluyen
public var staleAfterDays: Int?      // solo rutas sin cambios dentro desde hace N días
public var minimumBytes: Int64?      // por elemento
public var retention: RetentionRule?
public var discovery: DiscoveryKind?
public var reviewHint: String?       // fichas .info: qué hacer tú, en español
// CleanupItem gana (valores por defecto en init):
public var details: [String] = []        // nombres de contenedores, «Se conservan: …», «Proyecto sin tocar desde …»
public var targets: [String] = []        // valores de {target}
public var sizeNote: String? = nil       // «Tamaño desconocido», «No ocupa espacio en disco»
public var lastModified: Date? = nil
public var riskReason: String? = nil     // motivo de una guardia (floor) o de una protección
public var sizeIsPartial: Bool = false   // Task 11

// TreeWalk.swift — síncrono, no sigue enlaces (lstat), cuenta enlaces duros una vez, mira el reloj en cada entrada
public struct TreeSummary: Sendable, Equatable {
    public var bytes: Int64; public var latestModification: Date?; public var watched: [String]  // rutas relativas, máx. 10
}
public enum TreeWalk {
    /// `nil` si se agota `budget` o la raíz no se puede leer. `prune(nombre, rutaRelativa)` ⇒ no entrar.
    /// Una raíz que es fichero devuelve su tamaño y su mtime.
    public static func summarize(_ root: String, budget: Duration,
                                 prune: (String, String) -> Bool = { _, _ in false },
                                 watch: (String) -> Bool = { _ in false }) -> TreeSummary?
}

// CleanupTargets.swift
public struct DiscoveryContext: Sendable {
    public let catalog: Catalog, home: String, runner: any CommandRunning, processListing: any ProcessListing
    public let now: Date, scan: FileNode?          // Task 2 añade `docker: DockerState?`
}
public struct DiscoveredTarget: Sendable, Equatable {
    public var idSuffix: String?               // nil ⇒ id = entry.id; si no, "\(entry.id):\(idSuffix)"
    public var paths: [String]
    public var targets: [String] = []
    public var bytes: Int64? = nil             // nil ⇒ el escáner mide (índice o TreeWalk con TimeBudget.sizeMeasure)
    public var details: [String] = []
    public var lastModified: Date? = nil
    public var needle: String? = nil           // comprobación de referencias (HF, como ahora)
    public var floor: Risk? = nil              // guardia: solo sube
    public var floorReason: String? = nil
    public var blockedReason: String? = nil
    public var sizeNote: String? = nil
}
public protocol CleanupTargetSource: Sendable {
    func discover(_ entry: CatalogEntry, context: DiscoveryContext) async -> [DiscoveredTarget]
    /// En el embudo, justo antes de actuar. `nil` = sigue valiendo tal cual; si no, motivo en español.
    func revalidate(_ entry: CatalogEntry, item: CleanupItem, context: DiscoveryContext) async -> String?
}
public enum CleanupTargets {
    /// discovery ⇒ su fuente; retention ⇒ RetentionSource; si no, StaticPatternSource.
    public static func source(for entry: CatalogEntry) -> any CleanupTargetSource
}
public struct StaticPatternSource: CleanupTargetSource { public init() }
public struct RetentionSource: CleanupTargetSource { public init() }
// RiskClassifier: classify(entry:paths:ai:floor:) con `floor: Risk? = nil` (strictest con todo lo demás).
// CleanupExecutor.init gana `processListing: any ProcessListing = LibprocListing()` y `now: @Sendable () -> Date = { Date() }`.
```

Reglas de las fuentes:
- **`StaticPatternSource.discover`** hace hoy lo que ya hace `CleanupScanner.candidates(for:)`, sin cambios de comportamiento: expande los patrones; las fichas `.command` necesitan `runner.resolve`; si tienen `sizeProbe` y no son de sqlite (Task 5), salen fuera; las fichas con `referenceCheck` dan un elemento por carpeta con `needle`. Además:
  - Quita las rutas cuyo último componente está en `except`.
  - Con `perMatch`, da un elemento por ruta, con `idSuffix = Format.tildePath(ruta)`.
  - Con `staleAfterDays`, mide con `TreeWalk.summarize`. Se queda la ruta solo si `latestModification` es anterior a `now - días`. Un `nil` del paseo la deja fuera.
  - Aplica `minimumBytes`.
  - En `.command` con `{target}`, cada ruta encontrada pasa a ser un `target`.
- **`StaticPatternSource.revalidate`** según el método de la ficha:
  - `.trash`: cada `item.paths` debe estar en la expansión viva (después de aplicar `except`). Con `staleAfterDays`, debe seguir viejo (si no, «Lo has usado hace poco.»).
  - `.command` sin `{target}`: devuelve `nil`.
  - `.command` con `{target}`: cada `target` debe seguir en la expansión.
- **`RetentionSource.discover`**:
  1. Expande y agrupa las rutas por carpeta padre.
  2. En cada grupo ordena por `mtime` descendente (empate: nombre descendente).
  3. Si hay `activeLink`, resuelve `realpath` del enlace. La versión activa es la ruta del grupo que lo contiene o lo iguala. Si no se resuelve o queda fuera del grupo, ese grupo no da nada (fallo cerrado).
  4. Se conservan la activa y las más nuevas hasta sumar `keepNewest`; el resto son las rutas del elemento.
  5. Da un elemento por ficha, con `details = ["Se conservan: \(nombres)"]`.
- **`RetentionSource.revalidate`**: recalcula el conjunto conservado. Una ruta que ahora se conserva, o que ya no existe, se rechaza con «Ya no es una versión antigua: \(nombre).». Con `activeLink`, también se rechaza si algún proceso de `processListing.processes()` tiene `executablePath` dentro de una ruta del elemento («Está en uso: \(nombre).»), o si el listado es `nil` («No se pudo comprobar si está en uso; Airy no lo toca.»).
- **Escáner**:
  1. Por cada ficha, en orden: `source(for:).discover`.
  2. **Una ruta, un elemento**: se descartan las rutas cuya forma canónica ya reclamó un elemento anterior. Si no le queda ninguna, el candidato desaparece.
  3. Tamaño: `bytes` de la fuente o, si falta, índice → `TreeWalk.summarize(budget: TimeBudget.sizeMeasure)`. Si el paseo agota el plazo: `sizeNote = "Tamaño desconocido"` y `blockedReason = "No se pudo medir a tiempo."`.
  4. Se descartan los candidatos de 0 bytes, salvo que tengan `sizeNote` o `blockedReason`.
  5. Riesgo con `classify(entry:paths:floor:)`. `riskReason` = `floorReason` o el motivo de la protección.
  6. El resto del pipeline (referencias, `ProcessGuard`, `usedBy`) no cambia.
  7. `CleanupScanner.parseDockerDF/parseDockerSize` siguen como reenvíos públicos (pruebas de la fase 1).
- **Embudo**: en el `plan` privado, el paso «pertenece a los patrones de la ficha» pasa a ser `CleanupTargets.source(for: live).revalidate(live, item:, context:)`, seguido de `PathGate.validate` por ruta, como antes. En `.command` con `{target}`:
  - se exige `!item.targets.isEmpty`;
  - cada objetivo que empieza por `/` pasa por `PathGate.validate`;
  - se ejecuta una vez por objetivo, sustituyendo el marcador;
  - las liberaciones se suman en `.freed`;
  - el primer fallo detiene la tanda y devuelve `.failed`;
  - `preview` devuelve `.wouldRun(command:)` con el primer objetivo sustituido.

- [ ] **Step 1: Write the failing tests** (`CatalogSchemaTests.swift`, home temporal; `FakeRunner`/`FakeProbes` de `CleanupTests.swift`; `FakeListing: ProcessListing` local)

```swift
@Test func newFieldsRoundTripAndDefaultsAreOmitted()      // JSON con shortReason, perMatch, except, staleAfterDays, minimumBytes,
    // retention {keepNewest 2, activeLink}, discovery {"type":"projectArtifacts","names":["node_modules"],"cachedirTag":true}
    // → decodifica igual; reencode sin los campos por defecto (perMatch false no aparece); discovery {"type":"nope"} → throws
@Test func treeWalkStopsAtBudgetAndDoesNotFollowLinks()   // budget .zero → nil; enlace a carpeta de 10 MB cuenta 0 bytes, no la recorre
@Test func treeWalkPrunesAndWatches()                     // prune "node_modules": su mtime nuevo no cuenta; watch "-keypair.json" lo lista
@Test func perMatchExceptStaleAndMinimum() async {        // ~/Downloads con a.bin (200 MB, viejo), b.bin (200 MB, nuevo), c.bin (1 MB, viejo), .DS_Store
    #expect(items.map(\.id) == ["old:~/Downloads/a.bin"])  // staleAfterDays 180, minimumBytes 50 MB, except [".DS_Store"]
}
@Test func retentionKeepsNewestTwoPerParent() async       // iOS DeviceSupport 15,16,17 + watchOS 9,10 → paths == [iOS 15]; details "Se conservan: 17, 16"
@Test func retentionKeepsActiveLinkPlusOne() async         // versions/1.0,1.1,2.0 (2.0 más nueva), enlace → 1.0 ⇒ se conservan 1.0 y 2.0; borra 1.1
@Test func samePathNeverInTwoItems() async                 // dos fichas con el mismo patrón → la primera del catálogo se queda la ruta; total sin doble cuenta
@Test func zeroByteItemsOnlyWithNoteOrBlock() async
@Test func funnelRevalidatesThroughTheSource() async       // ficha retention: tras detectar, se crea 18 (más nueva) → execute del item con 16 → .blocked("Ya no es una versión antigua: 16.")
@Test func targetPlaceholderRunsOncePerValidatedTarget() async {
    // ficha .command sqlite3 ["{target}", "VACUUM;"], item.targets = [db1, db2] → runner.calls args == [[db1,"VACUUM;"],[db2,"VACUUM;"]]
    // item.targets == [] → .blocked; target relativo o protegido (home/Library/Keychains/x) → .blocked y runner sin llamadas
}
@Test func classifierFloorOnlyRaises()                     // floor .doNotTouch sobre safe → .doNotTouch; floor .safe sobre yourCall → .yourCall
```

- [ ] **Step 2: Run** — `swift test --filter CatalogSchemaTests` → FAIL (tipos y campos inexistentes).
- [ ] **Step 3: Implement** según Interfaces y las reglas de arriba. `TreeWalk` usa `opendir`/`lstat` (como `AllocatedSize`) y un `ContinuousClock` con fecha límite; no crea tareas.
- [ ] **Step 4: Run** — `swift test 2>&1 | tail -3` → todo en verde. Las pruebas de la fase 1 de `CleanupTests` (escáner, Docker, referencias) siguen pasando sin cambios: StaticPatternSource conserva su comportamiento.
- [ ] **Step 5: Commit** — `feat: fuentes de objetivos de limpieza compartidas por escáner y embudo` (+ Co-Authored-By).

---

### Task 2: Docker agresivo (prunes oficiales, demonio caído y nunca volúmenes)

**Files:**
- Create: `Sources/DiskMapCore/Cleanup/DockerSource.swift`, `Sources/DiskMapCore/Safety/CommandPolicy.swift`
- Modify: `catalog.json` (fichas Docker), `CleanupScanner.swift` (una sola sonda Docker por pasada → `DiscoveryContext.docker`; `dockerMeasure` se mueve a `DockerSource`), `CleanupExecutor.swift` (`CommandPolicy` antes de **cada** `runner.run` de limpieza)
- Test: `Tests/DiskMapCoreTests/DockerTests.swift`. Se adaptan con motivo: `CleanupTests.dockerImagesAndVolumesAppearAsInfo` (imágenes = comando y miden `Reclaimable`), `CleanupTests.dockerOmittedWhenDaemonDown` (ahora salen filas bloqueadas) y `CatalogTests.correctedCopyAndRisks` (`docker-images.regenerates == true`).

**Interfaces:**
- Consumes: `CleanupTargetSource`, `DiscoveryContext`, `DiscoveredTarget` (Task 1).
- Produces:
```swift
public struct DockerUsage: Sendable, Equatable { public var size: Int64?; public var reclaimable: Int64? }
public struct DockerSnapshot: Sendable, Equatable {
    public var usage: [String: DockerUsage]      // por "Type" de `docker system df`
    public var stoppedContainers: [String]       // nombres
    public var unusedNetworks: [String]          // sin bridge/host/none
}
public enum DockerState: Sendable, Equatable { case notInstalled, daemonDown, running(DockerSnapshot) }
public enum DockerProbe {
    public static let timeout: TimeInterval = 20
    public static let unavailableMessage = "Abre Docker Desktop para limpiar esto"
    public static func state(runner: any CommandRunning) async -> DockerState
    /// `docker version --format {{.Server.Version}}`: estado 0 **y** salida no vacía.
    public static func daemonResponds(runner: any CommandRunning) async -> Bool
}
public struct DockerSource: CleanupTargetSource { public init() }   // discovery {"type":"docker"}
public enum CommandPolicy {
    /// Motivo para no ejecutar nunca esta orden aunque venga del catálogo; `nil` si se permite.
    public static func refusal(executable: String, arguments: [String]) -> String?
}
// DiscoveryContext gana `docker: DockerState?` (el escáner lo rellena una vez si alguna ficha es discovery .docker).
```
Sondas (arrays exactos, con la ruta resuelta de `docker`):
- `["version","--format","{{.Server.Version}}"]`;
- `["system","df","--format","{{json .}}"]`;
- `["ps","-a","--filter","status=exited","--filter","status=created","--filter","status=dead","--format","{{.Names}}"]`;
- `["network","ls","--filter","dangling=true","--format","{{.Name}}"]`.

Si `resolve` devuelve `nil`, el estado es `notInstalled`. Si `version` o `df` fallan, es `daemonDown`.

| id | método (`docker …`) | medida (`df` Type / campo) | riesgo → Agresivo | presel. Agresivo | detalles / nota |
|---|---|---|---|---|---|
| `docker-build-cache` | `builder prune -a -f` | Build Cache / Reclaimable | safe | — | — |
| `docker-images` | `image prune -a -f` | Images / Reclaimable | yourCall → **safe**, `regenerates: true` | — | — |
| `docker-containers` (nueva) | `container prune -f` | Containers / Reclaimable | yourCall | **sí** | `details` = nombres; `shortReason` «Un contenedor parado puede guardar datos en su capa: lo pierdes.» |
| `docker-networks` (nueva) | `network prune -f` | — (0 bytes) | safe | — | `sizeNote` «No ocupa espacio en disco»; `details` = nombres; solo si hay alguna |
| `docker-volumes` | info | Local Volumes / Size | doNotTouch | — | `shortReason` «Guarda los datos de tus contenedores (bases de datos…): no se recuperan.» |

Todas llevan `discovery {"type":"docker"}`, `profiles ["developer"]` y `shortReason`. `docker-build-cache`/`docker-images`: «Docker la vuelve a descargar o construir cuando la necesita.».

Comportamiento según el estado del demonio:
- **Demonio caído:** cada ficha con método `.command` da un objetivo con `bytes 0`, `sizeNote "Tamaño desconocido"` y `blockedReason = DockerProbe.unavailableMessage`. Volúmenes no da nada, y nunca se arranca Docker.
- **Revalidación:** si `daemonResponds` es `false`, se rechaza con `unavailableMessage`.
- **`CommandPolicy`:** para `docker`, rechaza cualquier argumento `volume`, `volumes` o que empiece por `--volumes`, y la pareja `system prune`, con «Airy nunca borra volúmenes de Docker.». Para cualquier ejecutable, rechaza los argumentos con escalares de control, con «Orden no válida.».

- [ ] **Step 1: Write the failing tests**

```swift
@Test func runningDaemonYieldsFourActionableItems() async   // fixture df + 2 parados + 1 red → ids build-cache, images, containers, networks, volumes;
    // images.bytes == Reclaimable del fixture; containers.details == ["db-viejo","web"]; networks.sizeNote == "No ocupa espacio en disco"
@Test func daemonDownShowsBlockedRowsAndNoVolumes() async   // `version` con estado 1 → 4 filas con blockedReason == "Abre Docker Desktop para limpiar esto", canSelect false; sin docker-volumes
@Test func emptyVersionOutputCountsAsDown() async           // FakeRunner devuelve 0 y "" por defecto → daemonDown
@Test func notInstalledYieldsNothing() async
@Test func daemonStoppedAfterDetectionBlocksAtAct() async    // detectar con demonio arriba; cambiar runner a `version` estado 1; execute(images) → .blocked(unavailableMessage); runner sin "image prune"
@Test func commandPolicyRefusesVolumes() {
    #expect(CommandPolicy.refusal(executable: "/usr/local/bin/docker", arguments: ["volume","prune","-f"]) != nil)
    #expect(CommandPolicy.refusal(executable: "docker", arguments: ["system","prune","-a","--volumes"]) != nil)
    #expect(CommandPolicy.refusal(executable: "docker", arguments: ["image","prune","-a","-f"]) == nil)
}
@Test func executorNeverRunsAVolumeCommandEvenFromCatalog() async  // catálogo de prueba con docker-builder args ["builder","prune","--volumes"] → .blocked; runner.calls vacío
@Test func bundledCatalogPassesCommandPolicy() throws         // ninguna ficha del catálogo real es rechazada; ninguna contiene "volume"
@Test func aggressiveVsPrudentDockerRisks() throws            // agresivo: images safe, containers yourCall+preselected, volumes doNotTouch; prudente: images yourCall, nada ámbar preseleccionado
```

- [ ] **Step 2: Run** — `swift test --filter DockerTests` → FAIL.
- [ ] **Step 3: Implement** según Interfaces; adaptar las tres pruebas de la fase 1 citadas (motivo en un comentario de una línea en cada una).
- [ ] **Step 4: Run** — `swift test 2>&1 | tail -3` → verde.
- [ ] **Step 5: Commit** — `feat: prunes oficiales de Docker, demonio caído bloqueado y veto a volúmenes` (+ Co-Authored-By).

---

### Task 3: Herramientas de desarrollo y Xcode (Node, Python, cola larga, DeviceSupport, runtimes) y tabla de clasificación

**Files:**
- Create: `Sources/DiskMapCore/Cleanup/SimulatorRuntimeSource.swift`
- Modify: `catalog.json`
- Test: `Tests/DiskMapCoreTests/DevCatalogTests.swift`

**Interfaces:**
- Consumes: Task 1 (`RetentionRule`, `CleanupTargetSource`, `{target}`), `ProcessGuard` (plan 1, vía `processNames`).
- Produces: `public struct SimulatorRuntimeSource: CleanupTargetSource { public init() }` (discovery `simulatorRuntimes`); `public enum Phase1Risks { public static let byID: [String: Risk] }` en el target de pruebas (`DevCatalogTests.swift`), con los riesgos de las 26 fichas de la fase 1 (las de `catalog.json` antes de este plan).

Fichas existentes (sin cambiar riesgo; ganan `profiles` y `shortReason`):
- `profiles ["developer"]`: npm, pnpm, pnpm-cache, uv, pip, conda, cargo, homebrew, xcode-deriveddata, xcode-simulators, codex-stale-installs, playwright.
- `profiles ["localAI"]`: huggingface-model, ollama-models, whisper-cache, claude-vm.
- `profiles ["basic"]`: user-logs.

Se comprueba que los comandos existentes son exactamente los del spec: `npm cache clean --force`, `pnpm store prune`, `uv cache clean`, `pip3 cache purge`, `conda clean --all -y` y `brew cleanup --prune=all -s`; cargo va con `registry` y `git` a la Papelera.

Fichas nuevas (todas `regenerates: true` salvo que se diga; `profiles ["developer"]`):

| id | rutas | método | riesgo → Agresivo | `processNames` / otros |
|---|---|---|---|---|
| `yarn` | `~/Library/Caches/Yarn` | `yarn cache clean` | safe | `["yarn"]` |
| `yarn-berry` | `~/.yarn/berry/cache` | trash | safe | `["yarn"]` |
| `bun` | `~/.bun/install/cache` | `bun pm cache rm` | safe | `["bun"]` |
| `corepack` | `~/.cache/node/corepack` | trash | safe | `["corepack"]` |
| `go-build-cache` | `~/Library/Caches/go-build` | `go clean -cache` | safe | `["go"]` |
| `go-mod-cache` | `~/go/pkg/mod` | `go clean -modcache` | yourCall → safe | `["go"]` |
| `poetry-cache` | `~/Library/Caches/pypoetry/cache`, `~/Library/Caches/pypoetry/artifacts` | trash | safe | `["poetry"]` (`virtualenvs` sigue protegido) |
| `pyenv-cache` | `~/.pyenv/cache` | trash | safe | — |
| `bundler-cache` | `~/.bundle/cache` | trash | safe | `["bundle","bundler"]` |
| `composer-cache` | `~/Library/Caches/composer`, `~/.composer/cache` | `composer clear-cache` | safe | `["composer"]` |
| `gradle-caches` | `~/.gradle/caches` | trash | yourCall (sin `aggressiveRisk`) | `["gradle"]`; `shortReason` «Gradle tarda en volver a bajarlo todo y lo que compilas sin conexión deja de funcionar.» |
| `swiftpm-cache` | `~/Library/Caches/org.swift.swiftpm` | trash | safe | `["swift-build","swift-package"]` |
| `cocoapods-cache` | `~/Library/Caches/CocoaPods` | `pod cache clean --all` | safe | `["pod"]` |
| `dart-pub-cache` | `~/.pub-cache` | `dart pub cache clean --force` | yourCall → safe | `["dart","flutter"]` |
| `electron-cache` | `~/Library/Caches/electron` | trash | safe | — |
| `node-gyp-cache` | `~/Library/Caches/node-gyp`, `~/.node-gyp` | trash | safe | — |
| `prisma-cache` | `~/.cache/prisma` | trash | safe | — |
| `terraform-plugins` | `~/.terraform.d/plugin-cache` | trash | safe | `["terraform"]` |
| `expo-cache` | `~/.expo/*` con `except ["state.json"]` | trash | safe | `["expo"]` |
| `android-build-cache` | `~/.android/build-cache`, `~/.android/cache` | trash | safe | — |
| `jetbrains-caches` | `~/Library/Caches/JetBrains/*` | trash | yourCall | `["idea","pycharm","webstorm","goland","clion","rider","phpstorm","rubymine","datagrip","studio"]` |
| `vscode-caches` | `~/Library/Application Support/Code/{Cache,CachedData,Code Cache,GPUCache,CachedExtensionVSIXs}` (5 patrones literales) | trash | safe | `mustBeClosed ["com.microsoft.VSCode"]` |
| `cursor-caches` | lo mismo bajo `Application Support/Cursor` | trash | safe | `mustBeClosed ["com.todesktop.230313mzl4w4u92"]` |
| `xcode-device-support` | `~/Library/Developer/Xcode/{iOS,watchOS,tvOS,visionOS} DeviceSupport/*` | trash, `retention {keepNewest: 2}` | safe | `["Xcode","xcodebuild"]`; `shortReason` «Xcode vuelve a copiarlo al conectar el dispositivo; se conservan las 2 más recientes.» |
| `xcode-coresimulator-caches` | `~/Library/Developer/CoreSimulator/Caches` | trash | safe | `["Simulator","xcodebuild"]` |
| `xcode-test-devices` | `~/Library/Developer/XCTestDevices/*` | trash | safe | `["Xcode","xcodebuild"]` |
| `xcode-doc-cache` | `~/Library/Developer/Xcode/DocumentationCache` | trash | safe | `["Xcode"]` |
| `xcode-caches` | `~/Library/Caches/com.apple.dt.Xcode` | trash | safe | `["Xcode"]` |
| `xcode-orphan-runtimes` | — (discovery `simulatorRuntimes`) | `xcrun simctl runtime delete {target}` | yourCall, `regenerates: false` | `["Simulator","Xcode","xcodebuild"]`; `shortReason` «Tendrías que volver a descargar el runtime desde Xcode.» |
| `xcode-archives` | `~/Library/Developer/Xcode/Archives` | info (Solo revisar) | yourCall | `reviewHint` «Bórralos desde Xcode › Window › Organizer: ahí ves cuáles ya subiste.» |

Las 5 rutas de `vscode-caches` y `cursor-caches` son patrones **literales**: así cumplen la excepción de la capa C de `HardProtections` («patrón literal de una ficha con acción»).

`SimulatorRuntimeSource`:
- Sondas, con array exacto: `["simctl","runtime","list","-j"]` y `["simctl","list","devices","-j"]`.
- Formato de `runtime list -j`: objeto `{ "<UUID>": {"identifier": UUID, "runtimeIdentifier": "...", "platformIdentifier": "com.apple.platform.iphonesimulator", "version": "17.0", "sizeBytes": Int, "deletable": Bool} }`.
- Formato de `list devices -j`: `{"devices": {"<runtimeIdentifier>": [...]}}`.
- **Huérfano** = `deletable == true` y sin dispositivos en su `runtimeIdentifier`.
- El `target` es el `identifier` si cumple `^[0-9A-Fa-f-]{36}$` (si no, se descarta).
- `idSuffix` = «iOS 17.0». Mapa de plataformas: iphonesimulator → iOS, watchsimulator → watchOS, appletvsimulator → tvOS, xrsimulator → visionOS.
- `bytes` = `sizeBytes`. Cualquier fallo de sonda o de JSON da `[]`.
- `revalidate`: vuelve a sondear. Cada objetivo debe seguir siendo huérfano y borrable; si no, «Ese runtime ya tiene simuladores o ya no está.».

- [ ] **Step 1: Write the failing tests**

```swift
@Test func phase1EntriesKeepPhase1RiskInPrudent() throws {   // R3
    let c = RiskClassifier(catalog: try .bundled(), settings: prudent, home: h)
    for (id, risk) in Phase1Risks.byID { #expect(c.baseRisk(of: try #require(catalog.entry(id: id))) == risk, "\(id)") }
}
@Test func prudentNeverPreselectsAmber() throws              // todas las fichas, classify(entry:paths:[]) en Prudente: ningún yourCall con preselected
@Test func aggressiveClassificationTable() throws {          // spec §2.5
    // safe: docker-build-cache, docker-images, docker-networks, npm, pnpm, yarn, bun, uv, pip, conda, cargo, homebrew,
    //       xcode-deriveddata, xcode-simulators, xcode-device-support, go-mod-cache
    // yourCall + preselected: docker-containers, old-project-artifacts (Task 4; esta línea se añade allí)
    // doNotTouch: docker-volumes, codex-runtime
}
@Test func catalogLint() throws {
    // aggressiveRisk < risk ⇒ regenerates && risk != .doNotTouch; ejecutables sin "/"; {target} como mucho una vez y solo en .command;
    // retention.keepNewest ≥ 1; ids únicos; toda ficha nueva (no en Phase1Risks) tiene shortReason; .info no doNotTouch ⇒ reviewHint
}
@Test func specCommandsAreExact() throws                      // los seis arrays del spec + yarn ["cache","clean"], bun ["pm","cache","rm"], simctl delete unavailable
@Test func deviceSupportKeepsTwoNewest() async                // home temporal: iOS 15,16,17 → solo 15
@Test func orphanRuntimeBecomesTargetedCommand() async {      // fixture: R1 sin dispositivos, R2 con uno, R3 no borrable → un item con targets == [R1.uuid];
    // execute → runner.calls.last?.arguments == ["simctl","runtime","delete", R1.uuid]
}
@Test func runtimeWithNewDeviceIsRefusedAtAct() async         // tras detectar, fixture de devices incluye R1 → .blocked
@Test func malformedRuntimeIDIsDropped() async                // identifier "x; rm -rf ~" → ningún item
@Test func expoKeepsStateJSON() async
```

- [ ] **Step 2: Run** — `swift test --filter DevCatalogTests` → FAIL.
- [ ] **Step 3: Implement** fichas y fuente según las tablas.
- [ ] **Step 4: Run** — `swift test 2>&1 | tail -3` → verde.
- [ ] **Step 5: Commit** — `feat: catálogo de desarrollo agresivo (Node, Python, Go, Xcode fino y cola larga)` (+ Co-Authored-By).

---

### Task 4: Proyectos sin tocar ≥ 3 meses (artefactos regenerables con guardias)

**Files:**
- Create: `Sources/DiskMapCore/Cleanup/ProjectArtifactSource.swift`
- Modify: `catalog.json` (dos fichas)
- Test: `Tests/DiskMapCoreTests/ProjectArtifactTests.swift`; añade a `DevCatalogTests.aggressiveClassificationTable` la línea de `old-project-artifacts`

**Interfaces:**
- Consumes: `TreeWalk` (Task 1), `CleanupTargetSource`, `CommandRunning` (para `git`).
- Produces:
```swift
public enum ProjectArtifactRules {
    public static let rootMarkers = ["package.json", "pyproject.toml", "requirements.txt", "Cargo.toml", ".git"]
    public static let signalExcluded: Set<String> = ["node_modules", ".venv", "target", ".next", "build", "dist"]  // y .git/objects
    public static let staleAfter: TimeInterval = 90 * 86_400
    public static let cachedirSignature = "Signature: 8a477f597d28d172789f06886806bc55"
    public static let searchRootNames = ["Projects", "Developer", "dev", "Code", "GitHub", "Repos", "src", "Workspace",
                                         "orca", "Desktop", "Documents"]
    public static func defaultSearchRoots(home: String) -> [String]       // las que existen, carpetas reales
    public static func regenerationHint(for name: String) -> String       // «Se rehace con npm install (o pnpm/yarn)»…
}
public struct ProjectArtifactSource: CleanupTargetSource {
    public init(searchRoots: [String]? = nil, maxDepth: Int = 6,
                projectBudget: Duration = .seconds(5), totalBudget: Duration = .seconds(30))
}
```
Fichas, ambas `trash`, `risk yourCall`, `regenerates true`, `profiles ["developer"]`:
- `old-project-artifacts`: `discovery {projectArtifacts, names [node_modules, .venv, target, .next, build], cachedirTag false}`, `preselectInAggressive true`. Título «Carpeta regenerable de un proyecto viejo». `shortReason` «Está en un proyecto que no tocas hace más de 3 meses; se rehace con su comando.»
- `old-project-build-leftovers`: `names [venv, dist, Pods, .gradle, .dart_tool, .build, .turbo, .angular, .svelte-kit, .astro, .nuxt, .output, .parcel-cache, .tox, .nox, __pycache__, .pytest_cache, .mypy_cache, .ruff_cache, .zig-cache, zig-out, .cxx, .expo, .terragrunt-cache, DerivedData, obj, bin, vendor]`, `cachedirTag true`, sin preselección (R6).

Algoritmo de `discover` (dentro de `totalBudget`; al agotarlo se devuelve lo ya **completo**):
1. **Raíces de búsqueda.** `searchRoots ?? defaultSearchRoots`, cada una resuelta con `realpath`. Se saltan las que quedan bajo `~/Library` (incluidos `Mobile Documents` y `CloudStorage`) y las que tienen `URLResourceValues.isUbiquitousItem == true`.
2. **Proyectos.** BFS hasta `maxDepth` sin seguir enlaces. Se poda `.git`, `Library`, `.Trash`, `Applications`, todo nombre de artefacto de cualquiera de las dos fichas y todo nombre de `signalExcluded`. Una carpeta con algún `rootMarker` es un **proyecto** (el más externo): no se buscan proyectos dentro de él. Las carpetas ubicuas se saltan.
3. **Señal.** `TreeWalk.summarize(proyecto, budget: projectBudget, prune: nombre ∈ signalExcluded || (nombre == "objects" && padre == ".git"))`. Si da `nil`, el proyecto no se ofrece. Es viejo si `latestModification < now - staleAfter`.
4. **Artefactos de un proyecto viejo.** Carpetas reales (`lstat` → `S_IFDIR`; un enlace se ignora) dentro del proyecto, sin entrar en `.git` ni en artefactos ya encontrados, cuyo nombre está en `names`. Con `cachedirTag`, también cualquier carpeta con un `CACHEDIR.TAG` que empiece por la firma.
   - `bin` solo vale si el padre tiene `*.csproj|*.fsproj|*.vbproj` y `bin/Debug` o `bin/Release`.
   - `vendor` solo vale si el padre tiene `composer.json` y `vendor/autoload.php`.
   - Si no, se ignoran sin fila.
5. **Guardias por artefacto.** `TreeWalk.summarize(artefacto, budget: projectBudget, watch: nombre == ".git" || nombre.hasSuffix("-keypair.json"))`:
   - `nil` ⇒ `blockedReason` «No se pudo revisar a tiempo.»;
   - `.git` dentro ⇒ `floor .doNotTouch`, `floorReason` «Contiene otro repositorio Git dentro.»;
   - un `*-keypair.json` ⇒ `floor .doNotTouch`, «Contiene claves (\(nombre)): no se regeneran.»;
   - si el proyecto o un ancestor hasta la raíz de búsqueda tiene `.git`, se ejecuta `git -C <padre del artefacto> ls-files -z -- <nombre>` (con `runner.resolve("git")`, plazo 10 s):
     - estado 0 con salida ⇒ `floor .doNotTouch`, «Git guarda archivos aquí: no es solo un resto de compilación.»;
     - estado 0 vacío ⇒ ok;
     - cualquier otra cosa ⇒ `blockedReason` «No se pudo comprobar con Git si guarda archivos aquí.».
6. **Objetivo.** `idSuffix = Format.tildePath(artefacto)`, `bytes = summary.bytes`, `lastModified` = señal del proyecto, `details = ["Proyecto sin tocar desde \(fecha dd/MM/yyyy)", regenerationHint(nombre)]`.

`revalidate` exige exactamente una ruta, carpeta real (no enlace), nombre en `names` y una raíz de búsqueda actual que la contenga. Después repite los pasos 2–5 **solo para esa ruta**:
- proyecto más externo subiendo desde el padre; si no hay ninguno, «Ya no está dentro de un proyecto.»;
- si ya no es viejo, «Has tocado el proyecto hace poco (\(fecha)): no se borra.»;
- si alguna guardia sube el riesgo o bloquea, se rechaza con su motivo.

- [ ] **Step 1: Write the failing tests** (árbol temporal con `utimes` para fechar; `now` inyectado; `FakeRunner` con `git` resuelto)

```swift
@Test func staleProjectOffersItsNodeModulesPreselectedInAggressive() async   // app/{package.json, src/a.js (hace 120 d), node_modules (hoy)} → 1 item yourCall preselected
@Test func signalIgnoresRegenerableFoldersAndGitObjects() async              // solo node_modules/.git/objects recientes → sigue viejo
@Test func recentFileAnywhereKeepsEverything() async                         // src/b.js de hace 10 d → nada
@Test func outermostRootDecidesForMonorepo() async                           // repo/.git, repo/packages/a/node_modules; packages/b/x.ts reciente → nada
@Test func extendedNamesAreNotPreselected() async                            // __pycache__ y Pods → items de la segunda ficha, preselected false
@Test func cachedirTagIsRecognised() async
@Test func nestedRepoAndKeypairAreRed() async                                // target/deploy/x-keypair.json → doNotTouch con floorReason; vendor/.git → doNotTouch
@Test func gitTrackedBuildIsRedAndGitFailureBlocks() async                   // ls-files con salida → doNotTouch; estado 128 → blockedReason; git sin resolver → blockedReason
@Test func binAndVendorOnlyForDotNetAndComposer() async
@Test func symlinkedArtifactIsNeitherWalkedNorOffered() async                // node_modules → enlace a home/Documents/grande: sin item; TreeWalk nunca entra
@Test func iCloudAndCloudStorageAreSkipped() async                           // raíz bajo home/Library/CloudStorage → nada
@Test func budgetExceededOffersNothing() async                               // projectBudget .zero → []
@Test func projectTouchedAfterDetectionIsRefused() async                     // detectar; tocar src/a.js; execute → .blocked("Has tocado el proyecto hace poco…"); node_modules intacto
@Test func revalidateRejectsPathOutsideAnyProject() async
```

- [ ] **Step 2: Run** — `swift test --filter ProjectArtifactTests` → FAIL.
- [ ] **Step 3: Implement** según Interfaces.
- [ ] **Step 4: Run** — `swift test 2>&1 | tail -3` → verde.
- [ ] **Step 5: Commit** — `feat: artefactos de proyectos sin tocar en 3 meses, con guardias de Git y claves` (+ Co-Authored-By).

---

### Task 5: Instaladores, firmware, versiones de agentes, Safari, cuarentena y «Solo revisar»

**Files:**
- Create: `Sources/DiskMapCore/Cleanup/InstallerSource.swift`
- Modify: `catalog.json`, `CleanupTargets.swift` (sonda sqlite de `StaticPatternSource`)
- Test: `Tests/DiskMapCoreTests/ExtraTargetsTests.swift`

**Interfaces:**
- Consumes: Task 1 (`RetentionSource`, `{target}`, `perMatch`, `staleAfterDays`).
- Produces: `public struct InstallerSource: CleanupTargetSource { public init(); public static let extensions: Set<String> = ["dmg","pkg","mpkg","iso","xip"]; public static let rootNames = ["Downloads","Desktop","Documents"]; public static let zipListTimeout: TimeInterval = 5 }`. Además, la sonda sqlite: en `StaticPatternSource`, una ficha `.command` con `executable == "sqlite3"` y `sizeProbe` ejecuta la sonda con `{target}` sustituido y toma `bytes = page_size × freelist_count` (dos enteros, uno por línea). Si falla, no hay elemento.

`InstallerSource`:
- Busca en cada raíz existente, a profundidad ≤ 2, sin seguir enlaces y saltando lo ubicuo.
- Toma los ficheros regulares con extensión en `extensions`, y los `.zip` cuyo `zipinfo -1 <ruta>` (resuelto con `resolve("zipinfo")`, plazo `zipListTimeout`) tenga alguna línea con un componente de nivel 1–2 terminado en `.app`, o un fichero de nivel ≤ 2 terminado en `.pkg`, `.mpkg` o `.dmg`. Un fallo o un plazo agotado ⇒ no es instalador.
- Un elemento por fichero: `idSuffix` = ruta con `~`, `details ["Descargado \(Format.relativeDate(mtime))"]`.
- `revalidate`: sigue siendo un fichero regular y sigue siendo instalador.

Fichas nuevas:

| id | rutas / fuente | método | riesgo (Agr.) | perfiles | notas |
|---|---|---|---|---|---|
| `device-firmware` | `~/Library/iTunes/*Software Updates/*.ipsw`, `~/Library/Group Containers/K36BKF7T3D.group.com.apple.configurator/Library/Caches/Firmware/*.ipsw` | trash | safe | — | «El Mac lo vuelve a descargar si actualizas el iPhone o el iPad.» |
| `claude-code-old-versions` | `~/.local/share/claude/versions/*`, `retention {keepNewest 2, activeLink "~/.local/bin/claude"}` | trash | safe | developer, localAI | «Se conservan la versión activa y la anterior.» |
| `cursor-agent-old-versions` | `~/.local/share/cursor-agent/versions/*`, `retention {2, "~/.local/bin/cursor-agent"}` | trash | safe | developer | idem |
| `lmstudio-models` | `~/.lmstudio/models/*/*`, `~/.cache/lm-studio/models/*/*`, `perMatch` | trash | yourCall | localAI | `mustBeClosed ["ai.elementlabs.lmstudio"]`; «Tendrías que volver a descargar \(tamaño).» (vía RiskExplanation) |
| `safari-compact` | `~/Library/Safari/History.db` | `sqlite3 {target} "VACUUM;"`, `sizeProbe ["-readonly","{target}","PRAGMA page_size; PRAGMA freelist_count;"]`, `partialCleanup`, `minimumBytes 10 MB` | yourCall | basic | `mustBeClosed ["com.apple.Safari"]`, `processNames ["Safari"]`; «Compacta el historial; solo con Safari cerrado.» |
| `quarantine-history` | `~/Library/Preferences/com.apple.LaunchServices.QuarantineEventsV2` | trash | yourCall, sin preselección | — | «Borra el historial de lo que has descargado; macOS lo vuelve a crear vacío.» |
| `installers` | discovery `installers` | trash | yourCall | basic | «Si lo borras, tendrás que volver a descargarlo para reinstalar.» |
| `old-downloads` | `~/Downloads/*`, `perMatch`, `staleAfterDays 180`, `minimumBytes 50_000_000`, `except [".DS_Store",".localized"]` | trash | yourCall | basic | R10; va **después** de `installers` |

Fichas «Solo revisar» (`.info`, `risk yourCall`, con `reviewHint`; R1 y R2):

| id | rutas | `reviewHint` |
|---|---|---|
| `system-diagnostic-reports` | `/Library/Logs/DiagnosticReports` | «Necesita tu contraseña de administrador y Airy no borra fuera de tu carpeta. Puedes borrarlos tú desde Finder (⌘⇧G).» |
| `system-logs` | `/private/var/log` | idem |
| `system-caches` | `/Library/Caches` | idem |
| `macos-installers` | `/Applications/Install macOS*.app` | «Arrástralo a la Papelera desde Aplicaciones si ya actualizaste.» |
| `chrome-old-frameworks`, `brave-old-frameworks`, `edge-old-frameworks` (3 fichas) | `/Applications/<App>.app/Contents/Frameworks/<App> Framework.framework/Versions/*` con `<App>` = «Google Chrome», «Brave Browser», «Microsoft Edge»; `retention {keepNewest 1, activeLink "…/Versions/Current"}` | «Se quitan al actualizar el navegador; si no, reinstálalo.» |
| `ios-backups` | `~/Library/Application Support/MobileSync/Backup` | «Gestiónalas desde Finder › tu iPhone › Gestionar copias.» |
| `android-emulators` | `~/.android/avd` | «Bórralos desde Android Studio › Device Manager.» |
| `agent-worktrees` | `~/.codex/worktrees`, `~/.claude/worktrees` | «Quítalos con git worktree remove desde su repositorio.» |
| `time-machine-in-progress` | `/Volumes/*/Backups.backupdb/*/*.inProgress` | «Es una copia de Time Machine que no terminó; revísala desde Time Machine.» |
| `music-sound-libraries` (`profiles ["music"]`) | `/Library/Application Support/GarageBand`, `/Library/Application Support/Logic`, `/Library/Audio/Apple Loops` | «Gestiónalas desde Logic Pro o GarageBand › Biblioteca de sonidos: así se pueden volver a descargar.» |

En las fichas `.info` el escáner mide con `TreeWalk` (presupuesto `TimeBudget.sizeMeasure`). Si agota el plazo, `sizeNote = "Tamaño desconocido"`. Las fichas de revisión **no** reciben `blockedReason` por tamaño desconocido: no tienen acción.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func installersByExtensionAndZipListing() async   // Downloads/{a.dmg, b.pkg, c.zip (zipinfo lista "Foo.app/"), d.zip (lista "notes.txt"), e.txt} → a, b, c
@Test func zipinfoFailureIsNotAnInstaller() async
@Test func installerAlsoOldIsListedOnce() async         // a.dmg de 300 MB y 1 año → solo "installers:…" (orden del catálogo)
@Test func missingActiveLinkOffersNothing() async        // versions/{1,2,3} sin ~/.local/bin/claude → ningún item
@Test func runningOldVersionIsRefused() async            // FakeListing con executablePath dentro de versions/1 → execute .blocked("Está en uso: 1.")
@Test func listingUnknownRefusesRetentionWithLink() async
@Test func safariCompactionSizesFromFreelistAndNeedsSafariClosed() async {
    // sonda devuelve "4096\n5000" → bytes 20_480_000; FakeProbes con Safari abierto → blockedByOpenApps no vacío; execute → .blocked
}
@Test func safariCompactionRunsVacuumWithExactArguments() async   // Safari cerrado → runner.calls.last == [sqlite3, [db, "VACUUM;"]]
@Test func quarantineIsAmberNotPreselected() throws
@Test func reviewOnlyEntriesHaveNoActionAndAHint() throws         // todas las de la tabla: .info, yourCall, reviewHint no vacío; showsCheckbox false
@Test func adminAndApplicationsPathsAreNeverActionable() throws   // ninguna ficha con acción tiene patrones bajo /Library, /private, /Applications, /System
@Test func neverMessagesOrMailCaches() throws                     // ningún patrón contiene "Library/Messages", "com.apple.mail", "Mail Downloads", "Library/Mail"
```

- [ ] **Step 2: Run** — `swift test --filter ExtraTargetsTests` → FAIL.
- [ ] **Step 3: Implement** según las tablas.
- [ ] **Step 4: Run** — `swift test 2>&1 | tail -3` → verde.
- [ ] **Step 5: Commit** — `feat: instaladores, firmware, versiones antiguas de agentes, Safari y «Solo revisar»` (+ Co-Authored-By).

---

### Task 6: Navegadores Chromium, heurística de Application Support y cachés de apps por perfil

**Files:**
- Create: `Sources/DiskMapCore/Cleanup/AppSupportCacheSource.swift`
- Modify: `catalog.json`
- Test: `Tests/DiskMapCoreTests/AppCacheTests.swift`

**Interfaces:**
- Consumes: Task 1; `HardProtections.standard.match(canonicalPath:home:catalog:)` (plan 1).
- Produces: `public struct AppSupportCacheSource: CleanupTargetSource { public init(); public static let markers = ["Code Cache","GPUCache","DawnCache","GrShaderCache","GraphiteDawnCache","DawnGraphiteCache","DawnWebGPUCache","Crashpad"]; public static let alsoCleared = ["Cache","CachedData","Crashpad/completed"]; public static let maxChildren = 5_000 }`.

**Navegadores.** Rutas de perfil P = `Cache, Code Cache, GPUCache, DawnCache, DawnGraphiteCache, DawnWebGPUCache, Service Worker/CacheStorage, Service Worker/ScriptCache`. Rutas del navegador B = `GrShaderCache, GraphiteDawnCache, ShaderCache, component_crx_cache, extensions_crx_cache, Crashpad/completed`. Cada ficha incluye como patrones `<base>/<p>`, `<base>/*/<p>` y `<base>/<b>`, además de su carpeta de `~/Library/Caches`. Todas son trash, safe, `profiles ["basic"]`, «Se vuelve a crear sola al navegar; cierra el navegador antes.»:

| id | `<base>` (bajo `~/Library/Application Support/`) | `~/Library/Caches/…` | `mustBeClosed` |
|---|---|---|---|
| `chrome-cache` (amplía) | `Google/Chrome` | `Google/Chrome` | `com.google.Chrome` |
| `brave-cache` (amplía) | `BraveSoftware/Brave-Browser` | `BraveSoftware`, `com.brave.Browser` | `com.brave.Browser` |
| `edge-cache` | `Microsoft Edge` | `com.microsoft.edgemac` | `com.microsoft.edgemac` |
| `chromium-cache` | `Chromium` | `Chromium` | `org.chromium.Chromium` |
| `arc-cache` | `Arc/User Data` | `company.thebrowser.Browser` | `company.thebrowser.Browser` |
| `vivaldi-cache` | `Vivaldi` | `com.vivaldi.Vivaldi` | `com.vivaldi.Vivaldi` |
| `opera-cache` | `com.operasoftware.Opera` | `com.operasoftware.Opera` | `com.operasoftware.Opera` |
| `firefox-cache` | — | `Firefox` | `org.mozilla.firefox` |

**Cachés de apps.** Todas son trash. `mustBeClosed` = el bundle id indicado. Las rutas bajo `Application Support` de apps de la capa C son **patrones literales**, que es la excepción de `HardProtections`.

| id | rutas | riesgo | perfiles | `mustBeClosed` |
|---|---|---|---|---|
| `slack-cache` | `~/Library/Application Support/Slack/{Cache,Code Cache,GPUCache,Service Worker/CacheStorage}`, `~/Library/Caches/com.tinyspeck.slackmacgap` | safe | basic | `com.tinyspeck.slackmacgap` |
| `discord-cache` | `~/Library/Application Support/discord/{Cache,Code Cache,GPUCache}` | safe | basic | `com.hnc.Discord` |
| `zoom-cache` | `~/Library/Caches/us.zoom.xos` | safe | basic | `us.zoom.xos` |
| `teams-cache` | `~/Library/Containers/com.microsoft.teams2/Data/Library/Caches` | safe | basic | `com.microsoft.teams2` |
| `whatsapp-cache` | `~/Library/Containers/net.whatsapp.WhatsApp/Data/Library/Caches` | safe | basic | `net.whatsapp.WhatsApp` |
| `telegram-cache` | `~/Library/Containers/ru.keepcoder.Telegram/Data/Library/Caches` | safe | basic | `ru.keepcoder.Telegram` |
| `office-caches` | `~/Library/Containers/com.microsoft.{Word,Excel,Powerpoint,Outlook}/Data/Library/Caches` (4 literales) | safe | basic | los 4 bundle ids |
| `notion-cache` | `~/Library/Application Support/Notion/{Cache,Code Cache,GPUCache}` | safe | basic | `notion.id` |
| `adobe-media-cache` | `~/Library/Application Support/Adobe/Common/Media Cache Files`, `…/Adobe/Common/Media Cache`, `~/Library/Caches/Adobe` | safe | creative | — (`processNames ["Adobe Premiere Pro","After Effects","Adobe Media Encoder"]`) |
| `figma-cache` | `~/Library/Application Support/Figma/{Cache,Code Cache,GPUCache}` | safe | creative | `com.figma.Desktop` |
| `finalcut-cache` | `~/Library/Caches/com.apple.FinalCut` | safe | creative | `com.apple.FinalCut` |
| `davinci-cache` | `~/Movies/CacheClip` | safe (suelo personal ⇒ ámbar) | creative | `com.blackmagic-design.DaVinciResolve` |
| `sketch-cache` | `~/Library/Caches/com.bohemiancoding.sketch3` | safe | creative | `com.bohemiancoding.sketch3` |
| `apple-music-cache` | `~/Library/Caches/com.apple.Music` | safe | music | `com.apple.Music` |
| `spotify-cache` (existe) | — | yourCall | music, basic | — |
| `vlc-cache` | `~/Library/Caches/org.videolan.vlc` | safe | music | `org.videolan.vlc` |
| `steam-caches` | `~/Library/Application Support/Steam/{appcache,htmlcache,depotcache,logs}`, `…/Steam/steamapps/shadercache` | safe | gaming | `com.valvesoftware.steam` |
| `steam-games` | `~/Library/Application Support/Steam/steamapps/common/*`, `perMatch`, `staleAfterDays 90` | yourCall | gaming | `com.valvesoftware.steam` |
| `epic-games` | `/Users/Shared/Epic Games/*`, `perMatch`, `staleAfterDays 90` | yourCall | gaming | `com.epicgames.EpicGamesLauncher` |
| `whisky-bottles` | `~/Library/Containers/com.isaacmarovitz.Whisky/Bottles/*`, `perMatch`, `staleAfterDays 90`, `regenerates false` | yourCall | gaming | `com.isaacmarovitz.Whisky` |
| `minecraft-logs` | `~/Library/Application Support/minecraft/logs` | safe | gaming | — |
| `app-support-caches` | discovery `appSupportCaches` (**última ficha del catálogo**) | yourCall → safe, `regenerates true` | — | — |

Notas sobre la tabla:
- **Excepción del catálogo.** Para que `HardProtections` acepte las rutas de capa C, su forma canónica debe empezar por la de un patrón literal. Comprueba que las cuatro rutas literales de Slack, Discord, Notion y Figma pasan `PathGate.validate` en la prueba `sensitiveAppCachesPassThroughCatalogException`.
- **Mensajes y Mail.** No llevan ninguna ficha; ya lo comprueba `neverMessagesOrMailCaches` en Task 5.

`AppSupportCacheSource`:
- Recorre las carpetas reales A y A/B bajo `~/Library/Application Support`, con un `TreeWalk` de presupuesto 10 s en total para la búsqueda.
- Se queda con las que contienen alguna carpeta de `markers` como hija directa. Objetivos = hijos existentes de `markers` (cambiando `Crashpad` por `Crashpad/completed`) ∪ `alsoCleared`.
- Se descarta la carpeta si:
  - tiene más de `maxChildren` hijos directos;
  - algún objetivo lo reclama **otra** ficha (`catalog.match` ≠ esta);
  - todos sus objetivos rechazan `HardProtections.match` (las rutas rechazadas se quitan sin fila roja).
- Un elemento por carpeta: `idSuffix` = ruta relativa a Application Support. Título de la ficha: «Cachés regenerables de una app».
- `revalidate`: cada ruta existe, es carpeta real, su nombre está en `markers ∪ alsoCleared`, el padre sigue teniendo un marcador, nadie más la reclama y no está protegida. El guardián de caché viva (`checkOpenFiles` del embudo) hace el resto.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func chromiumProfileCachesAreFoundButNotProfileData() async   // Chrome/Default/{Code Cache, Cookies, Local Storage} → solo Code Cache
@Test func heuristicFindsElectronAppAndSkipsCatalogued() async       // Application Support/FooApp/{GPUCache,Cache,Data} → item con GPUCache y Cache; Google/Chrome → ninguno (lo reclama chrome-cache)
@Test func heuristicDropsHardProtectedApps() async                   // Application Support/1Password/{GPUCache} → sin item
@Test func heuristicSkipsHugeFolders() async                         // 5 001 hijos → sin item
@Test func sensitiveAppCachesPassThroughCatalogException() throws    // PathGate.validate(.../Slack/Cache) == nil; (.../Slack/storage) != nil
@Test func staleGamesOnlyAfter90Days() async
@Test func appCachesCarryTheirProfiles() throws                      // tabla: cada id con sus perfiles
```

- [ ] **Step 2: Run** — `swift test --filter AppCacheTests` → FAIL.
- [ ] **Step 3: Implement** según las tablas.
- [ ] **Step 4: Run** — `swift test 2>&1 | tail -3` → verde.
- [ ] **Step 5: Commit** — `feat: navegadores Chromium, heurística de caché regenerable y cachés de apps por perfil` (+ Co-Authored-By).

---

### Task 7: Tablero de Limpieza (etiquetas, «Solo revisar», selección y confirmación única)

**Files:**
- Modify: `Sources/DiskMapCore/UIState/CleanupBoard.swift`
- Create: `Sources/DiskMapCore/UIState/RiskExplanation.swift`
- Test: `Tests/DiskMapCoreTests/CleanupBoardTests.swift`. Se adaptan `groupsByRiskInFixedOrderSortedBySize` (títulos «Sin problema», «Tú decides», «No borrar») y `yourCallNoteUsesProperPlural` («Tú decides»).

**Interfaces:**
- Produces:
```swift
extension CleanupBoard {
    public static func isReviewOnly(_ item: CleanupItem) -> Bool   // .info y risk != .doNotTouch
    // `groups` deja fuera lo de revisión; Group.title == risk.label
    public var reviewItems: [CleanupItem]                          // bytes desc, id
    public var displayItems: [CleanupItem]                         // groups (verde, ámbar, rojo) + reviewItems
    public var greenSelection: Set<String>                         // ids de readySafeItems
    public var fullSelection: Set<String>                          // canSelect, verde y ámbar; nunca rojo
    /// Poda lo que ya no vale y añade los preseleccionados (canSelect) que no estaban en `seen`.
    public func nextSelection(current: Set<String>, seen: Set<String>) -> (selection: Set<String>, seen: Set<String>)
    public static func deleteAllTitle(_ items: [CleanupItem]) -> String   // "Borrar todo · 3,2 GB" / "Borrar todo · hasta 3,2 GB"
    /// `regular` = verde; `review` = ámbar, en el orden recibido; los rojos no llegan aquí (canSelect).
    public static func confirmSections(_ items: [CleanupItem], excluding removed: Set<String>)
        -> (regular: [CleanupItem], review: [CleanupItem])
    public static let reviewBlockTitle = "Revisa: esto no se regenera solo o puede tener estado"
    public static func sizeText(_ item: CleanupItem) -> String     // sizeNote si existe; "hasta" si parcial; "+" si sizeIsPartial (Task 11)
}
public enum RiskExplanation {
    public static func why(risk: Risk, entry: CatalogEntry?, protection: ProtectionMatch?, reason: String?, bytes: Int64,
                           personal: Bool) -> String
    public static func why(_ item: CleanupItem, home: String = NSHomeDirectory()) -> String
}
// CleanupRunSummary gana `public var successes: [Success]` (Success: title, text — «Liberados 2 GB» / «1,2 GB a la Papelera»),
// que `record` rellena en .freed/.movedToTrash.
```
Prioridad de `why` (la primera que aplique):
- **doNotTouch:** `reason` (guardia o protección) → `protection.reason` → `entry.shortReason` → «Es del sistema o guarda datos que no se recuperan.».
- **yourCall:**
  - `reason` → `entry.shortReason`;
  - si no, cuando `personal` (está bajo una carpeta personal de `RiskPolicy.personalRoots`): «Está en tus carpetas personales: solo tú sabes si lo necesitas.»;
  - si no, con `bytes > 0`: «Pierdes lo que hay dentro (\(Format.bytes(bytes))); no vuelve solo.»;
  - si no: «Pierdes lo que hay dentro; no vuelve solo.».
- **safe:** `entry.shortReason` → «Se vuelve a crear sola.».

- [ ] **Step 1: Write the failing tests**

```swift
@Test func groupsUseTheThreeLabelsGreenFirst()          // ["Sin problema","Tú decides","No borrar"]
@Test func reviewOnlyItemsLiveInTheirOwnList()          // ollama (info yourCall) → reviewItems, no en groups; docker-volumes (info rojo) sigue en "No borrar"
@Test func selectAllNeverIncludesRedOrBlocked()         // fullSelection = verde+ámbar seleccionables; rojo, protegido y bloqueado fuera
@Test func greenSelectionIsReadySafe()
@Test func preselectionAppliesOnlyToNewItems() {        // 1.ª detección: preseleccionados; el usuario quita uno; 2.ª detección con los mismos ids → no vuelve;
    // aparece uno nuevo preseleccionado → se añade; uno que desaparece → se poda
}
@Test func deleteAllTitleSaysUpToWhenPartial()          // "Borrar todo · 3 GB" y "Borrar todo · hasta 3 GB"
@Test func confirmSectionsSplitAmberAndHonourRemoval()  // [verde A, ámbar B, ámbar C], removed {C} → regular [A], review [B]; removed {A,B,C} → ambos vacíos
@Test func whyTextsFollowPriority()                     // guardia > protección > shortReason > personal > tamaño; verde por defecto «Se vuelve a crear sola.»
@Test func summaryListsSuccessesAndProblems()           // .freed y .movedToTrash → successes con texto; .blocked/.failed → problems
@Test func sizeNoteOverridesSize()                      // "No ocupa espacio en disco"
```

- [ ] **Step 2: Run** — `swift test --filter CleanupBoardTests` → FAIL.
- [ ] **Step 3: Implement** según Interfaces.
- [ ] **Step 4: Run** — `swift test 2>&1 | tail -3` → verde.
- [ ] **Step 5: Commit** — `feat: tablero con «Sin problema / Tú decides / No borrar», «Solo revisar» y selección` (+ Co-Authored-By).

---

### Task 8: Perfil en el núcleo (preselección, primera vez, MCP y Asistente)

**Files:**
- Modify: `Sources/DiskMapCore/Safety/RiskClassifier.swift` (preselección R5), `Sources/DiskMapCore/Settings/AirySettings.swift`, `Sources/DiskMapCore/MCP/Tools/ReadTools.swift` (`ListCleanupItemsTool`, plan 1 Task 12), `Sources/DiskMapCore/AI/AIContextBuilder.swift`, `Sources/DiskMapCore/AI/AIAssistant.swift` (línea de perfil en el prompt)
- Test: `Tests/DiskMapCoreTests/ProfileTests.swift`, `Tests/DiskMapCoreTests/MCPReadToolTests.swift`

**Interfaces:**
- Consumes: `CleanupBoard.displayItems` y `RiskExplanation.why(_:)` (Task 7), `AiryEnvironment.classifier()` (plan 1).
- Produces:
```swift
// AirySettings: public var profilePrompted = false   // JSON "profilePrompted", decodeIfPresent → false; se codifica siempre
// RiskClassifier.preselected(risk:entry:) pasa a:
//   let fits = settings.profiles.isEmpty || entry.profiles.isEmpty || highlighted(entry)
//   fits && (risk == .safe || (mode == .aggressive && risk == .yourCall && entry.preselectInAggressive))
// AIContextBuilder.context(…, profiles: Set<UsageProfile> = []) → payload "profiles": ["Programo", …] (títulos, ordenados)
// AIAssistant: si hay perfiles, el prompt añade «El usuario usa su Mac para: <títulos>. Prioriza lo que le sirve; nunca bajes un riesgo por eso.»
// list_cleanup_items: items en el orden de CleanupBoard(items:).displayItems; cada item gana
//   "review_only": Bool, "details": [String], "size_note": String|null, "why": String, "profiles": [String];
//   salida gana "profiles": [rawValue ordenados]
```

- [ ] **Step 1: Write the failing tests**

```swift
@Test func profilesNeverChangeRiskOnBundledCatalog() throws {   // 64 combinaciones × todas las fichas × ambos modos: mismo risk que sin perfil
}
@Test func profileHighlightsItsMinimumEntries() throws {        // spec §2.3: por perfil, estas ids existen y tienen el perfil
    // developer: docker-build-cache, docker-images, docker-containers, docker-networks, npm, pnpm, yarn, bun, uv, pip, conda,
    //            cargo, xcode-deriveddata, xcode-simulators, xcode-device-support, old-project-artifacts
    // localAI: ollama-models, lmstudio-models, huggingface-model · creative: adobe-media-cache, finalcut-cache, davinci-cache
    // gaming: steam-games, epic-games, whisky-bottles · music: music-sound-libraries · basic: chrome-cache, safari-cache, user-logs, old-downloads
}
@Test func otherProfilesEntriesAreNotPreselected()              // perfiles [.basic]: docker-build-cache safe, preselected false; user-logs safe, preselected true
@Test func noProfilesKeepsPlan1Preselection()                   // perfiles []: igual que antes (preselection() del plan 1 sigue en verde)
@Test func profilePromptedRoundTrips()                          // {"version":1} → false; save/load true
@Test func aiContextCarriesProfileTitlesOnly()                  // JSON contiene "Programo"; ningún contenido de archivo
@Test func listCleanupItemsFollowsProfileOrder() async {        // MCPReadToolTests: settings.json con profiles ["developer"];
    // A (safe, 5 GB, sin perfil), B (safe, 1 GB, developer) → orden [B, A]; sin perfiles → [A, B]; "profiles" == ["developer"]
}
@Test func listCleanupItemsMarksReviewOnly() async              // ficha .info yourCall → review_only true, actionable_by_agent false, al final
```

- [ ] **Step 2: Run** — `swift test --filter ProfileTests` y `--filter MCPReadToolTests` → FAIL.
- [ ] **Step 3: Implement** según Interfaces.
- [ ] **Step 4: Run** — `swift test 2>&1 | tail -3` → verde (incluido `ClassifierTests.preselection`).
- [ ] **Step 5: Commit** — `feat: el perfil ordena, destaca y preselecciona en Limpieza, MCP y Asistente` (+ Co-Authored-By).

---

### Task 9: Vista Limpieza, «Borrar todo» y la confirmación única

**Files:**
- Modify: `Sources/Airy/Cleanup/CleanupView.swift`, `CleanupRow.swift`, `ConfirmSheet.swift`, `CleanupFlow.swift`, `Sources/Airy/AppModel.swift` (escáner con `ProjectArtifactSource`, contexto Docker y `inaccessible`)

**Interfaces:**
- Consumes: Task 7 (`CleanupBoard.*`, `RiskExplanation`, `CleanupRunSummary.successes`), Task 8 (perfil), plan 1 Task 9 (`AppModel.perform(_:context:)`, `preview(_:)`, vista previa por fila), `RiskBadge(risk:compact:reason:)`, `Theme.Airy`, `.leafAway`, `CleanupFlow.gust`/`batchFreed` (plan 2).
- Produces: `CleanupFlow.confirm(_ request:, excluding removed: Set<String>, model:)` (con `removed` vacío se comporta como ahora y sigue disparando `gust` y `batchFreed` del plan 2 con los elementos que quedan); `CleanupFlow.ConfirmRequest.Kind.items` sigue igual.

Comportamiento y textos:
- **Cabecera** (HeroCard): «Puedes liberar (hasta) X», como ahora. El botón pasa a ser «Seleccionar todo lo verde» (`greenSelection`, R7), y a su lado «Seleccionar todo» (`fullSelection`) con estilo secundario. Ambos se desactivan si están vacíos o `flow.isBusy`.
- **Selección inicial:** `nextSelection(current:seen:)` al terminar cada detección (`@ViewState seen`).
- **Grupos:** `GroupSection` usa `group.title` (etiqueta). Textos breves:
  - verde: «Se vuelve a crear solo: bórralo sin miedo.»
  - ámbar: «Se puede borrar, pero pierdes algo: lee qué.»
  - rojo: «No se borra: Airy te dice por qué.»
  Cada grupo tiene «Seleccionar este grupo» (solo verde y ámbar).
- **«Solo revisar»:** sección final, con título «Solo revisar» y el texto «Airy te dice qué es y cómo hacerlo tú; aquí no hay botón de borrar.». Cada fila muestra `RiskBadge`, el tamaño o la `sizeNote`, el `reviewHint` y un botón «Mostrar en Finder» (`NSWorkspace.activateFileViewerSelecting`; no es destructivo).
- **Fila:**
  - `RiskBadge(risk: item.risk, reason: RiskExplanation.why(item))` **siempre** (plan 2: texto `risk.label`).
  - Debajo del título, una línea con `RiskExplanation.why(item)` en `Theme.Airy.riskInk(item.risk)` para rojo y ámbar, y secundario para verde.
  - Las filas limpiadas salen con `.transition(.leafAway)` (plan 2), que respeta «Reducir movimiento».
  - Chip «Para ti» cuando `highlighted`.
  - `details`: los primeros 3, y «y N más» si hay más.
  - `sizeText` con nota.
  - Las filas rojas **no** tienen casilla ni ningún botón de acción.
  - Durante la tanda: la fila actual muestra `ProgressView` y «Limpiando…»; las de `queuedIDs`, «En cola».
- **Barra de selección:** «N seleccionados · X», «Quitar selección» y el botón principal `CleanupBoard.deleteAllTitle(selected)`, que abre `flow.requestClean(selected)`.
- **ConfirmSheet** (`.items`):
  - El título es «¿Borrar N elementos?».
  - Primero va la lista verde y después, si hay ámbar, un **bloque aparte** con fondo `Theme.color(for: .yourCall).opacity(0.10)`, borde ámbar, título `CleanupBoard.reviewBlockTitle` y cada fila con su `why`.
  - **Toda** fila de la hoja tiene «Quitar» (un clic → `removed`); el bloque ámbar tiene además «Quitar todo lo ámbar».
  - Cada fila dice su método («Irá a la Papelera» / «Se ejecutará `docker container prune -f`», con la vista previa del plan 1).
  - En `docker-containers` se listan los nombres: «Contenedores parados: a, b y c».
  - El total se recalcula sin lo quitado. Si no queda nada, el botón se desactiva.
  - El botón dice «Borrar N · X». Intro solo confirma si todo va a la Papelera, como ahora.
  - Al confirmar: `flow.confirm(request, excluding: removed, model:)`.
- **Resultado** (ResultBanner): titular como ahora; debajo, «Hecho» con `successes` (título · texto) y «No se pudo» con `problems` (título: motivo).
- **AppModel:** el escáner recibe el clasificador vivo (plan 1) y `inaccessible` del análisis (Task 11). El ejecutor recibe `processListing` (Task 1).
- **DEBUG** (`AIRY_CLEANUP_SCRIPT`): pasos nuevos `selectgreen`, `selectall` y `deleteall`. `deleteall` solo **abre** la hoja; no hay paso que confirme.

- [ ] **Step 1: Verify build** — `swift build` → compila.
- [ ] **Step 2: Implement** según lo descrito (sin `.fixedSize(horizontal:false,vertical:true)` en los textos nuevos).
- [ ] **Step 3: Verify** — `swift build && swift test 2>&1 | tail -3` → verde. Prueba manual en DEBUG, con su propio soporte y carpeta de prueba:
  1. `mkdir -p ~/Library/Logs/AiryPrueba && dd if=/dev/zero of=~/Library/Logs/AiryPrueba/x bs=1m count=5`.
  2. `AIRY_SUPPORT_DIR=$(mktemp -d) AIRY_CLEANUP_SCRIPT="section:cleanup@2,selectall@6,deleteall@8,cancel@14" .build/debug/Airy &`; guardar `$!`.
  3. Comprobar en una captura propia (DebugSnapshot): grupos con las tres etiquetas, «Solo revisar» al final, barra «Borrar todo · …» y hoja con bloque ámbar aparte.
  4. **No confirmar nada.** Parar con `kill <PID>`.
- [ ] **Step 4: Commit** — `feat: Limpieza con selección múltiple, «Borrar todo» y confirmación única con bloque ámbar` (+ Co-Authored-By).

---

### Task 10: «¿Cómo usas tu Mac?» en el primer arranque y en Ajustes

**Files:**
- Create: `Sources/Airy/Profile/ProfileSheet.swift`
- Modify: `Sources/Airy/Shell/RootView.swift` (presentación), `Sources/Airy/Settings/SettingsView.swift` (plan 1 Task 9: sección nueva), `Sources/Airy/AppModel.swift` (`setProfiles(_:)`)

**Interfaces:**
- Consumes: `AppModel.settings`, `updateSettings(_:)`, `settingsLoad` (plan 1 Task 9); `AirySettings.profilePrompted` (Task 8).
- Produces: `AppModel.setProfiles(_ profiles: Set<UsageProfile>)`, que guarda `profiles`, pone `profilePrompted = true` y llama a `refreshCleanup()`. `struct ProfilePicker: View { @Binding var selection: Set<UsageProfile> }`, compartido por la hoja y Ajustes.

Textos y comportamiento:
- Hoja (≈ 560 pt de ancho): título «¿Cómo usas tu Mac?»; subtítulo «Elige todo lo que encaje. Airy pondrá primero y marcará lo que más te sirve. Nunca cambia lo que es seguro borrar.».
- Seis tarjetas seleccionables con símbolo SF, título `UsageProfile.title` y una línea:
  - Programo «Docker, Node, Python, Xcode y proyectos viejos»;
  - Diseño, foto o vídeo «Cachés de Adobe, Final Cut y DaVinci»;
  - Uso IA en local «Modelos de Ollama, LM Studio y Hugging Face»;
  - Juego «Juegos y bottles sin abrir hace meses»;
  - Música y audio «Librerías de sonidos de Logic y GarageBand»;
  - Uso básico «Navegadores, registros y descargas viejas».
- Botones: «Ahora no» (`setProfiles([])`) y «Continuar» (`setProfiles(selection)`).
- Se presenta desde `RootView` una sola vez cuando `!model.settings.profilePrompted && !model.settingsLoad.isUnreadable`, después de la migración y fuera de la animación de arranque (plan 2).
- Ajustes › «Cómo usas tu Mac»: el mismo `ProfilePicker` (guarda al cambiar). Pie: «Solo cambia el orden y lo que se marca de entrada; nunca lo que es seguro borrar.».
- DEBUG: paso `profile` de `AIRY_CLEANUP_SCRIPT`, que abre la hoja (y `cancel` la cierra).

- [ ] **Step 1: Write the failing test** — en `ProfileTests`: `promptOnlyWhenNotPromptedAndReadable()` sobre una función pura `ProfilePrompt.shouldShow(_ load: SettingsLoad) -> Bool` (en `DiskMapCore/Settings/AirySettings.swift`): `.missing` → true; `.loaded(prompted)` → false; `.unreadable` → false.
- [ ] **Step 2: Run** — `swift test --filter ProfileTests` → FAIL.
- [ ] **Step 3: Implement** la función, la hoja, la sección de Ajustes y `setProfiles`.
- [ ] **Step 4: Verify** — `swift test 2>&1 | tail -3` → verde. Prueba manual: `AIRY_SUPPORT_DIR=$(mktemp -d) .build/debug/Airy &`; aparece la hoja; elegir «Programo» y «Continuar»; en Limpieza, lo de desarrollo va primero con «Para ti»; reabrir con el mismo `AIRY_SUPPORT_DIR` ⇒ no vuelve a salir; Ajustes (⌘,) lo muestra marcado. Parar por PID.
- [ ] **Step 5: Commit** — `feat: perfil «¿Cómo usas tu Mac?» al primer arranque y en Ajustes` (+ Co-Authored-By).

---

### Task 11: Honestidad del análisis («+») y etiquetas en el Mapa

**Files:**
- Create: `Sources/DiskMapCore/Scan/ScanHonesty.swift`
- Modify: `Sources/DiskMapCore/Model/Formatting.swift`, `Sources/DiskMapCore/Cleanup/CleanupScanner.swift` (`sizeIsPartial`), `Sources/DiskMapCore/MCP/Tools/ReadTools.swift` (`list_largest` y `get_disk_summary`), `Sources/Airy/AppModel.swift` (`partialIndex`), `Sources/Airy/Map/HoverCard.swift`, `Sources/Airy/Map/MapView.swift` (tarjeta del disco / pie del mapa)
- Test: `Tests/DiskMapCoreTests/ScanHonestyTests.swift`, `MCPReadToolTests.swift`

**Interfaces:**
- Consumes: `ScanResult.inaccessible` (ya existe y se persiste en el índice), `RiskExplanation` (Task 7), `AppModel.classify(path:)` (plan 1 Task 9).
- Produces:
```swift
public enum ScanCompleteness: Sendable, Equatable {
    case complete, partial(unreadable: Int), unavailable
    public static func of(_ result: ScanResult?) -> ScanCompleteness
    public var label: String   // "Análisis completo" / "Análisis parcial: no se pudieron leer N carpetas" / "Sin análisis"
    public var jsonName: String   // "complete" | "partial" | "unavailable"
}
public struct PartialScanIndex: Sendable {
    public init(inaccessible: [String])            // ordena una vez
    public func isPartial(_ path: String) -> Bool  // alguna ruta ilegible es `path` o está dentro (búsqueda binaria del prefijo)
}
extension Format { public static func bytes(_ value: Int64, partial: Bool) -> String }   // "12,3 GB+"
// CleanupScanner.findItems(scan:inaccessible:) con `inaccessible: [String] = []`: un tamaño tomado del índice
// para una ruta parcial ⇒ item.sizeIsPartial = true
// list_largest: cada hijo gana "size_partial": Bool; get_disk_summary gana "scan_status": jsonName
```
Interfaz:
- **HoverCard:** el tamaño se muestra con `Format.bytes(_, partial:)` y, si es parcial, con la ayuda «Airy no pudo leer todo lo que hay dentro: puede ocupar más.». El riesgo sale de `model.classify(path:)`: `RiskBadge(risk:reason:)` y debajo la línea `RiskExplanation.why(risk:entry:protection:reason:nil,bytes:personal:)`.
- **Mapa:** la tarjeta del disco o el pie muestran `ScanCompleteness.label` cuando no es `.complete`, y los totales llevan «+».
- **Limpieza:** `CleanupBoard.sizeText` añade «+» (Task 7 ya lo prevé).

- [ ] **Step 1: Write the failing tests**

```swift
@Test func completenessFromResult()                      // [] → .complete; 3 rutas → .partial(3); nil → .unavailable
@Test func partialIndexMatchesSelfAndAncestorsOnly() {
    let i = PartialScanIndex(inaccessible: ["/Users/a/Library/Mail", "/Users/a/x"])
    #expect(i.isPartial("/Users/a") && i.isPartial("/Users/a/Library") && i.isPartial("/Users/a/Library/Mail"))
    #expect(!i.isPartial("/Users/a/Library/Caches") && !i.isPartial("/Users/a/xy"))
}
@Test func plusSuffix()                                  // Format.bytes(1_000_000_000, partial: true).hasSuffix("+")
@Test func cleanupItemFromPartialIndexIsMarked() async
@Test func listLargestAndSummaryReportPartial() async    // MCP: hijo con ruta ilegible dentro → size_partial true; scan_status "partial"
```

- [ ] **Step 2: Run** — `swift test --filter ScanHonestyTests` → FAIL.
- [ ] **Step 3: Implement** según Interfaces.
- [ ] **Step 4: Verify** — `swift test 2>&1 | tail -3` → verde. Manual (DEBUG, soporte propio): pasar el ratón por `~/Library` sin Acceso total al disco ⇒ tamaño con «+» y etiqueta con su «por qué». Parar por PID.
- [ ] **Step 5: Commit** — `feat: tamaños con «+» si el análisis es parcial y etiquetas claras en el Mapa` (+ Co-Authored-By).

---

### Task 12: Verificación final

**Files:** ninguno nuevo (solo lo que destapen las comprobaciones).

- [ ] **Step 1: Pruebas** — `swift test 2>&1 | tail -3` → todo en verde (las de los planes 1–2 más las de este plan).
- [ ] **Step 2: Rastreo de reglas en el código:**
  - `grep -rn '"--volumes"\|volume prune' Sources` → solo `CommandPolicy.swift` y sus pruebas.
  - `grep -rn 'fixedSize(horizontal: false, vertical: true)' Sources/Airy` → ninguna aparición en archivos tocados por este plan.
  - `grep -rn 'trashItem(' Sources` → solo `CleanupExecutor.swift`.
- [ ] **Step 3: Humo MCP contra el sistema real, solo lectura** (resolución F11):
  1. `AIRY_SUPPORT_DIR=$(mktemp -d)`; enviar `initialize`, `tools/call list_cleanup_items` y `tools/call run_safe_cleanup_all {"dry_run": true}` a `.build/debug/airy-mcp`.
  2. Comprobar que salen las fichas nuevas presentes en este Mac, que Docker sale bloqueado si el demonio está parado, que no aparece ningún elemento ámbar en `results` y que solo hay `would_*`/`blocked`.
  3. Comprobar que no se ha movido ni ejecutado nada: `runner` real sin limpiezas (el registro de la carpeta temporal solo tiene `dryRun: true`).
- [ ] **Step 4: App** — `bash scripts/build-app.sh` y `open build/Airy.app`. El controlador decide con el usuario si es la instalada; si no, se usa la build DEBUG con `AIRY_SUPPORT_DIR` propio. Revisar:
  - aparece la hoja de perfil;
  - Limpieza muestra las tres etiquetas, «Solo revisar», «Seleccionar todo lo verde / Seleccionar todo» y «Borrar todo · X GB»;
  - la hoja de confirmación tiene un bloque ámbar aparte y se puede quitar algo con un clic; después se **cancela**;
  - en el Mapa, el hover muestra la etiqueta y su «por qué».

  No confirmar ninguna limpieza real sin el usuario delante. Parar por PID.
- [ ] **Step 5: Commit** (si hubo correcciones) — `fix: revisión final del plan 3 (limpieza agresiva y perfil)` (+ Co-Authored-By).
