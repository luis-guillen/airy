# Airy 1 de 5 — Identidad, seguridad y MCP · Plan de implementación

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** DiskMap pasa a ser Airy (identidad técnica completa con migración de datos), todo borrado pasa por un embudo único con las protecciones de Mole, el riesgo se clasifica en la biblioteca común con modo y perfil, y un servidor MCP `airy-mcp` deja a los agentes consultar el disco, ejecutar solo lo verde y proponer lo demás en la app.

**Architecture:** Se mantiene la librería `DiskMapCore` (sin UI, probada con Swift Testing) y se le añaden ajustes compartidos, protecciones, clasificador, registro de operaciones y todo el servidor MCP; la app `Airy` (SwiftUI) y el ejecutable `airy-mcp` (envoltorio fino de stdio) consumen la misma librería, así que clasifican, validan y ejecutan igual aunque la app esté cerrada. App y MCP solo se comunican por ficheros en `~/Library/Application Support/Airy` y por URLs `airy://`.

**Tech Stack:** Swift 6.4 (solo Command Line Tools), SwiftPM, SwiftUI + AppKit, Swift Testing, `libproc`, MCP (JSON-RPC 2.0 por stdio).

**Spec:** `docs/superpowers/specs/2026-10-20-airy-fase-2-design.md` (§2.1, §2.8, §2.9 «Seguridad del borrado» y «Control del usuario», «Decisiones de Claude tras la revisión del constructor») y `docs/superpowers/specs/2026-10-20-diskmap-design.md` (§4 anti-objetivos, §7b MCP). Listas: `docs/superpowers/research/2026-10-20-mole-inspiracion.md` §2.15. Restricciones heredadas: `.superpowers/sdd/2026-10-20-diskmap-fase-1/progress.md`.

**Fuera de este plan:** icono, paleta y animaciones (plan 2); entradas agresivas del catálogo, interfaz del perfil y textos «Sin problema / Tú decides / No borrar» en la app (plan 3); `get_performance` y `propose_quit_app` (plan 4); Desinstalador y demás secciones (plan 5).

## Global Constraints

- Swift 6.4, SwiftPM, solo Command Line Tools (sin Xcode); `swift build` / `swift test`; plataforma `.macOS(.v15)`; el test target conserva las `unsafeFlags` del plugin de Swift Testing de Package.swift.
- Vistas SwiftUI con el alias `@ViewState` (no `@State`), nunca `.fixedSize(horizontal:false,vertical:true)` en `Text` multilínea; seguir los patrones existentes (`Theme`, `PrimaryButton`, `SectionHeader`).
- Interfaz en **español de España**; nombres de herramientas MCP en inglés, textos de respuesta en español.
- **Nunca** se envía contenido de archivos a la IA ni al MCP: solo rutas, tamaños, fechas, tipos y fichas del catálogo.
- Ubicaciones protegidas, nunca borrables: volúmenes de Docker (`~/Library/Containers/com.docker.docker`, `~/Library/Group Containers/group.com.docker`), iCloud (`~/Library/Mobile Documents`), Mail, Mensajes, Llaveros, AddressBook, Calendarios, Fotos, `/Applications`, `/Library`, `/usr`, `/bin`, `/sbin`, `/private`, `/opt/homebrew`, `/System`; las carpetas personales nunca son verdes; los runtimes en uso (`codex-primary-runtime`) nunca se tocan.
- Toda acción destructiva de la app pasa por `ConfirmSheet` → `AppModel` → `CleanupExecutor`; sin atajos DEBUG que actúen sin confirmación.
- El MCP solo ejecuta lo verde («Borrar sin riesgo») no bloqueado; nunca ámbar ni rojo; el interruptor de agentes apagado bloquea toda herramienta de acción (incluido `dry_run`); no existe herramienta que acepte comandos o rutas arbitrarias para borrar.
- Archivos → Papelera (`FileManager.trashItem`); cachés de herramientas → su comando oficial con array de argumentos (nunca cadena de shell).
- Capturas DEBUG solo de las ventanas de la propia app; para parar la app, matar **solo el PID propio** (nunca `pkill -x`); cada verificación manual usa su propio `AIRY_SUPPORT_DIR` (DEBUG).
- En pruebas y verificación nunca se ejecutan comandos de limpieza reales ni se vacía la Papelera real (`FakeRunner`/`FakeProbes`, carpetas temporales; contra el sistema real solo herramientas de lectura y `dry_run: true`).
- No tocar los ajustes de confianza del Llavero (sin `add-trusted-cert`); el certificado antiguo «DiskMap Local Signing» no se toca.
- Mole es GPL-3.0: se adaptan ideas y listas de rutas, **nunca código** (ni traducido); se le cita en «Acerca de Airy».
- Identidad: nombre **Airy**, bundle id `local.airy.Airy`, datos `~/Library/Application Support/Airy`, identidad de firma «Airy Local Signing», esquema `airy://`, ejecutable `airy-mcp` en `Airy.app/Contents/MacOS/`, servidor MCP registrado como `airy`, instalación en `/Applications/Airy.app`.
- Commits terminan con `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

1. **App y `airy-mcp` escribiendo a la vez** (historial, registro de operaciones, migración) → no se pierde ni se corrompe ningún registro. Test en Task 2 (`concurrentMigrationsCopyOnce`) y Task 7 (`concurrentAppendsFromTwoLogsKeepAll`, `historyConcurrentAppendsFromTwoStores`).
2. **`settings.json` corrupto, a medias o de una versión futura** → el MCP no ejecuta nada (fallo cerrado), la app avisa y no lo machaca sin preguntar. Test en Task 3 (`corruptSettingsDisallowAgents`, `futureVersionIsUnreadable`) y Task 13 (`unreadableSettingsBlocksActions`).
3. **`airy://` abierto por una web u otra app con parámetros hostiles** (`..`, caracteres de control, motivo de 10 000 caracteres, id inexistente) → se rechaza o recorta y nunca se actúa sin la confirmación. Test en Task 10 (`parseRejectsHostileInput`, `reasonIsSanitisedAndTruncated`).
4. **La ruta cambia entre la comprobación y el borrado** (carpeta sustituida por un enlace a `~/Documents`) → rechazo y nada movido. Test en Task 4 (`identityChangeIsDetected`) y Task 8 (`identityChangeBetweenPlanAndActRefuses`).
5. **El usuario apaga el interruptor mientras un agente limpia en tanda** → lo que queda se bloquea al momento (los ajustes se leen en cada elemento). Test en Task 8 (`liveSettingsReadPerItem`) y Task 13 (`runAllStopsWhenToggleTurnsOffMidBatch`).

---

## Estructura de archivos

```
Package.swift                          name "Airy"; productos DiskMapCore, Airy, airy-mcp
Resources/Info.plist                   identidad Airy + CFBundleURLTypes airy
Resources/Airy.icns, Airy-1024.png, Airy.entitlements   (renombrados; mismo icono)
scripts/build-app.sh                   Airy.app + airy-mcp, identidad nueva, instalación segura
Sources/Airy/                          (antes Sources/DiskMap) app SwiftUI
  AiryApp.swift                        (antes DiskMapApp.swift) escenas, URL, Ajustes, Acerca de
  Settings/SettingsView.swift          Modo, Agentes, Protegido por ti            (nuevo)
  Assistant/AgentsView.swift           pestaña «Conectar agente»                   (nuevo)
Sources/AiryMCP/main.swift             arranque del servidor por stdio             (nuevo)
Sources/DiskMapCore/
  Persistence/AppPaths.swift           rutas de datos Airy y legado DiskMap         (nuevo)
  Persistence/DataMigration.swift      copia DiskMap → Airy                         (nuevo)
  Persistence/OperationLog.swift       registro JSONL con run id y autor            (nuevo)
  Settings/AirySettings.swift          modo, perfiles, agentes, lista del usuario   (nuevo)
  Settings/SettingsStore.swift         settings.json                               (nuevo)
  Settings/ProtectList.swift           «Proteger esto»                             (nuevo)
  Safety/HardProtections.swift         lista dura (Mole §2.15 + restricciones)      (nuevo)
  Safety/PathGate.swift                validación de ruta e identidad               (nuevo)
  Safety/ProcessGuard.swift            guardián de proceso en 3 estados             (nuevo)
  Safety/TimeBudget.swift              presupuestos de tiempo                       (nuevo)
  Safety/RiskClassifier.swift          riesgo efectivo único                        (nuevo)
  Catalog/FolderExplanations.swift     movido desde Sources/Airy/Map/HoverCard.swift
  Integration/AiryURL.swift            airy://propose|show|rescan                   (nuevo)
  Integration/AgentSnippets.swift      textos de conexión + alta en Claude Code     (nuevo)
  MCP/JSONValue.swift, MCPServer.swift, MCPTool.swift, AiryEnvironment.swift, StdioTransport.swift
  MCP/Tools/ReadTools.swift, MCP/Tools/ActionTools.swift
Tests/DiskMapCoreTests/                IdentityTests, MigrationTests, SettingsTests, PathGateTests,
                                       ClassifierTests, ProcessGuardTests, OperationLogTests,
                                       FunnelTests, AiryURLTests, MCPServerTests, MCPReadToolTests,
                                       MCPActionToolTests, AgentSnippetsTests
```

**Ruling — nombres de SwiftPM:** el paquete pasa a `Airy`, el ejecutable a `Airy` (`Sources/Airy`), y la librería sigue llamándose `DiskMapCore` (y su test target `DiskMapCoreTests`): renombrarla tocaría cada `import` de ~70 ficheros sin efecto visible. Consecuencia: el bundle de recursos pasa a `Airy_DiskMapCore.bundle`.

---

### Task 1: Rama `fase-2` y cambio de identidad DiskMap → Airy

**Files:**
- Modify: `Package.swift`, `Resources/Info.plist`, `scripts/build-app.sh`, `scripts/make-icon.swift` (nombre de salida), `Sources/DiskMapCore/Catalog/Catalog.swift:171`, `Sources/DiskMapCore/AI/AIAssistant.swift` (prompts), `Sources/DiskMapCore/System/CommandRunner.swift:205` (prefijo temporal)
- Rename: `Sources/DiskMap/` → `Sources/Airy/`; `DiskMapApp.swift` → `AiryApp.swift` (`struct AiryApp`); `Resources/DiskMap.icns|DiskMap-1024.png|DiskMap.entitlements` → `Airy.*`
- Modify: todas las cadenas visibles «DiskMap» de `Sources/Airy/**` → «Airy»; variables `DISKMAP_*` → `AIRY_*`; `local.diskmap.layout` → `local.airy.layout`; `Notification.Name("DiskMap…")` → `"Airy…"`; carpeta de prueba `DiskMapPrueba` → `AiryPrueba`
- Test: `Tests/DiskMapCoreTests/IdentityTests.swift`; ajustar expectativas que citen «DiskMap» en `AITests.swift`

**Interfaces:**
- Produces: `Catalog.bundleName == "Airy_DiskMapCore.bundle"`; ejecutable `Airy`; Info.plist con `CFBundleIdentifier local.airy.Airy`, `CFBundleExecutable/Name/DisplayName/IconFile Airy`, `CFBundleShortVersionString 0.2.0`, `CFBundleVersion 2`, `NSAppleEventsUsageDescription "Airy usa Finder para vaciar la Papelera."`, `CFBundleURLTypes = [{CFBundleURLName: local.airy.Airy, CFBundleURLSchemes: [airy]}]`.

