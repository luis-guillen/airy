# Airy 3b — Instalaciones duplicadas de desarrollo · Plan de implementación

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Limpieza detecta varias versiones instaladas de la misma herramienta de desarrollo (Python, Node, Ruby, Java, Rust, Go, entornos de conda) y propone quitar las que sobran. Las que están en uso salen en rojo. Las demás salen en ámbar y nunca en verde. Se quitan con el comando oficial de su gestor como array de argumentos, o a la Papelera si el gestor no tiene comando. También se añaden filas informativas para Xcode duplicado, instalaciones del sistema y `node_modules` repetidos.

**Architecture:** todo vive en `DiskMapCore`, sobre el núcleo del plan 3 (rama `fase-2-limpieza`):
- **Inventario y uso.** Un inventario de solo lectura del sistema de archivos (`ToolchainInventory`) y un detector de uso (`ToolchainUsage`: versión por defecto, PATH, pins de proyecto) se calculan **una vez por detección** en un memo de `DiscoveryContext`. El memo tiene presupuesto de tiempo.
- **Fuente de objetivos.** `ToolchainSource` es la fuente de `CleanupTargets.source(for:)` para las fichas `discovery {"type":"toolchains","manager":…}`. Hay una ficha por gestor, porque cada gestor tiene su propio método de limpieza. La misma regla sirve en `discover` y en `revalidate`.
- **Proyectos.** Los pins de proyecto se leen de las raíces de proyecto del paseo compartido de `ProjectArtifactSource`, que se amplía para memorizar también la lista de proyectos.
- **Interfaz.** No hay vista nueva. Las filas salen en el tablero del plan 3 (`CleanupBoard`, «Solo revisar» para `info`).

**Tech Stack:** Swift 6.4 (solo Command Line Tools), SwiftPM, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-10-20-airy-fase-2-design.md` §2.5b (y §2.4 etiquetas, §2.5 raíces de proyectos, §2.9 presupuestos y fallo cerrado). Anti-objetivos: `docs/superpowers/specs/2026-10-20-diskmap-design.md` §4. Código base: plan 3 (`docs/superpowers/plans/2026-10-20-airy-3-limpieza-agresiva-perfil.md`, ya implementado en `fase-2-limpieza`): `CleanupTargetSource`, `DiscoveryContext`, `DiscoveredTarget` (`floor`, `floorReason`, `blockedReason`, `preselectable`, `targets`), `{target}` (los objetivos que son rutas pasan por `PathGate` sin su ficha y se revalidan con `confirmUnchanged` al actuar), `CommandPolicy.refusal`, `CleanupExecutor.commandWorkingDirectory == "/"`, `ProjectArtifactSource`/`ProjectWalkMemo`, `RiskClassifier` con modo Agresivo/Prudente.

**Decisión del usuario:** sin perfil de uso. La preselección depende **solo** del riesgo y del modo. Las fichas nuevas llevan `profiles: []`.

**Fuera de este plan:** desinstalar Xcode (Desinstalador, plan 5); runtimes de simulador (ya en el plan 3, `SimulatorRuntimeSource`); copias idénticas de modelos de IA (Duplicados, plan 5); virtualenvs duplicados (R5).

## Global Constraints

- Swift 6.4, SwiftPM, solo Command Line Tools; `swift build` / `swift test`; `.macOS(.v15)`; el test target conserva las `unsafeFlags` del plugin de Swift Testing.
- Interfaz en **español de España**; nombres de herramientas y campos MCP en inglés.
- **Nunca** se envía contenido de archivos a la IA ni al MCP. Solo se envían metadatos (rutas, tamaños, fechas, nombres y versiones). Leer `.nvmrc`, `package.json` (`name`/`version`) o `settings.toml` es local y no sale de Airy.
- Ubicaciones protegidas, nunca borrables: volúmenes de Docker, iCloud, Mail, Mensajes, Llaveros, AddressBook, Calendarios, Fotos, `/Applications`, `/Library`, `/usr`, `/bin`, `/sbin`, `/private`, `/opt/homebrew`, `/System`. Las carpetas personales nunca son verdes. **Los runtimes en uso nunca se tocan.**
- Toda acción destructiva pasa por `ConfirmSheet` → `AppModel` → `CleanupExecutor` (embudo). Sin atajos DEBUG que actúen sin confirmación.
- La IA solo sube el riesgo. Sin perfil (decisión del usuario).
- El MCP solo ejecuta lo verde no bloqueado, nunca ámbar ni rojo. Con el interruptor apagado, toda acción queda bloqueada. Estas filas son siempre ámbar o rojas: el MCP **solo las lista** (`list_cleanup_items`).
- Comandos oficiales **siempre como array de argumentos** (nunca `sh -c` ni cadena de shell), ejecutados con `workingDirectory "/"` del embudo. `nvm`, `sdk` y `rvm` son funciones de shell y **nunca** se invocan.
- Sondas de solo lectura, con presupuesto de tiempo y fallo cerrado: lo que no se pudo comprobar no se preselecciona; al actuar, se bloquea.
- En pruebas y verificación nunca se ejecutan comandos de limpieza reales ni se vacía la Papelera real. Se usan `FakeRunner`, `FakeListing`, carpetas temporales y `AIRY_SUPPORT_DIR` propio. Contra el sistema real solo lectura y `dry_run: true`.
- Cero CPU en reposo: inventario, `brew uses` y paseo de proyectos solo durante una detección o justo antes de actuar. Nada en segundo plano.
- Capturas DEBUG solo de ventanas propias. Parar la app matando solo su PID (nunca `pkill -x`). No tocar la confianza del Llavero.
- Mole es GPL-3.0: solo ideas, nunca código.
- Commits terminan con `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

