# Airy 4 de 5 — Rendimiento · Plan de implementación

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Nueva sección **Rendimiento** que explica en lenguaje sencillo lo del Monitor de Actividad (estado general con semáforo, memoria y swap, temperatura sin grados, CPU y energía, «Lo que más pesa» con apps agrupadas y botón Cerrar, extras, elementos de inicio rotos y mantenimiento reversible), con medición en la biblioteca común para que el MCP (`get_performance`, `propose_quit_app`) mida y proponga igual aunque la app esté cerrada.

**Architecture:** Todo lo que mide, agrupa, diagnostica y cierra vive en `DiskMapCore/Performance` (sin UI, probado con muestreadores y listas de procesos falsas). El muestreo es **a petición**: `PerformanceMonitor` no tiene temporizador propio; la app lo llama cada 1,5 s solo con la sección visible y el MCP lo llama dos veces separadas 1 s por consulta. Cerrar apps tiene su propio embudo único (`QuitExecutor`: confirmación del usuario, revalidación al actuar, cierre normal primero, «Forzar cierre» solo si no respondió, registro); el mantenimiento son fichas del catálogo que se ejecutan por el embudo de borrado de siempre (`CleanupExecutor`).

**Tech Stack:** Swift 6.4 (solo Command Line Tools), SwiftPM, Swift Testing, SwiftUI + AppKit, `host_statistics64`/`host_processor_info`, `sysctl`, `libproc` (`proc_pid_rusage`, `proc_pidinfo`), `/bin/ps` (lectura), IOKit (`IOPowerSources`, `AppleSmartBattery`, `IOBlockStorageDriver`, `IOPMCopyCPUPowerStatus`), `NSRunningApplication`.

**Spec:** `docs/superpowers/specs/2026-10-20-airy-fase-2-design.md` §2.6 (Rendimiento), §2.9 «Rendimiento más completo», §2.8 (`get_performance`, `propose_quit_app`), §2.2 (animación de Rendimiento), §3–§5 (no-objetivos, anti-objetivos, APIs públicas) y «Decisiones de Claude tras la revisión del constructor» (MCP con la app cerrada). Ideas y umbrales de Mole: `docs/superpowers/research/2026-10-20-mole-inspiracion.md` §3, §3.1, §4 y filas #6, #17, #18, #20, #21 de §6. Interfaces del plan 1 (vinculantes): `docs/superpowers/plans/2026-10-20-airy-1-identidad-seguridad-mcp.md` (Tasks 3, 6, 7, 8, 9, 10, 11, 13) y sus rulings en `.superpowers/sdd/2026-10-20-airy-1-identidad-seguridad-mcp/progress.md`. Tokens y animaciones: plan 2 (`docs/superpowers/plans/2026-10-20-airy-2-marca-animaciones.md`, tabla «Interfaces públicas que consumen los planes 3–5»).