- [ ] **Step 1: Crear la rama**

Run: `git switch fase-1 && git status --short && git switch -c fase-2`
Expected: árbol limpio; `git branch --show-current` → `fase-2`.

- [ ] **Step 2: Write the failing tests** (`IdentityTests.swift`; leen el repositorio con `#filePath`)

```swift
@Test func resourceBundleNameIsAirys() { #expect(Catalog.bundleName == "Airy_DiskMapCore.bundle") }
@Test func infoPlistHasAiryIdentity() throws {
    let plist = try repoPlist("Resources/Info.plist")
    #expect(plist["CFBundleIdentifier"] as? String == "local.airy.Airy")
    #expect(plist["CFBundleExecutable"] as? String == "Airy")
    let types = plist["CFBundleURLTypes"] as? [[String: Any]]
    #expect(types?.first?["CFBundleURLSchemes"] as? [String] == ["airy"])
}
/// Ningún literal de cadena de Sources/ contiene "DiskMap" (salvo "DiskMapCore") ni "DISKMAP_",
/// excepto Persistence/AppPaths.swift y Persistence/DataMigration.swift (legado, Task 2).
@Test func noDiskMapLeftInStringLiterals() throws {
    #expect(try stringLiteralHits(pattern: #/DiskMap(?!Core)|DISKMAP_/#, under: "Sources",
                                  allow: ["AppPaths.swift", "DataMigration.swift"]) == [])
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `swift test --filter IdentityTests`
Expected: FAIL (bundle `DiskMap_DiskMapCore.bundle`, identificador `local.diskmap.DiskMap`, decenas de literales).

- [ ] **Step 4: Renombrar** con `git mv` y editar según **Files**. `Package.swift`: `name: "Airy"`, productos `.library(name: "DiskMapCore", …)` y `.executable(name: "Airy", targets: ["Airy"])`, `.executableTarget(name: "Airy", dependencies: ["DiskMapCore"], path: "Sources/Airy")`. `WindowGroup("Airy")`, barra lateral «Airy», banner «Airy no puede ver todo el disco», prompts «Eres el asistente de Airy…».

- [ ] **Step 5: `scripts/build-app.sh`**: `APP_NAME="Airy"`, `IDENTITY="Airy Local Signing"`, bundle `Airy_DiskMapCore.bundle`. Instalación (`--install`), en este orden:
  1. copiar a `/Applications/.Airy.app.new` y `codesign --verify --deep --strict` sobre la copia;
  2. si `/Applications/Airy.app` existe: preguntar (como ahora); si está abierta, preguntar y cerrarla con `osascript -e 'tell application id "local.airy.Airy" to quit'` (espera ≤ 10 s; nunca `pkill`); `rm -rf` de la antigua y `mv` de la nueva;
  3. **solo si todo lo anterior fue bien** y existe `/Applications/DiskMap.app`: si está abierta, preguntar y cerrarla con `tell application id "local.diskmap.DiskMap" to quit`; moverla con `mv "/Applications/DiskMap.app" "$HOME/.Trash/DiskMap $(date +%Y%m%d-%H%M%S).app"`; imprimir «✓ DiskMap.app movida a la Papelera».
  4. Recordatorio final: «Vuelve a dar Acceso total al disco a Airy (Ajustes del Sistema › Privacidad y seguridad).»

- [ ] **Step 6: Run tests to verify they pass**

Run: `swift test 2>&1 | tail -3`
Expected: PASS, 245 + 3 pruebas.

- [ ] **Step 7: Empaquetar sin instalar**

Run: `bash scripts/build-app.sh && plutil -extract CFBundleIdentifier raw build/Airy.app/Contents/Info.plist && ls build/Airy.app/Contents/Resources`
Expected: «✓ Firmada con "Airy Local Signing"», `local.airy.Airy`, `Airy.icns` y `Airy_DiskMapCore.bundle`.

- [ ] **Step 8: Commit**

```bash
git add -A && git commit -m "feat: DiskMap pasa a llamarse Airy (identidad, bundle id, firma, esquema)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: Carpeta de datos de Airy y migración desde DiskMap

**Files:**
- Create: `Sources/DiskMapCore/Persistence/AppPaths.swift`, `Sources/DiskMapCore/Persistence/DataMigration.swift`
- Modify: `Sources/Airy/AppModel.swift:166-176` (usa `AppPaths`, migra antes de crear `IndexStore`; `Notice.Kind` gana `.migration`), `Sources/Airy/Assistant/AssistantSession.swift` (migra `claudePath`)
- Test: `Tests/DiskMapCoreTests/MigrationTests.swift`

**Interfaces:**
- Produces:
```swift
public struct AppPaths: Sendable, Equatable {
    public static let folderName = "Airy", legacyFolderName = "DiskMap", legacyBundleID = "local.diskmap.DiskMap"
    public let support: URL
    public let legacySupport: URL?            // nil con AIRY_SUPPORT_DIR
    public init(support: URL, legacySupport: URL?)
    /// `AIRY_SUPPORT_DIR` solo se respeta en compilaciones DEBUG.
    public static func standard(home: String = NSHomeDirectory(),
                                environment: [String: String] = ProcessInfo.processInfo.environment) -> AppPaths
    public var settingsFile: URL     // support/settings.json
    public var operationsFile: URL   // support/operations.jsonl
    public var migrationMarker: URL  // support/.migrated-from-diskmap
}
public enum MigrationResult: Sendable, Equatable { case notNeeded, migrated(copied: [String]), failed(String) }
public enum DataMigration {
    public static func migrateIfNeeded(_ paths: AppPaths) -> MigrationResult
    /// Copia de `legacy` a `current` las claves que falten en `current`; devuelve las copiadas.
    public static func migrateDefaults(from legacy: UserDefaults?, to current: UserDefaults, keys: [String]) -> [String]
}
```

- [ ] **Step 1: Write the failing tests**

```swift
@Test func copiesIndexHistoryAndVolumesLeavingLegacyIntact() throws {
    // legacy: scan.plist, history.json, Volumes/_Volumes_X/scan.plist
    let r = DataMigration.migrateIfNeeded(paths)
    #expect(r == .migrated(copied: ["Volumes", "history.json", "scan.plist"]))
    #expect(try Data(contentsOf: support/"history.json") == legacyHistoryBytes)
    #expect(try snapshot(legacyDir) == legacyBefore)       // nombres, bytes y mtime sin cambios
    #expect(FileManager.default.fileExists(atPath: paths.migrationMarker.path))
}
@Test func doesNotOverwriteExistingAiryData()      // support/history.json previo se conserva tal cual
@Test func secondRunIsNoOp()                       // segunda llamada → .notNeeded
@Test func noLegacyFolderWritesMarker()            // → .notNeeded y marcador escrito
@Test func interruptedMigrationResumes()           // restos ".scan.plist.partial-*" se borran; scan.plist copiado
@Test func concurrentMigrationsCopyOnce() async    // dos tareas a la vez: un .migrated y un .notNeeded; contenido idéntico
@Test func defaultsMigrationCopiesOnlyMissingKeys() // claudePath copiado si falta; no pisa uno existente
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter MigrationTests`
Expected: FAIL — `AppPaths` / `DataMigration` no existen.

- [ ] **Step 3: Implement `migrateIfNeeded`**: crear `support`; `flock(LOCK_EX)` sobre `support/.migration.lock`; borrar restos `.*.partial-*`; si existe el marcador → `.notNeeded`; si no hay legado → escribir marcador, `.notNeeded`; por cada hijo de primer nivel del legado (sin `.DS_Store`) que no exista en `support`: `copyItem` a `.<nombre>.partial-<uuid>` y `rename` al nombre final; al final escribir el marcador (fecha ISO 8601). Error → `.failed(mensaje)` sin marcador (se reintenta en el próximo arranque). Nunca escribe en el legado.

- [ ] **Step 4: Wire the app**: `AppModel.init` usa `AppPaths.standard()` y llama `migrateIfNeeded` antes de crear `IndexStore`; `.failed(m)` → aviso `.migration`: «No se pudieron copiar los datos de \(AppPaths.legacyFolderName) (\(m)). Siguen en su carpeta; Airy lo intentará otra vez al abrirse.» (interpolado, para que `noDiskMapLeftInStringLiterals` siga en verde). `AssistantSession` llama `migrateDefaults(from: UserDefaults(suiteName: AppPaths.legacyBundleID), to: .standard, keys: ["claudePath"])` una vez al iniciar.

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter MigrationTests` → PASS (7). Run: `swift test 2>&1 | tail -3` → todo en verde.

- [ ] **Step 6: Commit** — `feat: Airy copia los datos de DiskMap al primer arranque` (+ Co-Authored-By).

---

### Task 3: Ajustes compartidos (`settings.json`) y lista «Proteger esto»

**Files:**
- Create: `Sources/DiskMapCore/Settings/AirySettings.swift`, `SettingsStore.swift`, `ProtectList.swift`
- Test: `Tests/DiskMapCoreTests/SettingsTests.swift`

**Interfaces:**
- Produces:
```swift
public enum CleanupMode: String, Codable, Sendable, CaseIterable { case aggressive, prudent }   // title: "Agresivo" / "Prudente"
public enum UsageProfile: String, Codable, Sendable, CaseIterable {
    case developer, creative, localAI, gaming, music, basic
    // title: "Programo", "Diseño, foto o vídeo", "Uso IA en local", "Juego", "Música y audio", "Uso básico"
}
public struct AirySettings: Codable, Sendable, Equatable {
    public static let currentVersion = 1
    public var version = 1
    public var mode: CleanupMode = .aggressive
    public var profiles: Set<UsageProfile> = []
    public var agentsEnabled = true
    public var protectedPaths: [String] = []      // forma normalizada de ProtectList.normalise
    public static let defaults = AirySettings()
    public mutating func protect(_ path: String, home: String) -> Bool   // false si inválida o repetida
    public mutating func unprotect(_ pattern: String)
}
public enum SettingsLoad: Sendable, Equatable {
    case missing, loaded(AirySettings), unreadable(String)
    public var effective: AirySettings      // missing → defaults; unreadable → defaults con agentsEnabled = false
    public var allowsAgentActions: Bool     // missing → true; loaded → s.agentsEnabled; unreadable → false
}
public struct SettingsStore: Sendable {
    public init(file: URL)
    public func load() -> SettingsLoad
    public func save(_ settings: AirySettings) throws      // atómico, claves ordenadas, crea la carpeta
    public func resetUnreadable() throws -> AirySettings   // renombra a settings.unreadable-<yyyyMMdd-HHmmss>.json y escribe defaults
}
public struct ProtectList: Sendable, Equatable {
    public init(patterns: [String], home: String)
    /// Recorta, expande `~`, exige absoluta, rechaza `..`/`.`/control, colapsa `//`, quita la `/` final;
    /// devuelve la forma guardada con `~/` si está bajo home.
    public static func normalise(_ raw: String, home: String) -> String?
    /// Patrón que cubre `path` (lo iguala o lo contiene) o que está dentro de `path` (es carpeta superior);
    /// sin distinguir mayúsculas; `*` dentro de un componente (fnmatch).
    public func match(_ path: String) -> String?
}
```
Fichero: `{"version":1,"mode":"aggressive","profiles":[],"agentsEnabled":true,"protectedPaths":[]}`. Claves que falten → valor por defecto; perfiles desconocidos se ignoran; modo desconocido o `version > 1` → `.unreadable`.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func defaultsAreAggressiveAgentsOnEmptyLists() {
    let s = AirySettings.defaults
    #expect(s.mode == .aggressive && s.agentsEnabled && s.profiles.isEmpty && s.protectedPaths.isEmpty)
}
@Test func roundTripsAndFillsMissingKeys()          // {"version":1} → defaults; save+load → igual
@Test func corruptSettingsDisallowAgents() {        // "{no json" → .unreadable; allowsAgentActions == false; effective.agentsEnabled == false
}
@Test func futureVersionIsUnreadable()              // {"version":2} → .unreadable
@Test func unknownProfileIgnoredUnknownModeUnreadable()
@Test func resetUnreadableKeepsBadFileAside()       // queda settings.unreadable-*.json con los bytes originales
@Test func normaliseRules() {
    #expect(ProtectList.normalise(" ~/Library/Caches/foo/ ", home: h) == "~/Library/Caches/foo")
    #expect(ProtectList.normalise("relativa/x", home: h) == nil)
    #expect(ProtectList.normalise("/a/../b", home: h) == nil)
    #expect(ProtectList.normalise("/a\u{7}b", home: h) == nil)
}
@Test func matchInsideAncestorCaseAndWildcard() {
    let list = ProtectList(patterns: ["~/Library/Caches/Foo", "~/Models/*.gguf"], home: h)
    #expect(list.match(h + "/library/caches/foo/x") == "~/Library/Caches/Foo")
    #expect(list.match(h + "/Library/Caches") == "~/Library/Caches/Foo")   // carpeta superior
    #expect(list.match(h + "/Models/llama.gguf") != nil)
    #expect(list.match(h + "/Library/Caches/Bar") == nil)
}
@Test func protectDeduplicates()                    // protect dos veces → segunda false, una sola entrada
```