1. **El usuario cambia la versión por defecto (o crea un `.nvmrc`) entre la detección y «Borrar todo».** La versión que ahora se usa se rechaza al actuar con el motivo nuevo y no se ejecuta nada. Test en Task 3 (`defaultChangedAfterDetectionIsRefused`).
2. **Un pin que no se puede resolver** (`lts/*`, `node`, `system`, `stable` sin toolchain con ese canal) o un `alias default` roto. Nada de ese lenguaje se preselecciona, y si el default no se resuelve, la versión más alta de ese gestor cuenta como por defecto (roja). Test en Task 2 (`unresolvablePinsAreConservative`).
3. **`brew uses --installed` tarda, falla o lista dependientes.** La fórmula sale roja («Lo necesita Homebrew para: …») o bloqueada, nunca preselectable. Además, `brew uninstall` nunca lleva `--ignore-dependencies`. Test en Task 3 (`brewDependentsTimeoutAndVeto`).
4. **Un objetivo malicioso o raro** (versión con `/`, `..`, que empieza por `-`, entorno conda `base`, enlace simbólico en `versions/`). No se ofrece, y si llega al embudo se rechaza antes de ejecutar. Test en Task 3 (`hostileTargetsNeverRun`).
5. **Muchos proyectos o disco lento.** El paseo de proyectos se hace **una sola vez** por detección para artefactos, pins y dependencias. Si se agota el plazo, nada se preselecciona y al actuar se bloquea («No se pudo comprobar a tiempo si algún proyecto pide esta versión»). Test en Task 2 (`oneProjectWalkPerPassAndBudgetFailsClosed`).

## Rulings de este plan (decisiones del redactor)

- **R1 — Papelera donde no hay comando oficial por versión.**
  - `nvm`: función de shell → Papelera de `~/.nvm/versions/node/<v>`.
  - `volta`: `volta uninstall` solo quita paquetes, no runtimes → Papelera de `~/.volta/tools/image/node/<v>`.
  - `asdf`: su orden necesita dos argumentos (`plugin` y `versión`) y `{target}` es uno → Papelera de `~/.asdf/installs/<plugin>/<v>`, con detalle «Luego ejecuta asdf reshim».
  - `rvm`, SDKMAN y `~/sdk/go*` → Papelera.
- **R2 — conda con `-p`, no con `-n`.** El comando es `conda env remove -p {target} -y`. Con varias bases (miniconda + anaconda) el nombre es ambiguo, y una ruta absoluta pasa por `PathGate` y `confirmUnchanged`. La base nunca se ofrece. Solo se buscan bases bajo `~`.
- **R3 — Qué es «duplicada».**
  - Se cuentan las instalaciones por **lenguaje**, sumando todos los gestores y las instalaciones solo informativas (`/Library/Frameworks/Python.framework`, `/Library/Java/JavaVirtualMachines`). Los stubs de Apple en `/usr/bin` no cuentan.
  - Un lenguaje con menos de 2 instalaciones no ofrece nada.
  - Los entornos de conda son extra por definición: se ofrecen siempre, salvo `base`.
- **R4 — Pins.**
  - Se buscan en la raíz de cada proyecto del paseo compartido y en sus hijos directos (monorepos), no más hondo.
  - Coincidencia por componentes numéricos tras quitar `v`, `ruby-` y `python-`: `3.11` pide `3.11.x`; `18` pide `18.*`.
  - `environment.yml` (`name:` o `prefix:`) pide un entorno de conda. `go.mod` y `pom`/`gradle` no se leen.
  - Al actuar, el paseo se repite con su plazo. Si no termina, se bloquea.
- **R5 — Fuera.** Raíces personalizadas (`PYENV_ROOT`, `NVM_DIR`, `FNM_DIR`… la app no ve el entorno de la shell): solo se miran las rutas por defecto. Virtualenvs duplicados: no hay forma barata y fiable de compararlos, y los `.venv` viejos ya los cubre el plan 3.
- **R6 — Homebrew.**
  - Solo fórmulas `python@3.N`, `node`, `node@N`, `openjdk`, `openjdk@N`, `go`, `go@1.N` de `/opt/homebrew/Cellar` y `/usr/local/Cellar`.
  - `brew uses --installed <f>` solo para candidatas que no son ya rojas: como mucho 8 por detección, 15 s cada una.
  - `CommandPolicy` veta `brew … --ignore-dependencies` siempre.
  - Las rutas del Cellar nunca son `item.paths` (son protegidas). El tamaño va en `bytes`.

---

## File Structure

