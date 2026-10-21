# Airy 4 of 5 — Performance · Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A new **Performance** section that explains Activity Monitor's information in plain language (overall status with a traffic light, memory and swap, temperature without degrees, CPU and energy, «Lo que más pesa» (What weighs the most) with grouped apps and a Quit button, extras, broken startup items and reversible maintenance), with measurement in the common library so that the MCP (`get_performance`, `propose_quit_app`) measures and proposes the same even when the app is closed.

**Architecture:** Everything that measures, groups, diagnoses and quits lives in `DiskMapCore/Performance` (UI-free, tested with fake samplers and process lists). Sampling is **on demand**: `PerformanceMonitor` has no timer of its own; the app calls it every 1.5 s only with the section visible and the MCP calls it twice, 1 s apart, per query. Quitting apps has its own single funnel (`QuitExecutor`: user confirmation, revalidation when acting, normal quit first, «Forzar cierre» (Force quit) only if it did not respond, log); maintenance items are catalog records that run through the usual deletion funnel (`CleanupExecutor`).

**Tech Stack:** Swift 6.4 (Command Line Tools only), SwiftPM, Swift Testing, SwiftUI + AppKit, `host_statistics64`/`host_processor_info`, `sysctl`, `libproc` (`proc_pid_rusage`, `proc_pidinfo`), `/bin/ps` (read), IOKit (`IOPowerSources`, `AppleSmartBattery`, `IOBlockStorageDriver`, `IOPMCopyCPUPowerStatus`), `NSRunningApplication`.

**Spec:** `docs/superpowers/specs/2026-10-20-airy-fase-2-design.md` §2.6 (Performance), §2.9 «Rendimiento más completo» (More complete Performance), §2.8 (`get_performance`, `propose_quit_app`), §2.2 (Performance animation), §3–§5 (non-goals, anti-goals, public APIs) and «Decisiones de Claude tras la revisión del constructor» (Claude's decisions after the builder's review) (MCP with the app closed). Mole ideas and thresholds: `docs/superpowers/research/2026-10-20-mole-inspiracion.md` §3, §3.1, §4 and rows #6, #17, #18, #20, #21 of §6. Plan 1 interfaces (binding): `docs/superpowers/plans/2026-10-20-airy-1-identidad-seguridad-mcp.md` (Tasks 3, 6, 7, 8, 9, 10, 11, 13) and its rulings in `.superpowers/sdd/2026-10-20-airy-1-identidad-seguridad-mcp/progress.md`. Tokens and animations: plan 2 (`docs/superpowers/plans/2026-10-20-airy-2-marca-animaciones.md`, table «Interfaces públicas que consumen los planes 3–5» (Public interfaces consumed by plans 3–5)).