**Fuera de este plan:** grados y ventiladores (rechazado, #19), `purge` y demás placebo (#22), GPU, proxy y red por túnel; Desinstalador y demás secciones (plan 5); admin para limpiezas del sistema (plan 3).

## Global Constraints

- Swift 6.4, SwiftPM, solo Command Line Tools; `swift build` / `swift test`; `.macOS(.v15)`; el test target conserva las `unsafeFlags` del plugin de Swift Testing.
- Interfaz en **español de España**; nombres de herramientas MCP en inglés, textos de respuesta en español.
- Vistas con el alias `@ViewState` (no `@State`); **nunca** `.fixedSize(horizontal:false,vertical:true)` en `Text` multilínea (usar `.lineLimit(nil)` y ancho del contenedor); seguir `GlassCard`, `PrimaryButton`, `SectionHeader` y las interfaces públicas del plan 2 tal cual: `Theme.Airy` (incl. `swirlTint(_:)`, `riskFill`, `riskInk`), `RiskBadge(risk:compact:reason:)`, `WindSwirl(speed:tint:)`, `WindMotion.swirlRevolutionsPerSecond(cpuLoad:)`, `AnyTransition.leafAway`, `WindLeaves(mode:count:)`, `.hoverSway(_:)` y el portero `EnvironmentValues.airyAmbientMotion` / `.airyTransientMotion` (toda vista animada nueva lo lee).
- **Solo APIs públicas y estables** (§5): nada de sensores HID privados, `powermetrics`, `responsibility_get_pid_responsible_for_pid` ni SPI. Sin grados de temperatura.
- **Ligereza:** nada mide en segundo plano. La sección refresca cada **1,5 s** solo mientras está visible (sección elegida, ventana no oculta ni minimizada); al salir se para todo. El MCP mide solo cuando lo llaman. Cero CPU en reposo; respetar «Reducir movimiento» (fundidos en vez de remolino y hojas).
- **Nunca** se ofrecen para cerrar: procesos del sistema o de otros usuarios, Finder, Dock, WindowServer, loginwindow, SystemUIServer, Control Center, el propio Airy ni `airy-mcp`. Procesos sueltos del usuario (`node`, `python`, servidores locales) sí, en **ámbar** («Tú decides»).
- Cerrar = **cierre normal primero** (`terminate()` / `SIGTERM`; la app puede pedir guardar); «Forzar cierre» solo para lo que no se cerró en 10 s. Todo cierre pasa por `ConfirmSheet` → `AppModel` → `QuitExecutor` (único sitio con `terminate`/`forceTerminate`/`kill` de procesos ajenos, además de lo ya existente). Los agentes **nunca** cierran nada: `propose_quit_app` solo abre Airy con la confirmación preparada.
- **Sin botón de «liberar RAM».**
- Toda acción destructiva de mantenimiento pasa por `ConfirmSheet` → `AppModel` → `CleanupExecutor` (embudo del plan 1); el mantenimiento es siempre **ámbar**, nunca preseleccionado, reversible y explicado; el MCP nunca lo ve ni lo ejecuta.
- Elementos de inicio rotos: **solo informe** con enlace a Ajustes del Sistema; nada se borra.
- IA: «¿Por qué va lento?» envía a Claude **solo números y nombres de apps** (sin rutas, PIDs, argumentos ni carpetas de trabajo), con la invocación cerrada actual (`--tools ""`, `--setting-sources ""`…). El MCP tampoco recibe rutas ni argumentos de procesos.
- Comandos con array de argumentos, nunca cadena de shell (la única cadena AppleScript es la constante fija de reindexar Spotlight, ver Task 10).
- **Pruebas: nunca se cierra ni se mata un proceso real** (`FakeTerminator`, listas falsas); nunca se ejecutan `defaults write/delete`, `mdutil` ni `osascript` reales (`FakeRunner`); contra el sistema real solo lecturas (sondas, `ps`, `get_performance`). Verificación manual con `AIRY_SUPPORT_DIR=$(mktemp -d)`; para parar la app, `kill` de **su propio PID** (nunca `pkill -x`); capturas DEBUG solo de las ventanas propias; sin atajos DEBUG que cierren o ejecuten sin confirmación.
- Nunca se envía contenido de archivos a la IA ni al MCP; no tocar la confianza del Llavero.
- Commits terminan con `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Rulings de este plan (decisiones que el spec deja al constructor)

- **R1 — Agrupar procesos por app:** por la **ruta del bundle** (el `.app` más externo de `proc_pidpath`; Chrome Helper vive dentro de `Google Chrome.app` ⇒ cuenta como Chrome). Sin cadena de padres ni «app responsable» (SPI privada). Procesos fuera de un `.app`: en carpetas del sistema ⇒ sistema; si no ⇒ proceso suelto (con «· carpeta» de su directorio de trabajo). Limitación aceptada: los procesos `com.apple.WebKit.*` salen como sistema («Contenido web»), no dentro de Safari.
- **R2 — Procesos de otros usuarios:** libproc devuelve `EPERM` para procesos de root y de otros usuarios (comprobado en este Mac: `proc_pid_rusage` y `PROC_PIDTBSDINFO` fallan con WindowServer y `syspolicyd`). Para las reglas de familias (`syspolicyd`, WindowServer, Spotlight, CoreSimulator) y los zombis se lee `/bin/ps` (setuid, solo lectura, el mismo método que Mole) una vez por muestra. Los procesos propios usan libproc (huella de memoria, energía, E/S, carpeta de trabajo). `ps` imprime decimales con coma en es_ES: el analizador acepta `,` y `.`.
- **R3 — Núcleos P/E:** `hw.perflevel0.logicalcpu` = rendimiento, `hw.perflevel1.logicalcpu` = eficiencia; se asume que `host_processor_info` lista primero los de eficiencia (orden de Apple Silicon). Sin `perflevel1` (Intel) solo hay un grupo «Núcleos».
- **R4 — Memoria (como el Monitor de Actividad):** usada = app (internas − purgables) + cableada + comprimida; caché de archivos = externas + purgables; libre = total − usada − caché (≥ 0); **disponible** = libre + caché. «Libre < 15 %» del spec usa `disponible / total`.
- **R5 — Estrangulamiento:** `throttling = (IOPMCopyCPUPowerStatus.speedLimit < 100) || thermalState ≥ .serious`.
- **R6 — Cerrar no es borrar:** no pasa por `CleanupExecutor` (que solo mueve a la Papelera o ejecuta comandos del catálogo) sino por `QuitExecutor`, con el mismo patrón: plan → revalidar al actuar → actuar → registrar en `OperationLog` (acciones `quit_app` / `force_quit_app` / `propose_quit`).
- **R7 — Mantenimiento por el embudo:** fichas nuevas en `catalog.json` con `section: "maintenance"`; `CleanupScanner`, `Catalog.match` y el MCP las ignoran; las detecta `MaintenanceScanner` y se ejecutan como cualquier `CleanupItem` (`flow.requestClean` → `CleanupExecutor`). Reindexar Spotlight necesita administrador: comando fijo `osascript -e 'do shell script "/usr/bin/mdutil -E /" with administrator privileges'` sin ninguna parte variable (mismo enfoque que la fase 1 para rutas de administrador); solo se ofrece tras medir Spotlight lento y con el cargador conectado.
- **R8 — Proceso desbocado:** vivo ≥ 12 h y CPU media de toda su vida ≥ 25 % (tiempo de CPU / edad), como Mole.
- **R9 — VM de Docker:** memoria del grupo Docker Desktop (`com.docker.docker`) + procesos `com.apple.Virtualization.VirtualMachine` si hay grupo Docker y ninguna otra app de virtualización (UTM, Parallels, VMware, OrbStack) abierta; contenedores con `docker ps -q` (3 s; si Docker no responde, no se afirma nada).

## Review Focus

1. **El PID se reutiliza** entre la lista mostrada y el cierre (la app se cerró sola y otro proceso heredó el PID) → nunca se cierra el proceso equivocado. Test en Task 8 (`pidReuseIsRefused`).
2. **`ps` en español** (`4,4` con coma), líneas de `<defunct>`, nombres con espacios, salida vacía o `ps` que falla → se analiza bien o el diagnóstico de familias se omite sin inventar. Test en Task 3 (`parsesSpanishDecimalsAndSpaces`, `psFailureMeansNoSystemList`).
3. **Contadores que retroceden o saltan** (primera muestra, interfaz de red que cae, reposo/activación, proceso que desaparece entre muestras) → sin tasas negativas ni enormes: `nil` («—»). Test en Task 1 (`countersGoingBackwardsGiveNoRate`, `vanishedProcessHasNoCPU`).
4. **Un agente pide cerrar «Finder», «Airy», «airy-mcp», un nombre ambiguo o inexistente, o con el interruptor apagado** → error, nunca se abre la URL. Test en Task 12 (`proposeQuitRefusesNeverClosableUnknownAndToggleOff`).
5. **Rendimiento abierto antes de que termine el primer análisis del disco** o por `airy://quit` con la app cerrada → la sección funciona sin análisis y la propuesta espera a la primera muestra. Verificación manual en Task 14 (paso 5) y test en Task 13 (`boardResolvesProposalOnlyWithSnapshot`).

---

## Estructura de archivos

```
Sources/DiskMapCore/Performance/
  PerformanceModels.swift        RawSample y piezas (memoria, térmico, CPU, procesos, batería, E/S)
  PerformanceMonitor.swift       PerformanceSampling, PerformanceMonitor (deltas, historial), PerformanceSnapshot
  Probes/MemoryProbe.swift       host_statistics64, hw.memsize, vm.swapusage, kern.memorystatus_vm_pressure_level
  Probes/CPUProbe.swift          host_processor_info, hw.perflevel*, kern.boottime
  Probes/PowerProbe.swift        thermalState, IOPMCopyCPUPowerStatus, IOPowerSources, AppleSmartBattery
  Probes/IOProbe.swift           IOBlockStorageDriver «Statistics», sysctl NET_RT_IFLIST2
  Probes/ProcessProbe.swift      libproc (procesos propios), /bin/ps (todos), apps abiertas
  LiveSampler.swift              compone las sondas
  AppGrouper.swift               procesos → AppGroup (R1)
  AppCatalog.swift               explicación de una línea por app/proceso (Resources/apps.json)
  QuitPolicy.swift               qué se puede cerrar y con qué riesgo
  QuitExecutor.swift             embudo de cierre (R6)
  PerformanceDiagnosis.swift     reglas, hallazgos, semáforo y frase
  DiagnosisProbes.swift          docker ps -q, hdiutil info
  LoginItemsAudit.swift          LaunchAgents con binario inexistente
  PerformanceAIContext.swift     JSON con solo números y nombres
Sources/DiskMapCore/Maintenance/MaintenanceScanner.swift, SpotlightCheck.swift
Sources/DiskMapCore/UIState/PerformanceBoard.swift   filas y selección (lógica pura)
Sources/DiskMapCore/MCP/Tools/PerformanceTools.swift GetPerformanceTool, ProposeQuitAppTool
Sources/DiskMapCore/Resources/apps.json              (nuevo recurso)
Sources/Airy/Performance/
  PerformanceSession.swift       ciclo de muestreo (solo visible), estado observado
  PerformanceView.swift          cabecera (remolino + frase + semáforo) y disposición
  MemoryThermalCards.swift       memoria/presión/swap y temperatura
  HeavyAppsList.swift            «Lo que más pesa», CPU y energía, selección y Cerrar
  ExtrasCard.swift               batería, disco, red, encendido, zombis, núcleos P/E
  MaintenanceCard.swift          mantenimiento + elementos de inicio rotos
  SlowAISheet.swift              «¿Por qué va lento?»
Modify: Package.swift (recurso apps.json), Catalog.swift (section), CleanupScanner.swift, catalog.json,
        AIAssistant.swift, AiryURL.swift, AiryEnvironment.swift, MCPToolRegistry.standard(),
        Sources/Airy/AppModel.swift, Shell/RootView.swift, Cleanup/CleanupFlow.swift, Cleanup/ConfirmSheet.swift
Tests/DiskMapCoreTests/  PerformanceMonitorTests, ProbeTests, AppGrouperTests, QuitPolicyTests,
                         QuitExecutorTests, DiagnosisTests, LoginItemsTests, MaintenanceTests,
                         PerformanceAITests, MCPPerformanceToolTests, PerformanceBoardTests
```

---

### Task 1: Modelo de muestras y `PerformanceMonitor` (deltas, historial, a petición)

**Files:**
- Create: `Sources/DiskMapCore/Performance/PerformanceModels.swift`, `Sources/DiskMapCore/Performance/PerformanceMonitor.swift`
- Test: `Tests/DiskMapCoreTests/PerformanceMonitorTests.swift` (con `FakeSampler` que devuelve muestras guionizadas y cuenta llamadas)

**Interfaces:**
- Produces (todos `Sendable, Equatable`, `public`):
```swift
public enum MemoryPressure: String, Codable { case normal, warning, critical }   // sysctl 1 / 2 / 4
public struct MemoryStats {
    public var total, used, appMemory, wired, compressed, fileCache, free: Int64
    public var pressure: MemoryPressure?                  // nil = no se pudo leer
    public var swapUsed, swapTotal: Int64
    public var available: Int64 { free + fileCache }      // R4
    public var availableFraction: Double                  // available / total (0 si total == 0)
    public var swapFraction: Double?                      // nil si swapTotal == 0
}
public enum ThermalLevel: String, Codable, Comparable { case nominal, fair, serious, critical
    public var label: String                              // «Normal», «Caliente», «Muy caliente», «Crítico»
    public var processInfoState: ProcessInfo.ThermalState } // para Theme.Airy.swirlTint del plan 2
public struct ThermalReading { public var level: ThermalLevel; public var speedLimit: Int?; public var throttling: Bool }
public struct CoreTicks { public var user, system, idle, nice: UInt64 }
public struct CoreTopology { public var performance: Int; public var efficiency: Int }   // efficiency 0 en Intel
public struct OwnProcess {          // procesos del usuario actual (libproc)
    public var pid, ppid: Int32; public var uid: UInt32; public var name: String; public var executablePath: String?
    public var startTime: Date; public var cpuTimeNs: UInt64; public var footprint: Int64
    public var energyNj: UInt64; public var diskReadBytes, diskWriteBytes: UInt64
    public var workingDirectory: String?; public var isZombie: Bool
}
public struct SystemProcess {       // todos los usuarios (/bin/ps)
    public var pid, ppid: Int32; public var uid: UInt32; public var cpuPercent: Double; public var rssBytes: Int64
    public var state: String; public var name: String
    public var isZombie: Bool { state.hasPrefix("Z") }
}
public struct RunningAppInfo { public var pid: Int32; public var bundleID: String?; public var name: String
    public var bundlePath: String?; public enum Policy: String { case regular, accessory, prohibited }; public var policy: Policy }
public struct BatteryReading { public var percent: Int; public var isCharging: Bool; public var onACPower: Bool
    public var cycleCount: Int?; public var healthPercent: Int? }
public struct IOCounters { public var read: UInt64; public var written: UInt64 }   // disco: leídos/escritos; red: bajada/subida
public struct RawSample {
    public var date: Date; public var uptimeNs: UInt64                 // CLOCK_UPTIME_RAW
    public var memory: MemoryStats; public var thermal: ThermalReading
    public var cores: [CoreTicks]; public var topology: CoreTopology?; public var bootTime: Date?
    public var processes: [OwnProcess]; public var system: [SystemProcess]?   // nil = ps falló
    public var apps: [RunningAppInfo]; public var battery: BatteryReading?
    public var disk: IOCounters?; public var network: IOCounters?
}
public struct Rate { public var readPerSecond: Double; public var writePerSecond: Double }
public struct CPUUsage { public var total: Double; public var performance: Double?; public var efficiency: Double?; public var topology: CoreTopology? } // 0…100
public struct Zombie { public var pid: Int32; public var parentPID: Int32; public var parentName: String? }
public struct PerformanceSnapshot {
    public var date: Date; public var memory: MemoryStats; public var thermal: ThermalReading
    public var cpu: CPUUsage?                         // nil en la primera muestra
    public var processCPU: [Int32: Double]            // % por PID propio (100 = un núcleo), solo con muestra previa
    public var processEnergy: [Int32: Double]         // vatios aprox. (ΔnJ / Δt)
    public var raw: RawSample                         // la muestra cruda (procesos, apps, sistema)
    public var groups: [AppGroup]                     // los rellena Task 5 (vacío hasta entonces)
    public var battery: BatteryReading?; public var disk: Rate?; public var network: Rate?
    public var uptime: TimeInterval?; public var zombies: [Zombie]
}
public protocol PerformanceSampling: Sendable { func sample() async -> RawSample }
public actor PerformanceMonitor {
    public init(sampler: any PerformanceSampling, historyLimit: Int = 6,
                grouper: @escaping @Sendable (RawSample, [Int32: Double], [Int32: Double]) -> [AppGroup] = { _, _, _ in [] })
    public func refresh() async -> PerformanceSnapshot        // una muestra, deltas contra la anterior, añade al historial
    public var history: [PerformanceSnapshot] { get }         // más reciente al final, como mucho historyLimit
    public func reset()                                       // olvida la muestra previa (al salir de la sección)
}
```
Reglas de deltas: CPU total = Σ(user+system+nice) / Σ(todos) de las diferencias por núcleo × 100; P/E según R3. CPU por proceso = ΔcpuTimeNs / ΔuptimeNs × 100, solo si el PID y su `startTime` coinciden en ambas muestras. Tasas = Δ / Δt; **cualquier contador que retrocede, Δt ≤ 0 o falta en una de las dos muestras ⇒ `nil`**. `uptime` = `date − bootTime`. Zombis: de `system` (estado `Z`) con el nombre del padre buscado en `system`; si `system == nil`, de `processes.isZombie`.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func monitorNeverSamplesUnasked() async       // crear el monitor y esperar 0,3 s → sampler.calls == 0
@Test func firstSnapshotHasNoCPUOrRates() async     // cpu == nil, disk == nil, network == nil, processCPU vacío
@Test func cpuTotalAndClustersFromTicks() async {
    // 4 núcleos (2 E + 2 P): E ocupados 50 %, P 100 % → total 75, efficiency 50, performance 100
    #expect(s.cpu?.total == 75); #expect(s.cpu?.efficiency == 50); #expect(s.cpu?.performance == 100)
}
@Test func processCPUFromCPUTime() async            // +500 ms de CPU en 1 s de uptime → processCPU[pid] == 50
@Test func vanishedProcessHasNoCPU() async          // PID ausente o con otro startTime en la 2.ª → sin entrada
@Test func countersGoingBackwardsGiveNoRate() async // disco 10→5, red ausente en la 2.ª, uptime igual → nil, nil
@Test func ratesPerSecond() async                   // disco +2 MB en 2 s → readPerSecond == 1_048_576
@Test func memoryDerivedValues()                    // available, availableFraction, swapFraction(0 total → nil)
@Test func zombiesNameTheirParent() async           // ps: 83479 Z ppid 83371 "<defunct>", 83371 "node" → parentName "node"
@Test func historyIsBounded() async                 // 8 refresh con historyLimit 6 → history.count == 6
```

- [ ] **Step 2: Run test to verify it fails** — `swift test --filter PerformanceMonitorTests` → FAIL (tipos inexistentes).
- [ ] **Step 3: Implement** según Interfaces. `AppGroupKind` y `struct AppGroup` (campos en Task 5) se declaran ya en `PerformanceModels.swift` para que `PerformanceSnapshot` compile; Task 5 añade solo el agrupador y el catálogo.
- [ ] **Step 4: Run tests** — `swift test --filter PerformanceMonitorTests` → PASS (10).
- [ ] **Step 5: Commit** — `feat: modelo de muestras de rendimiento y monitor a petición` (+ Co-Authored-By).

---

### Task 2: Sondas del sistema: memoria, presión, swap, térmico, CPU, encendido

**Files:**
- Create: `Sources/DiskMapCore/Performance/Probes/MemoryProbe.swift`, `CPUProbe.swift`, `PowerProbe.swift` (solo la parte térmica aquí; batería en Task 4)
- Test: `Tests/DiskMapCoreTests/ProbeTests.swift`

**Interfaces:**
- Produces:
```swift
public enum MemoryProbe {
    public static func read() -> MemoryStats?          // host_statistics64(HOST_VM_INFO64) + hw.memsize + vm.swapusage + presión
    static func stats(vm: vm_statistics64, pageSize: Int64, total: Int64, swap: xsw_usage?, pressureLevel: Int32?) -> MemoryStats  // R4, pura
    static func pressure(level: Int32) -> MemoryPressure?   // 1 normal, 2 warning, 4 critical, otro nil
}
public enum CPUProbe {
    public static func ticks() -> [CoreTicks]?          // host_processor_info(PROCESSOR_CPU_LOAD_INFO); vm_deallocate del array
    public static func topology() -> CoreTopology?      // hw.perflevel0/1.logicalcpu (R3); nil si no existe perflevel0
    public static func bootTime() -> Date?              // kern.boottime
}
public enum ThermalProbe {
    public static func read() -> ThermalReading         // ProcessInfo.thermalState + IOPMCopyCPUPowerStatus (R5)
    static func reading(state: ProcessInfo.ThermalState, speedLimit: Int?) -> ThermalReading  // pura
}
```

- [ ] **Step 1: Write the failing tests**

```swift
@Test func memoryStatsFollowActivityMonitor() {
    // páginas de 16 KiB: internal 1000, purgeable 100, wire 200, compressor 300, external 400, total 4000 páginas
    // → appMemory 900 p, used 1400 p, fileCache 500 p, free 2100 p (en bytes ×16384)
}
@Test func pressureLevels()                       // 1 → .normal, 2 → .warning, 4 → .critical, 7 → nil
@Test func thermalMappingAndThrottling() {
    #expect(ThermalProbe.reading(state: .serious, speedLimit: nil).throttling)
    #expect(ThermalProbe.reading(state: .nominal, speedLimit: 80).throttling)
    #expect(!ThermalProbe.reading(state: .fair, speedLimit: 100).throttling)
    #expect(ThermalLevel.fair.label == "Caliente")
}
@Test func liveMemoryIsPlausible()                // real: total == hw.memsize > 0; used + fileCache + free == total
@Test func liveTicksMatchCoreCount()              // real: ticks().count == ProcessInfo.activeProcessorCount
@Test func liveTopologySumsToCores()              // real: si no nil, performance + efficiency == activeProcessorCount
@Test func liveBootTimeInThePast()
```

- [ ] **Step 2: Run** — `swift test --filter ProbeTests` → FAIL.
- [ ] **Step 3: Implement** según Interfaces (las funciones `read`/`ticks` llaman a las puras).
- [ ] **Step 4: Run** — `swift test --filter ProbeTests` → PASS (7).
- [ ] **Step 5: Commit** — `feat: sondas de memoria, presión, swap, estado térmico y CPU` (+ Co-Authored-By).

---

### Task 3: Sonda de procesos (libproc para los propios, `ps` para todos, apps abiertas)

**Files:**
- Create: `Sources/DiskMapCore/Performance/Probes/ProcessProbe.swift`
- Test: `Tests/DiskMapCoreTests/ProbeTests.swift` (añadir)

**Interfaces:**
- Consumes: `CommandRunning` (fase 1), tipos de Task 1.
- Produces:
```swift
public enum ProcessProbe {
    /// Procesos con el mismo uid que este proceso (incluido él mismo). PROC_PIDTBSDINFO (uid, ppid, estado, inicio),
    /// proc_pidpath, proc_pid_rusage(RUSAGE_INFO_V4) (ri_user_time + ri_system_time convertidos con mach_timebase_info,
    /// ri_phys_footprint, ri_billed_energy, ri_diskio_bytesread/written); directorio de trabajo con PROC_PIDVNODEPATHINFO
    /// solo para procesos fuera de un .app. Los que fallan (EPERM, ya terminados) se saltan.
    public static func ownProcesses() -> [OwnProcess]
    public static let psArguments = ["-Ac", "-o", "pid=,ppid=,uid=,pcpu=,rss=,state=,comm="]
    /// `/bin/ps` con psArguments, plazo 3 s; estado ≠ 0, plazo agotado o salida vacía ⇒ nil.
    public static func systemProcesses(runner: any CommandRunning) async -> [SystemProcess]?
    /// Seis campos separados por espacios y el resto de la línea es el nombre; `,` o `.` decimal; rss en KiB.
    static func parsePS(_ output: String) -> [SystemProcess]
    /// NSWorkspace.shared.runningApplications → RunningAppInfo (bundleURL.path, activationPolicy).
    public static func runningApps() -> [RunningAppInfo]
}
```

- [ ] **Step 1: Write the failing tests**

```swift
@Test func parsesSpanishDecimalsAndSpaces() {
    let out = """
      603    1    88  41,4 117504 Ss   WindowServer
    83479 83371  501   0,0      0 Z+   <defunct>
      900    1   501  12.5   2048 S    Google Chrome Helper (Renderer)
    basura
    """
    let p = ProcessProbe.parsePS(out)
    #expect(p.count == 3)
    #expect(p[0].cpuPercent == 41.4 && p[0].rssBytes == 117504 * 1024 && p[0].uid == 88)
    #expect(p[1].isZombie && p[1].ppid == 83371)
    #expect(p[2].name == "Google Chrome Helper (Renderer)" && p[2].cpuPercent == 12.5)
}
@Test func psFailureMeansNoSystemList() async      // FakeRunner: estado 1 → nil; salida vacía → nil
@Test func psUsesFixedArguments() async            // FakeRunner registra ("/bin/ps", psArguments)
@Test func ownProcessesIncludeSelfWithFootprint() {
    let me = ProcessProbe.ownProcesses().first { $0.pid == ProcessInfo.processInfo.processIdentifier }
    #expect(me != nil && me!.footprint > 0 && me!.uid == getuid())
}
@Test func ownProcessesNeverIncludeOtherUsers()    // todos con uid == getuid()
@Test func ownCPUTimeAdvances()                    // bucle ocupado 200 ms → cpuTimeNs propio sube ≥ 100 ms
@Test func runningAppsHaveNamesAndPolicies()       // real: no vacío en una sesión gráfica; si vacío (CI sin sesión) se registra y pasa
```

- [ ] **Step 2: Run** — `swift test --filter ProbeTests` → FAIL.
- [ ] **Step 3: Implement** según Interfaces.
- [ ] **Step 4: Run** — `swift test --filter ProbeTests` → PASS (14).
- [ ] **Step 5: Commit** — `feat: sonda de procesos (libproc propios, ps de lectura para el sistema)` (+ Co-Authored-By).

---

### Task 4: Sondas de batería, disco y red, y `LiveSampler`

**Files:**
- Create: `Sources/DiskMapCore/Performance/Probes/IOProbe.swift`, `Sources/DiskMapCore/Performance/LiveSampler.swift`
- Modify: `Sources/DiskMapCore/Performance/Probes/PowerProbe.swift` (batería)
- Test: `Tests/DiskMapCoreTests/ProbeTests.swift` (añadir)

**Interfaces:**
- Produces:
```swift
public enum BatteryProbe {
    /// IOPSCopyPowerSourcesInfo (capacidad, cargando, «AC Power») + registro AppleSmartBattery
    /// (CycleCount; salud = AppleRawMaxCapacity / DesignCapacity × 100, acotada 0…100). nil sin batería interna.
    public static func read() -> BatteryReading?
    static func health(rawMax: Int?, design: Int?) -> Int?
    public static func onACPower() -> Bool          // IOPSGetProvidingPowerSourceType == "AC Power"
}
public enum IOProbe {
    public static func disk() -> IOCounters?        // Σ «Statistics» de IOBlockStorageDriver: «Bytes (Read)», «Bytes (Write)»
    public static func network() -> IOCounters?     // sysctl NET_RT_IFLIST2, if_data64 ifi_ibytes/ifi_obytes
    static func countsInterface(name: String, isLoopback: Bool) -> Bool   // fuera lo*, utun*, ipsec* (el túnel ya cuenta en su portadora)
}
public struct LiveSampler: PerformanceSampling {
    public init(runner: any CommandRunning = ProcessRunner())
    public func sample() async -> RawSample          // todas las sondas; ps en paralelo con las demás
}
```

- [ ] **Step 1: Write the failing tests**

```swift
@Test func batteryHealthClamped() {
    #expect(BatteryProbe.health(rawMax: 4200, design: 5000) == 84)
    #expect(BatteryProbe.health(rawMax: 5200, design: 5000) == 100)
    #expect(BatteryProbe.health(rawMax: nil, design: 5000) == nil)
}
@Test func tunnelsAndLoopbackNotCounted()           // lo0, utun3, ipsec0 → false; en0 → true
@Test func liveDiskAndNetworkReadable()             // real: disk() != nil; network() != nil
@Test func liveSamplerFillsEverything() async {     // real: memory.total > 0, cores no vacío, processes contiene el PID propio,
    // system != nil, uptimeNs > 0; batería puede ser nil (Mac de sobremesa)
}
@Test func liveSamplerIsQuick() async               // una muestra < 1 s (ligereza)
```

- [ ] **Step 2: Run** — `swift test --filter ProbeTests` → FAIL.
- [ ] **Step 3: Implement** según Interfaces.
- [ ] **Step 4: Run** — `swift test --filter ProbeTests` → PASS (19).
- [ ] **Step 5: Commit** — `feat: batería, E/S de disco y red, y muestreador real` (+ Co-Authored-By).

---

### Task 5: Agrupar procesos por app y catálogo de explicaciones

**Files:**
- Create: `Sources/DiskMapCore/Performance/AppGrouper.swift`, `Sources/DiskMapCore/Performance/AppCatalog.swift`, `Sources/DiskMapCore/Resources/apps.json`
- Modify: `Package.swift` (`resources: [.process("Resources/catalog.json"), .process("Resources/apps.json")]`). Quien crea un `PerformanceMonitor` real (Tasks 12 y 13) le pasa `grouper: { AppGrouper.group($0, cpu: $1, energy: $2, catalog: appCatalog) }`.
- Test: `Tests/DiskMapCoreTests/AppGrouperTests.swift`

**Interfaces:**
- Produces (`AppGroupKind` y `AppGroup` viven en `PerformanceModels.swift`, declarados en Task 1):
```swift
public enum AppGroupKind: String, Sendable, Codable { case app, background, looseProcess, system }
public struct AppGroup: Sendable, Equatable, Identifiable {
    public var id: String              // bundleID ?? "bundle:" + bundlePath  |  "pid:\(pid):\(startTime epoch)"
    public var name: String            // localizedName de la app, o nombre del proceso
    public var detail: String?         // sueltos: último componente del directorio de trabajo (no se envía a IA/MCP)
    public var bundleID: String?; public var bundlePath: String?
    public var kind: AppGroupKind
    public var uid: UInt32
    public var leadPID: Int32; public var leadStart: Date; public var pids: [Int32]
    public var processNames: [String]
    public var memory: Int64           // Σ footprint
    public var cpuPercent: Double?     // Σ processCPU (nil si ninguno tiene delta)
    public var energy: Double?         // Σ processEnergy
    public var explanation: String?    // AppCatalog
    public func impact(totalMemory: Int64, logicalCores: Int) -> Double
        // memory / totalMemory + (cpuPercent ?? 0) / (100 × max(1, logicalCores))
}
public struct AppCatalogEntry: Codable, Sendable, Equatable { public var id, title, explanation: String
    public var bundleIDs: [String]; public var processNames: [String] }
public struct AppCatalog: Sendable {
    public static func bundled() throws -> AppCatalog       // misma búsqueda de bundle que Catalog.bundled()
    public init(entries: [AppCatalogEntry])
    public func entry(bundleID: String?, processName: String) -> AppCatalogEntry?   // bundle id primero; nombre sin mayúsculas
}
public enum AppGrouper {
    public static let systemPrefixes = ["/System/", "/usr/", "/sbin/", "/bin/", "/Library/Apple/", "/private/"]
    public static func outermostBundle(_ path: String?) -> String?   // "/Applications/Google Chrome.app" de un helper interno
    public static func group(_ raw: RawSample, cpu: [Int32: Double], energy: [Int32: Double], catalog: AppCatalog?) -> [AppGroup]
}
```
Algoritmo (R1): por cada `OwnProcess` no zombi: `outermostBundle` ⇒ clave del bundle; la app abierta con ese `bundlePath` da nombre, bundle id y `kind` (`.regular`/`.accessory` ⇒ `.app`; `.prohibited` o sin app abierta ⇒ `.background`; un bundle bajo `systemPrefixes` sin app regular ⇒ `.system`). El proceso cuyo PID es el de la app es el `lead` (si no hay, el de mayor memoria). Sin bundle: ruta bajo `systemPrefixes` ⇒ `.system` (agrupado por nombre); si no ⇒ `.looseProcess`, un grupo por PID con `detail` = último componente de `workingDirectory` salvo que sea `/` o el home. Orden de salida: `impact` descendente.
`apps.json` (`{"entries": [...]}`) con, como mínimo, estos ids y una explicación de una línea en español cada uno: `chrome` (`com.google.Chrome`), `safari`, `firefox`, `brave`, `edge`, `arc`, `slack`, `discord`, `teams`, `zoom`, `spotify`, `docker-desktop` (`com.docker.docker`), `vscode`, `cursor`, `xcode`, `simulator`, `figma`, `photoshop`, `premiere`, `final-cut`, `notion`, `whatsapp`, `telegram`, `claude`, `chatgpt`, `ollama`, `lm-studio`, `node` (`node`), `python` (`python`, `python3`, `Python`), `ruby`, `java`, `bun`, `deno`, `postgres`, `redis` (`redis-server`), `webkit-content` (`com.apple.WebKit.WebContent`), `windowserver`, `spotlight` (`mds`, `mds_stores`, `mdworker`, `mdworker_shared`), `syspolicyd`, `kernel-task`. Ejemplos exactos: chrome «Navegador de Google; cada pestaña y extensión es un proceso aparte, por eso suma tanto.»; node «Programa de JavaScript, normalmente un servidor o una herramienta que lanzaste en la terminal.»; docker-desktop «Docker Desktop y su máquina virtual Linux; reserva memoria aunque no haya contenedores.»

- [ ] **Step 1: Write the failing tests**

```swift
@Test func helpersCountAsTheirApp() {
    // Chrome (pid 10, /Applications/Google Chrome.app/Contents/MacOS/Google Chrome, 300 MB)
    // + helper en …/Google Chrome.app/Contents/Frameworks/…/Google Chrome Helper.app/… (pid 11, 700 MB)
    let g = AppGrouper.group(raw, cpu: [10: 5, 11: 20], energy: [:], catalog: catalog)
    #expect(g.count == 1 && g[0].name == "Google Chrome" && g[0].memory == 1_000 << 20)
    #expect(g[0].cpuPercent == 25 && g[0].leadPID == 10 && g[0].pids.sorted() == [10, 11])
    #expect(g[0].explanation?.hasPrefix("Navegador de Google") == true)
}
@Test func outermostBundleOfNestedHelper()
@Test func looseNodeShowsProjectFolder()          // /opt/homebrew/bin/node, cwd /Users/x/Proyectos/mi-api → kind .looseProcess, detail "mi-api"
@Test func looseInHomeOrRootHasNoDetail()
@Test func systemPathsAreSystem()                 // /usr/libexec/x, /System/Library/…/mds → .system
@Test func backgroundAgentIsNotAnApp()            // bundle en ~/Library/…/Helper.app con policy .prohibited → .background
@Test func zombiesAreNotGrouped()
@Test func sortedByImpact()                       // 2 GB sin CPU frente a 100 MB al 400 % en 4 núcleos → orden por impact
@Test func bundledAppCatalogHasRequiredIDs()      // los 40 ids de arriba; explicaciones no vacías y de una línea (sin "\n")
```

- [ ] **Step 2: Run** — `swift test --filter AppGrouperTests` → FAIL.
- [ ] **Step 3: Implement** según Interfaces.
- [ ] **Step 4: Run** — `swift test --filter AppGrouperTests` → PASS (9); `swift test 2>&1 | tail -3` → verde.
- [ ] **Step 5: Commit** — `feat: agrupar procesos por app y catálogo de explicaciones` (+ Co-Authored-By).

---

### Task 6: Política de cierre (`QuitPolicy`)

**Files:**
- Create: `Sources/DiskMapCore/Performance/QuitPolicy.swift`
- Test: `Tests/DiskMapCoreTests/QuitPolicyTests.swift`

**Interfaces:**
- Consumes: `AppGroup` (Task 5), `Risk`.
- Produces:
```swift
public enum QuitEligibility: Sendable, Equatable {
    case allowed(Risk)          // .safe (app normal) o .yourCall (proceso suelto); nunca .doNotTouch
    case never(String)          // motivo visible
    public var isAllowed: Bool
}
public struct QuitPolicy: Sendable {
    public static let neverBundleIDs: Set<String>   // com.apple.finder, com.apple.dock, com.apple.loginwindow,
        // com.apple.systemuiserver, com.apple.controlcenter, com.apple.notificationcenterui, com.apple.WindowManager,
        // com.apple.Spotlight, local.airy.Airy
    public static let neverProcessNames: Set<String> // Finder, Dock, WindowServer, loginwindow, SystemUIServer,
        // ControlCenter, Control Center, NotificationCenter, Airy, airy-mcp, launchd, kernel_task (comparación sin mayúsculas)
    public init(currentUID: UInt32 = getuid(), ownPIDs: Set<Int32> = [ProcessInfo.processInfo.processIdentifier])
    public func eligibility(_ group: AppGroup) -> QuitEligibility
}
```
Orden y textos exactos: PID propio, `bundlePath`/ruta con `/Airy.app/` o proceso `airy-mcp` ⇒ «Es el propio Airy.»; `uid ≠ currentUID` ⇒ «Es de otro usuario o del sistema.»; `kind == .system` ⇒ «Es parte de macOS.»; `kind == .background` ⇒ «Es un proceso de fondo; macOS lo vuelve a abrir solo.»; bundle id o algún nombre en las listas ⇒ «macOS lo necesita para funcionar.»; `.looseProcess` ⇒ `.allowed(.yourCall)`; `.app` ⇒ `.allowed(.safe)`. Aviso ámbar de sueltos (lo usa la UI): `QuitPolicy.looseWarning = "Puede que estés usándolo: un servidor o un programa que lanzaste en la terminal."`

- [ ] **Step 1: Write the failing tests**

```swift
@Test func neverClosableList() {
    for (bundle, name) in [("com.apple.finder", "Finder"), ("com.apple.dock", "Dock"), (nil, "WindowServer"),
                           ("com.apple.loginwindow", "loginwindow"), ("com.apple.systemuiserver", "SystemUIServer"),
                           ("com.apple.controlcenter", "Control Center"), ("local.airy.Airy", "Airy"), (nil, "airy-mcp")] {
        #expect(!policy.eligibility(app(bundle: bundle, name: name)).isAllowed)
    }
}
@Test func namesAreCaseInsensitive()              // "finder", "WINDOWSERVER" → never
@Test func ownPIDNeverEvenIfRenamed()             // grupo con leadPID propio y nombre "Otra" → «Es el propio Airy.»
@Test func airyMCPInsideBundleIsNever()           // ruta …/Airy.app/Contents/MacOS/airy-mcp
@Test func otherUsersAndSystemNever()             // uid 0; kind .system; kind .background
@Test func looseProcessesAreAmber()               // node, python3 → .allowed(.yourCall)
@Test func normalAppsAreGreen()                   // Spotify → .allowed(.safe)
@Test func neverWinsOverEverything()              // app regular con bundle com.apple.finder y uid propio → never
```

- [ ] **Step 2: Run** — `swift test --filter QuitPolicyTests` → FAIL.
- [ ] **Step 3: Implement** según Interfaces.
- [ ] **Step 4: Run** — `swift test --filter QuitPolicyTests` → PASS (8).
- [ ] **Step 5: Commit** — `feat: política de qué se puede cerrar desde Rendimiento` (+ Co-Authored-By).

---

### Task 7: Diagnóstico por reglas, semáforo y frase de estado general

**Files:**
- Create: `Sources/DiskMapCore/Performance/PerformanceDiagnosis.swift`, `Sources/DiskMapCore/Performance/DiagnosisProbes.swift`
- Modify: `PerformanceMonitor` (`verdict(probes:)` con caché de extras de 30 s)
- Test: `Tests/DiskMapCoreTests/DiagnosisTests.swift`

**Interfaces:**
- Consumes: `PerformanceSnapshot`, `AppGroup`, `SystemProcess`.
- Produces:
```swift
public enum HealthLevel: String, Sendable, Codable, Comparable { case good, fair, poor }   // verde, ámbar, rojo
public struct Finding: Sendable, Equatable, Identifiable { public var id: String; public var level: HealthLevel; public var sentence: String }
public struct HealthVerdict: Sendable, Equatable { public var level: HealthLevel; public var sentence: String; public var findings: [Finding] }
public struct DiagnosisExtras: Sendable, Equatable {
    public var dockerRunningContainers: Int?      // nil = no se sabe
    public var mountedDiskImages: [String]?       // nombres (último componente), nil = no se sabe
    public static let unknown = DiagnosisExtras(dockerRunningContainers: nil, mountedDiskImages: nil)
}
public enum ProcessFamily: String, CaseIterable, Sendable { case syspolicyd, windowServer, spotlight, coreSimulator
    public var processNames: [String] }   // ["syspolicyd"], ["WindowServer"], ["mds","mds_stores","mdworker","mdworker_shared","mdbulkimport"],
                                          // ["diskimagesiod","simdiskimaged","com.apple.CoreSimulator.CoreSimulatorService","launchd_sim"]
public enum PerformanceDiagnosis {
    public static let familyThreshold = 25.0, swapThreshold = 0.5, availableThreshold = 0.15
    public static let dockerVMBytes: Int64 = 2 << 30, runawayAge: TimeInterval = 12 * 3600, runawayCPU = 25.0, busyCPU = 85.0
    public static func familyCPU(_ system: [SystemProcess]) -> [ProcessFamily: Double]
    public static func dockerVMMemory(_ snapshot: PerformanceSnapshot) -> Int64?     // R9; nil sin grupo Docker
    /// `history`: más reciente al final. Las reglas «sostenidas» exigen las dos últimas muestras.
    public static func evaluate(_ history: [PerformanceSnapshot], extras: DiagnosisExtras) -> HealthVerdict
}
public struct DiagnosisProbes: Sendable {
    public init(runner: any CommandRunning)
    public func dockerRunningContainers() async -> Int?   // resolve("docker"); ["ps","-q"], 3 s; estado ≠ 0 ⇒ nil; líneas no vacías
    public func mountedDiskImages() async -> [String]?    // /usr/bin/hdiutil ["info","-plist"], 5 s; images[].image-path, sin /System ni /Library/Apple
}
extension PerformanceMonitor {
    /// Llama a docker solo si dockerVMMemory > dockerVMBytes y a hdiutil solo si syspolicyd ≥ umbral en las dos últimas; caché 30 s.
    public func verdict(probes: DiagnosisProbes?) async -> HealthVerdict
}
```
Hallazgos (id · nivel · frase exacta; `\(…)` se rellena):
- `thermal-critical` · poor · «Tu Mac está muy caliente y va mucho más lento para enfriarse.» (térmico `.critical`)
- `thermal-throttling` · fair · «Tu Mac se está calentando y ha bajado la velocidad.» (`throttling` y no crítico)
- `memory` · poor si presión `.critical`, si no fair · «Tu Mac va justo de memoria: \(A) y \(B) se llevan el \(p) %.» — A, B = los 2 grupos de más memoria, p = (memA + memB) / `memory.used` × 100 redondeado; con un solo grupo «\(A) se lleva el \(p) %»; sin grupos «Tu Mac va justo de memoria.» Se dispara con presión ≠ `.normal`, `swapFraction > 0.5` o `availableFraction < 0.15`.
- `docker-vm` · fair · «Docker Desktop retiene \(Format.bytes) sin contenedores en marcha: ciérralo si no lo usas.» (`dockerVMMemory > 2 GiB` y `dockerRunningContainers == 0`)
- `runaway:<pid>` · fair · «\(nombre) lleva \(h) h usando mucho procesador sin parar.» (R8, solo procesos propios)
- `family-syspolicyd` · fair · «La comprobación de seguridad de apps (syspolicyd) está trabajando mucho.»; si además hay imágenes montadas, `disk-images` · fair · «Hay imágenes de disco montadas (\(hasta 3 nombres, «, »)) que la hacen trabajar: expúlsalas en Finder si ya no las usas.»
- `family-windowServer` · fair · «La pantalla está trabajando mucho (WindowServer): suele ser por muchas ventanas, pantallas externas o efectos.»
- `family-spotlight` · fair · «Spotlight está indexando y usa mucho procesador; suele terminar solo.»
- `family-coreSimulator` · fair · «Los simuladores de Xcode están usando mucho procesador; ciérralos si no los usas.»
- `cpu-busy` · fair · «El procesador va al máximo: \(grupo de más CPU) es lo que más lo usa.» (`cpu.total ≥ 85` en las dos últimas)
Veredicto: nivel = el peor; frase = la del primer hallazgo en este orden de prioridad: thermal-critical, thermal-throttling, memory, docker-vm, runaway, disk-images, family-syspolicyd, family-coreSimulator, family-spotlight, family-windowServer, cpu-busy; sin hallazgos: good, «Tu Mac va bien.». `system == nil` ⇒ sin reglas de familias (no se inventan).

- [ ] **Step 1: Write the failing tests** (instantáneas falsas construidas a mano)

```swift
@Test func goodWhenNothingFires()                       // .good, "Tu Mac va bien."
@Test func familyNeedsTwoSustainedSamples() {
    // syspolicyd 30 % solo en la última → sin hallazgo; 30 % y 26 % → family-syspolicyd; 24,9 % → nada
}
@Test func spotlightFamilySumsWorkers()                 // mds_stores 15 + mdworker_shared 12 en ambas → dispara
@Test func swapAndAvailableThresholds() {
    // swap 51 % → memory; swap exactamente 50 % → nada; disponible 14 % → memory; 15 % → nada
}
@Test func memorySentenceNamesTopTwo() {
    #expect(v.sentence == "Tu Mac va justo de memoria: Google Chrome y Docker Desktop se llevan el 60 %.")
}
@Test func criticalPressureIsRed()                      // .critical → level .poor
@Test func dockerVMOnlyWithZeroContainers()             // 3 GiB y 0 → hallazgo; 3 GiB y nil → nada; 1 GiB y 0 → nada
@Test func runawayNeedsAgeAndLifetimeCPU()              // 13 h y 30 % de media → sí; 11 h → no; 13 h y 20 % → no
@Test func diskImagesOnlyWithSyspolicyd()
@Test func thermalBeatsMemoryInSentence()               // ambos → frase térmica, nivel el peor
@Test func noSystemListSkipsFamilies()                  // system nil con nombres que dispararían → ninguna family-*
@Test func probesAreCalledOnlyWhenNeeded() async        // FakeRunner: sin Docker grande ni syspolicyd → 0 llamadas; caché 30 s
@Test func dockerProbeParsesCountAndFailure() async     // "abc\ndef\n" → 2; estado 1 → nil; sin docker → nil
```

- [ ] **Step 2: Run** — `swift test --filter DiagnosisTests` → FAIL.
- [ ] **Step 3: Implement** según Interfaces.
- [ ] **Step 4: Run** — `swift test --filter DiagnosisTests` → PASS (13).
- [ ] **Step 5: Commit** — `feat: diagnóstico de rendimiento por reglas con semáforo y frase` (+ Co-Authored-By).

---

### Task 8: Embudo de cierre (`QuitExecutor`)

**Files:**
- Create: `Sources/DiskMapCore/Performance/QuitExecutor.swift`
- Test: `Tests/DiskMapCoreTests/QuitExecutorTests.swift` (con `FakeTerminator`; **ningún proceso real**)

**Interfaces:**
- Consumes: `QuitPolicy` (Task 6), `AppGroup` (Task 5), `OperationContext`, `OperationLog`, `OperationRecord` (plan 1 Tasks 7–8).
- Produces:
```swift
public protocol ProcessTerminating: Sendable {
    func requestQuit(pid: Int32, isApp: Bool) -> Bool   // app: NSRunningApplication(processIdentifier:)?.terminate(); suelto: kill(pid, SIGTERM)
    func forceQuit(pid: Int32, isApp: Bool) -> Bool     // app: forceTerminate(); suelto: kill(pid, SIGKILL)
    func isAlive(pid: Int32, startedAt: Date) -> Bool   // PROC_PIDTBSDINFO con el mismo inicio (±1 s): protege de PID reutilizado
}
public struct LiveTerminator: ProcessTerminating { public init() }
public enum QuitOutcome: Sendable, Equatable {
    case closed
    case didNotClose            // no respondió en `wait`: ahora se puede forzar
    case blocked(String)
    case failed(String)
}
public final class QuitExecutor: Sendable {
    public init(terminator: any ProcessTerminating = LiveTerminator(), policy: QuitPolicy = QuitPolicy(),
                currentGroups: @escaping @Sendable () async -> [AppGroup], log: OperationLog? = nil,
                wait: Duration = .seconds(10), poll: Duration = .milliseconds(250))
    public func quit(_ group: AppGroup, context: OperationContext) async -> QuitOutcome
    public func forceQuit(_ group: AppGroup, context: OperationContext) async -> QuitOutcome
    public func canForceQuit(_ group: AppGroup) -> Bool
}
```
Orden en `quit`: contexto de agente ⇒ `.blocked("Cerrar apps siempre lo decides tú en Airy.")`; `currentGroups()` **nuevo**: buscar el grupo con el mismo `id`, `leadPID` y `leadStart` (si no ⇒ `.blocked("Ya no está abierta.")`); `policy.eligibility` del grupo **actual** (never ⇒ `.blocked(motivo)`); `requestQuit` solo al `leadPID` (las ayudantes se cierran con su app; un suelto es un solo PID); esperar sondeando `isAlive` cada `poll` hasta `wait`: muerto ⇒ `.closed`; vivo ⇒ `.didNotClose` y se guarda `(leadPID, leadStart)` en un `Mutex<Set>` de «no responde». `forceQuit`: mismas comprobaciones y además exige `canForceQuit` (si no ⇒ `.blocked("Primero hay que intentar cerrarla normalmente.")`); `forceQuit` del lead; `.closed` o `.failed("No se pudo forzar el cierre.")`. Cada llamada añade un `OperationRecord` (`action` `quit_app`/`force_quit_app`, `itemID` = id, `title` = nombre, `paths: []`, `outcome` `closed`/`did_not_close`/`blocked`/`failed`, `bytes` = memoria del grupo, `proposedBy` del contexto).

- [ ] **Step 1: Write the failing tests**

```swift
@Test func agentContextNeverQuits() async            // .blocked; terminator.calls vacío; registro actor agente, outcome "blocked"
@Test func normalQuitFirst() async                   // FakeTerminator muere al pedirlo → .closed; calls == [.request(10, isApp: true)]
@Test func unresponsiveGivesDidNotCloseThenForce() async {
    // no muere: quit → .didNotClose (wait 0,3 s en el test); canForceQuit true; forceQuit → .closed; calls == [request, force]
}
@Test func forceWithoutPriorAttemptIsRefused() async // .blocked("Primero hay que intentar cerrarla normalmente."); sin llamadas
@Test func pidReuseIsRefused() async                 // currentGroups devuelve mismo pid con otro leadStart → .blocked("Ya no está abierta."); sin llamadas
@Test func revalidatesPolicyAtActTime() async        // el grupo actual tiene ahora bundle com.apple.finder → .blocked; sin llamadas
@Test func looseProcessUsesSignalPath() async        // kind .looseProcess → request(pid, isApp: false)
@Test func everyAttemptIsLogged() async              // closed, did_not_close, blocked → 3 registros con action y outcome correctos
@Test func quitCallsOnlyInQuitExecutor() throws {    // fuente: "forceTerminate(" y "kill(" con SIGTERM/SIGKILL solo en
    // QuitExecutor.swift (y los "terminate(" ya existentes de CleanupFlow.swift y CommandRunner.swift)
}
```

- [ ] **Step 2: Run** — `swift test --filter QuitExecutorTests` → FAIL.
- [ ] **Step 3: Implement** según Interfaces.
- [ ] **Step 4: Run** — `swift test --filter QuitExecutorTests` → PASS (9).
- [ ] **Step 5: Commit** — `feat: embudo de cierre de apps con cierre normal primero` (+ Co-Authored-By).

---

### Task 9: Elementos de inicio rotos (solo informe)

**Files:**
- Create: `Sources/DiskMapCore/Performance/LoginItemsAudit.swift`
- Test: `Tests/DiskMapCoreTests/LoginItemsTests.swift` (carpetas temporales con plists)

**Interfaces:**
- Produces:
```swift
public struct BrokenLoginItem: Sendable, Equatable, Identifiable {
    public var id: String { plistPath }
    public var label: String; public var plistPath: String; public var missingProgram: String
}
public enum LoginItemsAudit {
    public static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!
    public static func standardDirectories(home: String = NSHomeDirectory()) -> [String]   // ~/Library/LaunchAgents, /Library/LaunchAgents
    /// Lee cada *.plist (≤ 1 MB) con PropertyListSerialization; programa = Program ?? ProgramArguments[0];
    /// solo rutas absolutas; si está bajo /Volumes/<X> y /Volumes/<X> no existe (disco desmontado) no cuenta;
    /// roto si el programa no existe. Plists ilegibles se saltan. Etiqueta = Label ?? nombre del fichero sin extensión.
    public static func broken(in directories: [String], fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> [BrokenLoginItem]
}
```

- [ ] **Step 1: Write the failing tests**

```swift
@Test func reportsMissingProgram()               // Program /nope/x → 1 elemento con label y missingProgram "/nope/x"
@Test func usesFirstProgramArgument()            // ProgramArguments ["/nope/y", "--flag"]
@Test func existingProgramIsFine()               // /bin/ls → nada
@Test func relativeProgramIgnored()              // "node" → nada
@Test func unmountedVolumeIgnored()              // /Volumes/NoExiste/app → nada
@Test func unreadablePlistSkipped()              // bytes basura → nada, sin fallo
@Test func auditNeverDeletes() throws            // el directorio queda idéntico (nombres y bytes) tras broken(in:)
```

- [ ] **Step 2: Run** — `swift test --filter LoginItemsTests` → FAIL.
- [ ] **Step 3: Implement** según Interfaces.
- [ ] **Step 4: Run** — `swift test --filter LoginItemsTests` → PASS (7).
- [ ] **Step 5: Commit** — `feat: informe de elementos de inicio rotos` (+ Co-Authored-By).

---

### Task 10: Mantenimiento reversible en ámbar (fichas del catálogo + `MaintenanceScanner` + Spotlight)

**Files:**
- Create: `Sources/DiskMapCore/Maintenance/MaintenanceScanner.swift`, `Sources/DiskMapCore/Maintenance/SpotlightCheck.swift`
- Modify: `Sources/DiskMapCore/Catalog/Catalog.swift` (`CatalogEntry.section`, `Catalog.match` las salta), `Sources/DiskMapCore/Cleanup/CleanupScanner.swift` (las salta), `Sources/DiskMapCore/Resources/catalog.json` (8 fichas)
- Test: `Tests/DiskMapCoreTests/MaintenanceTests.swift`

**Interfaces:**
- Consumes: `CatalogEntry`, `CleanupItem`, `RiskClassifier`, `CommandRunning`, `CleanupExecutor.preview/execute` (plan 1 Task 8).
- Produces:
```swift
public enum CatalogSection: String, Codable, Sendable { case cleanup, maintenance }
// CatalogEntry gana `public var section: CatalogSection` (decodifica por defecto .cleanup; se codifica solo si es .maintenance;
// parámetro `section: CatalogSection = .cleanup` al final del init)
public enum SpotlightDiagnosis: Sendable, Equatable { case fine(seconds: Double), slow(seconds: Double), disabled, unknown }
public struct SpotlightCheck: Sendable {
    public static let slowSeconds = 3.0
    public init(runner: any CommandRunning)
    /// /usr/bin/mdutil ["-s", "/"] (5 s): «disabled» ⇒ .disabled. Luego dos veces
    /// /usr/bin/mdfind ["kMDItemFSName == 'Applications'"] (10 s cada una): ambas > 3 s (o plazo agotado) ⇒ .slow(máx);
    /// si no ⇒ .fine(máx); fallo de ejecución ⇒ .unknown. Lo lanza el usuario con un botón, nunca solo.
    public func run() async -> SpotlightDiagnosis
}
public struct MaintenanceScanner: Sendable {
    public init(catalog: Catalog, runner: any CommandRunning, home: String, classifier: RiskClassifier?)
    /// Solo fichas `section == .maintenance` cuya condición se cumple; riesgo del clasificador (nunca menos que ámbar), preselected false.
    public func findItems(spotlight: SpotlightDiagnosis?, onACPower: Bool) async -> [CleanupItem]
}
```
Fichas de `catalog.json` (todas `risk: "yourCall"`, `kind: "system"`, `regenerates: false`, `section: "maintenance"`, sin `aggressiveRisk` ni preselección; `explanation` dice qué hace y **cómo deshacerlo**):

| id | `cleanup` | Se ofrece si (lecturas con `FakeRunner` en pruebas) |
|---|---|---|
| `maintenance-dsstore-network` | command `defaults` `["write","com.apple.desktopservices","DSDontWriteNetworkStores","-bool","true"]` | `defaults read com.apple.desktopservices DSDontWriteNetworkStores` ≠ `1` |
| `maintenance-dsstore-usb` | ídem con `DSDontWriteUSBStores` | ídem |
| `maintenance-legacy-appnap` | `defaults` `["delete","-g","NSAppSleepDisabled"]` | `defaults read -g NSAppSleepDisabled` == `1` |
| `maintenance-legacy-skipverify` | `defaults` `["delete","com.apple.frameworks.diskimages","skip-verify"]` | read == `1` |
| `maintenance-legacy-skipverify-locked` | ídem `skip-verify-locked` | read == `1` |
| `maintenance-legacy-skipverify-remote` | ídem `skip-verify-remote` | read == `1` |
| `maintenance-corrupt-plist` | `trash`, `paths: ["~/Library/Preferences/*.plist"]` | por fichero: nombre sin prefijo `com.apple.`, ≤ 10 MB, `PropertyListSerialization` falla; id `maintenance-corrupt-plist:<nombre>` |
| `maintenance-spotlight-reindex` | command `osascript` `["-e","do shell script \"/usr/bin/mdutil -E /\" with administrator privileges"]` | `spotlight == .slow` **y** `onACPower` |

Ejemplos de texto exactos: dsstore-network título «No crear archivos .DS_Store en discos de red», explicación «Evita que Finder deje archivos ocultos .DS_Store en carpetas compartidas. Se deshace con: defaults delete com.apple.desktopservices DSDontWriteNetworkStores.»; corrupt-plist título «Preferencias dañadas», explicación «Este archivo de ajustes de una app está dañado y puede impedir que arranque. Va a la Papelera y la app crea uno nuevo; si algo falla, sácalo de la Papelera.»; spotlight-reindex título «Reindexar Spotlight», explicación «Spotlight tarda en buscar. Reindexar lo rehace desde cero: pedirá la contraseña de administrador y durante 1–2 horas el Mac irá algo más cargado.»

- [ ] **Step 1: Write the failing tests**

```swift
@Test func maintenanceEntriesAreAmberAndNeverPreselected() throws   // catálogo real: las 8, yourCall, section .maintenance
@Test func cleanupScannerIgnoresMaintenance() async                 // findItems de Limpieza nunca devuelve ids "maintenance-*"
@Test func catalogMatchIgnoresMaintenance() throws                  // match(home/Library/Preferences/x.plist) no es maintenance-corrupt-plist
@Test func dsStoreOfferedOnlyWhenNotSet() async                     // read → "1" ⇒ no; estado 1 (clave ausente) ⇒ sí
@Test func legacyDefaultsOfferedOnlyWhenHarmful() async             // "1" ⇒ sí; "0" o ausente ⇒ no
@Test func corruptPlistDetectedButAppleAndValidSkipped() async      // tmp home: bad.plist basura ⇒ item; com.apple.bad.plist ⇒ no; ok.plist ⇒ no
@Test func spotlightOnlyAfterSlowDiagnosisOnAC() async              // nil / .fine / .slow sin AC ⇒ no; .slow + AC ⇒ sí
@Test func spotlightCheckTiming() async                             // FakeRunner con retardos 3,5 s y 4 s ⇒ .slow; 0,1 s ⇒ .fine; "disabled" ⇒ .disabled
@Test func scannerOnlyReads() async                                 // runner.calls solo contiene "read", "-s" o consultas mdfind; nunca write/delete/osascript
@Test func maintenanceExecutesThroughFunnel() async {               // CleanupExecutor con FakeRunner: execute(item dsstore) ⇒
    // runner llamado con ("/usr/bin/defaults", ["write", …, "-bool", "true"]); registro en OperationLog
    // execute(item corrupt-plist) ⇒ el fichero temporal va a la Papelera (embudo del plan 1); preview no ejecuta nada
}
@Test func agentCannotRunMaintenance() async                        // contexto .agent ⇒ .blocked (ámbar); runner sin llamadas
```

- [ ] **Step 2: Run** — `swift test --filter MaintenanceTests` → FAIL.
- [ ] **Step 3: Implement** según Interfaces.
- [ ] **Step 4: Run** — `swift test 2>&1 | tail -3` → todo verde (las pruebas de catálogo y Limpieza existentes siguen pasando).
- [ ] **Step 5: Commit** — `feat: mantenimiento reversible en ámbar por el embudo de limpieza` (+ Co-Authored-By).

---

### Task 11: IA «¿Por qué va lento?» (solo números y nombres)

**Files:**
- Create: `Sources/DiskMapCore/Performance/PerformanceAIContext.swift`
- Modify: `Sources/DiskMapCore/AI/AIAssistant.swift` (extraer el bucle de streaming de `chat` a un `private func streamResponse(arguments:prompt:)` reutilizado; añadir `explainSlowness`)
- Test: `Tests/DiskMapCoreTests/PerformanceAITests.swift` (con `AIFakeRunner` de `AITests.swift`)

**Interfaces:**
- Produces:
```swift
public enum PerformanceAIContext {
    /// JSON con claves ordenadas: memory {total_gb, used_gb, file_cache_gb, pressure, swap_used_gb, swap_total_gb},
    /// thermal {state, throttling}, cpu {total_percent}, apps [{name, memory_mb, cpu_percent, processes}] (10 de más impacto,
    /// `name` = AppGroup.name; nunca detail, bundlePath, bundleID, pids ni rutas), findings [frase].
    public static func build(_ snapshot: PerformanceSnapshot, verdict: HealthVerdict) -> String
}
extension AIAssistant {
    static let performanceSystemPrompt: String
    public func explainSlowness(context: String) -> AsyncThrowingStream<String, Error>
}
```
`performanceSystemPrompt` (exacto): «Eres el asistente de Airy, una app de macOS. Solo ves números de memoria, procesador y temperatura y los nombres de las apps abiertas, nunca archivos ni contenido. Explica en español de España, en pocas frases sencillas, por qué este Mac puede ir lento y qué apps convendría cerrar. No recomiendes «liberar RAM», `purge` ni cerrar procesos del sistema, y no puedes hacer nada tú mismo: el usuario cierra las apps desde Rendimiento.» Argumentos = `arguments(systemPrompt:)` + `["--output-format","stream-json","--verbose","--include-partial-messages"]`; prompt: «Estado del Mac (JSON, solo números y nombres de apps):\n\(context)\n\n¿Por qué puede ir lento y qué haría?».

- [ ] **Step 1: Write the failing tests**

```swift
@Test func contextHasOnlyNumbersAndNames() {
    // grupo node con detail "proyecto-secreto", bundlePath "/Applications/X.app", pid 4242
    let json = PerformanceAIContext.build(snapshot, verdict: verdict)
    #expect(!json.contains("/") && !json.contains("proyecto-secreto") && !json.contains("4242"))
    #expect(json.contains("\"name\":\"node\""))
}
@Test func contextLimitsToTenApps()
@Test func explainSlownessUsesClosedInvocation() async {
    // AIFakeRunner: argumentos contienen "--tools", "", "--setting-sources", "", "--strict-mcp-config" y el prompt de rendimiento;
    // stdin contiene el contexto; el texto del stream llega entero
}
@Test func chatStillWorksAfterRefactor() async      // la prueba de chat existente en AITests sigue pasando (ejecutar el suite)
```

- [ ] **Step 2: Run** — `swift test --filter PerformanceAITests` → FAIL.
- [ ] **Step 3: Implement** según Interfaces.
- [ ] **Step 4: Run** — `swift test --filter "PerformanceAITests|AITests"` → PASS.
- [ ] **Step 5: Commit** — `feat: «¿Por qué va lento?» con la invocación cerrada de Claude` (+ Co-Authored-By).

---

### Task 12: MCP `get_performance` y `propose_quit_app` (+ `airy://quit`)

**Files:**
- Create: `Sources/DiskMapCore/MCP/Tools/PerformanceTools.swift`
- Modify: `Sources/DiskMapCore/Integration/AiryURL.swift` (caso `proposeQuit`), `Sources/DiskMapCore/MCP/AiryEnvironment.swift` (campo `sampler`), `MCPToolRegistry.standard()` (11 herramientas), `Tests/DiskMapCoreTests/MCPActionToolTests.swift` (`registryHasExactlyNineToolsAndNoArbitraryInput` pasa a `…ElevenTools…` con los dos nombres nuevos), `Tests/DiskMapCoreTests/AiryURLTests.swift`
- Test: `Tests/DiskMapCoreTests/MCPPerformanceToolTests.swift`

**Interfaces:**
- Consumes: `MCPTool`, `MCPToolResult`, `MCPCallContext`, `AiryEnvironment`, `AgentGate.refusal`, `URLOpening`, `AiryURLCommand` (plan 1 Tasks 10–13); `PerformanceMonitor.measureOnce`, `verdict`, `AppGrouper`, `QuitPolicy`, `DiagnosisProbes`.
- Produces:
```swift
// AiryURLCommand gana:
case proposeQuit(app: String, reason: String, agent: String?)
// forma airy://quit?app=<a>&reason=<r>&agent=<g>; app: 1…maxItemID (200), sin caracteres de control; reason/agent saneados como en propose
// AiryEnvironment gana `public let sampler: any PerformanceSampling` y `public let appCatalog: AppCatalog?`
// (parámetros `sampler: any PerformanceSampling = LiveSampler(), appCatalog: AppCatalog? = try? AppCatalog.bundled()`
// al final del init memberwise; live() pasa LiveSampler(runner: runner))
public struct GetPerformanceTool: MCPTool { public init(interval: Duration = .seconds(1)) }       // "get_performance"
public struct ProposeQuitAppTool: MCPTool { public init() }                                       // "propose_quit_app"
```

| Herramienta | Entrada | Comportamiento y salida (`structured`) |
|---|---|---|
| `get_performance` | `{}` | Solo lectura (`readOnly: true, destructive: false, idempotent: true`), sin `AgentGate`; funciona con la app cerrada: `PerformanceMonitor(sampler: env.sampler, grouper: AppGrouper…)`, `refresh()`, espera `interval`, `refresh()` y `verdict(probes: DiagnosisProbes(runner: env.runner))` (solo mide durante la llamada). Salida: `health {level: good\|fair\|poor, light: green\|amber\|red, sentence}`, `findings [{id, sentence}]`, `memory {total_bytes, used_bytes, free_bytes, file_cache_bytes, available_bytes, pressure: normal\|warning\|critical\|null, swap_used_bytes, swap_total_bytes}`, `thermal {state, label, throttling}`, `cpu {total_percent, performance_percent, efficiency_percent, performance_cores, efficiency_cores}`, `top_by_memory` y `top_by_cpu` (5 cada uno) `[{name, bundle_id, memory_bytes, cpu_percent, process_count, closable, risk}]` (`closable` = `QuitPolicy.eligibility.isAllowed`, `risk` = `safe\|yourCall\|null`), `battery {percent, charging, cycle_count, health_percent} \| null`, `uptime_seconds`, `zombie_count`. Texto: la frase de salud. Nunca rutas, PIDs, argumentos ni `detail`. |
| `propose_quit_app` | `app` requerido (string 1…200), `reason?` (≤ 500), `dry_run?` (false) | `AgentGate` primero (apagado o ilegible ⇒ su error, nada abierto). Una muestra y `AppGrouper.group`; coincidencia exacta sin mayúsculas con `bundleID` o `name` (varias ⇒ la de más memoria); sin coincidencia ⇒ error «No hay ninguna app abierta llamada «\(app)».»; `never(m)` ⇒ error ««\(nombre)» no se puede cerrar desde Airy: \(m)». Si no, URL `AiryURLCommand.proposeQuit(app: bundleID ?? name, reason:, agent: client).url`; `dry_run` la devuelve sin abrirla; abrir falla ⇒ «No se pudo abrir Airy (¿está instalada en /Applications?).». Salida `{status: "pending_user_confirmation", app, risk, url, message: "Propuesta enviada a Airy; el usuario decide si la cierra. Airy nunca cierra apps por su cuenta."}`. Registro `OperationRecord` actor agente, `action "propose_quit"`, `outcome "pending_user"` (o `blocked`). Anotaciones `readOnly: false, destructive: false`. |

Descripciones (español) de las herramientas: `get_performance` «Estado del Mac ahora: memoria, presión, swap, temperatura (sin grados), procesador y las apps que más pesan, con una frase de diagnóstico. Solo lectura; mide durante 1 s.»; `propose_quit_app` «Propone al usuario cerrar una app abierta: abre Airy con la confirmación preparada. Nunca cierra nada; el usuario decide en la app.»

- [ ] **Step 1: Write the failing tests** (`FakeSampler` con dos muestras, `FakeOpener`, entorno temporal de plan 1 `makeTestEnvironment(home:)` con `sampler:`)

```swift
@Test func getPerformanceSamplesItselfAndReportsHealth() async   // calls == 2; health.sentence == verdict; memory.total_bytes correcto
@Test func getPerformanceNeverLeaksPathsOrArgs() async           // detail "proyecto-secreto", rutas y pid ausentes del texto y del JSON
@Test func getPerformanceMarksNeverClosable() async              // Finder closable false; Spotify true risk "safe"; node risk "yourCall"
@Test func getPerformanceWorksWithToggleOff() async              // agentsEnabled false ⇒ sigue respondiendo (solo lectura)
@Test func proposeQuitOpensURLAndNeverQuits() async {
    #expect(opener.urls == [URL(string: "airy://quit?app=com.spotify.client&reason=pesa&agent=test-client")!])
    // FakeTerminator no se usa en ningún camino de la herramienta; registro "propose_quit" / "pending_user"
}
@Test func proposeQuitRefusesNeverClosableUnknownAndToggleOff() async {
    // "Finder", "airy-mcp", "Airy", "NoExiste", interruptor apagado, ajustes ilegibles ⇒ isError y opener.urls vacío
}
@Test func proposeQuitDryRunDoesNotOpen() async
@Test func proposeQuitPicksBiggestOnAmbiguousName() async
@Test func quitURLRoundTripsAndRejectsHostile() {                 // en AiryURLTests: ida y vuelta; app vacía, con "\n" o de 201 ⇒ nil
}
@Test func registryHasExactlyElevenToolsAndNoArbitraryInput()     // + "get_performance", "propose_quit_app"; "app" solo en propose_quit_app
```

- [ ] **Step 2: Run** — `swift test --filter "MCPPerformanceToolTests|AiryURLTests|MCPActionToolTests"` → FAIL.
- [ ] **Step 3: Implement** según Interfaces.
- [ ] **Step 4: Verify** — `swift test 2>&1 | tail -3` → verde. Contra el sistema real, solo lectura: `swift build && printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"prueba","version":"1"}}}' '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"get_performance","arguments":{}}}' | AIRY_SUPPORT_DIR=$(mktemp -d) .build/debug/airy-mcp` → dos líneas JSON; la segunda con `health.sentence` y `memory.total_bytes > 0`. **No** llamar a `propose_quit_app` sin `dry_run: true` contra el sistema real.
- [ ] **Step 5: Commit** — `feat: herramientas MCP get_performance y propose_quit_app` (+ Co-Authored-By).

---

### Task 13: Sección Rendimiento: muestreo solo visible, tablero y tarjetas

**Files:**
- Create: `Sources/DiskMapCore/UIState/PerformanceBoard.swift`; `Sources/Airy/Performance/PerformanceSession.swift`, `PerformanceView.swift`, `MemoryThermalCards.swift`, `HeavyAppsList.swift`, `ExtrasCard.swift`
- Modify: `Sources/Airy/AppModel.swift` (`Section.performance` disponible entre Limpieza y Asistente IA: título «Rendimiento», símbolo `gauge.with.dots.needle.67percent`; `let performance = PerformanceSession()`), `Sources/Airy/Shell/RootView.swift` (Rendimiento se muestra aunque no haya análisis del disco ni error de análisis: el `hero` de progreso y `ScanErrorView` solo cubren las secciones que dependen del disco)
- Test: `Tests/DiskMapCoreTests/PerformanceBoardTests.swift`

**Interfaces:**
- Consumes: Tasks 1–7.
- Produces:
```swift
// core
public struct PerformanceRow: Sendable, Equatable, Identifiable {
    public var group: AppGroup; public var eligibility: QuitEligibility; public var id: String { group.id }
}
public struct PerformanceBoard: Sendable, Equatable {
    public init(snapshot: PerformanceSnapshot?, policy: QuitPolicy, limit: Int = 12)
    public var rows: [PerformanceRow]            // .app, .looseProcess y .background por impact desc, hasta limit; .system nunca
    public var topByCPU: [AppGroup]              // 5, cpuPercent desc (sin nil)
    public var topByEnergy: [AppGroup]           // 5, energy desc (sin nil)
    public static func canSelect(_ row: PerformanceRow) -> Bool          // eligibility.isAllowed
    public func selected(_ ids: Set<String>) -> [PerformanceRow]          // solo filas que siguen existiendo y canSelect
    /// Propuesta de agente: fila por bundle id o nombre (sin mayúsculas); nil sin instantánea o sin coincidencia.
    public func row(matching app: String) -> PerformanceRow?
}
// app
@MainActor @Observable final class PerformanceSession {
    static let interval: Duration = .milliseconds(1500)
    private(set) var snapshot: PerformanceSnapshot?
    private(set) var verdict: HealthVerdict?
    private(set) var board: PerformanceBoard
    var selection: Set<String>
    private(set) var unresponsive: Set<String>       // ids con .didNotClose
    private(set) var leaving: Set<String>            // ids que salen volando (animación)
    private(set) var loginItems: [BrokenLoginItem]
    private(set) var maintenance: [CleanupItem]
    private(set) var spotlight: SpotlightDiagnosis?
    let monitor: PerformanceMonitor                   // LiveSampler + AppGrouper.group con AppCatalog.bundled()
    func start()        // idempotente: un único Task { while !cancelled { refresh; verdict; sleep(interval) } }
    func stop()         // cancela el Task y monitor.reset(); ninguna medición después
    func firstSnapshot() async -> PerformanceSnapshot   // espera a la primera (para airy://quit)
}
```
Ciclo de vida (ligereza): `PerformanceView` llama a `start()` en `onAppear` y `stop()` en `onDisappear`; además escucha `NSWindow.didChangeOcclusionStateNotification`, `didMiniaturizeNotification`/`didDeminiaturizeNotification` y `NSApplication.didHideNotification`/`didUnhideNotification` de su ventana: no visible ⇒ `stop()`, visible otra vez ⇒ `start()`. Elementos de inicio y mantenimiento se leen al aparecer y tras cada acción (no en cada muestra).
Contenido (textos exactos):
- Cabecera: `WindSwirl(speed: WindMotion.swirlRevolutionsPerSecond(cpuLoad: (snapshot.cpu?.total ?? 0) / 100), tint: Theme.Airy.swirlTint(snapshot.thermal.level.processInfoState))` (plan 2: más rápido con más CPU, del azul al naranja con el Mac caliente; con «Reducir movimiento» queda quieto y el tinte funde; se pausa solo con `airyAmbientMotion`), la frase del veredicto en grande y un semáforo (`Theme.Airy.riskFill(.safe/.yourCall/.doNotTouch)` = verde «Va bien», ámbar «Atención», rojo «Problema»); debajo, los demás hallazgos en lista corta.
- Memoria: barra usada / caché de archivos / libre con cifras; «Presión de memoria» con píldora Normal (verde) / Alta (ámbar) / Crítica (rojo) / «—»; «Swap: \(usada) de \(total)». Textos de ayuda: presión «La presión de memoria dice si a macOS le cuesta encontrar memoria libre. En verde va sobrado; en ámbar empieza a comprimir y a usar el disco; en rojo, las apps irán lentas.»; swap «La swap es memoria que macOS guarda temporalmente en el disco cuando no cabe todo en la RAM. Crece cuando abres muchas cosas a la vez y no baja sola hasta que cierras apps o reinicias; un poco es normal, mucha hace que todo vaya más lento.»; caché «Archivos que macOS guarda en memoria para abrirlos antes; la suelta en cuanto otra app la necesita.»; pie «Airy no tiene botón de «liberar RAM»: macOS ya gestiona la memoria y esos botones no ayudan. Lo que alivia de verdad es cerrar lo que más consume.»
- Temperatura: «Temperatura: \(label)» y «macOS ha bajado la velocidad para enfriarlo.» / «Sin reducción de velocidad.»; ayuda «Airy no muestra grados: leerlos exige interfaces privadas de Apple que pueden romperse.»
- CPU y energía: total y P/E, `topByCPU` y `topByEnergy` (barras relativas, sin vatios).
- «Lo que más pesa»: filas de `board.rows` con icono de la app, nombre (+ «· \(detail)» en sueltos), explicación del catálogo, memoria, CPU, nº de procesos («Chrome · 23 procesos»), `RiskBadge(risk:)` (verde app / ámbar suelto con `QuitPolicy.looseWarning`), casilla y botón «Cerrar» solo si `canSelect`; las de `never` muestran el motivo y ningún control. Barra de selección: «Cerrar seleccionadas (n)». Fila en `unresponsive`: «No responde» + botón «Forzar cierre…».
- Extras: batería «\(percent) % · \(ciclos) ciclos · salud \(health) %» (o «Sin batería»); «Disco: lee \(x)/s · escribe \(y)/s»; «Red: baja \(x)/s · sube \(y)/s»; «Encendido desde hace \(…)»; zombis «Procesos zombi: \(n)» con los padres y ayuda «Procesos ya terminados que su programa no ha recogido; no gastan recursos, pero muchos indican un programa con fallos.»; «—» para cualquier `nil`.

- [ ] **Step 1: Write the failing tests** (core)

```swift
@Test func rowsSortedAndLimited()                     // 15 grupos → 12 filas por impact; .system nunca aparece en rows
@Test func neverRowsHaveNoCheckbox()                  // Finder: canSelect false; selected(["finder-id"]) vacío
@Test func selectionDropsVanishedRows()               // ids de un grupo que ya no está → fuera
@Test func topByCPUSkipsUnknown()                     // cpuPercent nil no entra
@Test func boardResolvesProposalOnlyWithSnapshot()    // snapshot nil → row(matching:) nil; con snapshot → por bundle id y por nombre
@Test func thermalLevelMapsToProcessInfo()             // .serious.processInfoState == .serious (los cuatro)
```

- [ ] **Step 2: Run** — `swift test --filter PerformanceBoardTests` → FAIL.
- [ ] **Step 3: Implement** el tablero (core) y luego la sesión y las vistas según Interfaces.
- [ ] **Step 4: Verify** — `swift build && swift test 2>&1 | tail -3` → verde. Manual: `AIRY_SUPPORT_DIR=$(mktemp -d) .build/debug/Airy &` (guardar `$!`): elegir Rendimiento **mientras aún analiza el disco** ⇒ la sección aparece y las cifras cambian cada ~1,5 s; ir a Mapa y en Monitor de Actividad comprobar que el %CPU de Airy vuelve a ~0; minimizar la ventana con Rendimiento abierto ⇒ ~0 %; Finder/Dock salen sin casilla ni «Cerrar». Parar con `kill <PID>`.
- [ ] **Step 5: Commit** — `feat: sección Rendimiento con muestreo solo visible` (+ Co-Authored-By).

---

### Task 14: Cerrar desde la app, propuestas `airy://quit`, mantenimiento, inicio, IA y animaciones

**Files:**
- Create: `Sources/Airy/Performance/MaintenanceCard.swift`, `Sources/Airy/Performance/SlowAISheet.swift`
- Modify: `Sources/Airy/Cleanup/CleanupFlow.swift` (`Kind.quitApps([AppGroup])`, `Kind.forceQuitApps([AppGroup])`, `requestQuit`, `requestForceQuit`, ejecución en secuencia), `Sources/Airy/Cleanup/ConfirmSheet.swift` (las dos variantes), `Sources/Airy/AppModel.swift` (`quitExecutor`, `quit`, `forceQuit`, `handle(url:)` para `.proposeQuit`, `Notice.Kind.performance`), `Sources/Airy/Performance/HeavyAppsList.swift` (hojas al salir), `Sources/Airy/Performance/PerformanceView.swift`

**Interfaces:**
- Consumes: Tasks 6, 8, 9, 10, 11, 13; `CleanupFlow.ConfirmRequest.Warning`, `requestClean` y `perform(_:context:)` (plan 1 Tasks 9–10).
- Produces (app):
```swift
// CleanupFlow
func requestQuit(_ groups: [AppGroup], warning: ConfirmRequest.Warning? = nil, proposedBy: String? = nil)
func requestForceQuit(_ groups: [AppGroup])
// AppModel
let quitExecutor: QuitExecutor      // currentGroups: { await performance.monitor.refresh().groups }, log: operationLog
func quit(_ group: AppGroup, context: OperationContext) async -> QuitOutcome
func forceQuit(_ group: AppGroup, context: OperationContext) async -> QuitOutcome
// PerformanceSession
func markClosed(_ id: String)       // añade a leaving (anima) y lo quita de selection
func markUnresponsive(_ id: String)
func refreshMaintenance() async     // MaintenanceScanner + LoginItemsAudit
func checkSpotlight() async         // SpotlightCheck.run() y refreshMaintenance
```
Confirmación de cierre (textos exactos): título «¿Cerrar \(nombre)?» o «¿Cerrar \(n) apps?»; filas con nombre, memoria y nº de procesos; las ámbar en bloque aparte con cabecera «Revisa: puede que estés usándolo» y `QuitPolicy.looseWarning`; nota «Primero se pide a cada app que se cierre; si tiene algo sin guardar, te lo preguntará.»; botón «Cerrar». Forzar: título «¿Forzar el cierre de \(nombre)?», nota «No respondió al cierre normal. Se perderá lo que no esté guardado.», botón «Forzar cierre» (rol destructivo; Intro no confirma). Al confirmar: secuencia con `.user(runID: lote, proposedBy:)`; `.closed` ⇒ `markClosed` (la fila sale de la lista con `.transition(.leafAway)` del plan 2: vuela como una hoja y se deshace en hojas; con «Reducir movimiento» el propio plan 2 lo cambia por un fundido); `.didNotClose` ⇒ `markUnresponsive`; `.blocked`/`.failed` ⇒ mensaje en la fila. Nunca se encadena «Forzar» sin una segunda confirmación.
`handle(url:)` con `.proposeQuit(app, reason, agent)`: sección Rendimiento; `await performance.firstSnapshot()`; `board.row(matching:)`: nil ⇒ aviso `.performance` «Un agente propuso cerrar «\(app)», pero no está abierta.»; `never` ⇒ «Un agente propuso cerrar «\(nombre)», pero Airy nunca la cierra.»; `flow.isBusy` ⇒ «Airy está ocupada; vuelve a pedirlo en un momento.»; si no, `flow.requestQuit([group], warning: Warning(title: "Un agente propone cerrar esto", subtitle: "\(agent ?? "Un agente") · \(reason.isEmpty ? "sin motivo" : reason)", reason: "Nada se cierra hasta que lo confirmes aquí.", note: "Si tiene algo sin guardar, la app te lo preguntará."), proposedBy: agent)`.
Tarjeta «Mantenimiento» (`MaintenanceCard`): filas de `session.maintenance` con `RiskBadge(.yourCall)`, título, explicación y botón «Aplicar…» ⇒ `flow.requestClean([item])` (embudo del plan 1); resultado de comando: «Hecho» (no «0 kB liberados»); botón «Comprobar Spotlight» (muestra «Midiendo…»; resultados «Spotlight responde bien (\(s) s).», «Spotlight tarda \(s) s en buscar.» + «Conecta el cargador para poder reindexar.» si no hay corriente, «Spotlight está desactivado en este disco.», «No se pudo medir Spotlight.»); vacío: «Nada que ajustar.». Bloque «Elementos de inicio rotos»: lista (etiqueta y «Falta: \(programa)») con «Abrir Ajustes de elementos de inicio» (`NSWorkspace.shared.open(LoginItemsAudit.settingsURL)`), pie «Airy solo avisa; quítalos tú en Ajustes del Sistema.»; vacío: «Ningún elemento de inicio roto.».
«¿Por qué va lento?» (botón en la cabecera, solo si `model.assistant` tiene Claude localizado; si no, oculto): `SlowAISheet` muestra «Se envía a Claude solo esto:» con el JSON de `PerformanceAIContext.build` desplegable, y la respuesta en streaming de `explainSlowness`; «Cerrar» cancela el stream.

- [ ] **Step 1: Comprobar que las piezas de core están en verde** — `swift test --filter "QuitExecutorTests|PerformanceBoardTests|MaintenanceTests|PerformanceAITests"` → PASS (esta tarea es cableado de interfaz; su lógica ya está probada).
- [ ] **Step 2: Implement** el cableado y las vistas según Interfaces.
- [ ] **Step 3: Build** — `swift build 2>&1 | tail -3` → sin errores ni avisos nuevos.
- [ ] **Step 4: Verificación manual con apps de prueba propias** (nunca cerrar apps del usuario): `AIRY_SUPPORT_DIR=$(mktemp -d) .build/debug/Airy &` (guardar `$!` como `AIRY`); abrir `open -n -a TextEdit` y crear un documento sin guardar con texto; en otra terminal `python3 -m http.server 8765 &` (guardar `$!` como `PY`).
  1. Rendimiento ⇒ TextEdit en verde con «Cerrar»; `python3` en ámbar con «· carpeta»; Finder, Dock y Airy sin controles.
  2. «Cerrar» TextEdit ⇒ hoja de confirmación ⇒ «Cerrar» ⇒ TextEdit pregunta si guardar (cierre normal): pulsar **Cancelar** en TextEdit ⇒ a los 10 s la fila dice «No responde» con «Forzar cierre…»; pulsar «Forzar cierre…» ⇒ segunda hoja ⇒ **Cancelar** (no forzar). Cerrar TextEdit a mano sin guardar.
  3. Seleccionar `python3` ⇒ «Cerrar seleccionadas (1)» ⇒ el bloque ámbar «Revisa: puede que estés usándolo» ⇒ confirmar ⇒ la fila sale volando en hojas; `kill -0 $PY` falla (cerrado por SIGTERM).
  4. Mantenimiento: «Comprobar Spotlight» muestra un resultado; **no** pulsar «Aplicar…» en ninguna ficha (solo abrir la hoja y Cancelar).
  5. Con la app cerrada (`kill $AIRY`): `bash scripts/build-app.sh && open 'airy://quit?app=com.apple.TextEdit&reason=prueba&agent=manual'` tras abrir TextEdit otra vez ⇒ Airy arranca en Rendimiento y muestra «Un agente propone cerrar esto» ⇒ **Cancelar**. `open 'airy://quit?app=Finder&reason=x&agent=manual'` ⇒ aviso «…pero Airy nunca la cierra.».
  6. «¿Por qué va lento?» (si Claude está instalado): el desplegable muestra solo números y nombres; llega una respuesta.
  7. «Reducir movimiento» activado en Ajustes del Sistema ⇒ remolino quieto y filas con fundido. Parar todo matando solo los PID guardados (Airy por su PID; TextEdit con ⌘Q).
- [ ] **Step 5: Run full suite** — `swift test 2>&1 | tail -3` → todo verde.
- [ ] **Step 6: Commit** — `feat: cerrar apps desde Rendimiento, propuestas de agentes, mantenimiento e IA` (+ Co-Authored-By).