- Create `Sources/DiskMapCore/Cleanup/Toolchains/ToolchainInventory.swift`: modelo, raíces inyectables, inventario de solo lectura y fecha de último uso.
- Create `Sources/DiskMapCore/Cleanup/Toolchains/ToolchainUsage.swift`: versión por defecto por gestor, PATH, pins (`VersionPin`) y lectura de pins en proyectos.
- Create `Sources/DiskMapCore/Cleanup/Toolchains/ToolchainSource.swift`: veredictos, memo por detección, `discover` y `revalidate`.
- Create `Sources/DiskMapCore/Cleanup/Toolchains/DependencyDuplicateSource.swift`: fila informativa de `node_modules` repetidos.
- Modify:
  - `Sources/DiskMapCore/Catalog/Catalog.swift`: `DiscoveryKind` (`.toolchains(manager:)`, `.toolchainSystemInfo`, `.dependencyDuplicates`) y `ToolchainManager`.
  - `Sources/DiskMapCore/Cleanup/CleanupTargets.swift`: `source(for:)` y el memo nuevo en `DiscoveryContext`.
  - `Sources/DiskMapCore/Cleanup/ProjectArtifactSource.swift`: lista de proyectos memorizada y compartida.
  - `Sources/DiskMapCore/Safety/CommandPolicy.swift`: vetos de `brew` y `conda`.
  - `Sources/DiskMapCore/Safety/TimeBudget.swift`: `toolchains`.
  - `Sources/DiskMapCore/System/CommandRunner.swift`: `fallbackPatterns`.
  - `Sources/DiskMapCore/Resources/catalog.json`: 14 fichas nuevas al final.
- Tests: `Tests/DiskMapCoreTests/ToolchainInventoryTests.swift`, `ToolchainUsageTests.swift`, `ToolchainSourceTests.swift`, `DependencyDuplicateTests.swift`, y líneas nuevas en `CatalogSchemaTests.swift`.

---

### Task 1: Esquema, fichas e inventario de solo lectura

**Files:**
- Modify:
  - `Sources/DiskMapCore/Catalog/Catalog.swift` (`DiscoveryKind`)
  - `Sources/DiskMapCore/Cleanup/CleanupTargets.swift` (`source(for:)`; los casos nuevos van a `PendingDiscoverySource` hasta las tasks 3 y 4)
  - `Sources/DiskMapCore/Resources/catalog.json`
  - `Sources/DiskMapCore/System/CommandRunner.swift` (`fallbackPatterns` += `"~/.pyenv/bin"`, `"~/.rbenv/bin"`, `"~/miniforge3/bin"`, `"~/.volta/bin"`)
- Create: `Sources/DiskMapCore/Cleanup/Toolchains/ToolchainInventory.swift`
- Test: `Tests/DiskMapCoreTests/ToolchainInventoryTests.swift`, `Tests/DiskMapCoreTests/CatalogSchemaTests.swift`

**Interfaces:**
- Consumes: `CleanupScanner.expand`, `CleanupTargets.realPath`, `ProjectArtifactRules.isRealDirectory`.
- Produces:
```swift
public enum ToolchainManager: String, Codable, Sendable, CaseIterable {
    case pyenv, conda, nvm, fnm, volta, asdf, rbenv, rvm, sdkman, rustup, goSDK, homebrew, system
}
// DiscoveryKind: case toolchains(manager: ToolchainManager)  // JSON {"type":"toolchains","manager":"pyenv"}
//                case toolchainSystemInfo                     // {"type":"toolchainSystemInfo"}
//                case dependencyDuplicates                    // {"type":"dependencyDuplicates"}
public enum ToolchainLanguage: String, Sendable { case python, node, ruby, java, rust, go, condaEnv, other }

public struct InstalledToolchain: Sendable, Equatable {
    public var manager: ToolchainManager
    public var language: ToolchainLanguage
    public var name: String          // "3.11.4", "v20.11.0", "stable-aarch64-apple-darwin", "python@3.11", "java/17.0.9-tem", nombre del entorno
    public var path: String          // carpeta de la instalación (Cellar/<f> en Homebrew)
    public var target: String        // valor de {target} (nombre o ruta según el gestor; véase la tabla)
    public var lastUsed: Date?       // max(atime del ejecutable principal, mtime de la carpeta); nil si no se pudo leer
    public var informational: Bool   // /Library/…, /Applications/Xcode*.app
}

public struct ToolchainRoots: Sendable {
    public var home: String
    public var cellars: [String]             // ["/opt/homebrew/Cellar", "/usr/local/Cellar"]
    public var applications: String          // "/Applications"
    public var libraryJava: String           // "/Library/Java/JavaVirtualMachines"
    public var libraryPython: String         // "/Library/Frameworks/Python.framework/Versions"
    public var xcodeSelectLink: String       // "/var/db/xcode_select_link"
    public static func standard(home: String) -> ToolchainRoots
}

public enum ToolchainInventory {
    /// Solo `lstat`/`readdir`/`readlink`: nunca lanza procesos. Las entradas que son enlaces simbólicos no se
    /// ofrecen (pyenv-virtualenv, `current` de SDKMAN, `default` de rvm).
    public static func scan(_ roots: ToolchainRoots) -> [InstalledToolchain]
}
```

Tabla de gestores (`~` = `roots.home`). En todas las fichas, el `paths` del catálogo es el patrón de la columna «Carpeta», o `[]` cuando la columna lo indica:

| manager | Carpeta (patrón) | language | target | Ejecutable de último uso |
|---|---|---|---|---|
| pyenv | `~/.pyenv/versions/*` | python | nombre | `bin/python3` |
| conda | `~/miniconda3/envs/*`, `~/anaconda3/envs/*`, `~/miniforge3/envs/*`, `~/mambaforge/envs/*`, `~/.conda/envs/*` | condaEnv | **ruta** | `bin/python` |
| nvm | `~/.nvm/versions/node/*` | node | ruta | `bin/node` |
| fnm | `~/Library/Application Support/fnm/node-versions/*`, `~/.local/share/fnm/node-versions/*`, `~/.fnm/node-versions/*` | node | nombre | `installation/bin/node` |
| volta | `~/.volta/tools/image/node/*` | node | ruta | `bin/node` |
| asdf | `~/.asdf/installs/*/*` (plugin `nodejs`→node, `python`, `ruby`, `java`, `golang`→go, `rust`; otros→other) | según plugin | ruta | `bin/<exe>` |
| rbenv | `~/.rbenv/versions/*` | ruby | nombre | `bin/ruby` |
| rvm | `~/.rvm/rubies/*` (except `default`) | ruby | ruta | `bin/ruby` |
| sdkman | `~/.sdkman/candidates/*/*` (except `current`; `java`→java, otros→other) | según candidato | ruta | `bin/<candidato>` |
| rustup | `~/.rustup/toolchains/*` | rust | nombre | `bin/rustc` |
| goSDK | `~/sdk/go*` | go | ruta | `bin/go` |
| homebrew | `[]` (Cellar es protegido) | según fórmula (R6) | nombre de fórmula | `<ver>/bin/<exe>` |
| system | `[]`; `Xcode*.app` (≥ 2), `libraryJava/*.jdk`, `libraryPython/*` (sin `Current`) | python/java/other | — | — |

Fichas en `catalog.json`, una por gestor salvo `system`:
- ids `toolchain-<manager>` (p. ej. `toolchain-pyenv`, `toolchain-go-sdk` para `goSDK`).
- Campos comunes: `risk "yourCall"`, `regenerates false`, sin `aggressiveRisk`, `preselectInAggressive true`, `profiles []`, `kind "code"`, `discovery {"type":"toolchains","manager":…}`.
- `cleanup`:
  - pyenv: `command pyenv ["uninstall","-f","{target}"]`
  - conda: `command conda ["env","remove","-p","{target}","-y"]`
  - fnm: `command fnm ["uninstall","{target}"]`
  - rbenv: `command rbenv ["uninstall","-f","{target}"]`
  - rustup: `command rustup ["toolchain","uninstall","{target}"]`
  - homebrew: `command brew ["uninstall","{target}"]`
  - el resto: `trash`
- `shortReason`: «Otra versión de la misma herramienta; la que usas y las que piden tus proyectos no se tocan.»
- Además:
  - `toolchain-system-info`: `cleanup info`, `discovery {"type":"toolchainSystemInfo"}`, `reviewHint` «Las versiones de /Library y las apps Xcode se quitan a mano o con el Desinstalador de Airy.»
  - `node-dependency-duplicates`: `cleanup info`, `discovery {"type":"dependencyDuplicates"}`, `reviewHint` «Con pnpm cada versión de un paquete se guarda una sola vez en el disco y la comparten todos tus proyectos.»
- `title`s:
  - «Versión de Python (pyenv)»
  - «Entorno de conda»
  - «Versión de Node (nvm)», «Versión de Node (fnm)», «Versión de Node (Volta)»
  - «Versión instalada con asdf»
  - «Versión de Ruby (rbenv)», «Versión de Ruby (rvm)»
  - «Versión instalada con SDKMAN»
  - «Toolchain de Rust»
  - «Versión de Go (~/sdk)»
  - «Versión de Homebrew»
  - «Versiones instaladas en el sistema»
  - «Paquetes de Node repetidos entre proyectos»

- [ ] **Step 1: Write the failing tests**

```swift
// CatalogSchemaTests
@Test func toolchainDiscoveryDecodesAndRoundTrips()        // {"type":"toolchains","manager":"rustup"} ↔ .toolchains(manager: .rustup); manager desconocido → DecodingError
@Test func toolchainFichasAreNeverGreen()                  // toda ficha con discovery .toolchains: risk == .yourCall, aggressiveRisk == nil, profiles.isEmpty;
                                                            // RiskClassifier(.aggressive) y (.prudent).baseRisk == .yourCall
@Test func toolchainCommandsAreArgumentArraysWithTarget()  // pyenv/conda/fnm/rbenv/rustup/homebrew: cleanup.usesTargets; ningún argumento contiene " " ni "sh"; conda usa "-p" (no "-n")
@Test func shellFunctionManagersUseTrash()                 // nvm, volta, asdf, rvm, sdkman, goSDK → .trash
// ToolchainInventoryTests (árbol temporal como home y Cellar falsos)
@Test func inventoryFindsEachManagerLayout()                // un caso por fila de la tabla → manager, language, name, target (nombre o ruta) exactos
@Test func symlinkEntriesAreNotInventoried()                // versions/foo → enlace; candidates/java/current; rubies/default → ausentes
@Test func homebrewOnlyVersionedLanguageFormulas()          // Cellar/{python@3.11,node@18,ffmpeg,openjdk} → python@3.11, node@18, openjdk; nunca ffmpeg
@Test func condaBaseIsNeverAnInstall()                      // ~/miniconda3 (base) no aparece; ~/miniconda3/envs/ml sí, target == ruta absoluta
@Test func lastUsedIsMaxOfExecutableAtimeAndFolderMtime()   // utimes: atime bin/python3 = hace 10 d, mtime carpeta = hace 200 d → hace 10 d; ejecutable ausente → mtime
@Test func systemInstallsAreInformational()                 // applications/{Xcode.app,Xcode-beta.app}, libraryJava/x.jdk → informational == true, manager .system
```