**Out of this plan:** degrees and fans (rejected, #19), `purge` and other placebos (#22), GPU, proxy and per-tunnel network; Uninstaller and other sections (plan 5); admin for system cleanups (plan 3).

## Global Constraints

- Swift 6.4, SwiftPM, Command Line Tools only; `swift build` / `swift test`; `.macOS(.v15)`; the test target keeps the `unsafeFlags` of the Swift Testing plugin.
- Interface in **Spanish (Spain)**; MCP tool names in English, response texts in Spanish.
- Views with the `@ViewState` alias (not `@State`); **never** `.fixedSize(horizontal:false,vertical:true)` on multiline `Text` (use `.lineLimit(nil)` and the container's width); follow `GlassCard`, `PrimaryButton`, `SectionHeader` and plan 2's public interfaces as they are: `Theme.Airy` (incl. `swirlTint(_:)`, `riskFill`, `riskInk`), `RiskBadge(risk:compact:reason:)`, `WindSwirl(speed:tint:)`, `WindMotion.swirlRevolutionsPerSecond(cpuLoad:)`, `AnyTransition.leafAway`, `WindLeaves(mode:count:)`, `.hoverSway(_:)` and the gatekeeper `EnvironmentValues.airyAmbientMotion` / `.airyTransientMotion` (every new animated view reads it).
- **Public and stable APIs only** (§5): no private HID sensors, `powermetrics`, `responsibility_get_pid_responsible_for_pid` nor SPI. No temperature degrees.
- **Lightness:** nothing measures in the background. The section refreshes every **1.5 s** only while it is visible (section chosen, window not hidden or minimized); on leaving, everything stops. The MCP measures only when called. Zero CPU at rest; respect «Reducir movimiento» (Reduce Motion) (fades instead of swirl and leaves).
- The following are **never** offered for quitting: system processes or those of other users, Finder, Dock, WindowServer, loginwindow, SystemUIServer, Control Center, Airy itself nor `airy-mcp`. Stray user processes (`node`, `python`, local servers) are, in **amber** («Tú decides» (You decide)).
- Quitting = **normal quit first** (`terminate()` / `SIGTERM`; the app may ask to save); «Forzar cierre» only for what did not close within 10 s. Every quit goes through `ConfirmSheet` → `AppModel` → `QuitExecutor` (the only place with `terminate`/`forceTerminate`/`kill` of foreign processes, in addition to what already exists). Agents **never** quit anything: `propose_quit_app` only opens Airy with the confirmation prepared.
- **No "free RAM" button.**
- Every destructive maintenance action goes through `ConfirmSheet` → `AppModel` → `CleanupExecutor` (plan 1 funnel); maintenance is always **amber**, never preselected, reversible and explained; the MCP never sees nor executes it.
- Broken startup items: **report only** with a link to System Settings; nothing is deleted.
- AI: «¿Por qué va lento?» (Why is it slow?) sends Claude **only numbers and app names** (no paths, PIDs, arguments or working folders), with the current closed invocation (`--tools ""`, `--setting-sources ""`…). The MCP does not receive process paths or arguments either.
- Commands with an argument array, never a shell string (the only AppleScript string is the fixed constant for reindexing Spotlight, see Task 10).
- **Tests: a real process is never quit nor killed** (`FakeTerminator`, fake lists); real `defaults write/delete`, `mdutil` or `osascript` are never run (`FakeRunner`); against the real system only reads (probes, `ps`, `get_performance`). Manual verification with `AIRY_SUPPORT_DIR=$(mktemp -d)`; to stop the app, `kill` **its own PID** (never `pkill -x`); DEBUG screenshots only of own windows; no DEBUG shortcuts that quit or execute without confirmation.
- File contents are never sent to the AI or the MCP; do not touch Keychain trust.
- Commits end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Rulings of this plan (decisions the spec leaves to the builder)

- **R1 — Group processes by app:** by **bundle path** (the outermost `.app` of `proc_pidpath`; Chrome Helper lives inside `Google Chrome.app` ⇒ counts as Chrome). No parent chain nor "responsible app" (private SPI). Processes outside an `.app`: in system folders ⇒ system; otherwise ⇒ stray process (with "· folder" from its working directory). Accepted limitation: `com.apple.WebKit.*` processes come out as system («Contenido web» (Web content)), not inside Safari.
- **R2 — Other users' processes:** libproc returns `EPERM` for root and other users' processes (checked on this Mac: `proc_pid_rusage` and `PROC_PIDTBSDINFO` fail with WindowServer and `syspolicyd`). For the family rules (`syspolicyd`, WindowServer, Spotlight, CoreSimulator) and for zombies, `/bin/ps` is read (setuid, read-only, the same method as Mole) once per sample. The user's own processes use libproc (memory footprint, energy, I/O, working folder). `ps` prints decimals with a comma in es_ES: the parser accepts `,` and `.`.
- **R3 — P/E cores:** `hw.perflevel0.logicalcpu` = performance, `hw.perflevel1.logicalcpu` = efficiency; it is assumed that `host_processor_info` lists the efficiency ones first (Apple Silicon order). Without `perflevel1` (Intel) there is only one group «Núcleos» (Cores).
- **R4 — Memory (like Activity Monitor):** used = app (internal − purgeable) + wired + compressed; file cache = external + purgeable; free = total − used − cache (≥ 0); **available** = free + cache. The spec's "Free < 15 %" uses `available / total`.
- **R5 — Throttling:** `throttling = (IOPMCopyCPUPowerStatus.speedLimit < 100) || thermalState ≥ .serious`.
- **R6 — Quitting is not deleting:** it does not go through `CleanupExecutor` (which only moves to the Trash or runs catalog commands) but through `QuitExecutor`, with the same pattern: plan → revalidate when acting → act → record in `OperationLog` (actions `quit_app` / `force_quit_app` / `propose_quit`).
- **R7 — Maintenance through the funnel:** new records in `catalog.json` with `section: "maintenance"`; `CleanupScanner`, `Catalog.match` and the MCP ignore them; `MaintenanceScanner` detects them and they run like any `CleanupItem` (`flow.requestClean` → `CleanupExecutor`). Reindexing Spotlight needs administrator: fixed command `osascript -e 'do shell script "/usr/bin/mdutil -E /" with administrator privileges'` with no variable part (same approach as phase 1 for administrator paths); it is only offered after measuring Spotlight as slow and with the charger connected.
- **R8 — Runaway process:** alive ≥ 12 h and average CPU over its whole life ≥ 25 % (CPU time / age), like Mole.
- **R9 — Docker VM:** memory of the Docker Desktop group (`com.docker.docker`) + `com.apple.Virtualization.VirtualMachine` processes if there is a Docker group and no other virtualization app (UTM, Parallels, VMware, OrbStack) open; containers with `docker ps -q` (3 s; if Docker does not respond, nothing is claimed).

## Review Focus

1. **The PID is reused** between the displayed list and the quit (the app closed by itself and another process inherited the PID) → the wrong process is never closed. Test in Task 8 (`pidReuseIsRefused`).
2. **`ps` in Spanish** (`4,4` with a comma), `<defunct>` lines, names with spaces, empty output or a failing `ps` → it is parsed correctly or the family diagnosis is skipped without making things up. Test in Task 3 (`parsesSpanishDecimalsAndSpaces`, `psFailureMeansNoSystemList`).
3. **Counters that go backwards or jump** (first sample, a network interface that drops, sleep/wake, a process that disappears between samples) → no negative or huge rates: `nil` («—»). Test in Task 1 (`countersGoingBackwardsGiveNoRate`, `vanishedProcessHasNoCPU`).
4. **An agent asks to quit «Finder», «Airy», «airy-mcp», an ambiguous or nonexistent name, or with the switch off** → error, the URL is never opened. Test in Task 12 (`proposeQuitRefusesNeverClosableUnknownAndToggleOff`).
5. **Performance opened before the first disk analysis finishes** or through `airy://quit` with the app closed → the section works without an analysis and the proposal waits for the first sample. Manual verification in Task 14 (step 5) and test in Task 13 (`boardResolvesProposalOnlyWithSnapshot`).

---

## File structure

```
Sources/DiskMapCore/Performance/
  PerformanceModels.swift        RawSample and pieces (memory, thermal, CPU, processes, battery, I/O)
  PerformanceMonitor.swift       PerformanceSampling, PerformanceMonitor (deltas, history), PerformanceSnapshot
  Probes/MemoryProbe.swift       host_statistics64, hw.memsize, vm.swapusage, kern.memorystatus_vm_pressure_level
  Probes/CPUProbe.swift          host_processor_info, hw.perflevel*, kern.boottime
  Probes/PowerProbe.swift        thermalState, IOPMCopyCPUPowerStatus, IOPowerSources, AppleSmartBattery
  Probes/IOProbe.swift           IOBlockStorageDriver «Statistics», sysctl NET_RT_IFLIST2
  Probes/ProcessProbe.swift      libproc (own processes), /bin/ps (all), open apps
  LiveSampler.swift              composes the probes
  AppGrouper.swift               processes → AppGroup (R1)
  AppCatalog.swift               one-line explanation per app/process (Resources/apps.json)
  QuitPolicy.swift               what can be quit and with what risk
  QuitExecutor.swift             quit funnel (R6)
  PerformanceDiagnosis.swift     rules, findings, traffic light and sentence
  DiagnosisProbes.swift          docker ps -q, hdiutil info
  LoginItemsAudit.swift          LaunchAgents with a nonexistent binary
  PerformanceAIContext.swift     JSON with only numbers and names
Sources/DiskMapCore/Maintenance/MaintenanceScanner.swift, SpotlightCheck.swift
Sources/DiskMapCore/UIState/PerformanceBoard.swift   rows and selection (pure logic)
Sources/DiskMapCore/MCP/Tools/PerformanceTools.swift GetPerformanceTool, ProposeQuitAppTool
Sources/DiskMapCore/Resources/apps.json              (new resource)
Sources/Airy/Performance/
  PerformanceSession.swift       sampling cycle (visible only), observed state
  PerformanceView.swift          header (swirl + sentence + traffic light) and layout
  MemoryThermalCards.swift       memory/pressure/swap and temperature
  HeavyAppsList.swift            «Lo que más pesa», CPU and energy, selection and Quit
  ExtrasCard.swift               battery, disk, network, uptime, zombies, P/E cores
  MaintenanceCard.swift          maintenance + broken startup items
  SlowAISheet.swift              «¿Por qué va lento?»
Modify: Package.swift (apps.json resource), Catalog.swift (section), CleanupScanner.swift, catalog.json,
        AIAssistant.swift, AiryURL.swift, AiryEnvironment.swift, MCPToolRegistry.standard(),
        Sources/Airy/AppModel.swift, Shell/RootView.swift, Cleanup/CleanupFlow.swift, Cleanup/ConfirmSheet.swift
Tests/DiskMapCoreTests/  PerformanceMonitorTests, ProbeTests, AppGrouperTests, QuitPolicyTests,
                         QuitExecutorTests, DiagnosisTests, LoginItemsTests, MaintenanceTests,
                         PerformanceAITests, MCPPerformanceToolTests, PerformanceBoardTests
```

---

### Task 1: Sample model and `PerformanceMonitor` (deltas, history, on demand)

**Files:**
- Create: `Sources/DiskMapCore/Performance/PerformanceModels.swift`, `Sources/DiskMapCore/Performance/PerformanceMonitor.swift`
- Test: `Tests/DiskMapCoreTests/PerformanceMonitorTests.swift` (with `FakeSampler` returning scripted samples and counting calls)

**Interfaces:**
- Produces (all `Sendable, Equatable`, `public`):
```swift
public enum MemoryPressure: String, Codable { case normal, warning, critical }   // sysctl 1 / 2 / 4
public struct MemoryStats {
    public var total, used, appMemory, wired, compressed, fileCache, free: Int64
    public var pressure: MemoryPressure?                  // nil = could not be read
    public var swapUsed, swapTotal: Int64
    public var available: Int64 { free + fileCache }      // R4
    public var availableFraction: Double                  // available / total (0 if total == 0)
    public var swapFraction: Double?                      // nil if swapTotal == 0
}
public enum ThermalLevel: String, Codable, Comparable { case nominal, fair, serious, critical
    public var label: String                              // «Normal», «Caliente» (Hot), «Muy caliente» (Very hot), «Crítico» (Critical)
    public var processInfoState: ProcessInfo.ThermalState } // for plan 2's Theme.Airy.swirlTint
public struct ThermalReading { public var level: ThermalLevel; public var speedLimit: Int?; public var throttling: Bool }
public struct CoreTicks { public var user, system, idle, nice: UInt64 }
public struct CoreTopology { public var performance: Int; public var efficiency: Int }   // efficiency 0 on Intel
public struct OwnProcess {          // current user's processes (libproc)
    public var pid, ppid: Int32; public var uid: UInt32; public var name: String; public var executablePath: String?
    public var startTime: Date; public var cpuTimeNs: UInt64; public var footprint: Int64
    public var energyNj: UInt64; public var diskReadBytes, diskWriteBytes: UInt64
    public var workingDirectory: String?; public var isZombie: Bool
}
public struct SystemProcess {       // all users (/bin/ps)
    public var pid, ppid: Int32; public var uid: UInt32; public var cpuPercent: Double; public var rssBytes: Int64
    public var state: String; public var name: String
    public var isZombie: Bool { state.hasPrefix("Z") }
}
public struct RunningAppInfo { public var pid: Int32; public var bundleID: String?; public var name: String
    public var bundlePath: String?; public enum Policy: String { case regular, accessory, prohibited }; public var policy: Policy }
public struct BatteryReading { public var percent: Int; public var isCharging: Bool; public var onACPower: Bool
    public var cycleCount: Int?; public var healthPercent: Int? }
public struct IOCounters { public var read: UInt64; public var written: UInt64 }   // disk: read/written; network: download/upload
public struct RawSample {
    public var date: Date; public var uptimeNs: UInt64                 // CLOCK_UPTIME_RAW
    public var memory: MemoryStats; public var thermal: ThermalReading
    public var cores: [CoreTicks]; public var topology: CoreTopology?; public var bootTime: Date?
    public var processes: [OwnProcess]; public var system: [SystemProcess]?   // nil = ps failed
    public var apps: [RunningAppInfo]; public var battery: BatteryReading?
    public var disk: IOCounters?; public var network: IOCounters?
}
public struct Rate { public var readPerSecond: Double; public var writePerSecond: Double }
public struct CPUUsage { public var total: Double; public var performance: Double?; public var efficiency: Double?; public var topology: CoreTopology? } // 0…100
public struct Zombie { public var pid: Int32; public var parentPID: Int32; public var parentName: String? }
public struct PerformanceSnapshot {
    public var date: Date; public var memory: MemoryStats; public var thermal: ThermalReading
    public var cpu: CPUUsage?                         // nil on the first sample
    public var processCPU: [Int32: Double]            // % per own PID (100 = one core), only with a previous sample
    public var processEnergy: [Int32: Double]         // approximate watts (ΔnJ / Δt)
    public var raw: RawSample                         // the raw sample (processes, apps, system)
    public var groups: [AppGroup]                     // filled in by Task 5 (empty until then)
    public var battery: BatteryReading?; public var disk: Rate?; public var network: Rate?
    public var uptime: TimeInterval?; public var zombies: [Zombie]
}
public protocol PerformanceSampling: Sendable { func sample() async -> RawSample }
public actor PerformanceMonitor {
    public init(sampler: any PerformanceSampling, historyLimit: Int = 6,
                grouper: @escaping @Sendable (RawSample, [Int32: Double], [Int32: Double]) -> [AppGroup] = { _, _, _ in [] })
    public func refresh() async -> PerformanceSnapshot        // one sample, deltas against the previous one, adds to the history
    public var history: [PerformanceSnapshot] { get }         // most recent at the end, at most historyLimit
    public func reset()                                       // forgets the previous sample (when leaving the section)
}
```
Delta rules: total CPU = Σ(user+system+nice) / Σ(all) of the per-core differences × 100; P/E according to R3. Per-process CPU = ΔcpuTimeNs / ΔuptimeNs × 100, only if the PID and its `startTime` match in both samples. Rates = Δ / Δt; **any counter that goes backwards, Δt ≤ 0 or is missing in one of the two samples ⇒ `nil`**. `uptime` = `date − bootTime`. Zombies: from `system` (state `Z`) with the parent's name looked up in `system`; if `system == nil`, from `processes.isZombie`.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func monitorNeverSamplesUnasked() async       // create the monitor and wait 0.3 s → sampler.calls == 0
@Test func firstSnapshotHasNoCPUOrRates() async     // cpu == nil, disk == nil, network == nil, processCPU empty
@Test func cpuTotalAndClustersFromTicks() async {
    // 4 cores (2 E + 2 P): E busy 50 %, P 100 % → total 75, efficiency 50, performance 100
    #expect(s.cpu?.total == 75); #expect(s.cpu?.efficiency == 50); #expect(s.cpu?.performance == 100)
}
@Test func processCPUFromCPUTime() async            // +500 ms of CPU in 1 s of uptime → processCPU[pid] == 50
@Test func vanishedProcessHasNoCPU() async          // PID absent or with another startTime in the 2nd → no entry
@Test func countersGoingBackwardsGiveNoRate() async // disk 10→5, network absent in the 2nd, same uptime → nil, nil
@Test func ratesPerSecond() async                   // disk +2 MB in 2 s → readPerSecond == 1_048_576
@Test func memoryDerivedValues()                    // available, availableFraction, swapFraction(0 total → nil)
@Test func zombiesNameTheirParent() async           // ps: 83479 Z ppid 83371 "<defunct>", 83371 "node" → parentName "node"
@Test func historyIsBounded() async                 // 8 refreshes with historyLimit 6 → history.count == 6
```

- [ ] **Step 2: Run test to verify it fails** — `swift test --filter PerformanceMonitorTests` → FAIL (nonexistent types).
- [ ] **Step 3: Implement** according to Interfaces. `AppGroupKind` and `struct AppGroup` (fields in Task 5) are already declared in `PerformanceModels.swift` so that `PerformanceSnapshot` compiles; Task 5 adds only the grouper and the catalog.
- [ ] **Step 4: Run tests** — `swift test --filter PerformanceMonitorTests` → PASS (10).
- [ ] **Step 5: Commit** — `feat: performance sample model and on-demand monitor` (+ Co-Authored-By).

---

### Task 2: System probes: memory, pressure, swap, thermal, CPU, uptime

**Files:**
- Create: `Sources/DiskMapCore/Performance/Probes/MemoryProbe.swift`, `CPUProbe.swift`, `PowerProbe.swift` (only the thermal part here; battery in Task 4)
- Test: `Tests/DiskMapCoreTests/ProbeTests.swift`

**Interfaces:**
- Produces:
```swift
public enum MemoryProbe {
    public static func read() -> MemoryStats?          // host_statistics64(HOST_VM_INFO64) + hw.memsize + vm.swapusage + pressure
    static func stats(vm: vm_statistics64, pageSize: Int64, total: Int64, swap: xsw_usage?, pressureLevel: Int32?) -> MemoryStats  // R4, pure
    static func pressure(level: Int32) -> MemoryPressure?   // 1 normal, 2 warning, 4 critical, other nil
}
public enum CPUProbe {
    public static func ticks() -> [CoreTicks]?          // host_processor_info(PROCESSOR_CPU_LOAD_INFO); vm_deallocate of the array
    public static func topology() -> CoreTopology?      // hw.perflevel0/1.logicalcpu (R3); nil if perflevel0 does not exist
    public static func bootTime() -> Date?              // kern.boottime
}
public enum ThermalProbe {
    public static func read() -> ThermalReading         // ProcessInfo.thermalState + IOPMCopyCPUPowerStatus (R5)
    static func reading(state: ProcessInfo.ThermalState, speedLimit: Int?) -> ThermalReading  // pure
}
```

- [ ] **Step 1: Write the failing tests**

```swift
@Test func memoryStatsFollowActivityMonitor() {
    // 16 KiB pages: internal 1000, purgeable 100, wire 200, compressor 300, external 400, total 4000 pages
    // → appMemory 900 p, used 1400 p, fileCache 500 p, free 2100 p (in bytes ×16384)
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
@Test func liveTopologySumsToCores()              // real: if not nil, performance + efficiency == activeProcessorCount
@Test func liveBootTimeInThePast()
```

- [ ] **Step 2: Run** — `swift test --filter ProbeTests` → FAIL.
- [ ] **Step 3: Implement** according to Interfaces (the `read`/`ticks` functions call the pure ones).
- [ ] **Step 4: Run** — `swift test --filter ProbeTests` → PASS (7).
- [ ] **Step 5: Commit** — `feat: memory, pressure, swap, thermal state and CPU probes` (+ Co-Authored-By).

---

### Task 3: Process probe (libproc for own processes, `ps` for all, open apps)

**Files:**
- Create: `Sources/DiskMapCore/Performance/Probes/ProcessProbe.swift`
- Test: `Tests/DiskMapCoreTests/ProbeTests.swift` (add)

**Interfaces:**
- Consumes: `CommandRunning` (phase 1), types from Task 1.
- Produces:
```swift
public enum ProcessProbe {
    /// Processes with the same uid as this process (including itself). PROC_PIDTBSDINFO (uid, ppid, state, start),
    /// proc_pidpath, proc_pid_rusage(RUSAGE_INFO_V4) (ri_user_time + ri_system_time converted with mach_timebase_info,
    /// ri_phys_footprint, ri_billed_energy, ri_diskio_bytesread/written); working directory with PROC_PIDVNODEPATHINFO
    /// only for processes outside an .app. Those that fail (EPERM, already terminated) are skipped.
    public static func ownProcesses() -> [OwnProcess]
    public static let psArguments = ["-Ac", "-o", "pid=,ppid=,uid=,pcpu=,rss=,state=,comm="]
    /// `/bin/ps` with psArguments, 3 s deadline; status ≠ 0, exhausted deadline or empty output ⇒ nil.
    public static func systemProcesses(runner: any CommandRunning) async -> [SystemProcess]?
    /// Six space-separated fields and the rest of the line is the name; `,` or `.` decimal; rss in KiB.
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
    garbage
    """
    let p = ProcessProbe.parsePS(out)
    #expect(p.count == 3)
    #expect(p[0].cpuPercent == 41.4 && p[0].rssBytes == 117504 * 1024 && p[0].uid == 88)
    #expect(p[1].isZombie && p[1].ppid == 83371)
    #expect(p[2].name == "Google Chrome Helper (Renderer)" && p[2].cpuPercent == 12.5)
}
@Test func psFailureMeansNoSystemList() async      // FakeRunner: status 1 → nil; empty output → nil
@Test func psUsesFixedArguments() async            // FakeRunner records ("/bin/ps", psArguments)
@Test func ownProcessesIncludeSelfWithFootprint() {
    let me = ProcessProbe.ownProcesses().first { $0.pid == ProcessInfo.processInfo.processIdentifier }
    #expect(me != nil && me!.footprint > 0 && me!.uid == getuid())
}
@Test func ownProcessesNeverIncludeOtherUsers()    // all with uid == getuid()
@Test func ownCPUTimeAdvances()                    // busy loop 200 ms → own cpuTimeNs goes up ≥ 100 ms
@Test func runningAppsHaveNamesAndPolicies()       // real: not empty in a graphical session; if empty (CI without a session) it is logged and passes
```

- [ ] **Step 2: Run** — `swift test --filter ProbeTests` → FAIL.
- [ ] **Step 3: Implement** according to Interfaces.
- [ ] **Step 4: Run** — `swift test --filter ProbeTests` → PASS (14).
- [ ] **Step 5: Commit** — `feat: process probe (own libproc, read-only ps for the system)` (+ Co-Authored-By).

---

### Task 4: Battery, disk and network probes, and `LiveSampler`

**Files:**
- Create: `Sources/DiskMapCore/Performance/Probes/IOProbe.swift`, `Sources/DiskMapCore/Performance/LiveSampler.swift`
- Modify: `Sources/DiskMapCore/Performance/Probes/PowerProbe.swift` (battery)
- Test: `Tests/DiskMapCoreTests/ProbeTests.swift` (add)

**Interfaces:**
- Produces:
```swift
public enum BatteryProbe {
    /// IOPSCopyPowerSourcesInfo (capacity, charging, «AC Power») + AppleSmartBattery registry
    /// (CycleCount; health = AppleRawMaxCapacity / DesignCapacity × 100, clamped 0…100). nil without an internal battery.
    public static func read() -> BatteryReading?
    static func health(rawMax: Int?, design: Int?) -> Int?
    public static func onACPower() -> Bool          // IOPSGetProvidingPowerSourceType == "AC Power"
}
public enum IOProbe {
    public static func disk() -> IOCounters?        // Σ «Statistics» of IOBlockStorageDriver: «Bytes (Read)», «Bytes (Write)»
    public static func network() -> IOCounters?     // sysctl NET_RT_IFLIST2, if_data64 ifi_ibytes/ifi_obytes
    static func countsInterface(name: String, isLoopback: Bool) -> Bool   // excludes lo*, utun*, ipsec* (the tunnel is already counted on its carrier)
}
public struct LiveSampler: PerformanceSampling {
    public init(runner: any CommandRunning = ProcessRunner())
    public func sample() async -> RawSample          // all probes; ps in parallel with the others
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
@Test func liveSamplerFillsEverything() async {     // real: memory.total > 0, cores not empty, processes contains the own PID,
    // system != nil, uptimeNs > 0; battery may be nil (desktop Mac)
}
@Test func liveSamplerIsQuick() async               // one sample < 1 s (lightness)
```

- [ ] **Step 2: Run** — `swift test --filter ProbeTests` → FAIL.
- [ ] **Step 3: Implement** according to Interfaces.
- [ ] **Step 4: Run** — `swift test --filter ProbeTests` → PASS (19).
- [ ] **Step 5: Commit** — `feat: battery, disk and network I/O, and real sampler` (+ Co-Authored-By).

---

### Task 5: Group processes by app and explanation catalog

**Files:**
- Create: `Sources/DiskMapCore/Performance/AppGrouper.swift`, `Sources/DiskMapCore/Performance/AppCatalog.swift`, `Sources/DiskMapCore/Resources/apps.json`
- Modify: `Package.swift` (`resources: [.process("Resources/catalog.json"), .process("Resources/apps.json")]`). Whoever creates a real `PerformanceMonitor` (Tasks 12 and 13) passes it `grouper: { AppGrouper.group($0, cpu: $1, energy: $2, catalog: appCatalog) }`.
- Test: `Tests/DiskMapCoreTests/AppGrouperTests.swift`

**Interfaces:**
- Produces (`AppGroupKind` and `AppGroup` live in `PerformanceModels.swift`, declared in Task 1):
```swift
public enum AppGroupKind: String, Sendable, Codable { case app, background, looseProcess, system }
public struct AppGroup: Sendable, Equatable, Identifiable {
    public var id: String              // bundleID ?? "bundle:" + bundlePath  |  "pid:\(pid):\(startTime epoch)"
    public var name: String            // the app's localizedName, or the process name
    public var detail: String?         // stray: last component of the working directory (not sent to AI/MCP)
    public var bundleID: String?; public var bundlePath: String?
    public var kind: AppGroupKind
    public var uid: UInt32
    public var leadPID: Int32; public var leadStart: Date; public var pids: [Int32]
    public var processNames: [String]
    public var memory: Int64           // Σ footprint
    public var cpuPercent: Double?     // Σ processCPU (nil if none has a delta)
    public var energy: Double?         // Σ processEnergy
    public var explanation: String?    // AppCatalog
    public func impact(totalMemory: Int64, logicalCores: Int) -> Double
        // memory / totalMemory + (cpuPercent ?? 0) / (100 × max(1, logicalCores))
}
public struct AppCatalogEntry: Codable, Sendable, Equatable { public var id, title, explanation: String
    public var bundleIDs: [String]; public var processNames: [String] }
public struct AppCatalog: Sendable {
    public static func bundled() throws -> AppCatalog       // same bundle lookup as Catalog.bundled()
    public init(entries: [AppCatalogEntry])
    public func entry(bundleID: String?, processName: String) -> AppCatalogEntry?   // bundle id first; name case-insensitive
}
public enum AppGrouper {
    public static let systemPrefixes = ["/System/", "/usr/", "/sbin/", "/bin/", "/Library/Apple/", "/private/"]
    public static func outermostBundle(_ path: String?) -> String?   // "/Applications/Google Chrome.app" from an internal helper
    public static func group(_ raw: RawSample, cpu: [Int32: Double], energy: [Int32: Double], catalog: AppCatalog?) -> [AppGroup]
}
```
Algorithm (R1): for each non-zombie `OwnProcess`: `outermostBundle` ⇒ bundle key; the open app with that `bundlePath` gives name, bundle id and `kind` (`.regular`/`.accessory` ⇒ `.app`; `.prohibited` or no open app ⇒ `.background`; a bundle under `systemPrefixes` without a regular app ⇒ `.system`). The process whose PID is the app's is the `lead` (if there is none, the one with the most memory). Without a bundle: path under `systemPrefixes` ⇒ `.system` (grouped by name); otherwise ⇒ `.looseProcess`, one group per PID with `detail` = last component of `workingDirectory` unless it is `/` or the home. Output order: `impact` descending.
`apps.json` (`{"entries": [...]}`) with, at minimum, these ids and a one-line explanation in Spanish each: `chrome` (`com.google.Chrome`), `safari`, `firefox`, `brave`, `edge`, `arc`, `slack`, `discord`, `teams`, `zoom`, `spotify`, `docker-desktop` (`com.docker.docker`), `vscode`, `cursor`, `xcode`, `simulator`, `figma`, `photoshop`, `premiere`, `final-cut`, `notion`, `whatsapp`, `telegram`, `claude`, `chatgpt`, `ollama`, `lm-studio`, `node` (`node`), `python` (`python`, `python3`, `Python`), `ruby`, `java`, `bun`, `deno`, `postgres`, `redis` (`redis-server`), `webkit-content` (`com.apple.WebKit.WebContent`), `windowserver`, `spotlight` (`mds`, `mds_stores`, `mdworker`, `mdworker_shared`), `syspolicyd`, `kernel-task`. Exact examples: chrome «Navegador de Google; cada pestaña y extensión es un proceso aparte, por eso suma tanto.» (Google's browser; each tab and extension is a separate process, which is why it adds up so much.); node «Programa de JavaScript, normalmente un servidor o una herramienta que lanzaste en la terminal.» (A JavaScript program, normally a server or a tool you launched in the terminal.); docker-desktop «Docker Desktop y su máquina virtual Linux; reserva memoria aunque no haya contenedores.» (Docker Desktop and its Linux virtual machine; it reserves memory even if there are no containers.)

- [ ] **Step 1: Write the failing tests**

```swift
@Test func helpersCountAsTheirApp() {
    // Chrome (pid 10, /Applications/Google Chrome.app/Contents/MacOS/Google Chrome, 300 MB)
    // + helper in …/Google Chrome.app/Contents/Frameworks/…/Google Chrome Helper.app/… (pid 11, 700 MB)
    let g = AppGrouper.group(raw, cpu: [10: 5, 11: 20], energy: [:], catalog: catalog)
    #expect(g.count == 1 && g[0].name == "Google Chrome" && g[0].memory == 1_000 << 20)
    #expect(g[0].cpuPercent == 25 && g[0].leadPID == 10 && g[0].pids.sorted() == [10, 11])
    #expect(g[0].explanation?.hasPrefix("Navegador de Google") == true)
}
@Test func outermostBundleOfNestedHelper()
@Test func looseNodeShowsProjectFolder()          // /opt/homebrew/bin/node, cwd /Users/x/Proyectos/mi-api → kind .looseProcess, detail "mi-api"
@Test func looseInHomeOrRootHasNoDetail()
@Test func systemPathsAreSystem()                 // /usr/libexec/x, /System/Library/…/mds → .system
@Test func backgroundAgentIsNotAnApp()            // bundle in ~/Library/…/Helper.app with policy .prohibited → .background
@Test func zombiesAreNotGrouped()
@Test func sortedByImpact()                       // 2 GB without CPU versus 100 MB at 400 % on 4 cores → ordered by impact
@Test func bundledAppCatalogHasRequiredIDs()      // the 40 ids above; non-empty one-line explanations (without "\n")
```

- [ ] **Step 2: Run** — `swift test --filter AppGrouperTests` → FAIL.
- [ ] **Step 3: Implement** according to Interfaces.
- [ ] **Step 4: Run** — `swift test --filter AppGrouperTests` → PASS (9); `swift test 2>&1 | tail -3` → green.
- [ ] **Step 5: Commit** — `feat: group processes by app and explanation catalog` (+ Co-Authored-By).

---

### Task 6: Quit policy (`QuitPolicy`)

**Files:**
- Create: `Sources/DiskMapCore/Performance/QuitPolicy.swift`
- Test: `Tests/DiskMapCoreTests/QuitPolicyTests.swift`

**Interfaces:**
- Consumes: `AppGroup` (Task 5), `Risk`.
- Produces:
```swift
public enum QuitEligibility: Sendable, Equatable {
    case allowed(Risk)          // .safe (normal app) or .yourCall (stray process); never .doNotTouch
    case never(String)          // visible reason
    public var isAllowed: Bool
}
public struct QuitPolicy: Sendable {
    public static let neverBundleIDs: Set<String>   // com.apple.finder, com.apple.dock, com.apple.loginwindow,
        // com.apple.systemuiserver, com.apple.controlcenter, com.apple.notificationcenterui, com.apple.WindowManager,
        // com.apple.Spotlight, local.airy.Airy
    public static let neverProcessNames: Set<String> // Finder, Dock, WindowServer, loginwindow, SystemUIServer,
        // ControlCenter, Control Center, NotificationCenter, Airy, airy-mcp, launchd, kernel_task (case-insensitive comparison)
    public init(currentUID: UInt32 = getuid(), ownPIDs: Set<Int32> = [ProcessInfo.processInfo.processIdentifier])
    public func eligibility(_ group: AppGroup) -> QuitEligibility
}
```
Order and exact texts: own PID, `bundlePath`/path with `/Airy.app/` or process `airy-mcp` ⇒ «Es el propio Airy.» (It is Airy itself.); `uid ≠ currentUID` ⇒ «Es de otro usuario o del sistema.» (It belongs to another user or the system.); `kind == .system` ⇒ «Es parte de macOS.» (It is part of macOS.); `kind == .background` ⇒ «Es un proceso de fondo; macOS lo vuelve a abrir solo.» (It is a background process; macOS opens it again by itself.); bundle id or some name in the lists ⇒ «macOS lo necesita para funcionar.» (macOS needs it to work.); `.looseProcess` ⇒ `.allowed(.yourCall)`; `.app` ⇒ `.allowed(.safe)`. Amber warning for stray ones (used by the UI): `QuitPolicy.looseWarning = "Puede que estés usándolo: un servidor o un programa que lanzaste en la terminal."` (You may be using it: a server or a program you launched in the terminal.)

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
@Test func ownPIDNeverEvenIfRenamed()             // group with the own leadPID and name "Otra" (Other) → «Es el propio Airy.»
@Test func airyMCPInsideBundleIsNever()           // path …/Airy.app/Contents/MacOS/airy-mcp
@Test func otherUsersAndSystemNever()             // uid 0; kind .system; kind .background
@Test func looseProcessesAreAmber()               // node, python3 → .allowed(.yourCall)
@Test func normalAppsAreGreen()                   // Spotify → .allowed(.safe)
@Test func neverWinsOverEverything()              // regular app with bundle com.apple.finder and own uid → never
```

- [ ] **Step 2: Run** — `swift test --filter QuitPolicyTests` → FAIL.
- [ ] **Step 3: Implement** according to Interfaces.
- [ ] **Step 4: Run** — `swift test --filter QuitPolicyTests` → PASS (8).
- [ ] **Step 5: Commit** — `feat: policy of what can be quit from Performance` (+ Co-Authored-By).

---

### Task 7: Rule-based diagnosis, traffic light and overall-status sentence

**Files:**
- Create: `Sources/DiskMapCore/Performance/PerformanceDiagnosis.swift`, `Sources/DiskMapCore/Performance/DiagnosisProbes.swift`
- Modify: `PerformanceMonitor` (`verdict(probes:)` with a 30 s extras cache)
- Test: `Tests/DiskMapCoreTests/DiagnosisTests.swift`

**Interfaces:**
- Consumes: `PerformanceSnapshot`, `AppGroup`, `SystemProcess`.
- Produces:
```swift
public enum HealthLevel: String, Sendable, Codable, Comparable { case good, fair, poor }   // green, amber, red
public struct Finding: Sendable, Equatable, Identifiable { public var id: String; public var level: HealthLevel; public var sentence: String }
public struct HealthVerdict: Sendable, Equatable { public var level: HealthLevel; public var sentence: String; public var findings: [Finding] }
public struct DiagnosisExtras: Sendable, Equatable {
    public var dockerRunningContainers: Int?      // nil = unknown
    public var mountedDiskImages: [String]?       // names (last component), nil = unknown
    public static let unknown = DiagnosisExtras(dockerRunningContainers: nil, mountedDiskImages: nil)
}
public enum ProcessFamily: String, CaseIterable, Sendable { case syspolicyd, windowServer, spotlight, coreSimulator
    public var processNames: [String] }   // ["syspolicyd"], ["WindowServer"], ["mds","mds_stores","mdworker","mdworker_shared","mdbulkimport"],
                                          // ["diskimagesiod","simdiskimaged","com.apple.CoreSimulator.CoreSimulatorService","launchd_sim"]
public enum PerformanceDiagnosis {
    public static let familyThreshold = 25.0, swapThreshold = 0.5, availableThreshold = 0.15
    public static let dockerVMBytes: Int64 = 2 << 30, runawayAge: TimeInterval = 12 * 3600, runawayCPU = 25.0, busyCPU = 85.0
    public static func familyCPU(_ system: [SystemProcess]) -> [ProcessFamily: Double]
    public static func dockerVMMemory(_ snapshot: PerformanceSnapshot) -> Int64?     // R9; nil without a Docker group
    /// `history`: most recent at the end. The "sustained" rules require the last two samples.
    public static func evaluate(_ history: [PerformanceSnapshot], extras: DiagnosisExtras) -> HealthVerdict
}
public struct DiagnosisProbes: Sendable {
    public init(runner: any CommandRunning)
    public func dockerRunningContainers() async -> Int?   // resolve("docker"); ["ps","-q"], 3 s; status ≠ 0 ⇒ nil; non-empty lines
    public func mountedDiskImages() async -> [String]?    // /usr/bin/hdiutil ["info","-plist"], 5 s; images[].image-path, excluding /System and /Library/Apple
}
extension PerformanceMonitor {
    /// Calls docker only if dockerVMMemory > dockerVMBytes and hdiutil only if syspolicyd ≥ threshold in the last two; 30 s cache.
    public func verdict(probes: DiagnosisProbes?) async -> HealthVerdict
}
```
Findings (id · level · exact sentence; `\(…)` is filled in):
- `thermal-critical` · poor · «Tu Mac está muy caliente y va mucho más lento para enfriarse.» (Your Mac is very hot and is running much slower to cool down.) (thermal `.critical`)
- `thermal-throttling` · fair · «Tu Mac se está calentando y ha bajado la velocidad.» (Your Mac is heating up and has slowed down.) (`throttling` and not critical)
- `memory` · poor if pressure `.critical`, otherwise fair · «Tu Mac va justo de memoria: \(A) y \(B) se llevan el \(p) %.» (Your Mac is tight on memory: A and B take p %.) — A, B = the 2 groups with the most memory, p = (memA + memB) / `memory.used` × 100 rounded; with a single group «\(A) se lleva el \(p) %»; without groups «Tu Mac va justo de memoria.» It fires with pressure ≠ `.normal`, `swapFraction > 0.5` or `availableFraction < 0.15`.
- `docker-vm` · fair · «Docker Desktop retiene \(Format.bytes) sin contenedores en marcha: ciérralo si no lo usas.» (Docker Desktop holds … with no containers running: close it if you do not use it.) (`dockerVMMemory > 2 GiB` and `dockerRunningContainers == 0`)
- `runaway:<pid>` · fair · «\(name) lleva \(h) h usando mucho procesador sin parar.» (… has been using a lot of processor non-stop for h h.) (R8, own processes only)
- `family-syspolicyd` · fair · «La comprobación de seguridad de apps (syspolicyd) está trabajando mucho.» (The app security check (syspolicyd) is working hard.); if there are also mounted images, `disk-images` · fair · «Hay imágenes de disco montadas (\(up to 3 names, «, »)) que la hacen trabajar: expúlsalas en Finder si ya no las usas.» (There are mounted disk images (…) that make it work: eject them in Finder if you no longer use them.)
- `family-windowServer` · fair · «La pantalla está trabajando mucho (WindowServer): suele ser por muchas ventanas, pantallas externas o efectos.» (The display is working hard (WindowServer): it is usually due to many windows, external displays or effects.)
- `family-spotlight` · fair · «Spotlight está indexando y usa mucho procesador; suele terminar solo.» (Spotlight is indexing and uses a lot of processor; it usually finishes by itself.)
- `family-coreSimulator` · fair · «Los simuladores de Xcode están usando mucho procesador; ciérralos si no los usas.» (The Xcode simulators are using a lot of processor; close them if you do not use them.)
- `cpu-busy` · fair · «El procesador va al máximo: \(group with the most CPU) es lo que más lo usa.» (The processor is at its maximum: … uses it the most.) (`cpu.total ≥ 85` in the last two)
Verdict: level = the worst; sentence = that of the first finding in this priority order: thermal-critical, thermal-throttling, memory, docker-vm, runaway, disk-images, family-syspolicyd, family-coreSimulator, family-spotlight, family-windowServer, cpu-busy; with no findings: good, «Tu Mac va bien.» (Your Mac is doing fine.). `system == nil` ⇒ no family rules (nothing is made up).

- [ ] **Step 1: Write the failing tests** (fake snapshots built by hand)

```swift
@Test func goodWhenNothingFires()                       // .good, "Tu Mac va bien."
@Test func familyNeedsTwoSustainedSamples() {
    // syspolicyd 30 % only in the last → no finding; 30 % and 26 % → family-syspolicyd; 24.9 % → nothing
}
@Test func spotlightFamilySumsWorkers()                 // mds_stores 15 + mdworker_shared 12 in both → fires
@Test func swapAndAvailableThresholds() {
    // swap 51 % → memory; swap exactly 50 % → nothing; available 14 % → memory; 15 % → nothing
}
@Test func memorySentenceNamesTopTwo() {
    #expect(v.sentence == "Tu Mac va justo de memoria: Google Chrome y Docker Desktop se llevan el 60 %.")
}
@Test func criticalPressureIsRed()                      // .critical → level .poor
@Test func dockerVMOnlyWithZeroContainers()             // 3 GiB and 0 → finding; 3 GiB and nil → nothing; 1 GiB and 0 → nothing
@Test func runawayNeedsAgeAndLifetimeCPU()              // 13 h and 30 % on average → yes; 11 h → no; 13 h and 20 % → no
@Test func diskImagesOnlyWithSyspolicyd()
@Test func thermalBeatsMemoryInSentence()               // both → thermal sentence, level the worst
@Test func noSystemListSkipsFamilies()                  // system nil with names that would fire → no family-*
@Test func probesAreCalledOnlyWhenNeeded() async        // FakeRunner: without large Docker or syspolicyd → 0 calls; 30 s cache
@Test func dockerProbeParsesCountAndFailure() async     // "abc\ndef\n" → 2; status 1 → nil; without docker → nil
```

- [ ] **Step 2: Run** — `swift test --filter DiagnosisTests` → FAIL.
- [ ] **Step 3: Implement** according to Interfaces.
- [ ] **Step 4: Run** — `swift test --filter DiagnosisTests` → PASS (13).
- [ ] **Step 5: Commit** — `feat: rule-based performance diagnosis with traffic light and sentence` (+ Co-Authored-By).

---

### Task 8: Quit funnel (`QuitExecutor`)

**Files:**
- Create: `Sources/DiskMapCore/Performance/QuitExecutor.swift`
- Test: `Tests/DiskMapCoreTests/QuitExecutorTests.swift` (with `FakeTerminator`; **no real process**)

**Interfaces:**
- Consumes: `QuitPolicy` (Task 6), `AppGroup` (Task 5), `OperationContext`, `OperationLog`, `OperationRecord` (plan 1 Tasks 7–8).
- Produces:
```swift
public protocol ProcessTerminating: Sendable {
    func requestQuit(pid: Int32, isApp: Bool) -> Bool   // app: NSRunningApplication(processIdentifier:)?.terminate(); stray: kill(pid, SIGTERM)
    func forceQuit(pid: Int32, isApp: Bool) -> Bool     // app: forceTerminate(); stray: kill(pid, SIGKILL)
    func isAlive(pid: Int32, startedAt: Date) -> Bool   // PROC_PIDTBSDINFO with the same start (±1 s): protects from a reused PID
}
public struct LiveTerminator: ProcessTerminating { public init() }
public enum QuitOutcome: Sendable, Equatable {
    case closed
    case didNotClose            // did not respond within `wait`: it can now be forced
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
Order in `quit`: agent context ⇒ `.blocked("Cerrar apps siempre lo decides tú en Airy.")` (Quitting apps is always your decision in Airy.); **new** `currentGroups()`: look for the group with the same `id`, `leadPID` and `leadStart` (if not ⇒ `.blocked("Ya no está abierta.")` (It is no longer open.)); `policy.eligibility` of the **current** group (never ⇒ `.blocked(reason)`); `requestQuit` only to the `leadPID` (helpers close with their app; a stray one is a single PID); wait, polling `isAlive` every `poll` up to `wait`: dead ⇒ `.closed`; alive ⇒ `.didNotClose` and `(leadPID, leadStart)` is stored in a `Mutex<Set>` of "does not respond". `forceQuit`: same checks and additionally requires `canForceQuit` (if not ⇒ `.blocked("Primero hay que intentar cerrarla normalmente.")` (First it must be tried to close it normally.)); `forceQuit` of the lead; `.closed` or `.failed("No se pudo forzar el cierre.")` (The quit could not be forced.). Each call adds an `OperationRecord` (`action` `quit_app`/`force_quit_app`, `itemID` = id, `title` = name, `paths: []`, `outcome` `closed`/`did_not_close`/`blocked`/`failed`, `bytes` = the group's memory, `proposedBy` from the context).

- [ ] **Step 1: Write the failing tests**

```swift
@Test func agentContextNeverQuits() async            // .blocked; terminator.calls empty; log agent actor, outcome "blocked"
@Test func normalQuitFirst() async                   // FakeTerminator dies when asked → .closed; calls == [.request(10, isApp: true)]
@Test func unresponsiveGivesDidNotCloseThenForce() async {
    // does not die: quit → .didNotClose (wait 0.3 s in the test); canForceQuit true; forceQuit → .closed; calls == [request, force]
}
@Test func forceWithoutPriorAttemptIsRefused() async // .blocked("Primero hay que intentar cerrarla normalmente."); no calls
@Test func pidReuseIsRefused() async                 // currentGroups returns the same pid with another leadStart → .blocked("Ya no está abierta."); no calls
@Test func revalidatesPolicyAtActTime() async        // the current group now has bundle com.apple.finder → .blocked; no calls
@Test func looseProcessUsesSignalPath() async        // kind .looseProcess → request(pid, isApp: false)
@Test func everyAttemptIsLogged() async              // closed, did_not_close, blocked → 3 records with correct action and outcome
@Test func quitCallsOnlyInQuitExecutor() throws {    // source: "forceTerminate(" and "kill(" with SIGTERM/SIGKILL only in
    // QuitExecutor.swift (and the already existing "terminate(" in CleanupFlow.swift and CommandRunner.swift)
}
```

- [ ] **Step 2: Run** — `swift test --filter QuitExecutorTests` → FAIL.
- [ ] **Step 3: Implement** according to Interfaces.
- [ ] **Step 4: Run** — `swift test --filter QuitExecutorTests` → PASS (9).
- [ ] **Step 5: Commit** — `feat: app quit funnel with normal quit first` (+ Co-Authored-By).

---

### Task 9: Broken startup items (report only)

**Files:**
- Create: `Sources/DiskMapCore/Performance/LoginItemsAudit.swift`
- Test: `Tests/DiskMapCoreTests/LoginItemsTests.swift` (temporary folders with plists)

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
    /// Reads each *.plist (≤ 1 MB) with PropertyListSerialization; program = Program ?? ProgramArguments[0];
    /// absolute paths only; if it is under /Volumes/<X> and /Volumes/<X> does not exist (unmounted disk) it does not count;
    /// broken if the program does not exist. Unreadable plists are skipped. Label = Label ?? file name without extension.
    public static func broken(in directories: [String], fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> [BrokenLoginItem]
}
```

- [ ] **Step 1: Write the failing tests**

```swift
@Test func reportsMissingProgram()               // Program /nope/x → 1 item with label and missingProgram "/nope/x"
@Test func usesFirstProgramArgument()            // ProgramArguments ["/nope/y", "--flag"]
@Test func existingProgramIsFine()               // /bin/ls → nothing
@Test func relativeProgramIgnored()              // "node" → nothing
@Test func unmountedVolumeIgnored()              // /Volumes/NoExiste/app → nothing
@Test func unreadablePlistSkipped()              // garbage bytes → nothing, no failure
@Test func auditNeverDeletes() throws            // the directory stays identical (names and bytes) after broken(in:)
```

- [ ] **Step 2: Run** — `swift test --filter LoginItemsTests` → FAIL.
- [ ] **Step 3: Implement** according to Interfaces.
- [ ] **Step 4: Run** — `swift test --filter LoginItemsTests` → PASS (7).
- [ ] **Step 5: Commit** — `feat: report of broken startup items` (+ Co-Authored-By).

---

### Task 10: Reversible maintenance in amber (catalog records + `MaintenanceScanner` + Spotlight)

**Files:**
- Create: `Sources/DiskMapCore/Maintenance/MaintenanceScanner.swift`, `Sources/DiskMapCore/Maintenance/SpotlightCheck.swift`
- Modify: `Sources/DiskMapCore/Catalog/Catalog.swift` (`CatalogEntry.section`, `Catalog.match` skips them), `Sources/DiskMapCore/Cleanup/CleanupScanner.swift` (skips them), `Sources/DiskMapCore/Resources/catalog.json` (8 records)
- Test: `Tests/DiskMapCoreTests/MaintenanceTests.swift`

**Interfaces:**
- Consumes: `CatalogEntry`, `CleanupItem`, `RiskClassifier`, `CommandRunning`, `CleanupExecutor.preview/execute` (plan 1 Task 8).
- Produces:
```swift
public enum CatalogSection: String, Codable, Sendable { case cleanup, maintenance }
// CatalogEntry gains `public var section: CatalogSection` (decodes as .cleanup by default; encoded only if .maintenance;
// parameter `section: CatalogSection = .cleanup` at the end of init)
public enum SpotlightDiagnosis: Sendable, Equatable { case fine(seconds: Double), slow(seconds: Double), disabled, unknown }
public struct SpotlightCheck: Sendable {
    public static let slowSeconds = 3.0
    public init(runner: any CommandRunning)
    /// /usr/bin/mdutil ["-s", "/"] (5 s): «disabled» ⇒ .disabled. Then twice
    /// /usr/bin/mdfind ["kMDItemFSName == 'Applications'"] (10 s each): both > 3 s (or deadline exhausted) ⇒ .slow(max);
    /// otherwise ⇒ .fine(max); execution failure ⇒ .unknown. Launched by the user with a button, never by itself.
    public func run() async -> SpotlightDiagnosis
}
public struct MaintenanceScanner: Sendable {
    public init(catalog: Catalog, runner: any CommandRunning, home: String, classifier: RiskClassifier?)
    /// Only records with `section == .maintenance` whose condition is met; risk from the classifier (never less than amber), preselected false.
    public func findItems(spotlight: SpotlightDiagnosis?, onACPower: Bool) async -> [CleanupItem]
}
```
`catalog.json` records (all `risk: "yourCall"`, `kind: "system"`, `regenerates: false`, `section: "maintenance"`, without `aggressiveRisk` or preselection; `explanation` says what it does and **how to undo it**):

| id | `cleanup` | Offered if (reads with `FakeRunner` in tests) |
|---|---|---|
| `maintenance-dsstore-network` | command `defaults` `["write","com.apple.desktopservices","DSDontWriteNetworkStores","-bool","true"]` | `defaults read com.apple.desktopservices DSDontWriteNetworkStores` ≠ `1` |
| `maintenance-dsstore-usb` | same with `DSDontWriteUSBStores` | same |
| `maintenance-legacy-appnap` | `defaults` `["delete","-g","NSAppSleepDisabled"]` | `defaults read -g NSAppSleepDisabled` == `1` |
| `maintenance-legacy-skipverify` | `defaults` `["delete","com.apple.frameworks.diskimages","skip-verify"]` | read == `1` |
| `maintenance-legacy-skipverify-locked` | same `skip-verify-locked` | read == `1` |
| `maintenance-legacy-skipverify-remote` | same `skip-verify-remote` | read == `1` |
| `maintenance-corrupt-plist` | `trash`, `paths: ["~/Library/Preferences/*.plist"]` | per file: name without the `com.apple.` prefix, ≤ 10 MB, `PropertyListSerialization` fails; id `maintenance-corrupt-plist:<name>` |
| `maintenance-spotlight-reindex` | command `osascript` `["-e","do shell script \"/usr/bin/mdutil -E /\" with administrator privileges"]` | `spotlight == .slow` **and** `onACPower` |

Exact text examples: dsstore-network title «No crear archivos .DS_Store en discos de red» (Do not create .DS_Store files on network disks), explanation «Evita que Finder deje archivos ocultos .DS_Store en carpetas compartidas. Se deshace con: defaults delete com.apple.desktopservices DSDontWriteNetworkStores.» (Prevents Finder from leaving hidden .DS_Store files in shared folders. Undone with: …); corrupt-plist title «Preferencias dañadas» (Damaged preferences), explanation «Este archivo de ajustes de una app está dañado y puede impedir que arranque. Va a la Papelera y la app crea uno nuevo; si algo falla, sácalo de la Papelera.» (This app settings file is damaged and may prevent it from starting. It goes to the Trash and the app creates a new one; if anything fails, take it out of the Trash.); spotlight-reindex title «Reindexar Spotlight» (Reindex Spotlight), explanation «Spotlight tarda en buscar. Reindexar lo rehace desde cero: pedirá la contraseña de administrador y durante 1–2 horas el Mac irá algo más cargado.» (Spotlight is slow to search. Reindexing rebuilds it from scratch: it will ask for the administrator password and for 1–2 hours the Mac will be somewhat more loaded.)

- [ ] **Step 1: Write the failing tests**

```swift
@Test func maintenanceEntriesAreAmberAndNeverPreselected() throws   // real catalog: the 8, yourCall, section .maintenance
@Test func cleanupScannerIgnoresMaintenance() async                 // Cleanup's findItems never returns ids "maintenance-*"
@Test func catalogMatchIgnoresMaintenance() throws                  // match(home/Library/Preferences/x.plist) is not maintenance-corrupt-plist
@Test func dsStoreOfferedOnlyWhenNotSet() async                     // read → "1" ⇒ no; status 1 (missing key) ⇒ yes
@Test func legacyDefaultsOfferedOnlyWhenHarmful() async             // "1" ⇒ yes; "0" or missing ⇒ no
@Test func corruptPlistDetectedButAppleAndValidSkipped() async      // tmp home: bad.plist garbage ⇒ item; com.apple.bad.plist ⇒ no; ok.plist ⇒ no
@Test func spotlightOnlyAfterSlowDiagnosisOnAC() async              // nil / .fine / .slow without AC ⇒ no; .slow + AC ⇒ yes
@Test func spotlightCheckTiming() async                             // FakeRunner with delays 3.5 s and 4 s ⇒ .slow; 0.1 s ⇒ .fine; "disabled" ⇒ .disabled
@Test func scannerOnlyReads() async                                 // runner.calls only contains "read", "-s" or mdfind queries; never write/delete/osascript
@Test func maintenanceExecutesThroughFunnel() async {               // CleanupExecutor with FakeRunner: execute(dsstore item) ⇒
    // runner called with ("/usr/bin/defaults", ["write", …, "-bool", "true"]); record in OperationLog
    // execute(corrupt-plist item) ⇒ the temporary file goes to the Trash (plan 1 funnel); preview executes nothing
}
@Test func agentCannotRunMaintenance() async                        // .agent context ⇒ .blocked (amber); runner without calls
```

- [ ] **Step 2: Run** — `swift test --filter MaintenanceTests` → FAIL.
- [ ] **Step 3: Implement** according to Interfaces.
- [ ] **Step 4: Run** — `swift test 2>&1 | tail -3` → all green (the existing catalog and Cleanup tests keep passing).
- [ ] **Step 5: Commit** — `feat: reversible amber maintenance through the cleanup funnel` (+ Co-Authored-By).

---

### Task 11: «¿Por qué va lento?» AI (numbers and names only)

**Files:**
- Create: `Sources/DiskMapCore/Performance/PerformanceAIContext.swift`
- Modify: `Sources/DiskMapCore/AI/AIAssistant.swift` (extract `chat`'s streaming loop into a reused `private func streamResponse(arguments:prompt:)`; add `explainSlowness`)
- Test: `Tests/DiskMapCoreTests/PerformanceAITests.swift` (with `AIFakeRunner` from `AITests.swift`)

**Interfaces:**
- Produces:
```swift
public enum PerformanceAIContext {
    /// JSON with sorted keys: memory {total_gb, used_gb, file_cache_gb, pressure, swap_used_gb, swap_total_gb},
    /// thermal {state, throttling}, cpu {total_percent}, apps [{name, memory_mb, cpu_percent, processes}] (the 10 with the most impact,
    /// `name` = AppGroup.name; never detail, bundlePath, bundleID, pids or paths), findings [sentence].
    public static func build(_ snapshot: PerformanceSnapshot, verdict: HealthVerdict) -> String
}
extension AIAssistant {
    static let performanceSystemPrompt: String
    public func explainSlowness(context: String) -> AsyncThrowingStream<String, Error>
}
```
`performanceSystemPrompt` (exact): «Eres el asistente de Airy, una app de macOS. Solo ves números de memoria, procesador y temperatura y los nombres de las apps abiertas, nunca archivos ni contenido. Explica en español de España, en pocas frases sencillas, por qué este Mac puede ir lento y qué apps convendría cerrar. No recomiendes «liberar RAM», `purge` ni cerrar procesos del sistema, y no puedes hacer nada tú mismo: el usuario cierra las apps desde Rendimiento.» (You are the assistant of Airy, a macOS app. You only see memory, processor and temperature numbers and the names of open apps, never files or content. Explain in Spanish (Spain), in a few simple sentences, why this Mac may be slow and which apps it would be good to close. Do not recommend «liberar RAM» (free RAM), `purge` nor quitting system processes, and you cannot do anything yourself: the user quits the apps from Performance.) Arguments = `arguments(systemPrompt:)` + `["--output-format","stream-json","--verbose","--include-partial-messages"]`; prompt: «Estado del Mac (JSON, solo números y nombres de apps):\n\(context)\n\n¿Por qué puede ir lento y qué haría?» (State of the Mac (JSON, numbers and app names only): … Why may it be slow and what would you do?).

- [ ] **Step 1: Write the failing tests**

```swift
@Test func contextHasOnlyNumbersAndNames() {
    // node group with detail "proyecto-secreto" (secret project), bundlePath "/Applications/X.app", pid 4242
    let json = PerformanceAIContext.build(snapshot, verdict: verdict)
    #expect(!json.contains("/") && !json.contains("proyecto-secreto") && !json.contains("4242"))
    #expect(json.contains("\"name\":\"node\""))
}
@Test func contextLimitsToTenApps()
@Test func explainSlownessUsesClosedInvocation() async {
    // AIFakeRunner: arguments contain "--tools", "", "--setting-sources", "", "--strict-mcp-config" and the performance prompt;
    // stdin contains the context; the stream's text arrives whole
}
@Test func chatStillWorksAfterRefactor() async      // the existing chat test in AITests keeps passing (run the suite)
```

- [ ] **Step 2: Run** — `swift test --filter PerformanceAITests` → FAIL.
- [ ] **Step 3: Implement** according to Interfaces.
- [ ] **Step 4: Run** — `swift test --filter "PerformanceAITests|AITests"` → PASS.
- [ ] **Step 5: Commit** — `feat: «¿Por qué va lento?» with Claude's closed invocation` (+ Co-Authored-By).

---

### Task 12: MCP `get_performance` and `propose_quit_app` (+ `airy://quit`)

**Files:**
- Create: `Sources/DiskMapCore/MCP/Tools/PerformanceTools.swift`
- Modify: `Sources/DiskMapCore/Integration/AiryURL.swift` (`proposeQuit` case), `Sources/DiskMapCore/MCP/AiryEnvironment.swift` (`sampler` field), `MCPToolRegistry.standard()` (11 tools), `Tests/DiskMapCoreTests/MCPActionToolTests.swift` (`registryHasExactlyNineToolsAndNoArbitraryInput` becomes `…ElevenTools…` with the two new names), `Tests/DiskMapCoreTests/AiryURLTests.swift`
- Test: `Tests/DiskMapCoreTests/MCPPerformanceToolTests.swift`

**Interfaces:**
- Consumes: `MCPTool`, `MCPToolResult`, `MCPCallContext`, `AiryEnvironment`, `AgentGate.refusal`, `URLOpening`, `AiryURLCommand` (plan 1 Tasks 10–13); `PerformanceMonitor.measureOnce`, `verdict`, `AppGrouper`, `QuitPolicy`, `DiagnosisProbes`.
- Produces:
```swift
// AiryURLCommand gains:
case proposeQuit(app: String, reason: String, agent: String?)
// form airy://quit?app=<a>&reason=<r>&agent=<g>; app: 1…maxItemID (200), without control characters; reason/agent sanitized as in propose
// AiryEnvironment gains `public let sampler: any PerformanceSampling` and `public let appCatalog: AppCatalog?`
// (parameters `sampler: any PerformanceSampling = LiveSampler(), appCatalog: AppCatalog? = try? AppCatalog.bundled()`
// at the end of the memberwise init; live() passes LiveSampler(runner: runner))
public struct GetPerformanceTool: MCPTool { public init(interval: Duration = .seconds(1)) }       // "get_performance"
public struct ProposeQuitAppTool: MCPTool { public init() }                                       // "propose_quit_app"
```

| Tool | Input | Behavior and output (`structured`) |
|---|---|---|
| `get_performance` | `{}` | Read-only (`readOnly: true, destructive: false, idempotent: true`), without `AgentGate`; works with the app closed: `PerformanceMonitor(sampler: env.sampler, grouper: AppGrouper…)`, `refresh()`, waits `interval`, `refresh()` and `verdict(probes: DiagnosisProbes(runner: env.runner))` (only measures during the call). Output: `health {level: good\|fair\|poor, light: green\|amber\|red, sentence}`, `findings [{id, sentence}]`, `memory {total_bytes, used_bytes, free_bytes, file_cache_bytes, available_bytes, pressure: normal\|warning\|critical\|null, swap_used_bytes, swap_total_bytes}`, `thermal {state, label, throttling}`, `cpu {total_percent, performance_percent, efficiency_percent, performance_cores, efficiency_cores}`, `top_by_memory` and `top_by_cpu` (5 each) `[{name, bundle_id, memory_bytes, cpu_percent, process_count, closable, risk}]` (`closable` = `QuitPolicy.eligibility.isAllowed`, `risk` = `safe\|yourCall\|null`), `battery {percent, charging, cycle_count, health_percent} \| null`, `uptime_seconds`, `zombie_count`. Text: the health sentence. Never paths, PIDs, arguments or `detail`. |
| `propose_quit_app` | `app` required (string 1…200), `reason?` (≤ 500), `dry_run?` (false) | `AgentGate` first (off or unreadable ⇒ its error, nothing opened). One sample and `AppGrouper.group`; case-insensitive exact match with `bundleID` or `name` (several ⇒ the one with the most memory); no match ⇒ error «No hay ninguna app abierta llamada «\(app)».» (There is no open app called «…».); `never(m)` ⇒ error ««\(name)» no se puede cerrar desde Airy: \(m)» («…» cannot be quit from Airy: …). Otherwise URL `AiryURLCommand.proposeQuit(app: bundleID ?? name, reason:, agent: client).url`; `dry_run` returns it without opening it; opening fails ⇒ «No se pudo abrir Airy (¿está instalada en /Applications?).» (Airy could not be opened (is it installed in /Applications?).). Output `{status: "pending_user_confirmation", app, risk, url, message: "Propuesta enviada a Airy; el usuario decide si la cierra. Airy nunca cierra apps por su cuenta."}` (Proposal sent to Airy; the user decides whether to quit it. Airy never quits apps by itself.). `OperationRecord` with agent actor, `action "propose_quit"`, `outcome "pending_user"` (or `blocked`). Annotations `readOnly: false, destructive: false`. |

Tool descriptions (Spanish): `get_performance` «Estado del Mac ahora: memoria, presión, swap, temperatura (sin grados), procesador y las apps que más pesan, con una frase de diagnóstico. Solo lectura; mide durante 1 s.» (State of the Mac now: memory, pressure, swap, temperature (no degrees), processor and the apps that weigh the most, with a diagnosis sentence. Read-only; measures for 1 s.); `propose_quit_app` «Propone al usuario cerrar una app abierta: abre Airy con la confirmación preparada. Nunca cierra nada; el usuario decide en la app.» (Proposes to the user to quit an open app: opens Airy with the confirmation prepared. It never quits anything; the user decides in the app.)

- [ ] **Step 1: Write the failing tests** (`FakeSampler` with two samples, `FakeOpener`, plan 1's temporary environment `makeTestEnvironment(home:)` with `sampler:`)

```swift
@Test func getPerformanceSamplesItselfAndReportsHealth() async   // calls == 2; health.sentence == verdict; memory.total_bytes correct
@Test func getPerformanceNeverLeaksPathsOrArgs() async           // detail "proyecto-secreto", paths and pid absent from the text and the JSON
@Test func getPerformanceMarksNeverClosable() async              // Finder closable false; Spotify true risk "safe"; node risk "yourCall"
@Test func getPerformanceWorksWithToggleOff() async              // agentsEnabled false ⇒ it still responds (read-only)
@Test func proposeQuitOpensURLAndNeverQuits() async {
    #expect(opener.urls == [URL(string: "airy://quit?app=com.spotify.client&reason=pesa&agent=test-client")!])
    // FakeTerminator is not used on any path of the tool; record "propose_quit" / "pending_user"
}
@Test func proposeQuitRefusesNeverClosableUnknownAndToggleOff() async {
    // "Finder", "airy-mcp", "Airy", "NoExiste", switch off, unreadable settings ⇒ isError and opener.urls empty
}
@Test func proposeQuitDryRunDoesNotOpen() async
@Test func proposeQuitPicksBiggestOnAmbiguousName() async
@Test func quitURLRoundTripsAndRejectsHostile() {                 // in AiryURLTests: round trip; empty app, with "\n" or of 201 ⇒ nil
}
@Test func registryHasExactlyElevenToolsAndNoArbitraryInput()     // + "get_performance", "propose_quit_app"; "app" only in propose_quit_app
```

- [ ] **Step 2: Run** — `swift test --filter "MCPPerformanceToolTests|AiryURLTests|MCPActionToolTests"` → FAIL.
- [ ] **Step 3: Implement** according to Interfaces.
- [ ] **Step 4: Verify** — `swift test 2>&1 | tail -3` → green. Against the real system, read-only: `swift build && printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"prueba","version":"1"}}}' '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"get_performance","arguments":{}}}' | AIRY_SUPPORT_DIR=$(mktemp -d) .build/debug/airy-mcp` → two JSON lines; the second with `health.sentence` and `memory.total_bytes > 0`. **Do not** call `propose_quit_app` without `dry_run: true` against the real system.
- [ ] **Step 5: Commit** — `feat: get_performance and propose_quit_app MCP tools` (+ Co-Authored-By).

---

### Task 13: Performance section: visible-only sampling, board and cards

**Files:**
- Create: `Sources/DiskMapCore/UIState/PerformanceBoard.swift`; `Sources/Airy/Performance/PerformanceSession.swift`, `PerformanceView.swift`, `MemoryThermalCards.swift`, `HeavyAppsList.swift`, `ExtrasCard.swift`
- Modify: `Sources/Airy/AppModel.swift` (`Section.performance` available between Cleanup and AI Assistant: title «Rendimiento» (Performance), symbol `gauge.with.dots.needle.67percent`; `let performance = PerformanceSession()`), `Sources/Airy/Shell/RootView.swift` (Performance is shown even if there is no disk analysis or analysis error: the progress `hero` and `ScanErrorView` only cover the sections that depend on the disk)
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
    public var rows: [PerformanceRow]            // .app, .looseProcess and .background by impact desc, up to limit; .system never
    public var topByCPU: [AppGroup]              // 5, cpuPercent desc (without nil)
    public var topByEnergy: [AppGroup]           // 5, energy desc (without nil)
    public static func canSelect(_ row: PerformanceRow) -> Bool          // eligibility.isAllowed
    public func selected(_ ids: Set<String>) -> [PerformanceRow]          // only rows that still exist and canSelect
    /// Agent proposal: row by bundle id or name (case-insensitive); nil without a snapshot or without a match.
    public func row(matching app: String) -> PerformanceRow?
}
// app
@MainActor @Observable final class PerformanceSession {
    static let interval: Duration = .milliseconds(1500)
    private(set) var snapshot: PerformanceSnapshot?
    private(set) var verdict: HealthVerdict?
    private(set) var board: PerformanceBoard
    var selection: Set<String>
    private(set) var unresponsive: Set<String>       // ids with .didNotClose
    private(set) var leaving: Set<String>            // ids flying off (animation)
    private(set) var loginItems: [BrokenLoginItem]
    private(set) var maintenance: [CleanupItem]
    private(set) var spotlight: SpotlightDiagnosis?
    let monitor: PerformanceMonitor                   // LiveSampler + AppGrouper.group with AppCatalog.bundled()
    func start()        // idempotent: a single Task { while !cancelled { refresh; verdict; sleep(interval) } }
    func stop()         // cancels the Task and monitor.reset(); no measurement afterwards
    func firstSnapshot() async -> PerformanceSnapshot   // waits for the first one (for airy://quit)
}
```
Lifecycle (lightness): `PerformanceView` calls `start()` in `onAppear` and `stop()` in `onDisappear`; it also listens to `NSWindow.didChangeOcclusionStateNotification`, `didMiniaturizeNotification`/`didDeminiaturizeNotification` and `NSApplication.didHideNotification`/`didUnhideNotification` of its window: not visible ⇒ `stop()`, visible again ⇒ `start()`. Startup items and maintenance are read on appearing and after each action (not on every sample).
Content (exact texts):
- Header: `WindSwirl(speed: WindMotion.swirlRevolutionsPerSecond(cpuLoad: (snapshot.cpu?.total ?? 0) / 100), tint: Theme.Airy.swirlTint(snapshot.thermal.level.processInfoState))` (plan 2: faster with more CPU, from blue to orange with the Mac hot; with «Reducir movimiento» it stays still and the tint fades; it pauses only with `airyAmbientMotion`), the verdict sentence in large type and a traffic light (`Theme.Airy.riskFill(.safe/.yourCall/.doNotTouch)` = green «Va bien» (Doing fine), amber «Atención» (Attention), red «Problema» (Problem)); below, the other findings in a short list.
- Memory: used / file cache / free bar with figures; «Presión de memoria» (Memory pressure) with pill Normal (green) / Alta (High) (amber) / Crítica (Critical) (red) / «—»; «Swap: \(used) de \(total)». Help texts: pressure «La presión de memoria dice si a macOS le cuesta encontrar memoria libre. En verde va sobrado; en ámbar empieza a comprimir y a usar el disco; en rojo, las apps irán lentas.» (Memory pressure says whether macOS has trouble finding free memory. In green it has plenty; in amber it starts compressing and using the disk; in red, apps will be slow.); swap «La swap es memoria que macOS guarda temporalmente en el disco cuando no cabe todo en la RAM. Crece cuando abres muchas cosas a la vez y no baja sola hasta que cierras apps o reinicias; un poco es normal, mucha hace que todo vaya más lento.» (Swap is memory that macOS temporarily stores on the disk when not everything fits in RAM. It grows when you open many things at once and does not go down by itself until you close apps or restart; a little is normal, a lot makes everything slower.); cache «Archivos que macOS guarda en memoria para abrirlos antes; la suelta en cuanto otra app la necesita.» (Files that macOS keeps in memory to open them sooner; it releases it as soon as another app needs it.); footer «Airy no tiene botón de «liberar RAM»: macOS ya gestiona la memoria y esos botones no ayudan. Lo que alivia de verdad es cerrar lo que más consume.» (Airy has no «free RAM» button: macOS already manages memory and such buttons do not help. What really relieves it is closing what consumes the most.)
- Temperature: «Temperatura: \(label)» (Temperature: …) and «macOS ha bajado la velocidad para enfriarlo.» (macOS has slowed down to cool it.) / «Sin reducción de velocidad.» (No slowdown.); help «Airy no muestra grados: leerlos exige interfaces privadas de Apple que pueden romperse.» (Airy does not show degrees: reading them requires private Apple interfaces that may break.)
- CPU and energy: total and P/E, `topByCPU` and `topByEnergy` (relative bars, without watts).
- «Lo que más pesa»: rows of `board.rows` with the app's icon, name (+ «· \(detail)» on stray ones), catalog explanation, memory, CPU, number of processes («Chrome · 23 procesos» (Chrome · 23 processes)), `RiskBadge(risk:)` (green app / amber stray with `QuitPolicy.looseWarning`), checkbox and a «Cerrar» (Quit) button only if `canSelect`; the `never` ones show the reason and no control. Selection bar: «Cerrar seleccionadas (n)» (Quit selected (n)). Row in `unresponsive`: «No responde» (Not responding) + button «Forzar cierre…» (Force quit…).
- Extras: battery «\(percent) % · \(cycles) ciclos · salud \(health) %» (… cycles · health …) (or «Sin batería» (No battery)); «Disco: lee \(x)/s · escribe \(y)/s» (Disk: reads … · writes …); «Red: baja \(x)/s · sube \(y)/s» (Network: down … · up …); «Encendido desde hace \(…)» (Powered on for …); zombies «Procesos zombi: \(n)» (Zombie processes: n) with the parents and help «Procesos ya terminados que su programa no ha recogido; no gastan recursos, pero muchos indican un programa con fallos.» (Already terminated processes that their program has not collected; they use no resources, but many indicate a faulty program.); «—» for any `nil`.

- [ ] **Step 1: Write the failing tests** (core)

```swift
@Test func rowsSortedAndLimited()                     // 15 groups → 12 rows by impact; .system never appears in rows
@Test func neverRowsHaveNoCheckbox()                  // Finder: canSelect false; selected(["finder-id"]) empty
@Test func selectionDropsVanishedRows()               // ids of a group that is no longer there → out
@Test func topByCPUSkipsUnknown()                     // cpuPercent nil does not enter
@Test func boardResolvesProposalOnlyWithSnapshot()    // snapshot nil → row(matching:) nil; with snapshot → by bundle id and by name
@Test func thermalLevelMapsToProcessInfo()             // .serious.processInfoState == .serious (all four)
```

- [ ] **Step 2: Run** — `swift test --filter PerformanceBoardTests` → FAIL.
- [ ] **Step 3: Implement** the board (core) and then the session and the views according to Interfaces.
- [ ] **Step 4: Verify** — `swift build && swift test 2>&1 | tail -3` → green. Manual: `AIRY_SUPPORT_DIR=$(mktemp -d) .build/debug/Airy &` (save `$!`): choose Performance **while it is still analyzing the disk** ⇒ the section appears and the figures change every ~1.5 s; go to Map and in Activity Monitor check that Airy's %CPU goes back to ~0; minimize the window with Performance open ⇒ ~0 %; Finder/Dock come out without checkbox or «Cerrar». Stop with `kill <PID>`.
- [ ] **Step 5: Commit** — `feat: Performance section with visible-only sampling` (+ Co-Authored-By).

---

### Task 14: Quitting from the app, `airy://quit` proposals, maintenance, startup, AI and animations

**Files:**
- Create: `Sources/Airy/Performance/MaintenanceCard.swift`, `Sources/Airy/Performance/SlowAISheet.swift`
- Modify: `Sources/Airy/Cleanup/CleanupFlow.swift` (`Kind.quitApps([AppGroup])`, `Kind.forceQuitApps([AppGroup])`, `requestQuit`, `requestForceQuit`, sequential execution), `Sources/Airy/Cleanup/ConfirmSheet.swift` (the two variants), `Sources/Airy/AppModel.swift` (`quitExecutor`, `quit`, `forceQuit`, `handle(url:)` for `.proposeQuit`, `Notice.Kind.performance`), `Sources/Airy/Performance/HeavyAppsList.swift` (leaves when leaving), `Sources/Airy/Performance/PerformanceView.swift`

**Interfaces:**
- Consumes: Tasks 6, 8, 9, 10, 11, 13; `CleanupFlow.ConfirmRequest.Warning`, `requestClean` and `perform(_:context:)` (plan 1 Tasks 9–10).
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
func markClosed(_ id: String)       // adds to leaving (animates) and removes it from selection
func markUnresponsive(_ id: String)
func refreshMaintenance() async     // MaintenanceScanner + LoginItemsAudit
func checkSpotlight() async         // SpotlightCheck.run() and refreshMaintenance
```
Quit confirmation (exact texts): title «¿Cerrar \(name)?» (Quit …?) or «¿Cerrar \(n) apps?» (Quit n apps?); rows with name, memory and number of processes; the amber ones in a separate block with header «Revisa: puede que estés usándolo» (Review: you may be using it) and `QuitPolicy.looseWarning`; note «Primero se pide a cada app que se cierre; si tiene algo sin guardar, te lo preguntará.» (First each app is asked to quit; if it has anything unsaved, it will ask you.); button «Cerrar». Force: title «¿Forzar el cierre de \(name)?» (Force quit …?), note «No respondió al cierre normal. Se perderá lo que no esté guardado.» (It did not respond to the normal quit. Anything not saved will be lost.), button «Forzar cierre» (destructive role; Return does not confirm). On confirming: sequence with `.user(runID: batch, proposedBy:)`; `.closed` ⇒ `markClosed` (the row leaves the list with plan 2's `.transition(.leafAway)`: it flies off like a leaf and breaks apart into leaves; with «Reducir movimiento» plan 2 itself changes it to a fade); `.didNotClose` ⇒ `markUnresponsive`; `.blocked`/`.failed` ⇒ message on the row. «Forzar» is never chained without a second confirmation.
`handle(url:)` with `.proposeQuit(app, reason, agent)`: Performance section; `await performance.firstSnapshot()`; `board.row(matching:)`: nil ⇒ `.performance` notice «Un agente propuso cerrar «\(app)», pero no está abierta.» (An agent proposed quitting «…», but it is not open.); `never` ⇒ «Un agente propuso cerrar «\(name)», pero Airy nunca la cierra.» (An agent proposed quitting «…», but Airy never quits it.); `flow.isBusy` ⇒ «Airy está ocupada; vuelve a pedirlo en un momento.» (Airy is busy; ask again in a moment.); otherwise `flow.requestQuit([group], warning: Warning(title: "Un agente propone cerrar esto", subtitle: "\(agent ?? "Un agente") · \(reason.isEmpty ? "sin motivo" : reason)", reason: "Nada se cierra hasta que lo confirmes aquí.", note: "Si tiene algo sin guardar, la app te lo preguntará."), proposedBy: agent)` (title: An agent proposes quitting this; reason: Nothing is quit until you confirm it here; note: If it has anything unsaved, the app will ask you).
«Mantenimiento» (Maintenance) card (`MaintenanceCard`): rows of `session.maintenance` with `RiskBadge(.yourCall)`, title, explanation and an «Aplicar…» (Apply…) button ⇒ `flow.requestClean([item])` (plan 1 funnel); command result: «Hecho» (Done) (not «0 kB liberados» (0 kB freed)); «Comprobar Spotlight» (Check Spotlight) button (shows «Midiendo…» (Measuring…); results «Spotlight responde bien (\(s) s).» (Spotlight responds well), «Spotlight tarda \(s) s en buscar.» (Spotlight takes … s to search.) + «Conecta el cargador para poder reindexar.» (Connect the charger to be able to reindex.) if there is no power, «Spotlight está desactivado en este disco.» (Spotlight is disabled on this disk.), «No se pudo medir Spotlight.» (Spotlight could not be measured.)); empty: «Nada que ajustar.» (Nothing to adjust.). «Elementos de inicio rotos» (Broken startup items) block: list (label and «Falta: \(program)» (Missing: …)) with «Abrir Ajustes de elementos de inicio» (Open Login Items settings) (`NSWorkspace.shared.open(LoginItemsAudit.settingsURL)`), footer «Airy solo avisa; quítalos tú en Ajustes del Sistema.» (Airy only warns; remove them yourself in System Settings.); empty: «Ningún elemento de inicio roto.» (No broken startup items.).
«¿Por qué va lento?» (button in the header, only if `model.assistant` has Claude located; otherwise hidden): `SlowAISheet` shows «Se envía a Claude solo esto:» (Only this is sent to Claude:) with the collapsible JSON from `PerformanceAIContext.build`, and the streaming answer of `explainSlowness`; «Cerrar» cancels the stream.

- [ ] **Step 1: Check that the core pieces are green** — `swift test --filter "QuitExecutorTests|PerformanceBoardTests|MaintenanceTests|PerformanceAITests"` → PASS (this task is interface wiring; its logic is already tested).
- [ ] **Step 2: Implement** the wiring and the views according to Interfaces.
- [ ] **Step 3: Build** — `swift build 2>&1 | tail -3` → no errors or new warnings.
- [ ] **Step 4: Manual verification with own test apps** (never close the user's apps): `AIRY_SUPPORT_DIR=$(mktemp -d) .build/debug/Airy &` (save `$!` as `AIRY`); open `open -n -a TextEdit` and create a document with unsaved text; in another terminal `python3 -m http.server 8765 &` (save `$!` as `PY`).
  1. Performance ⇒ TextEdit in green with «Cerrar»; `python3` in amber with «· folder»; Finder, Dock and Airy without controls.
  2. «Cerrar» TextEdit ⇒ confirmation sheet ⇒ «Cerrar» ⇒ TextEdit asks whether to save (normal quit): press **Cancel** in TextEdit ⇒ after 10 s the row says «No responde» with «Forzar cierre…»; press «Forzar cierre…» ⇒ second sheet ⇒ **Cancel** (do not force). Close TextEdit by hand without saving.
  3. Select `python3` ⇒ «Cerrar seleccionadas (1)» ⇒ the amber block «Revisa: puede que estés usándolo» ⇒ confirm ⇒ the row flies off in leaves; `kill -0 $PY` fails (closed by SIGTERM).
  4. Maintenance: «Comprobar Spotlight» shows a result; do **not** press «Aplicar…» on any record (only open the sheet and Cancel).
  5. With the app closed (`kill $AIRY`): `bash scripts/build-app.sh && open 'airy://quit?app=com.apple.TextEdit&reason=prueba&agent=manual'` after opening TextEdit again ⇒ Airy starts on Performance and shows «Un agente propone cerrar esto» ⇒ **Cancel**. `open 'airy://quit?app=Finder&reason=x&agent=manual'` ⇒ notice «…pero Airy nunca la cierra.».
  6. «¿Por qué va lento?» (if Claude is installed): the collapsible shows only numbers and names; an answer arrives.
  7. «Reducir movimiento» enabled in System Settings ⇒ swirl still and rows with a fade. Stop everything by killing only the saved PIDs (Airy by its PID; TextEdit with ⌘Q).
- [ ] **Step 5: Run full suite** — `swift test 2>&1 | tail -3` → all green.
- [ ] **Step 6: Commit** — `feat: quit apps from Performance, agent proposals, maintenance and AI` (+ Co-Authored-By).