- [ ] **Step 2: Run test to verify it fails** — `swift test --filter SettingsTests` → FAIL (tipos inexistentes).
- [ ] **Step 3: Implement** según Interfaces.
- [ ] **Step 4: Run tests to verify they pass** — `swift test --filter SettingsTests` → PASS (9).
- [ ] **Step 5: Commit** — `feat: ajustes compartidos de Airy y lista «Proteger esto»` (+ Co-Authored-By).

---

### Task 4: Protecciones duras y validación de ruta (`PathGate`)

**Files:**
- Create: `Sources/DiskMapCore/Safety/HardProtections.swift`, `Sources/DiskMapCore/Safety/PathGate.swift`
- Modify: `Sources/DiskMapCore/Catalog/RiskPolicy.swift` (las listas `sealed*`/`protectedSystemRoots` y `trashRefusal` pasan a `HardProtections`; `minimumRisk`, `effectiveRisk`, `canonical`, `isInside` se quedan)
- Test: `Tests/DiskMapCoreTests/PathGateTests.swift`

**Interfaces:**
- Consumes: `ProtectList` (Task 3), `Catalog`.
- Produces:
```swift
public struct ProtectionMatch: Sendable, Equatable {
    public enum Source: String, Sendable { case airy, user }
    public let source: Source; public let pattern: String; public let reason: String   // reason en español
}
public struct HardProtections: Sendable {
    public static let standard: HardProtections
    /// `canonicalPath` en minúsculas (RiskPolicy.canonical). `nil` si no está protegida.
    public func match(canonicalPath: String, home: String, catalog: Catalog?) -> ProtectionMatch?
    /// Rutas cuyo inodo nunca se borra (raíces críticas + home); las resuelve `PathGate`.
    public var criticalRoots: [String] { get }
}
public struct FileIdentity: Sendable, Equatable {
    public let device: UInt64, inode: UInt64, parentDevice: UInt64, parentInode: UInt64, isSymlink: Bool
}
public struct ValidatedPath: Sendable, Equatable { public let path: String; public let forms: [String]; public let identity: FileIdentity }
public struct PathRefusal: Error, Sendable, Equatable { public let reason: String }
public struct PathGate: Sendable {
    public init(home: String, catalog: Catalog?, userProtected: ProtectList, protections: HardProtections = .standard)
    public func validate(_ path: String) -> Result<ValidatedPath, PathRefusal>
    /// Vuelve a hacer `lstat` de la ruta y su padre justo antes de actuar; distinto ⇒ rechazo.
    public func confirmUnchanged(_ validated: ValidatedPath) -> PathRefusal?
}
```

**Lista dura** (`HardProtections.standard`, adaptada de Mole §2.15 + restricciones; nunca editable por el usuario y siempre aplicada encima de sus ajustes). Rutas con `~` relativas a home; comparación sin mayúsculas:

| Grupo | Regla | Valores |
|---|---|---|
| Raíces críticas | la ruta **es** una de ellas (texto o inodo) | `/`, `/bin`, `/dev`, `/sbin`, `/usr`, `/System`, `/System/Volumes/Data`, `/Library`, `/Library/Apple`, `/Library/Application Support`, `/Library/Extensions`, `/Library/Keychains`, `/Applications`, `/Applications/Safari.app`, `/Volumes`, `/opt`, `/opt/homebrew`, `/Users`, `/Users/Shared`, `/Users/Guest`, `/private`, `/private/tmp`, `/etc`, `/var`, `/var/db`, `/var/audit`, `/var/root`, `/private/var`, `/private/var/tmp`, `/private/var/folders`, `/private/var/db`, `/private/var/audit`, `/private/var/root`, `/Network`, `/cores`, `/home`, `/net`, `/tmp`; además cualquier `/Users/<nombre>` y el home (todas sus formas) |
| Selladas del sistema | ni ella, ni dentro, ni superiores | `/System`, `/Applications`, `/Library`, `/usr`, `/bin`, `/sbin`, `/private` (excepción ya existente: contenido de la carpeta temporal del usuario), `/opt/homebrew`, `/private/var/db/powerlog` |
| Selladas de home | ni ella, ni dentro, ni superiores | `Library/Containers/com.docker.docker`, `Library/Group Containers/group.com.docker`, `Library/Mobile Documents`, `Library/Mail`, `Library/Messages`, `Library/Keychains`, `Library/Accounts`, `Library/Contacts`, `Library/Calendars`, `Library/Application Support/AddressBook`, `Library/Photos`, `Pictures/*.photoslibrary`, `Library/Application Support/com.apple.idleassetsd`, `Library/Application Support/com.apple.wallpaper`, `Library/Preferences/com.apple.dock.plist`, `Library/Preferences/com.apple.finder.plist`, `Library/Preferences/ByHost/com.apple.bluetooth.*`, `Library/Preferences/com.apple.wifi.*`, `Library/Preferences/com.apple.networkextension*`, `Library/Caches/pypoetry/virtualenvs`, `Library/Caches/org.R-project.R/R/renv`, `.prometheus/data`, `.orbstack`, `Library/Group Containers/*dev.orbstack`, `.cache/codex-runtimes/codex-primary-runtime`, `.codex/auth.json`, `.codex/sessions`, `.codex/history.jsonl`, `.codex/config.toml`, `.claude.json`, `.claude/projects`, `.ssh`, `.gnupg`, `.gitconfig.bak*`, `.zsh_history.bak*`, `.bash_history.bak*` |
| Hacia arriba (home) | ella y sus superiores; su contenido sí | home, `Documents`, `Desktop`, `Pictures`, `Movies`, `Music`, `Downloads`, `orca`, `Projects`, `Library`, `Applications`, `.Trash`, `.cache`, `.config`, `.local`, `.local/bin`, `.local/lib`, `.local/share`, `.local/state`, `Library/Application Support`, `Library/Caches`, `Library/Containers`, `Library/Group Containers`, `Library/Preferences`, `Library/Logs`, `Library/Developer` |
| Fragmentos | algún componente contiene (sin mayúsculas) | `systemsettings`, `systempreferences`, `controlcenter`, `com.apple.settings`, `com.apple.notes`, `finder.cache`, `dock.cache`, `coreaudio`, `com.apple.audio.`, `com.apple.fontregistry`, `spotlight`, `cloudkit`, `com.apple.containermanagerd`, `com.apple.homed`, `com.apple.ap.adprivacyd`, `familycircle`, `homekit`, `shortcutssandboxcache`, `gippseudonymousid`, `cctclearcutlogger`, `com.apple.e5rt.e5bundlecache`, `com.crowdstrike.`, `com.sentinelone.`, `com.sentinel-labs.`, `com.eset.`, `com.jamf.`, `com.jamfsoftware.`, `com.paloaltonetworks.`, `com.cisco.anyconnect`, `com.cisco.secureclient`, `1password`, `keychain`, `bitwarden`, `lastpass`, `keepass`, `dashlane`, `enpass`, `gnupg` |
| Datos de apps sensibles (Capa C) | todo bajo `~/Library/{Application Support,Containers,Group Containers}/<carpeta>` si el nombre normalizado (minúsculas sin espacios, `.`, `-`, `_`) **contiene** un fragmento largo o su último componente DNS **es** uno corto; excepto subárboles `Caches`, `Data/Library/Caches`, `Data/tmp`, y rutas que un patrón literal del catálogo (no `info`) declara **dentro** de esa carpeta (p. ej. `Claude/vm_bundles`) | largos: `1password bitwarden lastpass dashlane keepass authy yubico jetbrains vscode sublime typora cursor claude chatgpt openai codex ollama lmstudio perplexity drawthings windsurf gemini postman insomnia charles proxyman clash surge tailscale zerotier wireguard openvpn cloudflare nordvpn expressvpn protonvpn mullvad githubdesktop gitkraken sublimemerge iterm2 kitty alacritty wezterm docker orbstack vmware parallels virtualbox vagrant alfred raycast karabiner rectangle bartender obsidian notion logseq evernote dayone goodnotes adobe figma sketch affinity pixelmator maxon autodesk nativeinstruments izotope fabfilter slack discord teams telegram whatsapp wechat dropbox onedrive googledrive backblaze teamviewer anydesk`; cortos (igualdad): `jan box paw code bear zoom warp nova fork utm tower` |

Motivos visibles (ejemplos): «Carpeta crítica del sistema.», «Ubicación protegida por Airy: Llaveros.», «Datos de una app sensible (1Password).», «Lo has protegido tú (~/…).»

- [ ] **Step 1: Write the failing tests** (home temporal con la estructura necesaria)