- [ ] **Step 2: Run** `swift test --filter "ToolchainInventoryTests|CatalogSchemaTests"`. Expected: FAIL (tipos no definidos).
- [ ] **Step 3: Implement** según Interfaces y la tabla. La fecha se lee con `lstat` (`st_atimespec`, `st_mtimespec`). En `source(for:)`, los tres casos nuevos devuelven `PendingDiscoverySource()` por ahora.
- [ ] **Step 4: Run** `swift test 2>&1 | tail -3`. Expected: todo en verde (las pruebas existentes del catálogo siguen pasando con las 14 fichas nuevas).
- [ ] **Step 5: Commit**: `feat: inventario de versiones instaladas de herramientas de desarrollo` (+ Co-Authored-By).

---

### Task 2: Qué versión se usa (por defecto, PATH y pins de proyecto con el paseo compartido)

**Files:**
- Create: `Sources/DiskMapCore/Cleanup/Toolchains/ToolchainUsage.swift`
- Modify: `Sources/DiskMapCore/Cleanup/ProjectArtifactSource.swift` (`ProjectWalkMemo` gana la lista de proyectos; `walk` la consume)
- Test: `Tests/DiskMapCoreTests/ToolchainUsageTests.swift`, `Tests/DiskMapCoreTests/ProjectArtifactTests.swift`

**Interfaces:**
- Consumes: `InstalledToolchain`, `ToolchainRoots` (Task 1); `CommandRunning.resolve`; `ProjectArtifactSource`.
- Produces:
```swift
public struct ProjectList: Sendable, Equatable { public var projects: [String]; public var complete: Bool }
// ProjectWalkMemo: func projectList(compute: () async -> ProjectList) async -> ProjectList   (segundo hueco, mismo patrón Mutex)
// ProjectArtifactSource:
public func projectList(context: DiscoveryContext) async -> ProjectList   // BFS de roots(home:) con totalBudget; memorizado en context.projectWalk
// `walk` usa projectList(context:) en vez de recorrer otra vez; `onWalk` sigue contando paseos de artefactos;
// nuevo hook de prueba `onListProjects: (@Sendable () -> Void)?` cuenta los BFS.

public struct VersionPin: Sendable, Equatable {
    public var language: ToolchainLanguage
    public var raw: String              // tal cual, sin espacios
    public var source: String           // "~/Projects/app/.nvmrc" (tildePath) o "pyenv global"
    public var resolvable: Bool         // false: "lts/*", "node", "latest", "system", "stable"/"nightly" sin toolchain de ese canal
    public func matches(_ install: InstalledToolchain) -> Bool
}

public struct UsageReport: Sendable {
    public var defaults: [String: String]        // InstalledToolchain.path → motivo («Es la versión por defecto de pyenv.», «La usa el PATH (node).», «Xcode activo (xcode-select).»)
    public var requested: [String: String]       // path → «La pide ~/Projects/app (.nvmrc).»
    public var noPreselect: Set<ToolchainLanguage>  // pin no resoluble o lista de proyectos incompleta
    public var projectsComplete: Bool
}

public enum ToolchainUsage {
    static let pinFiles = [".nvmrc", ".node-version", ".python-version", ".tool-versions", "rust-toolchain",
                           "rust-toolchain.toml", ".ruby-version", "environment.yml"]
    static let pathExecutables: [ToolchainLanguage: [String]] = [.python: ["python3", "python"], .node: ["node"],
        .ruby: ["ruby"], .java: ["java"], .rust: ["rustc", "cargo"], .go: ["go"]]
    public static func report(installs: [InstalledToolchain], roots: ToolchainRoots, projects: ProjectList,
                              runner: any CommandRunning) async -> UsageReport
    static func pins(inProject root: String) -> [VersionPin]     // raíz + hijos directos (R4); archivos > 64 KB se ignoran
}
```

Reglas del default por gestor. Solo se leen archivos; ninguna orden se ejecuta:
- **pyenv:** `~/.pyenv/version`, todas sus líneas. Una línea que nombra un enlace de `versions/` (virtualenv) marca la versión dueña de su `realpath`.
- **nvm:** `~/.nvm/alias/default`. Se siguen alias (`~/.nvm/alias/<x>`, también `lts/<x>`) hasta 3 saltos.
- **fnm:** `realpath` de `<fnm>/aliases/default`.
- **volta:** `node.runtime` de `~/.volta/tools/user/platform.json` (JSON).
- **asdf:** `~/.tool-versions`.
- **rbenv:** `~/.rbenv/version`.
- **rvm:** `realpath` de `~/.rvm/rubies/default`.
- **SDKMAN:** `realpath` de `candidates/<c>/current`.
- **rustup:** `default_toolchain` y los valores de `[overrides]` de `~/.rustup/settings.toml`, leídos línea a línea con `^\s*([^=]+?)\s*=\s*"(.*)"\s*$`. No hace falta un parser TOML.
- **Xcode:** `readlink(xcodeSelectLink)`.
- **PATH:** para cada ejecutable de `pathExecutables`, `runner.resolve` y luego `realpath`. Si cae dentro de `install.path`, esa instalación está en uso. Los shims no caen dentro de ninguna y no marcan nada.
- **Default no resoluble:** la versión más alta (orden numérico por componentes) de ese gestor cuenta como por defecto, y su lenguaje entra en `noPreselect`.

