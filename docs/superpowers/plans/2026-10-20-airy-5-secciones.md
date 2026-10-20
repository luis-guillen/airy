# Airy 5 de 5 — Desinstalador, Grandes y viejos, Duplicados, Tipos de archivo · Plan de implementación

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Las cuatro secciones «Próximamente» de la barra lateral pasan a funcionar: un Desinstalador con tamaño real, desinstalación completa, restos huérfanos y enlaces rotos; Grandes y viejos; Duplicados; y Tipos de archivo. Las cuatro llevan las tres etiquetas, selección múltiple y las animaciones de viento, y todo lo que borran pasa por el embudo único.

**Architecture:** Toda la lógica vive en `DiskMapCore`, probada con carpetas temporales y dobles (`Apps/` para inventario, restos, huérfanos y enlaces; `Sections/` para grandes y viejos, duplicados y tipos). Lo destructivo nuevo, que es desinstalar y quitar enlaces rotos, entra en `CleanupExecutor` como métodos del mismo embudo. El resto reutiliza `trashPaths`. La app solo añade vistas y almacenes `@Observable` que llaman a `AppModel`, y el MCP gana herramientas de lectura más `propose_uninstall` por `airy://`.

**Tech Stack:** Swift 6.4 (solo Command Line Tools), SwiftPM, SwiftUI + AppKit, Swift Testing, CoreServices (`MDItem`), CryptoKit (`SHA256`), `getattrlist`, `launchctl`, `pkgutil`, `osascript`.

**Spec:** `docs/superpowers/specs/2026-10-20-airy-fase-2-design.md` (§2.4 etiquetas, §2.7 secciones, §2.9 «Huérfanos y desinstalador más precisos», §2.8 MCP) y `docs/superpowers/specs/2026-10-20-diskmap-design.md` (§2 puntos 3–6, §4 anti-objetivos, §6 «Papelera», «Acciones de la IA», §7b MCP). Listas de rutas: `docs/superpowers/research/2026-10-20-mole-inspiracion.md` §5.1, §5.2, §2.15. Interfaces vinculantes del plan 1: `docs/superpowers/plans/2026-10-20-airy-1-identidad-seguridad-mcp.md` y sus *rulings* en `.superpowers/sdd/2026-10-20-airy-1-identidad-seguridad-mcp/progress.md`.

**Consume, sin redefinir:** `PathGate`, `HardProtections`, `ProtectionMatch`, `ValidatedPath`, `PathRefusal` (plan 1, Task 4). `RiskClassifier`, `Classification` (Task 5). `ProcessGuard`, `TimeBudget` (Task 6). `OperationLog`, `OperationRecord`, `OperationActor` (Task 7; *ruling* F2: se llama `OperationActor`, no `Actor`). `OperationContext`, `CleanupPreview`, `CleanupExecutor.trashPaths(_:title:context:)`, el gancho `beforeMove` (Task 8). `AppModel.classify/trash/settings` (Task 9). `AiryURLCommand`, `MapNavigation.reveal(path:)`, `AppModel.handle(url:)` (Task 10). `MCPTool`, `MCPToolRegistry`, `AiryEnvironment`, `MCPFormat`, `AgentGate` (Tasks 11–13). Del plan 2 (`docs/superpowers/plans/2026-10-20-airy-2-marca-animaciones.md`) usa la paleta `Theme.Airy` y `RiskBadge(risk:compact:reason:)` con los textos «Sin problema / Tú decides / No borrar». Usa también sus animaciones: la transición `.leafAway` para cada fila que sale; `GustSweep(start:)` + `.gustSway(index:start:)` para las tandas de varios elementos, como en Limpieza; `WindLeaves(mode: .orbit(radius:))` alrededor del progreso; y `BreezeBackground`. Todas respetan `airyAmbientMotion`/`airyTransientMotion` (pausa y «Reducir movimiento»).

**Fuera de este plan:** entradas agresivas del catálogo y perfil (plan 3); Rendimiento, cierre de apps desde Rendimiento, `get_performance`, `propose_quit_app` (plan 4). Si el plan 3 ya creó un ejecutor con contraseña de administrador, Task 4 lo reutiliza en vez de `PrivilegedRunning`; los nombres de las pruebas no cambian. El `ProcessTerminating` del plan 4 trabaja por PID e incluye forzar el cierre, así que el Desinstalador usa su propio `AppQuitting` (por bundle id y nunca forzando). `WorkspaceQuitter` puede apoyarse en `LiveTerminator.requestQuit`.

## Global Constraints