```swift
@Test func rejectsRelativeDotDotAndControlChars() {
    for p in ["Library/x", "/tmp/a/../b", "/a\u{7}b", "", "/a//b"] { #expect(gate.validate(p).failure != nil) }
}
@Test func rejectsCriticalRootsCaseInsensitive()   // "/usr", "/USR", "/applications", "/System/Library"
@Test func rejectsHomeAndUsersChildren()           // home, "/Users/Shared", "/Users/" + NSUserName()
@Test func rejectsAliasOfCriticalRootByInode()     // "/System/Volumes/Data/Users" (mismo inodo que /Users)
@Test func resolvesSymlinkedAncestor()             // tmp/enlace → home/Library/Mail; validate(tmp/enlace/x) falla
@Test func symlinkTargetIsValidated()              // enlace → home/Library/Keychains: falla
@Test func identityChangeIsDetected() {            // validar carpeta; sustituirla por enlace a home/Documents
    #expect(gate.confirmUnchanged(validated) != nil)
}
@Test func userProtectedAndItsAncestorsRefused()   // protegido ~/Library/Caches/Foo: Foo/x y ~/Library/Caches/… superior
@Test func hardProtectionsIgnoreUserSettings()     // ProtectList vacía: home/Library/Keychains/x sigue fallando
@Test func sensitiveAppDataRefusedCatalogExceptionAllowed() {
    #expect(gate.validate(h + "/Library/Application Support/1Password/data").failure != nil)
    #expect(gate.validate(h + "/Library/Application Support/Claude/vm_bundles").failure == nil)   // catálogo real
    #expect(gate.validate(h + "/Library/Application Support/Claude/otra").failure != nil)
    #expect(gate.validate(h + "/Library/Containers/com.tinyspeck.slackmacgap/Data/Library/Caches/x").failure == nil)
}
@Test func fragmentsAnywhere()                     // ~/Library/Caches/com.apple.FontRegistry, …/com.crowdstrike.x
@Test func userTempDirContentsStillAllowed()       // comportamiento de la fase 1
```

- [ ] **Step 2: Run test to verify it fails** — `swift test --filter PathGateTests` → FAIL.
- [ ] **Step 3: Implement `PathGate.validate`** en este orden: sintaxis (no vacía, empieza por `/`, ≤ 1024 bytes, sin escalares < 0x20 ni 0x7F, sin componentes vacíos/`.`/`..`) → `lstat` (debe existir; identidad + `lstat` del padre) → formas canónicas: literal, padre resuelto con `realpath` + último componente, y destino del enlace si lo es → por cada forma: raíz crítica / `/users/<x>` / home, `HardProtections.match`, `userProtected.match`, reglas de catálogo de `CleanupExecutor.unsafeTrashReason` (fichas `doNotTouch` relacionadas y cachés «solo con su comando oficial», movidas aquí) → `(st_dev, st_ino)` del destino frente al conjunto de inodos de raíces críticas y home (calculado una vez con `stat`).
- [ ] **Step 4: Run tests** — `swift test --filter PathGateTests` → PASS (12); `swift test --filter CleanupTests` → las pruebas de rechazo de la fase 1 siguen en verde.
- [ ] **Step 5: Commit** — `feat: protecciones duras ampliadas y validación de ruta con identidad` (+ Co-Authored-By).

---

### Task 5: Clasificador de riesgo único (catálogo + modo + perfil + protecciones)

**Files:**
- Create: `Sources/DiskMapCore/Safety/RiskClassifier.swift`
- Modify: `Sources/DiskMapCore/Catalog/Catalog.swift` (campos nuevos de `CatalogEntry`), `Sources/DiskMapCore/Model/FileNode.swift` (`Risk.label`), `Sources/DiskMapCore/Cleanup/CleanupScanner.swift` (usa el clasificador; `CleanupItem` gana campos), `Sources/DiskMapCore/UIState/CleanupBoard.swift` (orden y `canSelect`), `Sources/DiskMapCore/AI/AIAssistant.swift:252` (veredicto vía clasificador)
- Test: `Tests/DiskMapCoreTests/ClassifierTests.swift`

**Interfaces:**
- Consumes: `AirySettings`, `ProtectList` (Task 3), `HardProtections`, `ProtectionMatch` (Task 4).
- Produces (API que el plan 3 amplía con entradas agresivas y perfiles; **regla de extensión:** toda entrada nueva solo puede subir el riesgo, salvo `aggressiveRisk`, acotado abajo por `regenerates` y por los suelos):
```swift
extension CatalogEntry {   // JSON opcionales; ausentes ⇒ comportamiento de la fase 1
    public var aggressiveRisk: Risk?        // "aggressiveRisk"
    public var preselectInAggressive: Bool  // "preselectInAggressive", false
    public var profiles: [UsageProfile]     // "profiles", []
    public var processNames: [String]       // "processNames", [] (Task 6)
}
extension Risk { public var label: String }   // "Sin problema" / "Tú decides" / "No borrar"
public struct Classification: Sendable, Equatable {
    public var risk: Risk
    public var preselected: Bool
    public var highlighted: Bool             // coincide con algún perfil del usuario
    public var protection: ProtectionMatch?
    public var keptPaths: [String]           // rutas que quedan tras quitar las protegidas (fichas .trash)
    public var reasons: [String]
}
public struct RiskClassifier: Sendable {
    public init(catalog: Catalog, settings: AirySettings, home: String, protections: HardProtections = .standard)
    public func baseRisk(of entry: CatalogEntry) -> Risk
    public func classify(entry: CatalogEntry, paths: [String], ai: Risk? = nil) -> Classification
    public func classify(path: String, ai: Risk? = nil) -> Classification
}
// CleanupItem gana (con valores por defecto en init): preselected = false, highlighted = false,
// protection: ProtectionMatch? = nil, blockedReason: String? = nil  (Task 6 lo rellena)
// CleanupScanner.init gana `classifier: RiskClassifier? = nil` (nil ⇒ RiskClassifier(catalog:settings:.defaults,home:))
```
Algoritmo de `classify(entry:paths:ai:)`:
1. `base = baseRisk(entry)`: en Prudente, `entry.risk`; en Agresivo, `entry.aggressiveRisk` si es mayor que `entry.risk`, o si es menor **y** `entry.regenerates` **y** `entry.risk != .doNotTouch`; si no, `entry.risk`.
2. Protecciones (dura primero, luego del usuario) por ruta. Fichas `.trash`: las rutas protegidas salen de `keptPaths`; si no queda ninguna (y había), `risk = .doNotTouch` con `protection`. Fichas `.command`/`.info`: cualquier protección relacionada (dentro o superior) ⇒ `.doNotTouch`.
3. `risk = strictest(base, ai, RiskPolicy.minimumRisk(path:home:) de cada ruta conservada)`.
4. `highlighted = !Set(entry.profiles).isDisjoint(with: settings.profiles)`; el perfil nunca toca `risk`.
5. `preselected = risk == .safe || (mode == .aggressive && risk == .yourCall && entry.preselectInAggressive)`.
`classify(path:ai:)`: ficha de `catalog.match` → `baseRisk`; protección (incluida «es superior de algo protegido») ⇒ `.doNotTouch`; si no, `RiskPolicy.effectiveRisk(path:home:catalog:ai:)`.
`CleanupBoard`: dentro de cada grupo, `highlighted` primero, luego bytes desc e id; `canSelect` exige además `protection == nil && blockedReason == nil`.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func prudentUsesCatalogRisk()
@Test func aggressiveLowersOnlyRegenerableEntries() {
    let e = entry(risk: .yourCall, aggressiveRisk: .safe, regenerates: true)
    #expect(classifier(.aggressive).classify(entry: e, paths: [cache]).risk == .safe)
    #expect(classifier(.prudent).classify(entry: e, paths: [cache]).risk == .yourCall)
    #expect(classifier(.aggressive).classify(entry: e.with(regenerates: false), paths: [cache]).risk == .yourCall)
}
@Test func aggressiveNeverUnlocksDoNotTouch()
@Test func personalFolderNeverGreenEvenInAggressive()   // home/Projects/app/node_modules con aggressiveRisk .safe → .yourCall
@Test func profilesNeverChangeRisk() {                  // las 64 combinaciones de UsageProfile dan el mismo risk
}
@Test func aiCanOnlyRaise()                             // ai .safe sobre .yourCall → .yourCall; ai .doNotTouch → .doNotTouch
@Test func userProtectedMakesItemRed()
@Test func protectedChildIsDroppedFromAggregateItem()   // user-logs con un hijo «…/CloudKit»: keptPaths sin él, risk sin cambiar
@Test func hardProtectionBeatsUserSettings()            // ficha safe con ruta home/Library/Keychains → .doNotTouch
@Test func preselection()                               // Agresivo+flag preselecciona yourCall; Prudente nunca
@Test func scannerRiskEqualsClassifier() async          // CleanupScanner(classifier:) → item.risk == classify(entry:paths:).risk
@Test func bundledCatalogDecodesWithDefaults()          // aggressiveRisk nil, profiles [] en todas las fichas
@Test func highlightedItemsComeFirstWithinGroup()
```

- [ ] **Step 2: Run test to verify it fails** — `swift test --filter ClassifierTests` → FAIL.
- [ ] **Step 3: Implement** según Interfaces; `CleanupScanner.findItems` toma riesgo, `paths = keptPaths`, `preselected`, `highlighted`, `protection` del clasificador (con `usedBy` no vacío ⇒ `.doNotTouch`, como ahora); `AIAssistant` recibe `classifier: RiskClassifier?` y lo usa en lugar de `RiskPolicy.effectiveRisk` cuando existe.
- [ ] **Step 4: Run tests** — `swift test 2>&1 | tail -3` → todo en verde (incluidos `CleanupTests`, `CleanupBoardTests`, `AITests`).
- [ ] **Step 5: Commit** — `feat: clasificador de riesgo único con modo, perfil y protecciones` (+ Co-Authored-By).

---

### Task 6: Guardián de proceso en tres estados y presupuestos de tiempo

**Files:**
- Create: `Sources/DiskMapCore/Safety/ProcessGuard.swift`, `Sources/DiskMapCore/Safety/TimeBudget.swift`
- Modify: `Sources/DiskMapCore/Cleanup/ReferenceChecker.swift` (resultado con `complete`), `Sources/DiskMapCore/Cleanup/CleanupScanner.swift` (`blockedReason` si la comprobación de referencias no terminó), `Sources/DiskMapCore/Resources/catalog.json` (`processNames`)
- Test: `Tests/DiskMapCoreTests/ProcessGuardTests.swift`

**Interfaces:**
- Produces:
```swift
public enum TimeBudget {
    public static let processScan: Duration = .seconds(3)
    public static let sizeMeasure: Duration = .seconds(30)
    public static let references: TimeInterval = 10
    /// `nil` si no termina a tiempo (la tarea se cancela).
    public static func run<T: Sendable>(_ limit: Duration, _ operation: @escaping @Sendable () async -> T) async -> T?
}
public struct RunningProcess: Sendable, Equatable { public let pid: Int32; public let name: String; public let executablePath: String? }
public protocol ProcessListing: Sendable {
    func processes() -> [RunningProcess]?                                   // nil = no se pudo leer
    func holders(ofPathsUnder paths: [String]) -> [RunningProcess]?         // nil = no se sabe
}
public struct LibprocListing: ProcessListing { public init() }   // proc_listallpids, proc_name, proc_pidpath,
    // PROC_PIDLISTFDS + PROC_PIDFDVNODEPATHINFO; excluye el PID propio; procesos no inspeccionables (EPERM) se saltan