Coincidencia de `VersionPin.matches`:
- Quita los prefijos `v`, `ruby-`, `python-`, `go` y `java/` (SDKMAN).
- Compara componente a componente separando por `.`: el pin es prefijo de la versión instalada.
- Rust: el nombre instalado se compara sin el sufijo `-(aarch64|x86_64)-apple-darwin`, y `stable`/`beta`/`nightly` coinciden por canal.
- Conda: `name:` coincide con el último componente de la ruta del entorno, y `prefix:` con la ruta.
- Homebrew: `python@3.11` cuenta como versión `3.11`.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func defaultsFromEachManagerFile()                     // un caso por gestor → defaults[path] con el motivo exacto («Es la versión por defecto de pyenv.»…)
@Test func pathResolutionMarksInUse()                        // FakeRunner.resolved["node"] = <home>/.nvm/versions/node/v20.1.0/bin/node → «La usa el PATH (node).»; shim de pyenv → nada
@Test func projectPinsMarkRequestedVersions()                // ~/Projects/app/.nvmrc "18" → v18.17.0 y v18.20.1 pedidas; v20 no; ~/Projects/mono/web/.python-version "3.11" (hijo directo) → 3.11.4
@Test func pinMatchingIsComponentWise()                      // "3.1" no pide 3.11.0; "v18" pide 18.0.0; "ruby-3.2.2" pide 3.2.2; "1.75" pide "1.75.0-aarch64-apple-darwin"; "stable" pide "stable-aarch64-apple-darwin"
@Test func toolVersionsAndRustToolchainTomlAreParsed()       // "nodejs 18.17.0 20.1.0" → dos pins; [toolchain] channel = "1.70.0" → pin rust
@Test func unresolvablePinsAreConservative()                 // .nvmrc "lts/*" → .node ∈ noPreselect; alias default "lts/iron" sin archivo → la más alta de nvm en defaults
@Test func condaEnvironmentYmlRequestsEnv()                  // environment.yml "name: ml" → ~/miniconda3/envs/ml pedido
@Test func oneProjectWalkPerPassAndBudgetFailsClosed() async // mismo DiscoveryContext: discover(old-project-artifacts) + report → onListProjects == 1;
                                                              // totalBudget .zero → complete == false y todos los lenguajes en noPreselect