- Swift 6.4, SwiftPM, solo Command Line Tools (sin Xcode); `swift build` / `swift test`; plataforma `.macOS(.v15)`; el test target conserva las `unsafeFlags` del plugin de Swift Testing de Package.swift.
- Interfaz en **español de España**; nombres de herramientas MCP en inglés y textos de respuesta en español.
- **Nunca** se envía contenido de archivos a la IA ni al MCP: solo rutas, tamaños, fechas, tipos e identificadores. Las huellas (hash) de Duplicados **no** salen del proceso que las calcula ni se guardan en disco.
- Ubicaciones protegidas, nunca borrables: volúmenes de Docker, iCloud, Mail, Mensajes, Llaveros, AddressBook, Calendarios, Fotos, `/Applications`, `/Library`, `/usr`, `/bin`, `/sbin`, `/private`, `/opt/homebrew`, `/System`. Las carpetas personales nunca son verdes y los runtimes en uso nunca se tocan. **Única excepción, acotada (Task 2):** el `.app` exacto que el usuario desinstala, en `/Applications` o `~/Applications`.
- Toda acción destructiva pasa por `ConfirmSheet` → `AppModel` → `CleanupExecutor`; archivos → Papelera (`trashItem` solo en `CleanupExecutor.swift`); comandos con array de argumentos, nunca una cadena de shell; nada se ejecuta sin la confirmación.
- La IA y el perfil solo suben el riesgo. El MCP solo ejecuta lo verde: en este plan **ninguna** herramienta nueva actúa, solo leen o proponen por `airy://`. El interruptor de agentes apagado bloquea `propose_uninstall`, también con `dry_run`.
- Rojo = sin casilla y sin botón de borrar. «Seleccionar todo» = verde + ámbar seleccionable. Ningún paso selecciona rojo ni protegido.
- Sin atajos DEBUG que actúen sin confirmación. Las capturas DEBUG son solo de ventanas propias. Para parar la app se mata **solo el PID propio** (nunca `pkill -x`). Cada verificación manual usa su propio `AIRY_SUPPORT_DIR`.
- En pruebas y verificación: **nunca se desinstala una app real**, no se ejecutan `brew`, `launchctl`, `pkgutil` ni `osascript` reales, y no se vacía la Papelera real. Se usan `FakeRunner`, `FakePrivileged`, `FakeQuitter`, `FakeLookup` y carpetas temporales. La única orden real permitida es `/usr/bin/find … -delete` sobre una carpeta temporal propia (Task 5).
- No tocar los ajustes de confianza del Llavero.
- Mole es GPL-3.0: se adaptan ideas y listas de rutas, **nunca código**.
- Vistas con `@ViewState` (no `@State`); nunca `.fixedSize(horizontal:false,vertical:true)` en `Text` multilínea; **cero CPU en reposo** (nada de `TimelineView` continuo; cálculo solo al abrir la sección o al pedirlo); «Reducir movimiento» sustituye las animaciones por fundidos.
- Commits terminan con `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

1. **La app cambia entre abrir la hoja y confirmar** (se actualiza, se mueve, otra app ocupa la ruta o el `.app` pasa a ser un enlace) → rechazo y nada movido. Test en Task 4: `bundleReplacedAfterPlanIsRefused`.
2. **Un duplicado se edita o desaparece entre la búsqueda y el borrado**, o desaparece la copia que se conserva → esa copia no va a la Papelera. Test en Task 7: `verifyRejectsChangedFile`, `verifyRejectsMissingKeeper`, `verifyRefusesRemovingTheKeeper`.
3. **Spotlight apagado, `mdfind` lento o una carpeta de apps ilegible** → no se declara huérfano nada. Test en Task 5: `mdfindFailureMeansInstalled`, `incompleteInventoryDecidesNothing`.
4. **La app pide guardar o no se cierra al desinstalar** → no se borra nada, ni el `.app` ni sus restos. Test en Task 4: `stillRunningBlocksAndTouchesNothing`.
5. **Nombres raros en `/usr/local/bin`** (espacios, `*`, `?`, `[`, comillas) o un enlace roto que vuelve a apuntar a algo → solo se quita ese enlace, y solo si sigue roto. Test en Task 5: `deleteCommandEscapesAndOnlyTouchesBrokenSymlinks`.

---

## Estructura de archivos

```
Sources/DiskMapCore/
  Apps/AppInventory.swift            apps instaladas, ids, ayudantes, último uso, completitud   (nuevo)
  Apps/HomebrewCasks.swift           app → token de cask                                        (nuevo)
  Apps/LeftoverFinder.swift          restos de una app (tabla de ubicaciones)                   (nuevo)
  Apps/UninstallPlan.swift           plan con tamaño real y selección por defecto               (nuevo)
  Apps/OrphanFinder.swift            restos huérfanos por bundle id                             (nuevo)
  Apps/BrokenLinks.swift             enlaces rotos de /usr/local/bin                            (nuevo)
  System/PrivilegedRunner.swift      una contraseña, comandos como arrays                       (nuevo)
  System/AppQuitter.swift            cierre normal de apps                                      (nuevo)
  Cleanup/CleanupExecutor+Uninstall.swift  embudo: desinstalar y quitar enlaces             (nuevo)
  Safety/HardProtections.swift       ProtectionMatch.rule, matches(...)                         (mod.)
  Safety/PathGate.swift              validate(_:waiver:), ProtectionWaiver                      (mod.)
  Sections/FileSelection.swift       ActionableFile, selección y grupos por riesgo              (nuevo)
  Sections/LargeOldFinder.swift      grandes y viejos                                           (nuevo)
  Sections/DuplicateFinder.swift     tamaño → hash parcial → hash completo                      (nuevo)
  Sections/DuplicateBoard.swift      qué conservar, selección segura                            (nuevo)
  Sections/DuplicateReport.swift     duplicates.json sin huellas (para el MCP)                  (nuevo)
  Sections/FileTypeBreakdown.swift   espacio por tipo y elementos de cada tipo                  (nuevo)
  MCP/Tools/SectionTools.swift       list_apps, explain_app, list_orphans, list_large_old,
                                     list_duplicates, propose_uninstall                         (nuevo)
Sources/Airy/Sections/               SectionStores, FileListComponents, LargeOldView, FileTypesView,
                                     TypeDonut, DuplicatesView, UninstallerView, UninstallDetail,
                                     OrphansView                                                (nuevos)
Tests/DiskMapCoreTests/              AppInventoryTests, UninstallGateTests, LeftoverTests,
                                     UninstallFunnelTests, OrphanTests, LargeOldTests,
                                     DuplicateTests, FileTypeTests, MCPSectionToolTests
```

**Ruling: excepción de `/Applications`.** El diseño de la fase 1 pide un Desinstalador «con borrado completo» y la lista dura sella `/Applications`. La regla se resuelve con una **dispensa** (`ProtectionWaiver`) que solo construye el embudo de desinstalación y que deja pasar dos cosas. La primera es el `.app` exacto que se desinstala, comprobando su `CFBundleIdentifier` en el momento de actuar. La segunda son las carpetas de datos «sensibles» (capa C de Mole) **de esa misma app**. Nunca dispensa raíces críticas, selladas del home, fragmentos de datos (`keychain`, `1password`…) ni la lista del usuario. Lo que esté fuera del home (`/Library/...`, recibos aparte) se enseña en rojo y no se borra. Coste: Airy no limpia los restos de sistema de una app; el usuario lo ve dicho.

**Ruling: el MCP.** Gana seis herramientas: cinco de solo lectura (`list_apps`, `explain_app`, `list_orphans`, `list_large_old`, `list_duplicates`) y una de propuesta, `propose_uninstall`, que abre la hoja en Airy. No hay herramienta de tipos de archivo, porque `get_disk_summary.by_kind` ya lo da. Para borrar un archivo grande, un duplicado o un huérfano, el agente usa `propose_cleanup(path:)` del plan 1. `list_duplicates` lee el último `duplicates.json` que guardó la app: el MCP no lee contenido para buscar duplicados.

---

### Task 1: Inventario de apps (`AppInventory`, `HomebrewCasks`)

**Files:**
- Create: `Sources/DiskMapCore/Apps/AppInventory.swift`, `Sources/DiskMapCore/Apps/HomebrewCasks.swift`
- Test: `Tests/DiskMapCoreTests/AppInventoryTests.swift`

**Interfaces:**
- Consumes: `TimeBudget.run` (plan 1, Task 6), `CommandRunning`.
- Produces:
```swift
public struct AppRecord: Sendable, Equatable, Identifiable {
    public let bundleID: String
    public let name: String             // CFBundleDisplayName ?? CFBundleName ?? nombre del .app sin extensión
    public let version: String?         // CFBundleShortVersionString
    public let path: String             // ruta del .app
    public let helperBundleIDs: [String] // Contents/Library/LoginItems/*.app, Contents/Helpers/*.app, Contents/XPCServices/*.xpc
    public let isSystem: Bool           // bajo /System/Applications o id en systemCriticalBundleIDs
    public let isAppStore: Bool         // existe Contents/_MASReceipt/receipt
    public let caskToken: String?
    public let lastUsed: Date?
    public var id: String { path }
    public init(…todos los campos…)     // memberwise público (pruebas)
}
public struct AppInventorySnapshot: Sendable, Equatable {
    public let apps: [AppRecord]        // orden por nombre (localizedStandardCompare)
    public let complete: Bool
    public let problems: [String]       // en español; vacío si complete
    public var installedIDs: Set<String> { get }   // bundleID + helperBundleIDs de todas, en minúsculas
}
public protocol AppUsageReading: Sendable { func lastUsed(bundlePath: String) -> Date? }
public struct SpotlightUsage: AppUsageReading { public init() }     // MDItemCreateWithURL + kMDItemLastUsedDate
public struct AppInventory: Sendable {
    public static func standardRoots(home: String) -> [String]
        // ["/Applications", "/System/Applications", home+"/Applications", "/opt/homebrew/Caskroom",
        //  "/usr/local/Caskroom", home+"/Library/Application Support/Setapp/Applications"]
    public static let systemCriticalBundleIDs: Set<String>
        // com.apple.Safari, com.apple.finder, com.apple.systempreferences, com.apple.SystemSettings (si existe), com.apple.AppStore,
        // com.apple.ActivityMonitor, com.apple.Terminal, com.apple.mail, com.apple.MobileSMS, com.apple.Photos, com.apple.iCal,
        // com.apple.AddressBook, com.apple.keychainaccess, com.apple.backup.launcher, com.apple.DiskUtility
    public static let officialUninstallerPrefixes: [String]
        // "com.crowdstrike.", "com.sentinelone.", "com.sentinel-labs.", "com.eset.", "com.jamf.", "com.jamfsoftware.",
        // "com.paloaltonetworks.", "com.cisco.anyconnect", "com.cisco.secureclient"
    public init(roots: [String], usage: any AppUsageReading = SpotlightUsage(), casks: [String: String] = [:],
                budget: Duration = .seconds(5))
    public func snapshot() async -> AppInventorySnapshot
    /// Tal cual, sin espacios, espacios → "_", espacios → "-", y en minúsculas; vacío si el nombre tiene < 4 caracteres
    /// o está en genericNames ("notes", "mail", "music", "photos", "preview", "books", "news", "home", "files", "app", "helper").
    public static func nameVariants(_ name: String) -> [String]
}
public enum HomebrewCasks {
    /// `brew info --cask --installed --json=v2` (60 s) → [nombre del .app: token]. `nil` si brew no está o falla.
    public static func installed(runner: any CommandRunning) async -> [String: String]?
    static func parse(_ json: String) -> [String: String]   // casks[].token y casks[].artifacts[].app (cadenas o {"target": …})
}
```
Reglas:
- Busca `*.app` hasta **profundidad 3** bajo cada raíz y no entra en un `.app`. Excepción: una app de iOS cuyo `Contents/Info.plist` falta y que tiene `Wrapper/*.app` usa el `Info.plist` de ese envoltorio. No sigue enlaces simbólicos de carpeta.
- Una raíz que no existe (`ENOENT`) es normal. Hay **inventario incompleto** (`complete == false` y un motivo en `problems`) si pasa algo de esto: una raíz existe pero no se puede leer; un `.app` no tiene `Info.plist` legible o le falta `CFBundleIdentifier`; o el recorrido entero (dentro de `TimeBudget.run(budget)`) no termina a tiempo.
- `caskToken` sale de `casks[nombre del .app]`.

- [ ] **Step 1: Write the failing tests** (apps falsas en una carpeta temporal: `Foo.app/Contents/Info.plist` escrito con `PropertyListSerialization`; `FakeUsage` y `FakeRunner` de `CleanupTests.swift`)

```swift
@Test func findsAppsWithIDNameAndVersion() async      // id "com.example.foo", name "Foo", version "1.2"
@Test func vendorFolderDepthTwoFoundDepthFourNot() async
@Test func helpersAreCollected() async                // LoginItems/Helper.app id → helperBundleIDs y installedIDs (minúsculas)
@Test func unreadablePlistMakesSnapshotIncomplete() async   // Info.plist corrupto → complete false, problems no vacío
@Test func unreadableRootMakesSnapshotIncomplete() async    // chmod 000 a la raíz (y restaurar en defer)
@Test func missingRootIsFine() async                  // raíz inexistente → complete true
@Test func budgetExhaustedIsIncomplete() async        // budget .zero → complete false
@Test func appStoreAndSystemFlags() async             // _MASReceipt/receipt → isAppStore; id com.apple.Safari → isSystem
@Test func iOSWrapperUsesInnerPlist() async
@Test func nameVariantsSkipShortAndGeneric()            // "Foo Bar" → ["Foo Bar","FooBar","Foo_Bar","Foo-Bar","foo bar"…]; "Notes", "Abc" → []
@Test func caskTokenFromBrewJSON() {
    let json = #"{"casks":[{"token":"visual-studio-code","artifacts":[{"app":["Visual Studio Code.app"]}]}]}"#
    #expect(HomebrewCasks.parse(json) == ["Visual Studio Code.app": "visual-studio-code"])
}
@Test func brewMissingGivesNil() async                // FakeRunner sin "brew" resuelto → nil
```

- [ ] **Step 2: Run test to verify it fails.** Run `swift test --filter AppInventoryTests`. Expected: FAIL (tipos no definidos).
- [ ] **Step 3: Implement** según Interfaces. `SpotlightUsage` usa `MDItemCreateWithURL` y `MDItemCopyAttribute(kMDItemLastUsedDate)`, sin lanzar procesos.
- [ ] **Step 4: Run tests.** Run `swift test --filter AppInventoryTests`. Expected: PASS (12).
- [ ] **Step 5: Commit.** Mensaje: `feat: inventario de apps instaladas con ayudantes, último uso y casks` (+ Co-Authored-By).

---

### Task 2: Dispensa acotada para desinstalar (`ProtectionWaiver`)

**Files:**
- Modify: `Sources/DiskMapCore/Safety/HardProtections.swift` (cada coincidencia lleva su regla; `matches` devuelve todas; init interno de pruebas con ubicaciones selladas), `Sources/DiskMapCore/Safety/PathGate.swift` (`validate(_:waiver:)`)
- Test: `Tests/DiskMapCoreTests/UninstallGateTests.swift`

**Interfaces:**
- Consumes: `AppRecord`, `AppInventory.officialUninstallerPrefixes`, `AppInventory.nameVariants` (Task 1).
- Produces:
```swift
extension ProtectionMatch {
    public enum Rule: String, Sendable { case critical, sealedSystem, sealedHome, upward, fragment, sensitiveAppData, other }
    public let rule: Rule        // campo nuevo almacenado; init gana `rule: Rule = .other`
}
extension HardProtections {
    /// Todas las coincidencias, en el orden en que `match` las comprueba; `match(...) == matches(...).first`.
    public func matches(canonicalPath: String, home: String, catalog: Catalog?) -> [ProtectionMatch]
    init(criticalRoots: [String], sealedSystemLocations: [String])   // solo pruebas
}
public struct ProtectionWaiver: Sendable, Equatable {
    public let bundlePath: String      // canónica
    public let bundleID: String
    public let ownedNames: [String]    // en minúsculas: bundleID, helperBundleIDs, AppInventory.nameVariants(name)
    /// `nil` (no hay dispensa) si: app.isSystem; id con prefijo de officialUninstallerPrefixes; id con prefijo "local.airy.";
    /// o app.path no cuelga de un elemento de `appRoots` a profundidad 1 o 2.
    public static func uninstall(_ app: AppRecord, appRoots: [String]) -> ProtectionWaiver?
    public static func productionAppRoots(home: String) -> [String]   // ["/Applications", home + "/Applications"]
}
extension PathGate {
    /// `validate(_:)` del plan 1 es `validate(_:waiver: nil)`.
    public func validate(_ path: String, waiver: ProtectionWaiver?) -> Result<ValidatedPath, PathRefusal>
}
```
Reglas de la dispensa: todo lo demás de `validate` sigue igual (sintaxis, formas resueltas, inodo de raíces críticas, lista del usuario).
- **Si la ruta es el `.app` exacto** (`== bundlePath`), se dispensan solo las coincidencias de dos reglas: `.sealedSystem` con patrón `/Applications` y `.fragment`. Además, el `.app` no puede ser un enlace y su `Contents/Info.plist`, leído en ese momento, tiene que dar `CFBundleIdentifier == bundleID`. Si no, el rechazo es «Ya no es la app que elegiste.».
- **Cualquier otra ruta:** se dispensan solo las coincidencias `.sensitiveAppData` cuyo último componente pertenezca a la app. Ese componente se pasa a minúsculas, se le quitan `.savedState`, `.plist` y `.binarycookies`, y tiene que ser igual a `bundleID` o estar en `ownedNames`.
- Nada dentro del `.app` ni la carpeta `/Applications` cuentan como el `.app`.

- [ ] **Step 1: Write the failing tests** (`HardProtections(criticalRoots: [], sealedSystemLocations: [tmp + "/Applications"])`, app falsa `tmp/Applications/Foo.app`, home temporal)

```swift
@Test func bundlePassesOnlyWithItsOwnWaiver() {
    #expect(gate.validate(foo, waiver: nil) is refusal)
    #expect(gate.validate(foo, waiver: .uninstall(fooApp, appRoots: [apps])) is success)
    #expect(gate.validate(apps + "/Other.app", waiver: fooWaiver) is refusal)
    #expect(gate.validate(apps, waiver: fooWaiver) is refusal)
    #expect(gate.validate(foo + "/Contents/MacOS/Foo", waiver: fooWaiver) is refusal)
}
@Test func waiverRefusesWhenBundleIDChanged()          // reescribe Info.plist con otro id → «Ya no es la app que elegiste.»
@Test func symlinkBundleRefused()
@Test func noWaiverForSystemOfficialUninstallerOrAiry() // isSystem; "com.crowdstrike.falcon"; "local.airy.Airy"; profundidad 3 → nil
@Test func sensitiveDataWaivedOnlyForOwner()           // home/Library/Application Support/Slack: Slack ok, sin dispensa y con la de Discord → rechazo
@Test func sealedHomeNeverWaived()                     // dispensa de com.docker.docker sobre home/Library/Containers/com.docker.docker → rechazo
@Test func fragmentDataNeverWaived()                   // dispensa de 1Password sobre home/Library/Application Support/1Password → rechazo
@Test func userProtectedNeverWaived()
@Test func matchIsFirstOfMatches()                     // para 20 rutas de PathGateTests: match == matches.first, mismas reglas
```

- [ ] **Step 2: Run test to verify it fails.** Run `swift test --filter UninstallGateTests`. Expected: FAIL.
- [ ] **Step 3: Implement** según Interfaces. Cada `return` de `match` pasa a añadir a una lista con su `Rule`, y `match` devuelve el primero.
- [ ] **Step 4: Run tests.** Run `swift test --filter "UninstallGateTests|PathGateTests|FunnelTests"`. Expected: PASS; las pruebas del plan 1 no cambian.
- [ ] **Step 5: Commit.** Mensaje: `feat: dispensa acotada de PathGate para desinstalar una app concreta` (+ Co-Authored-By).

---

### Task 3: Restos de una app y plan de desinstalación (`LeftoverFinder`, `UninstallPlan`)

**Files:**
- Create: `Sources/DiskMapCore/Apps/LeftoverFinder.swift`, `Sources/DiskMapCore/Apps/UninstallPlan.swift`
- Test: `Tests/DiskMapCoreTests/LeftoverTests.swift`

**Interfaces:**
- Consumes: `AppRecord`, `AppInventorySnapshot` (Task 1), `ProtectionWaiver`, `PathGate.validate(_:waiver:)` (Task 2), `AllocatedSize.of`, `TimeBudget`.
- Produces:
```swift
public struct Leftover: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable, CaseIterable {
        case appSupport, caches, containers, preferences, byHost, savedState, httpStorage, logs, launchAgent, webKit,
             cookies, applicationScripts, autosave, syncedPreferences, plugin, receipt, systemLocation
    }
    public let path: String            // en .receipt: el pkg id
    public let kind: Kind
    public let bytes: Int64
    public let risk: Risk
    public let preselected: Bool
    public let matchedByName: Bool
    public let reason: String          // por qué esta etiqueta (español)
    public let launchLabel: String?    // solo .launchAgent
    public var id: String { kind.rawValue + ":" + path }
    public var canSelect: Bool { risk != .doNotTouch }
}
public struct UninstallPlan: Sendable, Equatable, Identifiable {
    public let app: AppRecord
    public let appBytes: Int64
    public let leftovers: [Leftover]   // risk asc, bytes desc, path
    public let refusal: String?
    public let sharedWith: String?
    public let sizeComplete: Bool
    public var id: String { app.path }
    public var leftoverBytes: Int64 { get }          // restos con canSelect
    public var realBytes: Int64 { get }              // appBytes + leftoverBytes
    public var defaultSelection: Set<String> { get } // preselected && canSelect
    public func bytes(selected: Set<String>) -> Int64 // appBytes + seleccionados
}
public struct LeftoverFinder: Sendable {
    public init(home: String, gate: PathGate, runner: any CommandRunning, appRoots: [String],
                systemLibrary: String = "/Library", budget: Duration = TimeBudget.sizeMeasure)
    public func plan(for app: AppRecord, inventory: AppInventorySnapshot) async -> UninstallPlan
}
```
Tabla de ubicaciones (bajo `home/Library`). «id» quiere decir `bundleID` o un `helperBundleID`; «nombre» quiere decir una de las `AppInventory.nameVariants`.

| Kind | Ruta | Coincide por | Riesgo | Preselec. | Motivo visible |
|---|---|---|---|---|---|
| appSupport | `Application Support/<id\|nombre>` | id, nombre | Tú decides | sí | «Datos y ajustes de la app; si la reinstalas empezará de cero.» |
| caches | `Caches/<id\|nombre>` | id, nombre | Sin problema | sí | «Caché: se regenera.» |
| containers | `Containers/<id>` | id | Tú decides | sí | «Datos de la app (sandbox).» |
| preferences | `Preferences/<id>.plist` | id | Tú decides | sí | «Ajustes de la app.» |
| byHost | `Preferences/ByHost/<id>.*.plist` | id | Tú decides | sí | «Ajustes de la app en este Mac.» |
| savedState | `Saved Application State/<id>.savedState` | id | Sin problema | sí | «Estado de ventanas: se regenera.» |
| httpStorage | `HTTPStorages/<id>` y `<id>.binarycookies` | id | Sin problema | sí | «Datos de red de la app.» |
| logs | `Logs/<id\|nombre>` | id, nombre | Sin problema | sí | «Registros.» |
| launchAgent | `LaunchAgents/*.plist` cuyo `Label` es un id o empieza por `<id>.`, o cuyo `Program`/`ProgramArguments[0]` está dentro de `app.path` | plist | Tú decides | sí | «Se ejecuta al iniciar sesión; se detiene antes.» |
| webKit | `WebKit/<id>`, `WebKit/com.apple.WebKit.WebContent/<id>` | id | Sin problema | sí | «Caché web de la app.» |
| cookies | `Cookies/<id>.binarycookies` | id | Sin problema | sí | «Cookies de la app.» |
| applicationScripts | `Application Scripts/<id>` | id | Tú decides | sí | «Scripts de la app.» |
| autosave | `Autosave Information/<id>` | id | Tú decides | **no** | «Puede tener documentos sin guardar.» |
| syncedPreferences | `SyncedPreferences/<id>.plist` | id | Tú decides | sí | «Ajustes sincronizados.» |
| plugin | `Services/<nombre>.workflow`, `QuickLook/<nombre>.qlgenerator`, `Audio/Plug-Ins/{Components,VST,VST3}/<nombre>.*` | nombre | Tú decides | **no** | «Otras apps pueden usar este complemento.» |
| receipt | `pkgutil --file-info <app.path>` → líneas `pkgid: X` (10 s) | — | Sin problema | sí | «Registro de instalación; pide contraseña de administrador.» |
| systemLocation | `<systemLibrary>/{Application Support,Caches,Logs,Preferences,LaunchAgents,LaunchDaemons,PrivilegedHelperTools}/<id\|nombre>*` | id, nombre | No borrar | no | «Fuera de tu carpeta personal: Airy no lo borra.» |

Reglas, aplicadas en este orden:
1. **Solo por nombre** (fila de id+nombre en la que encaja el nombre pero no el id): Tú decides, no preseleccionado, `matchedByName = true`, motivo «Coincide por nombre: revisa que sea de «\(name)».».
2. Cada ruta pasa por `gate.validate(path, waiver: .uninstall(app, appRoots:))`. Si hay rechazo: No borrar, motivo = el del rechazo. Si `validate(path, waiver: nil)` rechaza pero con dispensa pasa: Tú decides, **no** preseleccionado, motivo «Datos de cuenta de «\(name)»: si la reinstalas tendrás que volver a configurarla.».
3. Suelo: `strictest(fila, RiskPolicy.minimumRisk(forPath:home:))`.
4. **Otra copia instalada:** si el inventario tiene otro `AppRecord` con el mismo `bundleID` y distinta ruta, `sharedWith` = esa ruta y todos los restos pasan a No borrar con «Otra copia instalada en \(ruta) los usa.».
5. **No se puede desinstalar:** si `ProtectionWaiver.uninstall` da `nil`, se rellena `refusal`:
   - sistema: «Es parte de macOS.»;
   - prefijo de desinstalador oficial: «Usa el desinstalador oficial de «\(name)».»;
   - `local.airy.*`: «Es Airy.»;
   - ruta de Setapp: «Desinstálala desde Setapp.»;
   - cualquier otra ruta: «Solo se desinstalan apps de Aplicaciones.».
6. Tamaños con `AllocatedSize.of` dentro de `TimeBudget.run(budget)`. Si se agota, `sizeComplete = false` y lo que no se midió queda con 0 bytes.

- [ ] **Step 1: Write the failing tests** (home y raíces temporales, app `com.example.foo` «Foo Bar», `FakeRunner` con salida `pkgid: com.example.foo.pkg` para `pkgutil`)

```swift
@Test func findsLeftoversByBundleIDInEveryHomeLocation() async   // Set(kinds) ⊇ todas menos receipt/systemLocation/plugin
@Test func riskTableAndPreselection() async   // caches .safe sí; appSupport .yourCall sí; autosave .yourCall no; plugin no
@Test func nameOnlyMatchIsYourCallUnselected() async               // Application Support/FooBar
@Test func shortOrGenericNamesDoNotMatch() async                   // app «Notes» y «Abc»: ningún resto por nombre
@Test func launchAgentOwnedByLabelOrProgram() async                // Label com.example.foo.helper ✓; ProgramArguments en Foo.app ✓; otro ✗
@Test func receiptsFromPkgutil() async                             // runner.calls contiene ["/usr/sbin/pkgutil", ["--file-info", app.path]]
@Test func systemLibraryRowsAreRedInfo() async                     // systemLibrary = tmp/Library con Caches/com.example.foo
@Test func sensitiveDataIsAmberUnselected() async                  // app Slack: Application Support/Slack .yourCall, preselected false
@Test func protectedLeftoverIsRed() async                          // ProtectList del usuario con Caches/com.example.foo
@Test func secondCopyMakesLeftoversInformational() async           // sharedWith != nil; todos .doNotTouch; defaultSelection vacío
@Test func refusalTexts() async                                    // las cinco frases exactas
@Test func realSizeAddsAppAndSelectableLeftovers() async           // realBytes == appBytes + suma de canSelect
```

- [ ] **Step 2: Run test to verify it fails.** Run `swift test --filter LeftoverTests`. Expected: FAIL.
- [ ] **Step 3: Implement** según Interfaces y tabla. Los `plist` de LaunchAgents se leen con `PropertyListSerialization`; los ilegibles se saltan.
- [ ] **Step 4: Run tests.** Run `swift test --filter LeftoverTests`. Expected: PASS (12).
- [ ] **Step 5: Commit.** Mensaje: `feat: restos de cada app y plan de desinstalación con tamaño real` (+ Co-Authored-By).

---

### Task 4: Embudo de desinstalación (cerrar, `launchctl bootout`, Homebrew o Papelera, recibos)

**Files:**
- Create: `Sources/DiskMapCore/System/PrivilegedRunner.swift`, `Sources/DiskMapCore/System/AppQuitter.swift`, `Sources/DiskMapCore/Cleanup/CleanupExecutor+Uninstall.swift`
- Modify: `Sources/DiskMapCore/Cleanup/CleanupExecutor.swift`. El `init` gana tres parámetros por defecto: `privileged: any PrivilegedRunning = OsascriptPrivilegedRunner()`, `quitter: any AppQuitting = WorkspaceQuitter()` y `appRoots: [String]? = nil` (`nil` ⇒ `ProtectionWaiver.productionAppRoots(home:)`). También gana un método interno `trashValidated(_ v: ValidatedPath) throws -> Int64`, que es la única llamada a `trashItem`.
- Modify: `Sources/DiskMapCore/Persistence/OperationLog.swift` (comentario de `action`: más `"uninstall"`, `"remove_broken_links"`).
- Test: `Tests/DiskMapCoreTests/UninstallFunnelTests.swift`

**Interfaces:**
- Consumes: `UninstallPlan`, `Leftover` (Task 3), `ProtectionWaiver` (Task 2), `OperationContext`, `OperationLog`, el gancho `beforeMove` (plan 1, Task 8).
- Produces:
```swift
public enum PrivilegedOutcome: Sendable, Equatable { case ok(CommandOutput), cancelled, failed(String) }
public protocol PrivilegedRunning: Sendable {
    /// Una sola petición de contraseña para todos los comandos; cada uno es [ejecutable, argumentos…].
    func run(_ commands: [[String]], prompt: String) async -> PrivilegedOutcome
}
public struct OsascriptPrivilegedRunner: PrivilegedRunning {
    public init(runner: any CommandRunning = ProcessRunner())
    /// Texto AppleScript fijo (`on run argv`): reconstruye cada comando con `quoted form of` de cada argumento,
    /// los une con " ; " y llama a `do shell script … with administrator privileges with prompt (item 1 of argv)`.
    static let scriptLines: [String]
    /// ["-e", línea…, "--", prompt, "\(n1)", exe1, args1…, "\(n2)", exe2, args2…]; n = número de elementos del comando.
    static func arguments(for commands: [[String]], prompt: String) -> [String]
    // estado 0 → .ok; stderr con "-128" → .cancelled; otro → .failed(stderr recortado a 300)
}
public enum QuitResult: Sendable, Equatable { case notRunning, quit, stillRunning, unknown }
public protocol AppQuitting: Sendable {
    func isRunning(bundleID: String) -> Bool?                           // nil = no se sabe
    func quit(bundleID: String, timeout: Duration) async -> QuitResult  // cierre normal (terminate()); nunca forceTerminate()
}
public struct WorkspaceQuitter: AppQuitting { public init() }           // NSRunningApplication.runningApplications(withBundleIdentifier:)
public struct UninstallRequest: Sendable, Equatable, Identifiable {
    public let plan: UninstallPlan
    public let selected: Set<String>   // ids de Leftover
    public var id: String { plan.id }
    public init(plan: UninstallPlan, selected: Set<String>)
}
public struct UninstallReport: Sendable, Equatable {
    public var outcome: CleanupOutcome    // .movedToTrash(trashed) si algo fue a la Papelera; si no, .freed(freed); o .blocked/.failed
    public var trashedBytes: Int64, freedBytes: Int64
    public var notes: [String]            // pasos que fallaron sin parar el resto (español)
}
extension CleanupExecutor {
    public func uninstall(_ request: UninstallRequest, context: OperationContext = .user()) async -> UninstallReport
}
```
Orden fijo de `uninstall` (cada `blocked` deja todo como estaba):
1. Si `context.actor != .user`: `.blocked("Los agentes no pueden desinstalar apps; solo proponerlo en Airy.")`.
2. Si `plan.refusal`, o si `ProtectionWaiver.uninstall(app, appRoots:)` es `nil`: `.blocked(motivo)`.
3. Se vuelve a validar el `.app` con `gate.validate(app.path, waiver:)`; si falla, `.blocked(motivo)`.
4. **Cerrar.** Primero `isRunning(bundleID)`: `nil` ⇒ `.blocked("No se pudo comprobar si «\(name)» está abierta; Airy no sigue.")`. Para el id principal y cada ayudante que esté abierto se llama `quit(timeout: .seconds(30))`. Con `.stillRunning` o `.unknown`: `.blocked("«\(name)» sigue abierta (quizá te pide guardar algo). Ciérrala y vuelve a intentarlo.")`.
5. Por cada `.launchAgent` seleccionado: `runner.run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(label)"], timeout: 15)`. Un estado distinto de 0 añade la nota «No se pudo detener \(label): \(stderr).» y sigue.
6. **Homebrew** (`caskToken != nil` y `runner.resolve("brew")` no es `nil`): `["uninstall", "--cask", "--zap", token]` con 600 s. Un estado distinto de 0 da `.failed("Homebrew no pudo desinstalarla: \(stderr recortado a 300)")` y para ahí. Si al terminar el `.app` sigue en su sitio, va a la Papelera como en el paso 7. Con `caskToken` pero sin `brew`, añade la nota «Homebrew no está disponible; la app va a la Papelera.» y sigue por el paso 7. `freedBytes` = bytes medidos antes de lo que ya no existe después.
7. **Papelera:** `confirmUnchanged` y luego `trashValidated` del `.app`.
8. Restos seleccionados con `canSelect` (no `.receipt` ni `.systemLocation`) que aún existan: para cada uno, `validate(_:waiver:)`, `confirmUnchanged` y `trashValidated`. Si uno se rechaza, nota con el motivo y se salta.
9. Recibos seleccionados: **una** llamada `privileged.run(ids.map { ["/usr/sbin/pkgutil", "--forget", $0] }, prompt: "Airy necesita tu contraseña para borrar el registro de instalación de «\(name)».")`. Si es `.cancelled`, nota «Cancelaste la contraseña: el registro de instalación se queda.»; si es `.failed`, nota con el motivo.
10. Se añade un `OperationRecord` con `action "uninstall"`, `itemID` = bundleID, `title` = nombre, `paths` = lo que fue a la Papelera, `command` = los argumentos de brew si los hubo, `message` = notas unidas por « · ». El historial se registra como en `trashPaths` (Papelera ≠ liberado).

- [ ] **Step 1: Write the failing tests** (`HardProtections(criticalRoots: [], sealedSystemLocations: [apps])`, `appRoots: [apps]`; `FakeQuitter` que registra llamadas; `FakePrivileged` que registra `commands` y devuelve lo configurado; `FakeRunner`)

```swift
@Test func agentCannotUninstall() async                // .agent("x") → .blocked; nada movido; sin llamadas
@Test func refusedPlanDoesNothing() async
@Test func quitsBeforeTrashing() async                 // FakeQuitter running → quit → .app en la Papelera; quitter.calls == ["com.example.foo"]
@Test func stillRunningBlocksAndTouchesNothing() async // .stillRunning → .blocked; .app y restos siguen; runner sin llamadas
@Test func unknownRunningStateBlocks() async           // isRunning nil
@Test func bootsOutSelectedLaunchAgents() async        // ["/bin/launchctl", ["bootout", "gui/\(getuid())/com.example.foo.helper"]]
@Test func brewCaskRunsZapFirst() async                // primera llamada: brew ["uninstall","--cask","--zap","foo"]
@Test func brewFailureStopsBeforeTrash() async         // estado 1 → .failed; .app y restos siguen
@Test func onlySelectedLeftoversAreTrashed() async
@Test func leftoverSwappedForSymlinkIsRefused() async  // beforeMove cambia Caches/com.example.foo por enlace a home/Documents → nota; Documents intacto
@Test func bundleReplacedAfterPlanIsRefused() async    // tras planificar, Info.plist con otro id → .blocked; nada movido
@Test func receiptsUseOnePrivilegedCallWithArgumentArrays() async {
    #expect(privileged.calls == [[["/usr/sbin/pkgutil", "--forget", "com.example.foo.pkg"],
                                  ["/usr/sbin/pkgutil", "--forget", "com.example.foo.extra"]]])
}
@Test func cancelledPasswordKeepsRestAndNotes() async  // .cancelled → outcome .movedToTrash; notes contiene «Cancelaste la contraseña…»
@Test func osascriptArgumentsNeverInterpolateIntoScript() {
    let hostile = "a'; rm -rf ~ #"
    let args = OsascriptPrivilegedRunner.arguments(for: [["/bin/echo", hostile]], prompt: "p")
    #expect(args.contains(hostile))
    #expect(!OsascriptPrivilegedRunner.scriptLines.joined().contains(hostile))
    #expect(OsascriptPrivilegedRunner.scriptLines.joined().contains("quoted form of"))
}
@Test func uninstallIsLogged() async                    // log.records().last?.action == "uninstall", actor .user
```

- [ ] **Step 2: Run test to verify it fails.** Run `swift test --filter UninstallFunnelTests`. Expected: FAIL.
- [ ] **Step 3: Implement** según Interfaces y orden. La prueba `trashItemOnlyCalledFromTheFunnel` del plan 1 debe seguir pasando: `CleanupExecutor+Uninstall.swift` no llama a `trashItem(` directamente.
- [ ] **Step 4: Run tests.** Run `swift test 2>&1 | tail -3`. Expected: todo en verde.
- [ ] **Step 5: Commit.** Mensaje: `feat: desinstalación completa por el embudo (cerrar, bootout, Homebrew o Papelera, recibos)` (+ Co-Authored-By).

---

### Task 5: Restos huérfanos y enlaces rotos

**Files:**
- Create: `Sources/DiskMapCore/Apps/OrphanFinder.swift`, `Sources/DiskMapCore/Apps/BrokenLinks.swift`
- Modify: `Sources/DiskMapCore/Cleanup/CleanupExecutor+Uninstall.swift` (`removeBrokenLinks`)
- Test: `Tests/DiskMapCoreTests/OrphanTests.swift`

**Interfaces:**
- Consumes: `AppInventorySnapshot` (Task 1), `PathGate`, `PrivilegedRunning` (Task 4).
- Produces:
```swift
public struct OrphanGroup: Sendable, Equatable, Identifiable {
    public let bundleID: String
    public let paths: [String]
    public let bytes: Int64
    public let lastModified: Date
    public let risk: Risk                // .safe (las protegidas no llegan aquí)
    public var id: String { bundleID }
}
public enum OrphanScan: Sendable, Equatable { case found([OrphanGroup]), undecided(String) }
public protocol BundleIDLookup: Sendable { func isInstalled(_ bundleID: String) async -> Bool? }   // nil = no se sabe
public struct SpotlightLookup: BundleIDLookup {
    public init(runner: any CommandRunning, timeout: TimeInterval = 5)
    // /usr/bin/mdfind ["kMDItemCFBundleIdentifier == \"\(id)\""]: salida no vacía → true; vacía con estado 0 → false; otro → nil
}
public struct OrphanFinder: Sendable {
    public static let minimumIdle: TimeInterval = 30 * 86_400
    public static let candidateFolders = ["Library/Caches", "Library/Logs", "Library/Saved Application State"]
    public static let sensitivePatterns = ["ssh", "gpg", "gnupg", "keychain", "1password", "bitwarden", "lastpass",
                                           "keepass", "dashlane", "enpass"]
    public init(home: String, gate: PathGate, lookup: any BundleIDLookup, now: @escaping @Sendable () -> Date = Date.init)
    public func scan(inventory: AppInventorySnapshot) async -> OrphanScan
    /// Justo antes de borrar: el mismo árbol de decisión con un inventario nuevo.
    public func stillOrphan(_ group: OrphanGroup, inventory: AppInventorySnapshot) async -> Bool
    /// "com.foo.bar" o "com.foo.bar.savedState" → id; solo com|org|net|io, ≥ 3 componentes, [A-Za-z0-9._-].
    static func bundleID(fromEntryName name: String) -> String?
}
public struct BrokenLink: Sendable, Equatable, Identifiable {
    public let path: String, target: String, needsAdmin: Bool
    public var id: String { path }
}
public enum BrokenLinks {
    public static let directory = "/usr/local/bin"
    /// lstat S_IFLNK, readlink, stat == ENOENT ⇒ roto (otros errores ⇒ no se lista); needsAdmin = access(dir, W_OK) != 0.
    public static func find(in directory: String = BrokenLinks.directory) -> [BrokenLink]
    /// ["/usr/bin/find", dir, "-maxdepth", "1", "-type", "l", "(", "-name", n1, "-o", "-name", n2, ")",
    ///  "!", "-exec", "/bin/test", "-e", "{}", ";", "-delete"]
    static func deleteCommand(directory: String, names: [String]) -> [String]
    static func globEscaped(_ name: String) -> String          // \ * ? [ ] precedidos de \
}
extension CleanupExecutor {
    /// Agentes ⇒ .blocked. Vuelve a llamar a `find` y solo actúa sobre los que siguen rotos con el mismo destino;
    /// nombres sin "/". Si alguno needsAdmin: privileged.run([cmd], prompt: "Airy necesita tu contraseña para quitar
    /// enlaces rotos de /usr/local/bin."); si no, runner.run(cmd). Resultado .freed(0); registro "remove_broken_links"
    /// con message = "ruta → destino" de cada uno.
    public func removeBrokenLinks(_ links: [BrokenLink], context: OperationContext = .user()) async -> CleanupOutcome
    func removeBrokenLinks(_ links: [BrokenLink], directory: String, context: OperationContext) async -> CleanupOutcome  // pruebas
}
```
Árbol de decisión de `scan`. El primer «no» descarta el id.
1. Si `inventory.complete == false`, devuelve `.undecided("No se pudo leer la lista completa de apps; Airy no marca restos como huérfanos.")`.
2. Solo se miran las entradas directas de `candidateFolders`, y solo las que dan un id. **Nunca** se miran Containers, Group Containers, LaunchAgents, LaunchDaemons, Application Scripts ni Application Support.
3. No si el id empieza por `com.apple.` o `local.airy.`, o si contiene en minúsculas un elemento de `sensitivePatterns`.
4. No si `gate.validate(ruta)` lo rechaza (protecciones duras y del usuario).
5. No si el id en minúsculas está en `inventory.installedIDs`.
6. No si la fecha más reciente entre el `mtime` de la entrada y el de sus hijos directos es posterior a `now() - minimumIdle`.
7. No si `lookup.isInstalled(id)` es `true` o `nil` (un fallo cuenta como instalada y no se guarda en ninguna caché).
8. Si pasa todo: huérfano. Se agrupa por id entre las tres carpetas y los bytes se suman con `AllocatedSize.of`.

- [ ] **Step 1: Write the failing tests** (home temporal, `utimes` para fechas, `FakeLookup`, inventario construido a mano)

```swift
@Test func incompleteInventoryDecidesNothing() async  // .undecided con el texto exacto
@Test func installedIDIsNotOrphan() async             // id principal y id de ayudante
@Test func recentFolderIsNotOrphan() async            // 29 días → no; 31 días → sí; hijo reciente en carpeta vieja → no
@Test func mdfindFailureMeansInstalled() async        // lookup nil → no huérfano
@Test func mdfindHitMeansInstalled() async
@Test func onlyCachesLogsSavedState() async           // mismo id viejo en Containers, Group Containers, LaunchAgents, Application Support → no aparece
@Test func sensitivePatternsNeverOrphans() async      // com.foo.ssh-agent, org.gnupg.x, com.1password.x, com.foo.keychainhelper
@Test func appleAndAiryNeverOrphans() async
@Test func userProtectedNeverOrphan() async
@Test func groupsAcrossFolders() async                // Caches + Logs + .savedState del mismo id → 1 grupo, bytes sumados
@Test func stillOrphanRechecks() async                // tras añadir la app al inventario → false
@Test func bundleIDParsing()                          // "com.a.b" ✓, "com.a.b.savedState" → "com.a.b", "Foo", "com.a", "com.a b.c", "../x" → nil
@Test func spotlightLookupQueryAndOutcomes() async    // FakeRunner: argumentos exactos; "/Apps/X.app\n" → true; "" → false; estado 1 → nil
@Test func brokenLinkFoundLiveLinkAndFileIgnored()    // carpeta temporal: roto ✓, vivo ✗, fichero ✗
@Test func deleteCommandEscapesAndOnlyTouchesBrokenSymlinks() async {
    // carpeta temporal con enlace roto "a *b?[1]", enlace roto "c", enlace vivo "a *b?[1]x" y fichero "d";
    // ProcessRunner real ejecuta deleteCommand(dir, ["a *b?[1]"]) → solo desaparece "a *b?[1]"
}
@Test func agentCannotRemoveLinks() async
@Test func adminLinksUsePrivilegedRunner() async      // needsAdmin → privileged.calls == [[cmd]]; runner sin llamadas
@Test func relinkedLinkIsNotRemoved() async           // entre find y remove, el destino pasa a existir → no se incluye
```

- [ ] **Step 2: Run test to verify it fails.** Run `swift test --filter OrphanTests`. Expected: FAIL.
- [ ] **Step 3: Implement** según Interfaces y árbol.
- [ ] **Step 4: Run tests.** Run `swift test --filter OrphanTests`. Expected: PASS (18).
- [ ] **Step 5: Commit.** Mensaje: `feat: restos huérfanos por bundle id y enlaces rotos de /usr/local/bin` (+ Co-Authored-By).

---

### Task 6: Grandes y viejos (núcleo) y selección compartida

**Files:**
- Create: `Sources/DiskMapCore/Sections/FileSelection.swift`, `Sources/DiskMapCore/Sections/LargeOldFinder.swift`
- Test: `Tests/DiskMapCoreTests/LargeOldTests.swift`

**Interfaces:**
- Consumes: `FileNode`, `RiskClassifier.classify(path:)`, `PathGate`, `Catalog.match`.
- Produces:
```swift
public struct ActionableFile: Sendable, Equatable, Identifiable {
    public let path: String, name: String, bytes: Int64, kind: ContentKind
    public let lastModified: Date?, lastOpened: Date?
    public let risk: Risk, protection: ProtectionMatch?, reasons: [String]
    public var id: String { path }
    public var canSelect: Bool { risk != .doNotTouch && protection == nil }
    public var lastActivity: Date? { get }     // la más reciente de lastModified y lastOpened
    /// risk = classifier.classify(path:).risk; si la ficha del catálogo no existe o no `regenerates`, al menos .yourCall;
    /// gate.validate falla ⇒ .doNotTouch con protection/reasons del rechazo.
    public static func make(node: FileNode, classifier: RiskClassifier, catalog: Catalog?, gate: PathGate,
                            lastOpened: Date?) -> ActionableFile
}
public struct FileSelection: Sendable, Equatable {
    public private(set) var ids: Set<String>
    public init()
    public mutating func toggle(_ file: ActionableFile)          // ignora !canSelect
    public mutating func selectAllGreen(_ files: [ActionableFile])
    public mutating func selectAll(_ files: [ActionableFile])    // verde + ámbar con canSelect
    public mutating func clear()
    public mutating func prune(to files: [ActionableFile])       // quita ids que ya no están o no se pueden marcar
    public func selected(in files: [ActionableFile]) -> [ActionableFile]   // orden de `files`
    public func bytes(in files: [ActionableFile]) -> Int64
    public static func groups(_ files: [ActionableFile]) -> [(risk: Risk, files: [ActionableFile])]   // verde, ámbar, rojo; sin vacíos
}
public protocol FileUsageReading: Sendable { func lastOpened(path: String) -> Date? }
public struct SpotlightFileUsage: FileUsageReading { public init() }    // kMDItemLastUsedDate
public struct LargeOldQuery: Sendable, Equatable {
    public enum Sort: String, Sendable, CaseIterable { case size, oldest, name }   // «Tamaño», «Más antiguos», «Nombre»
    public enum Scope: String, Sendable, CaseIterable { case home, everything }    // «Tu carpeta», «Todo el disco»
    public static let sizeSteps: [Int64] = [100_000_000, 500_000_000, 1_000_000_000, 5_000_000_000]
    public static let idleSteps: [Int?] = [nil, 3, 6, 12]     // meses; «Cualquier fecha», «3 meses», «6 meses», «1 año»
    public var minBytes: Int64 = 100_000_000
    public var minMonthsIdle: Int? = nil
    public var kinds: Set<ContentKind> = []                    // vacío = todos
    public var scope: Scope = .home
    public var sort: Sort = .size
    public var limit = 500
    public init()
}
public struct LargeOldFinder: Sendable {
    public init(classifier: RiskClassifier, catalog: Catalog?, gate: PathGate, home: String,
                usage: any FileUsageReading = SpotlightFileUsage(), now: @escaping @Sendable () -> Date = Date.init)
    /// Solo ficheros (no carpetas ni agregados «Otros»), sin entrar en `.app`; `usage` solo para los que pasan el tamaño.
    /// Un mes = 30 días; inactivo = now − lastActivity; sin fechas ⇒ no pasa un filtro de meses.
    /// Orden: size = bytes desc; oldest = lastActivity asc (nil al final); name = localizedStandardCompare; empate → path.
    public func find(in root: FileNode, query: LargeOldQuery) -> [ActionableFile]
}
```

- [ ] **Step 1: Write the failing tests** (árbol de `FileNode` construido a mano bajo un home temporal; `FakeUsage` que cuenta llamadas)

```swift
@Test func findsOnlyFilesAboveMinimum()
@Test func skipsAggregatesAndAppBundles()
@Test func idleFilterUsesNewestOfOpenedAndModified()   // modificado hace 1 año pero abierto hace 1 mes → no pasa «6 meses»
@Test func sortsBySizeOldestAndName()
@Test func kindFilterAndHomeScope()
@Test func personalFilesAtLeastAmber()                 // home/Movies/x.mov y home/Library/Application Support/x.bin → .yourCall
@Test func protectedFileIsRedWithoutCheckbox()         // home/Library/Mail/x.emlx → .doNotTouch, canSelect false
@Test func usageOnlyQueriedForCandidates()             // 3 ficheros grandes y 50 pequeños → 3 llamadas
@Test func selectAllNeverSelectsRed()
@Test func selectAllGreenOnlyGreen()
@Test func toggleIgnoresRed()
@Test func pruneDropsVanished()
@Test func groupsGreenFirst()
```

- [ ] **Step 2: Run test to verify it fails.** Run `swift test --filter LargeOldTests`. Expected: FAIL.
- [ ] **Step 3: Implement** según Interfaces.
- [ ] **Step 4: Run tests.** Run `swift test --filter LargeOldTests`. Expected: PASS (13).
- [ ] **Step 5: Commit.** Mensaje: `feat: grandes y viejos con filtros, orden y selección por riesgo` (+ Co-Authored-By).

---

### Task 7: Duplicados (núcleo)

**Files:**
- Create: `Sources/DiskMapCore/Sections/DuplicateFinder.swift`, `Sources/DiskMapCore/Sections/DuplicateBoard.swift`, `Sources/DiskMapCore/Sections/DuplicateReport.swift`
- Modify: `Sources/DiskMapCore/Persistence/AppPaths.swift` (`public var duplicatesFile: URL { support.appendingPathComponent("duplicates.json") }`)
- Test: `Tests/DiskMapCoreTests/DuplicateTests.swift`

**Interfaces:**
- Consumes: `RiskClassifier`, `PathGate`, `CryptoKit.SHA256`.
- Produces:
```swift
public struct DuplicateCopy: Sendable, Equatable, Identifiable {
    public let path: String, created: Date?, modified: Date?
    public let reclaimableBytes: Int64     // getattrlist ATTR_CMNEXT_PRIVATESIZE; si no hay, st_blocks * 512
    public let risk: Risk, protection: ProtectionMatch?
    public var id: String { path }
    public var canSelect: Bool { risk != .doNotTouch && protection == nil }
}
public struct DuplicateGroup: Sendable, Equatable, Identifiable {
    public let size: Int64                 // st_size de cada copia
    public let copies: [DuplicateCopy]     // ≥ 2; el conservado sugerido primero
    public let keeper: String
    public var id: String { keeper }
    public var wastedBytes: Int64 { get }  // reclaimableBytes de las que no son keeper
}
public struct DuplicateSearch: Sendable, Equatable {
    public var roots: [String]
    public var minBytes: Int64 = 1_000_000
    public static let sizeSteps: [Int64] = [1_000_000, 10_000_000, 100_000_000]
    public static let skippedNames: Set<String> = [".Trash", ".git", "node_modules", ".venv"]
    public static func defaultRoots(home: String) -> [String]   // hijos de home salvo "Library" y ".Trash"
    public init(roots: [String], minBytes: Int64 = 1_000_000)
}
public struct DuplicateResult: Sendable, Equatable {
    public let groups: [DuplicateGroup]    // wastedBytes desc, luego keeper
    public let complete: Bool
    public let filesExamined: Int
    public let date: Date
}
public struct DuplicateRemoval: Sendable, Equatable { public let keep: String; public let remove: [String]; public let size: Int64 }
public struct DuplicateFinder: Sendable {
    public static let partialChunk = 65_536
    public init(home: String, classifier: RiskClassifier, gate: PathGate)
    /// Cancelable: con Task.cancel() devuelve lo hallado con complete false. progress = ficheros examinados (≤ 10/s).
    public func find(_ search: DuplicateSearch, progress: @escaping @Sendable (Int) -> Void = { _ in }) async -> DuplicateResult
    /// Justo antes de borrar: relee el contenido completo de `keep` y de cada `remove`. Devuelve ruta → motivo de rechazo
    /// (vacío = todo bien).
    public func verify(_ removal: DuplicateRemoval) async -> [String: String]
    static func suggestedKeeper(_ copies: [DuplicateCopy], home: String) -> String
}
public struct DuplicateBoard: Sendable, Equatable {
    public init(groups: [DuplicateGroup])
    public private(set) var groups: [DuplicateGroup]
    public private(set) var keepers: [String: String]      // group.id → ruta conservada
    public private(set) var selected: Set<String>
    public mutating func toggle(_ path: String, in group: DuplicateGroup)   // nunca marca !canSelect ni el conservado; nunca deja el grupo sin copia sin marcar
    public mutating func keep(_ path: String, in group: DuplicateGroup)     // cambia el conservado y lo desmarca
    public mutating func selectAllCopies()                 // en cada grupo, todas salvo el conservado y las !canSelect
    public mutating func clear()
    public var reclaimableBytes: Int64 { get }
    public func removals() -> [DuplicateRemoval]           // nunca incluye el conservado
}
public enum DuplicateReport {
    public struct File: Codable, Sendable, Equatable {
        public struct Group: Codable, Sendable, Equatable {
            public let size: Int64, reclaimableBytes: Int64, keeper: String, copies: [String]
        }
        public let date: Date, complete: Bool, filesExamined: Int, groups: [Group]
    }
    public static func save(_ result: DuplicateResult, to url: URL) throws    // JSON snake_case, escritura atómica, 0600
    public static func load(from url: URL) throws -> File?                    // nil si no existe
}
```
Algoritmo de `find`:
1. Recorre con `opendir`/`lstat` sin seguir enlaces y sin cambiar de volumen. Salta `skippedNames` y no entra en `*.app`. Las carpetas ilegibles se saltan y se cuentan.
2. Se queda con los ficheros regulares con `st_size ≥ minBytes`. Agrupa por `(st_dev, st_ino)` y se queda con una sola ruta: los hard links no son duplicados.
3. Agrupa por tamaño (≥ 2).
4. Calcula un SHA-256 parcial de los primeros y los últimos `partialChunk` bytes y vuelve a agrupar (≥ 2).
5. Calcula un SHA-256 completo por bloques de 1 MiB, con `open(O_RDONLY | O_NOFOLLOW)`. Si el fichero cambia durante la lectura (tamaño o `mtime`), se descarta. Los grupos de ≥ 2 quedan.

Hay un `TaskGroup` de ancho `activeProcessorCount`. Riesgo de cada copia: `strictest(classifier.classify(path:).risk, .yourCall)`; si `gate.validate` falla, rojo con su protección.

`suggestedKeeper`, por orden: (1) la primera copia (por ruta) que no `canSelect`, porque lo protegido nunca se propone borrar; (2) las que no estén en `home/Downloads` ni `home/Desktop`; (3) la creada antes; (4) la ruta más corta; (5) el orden alfabético.

`verify` rechaza, con estos motivos:
- `remove` contiene `keep`: «Es la copia que conservas.»;
- `keep` no existe o su contenido es distinto: «Ya no existe la copia que conservas.» / «La copia que conservas ha cambiado.»;
- una copia no existe: «Ya no existe.»;
- una copia ha cambiado de tamaño o de contenido: «Ha cambiado desde la búsqueda.».

- [ ] **Step 1: Write the failing tests** (carpetas temporales; ficheros de 200 KiB)

```swift
@Test func identicalFilesAreGrouped() async
@Test func sameEndsDifferentMiddleAreNotDuplicates() async   // primeros y últimos 64 KiB iguales, centro distinto
@Test func hardLinksAreNotDuplicates() async                 // link() → ningún grupo
@Test func symlinksIgnored() async
@Test func belowMinimumIgnored() async
@Test func clonedCopyReclaimsNothing() async                 // clonefile(); si no es APFS, la prueba se salta con un comentario
@Test func keeperPrefersProtectedThenNotDownloadsThenOldest()
@Test func selectAllCopiesNeverSelectsKeeperOrProtected()
@Test func toggleNeverSelectsWholeGroup()                    // grupo de 2: marcar el conservado no hace nada; keep() cambia y desmarca
@Test func removalsNeverIncludeKeeper()
@Test func verifyRejectsChangedFile() async
@Test func verifyRejectsMissingKeeper() async
@Test func verifyRefusesRemovingTheKeeper() async
@Test func reportHasNoHashes() throws {                      // el JSON no contiene ningún hex de 64 caracteres; claves exactas
    // date, complete, files_examined, groups[].size, reclaimable_bytes, keeper, copies
}
@Test func cancellationGivesIncomplete() async
```

- [ ] **Step 2: Run test to verify it fails.** Run `swift test --filter DuplicateTests`. Expected: FAIL.
- [ ] **Step 3: Implement** según Interfaces y algoritmo.
- [ ] **Step 4: Run tests.** Run `swift test --filter DuplicateTests`. Expected: PASS (15).
- [ ] **Step 5: Commit.** Mensaje: `feat: duplicados por tamaño, hash parcial y completo, con copia a conservar` (+ Co-Authored-By).

---

### Task 8: Tipos de archivo (núcleo)

**Files:**
- Create: `Sources/DiskMapCore/Sections/FileTypeBreakdown.swift`
- Test: `Tests/DiskMapCoreTests/FileTypeTests.swift`

**Interfaces:**
- Consumes: `FileNode.kindBytes`, `ContentKind`.
- Produces:
```swift
public struct FileTypeSlice: Sendable, Equatable, Identifiable {
    public let kind: ContentKind, bytes: Int64, fraction: Double
    public var id: ContentKind { kind }
}
public struct FileTypeBreakdown: Sendable, Equatable {
    public let slices: [FileTypeSlice]       // sin tipos a 0; bytes desc; fracciones suman 1 (±1e-9)
    public let total: Int64
    public init(root: FileNode)
    /// Elementos de un tipo, mayores primero: ficheros con kind == k y paquetes `.app` (sin bajar dentro) para .apps;
    /// nunca agregados «Otros». hiddenBytes = bytes del tipo − suma de los listados (pequeños o fuera del límite).
    public static func items(of kind: ContentKind, in root: FileNode, limit: Int = 300) -> (items: [FileNode], hiddenBytes: Int64)
}
```

- [ ] **Step 1: Write the failing tests**

```swift
@Test func slicesSortedAndSumToOne()
@Test func zeroKindsDropped()
@Test func itemsOfKindSkipAggregatesAndStopAtApps()   // .apps lista Foo.app, no sus ficheros internos
@Test func hiddenBytesAccountsForRest()               // limit 2 de 5 → hiddenBytes == suma de los 3 restantes + agregados
```

- [ ] **Step 2: Run test to verify it fails.** Run `swift test --filter FileTypeTests`. Expected: FAIL.
- [ ] **Step 3: Implement** según Interfaces.
- [ ] **Step 4: Run tests.** Run `swift test --filter FileTypeTests`. Expected: PASS (4).
- [ ] **Step 5: Commit.** Mensaje: `feat: espacio por tipo de archivo y elementos de cada tipo` (+ Co-Authored-By).

---

### Task 9: Las secciones se activan, piezas comunes y vista Grandes y viejos

**Files:**
- Modify: `Sources/Airy/AppModel.swift`. `Section.isAvailable` es `true` para todas y desaparece `comingSoon`. Se añaden `let sections = SectionStores()` y las fábricas `largeOldFinder()`, `gate()` y `classifier()`, construidas con los ajustes vivos.
- Modify: `Sources/Airy/Shell/Sidebar.swift` (fuera el bloque «Próximamente» y `selectionDisabled`), `Sources/Airy/Shell/RootView.swift` (`SectionContent` dirige las cuatro secciones; se borra `SectionPlaceholder` si queda sin uso).
- Create: `Sources/Airy/Sections/SectionStores.swift`, `Sources/Airy/Sections/FileListComponents.swift`, `Sources/Airy/Sections/LargeOldView.swift`

**Interfaces:**
- Consumes: `ActionableFile`, `FileSelection`, `LargeOldFinder`, `LargeOldQuery` (Task 6); `CleanupFlow.requestTrash(paths:title:)` → `AppModel.trash(paths:title:context:)` (plan 1); `TreeGate.read(cancellable:)`; `MapNavigation.reveal(path:)`; `AppModel.protect(path:)`.
- Produces:
```swift
@MainActor @Observable final class SectionStores {
    let largeOld = LargeOldStore(); let fileTypes = FileTypesStore()
    let duplicates = DuplicatesStore(); let uninstaller = UninstallerStore()
}
@MainActor @Observable final class LargeOldStore {
    var query = LargeOldQuery(); var files: [ActionableFile] = []; var selection = FileSelection(); var isLoading = false
    func refresh(model: AppModel)      // cancela el anterior; lee el árbol con treeGate.read(cancellable: true)
}
struct SelectableFileRow: View        // casilla (si canSelect), icono Theme.symbol(for: kind), nombre, carpeta, tamaño,
                                      // fecha, RiskBadge(risk:), .help(reasons); menú: «Mostrar en Finder», «Ver en el mapa», «Proteger esto»
struct RiskGroupedList: View          // FileSelection.groups, cabecera por grupo con RiskBadge y total; filas que salen con .leafAway;
                                      // con varias a la vez, GustSweep + .gustSway (plan 2)
struct SelectionBar: View             // «Seleccionar todo lo verde», «Seleccionar todo», «Quitar selección»,
                                      // PrimaryButton «Mover a la Papelera · \(tamaño)» (desactivado si vacío)
```
Textos: fechas con `RelativeDateTimeFormatter` (`Theme.locale`): «Abierto hace 8 meses» si hay `lastOpened`; si no, «Modificado hace 8 meses». La confirmación usa `flow.requestTrash(paths:, title: n == 1 ? nombre : "\(n) archivos")`. Estados vacíos: sin análisis, «Analiza el disco para ver los archivos grandes.»; sin resultados, «Nada con estos filtros.». Filtros arriba: tamaño «≥ 100 MB»…; «Cualquier fecha / Sin abrir 3 meses / 6 meses / 1 año»; menú de tipos; segmentado «Tu carpeta / Todo el disco»; menú de orden. Se recalcula al aparecer y cuando cambian `query`, `model.scan` o `model.treeRevision`; nada corre si la sección no se ve. Tras confirmar, `selection.prune(to:)`.

- [ ] **Step 1: Verify the current state.** Run `swift build && swift test 2>&1 | tail -3`. Expected: verde. Esta tarea no añade lógica nueva al núcleo: su lógica ya la prueba Task 6.
- [ ] **Step 2: Implement** según Interfaces.
- [ ] **Step 3: Verify.** Run `swift build && swift test 2>&1 | tail -3`. Expected: verde.
- [ ] **Step 4: Manual check (DEBUG).** `D=$(mktemp -d); mkdir -p ~/AiryPrueba && mkfile 150m ~/AiryPrueba/grande.bin; AIRY_SUPPORT_DIR=$D .build/debug/Airy &` (guardar `$!`). Hay que comprobar cuatro cosas:
  - las cuatro secciones se pueden elegir y no queda ningún «Próximamente»;
  - tras el análisis, Grandes y viejos lista `grande.bin` en «Tú decides»;
  - los filtros y el orden cambian la lista;
  - un fichero de `~/Library/Mail` (si aparece) sale rojo y sin casilla.

  Después, marcar **solo** `grande.bin`, pulsar «Mover a la Papelera», confirmar y comprobar que la fila se va con `.leafAway`. Captura de la ventana propia con `DebugSnapshot`. Parar con `kill <PID>` y borrar `~/AiryPrueba`. No vaciar la Papelera.
- [ ] **Step 5: Commit.** Mensaje: `feat: secciones de la fase 2 activas y vista Grandes y viejos` (+ Co-Authored-By).

---

### Task 10: Vista Tipos de archivo con gráfico animado

**Files:**
- Create: `Sources/Airy/Sections/FileTypesView.swift`, `Sources/Airy/Sections/TypeDonut.swift`
- Modify: `Sources/Airy/Sections/SectionStores.swift` (`FileTypesStore`)

**Interfaces:**
- Consumes: `FileTypeBreakdown` (Task 8), `ActionableFile.make` y `FileSelection` (Task 6), `RiskGroupedList` y `SelectionBar` (Task 9).
- Produces:
```swift
@MainActor @Observable final class FileTypesStore {
    var breakdown: FileTypeBreakdown?; var chosen: ContentKind?
    var files: [ActionableFile] = []; var hiddenBytes: Int64 = 0; var selection = FileSelection()
    func refresh(model: AppModel); func choose(_ kind: ContentKind?, model: AppModel)
}
struct TypeDonut: View   // Canvas; porciones con Theme.color(for: kind) (gama fría de Theme.Airy tras el plan 2)
```
Comportamiento del gráfico:
- Al aparecer y al cambiar los datos, cada porción crece desde 0 grados con `Theme.zoomSpring`, escalonada con `Theme.stagger(index:)`. Con «Reducir movimiento» solo hay fundido.
- Al pasar el ratón la porción se resalta. En el centro van el total y, con el ratón encima, el tipo con su tamaño y su %.
- No hay `TimelineView` ni animación continua.

Leyenda al lado: tipo, tamaño y %. Al hacer clic en una porción o en una fila de la leyenda, sale debajo la lista de ese tipo (`RiskGroupedList` + `SelectionBar`). Si `hiddenBytes > 0`, el pie dice «y \(tamaño) en archivos pequeños». Sin análisis: «Analiza el disco para ver qué tipos ocupan más.».

- [ ] **Step 1: Implement** según Interfaces.
- [ ] **Step 2: Verify.** Run `swift build && swift test 2>&1 | tail -3`. Expected: verde.
- [ ] **Step 3: Manual check (DEBUG).** `AIRY_SUPPORT_DIR=$(mktemp -d) .build/debug/Airy &` (guardar `$!`). El gráfico entra animado, el ratón resalta y el clic en «Vídeo» lista vídeos. Con «Reducir movimiento» activado en Ajustes del Sistema solo hay fundido. `ps -o %cpu= -p <PID>` tras 10 s quieto en la sección da ≈ 0.0. Captura propia y `kill <PID>`.
- [ ] **Step 4: Commit.** Mensaje: `feat: vista Tipos de archivo con gráfico animado y acceso a los archivos` (+ Co-Authored-By).

---

### Task 11: Vista Duplicados

**Files:**
- Create: `Sources/Airy/Sections/DuplicatesView.swift`
- Modify: `Sources/Airy/Sections/SectionStores.swift` (`DuplicatesStore`)
- Modify: `Sources/Airy/Cleanup/CleanupFlow.swift` (`ConfirmRequest.Kind.duplicates([DuplicateRemoval])`, `requestRemoveDuplicates(_:)`)
- Modify: `Sources/Airy/Cleanup/ConfirmSheet.swift` (pinta `.duplicates`)
- Modify: `Sources/Airy/AppModel.swift` (`trashDuplicates`, guarda `duplicates.json`)

**Interfaces:**
- Consumes: `DuplicateFinder`, `DuplicateBoard`, `DuplicateRemoval`, `DuplicateReport`, `AppPaths.duplicatesFile` (Task 7).
- Produces:
```swift
@MainActor @Observable final class DuplicatesStore {
    var search: DuplicateSearch; var result: DuplicateResult?; var board = DuplicateBoard(groups: [])
    var examined = 0; var isSearching = false
    func start(model: AppModel); func cancel()
}
// AppModel:
func duplicateFinder() -> DuplicateFinder
/// Por cada removal: finder.verify; las copias rechazadas no se mueven y su motivo vuelve en `notes`; el resto,
/// trash(paths:title:context: .user()) en una sola llamada.
func trashDuplicates(_ removals: [DuplicateRemoval]) async -> (outcome: CleanupOutcome, notes: [String])
```
La búsqueda se lanza solo con el botón «Buscar duplicados» (nunca sola) y corre en `Task.detached` cancelable. Al terminar, la app guarda `DuplicateReport.save(result, to: paths.duplicatesFile)`; si falla, avisa con `report(.save, …)` y sigue.

Pantalla:
- Chips de carpetas («Tu carpeta» y «Elegir carpeta…» con `NSOpenPanel`), tamaño mínimo «≥ 1 MB / 10 MB / 100 MB».
- Progreso: «Comparando \(n) archivos…» con `WindLeaves(mode: .orbit(radius:))` alrededor del anillo (como el análisis tras el plan 2) y «Cancelar».
- Grupos en tarjetas: nombre, «\(n) copias de \(tamaño)», «Libera \(wastedBytes)».
- Cada copia en una fila: radio «Conservar», casilla, ruta, fecha y `RiskBadge`. Una copia protegida lleva candado y su motivo, sin casilla. Si `reclaimableBytes == 0`: «Copia APFS: no ocupa espacio extra».
- Botones «Seleccionar todas las copias» y `PrimaryButton` «Mover copias a la Papelera · \(board.reclaimableBytes)».
- Si `complete == false`: «Búsqueda incompleta: se canceló o no se pudo leer todo.».

Hoja `.duplicates`: por grupo, «Se conserva: \(ruta)» con marca verde y «A la Papelera: \(rutas)». Al final, el total y la nota «Antes de mover nada, Airy vuelve a comparar cada copia.».

- [ ] **Step 1: Implement** según Interfaces.
- [ ] **Step 2: Verify.** Run `swift build && swift test 2>&1 | tail -3`. Expected: verde.
- [ ] **Step 3: Manual check (DEBUG).** `mkdir -p ~/AiryPrueba/a ~/AiryPrueba/b && mkfile 5m ~/AiryPrueba/a/x.bin && cp ~/AiryPrueba/a/x.bin ~/AiryPrueba/b/x.bin && ln ~/AiryPrueba/a/x.bin ~/AiryPrueba/a/enlace.bin`. Luego `AIRY_SUPPORT_DIR=$(mktemp -d) .build/debug/Airy &` (guardar `$!`). Hay que comprobar cuatro cosas:
  - con «Elegir carpeta…» = `~/AiryPrueba`, sale un grupo de 2 copias y el hard link no cuenta;
  - no se pueden marcar las dos copias;
  - con `b/x.bin` marcada y `echo z >> ~/AiryPrueba/b/x.bin` antes de confirmar, no se mueve y aparece «Ha cambiado desde la búsqueda.»;
  - tras repetir la búsqueda y confirmar, la copia va a la Papelera.

  Después, `cat $AIRY_SUPPORT_DIR/duplicates.json` no tiene huellas. `kill <PID>` y borrar `~/AiryPrueba`.
- [ ] **Step 4: Commit.** Mensaje: `feat: vista Duplicados con copia a conservar y verificación antes de borrar` (+ Co-Authored-By).

---

### Task 12: Vista Desinstalador (apps, restos huérfanos, enlaces rotos)

**Files:**
- Create: `Sources/Airy/Sections/UninstallerView.swift`, `Sources/Airy/Sections/UninstallDetail.swift`, `Sources/Airy/Sections/OrphansView.swift`
- Modify: `Sources/Airy/Sections/SectionStores.swift` (`UninstallerStore`)
- Modify: `Sources/Airy/Cleanup/CleanupFlow.swift`. `ConfirmRequest.Kind` gana `.uninstall([UninstallRequest])`, `.orphans([OrphanGroup])` y `.brokenLinks([BrokenLink])`, con `requestUninstall(_:warning:proposedBy:)`, `requestTrashOrphans(_:)` y `requestRemoveBrokenLinks(_:)`. Las tandas de desinstalación van una a una con progreso por fila y resumen final, como `CleanupBatch`.
- Modify: `Sources/Airy/Cleanup/ConfirmSheet.swift` (pinta los tres tipos nuevos)
- Modify: `Sources/Airy/AppModel.swift`. `executor` recibe `appRoots`. Se añaden `inventorySnapshot()`, `uninstall(_:context:)`, `trashOrphans(_:)` y `removeBrokenLinks(_:)`. En DEBUG, `AIRY_APP_ROOTS` (rutas separadas por `:`) sustituye las raíces del inventario y `appRoots`.

**Interfaces:**
- Consumes: Tasks 1–5.
- Produces:
```swift
@MainActor @Observable final class UninstallerStore {
    enum Tab: String, CaseIterable { case apps, orphans, links }   // «Apps», «Restos huérfanos», «Enlaces rotos»
    enum Sort: String, CaseIterable { case realSize, name, lastUsed } // «Tamaño real», «Nombre», «Último uso»
    var tab: Tab = .apps; var sort: Sort = .realSize; var searchText = ""
    var inventory: AppInventorySnapshot?; var plans: [String: UninstallPlan] = [:]   // por app.path, se rellenan poco a poco
    var checkedApps: Set<String> = []; var leftoverSelection: [String: Set<String>] = [:]   // por defecto plan.defaultSelection
    var orphans: OrphanScan?; var orphanSelection: Set<String> = []; var links: [BrokenLink] = []; var linkSelection: Set<String> = []
    func refresh(model: AppModel)      // al primer aparecer y con «Actualizar»; nunca en segundo plano
}
// AppModel:
func inventorySnapshot() async -> AppInventorySnapshot       // HomebrewCasks.installed + AppInventory(roots:casks:)
func uninstall(_ request: UninstallRequest, context: OperationContext) async -> UninstallReport
    // executor.uninstall; luego updateTree(afterTouching: rutas movidas), refreshCounters, refreshVolumes
func trashOrphans(_ groups: [OrphanGroup]) async -> CleanupOutcome
    // inventario nuevo; solo los grupos con stillOrphan == true; trash(paths:title: "Restos huérfanos", context: .user())
func removeBrokenLinks(_ links: [BrokenLink]) async -> CleanupOutcome
```
**Pestaña Apps.**
- Lista: casilla (solo si `refusal == nil`), icono `NSWorkspace.shared.icon(forFile:)`, nombre y versión, insignias «Abierta» / «Homebrew» / «App Store», «Sin abrir desde hace \(x)» o «Sin datos de uso», tamaño real («+» si `!sizeComplete`) y `RiskBadge`: Tú decides, o No borrar con `refusal` como ayuda.
- Al hacer clic en una app se abre `UninstallDetail`: restos agrupados por riesgo (verde, ámbar, rojo), cada uno con casilla, ruta, tamaño y motivo; arriba, «App \(tamaño) + restos \(tamaño)».
- Botones: `PrimaryButton` «Desinstalar · \(bytes(selected:))»; y con varias marcadas, «Desinstalar \(n) apps · \(total)».

**Hoja `.uninstall`**, por app:
- «Se cerrará «\(name)» si está abierta (podrá pedirte guardar).»;
- o «Homebrew la desinstala con `brew uninstall --cask --zap \(token)`; lo que borra Homebrew no pasa por la Papelera.», o «La app irá a la Papelera.»;
- restos seleccionados: verde, y el ámbar en un bloque destacado «Revisa: esto no se regenera solo»;
- rojo bajo «Se quedan»;
- con recibos: «Pedirá tu contraseña de administrador.»;
- y el total.

**Pestaña Restos huérfanos.**
- Si es `.undecided(motivo)`, el texto del motivo.
- Si no, filas con id, carpetas, «Sin usar desde \(fecha)», tamaño y verde, más `SelectionBar` con «Mover a la Papelera · \(tamaño)».
- Si no hay ninguno: «No hay restos de apps desinstaladas.».

**Pestaña Enlaces rotos.**
- Filas «\(nombre) → \(destino)» y el botón «Quitar enlaces rotos».
- La hoja dice «Los enlaces rotos se borran: no apuntan a nada y no van a la Papelera.» y, si alguno `needsAdmin`, «Pedirá tu contraseña de administrador.».
- Si no hay ninguno: «No hay enlaces rotos en /usr/local/bin.».

Mientras se mide, las filas muestran el tamaño del `.app` y luego el real. Una app desinstalada sale con `.leafAway`; «Desinstalar \(n) apps» lanza `GustSweep` + `.gustSway` como «Borrar todo».

- [ ] **Step 1: Implement** según Interfaces.
- [ ] **Step 2: Verify.** Run `swift build && swift test 2>&1 | tail -3`. Expected: verde.
- [ ] **Step 3: Manual check (DEBUG; nunca una app real).**
  1. Crear una app falsa `$T/Apps/Prueba Airy.app` (`T=$(mktemp -d)`), con `Contents/Info.plist` (`CFBundleIdentifier` `com.example.airyprueba`, `CFBundleName` «Prueba Airy») y `Contents/MacOS/x`.
  2. Crear sus restos: `mkdir -p ~/Library/Caches/com.example.airyprueba && touch ~/Library/Preferences/com.example.airyprueba.plist`.
  3. Arrancar con `AIRY_APP_ROOTS=$T/Apps AIRY_SUPPORT_DIR=$(mktemp -d) .build/debug/Airy &` (guardar `$!`).
  4. Comprobar la lista y los restos (caché en verde, preferencias en ámbar).
  5. Desinstalar y confirmar: la app y los dos restos están en la Papelera, y el registro de operaciones tiene `uninstall`.
  6. Abrir las pestañas «Restos huérfanos» y «Enlaces rotos» (solo mirar; no confirmar nada fuera de la app de prueba).

  Captura propia y `kill <PID>`.
- [ ] **Step 4: Commit.** Mensaje: `feat: vista Desinstalador con restos, huérfanos y enlaces rotos` (+ Co-Authored-By).

---

### Task 13: MCP: herramientas de lectura de las secciones y `propose_uninstall`

**Files:**
- Create: `Sources/DiskMapCore/MCP/Tools/SectionTools.swift`
- Modify: `Sources/DiskMapCore/MCP/MCPTool.swift` (`MCPToolRegistry.standard()` añade las seis), `Sources/DiskMapCore/MCP/AiryEnvironment.swift` (gana `appRoots: [String]`, `usage: any AppUsageReading`, `bundleLookup: any BundleIDLookup`, `func inventorySnapshot() async -> AppInventorySnapshot`; `live()` con las raíces estándar), `Sources/DiskMapCore/Integration/AiryURL.swift` (caso `.uninstall`), `Sources/Airy/AppModel.swift` (`handle(url:)` para `.uninstall`)
- Test: `Tests/DiskMapCoreTests/MCPSectionToolTests.swift`, `Tests/DiskMapCoreTests/AiryURLTests.swift`, y la prueba del conjunto exacto de herramientas en `MCPActionToolTests.swift` (se añaden los seis nombres)

**Interfaces:**
- Consumes: `MCPTool`, `MCPFormat.risk`, `AgentGate`, `OperationLog`, `AiryURLCommand` (plan 1); Tasks 1, 3, 5, 6, 7.
- Produces: `ListAppsTool`, `ExplainAppTool`, `ListOrphansTool`, `ListLargeOldTool`, `ListDuplicatesTool` (`readOnly: true, destructive: false`) y `ProposeUninstallTool` (`readOnly: false, destructive: false`). Además:
```swift
extension AiryURLCommand {
    case uninstall(bundleID: String, reason: String, agent: String?)   // airy://uninstall?bundle=<id>&reason=<r>&agent=<a>
    // bundle: ^[A-Za-z0-9][A-Za-z0-9._-]{0,199}$; reason/agent saneados como en propose
}
```

| Herramienta | Entrada | Salida (`structured`) |
|---|---|---|
| `list_apps` | `limit?` 1…500 (100), `sort?` `size`\|`name`\|`last_used` | `complete`, `apps: [{name, bundle_id, version, path, app_bytes, last_used, running, source: homebrew\|app_store\|other, can_uninstall, refusal}]` |
| `explain_app` | `bundle_id` requerido | `{…lo de list_apps, real_bytes, leftover_bytes, size_complete, shared_with, leftovers: [{kind, path, bytes, preselected, matched_by_name, reason} + MCPFormat.risk]}`; id ausente → error «No hay ninguna app instalada con ese identificador.» |
| `list_orphans` | `{}` | `decided`, `reason` (si no), `groups: [{bundle_id, paths, bytes, last_modified, risk, risk_label}]` |
| `list_large_old` | `min_bytes?` ≥ 1 000 000 (100 000 000), `older_than_months?` 0…120, `kind?` (raw de `ContentKind`), `scope?` `home`\|`everything`, `limit?` 1…200 (50) | `files: [{path, name, bytes, kind, last_modified, last_opened} + MCPFormat.risk]` del índice guardado; sin índice → «Aún no hay análisis guardado. Abre Airy o usa rescan.» |
| `list_duplicates` | `limit?` 1…200 (50) | `date`, `complete`, `groups: [{size, reclaimable_bytes, keeper, copies}]` de `duplicates.json`; sin fichero → «Aún no hay búsqueda de duplicados. Búscalos en Airy › Duplicados.» |
| `propose_uninstall` | `bundle_id` requerido, `reason` requerido (1…500), `dry_run?` | `AgentGate`. Errores: id ausente (mismo texto que `explain_app`) y `refusal` con su texto. Si no, abre `AiryURLCommand.uninstall(…, agent: client).url` (con `dry_run` devuelve la URL sin abrir) y responde `{status: "pending_user_confirmation", url, message: "Propuesta enviada a Airy; pendiente de confirmación del usuario."}`. `OperationRecord` `propose` / `pending_user` |

`list_apps` no calcula restos; `explain_app` sí. En `explain_app` y `list_large_old`, `last_opened` sale de `usage`. Nada lee contenido de archivos.

En la app, `handle(url:)` con `.uninstall`: va a la sección `.uninstaller`, espera al inventario y busca el id.
- Si no está: aviso «Un agente propuso desinstalar «\(id)», pero no está instalada.».
- Si tiene `refusal`: aviso «Un agente propuso desinstalar «\(name)», pero \(refusal minúscula inicial)».
- Si no, `flow.requestUninstall([UninstallRequest(plan:, selected: plan.defaultSelection)], warning: (aviso de agente del plan 1), proposedBy: agent)`. La confirmación del usuario se ejecuta con `.user(runID:, proposedBy: agent)`.

- [ ] **Step 1: Write the failing tests** (`makeTestEnvironment(home:)` del plan 1 con `appRoots` y apps falsas en temporal, `FakeOpener`, `FakeLookup`, `FakeQuitter`)

```swift
@Test func listAppsIsReadOnlyAndSorted() async        // sort size/name/last_used; annotations.readOnly
@Test func explainAppGivesPlanWithRisks() async       // leftovers con risk_label «Sin problema» / «Tú decides»
@Test func explainUnknownAppIsError() async
@Test func listOrphansUndecidedWhenIncomplete() async
@Test func listLargeOldFromIndex() async              // ScanResult guardado; min_bytes y older_than_months filtran
@Test func listDuplicatesWithoutReport() async
@Test func listDuplicatesNeverExposesHashes() async   // ningún hex de 64 caracteres en text ni structured
@Test func proposeUninstallOpensURLOnly() async       // opener: airy://uninstall?bundle=com.example.foo&…&agent=test-client;
                                                      // la app falsa sigue; quitter y runner sin llamadas; registro pending_user
@Test func proposeUninstallRespectsToggle() async     // agentsEnabled false, también con dry_run → isError; opener sin llamadas
@Test func proposeUninstallRejectsSystemApp() async   // com.apple.Safari en /System/Applications falso → isError con «Es parte de macOS.»
@Test func sectionToolsAcceptNoArbitraryCommands()    // ningún esquema tiene "command", "args", "paths"; "path" en ninguno
@Test func uninstallURLRoundTrip()                    // AiryURLTests
@Test func uninstallURLRejectsHostileBundleID()       // "../x", "a b", "a\nb", 201 caracteres, sin bundle → nil
```

- [ ] **Step 2: Run test to verify it fails.** Run `swift test --filter "MCPSectionToolTests|AiryURLTests"`. Expected: FAIL.
- [ ] **Step 3: Implement** según Interfaces. Se actualiza el conjunto exacto de herramientas esperado sumando `list_apps`, `explain_app`, `list_orphans`, `list_large_old`, `list_duplicates` y `propose_uninstall`.
- [ ] **Step 4: Run tests.** Run `swift test 2>&1 | tail -3`. Expected: todo en verde.
- [ ] **Step 5: Commit.** Mensaje: `feat: el MCP consulta apps, huérfanos, grandes y duplicados y propone desinstalar` (+ Co-Authored-By).

---

### Task 14: Verificación final del plan 5

**Files:** ninguno nuevo (solo arreglos que salgan de la verificación, cada uno con su prueba).

- [ ] **Step 1: Tests.** Run `swift build && swift test 2>&1 | tail -3`. Expected: todo en verde; ninguna prueba ha tocado `/Applications`, `brew`, `launchctl`, `pkgutil`, `osascript` ni la Papelera real.
- [ ] **Step 2: Funnel audit.** Run `grep -rn 'trashItem(' Sources | grep -v CleanupExecutor.swift; grep -rn 'forceTerminate\|"/bin/sh"\|"-c"' Sources/DiskMapCore/Apps Sources/DiskMapCore/Sections Sources/DiskMapCore/System/PrivilegedRunner.swift Sources/DiskMapCore/System/AppQuitter.swift`. Expected: sin salida.
- [ ] **Step 3: MCP smoke (solo lectura y dry_run).** Primero `swift build`. Después, enviar a `.build/debug/airy-mcp` con `AIRY_SUPPORT_DIR=$(mktemp -d)` estas seis líneas: `initialize`; `tools/list`; `tools/call` `list_apps` `{"limit":5}`; `explain_app` con el id de una app real de la salida anterior; `list_orphans`; y `propose_uninstall` `{"bundle_id": <ese id>, "reason":"prueba", "dry_run": true}`. Expected:
  - las seis herramientas nuevas en `tools/list`;
  - respuestas sin `isError`, salvo una negativa explicada;
  - `propose_uninstall` devuelve la URL **sin** abrir Airy;
  - ningún texto con contenido de archivos.
- [ ] **Step 4: Packaged app.** Run `bash scripts/build-app.sh && codesign --verify --strict build/Airy.app`. Expected: sin errores. **No** se instala sobre `/Applications` en esta verificación, salvo que el usuario esté presente y lo pida.
- [ ] **Step 5: Final walk-through (DEBUG).** Recorrer las cuatro secciones con los datos de prueba de Tasks 9, 11 y 12 y comprobar:
  - las tres etiquetas en las cuatro;
  - «Seleccionar todo» nunca marca rojo;
  - con «Reducir movimiento» solo hay fundidos;
  - `ps -o %cpu= -p <PID>` ≈ 0.0 tras 10 s quieto en cada sección.

  Capturas solo de ventanas propias, `kill <PID>` y borrar los datos de prueba (`~/AiryPrueba`, `~/Library/Caches/com.example.airyprueba` si quedó).
- [ ] **Step 6: Commit** (si hubo arreglos). Mensaje: `fix: verificación final de las secciones de la fase 2` (+ Co-Authored-By).