public enum GuardState: Sendable, Equatable { case stopped, running(String), unknown(String) }
public struct ProcessGuard: Sendable {
    public init(listing: any ProcessListing = LibprocListing(), budget: Duration = TimeBudget.processScan)
    /// Nombres sin distinguir mayúsculas contra `name` y el último componente de `executablePath`.
    /// `checkOpenFiles`: además, ¿algún proceso tiene abierto un fichero bajo `paths` (caché viva, SQLite)?
    public func check(processNames: [String], paths: [String], checkOpenFiles: Bool) async -> GuardState
}
extension ReferenceChecker {
    public func referencesChecked(toAny needles: [String], timeout: TimeInterval) async -> (found: [String: [String]], complete: Bool)
}
```
`processNames` en catalog.json: `pnpm`, `pnpm-cache` → `["pnpm"]`; `npm` → `["npm"]`; `uv` → `["uv"]`; `pip` → `["pip", "pip3"]`; `conda` → `["conda"]`; `cargo` → `["cargo"]`; `homebrew` → `["brew"]`; `xcode-deriveddata` → `["Xcode", "xcodebuild"]`; `xcode-simulators` → `["Simulator", "xcodebuild"]`; `ollama-models` → `["ollama"]`; `whisper-cache` → `["whisper"]`.
Textos: `running` → «Está en marcha: \(nombre). Ciérralo antes de limpiar.»; `unknown` → «No se pudo comprobar si está en uso; Airy no lo toca.»; referencias incompletas → «No se pudo comprobar a tiempo si lo usa algún proyecto.»

- [ ] **Step 1: Write the failing tests**

```swift
@Test func stoppedWhenNoProcessMatches() async
@Test func runningWhenNameMatchesCaseInsensitive() async     // "PNPM" frente a ["pnpm"]
@Test func unknownWhenListingFails() async                   // processes() == nil → .unknown
@Test func unknownWhenListingIsTooSlow() async               // listado falso que tarda 5 s, budget 0,2 s → .unknown
@Test func runningWhenAnotherProcessHoldsAFile() async       // holders → [Brave Helper] → .running
@Test func unknownWhenHoldersUnknown() async
@Test func timeBudgetReturnsNilOnTimeout() async
@Test func libprocListsProcessesAndExcludesSelf() {          // real: no nil, no vacío, sin ProcessInfo.processIdentifier
}
@Test func incompleteReferenceCheckBlocksItem() async        // timeout 0 sobre un árbol con needle: item.blockedReason != nil; canSelect false
```

- [ ] **Step 2: Run test to verify it fails** — `swift test --filter ProcessGuardTests` → FAIL.
- [ ] **Step 3: Implement** según Interfaces (la llamada a libproc corre dentro de `TimeBudget.run`).
- [ ] **Step 4: Run tests** — `swift test --filter ProcessGuardTests` → PASS (9); `swift test 2>&1 | tail -3` → verde.
- [ ] **Step 5: Commit** — `feat: guardián de proceso en tres estados y presupuestos de tiempo` (+ Co-Authored-By).

---

### Task 7: Registro de operaciones exportable y historial seguro entre procesos

**Files:**
- Create: `Sources/DiskMapCore/Persistence/OperationLog.swift`
- Modify: `Sources/DiskMapCore/Persistence/IndexStore.swift` (`append` con `flock` entre procesos; `CleanupRecord.byAgent`)
- Test: `Tests/DiskMapCoreTests/OperationLogTests.swift`

**Interfaces:**
- Produces:
```swift
public enum Actor: Codable, Sendable, Equatable { case user; case agent(client: String) }
    // JSON: {"type":"user"} / {"type":"agent","client":"claude-code"}
public struct OperationRecord: Codable, Sendable, Equatable {
    public var runID: UUID, date: Date, actor: Actor
    public var action: String      // "clean" | "trash_paths" | "empty_trash" | "propose" | "show" | "rescan"
    public var itemID: String?, title: String
    public var paths: [String], command: [String]?
    public var dryRun: Bool
    public var outcome: String     // "freed" | "moved_to_trash" | "blocked" | "failed" | "would_trash" | "would_run" | "pending_user" | "requested"
    public var bytes: Int64, message: String?, proposedBy: String?
}
public final class OperationLog: Sendable {
    public init(file: URL)
    public func append(_ record: OperationRecord) throws   // una línea JSON + "\n"; O_APPEND|O_CREAT, 0600; flock(LOCK_EX)
    public func records(limit: Int? = nil) throws -> [OperationRecord]   // más recientes al final; líneas ilegibles se saltan
    public func exportJSON() throws -> Data   // {"exportedAt": ISO8601, "records": [...]}, claves ordenadas, con sangría
}
// CleanupRecord gana `public var byAgent: Bool` (decodeIfPresent → false; se codifica solo si true).
// IndexStore.append: flock(LOCK_EX) sobre <directory>/history.lock alrededor de leer-modificar-escribir.
```

- [ ] **Step 1: Write the failing tests**

```swift
@Test func appendAndReadBack()
@Test func skipsCorruptLine()                          // línea basura entre dos válidas → 2 registros
@Test func concurrentAppendsFromTwoLogsKeepAll() async  // dos OperationLog, mismo fichero, 200 cada uno → 400
@Test func historyConcurrentAppendsFromTwoStores() async // dos IndexStore, misma carpeta, 100 cada uno → history().count == 200
@Test func exportIsValidJSONWithRunIDsAndActors()
@Test func recordFieldsAreMetadataOnly() {             // Mirror: exactamente los 14 campos listados (nadie añade "contents")
}
@Test func oldHistoryWithoutByAgentDecodes()
```

- [ ] **Step 2: Run test to verify it fails** — `swift test --filter OperationLogTests` → FAIL.
- [ ] **Step 3: Implement** según Interfaces.
- [ ] **Step 4: Run tests** — `swift test --filter OperationLogTests` → PASS (7); `swift test --filter IndexStoreTests` → verde.
- [ ] **Step 5: Commit** — `feat: registro de operaciones exportable con run id y autor` (+ Co-Authored-By).

---

### Task 8: Embudo único de borrado (vista previa, autor y revalidación)

**Files:**
- Modify: `Sources/DiskMapCore/Cleanup/CleanupExecutor.swift` (reescritura interna: planificar → actuar)
- Test: `Tests/DiskMapCoreTests/FunnelTests.swift`

**Interfaces:**
- Consumes: `SettingsLoad` (Task 3), `PathGate` (Task 4), `RiskClassifier` (Task 5), `ProcessGuard`, `TimeBudget` (Task 6), `OperationLog`, `Actor` (Task 7).
- Produces:
```swift
public struct OperationContext: Sendable, Equatable {
    public let runID: UUID, actor: Actor, proposedBy: String?
    public static func user(runID: UUID = UUID(), proposedBy: String? = nil) -> OperationContext
    public static func agent(_ client: String, runID: UUID = UUID()) -> OperationContext
}
public enum CleanupPreview: Sendable, Equatable {
    case wouldTrash(paths: [String], bytes: Int64)
    case wouldRun(command: [String], bytes: Int64, upperBound: Bool)
    case blocked(reason: String)
}
// CleanupExecutor.init gana (con valores por defecto, sin romper llamadas existentes):
//   settings: @escaping @Sendable () -> SettingsLoad = { .missing },
//   log: OperationLog? = nil, processGuard: ProcessGuard = ProcessGuard(),
//   protections: HardProtections = .standard
public func preview(_ item: CleanupItem, context: OperationContext = .user()) async -> CleanupPreview
public func execute(_ item: CleanupItem, context: OperationContext = .user()) async -> CleanupOutcome
public func trashPaths(_ paths: [String], title: String, context: OperationContext = .user()) async -> CleanupOutcome
public func emptyTrash(context: OperationContext = .user()) async -> CleanupOutcome
public func wouldRefuseTrash(path: String) -> Bool     // = PathGate.validate falla (misma regla en interfaz y ejecutor)
```
Un solo camino privado `plan(item, context) async -> Result<PlannedAction, PathRefusal>`; `preview` lo devuelve sin actuar y `execute` lo ejecuta. Orden del plan: `settings()` **leído en cada llamada** → clasificador vivo (ficha viva del catálogo + ajustes vivos) → política de agente (`allowsAgentActions`; `risk == .safe`; si no, «Solo se ejecuta lo marcado «Sin problema»…») → bloqueos actuales (`usedBy`, `.doNotTouch`, `.info`, apps abiertas `mustBeClosed`) → `ProcessGuard` (`checkOpenFiles` solo en fichas `.trash`) → referencias con `referencesChecked` (`complete == false` ⇒ bloqueado) → por ruta: pertenece a los patrones de la ficha + `PathGate.validate` → tamaños con `TimeBudget.sizeMeasure` (agotado ⇒ bloqueado). Actuar: por cada ruta, `confirmUnchanged` y luego `trashItem` (única llamada a `trashItem` del código). Agentes: `trashPaths` y `emptyTrash` con contexto de agente ⇒ `.blocked` siempre. Cada `preview`/`execute`/`trashPaths`/`emptyTrash` añade un `OperationRecord` (`dryRun` en vista previa); el historial marca `byAgent`.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func agentCannotExecuteYourCall() async          // .blocked; runner.calls vacío; fichero intacto
@Test func agentBlockedWhenToggleOff() async           // settings .loaded(agentsEnabled: false)
@Test func agentBlockedWhenSettingsUnreadable() async
@Test func agentCannotTrashPathsOrEmptyTrash() async   // probes.emptyCount == 0
@Test func agentSafeItemExecutesAndIsLogged() async {
    #expect(outcome == .movedToTrash(10_000))
    #expect(try log.records().last?.actor == .agent(client: "test"))
    #expect(try store.history().last?.byAgent == true)
}
@Test func previewMovesNothingAndMatchesExecute() async   // preview == .wouldTrash(paths, bytes); ficheros siguen; execute mueve esos bytes
@Test func previewRunsNoCommand() async                   // ficha .command → .wouldRun(["uv","cache","clean"],…); runner.calls vacío
@Test func previewAndExecuteBlockForTheSameReason() async // para usedBy, apps abiertas, proceso desconocido, protegido
@Test func identityChangeBetweenPlanAndActRefuses() async // gancho interno beforeMove sustituye la carpeta por enlace a home/Documents → .blocked; Documents intacto
@Test func userProtectedRefusedAtExecution() async
@Test func liveSettingsReadPerItem() async                // ajustes en Mutex: 1.º execute de agente ok, se apaga, 2.º .blocked
@Test func trashItemOnlyCalledFromTheFunnel() throws {    // fuente: "trashItem(" solo en CleanupExecutor.swift;
    // "removeItem(" / "unlink(" / "rmdir(" solo en SystemProbes.swift (vaciar Papelera), IndexStore.swift (índice corrupto),
    // DataMigration.swift (restos .partial), CommandRunner.swift y AIAssistant.swift (sus propios temporales)
}
```
(El gancho es un parámetro `internal` de `init`, `beforeMove: (@Sendable (String) -> Void)? = nil`, solo para pruebas.)

- [ ] **Step 2: Run test to verify it fails** — `swift test --filter FunnelTests` → FAIL.
- [ ] **Step 3: Implement** según Interfaces.
- [ ] **Step 4: Run tests** — `swift test 2>&1 | tail -3` → todo en verde (las ~60 pruebas de `CleanupTests` deben seguir pasando; si una cambia de motivo, el texto nuevo ha de ser al menos igual de estricto).
- [ ] **Step 5: Commit** — `feat: embudo único de borrado con vista previa, autor y revalidación` (+ Co-Authored-By).