```

- [ ] **Step 2: Run** `swift test --filter "ToolchainUsageTests|ProjectArtifactTests"`. Expected: FAIL.
- [ ] **Step 3: Implement** según Interfaces. `projects(in:)` informa si se cortó por plazo (`complete`). Las pruebas existentes de `ProjectArtifactTests` no cambian.
- [ ] **Step 4: Run** `swift test 2>&1 | tail -3`. Expected: todo en verde.
- [ ] **Step 5: Commit**: `feat: versiones en uso por defecto, PATH y pins de proyecto con un solo paseo` (+ Co-Authored-By).

---

### Task 3: `ToolchainSource` (riesgo, preselección, Homebrew, embudo)

**Files:**
- Create: `Sources/DiskMapCore/Cleanup/Toolchains/ToolchainSource.swift`
- Modify:
  - `Sources/DiskMapCore/Cleanup/CleanupTargets.swift` (`DiscoveryContext.toolchains = ToolchainMemo()`; `.toolchains` → `ToolchainSource()`)
  - `Sources/DiskMapCore/Safety/CommandPolicy.swift`
  - `Sources/DiskMapCore/Safety/TimeBudget.swift` (`public static let toolchains: Duration = .seconds(20)`)
- Test: `Tests/DiskMapCoreTests/ToolchainSourceTests.swift`

**Interfaces:**
- Consumes: Task 1 y Task 2; `CleanupTargetSource`; `ProcessListing`; `TimeBudget.processScan`; `TreeWalk.summarize`.
- Produces:
```swift
final class ToolchainMemo: Sendable {        // mismo patrón que ProjectWalkMemo: una detección por DiscoveryContext
    func detection(compute: () async -> ToolchainDetection) async -> ToolchainDetection
}
struct ToolchainDetection: Sendable {
    var installs: [InstalledToolchain]
    var usage: UsageReport
    var brewDependents: [String: [String]?]   // fórmula → dependientes; nil = no se pudo comprobar
    var processes: [RunningProcess]?          // nil = listado desconocido
    var complete: Bool                        // false si se agotó TimeBudget.toolchains
}
public struct ToolchainSource: CleanupTargetSource {
    public init()
    init(roots: @escaping @Sendable (String) -> ToolchainRoots, budget: Duration = TimeBudget.toolchains,
         brewTimeout: TimeInterval = 15, brewLimit: Int = 8)          // pruebas
    static let brewUsesArguments = ["uses", "--installed"]           // + fórmula
    static let unusedAfter: TimeInterval = 90 * 86_400
    /// `^[A-Za-z0-9][A-Za-z0-9._+@-]*$` y sin `..`: lo único que llega como {target} no-ruta.
    static func isSafeName(_ text: String) -> Bool
}
// CommandPolicy.refusal: brew con "--ignore-dependencies" → «Airy nunca fuerza a Homebrew a ignorar dependencias.»;
//                        conda con "--all" o "base" → «Airy nunca borra el entorno base de conda.»
```

`discover(entry, context)` devuelve solo las instalaciones de `entry.discovery.manager`, a partir de una detección compartida:
1. **Inventario y grupos.** Inventario, informe de uso y listado de procesos (una vez, `TimeBudget.processScan`). Se agrupan las instalaciones por lenguaje (R3). Un lenguaje con menos de 2 no ofrece nada. `informational` nunca se ofrece aquí.
2. **Veredicto por instalación.** Gana el primero que aplique:
   - un proceso cuyo ejecutable está dentro de `path` ⇒ `floor .doNotTouch`, «Se está usando ahora.»;
   - listado de procesos desconocido ⇒ `blockedReason` «No se pudo comprobar si está en uso.»;
   - `usage.defaults[path]` ⇒ `floor .doNotTouch` con ese motivo;
   - `usage.requested[path]` ⇒ `floor .doNotTouch` con ese motivo;
   - Homebrew: `brew uses --installed <f>` (con `runner.resolve("brew")`, sin resolver ⇒ no se ofrece). Con salida no vacía ⇒ `floor .doNotTouch`, «Lo necesita Homebrew para: a, b.». Estado ≠ 0, plazo agotado o más de `brewLimit` ⇒ `blockedReason` «No se pudo comprobar a tiempo si Homebrew la necesita.»;
   - si no ⇒ ámbar.
3. **Preselección.** `preselectable` solo si se cumplen todas: `detection.complete`, `usage.projectsComplete`, el lenguaje no está en `noPreselect`, `lastUsed` conocido y `lastUsed < now − unusedAfter`. El clasificador ya limita la preselección del ámbar a Agresivo.
4. **Objetivo.**
   - `idSuffix = "\(language.rawValue) \(name)"`, o `"\(plugin) \(name)"` en asdf y SDKMAN.
   - `paths = [path]`, salvo Homebrew (`[]`).
   - `targets = [target]` solo en fichas de comando.
   - En Homebrew, `bytes` = `TreeWalk.summarize(Cellar/<f>)` con el plazo que quede; `nil` ⇒ `sizeNote` «Tamaño desconocido» + `blockedReason`.
   - `lastModified = lastUsed`.
   - `details`: «Usada por última vez: dd/MM/yyyy» (o «Sin fecha de uso»), «Otras versiones: …» (las del mismo lenguaje) y, en asdf, «Luego ejecuta asdf reshim».
5. **Plazo agotado.** Lo que no se evaluó del todo no se ofrece.

`revalidate(entry, item, context)` repite la detección **sin memo previo**, porque el embudo crea un `DiscoveryContext` nuevo. Exige, en este orden:
- un único `target` (o una única ruta en Papelera) que corresponda a una instalación viva de ese gestor con el mismo `path`;
- `isSafeName(target)` si no es ruta;
- que el entorno no sea una base de conda (el padre de la ruta debe llamarse `envs`);
- que el veredicto siga siendo ámbar. Si no, se rechaza con el motivo del veredicto (p. ej. «Es la versión por defecto de pyenv.»);
- `usage.projectsComplete`. Si no, «No se pudo comprobar a tiempo si algún proyecto pide esta versión.».

- [ ] **Step 1: Write the failing tests** (home temporal con `utimes`, `now` inyectado, `FakeRunner`, `FakeListing`, `ToolchainRoots` falsas)

```swift
@Test func inUseIsRedOthersAmberNeverGreen() async           // pyenv {3.9.18 (global), 3.11.4, 3.12.1} → 3.9.18 doNotTouch con riskReason; resto yourCall; nunca .safe en ningún modo
@Test func aggressivePreselectsOnlyOldUnrequested() async    // .aggressive: 3.11.4 (uso hace 200 d) preselected; 3.12.1 (hace 10 d) no; .prudent: ninguno preselected
@Test func singleInstallOffersNothing() async                // solo una versión de Ruby entre todos los gestores → []
@Test func runningVersionIsRed() async                       // FakeListing con exe en …/versions/3.11.4/bin/python3 → doNotTouch «Se está usando ahora.»
@Test func brewDependentsTimeoutAndVeto() async              // uses → "ffmpeg" ⇒ doNotTouch «Lo necesita Homebrew para: ffmpeg.»; estado 1 ⇒ blockedReason;
                                                              // CommandPolicy.refusal("brew", ["uninstall","--ignore-dependencies","x"]) != nil