---

### Task 9: La app usa ajustes, clasificador y embudo (Ajustes, «Proteger esto», vista previa, Acerca de)

**Files:**
- Create: `Sources/Airy/Settings/SettingsView.swift`
- Modify: `Sources/Airy/AppModel.swift`, `Sources/Airy/AiryApp.swift` (escena `Settings`, «Acerca de Airy»), `Sources/Airy/Cleanup/CleanupFlow.swift` + `ConfirmSheet.swift` (vista previa por fila, `runID` por tanda), `Sources/Airy/Cleanup/CleanupRow.swift`, `Sources/Airy/Map/MapView.swift` (menú contextual), `Sources/Airy/Map/HoverCard.swift` (riesgo por `model.classify(path:)`)
- Test: `Tests/DiskMapCoreTests/CleanupBoardTests.swift` (`protectedItemHasNoCheckbox`)

**Interfaces:**
- Consumes: Tasks 2–8.
- Produces (`AppModel`, usados por Tasks 10 y 14):
```swift
let paths: AppPaths
let operationLog: OperationLog
private(set) var settingsLoad: SettingsLoad
var settings: AirySettings { settingsLoad.effective }
func updateSettings(_ change: (inout AirySettings) -> Void)   // guarda; si cambia modo o lista → refreshCleanup()
func resetSettings()                                          // SettingsStore.resetUnreadable
func protect(path: String)                                    // updateSettings { $0.protect(path, home:) }
func classify(path: String) -> Classification
func preview(_ items: [CleanupItem]) async -> [String: CleanupPreview]
func perform(_ item: CleanupItem, context: OperationContext) async -> CleanupOutcome
func trash(paths: [String], title: String, context: OperationContext) async -> CleanupOutcome
```
Textos: Ajustes › «Modo de limpieza» (segmentado «Agresivo» / «Prudente»; pie Agresivo: «Borra también lo que se vuelve a descargar o reconstruir solo.»; Prudente: «Solo lo más evidente, sin nada «Depende de ti» preseleccionado.»); «Agentes» (interruptor «Permitir que los agentes ejecuten limpiezas seguras»); «Protegido por ti» (lista con botón quitar, «Añadir carpeta…» con `NSOpenPanel`, vacío: «Nada todavía. Usa «Proteger esto» en el Mapa o en Limpieza.»). Ajustes ilegibles: aviso `.settings` «No se pudieron leer los ajustes (\(motivo)). Los agentes no pueden limpiar hasta que los restablezcas.» con botón «Restablecer ajustes». Menú contextual «Proteger esto» en bloques del mapa y filas de Limpieza (no destructivo: sin confirmación). Filas protegidas: «Protegido por ti» / «Protegido por Airy: \(motivo)», sin casilla. Hoja de confirmación: cada fila muestra su vista previa («Irá a la Papelera» / «Se ejecutará `uv cache clean`» / tachada con el motivo si está bloqueada) y lo bloqueado no se ejecuta. «Acerca de Airy»: `orderFrontStandardAboutPanel` con créditos «Airy adapta ideas y listas de rutas de Mole (github.com/tw93/Mole, GPL-3.0). No incluye código de Mole.»

- [ ] **Step 1: Write the failing test** — `protectedItemHasNoCheckbox`: `CleanupBoard.canSelect(item(protection: .init(source: .user, …)))` es `false` y `readySafeItems` no lo incluye.
- [ ] **Step 2: Run** — `swift test --filter CleanupBoardTests` → FAIL hasta ajustar `canSelect` si Task 5 no lo cubrió; si ya pasa, seguir.
- [ ] **Step 3: Implement** el cableado y las vistas según Interfaces (el ejecutor recibe `settings: { store.load() }`, `log: operationLog`).
- [ ] **Step 4: Verify** — `swift build && swift test 2>&1 | tail -3` → verde. Manual (DEBUG): `AIRY_SUPPORT_DIR=$(mktemp -d) .build/debug/Airy &` (guardar `$!`): abrir Ajustes (⌘,), cambiar a Prudente y volver; «Proteger esto» sobre una carpeta de `~/Library/Logs/AiryPrueba` ⇒ aparece en la lista y la fila sale «Protegido por ti»; abrir una confirmación y cancelarla (no confirmar nada); «Acerca de Airy» muestra el crédito. Parar con `kill <PID>`.
- [ ] **Step 5: Commit** — `feat: la app usa los ajustes compartidos, el clasificador y el embudo` (+ Co-Authored-By).

---

### Task 10: URLs `airy://` y su manejo en la app (propuesta, mostrar, reanalizar)

**Files:**
- Create: `Sources/DiskMapCore/Integration/AiryURL.swift`
- Modify: `Sources/DiskMapCore/UIState/MapNavigation.swift` (`reveal(path:)`), `Sources/Airy/AiryApp.swift` (`.onOpenURL`, `.handlesExternalEvents(matching: ["*"])`), `Sources/Airy/AppModel.swift` (`handle(url:)`, `pendingURLCommand`), `Sources/Airy/Shell/RootView.swift` (consume el comando con su `CleanupFlow`), `Sources/Airy/Cleanup/CleanupFlow.swift` (`requestClean` gana `warning:` y `proposedBy:`; `requestTrash` gana `proposedBy:`)
- Test: `Tests/DiskMapCoreTests/AiryURLTests.swift`, `Tests/DiskMapCoreTests/AppModelTests.swift` (`revealZoomsToDeepestExistingFolder`)

**Interfaces:**
- Produces:
```swift
public enum AiryURLCommand: Sendable, Equatable {
    public enum ProposeTarget: Sendable, Equatable { case item(String), path(String) }
    case propose(target: ProposeTarget, reason: String, agent: String?)
    case show(path: String)
    case rescan
    public static let scheme = "airy"
    public static let maxReason = 500, maxAgent = 64, maxPath = 1024, maxItemID = 200
    public init?(url: URL)
    public var url: URL
}
extension MapNavigation { public mutating func reveal(path: String) -> Bool }   // true si llegó al final
```
Formas: `airy://propose?item=<id>&reason=<r>&agent=<a>`, `airy://propose?path=<p>&reason=<r>&agent=<a>`, `airy://show?path=<p>`, `airy://rescan` (query con percent-encoding de `URLComponents`). `init?(url:)` rechaza: esquema ≠ `airy`, host desconocido, `item` y `path` a la vez o ninguno, ruta no absoluta / con `..` / con caracteres de control / > 1024, id con control o > 200. `reason` y `agent`: control → espacio, recorte de espacios, truncado a 500 / 64 con «…».
App (`handle(url:)`, nunca ejecuta nada por sí misma): `rescan` → sección Mapa y `startScan()` si no analiza ya; `show` → sección Mapa y `navigation.reveal(path:)` al tener análisis; `propose(item)` → sección Limpieza, espera a la detección, busca el id: si falta, aviso «Un agente propuso «\(id)», pero ya no aparece en Limpieza.»; si es «No tocar», aviso «Un agente propuso «\(título)», pero es «No tocar»: Airy no lo ofrece.»; si no, `flow.requestClean([item], warning:, proposedBy:)`; `propose(path)` → si `wouldRefuseTrash`, aviso con el motivo; si no, `flow.requestTrash(paths: [path], title: último componente, warning:, proposedBy:)`. Con `flow.isBusy`: aviso «Airy está limpiando; vuelve a pedirlo en un momento.» Warning: título «Un agente propone limpiar esto», subtítulo «\(agent ?? "Un agente") · \(reason.isEmpty ? "sin motivo" : reason)», motivo «Nada se borra hasta que lo confirmes aquí.», nota «Revisa qué es antes de seguir.» La confirmación del usuario se ejecuta con `.user(runID:, proposedBy: agent)`.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func roundTripsEveryCommand()                    // url → init → igual, incl. ruta "/Users/x/Música & Co/ñ#1"
@Test func parseRejectsHostileInput() {
    for s in ["airy://propose?item=a&path=/x&reason=r", "airy://propose?path=x&reason=r",
              "airy://show?path=/a/../b", "airy://show?path=/a%0Ab", "airy://delete?path=/x", "http://propose?item=a"] {
        #expect(AiryURLCommand(url: URL(string: s)!) == nil)
    }
}
@Test func reasonIsSanitisedAndTruncated() {           // 10 000 caracteres con "\n" → count ≤ 501, sin "\n"
}
@Test func revealZoomsToDeepestExistingFolder()        // "/Users/ana/Proyectos/no-existe" → current == Proyectos; devuelve false
```

- [ ] **Step 2: Run test to verify it fails** — `swift test --filter AiryURLTests` → FAIL.
- [ ] **Step 3: Implement** según Interfaces.
- [ ] **Step 4: Verify** — `swift test 2>&1 | tail -3` → verde. Manual con `bash scripts/build-app.sh` y `open build/Airy.app`: `open 'airy://rescan'` dos veces ⇒ una sola ventana; `open 'airy://show?path=/Users'` ⇒ zoom; `open 'airy://propose?item=user-logs&reason=prueba&agent=manual'` ⇒ paso «Un agente propone…» y **Cancelar**. Parar por PID.
- [ ] **Step 5: Commit** — `feat: esquema airy:// para propuestas, mostrar y reanalizar` (+ Co-Authored-By).

---

### Task 11: Núcleo MCP (JSON-RPC por stdio) y ejecutable `airy-mcp` en el paquete

**Files:**
- Create: `Sources/DiskMapCore/MCP/JSONValue.swift`, `MCPTool.swift`, `MCPServer.swift`, `AiryEnvironment.swift`, `StdioTransport.swift`; `Sources/AiryMCP/main.swift`
- Modify: `Package.swift` (`.executable(name: "airy-mcp", targets: ["AiryMCP"])`, `.executableTarget(name: "AiryMCP", dependencies: ["DiskMapCore"], path: "Sources/AiryMCP")`), `Sources/DiskMapCore/Catalog/Catalog.swift` (`bundled()` busca también `<ejecutable>/../../Resources`), `Sources/DiskMapCore/System/SystemProbes.swift` (`volumeCapacity`), `scripts/build-app.sh`
- Test: `Tests/DiskMapCoreTests/MCPServerTests.swift`