@Test func funnelRunsOfficialCommandAsArgumentArray() async  // execute(item pyenv 3.11.4) → FakeRunner.calls == [pyenv ["uninstall","-f","3.11.4"], workingDirectory "/"]
@Test func condaRemovesByPathThroughPathGate() async         // calls == [conda ["env","remove","-p","<home>/miniconda3/envs/old","-y"]]; envs/old cambiado por enlace tras el plan → .blocked, sin llamada
@Test func nvmVersionGoesToTrash() async                     // execute → .movedToTrash; ningún FakeRunner.calls con "nvm"
@Test func defaultChangedAfterDetectionIsRefused() async     // detectar; escribir ~/.pyenv/version "3.11.4"; execute → .blocked("Es la versión por defecto de pyenv."); calls vacío
@Test func hostileTargetsNeverRun() async                    // targets "../x", "-rf", "3.11/../..", "base", "" → .blocked; ninguna llamada
@Test func agentCanOnlyList() async                          // context .agent("claude") → .blocked (solo verde); list_cleanup_items incluye la fila con risk "yourCall"
@Test func detectionBudgetExceededOffersNothing() async      // budget .zero → []
```

- [ ] **Step 2: Run** `swift test --filter ToolchainSourceTests`. Expected: FAIL.
- [ ] **Step 3: Implement** según Interfaces. `brew uses` se ejecuta en secuencia, nunca en paralelo, para no cargar la CPU.
- [ ] **Step 4: Run** `swift test 2>&1 | tail -3`. Expected: todo en verde.
- [ ] **Step 5: Commit**: `feat: versiones duplicadas de desarrollo en ámbar, en uso en rojo y con su comando oficial` (+ Co-Authored-By).

---

### Task 4: Filas informativas (sistema, Xcode y `node_modules` repetidos) y verificación

**Files:**
- Create: `Sources/DiskMapCore/Cleanup/Toolchains/DependencyDuplicateSource.swift`
- Modify:
  - `Sources/DiskMapCore/Cleanup/CleanupTargets.swift` (`.toolchainSystemInfo` → `ToolchainSystemInfoSource`, en `ToolchainSource.swift`; `.dependencyDuplicates` → `DependencyDuplicateSource`)
- Test: `Tests/DiskMapCoreTests/DependencyDuplicateTests.swift`, `Tests/DiskMapCoreTests/ToolchainSourceTests.swift`

**Interfaces:**
- Consumes: `ToolchainMemo`/`ToolchainDetection` (Task 3); `ProjectArtifactSource.projectList(context:)` (Task 2).
- Produces:
```swift
struct ToolchainSystemInfoSource: CleanupTargetSource      // revalidate → «Este elemento es solo informativo.»
public struct DependencyDuplicateSource: CleanupTargetSource {
    public init()
    init(budget: Duration)                                  // pruebas
    static let minimumProjects = 3
}
```

**Sistema.**
- Una fila por lenguaje con instalaciones `informational` cuando ese lenguaje suma ≥ 2 en total (R3), y una fila «Xcode» si hay ≥ 2 `Xcode*.app`.
- `idSuffix`: «Python», «Java» o «Xcode».
- `paths = []`.
- `bytes`: suma de `TreeWalk.summarize` con el plazo restante; `nil` ⇒ `sizeNote` «Tamaño desconocido».
- `details`: una línea por instalación (`tildePath`), marcando «(en uso)» la del PATH o la de `xcode-select`.

**Dependencias repetidas.**
- Para cada proyecto de `projectList`, se lee `node_modules/<pkg>/package.json` y `node_modules/@scope/<pkg>/package.json`, solo de primer nivel.
- De cada uno se toman `name` y `version` con `JSONSerialization`. Los archivos > 64 KB se ignoran.
- Las carpetas de paquete que son enlaces (pnpm ya deduplica) se saltan.
- Clave `name@version`. Los grupos presentes en ≥ `minimumProjects` proyectos distintos forman **una** fila:
  - `bytes` = Σ (copias − 1) × tamaño de una copia, medido con `TreeWalk` y el plazo; si se corta, `sizeNote` «Al menos» y se suma lo medido;
  - `details` = los 5 mayores: «react@18.2.0 · 7 proyectos · 4,1 MB cada copia»;
  - `preselectable = false`.
- Lista incompleta o plazo agotado ⇒ `sizeNote` «Análisis parcial». Nunca hay acción: la ficha es `info`.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func xcodeAndLibraryInstallsAreInfoRows() async        // applications/{Xcode.app,Xcode-15.4.app}, link → Xcode.app → 1 fila info con «(en uso)» en Xcode.app; execute → .blocked("Este elemento es solo informativo.")
@Test func libraryPythonCountsTowardDuplicates() async       // libraryPython/3.11 + pyenv 3.12.1 → fila info «Python» y 3.12.1 ofrecida en toolchain-pyenv
@Test func repeatedPackagesAcrossThreeProjectsMakeOneRow() async  // 3 proyectos con react@18.2.0, 2 con lodash@4.17.21 → 1 fila; details solo react; bytes == 2 × tamaño
@Test func pnpmSymlinkedPackagesAreSkipped() async           // node_modules/react → enlace a .pnpm/... → no cuenta
@Test func scopedPackagesAndBadJsonAreHandled() async        // @babel/core cuenta; package.json roto o > 64 KB → ignorado sin fallar
@Test func duplicatesNeverActAndAgentOnlyLists() async       // execute (usuario y agente) → .blocked; nunca FakeRunner.calls
```

- [ ] **Step 2: Run** `swift test --filter "DependencyDuplicateTests|ToolchainSourceTests"`. Expected: FAIL.
- [ ] **Step 3: Implement** según Interfaces.
- [ ] **Step 4: Run** `swift build 2>&1 | tail -3 && swift test 2>&1 | tail -3`. Expected: compila y todo en verde.
- [ ] **Step 5: Verificación de solo lectura en este Mac.** Abrir Airy (DEBUG) en Limpieza y lanzar la detección. Comprobar en las filas nuevas:
  - la versión por defecto de cada gestor instalado sale en rojo con su motivo;
  - ninguna fila sale en verde;
  - en Prudente no hay nada marcado;
  - «Solo revisar» muestra Xcode, sistema y paquetes repetidos si los hay.

  Sin pulsar «Borrar». Con `airy-mcp`, solo se hacen:
  - `list_cleanup_items`, que incluye las filas con `risk` `yourCall` o `doNotTouch`;
  - `run_safe_cleanup` con `dry_run: true`, que no las incluye.

  Capturas solo de la ventana propia. Para parar, matar solo el PID de Airy.
- [ ] **Step 6: Commit**: `feat: filas informativas de Xcode, sistema y paquetes de Node repetidos` (+ Co-Authored-By).