**Interfaces:**
- Produces:
```swift
public indirect enum JSONValue: Codable, Sendable, Equatable {
    case null, bool(Bool), number(Double), string(String), array([JSONValue]), object([String: JSONValue])
    public subscript(key: String) -> JSONValue? { get }
    public var stringValue: String? { get }; public var intValue: Int? { get }; public var boolValue: Bool? { get }
}
public struct MCPToolAnnotations: Sendable, Equatable { public var readOnly: Bool, destructive: Bool, idempotent: Bool }
public struct MCPToolResult: Sendable, Equatable {
    public var text: String; public var structured: JSONValue?; public var isError: Bool
    public static func ok(_ value: JSONValue, summary: String) -> MCPToolResult   // text = summary + "\n" + JSON con sangría
    public static func error(_ message: String) -> MCPToolResult
}
public struct MCPCallContext: Sendable { public let environment: AiryEnvironment; public let client: String }
public protocol MCPTool: Sendable {
    var name: String { get }
    var description: String { get }          // español
    var inputSchema: JSONValue { get }       // type object, additionalProperties false
    var annotations: MCPToolAnnotations { get }
    func call(_ arguments: [String: JSONValue], context: MCPCallContext) async -> MCPToolResult
}
public struct MCPToolRegistry: Sendable {
    public init(_ tools: [any MCPTool])
    public var tools: [any MCPTool] { get }
    public func adding(_ tool: any MCPTool) -> MCPToolRegistry
    /// Herramientas de Airy. Task 12 añade las de lectura, Task 13 las de acción.
    /// Plan 4 añade aquí `GetPerformanceTool()` y `ProposeQuitAppTool()`.
    public static func standard() -> MCPToolRegistry
}
public struct VolumeCapacity: Sendable, Equatable { public let total: Int64, available: Int64, importantAvailable: Int64 }
public protocol URLOpening: Sendable { func open(_ url: URL) async -> Bool }
public struct WorkspaceURLOpener: URLOpening { public init() }   // NSWorkspace.open; arranca Airy si está cerrada
public struct AiryEnvironment: Sendable {
    public let home: String, paths: AppPaths
    public let catalog: Catalog?, catalogError: String?
    public let settings: SettingsStore, index: IndexStore, log: OperationLog
    public let runner: any CommandRunning, probes: any SystemProbing, processGuard: ProcessGuard
    public let references: ReferenceChecker, urlOpener: any URLOpening
    public let capacity: @Sendable () -> VolumeCapacity?
    public init(…todos los campos…)                // memberwise público (pruebas)
    public static func live(paths: AppPaths = .standard()) -> AiryEnvironment
    public func classifier() -> RiskClassifier?     // con settings.load().effective
    public func makeScanner() -> CleanupScanner?
    public func makeExecutor() -> CleanupExecutor?  // settings: { settings.load() }, log
}
public actor MCPServer {
    public static let supportedProtocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
    public init(registry: MCPToolRegistry, environment: AiryEnvironment, serverVersion: String)
    public func handle(line: String) async -> String?    // nil para notificaciones y respuestas
}
public enum StdioTransport {
    public static func run(server: MCPServer, input: FileHandle = .standardInput, output: FileHandle = .standardOutput) async
}
```
Protocolo: un mensaje JSON por línea; las peticiones se atienden **en orden, de una en una**. `initialize` → `{protocolVersion: la pedida si está soportada, si no "2025-11-25"; capabilities: {tools: {listChanged: false}}; serverInfo: {name: "airy", title: "Airy", version}; instructions: "Airy consulta y limpia el disco de este Mac. Solo ejecuta lo marcado «Sin problema»; lo demás se propone al usuario en la app. Nunca recibes el contenido de los archivos."}`; guarda `clientInfo.name` (sin control, ≤ 64; por defecto «agente»). `ping` → `{}`. `tools/list` → `{tools: [{name, description, inputSchema, annotations: {readOnlyHint, destructiveHint, idempotentHint, openWorldHint: false}}]}`. `tools/call` → `{content: [{type: "text", text}], isError}` más `structuredContent` si la versión negociada ≥ `2025-06-18`. Errores JSON-RPC: análisis −32700 (id null), petición inválida o lote (array) −32600, método desconocido −32601, herramienta desconocida −32602; argumentos que no cumplen el esquema (requeridos, tipos, `additionalProperties`) → resultado con `isError: true`. Solo JSON-RPC por stdout; diagnósticos por stderr.
`main.swift`: `signal(SIGPIPE, SIG_IGN)`; `DataMigration.migrateIfNeeded(.standard())`; `MCPServer(registry: .standard(), environment: .live(), serverVersion: CFBundleShortVersionString del .app que lo contiene o "0.2.0")`; `await StdioTransport.run(server:)`; sale con EOF.
`build-app.sh`: copia `$BIN_DIR/airy-mcp` a `Contents/MacOS/airy-mcp` y lo firma **antes** que la app: `codesign --force --options runtime --timestamp=none -i local.airy.Airy.mcp -s "$IDENTITY" …/airy-mcp` (ad-hoc si no hay identidad).

- [ ] **Step 1: Write the failing tests** (con `FakeTool` y entorno temporal `makeTestEnvironment(home:)`)

```swift
@Test func initializeNegotiatesVersion() async     // "2025-06-18" → eco; "1999-01-01" → "2025-11-25"; serverInfo.name == "airy"
@Test func notificationsGetNoResponse() async      // notifications/initialized → nil
@Test func pingReturnsEmptyResult() async
@Test func toolsListListsRegistry() async          // nombre, esquema y annotations del FakeTool
@Test func unknownMethodIs32601() async
@Test func parseErrorIs32700WithNullID() async
@Test func batchArrayIsRejected() async            // "[...]" → −32600
@Test func unknownToolIs32602() async
@Test func schemaViolationIsToolError() async      // falta requerido / tipo erróneo / clave extra → isError true; FakeTool no llamado
@Test func structuredContentOnlyFromJune2025() async
@Test func transportWritesOneJSONLinePerResponse() async   // Pipe: 3 líneas (initialize, notificación, ping) → 2 líneas JSON válidas
@Test func catalogFoundFromBundledHelperLayout()           // Catalog.bundled(executableURL: tmp/X.app/Contents/MacOS/airy-mcp) con el bundle en Resources
```
(`Catalog.bundled()` gana una variante `bundled(executableURL: URL?)` para poder probar la búsqueda.)

- [ ] **Step 2: Run test to verify it fails** — `swift test --filter MCPServerTests` → FAIL.
- [ ] **Step 3: Implement** según Interfaces.
- [ ] **Step 4: Verify** — `swift test --filter MCPServerTests` → PASS (12). Run: `bash scripts/build-app.sh && ls build/Airy.app/Contents/MacOS && codesign --verify --strict build/Airy.app/Contents/MacOS/airy-mcp && printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"prueba","version":"1"}}}' '{"jsonrpc":"2.0","id":2,"method":"ping"}' | build/Airy.app/Contents/MacOS/airy-mcp`
Expected: `Airy  airy-mcp`; verificación sin errores; dos líneas JSON (`serverInfo.name` `airy`, `result {}`).
- [ ] **Step 5: Commit** — `feat: servidor MCP airy-mcp por stdio dentro de Airy.app` (+ Co-Authored-By).

---

### Task 12: Herramientas MCP de lectura

**Files:**
- Create: `Sources/DiskMapCore/MCP/Tools/ReadTools.swift`, `Sources/DiskMapCore/Catalog/FolderExplanations.swift` (movido desde `Sources/Airy/Map/HoverCard.swift:7-60`, ahora `public`)
- Modify: `MCPToolRegistry.standard()` (añade las cuatro)
- Test: `Tests/DiskMapCoreTests/MCPReadToolTests.swift`

**Interfaces:**
- Consumes: `AiryEnvironment`, `MCPTool` (Task 11); `RiskClassifier` (Task 5); `CleanupBoard`.
- Produces: `GetDiskSummaryTool`, `ListLargestTool`, `ExplainPathTool`, `ListCleanupItemsTool` (todas `readOnly: true, destructive: false`) y `public enum MCPFormat { static func risk(_ c: Classification) -> [String: JSONValue] }` → `{"risk": "safe|yourCall|doNotTouch", "risk_label": Risk.label, "protected_by": "airy"|"user"|null, "reasons": [...]}`.

| Herramienta | Entrada | Salida (`structured`) |
|---|---|---|
| `get_disk_summary` | `{}` | `scan_available`, `last_scan` (ISO 8601 o null), `total_bytes`, `free_bytes`, `purgeable_bytes`, `analyzed_bytes`, `by_kind: [{kind, title, bytes}]` (de `root.kindBytes`, desc), `full_disk_access`; sin índice: mensaje «Aún no hay análisis guardado. Abre Airy o usa rescan.» |
| `list_largest` | `path?` (absoluta o con `~`, por defecto `/`), `limit?` entero 1…200, por defecto 20 | `path`, `children: [{name, path, bytes, kind, last_modified, is_directory} + MCPFormat.risk]` desc; agregado «Otros» como `{name:"Otros", aggregated_count, path:null}`; ruta fuera del índice → error «Esa carpeta no está en el último análisis.» |
| `explain_path` | `path` requerido | `path`, `known`, `title`, `explanation` (ficha o `FolderExplanations`), `who_creates_it`, `regenerates`, `size_bytes` (solo del índice; si no, null), `exists` (`lstat`) + `MCPFormat.risk(classify(path:))` |
| `list_cleanup_items` | `{}` | `mode`, `items` en el orden de `CleanupBoard(items:).items`: `{id, title, bytes, size_text, upper_bound, method: trash|command|info, command: [String]?, blocked_by_open_apps, used_by, blocked_reason, preselected, highlighted, actionable_by_agent}` + `MCPFormat.risk`; `actionable_by_agent = risk == .safe && CleanupBoard.canSelect(item)` |

Nada lee contenido de archivos (solo índice, `lstat`, catálogo y detección de Limpieza).

- [ ] **Step 1: Write the failing tests**

```swift
@Test func summaryWithoutIndex() async             // scan_available false, isError false
@Test func summaryReportsKindsAndDate() async      // ScanResult guardado en IndexStore temporal
@Test func listLargestSortsAndLimits() async       // 3 hijos, limit 2 → los 2 mayores, desc
@Test func listLargestCapsLimitAndRejectsUnknownPath() async   // limit 500 → isError; ruta ausente → isError
@Test func explainKnownCatalogPath() async         // home/.npm/_cacache → title de la ficha npm, regenerates true
@Test func explainPersonalPathIsYourCall() async   // home/Documents/x → "Tú decides"
@Test func explainProtectedPathIsRed() async       // home/Library/Keychains → "No borrar", protected_by "airy"
@Test func explainUserProtected() async            // protected_by "user"
@Test func listCleanupItemsOrderedLikeBoard() async
@Test func yourCallIsNotActionableByAgent() async
@Test func outputsNeverContainFileContents() async // fichero con "SECRETO-123" en una ruta de limpieza; ningún texto de las 4 herramientas lo contiene
```

- [ ] **Step 2: Run test to verify it fails** — `swift test --filter MCPReadToolTests` → FAIL.
- [ ] **Step 3: Implement** según Interfaces (la app sigue usando `FolderExplanations` desde core).
- [ ] **Step 4: Run tests** — `swift test 2>&1 | tail -3` → verde.
- [ ] **Step 5: Commit** — `feat: herramientas MCP de lectura (resumen, mayores, explicar, limpiezas)` (+ Co-Authored-By).

---

### Task 13: Herramientas MCP de acción (solo verde; lo demás se propone en la app)

**Files:**
- Create: `Sources/DiskMapCore/MCP/Tools/ActionTools.swift`
- Modify: `MCPToolRegistry.standard()` (añade las cinco; total 9)
- Test: `Tests/DiskMapCoreTests/MCPActionToolTests.swift`

**Interfaces:**
- Consumes: `AiryEnvironment.makeScanner/makeExecutor` (Task 11), `CleanupExecutor.preview/execute` con `.agent(client, runID:)` (Task 8), `AiryURLCommand` (Task 10), `OperationLog` (Task 7).
- Produces: `RunSafeCleanupTool`, `RunSafeCleanupAllTool`, `ProposeCleanupTool`, `ShowInAppTool`, `RescanTool`; `enum AgentGate { static func refusal(_ env: AiryEnvironment) -> String? }`.

| Herramienta | Entrada | Comportamiento |
|---|---|---|
| `run_safe_cleanup` | `item_id` requerido, `dry_run?` (false) | `AgentGate`; detección nueva; id inexistente → error; `risk != .safe` o no `canSelect` → error explicativo y nada ejecutado; si no, `preview`/`execute` con contexto de agente. Salida `{run_id, item_id, title, dry_run, outcome, bytes, message}` |
| `run_safe_cleanup_all` | `dry_run?` | `AgentGate`; `CleanupBoard(items:).readySafeItems` (solo verde), en secuencia, un `run_id`; salida `{run_id, dry_run, results: [...], freed_bytes, moved_to_trash_bytes}` |
| `propose_cleanup` | exactamente uno de `item_id` / `path`; `reason` requerido (1…500); `dry_run?` | `AgentGate`; item inexistente o «No tocar», o ruta que `wouldRefuseTrash` rechaza → error; abre `AiryURLCommand.propose(…, agent: client).url`; salida `{status: "pending_user_confirmation", url, message}` |
| `show_in_app` | `path` requerido, `dry_run?` | `AgentGate`; abre `airy://show?path=` |
| `rescan` | `dry_run?` | `AgentGate`; abre `airy://rescan`; `{status: "scan_requested", message}` |

`dry_run: true` en `propose/show/rescan` devuelve la URL sin abrirla. Anotaciones: `run_*` `destructive: true`; el resto `destructive: false`; ninguna `readOnly`. Cada llamada de acción añade un `OperationRecord` (actor agente; `propose` → `pending_user`, `show`/`rescan` → `requested`). Textos fijos:
- apagado: «Has desactivado en Airy que los agentes ejecuten acciones (Asistente › Conectar agente).»
- ilegibles: «Airy no puede leer sus ajustes; no se ejecuta nada hasta que los revises en la app.»
- ámbar: ««\(título)» es «Tú decides»: solo se ejecuta lo marcado «Sin problema». Usa propose_cleanup para que el usuario decida en Airy.»
- rojo: ««\(título)» es «No borrar»: Airy no lo toca.»
- propuesta: «Propuesta enviada a Airy; pendiente de confirmación del usuario.»
- reanálisis: «Análisis pedido a Airy. Cuando termine, get_disk_summary mostrará la fecha nueva.»
- sin app: «No se pudo abrir Airy (¿está instalada en /Applications?).»

- [ ] **Step 1: Write the failing tests** (`FakeRunner`, `FakeProbes`, `FakeOpener` que registra URLs, home temporal, catálogo de prueba)

```swift
@Test func runSafeCleanupExecutesGreenItem() async       // fichero bajo home/Library/Caches/prueba → Papelera; log actor .agent("test-client")
@Test func runSafeCleanupRefusesYourCall() async         // isError; runner.calls vacío; fichero intacto
@Test func runSafeCleanupRefusesDoNotTouchAndOpenApp() async
@Test func runSafeCleanupDryRunMovesNothing() async      // outcome "would_trash"; fichero sigue; log dryRun true
@Test func agentCommandUsesExactCatalogArguments() async // ficha uv → runner.calls == [/fake/uv ["cache","clean"]]
@Test func toggleOffBlocksEveryActionTool() async        // las 5, también con dry_run → isError; opener y runner sin llamadas
@Test func unreadableSettingsBlocksActions() async
@Test func runAllOnlyTouchesGreen() async                // A, B verdes; C ámbar preseleccionado (Agresivo); D rojo → solo A y B
@Test func runAllStopsWhenToggleTurnsOffMidBatch() async // tras el 1.º, settings.json pasa a agentsEnabled false → 2.º "blocked"
@Test func proposeOpensURLWithoutExecuting() async       // opener recibe airy://propose?item=…&agent=test-client; runner y Papelera sin cambios
@Test func proposeRejectsRedBothTargetsAndMissingReason() async
@Test func proposePathRefusedWhenGateRefuses() async     // home/Library/Keychains
@Test func showAndRescanOpenURLsDryRunDoesNot() async
@Test func registryHasExactlyNineToolsAndNoArbitraryInput() {
    #expect(Set(MCPToolRegistry.standard().tools.map(\.name)) == ["get_disk_summary", "list_largest", "explain_path",
        "list_cleanup_items", "run_safe_cleanup", "run_safe_cleanup_all", "propose_cleanup", "show_in_app", "rescan"])
    // ningún esquema tiene "command", "args" ni "paths"; "path" solo en list_largest, explain_path, propose_cleanup, show_in_app
}
```

- [ ] **Step 2: Run test to verify it fails** — `swift test --filter MCPActionToolTests` → FAIL.
- [ ] **Step 3: Implement** según Interfaces.
- [ ] **Step 4: Run tests** — `swift test 2>&1 | tail -3` → verde.
- [ ] **Step 5: Commit** — `feat: herramientas MCP de acción (solo verde, propuestas por airy://)` (+ Co-Authored-By).

---

### Task 14: Pestaña «Conectar agente», registro de actividad y verificación final

**Files:**
- Create: `Sources/DiskMapCore/Integration/AgentSnippets.swift`, `Sources/Airy/Assistant/AgentsView.swift`
- Modify: `Sources/Airy/Assistant/AssistantSession.swift` (`Mode.agents`, título «Conectar agente»), `Sources/Airy/Assistant/AssistantView.swift` (el selector queda activo siempre; `.agents` se muestra aunque falte Claude)
- Test: `Tests/DiskMapCoreTests/AgentSnippetsTests.swift`

**Interfaces:**
- Consumes: `AppModel.settings/updateSettings/operationLog` (Task 9), `AssistantSession.claude` (ruta de Claude localizada).
- Produces:
```swift
public struct AgentSnippets: Sendable, Equatable {
    public init(serverPath: String)
    public var claudeCodeArguments: [String]   // ["mcp", "add", "-s", "user", "airy", "--", serverPath]
    public var claudeCode: String              // "claude mcp add -s user airy -- " + shellQuote(serverPath)
    public var codexTOML: String
    public var opencodeJSON: String
    public var genericJSON: String
    public static func shellQuote(_ s: String) -> String   // '…' con ' → '\''
}
public enum ClaudeRegistration: Sendable, Equatable { case added, alreadyPresent, failed(String) }
public enum ClaudeMCP {
    /// `claude mcp add -s user airy -- <ruta>` con array de argumentos, plazo 30 s.
    public static func add(claude: String, snippets: AgentSnippets, runner: any CommandRunning) async -> ClaudeRegistration
}
```
Textos exactos (`<ruta>` escapada para cada formato; TOML: `\` → `\\`, `"` → `\"`; JSON con `JSONSerialization`, claves ordenadas, sangría de 2):
```toml
# ~/.codex/config.toml
[mcp_servers.airy]
command = "<ruta>"
args = []
```
```json
{ "$schema": "https://opencode.ai/config.json", "mcp": { "airy": { "command": ["<ruta>"], "enabled": true, "type": "local" } } }
```
```json
{ "mcpServers": { "airy": { "args": [], "command": "<ruta>" } } }
```
`ClaudeMCP.add`: estado 0 → `.added`; stderr/stdout con «already exists» → `.alreadyPresent`; otro → `.failed(stderr recortado)`.
Vista «Conectar agente» (ruta del servidor = carpeta del ejecutable de la app + `airy-mcp`):
1. Estado: «Servidor MCP listo» + ruta en monoespaciada con «Copiar»; si no existe: «No se encuentra airy-mcp junto a Airy. Vuelve a empaquetar con scripts/build-app.sh.»; fuera de `/Applications`: «Instala Airy en Aplicaciones para que esta ruta no cambie.»
2. Interruptor «Permitir que los agentes ejecuten limpiezas seguras» (mismo ajuste que Ajustes) con pie «Solo lo marcado «Borrar sin riesgo». Lo demás siempre te lo proponen aquí.»
3. Tarjetas con «Copiar» (`NSPasteboard`): Claude Code (+ botón «Añadir a Claude Code», activo si Claude está localizado; resultados «Añadido a Claude Code», «Ya estaba añadido», «No se pudo añadir: …»), Codex, opencode, «Otros agentes (mcpServers)».
4. «Actividad de los agentes»: registros de `operationLog` con actor agente o `proposedBy`, más recientes primero, máximo 200 (fecha relativa, agente, acción, título, resultado, tamaño); vacío: «Ningún agente ha usado Airy todavía.»; botones «Actualizar» y «Exportar registro…» (`NSSavePanel`, nombre `airy-registro-<yyyy-MM-dd>.json`, escribe `exportJSON()`); se refresca al aparecer y al volver la app al frente.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func claudeCodeQuotesAwkwardPath() {
    let s = AgentSnippets(serverPath: "/Applications/Mi Airy's.app/Contents/MacOS/airy-mcp")
    #expect(s.claudeCode == "claude mcp add -s user airy -- '/Applications/Mi Airy'\\''s.app/Contents/MacOS/airy-mcp'")
    #expect(s.claudeCodeArguments.last == "/Applications/Mi Airy's.app/Contents/MacOS/airy-mcp")
}
@Test func codexEscapesBackslashAndQuote()
@Test func jsonSnippetsParseAndPointToServer()       // opencode: mcp.airy.command == [ruta]; genérico: mcpServers.airy.command == ruta
@Test func claudeAddUsesArgumentArray() async        // FakeRunner: una llamada con ["mcp","add","-s","user","airy","--",ruta]
@Test func claudeAddDetectsAlreadyPresentAndFailure() async
```

- [ ] **Step 2: Run test to verify it fails** — `swift test --filter AgentSnippetsTests` → FAIL.
- [ ] **Step 3: Implement** `AgentSnippets`, `ClaudeMCP` y la vista según Interfaces.
- [ ] **Step 4: Verificación final**
  - `swift test 2>&1 | tail -3` → todo en verde (245 de la fase 1 + las nuevas).
  - `bash scripts/build-app.sh` → «✓ Firmada con "Airy Local Signing"»; `codesign --verify --deep --strict build/Airy.app` sin salida.
  - Humo MCP contra el sistema real (solo lectura y `dry_run`): enviar por stdin `initialize`, `notifications/initialized`, `tools/list`, `tools/call get_disk_summary`, `tools/call list_cleanup_items`, `tools/call run_safe_cleanup_all {"dry_run": true}` a `build/Airy.app/Contents/MacOS/airy-mcp` ⇒ 9 herramientas, resumen coherente, resultados `would_*`/`blocked` y nada movido ni ejecutado.
  - App (`open build/Airy.app`): Asistente › «Conectar agente» muestra estado, interruptor, 4 tarjetas y la actividad del humo; «Exportar registro…» a una carpeta temporal produce JSON válido. **No** pulsar «Añadir a Claude Code» sin permiso del usuario. Parar por PID.
  - Instalación (`bash scripts/build-app.sh --install`) **solo con el usuario delante**: el controlador lo pregunta; tras instalar, el usuario vuelve a dar Acceso total al disco.
- [ ] **Step 5: Commit** — `feat: pestaña «Conectar agente» con instrucciones, alta en Claude Code y actividad` (+ Co-Authored-By).
