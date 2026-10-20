# Mole como inspiración para Airy

Fecha: 2026-10-20
Fuente: Mole v1.59.1 (tw93/Mole, instalado con Homebrew en `/opt/homebrew/Cellar/mole/1.59.1`), solo lectura de sus scripts de shell y del README. No se ejecutó ningún subcomando de `mo`. El binario de `status` (`status-go`) está compilado en Go y no tiene código fuente disponible: lo que se dice de sus sensores sale de `strings` sobre el binario (indicios fuertes, no código leído).

**Licencia:** GPL-3.0-or-later (fichero `LICENSE` y fórmula de Homebrew). El README pide además no usar el mismo nombre en bifurcaciones y mencionar a Mole como origen. Existe una app nativa aparte, "Mole for Mac", propietaria y de pago, de la que no hay nada que leer. Para Airy: **adaptamos ideas, listas de rutas (son hechos sobre macOS, no expresión creativa) y heurísticas, pero no copiamos código** (ni siquiera fragmentos de shell traducidos línea a línea) para no contaminar Airy con GPL. Conviene citar a Mole en la documentación como inspiración.

---

## 1. Funciones y comandos de Mole

| Comando | Qué hace |
|---|---|
| `mo` | Menú interactivo. |
| `mo clean` | Limpieza profunda: cachés, logs, temporales, artefactos de desarrollo y restos de apps ya desinstaladas. Vacía la Papelera por defecto (borrado directo, sin Finder). Opciones: `--dry-run`, `--whitelist`, `--debug`, `--external PATH` (limpia metadatos de SO de un volumen externo). |
| `mo uninstall [app…]` | Desinstala apps con sus restos. Va a la Papelera por defecto, `--permanent` para borrar ya. `--list`, `--dry-run`. Si falta la app, remite a `mo clean`. Integra Homebrew Cask (`brew uninstall --cask [--zap]`). |
| `mo optimize` | Mantenimiento acotado (DNS, Spotlight, caché de Finder, bases SQLite, etc.). Cada tarea se salta con motivo si no hace falta. Incluye un **diagnóstico de rendimiento** previo (solo lectura). `--whitelist` por tarea. |
| `mo analyze` | Explorador de disco en terminal (Go): vista general, navegación, filtro, multiselección, vista previa en Finder, mover a la Papelera. Marca "Old Downloads (90d+)". `--json` con `scan_status` por entrada (`complete`/`partial`/`unavailable`) para no mentir cuando el escaneo es parcial. |
| `mo status` | Panel de salud en vivo (Go): CPU, memoria, disco, red, energía, procesos. Puntuación de salud. `--json`, `--watch --interval 2s` (NDJSON), alertas de procesos con CPU sostenida, diagnóstico de zombis (solo lectura). |
| `mo purge` | Artefactos de proyecto regenerables (`node_modules`, `target`…), agrupados por proyecto, selección, borrado permanente solo de lo confirmado. `--paths` configura raíces, `--yes` para no interactivo. |
| `mo installer` | Busca instaladores (`.dmg .pkg .mpkg .iso .xip` y `.zip` que contengan un instalador) y los borra tras selección. |
| `mo history [--json]` | Registro de operaciones de limpieza (`~/Library/Logs/mole/operations.log`), con `run_id` y atribución. Se desactiva con `MO_NO_OPLOG=1`. |
| `mo touchid` | Configura Touch ID para `sudo`. |
| `mo completion`, `mo update`, `mo remove` | Utilidades de la propia herramienta (autocompletado, actualización, desinstalación). |
| Lanzadores Raycast/Alfred | Scripts que abren cada comando en el terminal. |

Principios de diseño visibles en el código, todos aprovechables por Airy:

1. **Todo borrado pasa por un único embudo** (`safe_remove` / `safe_clean`) que valida la ruta, aplica protecciones y lista blanca, y deja registro. Las funciones de limpieza solo *proponen* rutas.
2. **Fallar cerrado:** si un sondeo (tamaño, proceso, antigüedad) agota el tiempo o da error, el elemento se conserva y se dice por qué.
3. **Protocolo de proceso en tres estados** (corriendo / parado / desconocido): se limpia solo con "parado". Si no se sabe, se salta. Ejemplos: no se poda la caché de pnpm si hay un pnpm vivo, ni DerivedData con Xcode abierto, ni cachés de Mail si Mail corre.
4. **Doble comprobación** (la lista y, otra vez, justo antes de borrar), con identidad del archivo (inodo/padre) para evitar carreras.
5. **Categoría "solo revisar"**: cosas grandes que Mole *nunca* borra solo, las muestra con el comando manual (ver §2.14).
6. **Presupuestos de tiempo** (timeouts) en todo, para que una carpeta enorme o un disco lento no cuelgue la herramienta.

---

## 2. Catálogo de objetivos de limpieza

Convenciones: `~` = carpeta del usuario. "Edad" = antigüedad mínima. "(sudo)" = Mole pide contraseña de administrador. Casi todo son cachés bajo `~/Library/Caches` y `~/Library/Application Support/<app>`, y las rutas se agrupan aquí por familia. Entre paréntesis, cómo decide Mole la seguridad cuando tiene regla propia.

### 2.1 Sistema (requiere sudo)

| Ruta / patrón | Criterio |
|---|---|
| `/Library/Caches/**/*.cache` | archivos de más de 7 días |
| `/Library/Caches/**/*.log` | más de 7 días |
| `/Library/Logs/DiagnosticReports/*` | informes de fallos de más de 7 días |
| `/private/var/log/*.log` | más de 7 días, excluye `*.gz` y `*.asl` |
| `/Library/Logs/Adobe`, `/Library/Logs/CreativeCloud`, `/Library/Logs/adobegc.log` | más de 7 días |
| `/Library/Caches/com.apple.iconservices.store` | regenerable |
| Apps "Install macOS *.app" en `/Applications` | más de 14 días, no en ejecución, no la versión actual del sistema, sin actualización pendiente; si no se puede saber la versión, se conserva |
| `/System/Library/Caches/com.apple.coresymbolicationd/data` | única ruta bajo `/System` que su validador deja borrar (caché reconstruible); Airy **no** debe imitarlo |
| Cachés de GPU reconstruibles bajo `/private/var/folders/*/*/C/...` (Metal/Dawn/shader) | más de 1 día; **excluye** cualquier carpeta de un agente de seguridad (ver §2.16) |
| `com.apple.idleassetsd` temporales de `/private/var/folders/*/T/` (descargas abortadas `CFNetworkDownload_*.tmp`) | más de 7 días; se han visto cientos de GB de basura aquí ("Datos del sistema") |
| Clones de firma de código de navegadores (`*.code_sign_clone`) | reconstruibles; excluye EDR |
| Servicios huérfanos de sistema (LaunchDaemons/PrivilegedHelperTools cuyo binario ya no existe) | sudo; con una lista larga de falsos positivos conocidos (Docker, Zoom, Wireshark, Tailscale…) |
| Instantáneas locales de Time Machine | **no las borra**: solo cuenta (`tmutil listlocalsnapshots /`) y muestra "revisar" |
| Copias de TM fallidas `*.inProgress` en `/Volumes/*/Backups.backupdb` | solo con TM configurado, sin copia en marcha (`tmutil status`), y con más de 48 h |

No toca `/System`, `/usr`, `/bin`, `/sbin`, `/etc`, `/var/db`, `/Library/Apple`, `/Library/Extensions`, `/Library/Keychains` ni `/private/var/db` (ver lista de protegidos en §2.15).

### 2.2 Usuario: lo esencial

| Ruta | Notas |
|---|---|
| `~/Library/Caches/*` (barrido genérico de todos los hijos) | pasa por la lista de protecciones (§2.15) y por un **guardián de caché viva**: se rechaza si hay un proceso de la app dueña o un manejador abierto de SQLite en esa caché. Se excluye la raíz de Deno. |
| `~/Library/Logs/*` | logs de más de 7 días |
| `~/.Trash` | vaciado directo (el usuario puede protegerlo con la whitelist). Si falta Acceso total al disco, avisa y salta. |
| `~/Library/Saved Application State/*` | estados guardados |
| `~/Library/Preferences/com.apple.recentitems.plist` | lista de recientes |
| `~/Library/Mail Downloads`, `~/Library/Containers/com.apple.mail/Data/Library/Mail Downloads` | adjuntos de Mail de más de 30 días y de al menos 5 MB, y solo si Mail no corre |
| Descargas incompletas `~/Downloads/*.download`, `*.crdownload`, `*.part` | con guardián de "no activa" |
| `.DS_Store` en el home (máx. 500 por pasada) | **protegido por defecto** (está en la lista blanca por defecto) |
| `~/Library/Messages/StickerCache`, `Caches/Previews/{Attachments,StickerCache}` | cachés de Mensajes |
| `~/Library/Caches/com.apple.{photoanalysisd,akd,WebKit.Networking,QuickLook.thumbnailcache,iconservices*,helpd,GeoServices,AppleMediaServices,duetexpertd,parsecd,python}`, `Quick Look/*` | cachés de sistema de usuario |
| `~/Library/IdentityCaches/*`, `~/Library/Suggestions/*`, `AddressBook/Sources/*/Photos.cache` | cachés de identidad, Siri y Contactos |
| Contenedores de Apple: `~/Library/Containers/com.apple.{wallpaper.agent,mediaanalysisd,AppStore,configurator.xpc.InternetService,wallpaper.extension.aerials,geod,stocks,AvatarUI.AvatarPickerMemojiPicker,AMPArtworkAgent,CoreDevice.CoreDeviceService,NeptuneOneExtension,AppleMediaServicesUI.UtilityExtension}/Data/{Library/Caches,tmp}/*` | solo `Data/Library/Caches` y `Data/tmp`, nunca el resto del contenedor |
| `~/Library/Group Containers/*` cachés | salta `com.apple.*`, `group.com.apple.*` y contenedores de extensiones de Safari |
| Cachés de Apple Silicon: `~/Library/Caches/com.apple.rosetta.update`, `com.apple.amp.mediasevicesd` | menores |
| Portapapeles/Handoff cache | reconstruible |

### 2.3 Navegadores

Familia Safari, Chrome, Chromium, Edge, Brave, Arc, Dia, Vivaldi, Opera, Yandex, QQ Browser, Helium, Comet, Orion (Kagi), Zen y Firefox.

- Caché HTTP: `~/Library/Caches/{com.apple.Safari, Google/Chrome, Chromium, com.microsoft.edgemac, BraveSoftware/Brave-Browser, company.thebrowser.Browser (Arc), company.thebrowser.dia, com.vivaldi.Vivaldi, com.operasoftware.Opera, Yandex/YandexBrowser, net.imput.helium, Comet, com.kagi.kagimacOS, zen, Firefox}/*` y `~/.cache/puppeteer`.
- Dentro de `~/Library/Application Support/<Navegador>/<Perfil>/` y `User Data/<Perfil>/`: `Cache`, `Code Cache`, `GPUCache`, `DawnCache`, `DawnGraphiteCache`, `DawnWebGPUCache`, `GrShaderCache`, `GraphiteDawnCache`, `ShaderCache`, `Application Cache`, `component_crx_cache`, `extensions_crx_cache`, `Crashpad/completed`. GoogleUpdater: `crx_cache` y `*.old`.
- Service Worker CacheStorage: lógica propia para limpiarlo con presupuesto por dominio.
- **Versiones antiguas de Chrome/Edge/Brave dentro del `.app`**: `…/Contents/Frameworks/<Framework>/Versions/*` excepto la que apunta `Current`. Solo con el navegador cerrado y con el symlink `Current` válido.
- **Nunca** toca el perfil: cookies, historial, `Local Storage`, `IndexedDB`, extensiones, contraseñas.
- Guardián: solo se limpia si el navegador no está en ejecución (sondeo por familia).

### 2.4 Cachés de apps de usuario (más de 190 reglas, lista cerrada por app)

Patrón: `~/Library/Caches/<bundle id>/*`, `~/Library/Containers/<bundle>/Data/Library/Caches/*`, `~/Library/Application Support/<App>/{Cache,Code Cache,GPUCache,Dawn*,logs}` y logs.

- **Editores/IDE:** VS Code (`Code/{logs,Cache,CachedData,CachedExtensionVSIXs,WebStorage/*/CacheStorage}`), Cursor, Sublime, Zed (caché, node/cache, logs), CodeBuddy, extensiones obsoletas de editores, JetBrains (logs; versiones antiguas del Toolbox), Qoder, Antigravity, Filo.
- **Comunicación:** Slack, Discord, Legcord, Zoom, Teams (nuevo y heredado), WhatsApp, Telegram, WeChat, QQ, Skype, DingTalk, Feishu, Tencent Meeting.
- **IA:** ChatGPT, Claude (caché, `Application Support/Claude/{Cache,Code Cache,GPUCache,Dawn*,sentry}`, logs), LM Studio (caché de la app, no modelos), Codex Desktop (cachés de Chromium exactas; el perfil y las sesiones están protegidos), Claude Code/Cursor Agent/Copilot CLI **versiones antiguas** (se conserva la activa y 1 anterior).
- **Creativas:** Adobe (`Caches/Adobe`, `com.adobe.*`, `Media Cache Files`; el patrón `Adobe *` está protegido en la lista de rutas), Figma, Sketch, Final Cut (caché; los proxies solo si el usuario lo marca), DaVinci Resolve (`~/Movies/CacheClip`), Premiere, Blender, Cinema 4D, SketchUp, ScreenFlow.
- **Medios:** Spotify, Apple Music/Podcasts/TV (incluye temporales de Podcasts), Plex, IINA, VLC, mpv, Bilibili, iQIYI y similares, Stremio.
- **Descargas/torrents:** Transmission, qBittorrent, Aria2, Downie, Folx.
- **Juegos:** Steam (`htmlcache`, `appcache`, `depotcache`, `steamapps/shadercache`, logs), Epic, Battle.net, EA, GOG, Riot, Minecraft (logs, crash-reports, webcache), Lunar Client, PCSX2, RPCS3.
- **Utilidades:** Notion, Obsidian, Logseq, Bear, Evernote, Alfred, The Unarchiver, TeamViewer, AnyDesk, CleanShot, Warp, Ghostty, WakaTime, mihomo-party, Todoist, Spark, Airmail.
- **Oficina:** Word/Excel/PowerPoint/Outlook (caché + contenedor + logs), iWork, WPS, Thunderbird, **Apple Mail `com.apple.mail/*`** (la lista blanca de Mole lo ofrece como opcional).
- **Virtualización:** VMware Fusion, Parallels, VirtualBox `.cache`, UTM (caché de la app, del sandbox y temporales), Lima (descargas), Vagrant (`.vagrant.d/tmp`), Tart.
- **Heurística genérica de Application Support:** una carpeta de app se considera con caché regenerable si contiene `Code Cache`, `GPUCache`, `DawnCache`, `GrShaderCache`, `GraphiteDawnCache`, `DawnGraphiteCache`, `DawnWebGPUCache` o `Crashpad`; entonces se limpian esas subcarpetas (y `Cache`/`CachedData`), salvo apps protegidas (§2.15) y salvo carpetas con demasiados elementos.
- Otros: `~/.zcompdump*`, `~/.lesshst`, `~/.viminfo.tmp`, `~/.wget-hsts`, `~/.oh-my-zsh/cache`, `~/.cache/{curl,wget,pre-commit}`, cachés de curl y wget en `~/Library/Caches`.

### 2.5 Herramientas de desarrollo (cachés de paquetes y compiladores)

Con su comando oficial cuando existe (marcado con **cmd**):

| Herramienta | Qué limpia |
|---|---|
| npm | `~/.npm/_cacache/*` y residuales (`_logs`, etc.) usando la ruta de `npm config get cache`; `~/.tnpm` |
| pnpm | **cmd** `pnpm store prune` por cada binario pnpm usable, con ruta de store validada; salta si hay un pnpm corriendo; `~/Library/pnpm/store` solo se revisa |
| yarn | `~/.yarn/cache/*`, `~/Library/Caches/Yarn/*` |
| bun | **cmd** `bun pm cache rm` y huérfanos de `~/.bun/install/cache` |
| Corepack | `$COREPACK_HOME/*` |
| uv | **cmd** `uv cache prune` (`uv cache dir` para la ruta). Nota: Airy usa `uv cache clean`, más agresivo; Mole usa `prune` |
| pip | **cmd** `pip3 cache purge` |
| conda | **cmd** `conda clean --yes --index-cache --tarballs --logfiles` (no toca `pkgs` en uso: `~/.conda/pkgs` solo se revisa) |
| Poetry, pyenv, Jupyter, Ruff, mypy, pytest | `~/.cache/poetry`, `Library/Caches/pypoetry/{artifacts,cache}` (**`pypoetry/virtualenvs` protegido siempre**), `~/.pyenv/cache`, `~/.jupyter/runtime`, `~/.cache/{ruff,mypy}`, `~/.pytest_cache`, PyInstaller `bincache` |
| Go | rutas dadas por `go env GOCACHE` y `GOMODCACHE` (nunca rutas anchas como `~` o `~/go`) |
| Rust | `$CARGO_HOME/registry/cache` (solo la caché de descargas), `~/.rustup/downloads`; **no** toca `registry/src`, `registry/index`, `git`, `bin` ni `toolchains` (razón: rust-analyzer y compilaciones offline los usan). Salta si hay cargo/rustc corriendo |
| Ruby | rbenv cache, `~/.gem/specs`, `~/.gem/ruby/*/cache/*.gem`, `~/.bundle/cache` |
| PHP | Composer (`~/.composer/cache`, `~/Library/Caches/composer`) |
| Otros lenguajes | Perl CPAN build, Hex (Elixir), Opam, Bazel `~/.cache/bazel`, Zig, mise, Nix, Terraform, Gradle (protegido por defecto), Maven `~/.m2/repository` (solo revisar), Deno (solo revisar), NuGet (solo revisar), CocoaPods |
| Frontend | `~/.cache/{typescript,electron,node-gyp,webpack,vite,eslint,prettier,prisma}`, `~/.node-gyp`, `~/.turbo/cache`, `~/.vite/cache`, `~/.parcel-cache`, Expo (`~/.expo/*`, salvo `state.json` con tokens) |
| Nube/CI | `~/.kube/cache`, `~/.aws/cli/cache`, `~/.config/gcloud/logs`, `~/.azure/logs`, GitHub CLI (`~/.cache/gh`), `~/.cache/gitlab-runner`, `~/.circleci/cache`, `~/.sonar` |
| Clientes de BD y API | Sequel Ace/Pro, DBeaver, Navicat, Redis Insight, Postman, Insomnia, TablePlus, Paw, Charles, Proxyman (solo cachés) |
| Android/Swift | `~/.android/{build-cache,cache}`, `Caches/Google/AndroidStudio*`, `~/.cache/swift-package-manager`, `Library/Caches/org.swift.swiftpm` |
| Homebrew | **cmd** `brew cleanup --prune=30` (antes de ejecutar, una vista previa con `--dry-run`); `~/Library/Caches/Homebrew/downloads/*`; no barre `api/` ni `bootsnap/` ni el directorio de bloqueos; solo cada 7 días; **solo muestra** `brew autoremove` |
| Navegadores de automatización "huérfanos" | perfiles temporales de Puppeteer/Playwright de más de 2 h y sin proceso vivo |
| Cachés de proyecto | `__pycache__`, `.pytest_cache`, etc. dentro de proyectos con indicadores, con índice de Git (ver §5.2) |

### 2.6 Xcode y simuladores

| Ruta / comando | Criterio |
|---|---|
| `~/Library/Developer/Xcode/DerivedData/*` y `Products/*` | solo con Xcode y build tooling parados (sondeo de procesos) |
| `~/Library/Caches/com.apple.dt.Xcode/*` | idem |
| `~/Library/Developer/Xcode/{iOS,watchOS,tvOS} DeviceSupport/*` | **conserva las 2 más recientes** por fecha (configurable); limpia además `*/Symbols/System/Library/Caches/*` y `*.log` |
| `~/Library/Developer/XCTestDevices/*` | cada clon por separado; Xcode los recrea |
| **cmd** `xcrun simctl delete unavailable` | con un `DEVELOPER_DIR` que tenga `simctl`; reintenta una vez por el arranque en frío de CoreSimulatorService |
| `~/Library/Developer/CoreSimulator/Caches/*`, `Devices/*/data/tmp/*`, `~/Library/Logs/CoreSimulator/*` | solo sin simuladores arrancados (`simctl list devices booted -j`) |
| `~/Library/Developer/CoreSimulator/Profiles/Runtimes/*/…/System/Library/Caches/*` | caché de runtime |
| `/Library/Developer/CoreSimulator/Caches` (sudo), `/Library/Developer/Xcode/DocumentationCache` | caches de sistema |
| `~/Library/Developer/Xcode/UserData/IB Support/*` | caché de Interface Builder |
| Runtimes de simulador huérfanos (sin dispositivos) | **solo informa**: `xcrun simctl runtime delete <id>` |
| `Xcode/Archives`, `CoreSimulator/Devices` | **solo revisar** (§2.14) |

### 2.7 Docker, OrbStack y contenedores

**Mole no ejecuta ningún `docker … prune`.** Solo avisa "Docker unused data · review with `docker system df`" y borra `~/.docker/buildx/cache/*`, `~/.local/share/containers/storage/tmp/*`, `~/.vagrant.d/tmp`. Muestra "revisar" para `~/Library/Containers/com.docker.docker/Data`, OrbStack (`~/.orbstack`, `Group Containers/*dev.orbstack/data`, `~/OrbStack`; **protegidos** como ruta: contienen sistemas de archivos vivos) y `~/.lima`. Airy es más agresivo y capaz aquí (prunes oficiales); eso es una ventaja de Airy, no una carencia.

### 2.8 Homebrew y gestores

Ya cubierto en §2.5. Además: restos de descargas en `~/Library/Caches/Homebrew`; Caskroom como parte del inventario de apps instaladas.

### 2.9 Restos de apps ya desinstaladas (huérfanos)

Ver §5.1 para la lógica. Carpetas que revisa: `~/Library/Caches`, `~/Library/Logs`, `~/Library/Saved Application State`, más contenedores "stub" (solo los de MacPaw/CleanMyMac) y servicios del sistema (sudo).

### 2.10 Instaladores y firmware

- `mo installer`: `.dmg .pkg .mpkg .iso .xip` y `.zip` que listados con `zipinfo -1` parezcan instalador, en `~/Downloads`, `~/Desktop`, `~/Documents`, `~/Public`, `~/Library/Downloads`, `~/Library/Caches/Homebrew`, iCloud Drive `…/com~apple~CloudDocs/Downloads`, Mail Downloads, Telegram Desktop. Verifica identidad del archivo en el momento de borrar. Descarta la lista entera si el escaneo falla o expira.
- Firmware de dispositivos: `~/Library/iTunes/*Software Updates/*.ipsw`, `~/Library/Group Containers/*.group.com.apple.configurator/**/*.ipsw`.
- Actualizaciones de macOS: `/Library/Updates` y `/macOS Install Data` los deja a Software Update; `~/Library/Updates` solo revisa.

### 2.11 Logs

`~/Library/Logs/*` (más de 7 días; protegidos los de Codex y los del propio Mole), logs de apps (Claude, Zed, JetBrains, Warp, DingTalk, Steam, Minecraft…), logs del sistema (§2.1), informes de fallos (`~/Library/Logs/DiagnosticReports`, `Crashpad/completed` y `pending` de Codex de más de cierta edad, `SentryCrash`, `KSCrash`, `Crashlytics`).

### 2.12 Estado de apps y otros mantenimientos que borran

`~/Library/Saved Application State/*.savedState` de más de 30 días, `~/Library/Application Support/com.apple.sharedfilelist/*.sfl2|sfl3` corruptos (`plutil -lint` falla), preferencias `.plist` corruptas (no `com.apple.*`).

### 2.13 Cachés de Finder / Vista rápida

`com.apple.QuickLook.thumbnailcache`, `com.apple.iconservices.store`, `com.apple.iconservices` + `qlmanage -r cache` y `qlmanage -r`.

### 2.14 Elementos de solo revisar (nunca los borra solo)

Los muestra con tamaño y el comando manual. Para Airy es la base de su categoría "tú decides / revisar" sin botón automático:

Mail (`~/Library/Mail`), instaladores de macOS, caché de actualizaciones, datos de Docker/OrbStack/Lima, DerivedData y Archives de Xcode, datos de simuladores, copias de iOS (`~/Library/Application Support/MobileSync/Backup`), modelos de LM Studio, Hugging Face (`~/.cache/huggingface` y la ruta que pida `HF_HOME`), Maven, Ivy, NuGet, Deno, store de pnpm, `~/.conda/pkgs`, Gradle, emuladores y system-images de Android, instalaciones de `mise`, SDK de Flutter (FVM), datos antiguos de JetBrains, cachés de modelos compilados de Apple Intelligence (`com.apple.e5rt.e5bundlecache`: **protegido**, caro de regenerar), worktrees de agentes (`~/.codex/worktrees`, `~/.claude/worktrees`), instantáneas locales de Time Machine, login items/LaunchAgents rotos, artefactos de build (con comando `mo purge`).

### 2.15 Lista de protecciones (lo más valioso para copiar *como idea*)

Mole tiene tres capas independientes. Copio la lista tal cual está definida, porque es la parte de mayor valor para el motor de seguridad de Airy.

**Capa A: validación de ruta antes de borrar (`validate_path_for_deletion`)**

- Debe ser absoluta, sin `..` como componente, sin caracteres de control.
- Si la ruta es un enlace simbólico, se valida el destino. Si **algún ancestro** es un enlace, se resuelve la ruta física y se vuelven a pasar las comprobaciones de crítico y protegido.
- Raíces críticas, nunca borrables (ni sus alias por mayúsculas/minúsculas en APFS, ni por inodo): `/`, `/bin`, `/dev`, `/sbin`, `/usr`, `/System`, `/Library` (y `/Library/Apple`, `/Library/Application Support` raíz, `/Library/Extensions`, `/Library/Keychains`), `/Applications` (raíz), `/Applications/Finder.app`, `/Applications/Safari.app`, `/Volumes`, `/opt`, `/opt/homebrew` (raíz; los hijos sí se pueden), `/Users`, `/Users/Shared`, `/Users/Guest`, `/private`, `/private/tmp`, `/etc`, `/var`, `/var/db`, `/var/audit`, `/var/root`, `/private/var`, `/private/var/tmp`, `/private/var/folders` (raíz), `/private/var/db`, `/private/var/audit`, `/private/var/root`, `/Network`, `/cores`, `/home`, `/net`, `/tmp`. También rechaza `/Users/<nombre>` (la raíz de un home) para evitar un `rm -rf` por una variable vacía.
- Rechaza la base de datos activa de telemetría de energía (`powerlog`), aunque pese decenas de GB.

**Capa B: protección de rutas (`should_protect_path`), solo en modo limpieza**

- Siempre protegidos: `~/.prometheus/data`, copias de seguridad de configuración de Git y de historiales de shell (`.gitconfig.bak*`, `.zsh_history.bak*`…), las raíces compartidas `~/.cache`, `~/.config`, `~/.local` (y `~/.local/{bin,lib,share,state}`), pero no sus hijos específicos de una app.
- Cualquier ruta con `SystemSettings`, `SystemPreferences`, `ControlCenter`, `com.apple.Settings*`, `com.apple.Notes`; cachés de la interfaz del sistema (`com.apple.systempreferences.cache`, `controlcenter.cache`, `finder.cache`, `dock.cache`: borrarlas deja paneles en blanco); contenedores de Ajustes y Control Center; `dock.plist` y `finder.plist`; preferencias de Bluetooth y Wi-Fi (`ByHost/com.apple.bluetooth.*`, `wifi.*`); `com.apple.networkextension*.plist` (estado de VPN).
- iCloud Drive: `~/Library/Mobile Documents*`.
- Datos personales de cuentas: `~/Library/Accounts`, `~/Library/Keychains`, `~/Library/Mail`, `~/Library/Calendars`, `~/Library/Contacts`.
- Plugins de audio y licencias: `/Library/Audio/Plug-Ins/{Components,VST,VST3}`, `iZotope`, `LaserSoft Imaging`, preferencias de Native Instruments, Avid Media Composer, FabFilter, PACE (iLok).
- Cachés con estado de cuenta o licencia pese al nombre: `ms-playwright`, Cotypist, DisplayLink, SilverFast, `Adobe *`, `com.apple.containermanagerd`, `homed`, `ap.adprivacyd`, `FamilyCircle`, `HomeKit`, cachés de sandbox de Atajos (`ShortcutsSandboxCache`), `GIPPseudonymousID`, `CCTClearcutLogger` (borrarlas con Gemini abierto provoca un bucle de escritura).
- Fondos de pantalla y salvapantallas del usuario: `Application Support/com.apple.idleassetsd`, `com.apple.wallpaper`.
- Audio del sistema: cualquier cosa con `coreaudio`, `com.apple.audio.`, `coreaudiod` (borrar causa pérdida de sonido en Macs Intel).
- OrbStack (`~/.orbstack`, `Group Containers/*dev.orbstack`), estado de Codex (sesiones, `auth.json`, historial, índices).
- Cachés de **agentes de seguridad/EDR/MDM** bajo `/private/var/folders`: prefijos `com.crowdstrike.`, `com.sentinelone.`, `com.sentinel-labs.`, `com.eset.`, `com.jamf.`, `com.jamfsoftware.`, `com.paloaltonetworks.`, `com.cisco.anyconnect`, `com.cisco.secureclient`. Borrar algo ahí dispara la detección de manipulación (MITRE T1562.001) y corporativamente parece malware.
- Cachés de modelos compilados (`com.apple.e5rt.e5bundlecache`): se saltan.
- Contenedores de apps (`~/Library/Containers/<id>`, `Group Containers/<id>`): si el id es de una app protegida, se protege todo salvo `Data/Library/Caches/*` y `Data/tmp/*`, que se consideran regenerables por definición.

**Capa C: apps con datos sensibles (lista `DATA_PROTECTED_BUNDLES`), protegidas en limpieza (se pueden desinstalar a petición)**

Gestores de contraseñas (1Password, Bitwarden, LastPass, Dashlane, KeePass, Authy, Yubico), IDE y editores (JetBrains, VS Code, Sublime, Xcode, Nova, Typora), herramientas de IA (Cursor, Claude, ChatGPT, Codex, Ollama, LM Studio, Jan, Perplexity, DrawThings, Windsurf, Gemini), clientes de bases de datos, herramientas de API y red (Postman, Insomnia, Charles, Proxyman, Paw), **VPN y proxys** (Clash/ClashX/Verge, Surge, Tailscale, ZeroTier, WireGuard, OpenVPN, Cloudflare WARP, Nord/Express/Proton/Mullvad…), Git (GitHub Desktop, Tower, Fork, GitKraken, Sublime Merge), terminales (iTerm2, kitty, Alacritty, WezTerm, Warp), Docker y virtualización (Docker, OrbStack, UTM, VMware, Parallels, VirtualBox, Vagrant), monitorización, gestores de ventanas y lanzadores (Alfred, Raycast, Karabiner, Rectangle, Bartender), notas (Obsidian, Notion, Bear, Logseq, Evernote, Day One, GoodNotes), diseño y creativas (Adobe, Figma, Sketch, Affinity, Pixelmator, Cinema 4D, Autodesk, Native Instruments, iZotope, FabFilter), comunicación (Slack, Discord, Zoom, Teams, Telegram, WhatsApp, WeChat…), almacenamiento y copia (Dropbox, OneDrive, Google Drive, Box, Backblaze, iCloud `bird`/`CloudDocs`), acceso remoto (TeamViewer, AnyDesk, Chrome Remote Desktop), métodos de entrada (IME).

Además, una lista de **patrones de datos sensibles que nunca se tratan como huérfanos**: `*1password*`, `*keychain*`, `*bitwarden*`, `*lastpass*`, `*keepass*`, `*dashlane*`, `*enpass*`, `*ssh*`, `*gpg*`, `*gnupg*`, `com.apple.keychain*`.

**Lista blanca de usuario (`~/.config/mole/whitelist`)**

- Se gestiona con `mo clean --whitelist` (menú con las cachés ofrecidas) y se guarda una ruta/patrón por línea. Lo que el usuario guarda *reemplaza* los valores por defecto opcionales, pero las **protecciones de seguridad duras se vuelven a mezclar siempre** (para que una lista antigua no pierda protecciones nuevas).
- Valores por defecto opcionales (protegidos hasta que el usuario los desmarque): `~/Library/Caches/ms-playwright*`, `~/.gradle/{caches,daemon}/*`, `~/.ollama/models/*`, cachés y datos de Surge, `~/Library/Caches/org.R-project.R/R/renv/*`, `~/Library/Caches/JetBrains*`, `com.jetbrains.toolbox*`, `tealdeer/tldr-pages`, `~/Library/Application Support/JetBrains*`, `~/Library/Caches/com.apple.finder`, `~/Library/Mobile Documents*`, y la marca interna de "metadatos de Finder / .DS_Store".
- Protecciones duras que siempre se fusionan: FINDER_METADATA, `com.apple.FontRegistry*`, `com.apple.spotlight*`/`Spotlight*` (romperlas rompe la búsqueda y el renderizado de fuentes), `CloudKit*` (rompe sincronización de iCloud), `pypoetry/virtualenvs*` (intérpretes vivos), `renv` (enlaces simbólicos desde proyectos R).
- Para `optimize` hay una lista blanca aparte (`whitelist_optimize`, por nombre de tarea o patrón de ruta).

### 2.16 Retención y umbrales (constantes de Mole)

Logs 7 días; informes de fallos 7; temporales 7; huérfanos 30; "dotdir" huérfano (pista) 60; estados guardados 30; adjuntos de Mail 30 días y 5 MB; GPU 1 día; copia de TM segura 48 h; instaladores de macOS 14 días; Brew cada 7 días; carpetas DeviceSupport: conservar 2; versiones de agentes de IA: conservar la activa más 1; máx. 500 `.DS_Store` por pasada; máx. 15 trabajos en paralelo; base SQLite de más de 100 MB no se compacta; base de notificaciones se compacta si pasa de 50 MB; `knowledgeC.db` si pasa de 100 MB.

---

## 3. Tareas de `optimize`

Todas son "seguras para ejecución automática" según el catálogo de Mole (hay una validación que impide registrar una tarea no segura). Tras cada una informa uno de seis resultados: aplicado, sin cambios, saltado, no disponible, requiere atención, fallido. Mole **no usa `sudo` global**: lo pide al principio una vez y cada tarea comprueba si lo tiene; sin él, la salta con motivo. No se ejecuta como root.

Leyenda de utilidad: **Útil** (resuelve un problema real o libera algo medible), **Situacional** (solo ayuda si hay un fallo concreto), **Placebo** (en macOS actual no mejora nada medible o es ruido).

| Tarea | Qué ejecuta exactamente | sudo | Valoración |
|---|---|---|---|
| `system_maintenance` (DNS y Spotlight) | `dscacheutil -flushcache` + `killall -HUP mDNSResponder`; consulta `mdutil -s /` | sí | **Situacional.** Vaciar DNS solo ayuda con problemas de resolución; hacerlo de forma rutinaria es placebo. |
| `cache_refresh` (Finder) | `qlmanage -r cache`, `qlmanage -r`; borra `com.apple.QuickLook.thumbnailcache`, `com.apple.iconservices.store`, `com.apple.iconservices` | no | **Situacional.** Arregla miniaturas o iconos corruptos; libera poco; no acelera. |
| `saved_state_cleanup` | borra `*.savedState` de más de 30 días en `~/Library/Saved Application State` | no | **Útil menor.** Algo de espacio y estados obsoletos; riesgo mínimo. |
| `fix_broken_configs` | busca `.plist` corruptos en preferencias del usuario (no `com.apple.*`) y los elimina | no | **Situacional.** Resuelve apps que no arrancan por una preferencia dañada; conviene hacerlo en ámbar. |
| `network_optimization` | `dscacheutil -flushcache` + SIGHUP a mDNSResponder (se salta con VPN activa) | sí | **Placebo** como rutina (duplica `system_maintenance`). |
| `sqlite_vacuum` | `VACUUM` tras `PRAGMA integrity_check` en `Mail/V*/MailData/Envelope Index*`, `Messages/chat.db`, `Safari/History.db`, `Safari/TopSites.db`. Salta si Mail, Safari o Mensajes corren, si la base pasa de 100 MB o si la lista libre es pequeña | no | **Útil con reservas.** Compactar índices de Mail puede acelerar la búsqueda; para Airy es **rojo** (Mail/Mensajes). Solo Safari sería concebible. |
| `prevent_network_dsstore` | `defaults write com.apple.desktopservices DSDontWriteNetworkStores -bool true` y `DSDontWriteUSBStores` | no | **Útil.** Es persistente, reversible (`defaults delete`) y evita basura en discos de red y USB. |
| `legacy_overrides_audit` | lee `NSAppSleepDisabled` global y `com.apple.frameworks.diskimages skip-verify*`; si están a 1 los borra con `defaults delete` | no | **Útil.** Elimina "tweaks" antiguos que degradan macOS (App Nap desactivado, verificación de imágenes de disco omitida). |
| `network_stack_optimize` | `route -n flush` y `arp -a -d` (con comprobación previa de conectividad y de VPN de túnel completo) | sí | **Placebo / arriesgada.** Puede cortar rutas explícitas de VPN. Rechazar. |
| `disk_permissions_repair` | `diskutil resetUserPermissions / <uid>` (si detecta problema) | sí | **Situacional.** Solo si hay errores de permisos en el home. |
| `spotlight_index_optimize` | mide `mdfind "kMDItemFSName == 'Applications'"` dos veces; si ambas tardan más de 3 s y hay corriente, `mdutil -E /` (reindexa, 1-2 h de uso intenso) | sí | **Situacional útil.** Con búsqueda realmente rota. La medición previa es una buena idea; la reindexación a ciegas sería dañina. |
| `spotlight_orphan_rules_cleanup` | edita `EnabledPreferenceRules` en `com.apple.spotlight` quitando entradas de apps desinstaladas | no | **Útil menor / cosmético.** |
| `periodic_maintenance` | `sudo periodic daily weekly monthly` si está obsoleto | sí | **Placebo.** macOS lo hace solo; el comando desaparece en macOS 26+. |
| `shared_file_list_repair` | borra `*.sfl2/*.sfl3` corruptos (`plutil -lint`), salvo `ApplicationRecentDocuments` | no | **Situacional.** Arregla favoritos de Finder/Recientes rotos. |
| `disk_verify` | `diskutil verifyVolume /` (desactivado por defecto: `MOLE_ENABLE_DISK_VERIFY=1`) | no (reparar sí) | **Diagnóstico útil**, pero pesado; mejor leer el estado S.M.A.R.T. |
| `login_items_audit` | revisa elementos de inicio sin binario (`launchctl print`, `PlistBuddy`; evita `sfltool dumpbtm` porque lanza un aviso del sistema) | no | **Útil (solo informa).** |
| `quarantine_cleanup` | `sqlite3 …/com.apple.LaunchServices.QuarantineEventsV2 "DELETE FROM LSQuarantineEvent; VACUUM;"` | no | **Útil para privacidad**, no para rendimiento. Cambio de riesgo bajo. Ámbar. |
| `launch_agents_cleanup` | lista `~/Library/LaunchAgents/*.plist` cuyo `Program` absoluto no existe (ignora unidades desmontadas y nombres sin ruta) | no | **Útil (solo informa).** No borra. |
| `notification_cleanup` | `DELETE FROM record WHERE delivered_date < now-30d; VACUUM;` en la BD del Centro de notificaciones si pesa más de 50 MB; luego `killall NotificationCenter` | no | **Útil cuando la BD es enorme.** Raro. |
| `coreduet_cleanup` | `DELETE FROM ZOBJECT WHERE ZCREATIONDATE < now-90d; VACUUM;` en `~/Library/Application Support/Knowledge/knowledgeC.db` si pasa de 100 MB | no | **Útil con reservas.** Toca historial de uso (privacidad). Ámbar. |

Tareas que Mole **retiró** y de las que conviene aprender: `dock_refresh`, `memory_pressure_relief` (el `purge`), `launch_services_rebuild` (rompía extensiones de VPN en ejecución) y `radio_refresh` (cortaba Wi-Fi/Bluetooth). Es un respaldo a la postura de Airy de no ofrecer un botón "liberar RAM".

### 3.1 Diagnóstico de rendimiento (solo lectura)

Es lo mejor de `optimize` y encaja con la sección Rendimiento de Airy. Muestrea `ps -Aceo pcpu=,command=` dos veces, con 1 s de separación, y mira estas **familias** con un umbral de 25 % de CPU sostenida en ambas muestras:

- `syspolicyd` (Gatekeeper/firma de código; si sube, comprueba `spctl --status` y busca imágenes de disco montadas con `hdiutil info`, ofreciendo expulsar las que no son del sistema);
- `WindowServer` (composición; síntoma más que causa);
- Spotlight (`mds`, `mdworker`, `mds_stores`, `mdbulkimport`);
- discos de simuladores (`diskimagesiod`, `simdiskimaged`);
- agentes empresariales de seguridad (CloudShell, AliEntSafe…; **nunca los cierra**, solo los nombra).

Más dos comprobaciones fuera de esa lista:

- **Presión de memoria:** `sysctl vm.swapusage` (swap usada / total) y porcentaje libre. Avisa si la swap pasa del **50 %** o la memoria libre baja del **15 %**, y nombra los mayores consumidores.
- **VM inactiva reteniendo memoria:** una máquina virtual (típicamente Docker Desktop) con más de **2 GB** y sin contenedores en marcha; recomienda salir de Docker Desktop.
- **Proceso desbocado:** uno que lleva al menos **12 h** vivo y ha gastado **≥ 25 %** de CPU sostenida durante toda su vida. Sugiere `kill -TERM <pid>` pero no lo ejecuta.

---

## 4. Métricas de `status`

`mo status` es un binario de Go (`gopsutil` v4) con ayuda de utilidades del sistema. Salida JSON y NDJSON (`--watch`). Lo siguiente combina lo documentado en el README con las cadenas del binario.

| Métrica | Qué muestra | Cómo la mide (indicio) |
|---|---|---|
| CPU | uso total y por núcleo, carga 1/5/15 min, núcleos de rendimiento y eficiencia (`P+E`) | `host_processor_info`/gopsutil; `hw.perflevel0.logicalcpu`, `hw.perflevel1.logicalcpu`; `vm.loadavg` |
| Memoria | usada, libre, disponible, total, **presión** | `vm_stat` (activa, cableada, comprimida; tamaño de página de la cabecera), `hw.memsize`, `memory_pressure`, `sysctl vm.swapusage` |
| Disco | uso, libre, lectura/escritura MB/s | `statfs`/`df -k`, IOKit (`IOBlockStorageDriver`) para contadores; `diskutil info` para saber si es interno |
| Red | bajada/subida por interfaz con gráfico; detecta túneles (VPN) y evita contar dos veces el tráfico del túnel y de su portadora; proxy HTTP/HTTPS/SOCKS/PAC | `netstat -ib`, tabla de rutas, `scutil --proxy` |
| Energía | nivel, estado (cargando/descargando), ciclos, **salud de batería** (capacidad máxima), amperaje | IOKit `AppleSmartBattery` (propiedades como `AppleRawMaxCapacity`, `InstantAmperage`, `CycleCount`) y `system_profiler SPPowerDataType` |
| **Temperatura** | CPU y estado térmico, alerta "CPU temperature high" / "Overheating" | **Sensores HID privados de IOKit** (`IOHIDEventSystemClientCreate`, `…SetMatching`, `…CopyServices`, `IOHIDEventGetFloatValue`), es decir, API privada de Apple. Además usa `powermetrics` (necesita sudo) para potencia de GPU |
| Ventiladores | número y RPM | claves de IOKit `FanCount`, `FanSpeed` |
| GPU | uso (residencia activa/inactiva) | `ioreg`/`powermetrics`; hay rutas de `nvidia-smi` heredadas de otras plataformas |
| Bluetooth | dispositivos y batería | `system_profiler SPBluetoothDataType` |
| Procesos | top por CPU y memoria, alertas de proceso con CPU por encima del umbral durante una ventana (`--proc-cpu-threshold`, `--proc-cpu-window`), **zombis** con el proceso padre responsable | `ps -Ao pid,ppid,state,pcpu,pmem,rss,comm` |
| Sistema | modelo, chip, RAM, versión de macOS, tiempo encendido, número de procesos | `kern.boottime`, `kern.osrelease`, IOPlatformUUID, `sw_vers` |
| **Puntuación de salud (0-100)** | combina CPU, memoria, capacidad de disco, S.M.A.R.T., E/S, térmicos, batería y tiempo encendido, con rangos de color | cálculo propio |

El README de Mole dice además que la app comercial "Mole for Mac" ofrece control de ventiladores en Macs compatibles: no está en el CLI y no hay código.

Para Airy: ya decidió **no mostrar grados** por depender de API privada. Mole demuestra que es viable (IOHID sensores), pero con la fragilidad conocida. La batería, los contadores de E/S, la red, la GPU y el tiempo encendido sí son alcanzables con interfaces estables y no están en la especificación (ver §6).

---

## 5. Lógica de restos, desinstalación y purgado de proyectos

### 5.1 Detección de restos huérfanos (apps ya desinstaladas)

1. **Inventario de apps instaladas** (cacheado 5 min): busca `*.app` hasta profundidad 3 en `/Applications`, `/System/Applications`, `~/Applications`, `/opt/homebrew/Caskroom`, `/usr/local/Caskroom`, `~/Library/Application Support/Setapp/Applications`, más apps cuyo `.pkg` las instaló fuera de rutas estándar (`pkgutil --pkgs`/`--files`, `/var/db/receipts`; resultado cacheado una hora a una semana según la huella de recibos) y apps de iOS en Apple Silicon (`Wrapper/*.app`). Lee `CFBundleIdentifier` con `PlistBuddy`. **Si el inventario está incompleto o un Info.plist no se puede leer, no se decide nada** ("un inventario incompleto no puede autorizar huérfanos").
2. **Candidatos:** solo `~/Library/Caches`, `~/Library/Logs`, `~/Library/Saved Application State` con nombres `com.*`, `org.*`, `net.*`, `io.*` (id en formato DNS inverso).
3. **Árbol de decisión** para considerar huérfano un id:
   1. si está en la lista de datos protegidos, no;
   2. si coincide con los patrones sensibles (contraseñas, ssh, gpg…), no;
   3. si está en el inventario, no;
   4. si es un componente del sistema (`loginwindow`, `dock`, `finder`, `safari`, Ajustes…), no;
   5. **si la carpeta se modificó hace menos de 30 días, no**;
   6. como último recurso, `mdfind "kMDItemCFBundleIdentifier == '<id>'"` (con timeout; si falla o expira, **se asume instalada**, y no se guarda en la caché del resultado);
   7. si pasa todo, es huérfano.
4. **Nunca** considera huérfanos (reglas explícitas, "CRITICAL: NEVER"): `LaunchAgents`, `LaunchDaemons`, `Containers/`, `Application Scripts/`, `Group Containers/` (los ids con prefijo de equipo dan falsos positivos). Solo trata los "stubs" de contenedor de MacPaw/CleanMyMac.
5. **Servicios huérfanos del sistema** (sudo): plists de `/Library/LaunchAgents` y `/Library/LaunchDaemons` cuyo binario no existe y cuyo dueño no está instalado, con una lista de protección de apps conocidas (Docker, Zoom, Wireshark ChmodBPF, Tailscale, Intego, Homebrew `homebrew.mxcl.*`…). Y `PrivilegedHelperTools` equivalentes.
6. Comprueba la identidad del candidato (inodo, padre) justo antes de borrar.

### 5.2 Desinstalador (`find_app_files`)

Ubicaciones que asocia a una app, por **nombre** (con variantes: tal cual, sin espacios, guion bajo, guion, minúsculas) y por **bundle id** (y por los ids de bundles embebidos/ayudantes):

- Usuario: `Application Support`, `Caches`, `Logs`, `Preferences` (`.plist` y `ByHost/<id>.*`), `Saved Application State/<id>.savedState`, `Containers/<id>`, `Group Containers` (coincidencia con prefijo de equipo), `WebKit/<id>` y `WebKit/com.apple.WebKit.WebContent/<id>`, `HTTPStorages/<id>` (+ `.binarycookies`), `Cookies/<id>.binarycookies`, `Application Scripts/<id>`, `Autosave Information/<id>`, `SyncedPreferences/<id>.plist`, `~/.config/<app>`, `~/.cache/<app>`, `~/.local/share/<app>`.
- Extensiones de la app: `Services/*.workflow`, `QuickLook/*.qlgenerator`, `Internet Plug-Ins`, `Audio/Plug-Ins/{Components,VST,VST3,Digidesign}`, `PreferencePanes`, `Input Methods`, `Screen Savers`, `Frameworks`, `Contextual Menu Items`, `Spotlight/*.mdimporter`, `ColorPickers`, `Workflows`, `Address Book Plug-Ins`, `Accessibility`, `Mail/Bundles`.
- Lanzadores: `~/Library/LaunchAgents/*.plist` cuyo dueño es la app (por id o por programa que apunta dentro del `.app`); se descargan con `launchctl bootout gui/<uid>/<id>`.
- Sistema (sudo): `/Library/{Application Support,Caches,Logs,Preferences}` con el nombre o id, `/Library/LaunchAgents|LaunchDaemons/<id>.plist` (con `sudo launchctl`), `/Library/PrivilegedHelperTools`, recibos de `/private/var/db/receipts`.
- Si la app está instalada con Homebrew Cask, ejecuta `brew uninstall --cask` (o `--zap`).
- Seguridad: no toca restos de apps protegidas del sistema (lista `SYSTEM_CRITICAL_BUNDLES`: en vez de `com.apple.*`, enumera los componentes del sistema para que se puedan desinstalar Xcode, Final Cut, Logic, GarageBand, iWork, etc.); **rechaza** apps de seguridad/MDM/EDR que exigen su desinstalador oficial (ESET, Jamf, CrowdStrike, SentinelOne, GlobalProtect, Cisco Secure Client); cierra la app si está abierta (`osascript` / `pgrep -qx`) antes; comparte datos si otra copia instalada los usa ("shared app paths"); deja en la Papelera por defecto.
- Steam: tratamiento aparte para juegos.

### 5.3 Purgado de artefactos de proyecto (`mo purge`)

**Qué busca (31 nombres):** `node_modules`, `target`, `build`, `dist`, `venv`, `.venv`, `.pytest_cache`, `.mypy_cache`, `.tox`, `.nox`, `.ruff_cache`, `.gradle`, `.terragrunt-cache`, `__pycache__`, `.next`, `.nuxt`, `.output`, `vendor`, `bin`, `obj`, `.turbo`, `.parcel-cache`, `.dart_tool`, `.zig-cache`, `zig-out`, `.angular`, `.svelte-kit`, `.astro`, `coverage`, `DerivedData`, `Pods`, `.cxx`, `.expo`, `.build`. Además reconoce cualquier carpeta marcada con un fichero `CACHEDIR.TAG` con la firma estándar (`Signature: 8a477f597d28d172789f06886806bc55`).

**Dónde:** raíces por defecto `~/www`, `~/dev`, `~/Projects`, `~/GitHub`, `~/Code`, `~/Workspace`, `~/Repos`, `~/Development`, `~/Library/CloudStorage`, `~/.codex/worktrees`, `~/.claude/worktrees` (o las que configure el usuario en `~/.config/mole/purge_paths`, que *sustituyen* a las de por defecto). Profundidad: de 1 a 6 niveles bajo cada raíz. Usa `fd` si está disponible y `find` si no; poda `.git`, `Library`, `.Trash`, `Applications`. Un directorio es "proyecto" si contiene alguno de: `package.json`, `Cargo.toml`, `go.mod`, `pyproject.toml`, `requirements.txt`, `pom.xml`, `build.gradle`, `terragrunt.hcl`, `Gemfile`, `composer.json`, `pubspec.yaml`, `Package.swift`, `Makefile`, `build.zig`, `.git`. Reconoce monorepos (`lerna.json`, `pnpm-workspace.yaml`, `nx.json`, `rush.json`, `.git`).

**Umbral de edad:** `MIN_AGE_DAYS = 7`, pero **no es "proyecto sin tocar"**: es la actividad *dentro del propio artefacto*. Si hay algún archivo modificado en los últimos 7 días dentro del artefacto, o no se puede comprobar (timeout, error), queda **sin seleccionar por defecto** (estado `recent`/`uncertain`); el usuario puede marcarlo. No hay umbral de meses. El criterio de Airy (proyecto entero sin tocar ≥ 3 meses, excluyendo carpetas regenerables) es **más prudente y más acertado** que el de Mole.

**Protecciones por artefacto** (porque el nombre no prueba que sea regenerable):
- Se protege si contiene un repositorio Git anidado o un archivo `*-keypair.json` (claves de despliegue de Anchor/Solana en `target/deploy`).
- Se protege si contiene **archivos rastreados por Git** (`build/` o `coverage/` con código fuente en el repo).
- `bin` solo si el padre tiene `*.csproj|*.fsproj|*.vbproj` y `bin/` contiene `Debug/` o `Release/`.
- `vendor` solo si es de Composer (PHP); los demás `vendor` (Go, etc.) quedan protegidos.
- Debe estar contenido físicamente (sin enlaces simbólicos) dentro de una raíz configurada y a profundidad ≥ 1 (o ser la propia raíz si esta es un proyecto único).
- Se revalida justo antes de borrar. Se borran los artefactos dentro de worktrees, nunca el worktree.
- El borrado es **permanente** (no va a la Papelera); en no interactivo exige `--yes`.
- En `mo clean`, una versión ligera avisa de artefactos con una pista ("Build artifacts · 12.3 GB · run mo purge") excluyendo `bin` y `vendor` por ruido.

---

## 6. Tabla de carencias: lo que cubre Mole y la especificación de Airy no cubre

Recomendación: **Adoptar** (verde o sin riesgo según el catálogo), **Adoptar en ámbar** (se ofrece, nunca preseleccionado en Prudente, y se explica qué se pierde), **Rechazar** (con motivo). Respeta las reglas de Airy: nunca Docker volumes, documentos personales, iCloud, Mail, Mensajes, Llaveros, Fotos, `/System`; la IA y el perfil solo suben el riesgo; todo pasa por confirmación.

Ordenadas por valor esperado (las 10 primeras son las prioritarias).

| # | Carencia (qué hace Mole) | Recomendación | Motivo en una línea |
|---|---|---|---|
| 1 | **Embudo único de borrado con validación de ruta** (absoluta, sin `..`, sin control, enlaces y ancestros simbólicos resueltos, raíces críticas por inodo y sin distinguir mayúsculas, rechazo de `/Users/<yo>`, identidad del archivo comprobada otra vez al borrar) | **Adoptar** | Es la defensa contra el fallo más grave posible (borrar de más); Airy lo especifica a nivel de política, no de motor. |
| 2 | **Guardián de proceso en 3 estados** (corriendo/parado/desconocido) por familia de limpieza, más guardián de caché viva (proceso dueño + manejador SQLite abierto) | **Adoptar** | Evita limpiar bajo los pies de Xcode/pnpm/navegadores y corrupciones; "desconocido" = saltar. |
| 3 | **Lista de protecciones ampliada** (§2.15: UI del sistema, red/VPN, cachés con licencia, plugins de audio, EDR, modelos compilados de Apple Intelligence, CloudKit/Spotlight/FontRegistry, `pypoetry/virtualenvs`, `renv`, `.orbstack`, Codex) y su regla "las protecciones duras siempre se vuelven a mezclar" | **Adoptar** | Años de incidentes reales condensados; el catálogo de Airy solo enumera lo que se limpia. |
| 4 | **Lista blanca de usuario** ("Proteger esto") por ruta/patrón, aplicada por la app y por el MCP | **Adoptar** | Falta por completo en Airy y da control sin pedir permiso para cada limpieza. |
| 5 | **Modo "Vista previa"** (`--dry-run`) y **registro de operaciones** exportable con atribución (`run_id`, app o agente) | **Adoptar** | Airy tiene confirmación e historial, pero no previsualización para el MCP (`dry_run: true`) ni exportación JSON. |
| 6 | **Diagnóstico de rendimiento por reglas** (familias `syspolicyd`/`WindowServer`/Spotlight/CoreSimulator con ≥25 % sostenido en 2 muestras; swap >50 % o libre <15 %; VM de Docker >2 GB sin contenedores; proceso desbocado ≥25 % durante ≥12 h; imágenes de disco montadas que cargan `syspolicyd`) | **Adoptar** | Encaja con la sección Rendimiento y con las frases de "estado general"; son solo lectura y explican causas reales. |
| 7 | **Instaladores** (`.dmg .pkg .mpkg .iso .xip` y `.zip` con instalador) en Descargas/Escritorio/Documentos/caché de Homebrew/Telegram | **Adoptar en ámbar** (verde para la caché de Homebrew y para duplicados claros) | Es el "gran ganador" doméstico; el usuario puede querer conservar un instalador, así que ámbar con lista y antigüedad. |
| 8 | **Catálogo de artefactos de proyecto ampliado** (+ `CACHEDIR.TAG`, `Pods`, `.gradle`, `.dart_tool`, `.build`, `.turbo`, `.angular`, `.svelte-kit`, `.astro`, `.tox`, `__pycache__`…) y **guardias**: repositorio anidado, claves `*-keypair.json`, archivos rastreados por Git, `bin`/`vendor` solo si son .NET/Composer | **Adoptar en ámbar** | Airy lista 5 carpetas; faltan guardias que eviten borrar `build/` con código o `target/deploy` con claves. |
| 9 | **Limpieza completa de navegadores Chromium** (todos los derivados, `Code Cache`, `GPUCache`, `Dawn*`, `ShaderCache`, `component_crx_cache`, `Crashpad/completed`, Service Worker CacheStorage, versiones antiguas del framework dentro del `.app`) y heurística genérica de Application Support con marcadores de caché regenerable | **Adoptar** | Mucho espacio sin tocar perfil; Airy menciona Brave/Chrome/Safari pero no la lista fina ni las versiones antiguas. |
| 10 | **Reglas de huérfanos por bundle id** (inventario completo o nada, 30 días de reposo, `mdfind` con fallo = instalada, solo Caches/Logs/Saved State, nunca Containers/Group Containers/LaunchAgents/Application Scripts, patrones sensibles `ssh/gpg/keychain/1password…`) | **Adoptar** | Define con precisión cuándo un resto es huérfano y evita el falso positivo que borra datos de una app viva. |
| 11 | **Categoría "solo revisar"** (Xcode Archives, copias de iOS, emuladores Android, modelos LM Studio/HF, Maven/NuGet/Gradle, JetBrains antiguo, Docker/OrbStack, snapshots de Time Machine, worktrees de agentes) sin botón de borrar automático | **Adoptar** (rojo/ámbar sin acción, o ámbar con confirmación fuerte) | Coincide con las tres etiquetas de Airy: se muestran, se explican, el usuario decide. |
| 12 | **Xcode más fino**: conservar las N=2 versiones más recientes de DeviceSupport (iOS/watchOS/tvOS), XCTestDevices, DocumentationCache, Products, IB Support, `simctl runtime delete` de runtimes huérfanos, solo con Xcode y simuladores parados | **Adoptar** | Airy dice "iOS DeviceSupport antiguos" sin definir cuáles; Mole define la regla de retención. |
| 13 | **Catálogo largo de cachés de desarrollo** (Go vía `go env`, Poetry/pyenv/Ruff/mypy, Ruby/Bundler, Composer, Hex, Opam, Bazel, Terraform, kube, AWS/gcloud/Azure, Electron/node-gyp/webpack/vite/prisma, Expo, Android, Swift PM, Flutter, Corepack) con **cmd oficial** si existe | **Adoptar** (verde); excepciones en ámbar: `ms-playwright`, Gradle, JetBrains, `.ollama/models`, `renv`, tldr, `pypoetry/virtualenvs` (rojo) | Aprovecha el perfil "Programo"; conviene que el catálogo sea datos (JSON/Plist), no código. |
| 14 | **Cachés de apps de usuario** (comunicación, creativas, medios, juegos, utilidades, oficina, VM) | **Adoptar**, ordenadas por perfil | El perfil de Airy ya reordena esto; hacen falta las entradas. Solo `Caches` y `Data/Library/Caches`/`Data/tmp`; **rechazar** los cachés de Mensajes (`Messages/*Cache*`) y `com.apple.mail/*` y `Mail Downloads`. |
| 15 | **Sistema con contraseña de administrador**: `/Library/Logs/DiagnosticReports`, logs de `/private/var/log` y `/Library/Caches` antiguos (7 días), instaladores de macOS ("Install macOS *.app" de más de 14 días y no actuales), temporales abortados de `idleassetsd` (cientos de GB en "Datos del sistema") | **Adoptar en ámbar** (instaladores y `idleassetsd`); **adoptar en verde** los informes de fallos del propio usuario `~/Library/Logs/DiagnosticReports` | Recupera "Datos del sistema" opaco; todo exige contraseña del sistema y confirmación, nada preseleccionado. |
| 16 | **Cachés de GPU y clones de firma bajo `/private/var/folders`** | **Rechazar** | Ruta crítica protegida, ganancia de MB y riesgo de disparar detección EDR; Mole lo limita con muchas reservas. |
| 17 | **Auditoría de elementos de inicio** (LaunchAgents con binario inexistente, login items rotos) | **Adoptar en ámbar, solo informe** | Sección útil de Rendimiento ("arranque lento"); no borrar, enlazar a Ajustes del Sistema. |
| 18 | **Métricas de estado que faltan**: batería (ciclos, salud, amperaje), E/S de disco (MB/s), red por interfaz con detección de túnel, GPU, tiempo encendido, zombis con padre, CPU por núcleo (P/E), proxy | **Adoptar** (excepto GPU y sensores privados) | Todas con interfaces estables (IOKit batería, contadores del sistema, `getifaddrs`); Airy solo tiene memoria, swap, estado térmico y CPU. |
| 19 | **Temperatura en grados y ventiladores** (sensores IOHID privados, `powermetrics`) | **Rechazar por ahora** (revisar en una fase posterior como "experimental" y oculto por defecto) | Coherente con la decisión de Airy: API privada que se puede romper con cada macOS; el estado térmico oficial basta. |
| 20 | **Puntuación de salud global** (CPU, memoria, disco, S.M.A.R.T., E/S, térmico, batería, uptime) | **Adoptar** (como frase y semáforo, no solo número) | Resume el estado en un vistazo y alimenta el "estado general" por reglas fijas que Airy ya quiere. |
| 21 | **`optimize` útil**: `defaults write DSDontWriteNetworkStores/DSDontWriteUSBStores`, borrar tweaks heredados (`NSAppSleepDisabled`, `skip-verify*`), diagnóstico de Spotlight con medición previa antes de reindexar (`mdutil -E /`, 1-2 h), reparar `.plist`/`.sfl*` corruptos, compactar BD de notificaciones | **Adoptar en ámbar** (con descripción honesta y reversibilidad) | Reales y reversibles; la reindexación de Spotlight solo con búsqueda medida como lenta y con corriente. |
| 22 | **`optimize` placebo**: vaciar DNS, reiniciar red (`route -n flush`, `arp -d`), `periodic daily weekly monthly`, "reconstruir" Launch Services, `purge` de memoria, reiniciar el Dock | **Rechazar** | Sin beneficio medible o con efectos secundarios (cortes de VPN). Mole mismo retiró varias. |
| 23 | **Compactar bases SQLite de Mail, Mensajes y Safari** (`VACUUM`) | **Rechazar** Mail y Mensajes (rojo en Airy); Safari **adoptar en ámbar** solo con Safari cerrado | Mail/Mensajes son zona prohibida; el beneficio es pequeño frente al riesgo de corrupción. |
| 24 | **Limpieza de historial de privacidad** (`QuarantineEventsV2`, `knowledgeC.db` >90 días) | **Adoptar en ámbar** (opcional, sin preselección) | Tema de privacidad más que de espacio; borra historial, no cachés. |
| 25 | **Vaciar la Papelera automáticamente** | **Rechazar** | Airy ya decidió que lo hace el usuario con un botón. |
| 26 | **Eliminar `.DS_Store`** | **Rechazar** | Mole mismo lo deja protegido por defecto; ganancia nula. |
| 27 | **Servicios huérfanos de sistema** (LaunchDaemons/helpers sin binario) y **stubs de contenedores** | **Rechazar el borrado**, **adoptar solo informe** | Lista enorme de falsos positivos conocidos, requiere sudo y puede romper arranques. |
| 28 | **Copias de Time Machine `.inProgress` fallidas** (>48 h) | **Rechazar** (mostrar como "solo revisar") | Airy no toca copias de seguridad; las instantáneas locales sí las ofrece con `tmutil`, Mole solo las cuenta. |
| 29 | **Desinstalador: ubicaciones extra y proceso completo** (WebKit, HTTPStorages, Cookies binarios, Application Scripts, Autosave Information, SyncedPreferences, plugins de audio/Servicios/Quick Look, ByHost, recibos `pkgutil`, `launchctl bootout` de ayudantes, `brew uninstall --cask [--zap]`, cierre de la app abierta, restos del sistema con contraseña, **negativa para apps de seguridad/MDM**) | **Adoptar** (restos de `/Library` en ámbar con contraseña; plugins de audio en ámbar) | Airy lista 8 ubicaciones; Mole demuestra que faltan unas 15 y que hay apps que no se deben desinstalar a mano. |
| 30 | **Retirada de versiones antiguas de agentes de IA** (Claude Code, Cursor Agent, Copilot CLI, runtimes de Codex; conserva la activa y 1 anterior) | **Adoptar** (verde, solo versiones no activas) | Relevante para el perfil "Programo/IA"; regla de retención clara. |
| 31 | **Honestidad de escaneo** (`scan_status`: completo/parcial/no disponible; tamaño con `+` si parcial) | **Adoptar** | Refuerza el anti-objetivo "mentir con números". |
| 32 | **Presupuestos de tiempo y fallo cerrado** en cada sondeo | **Adoptar** (como requisito de ingeniería) | Un disco grande o lento no debe colgar la app ni borrar con datos dudosos. |
| 33 | **Firmware de dispositivos** (`.ipsw` en `~/Library/iTunes/*Software Updates`, Apple Configurator) | **Adoptar** (verde) | Fácil de recuperar (se vuelve a descargar) y suele ocupar varios GB. |
| 34 | **Touch ID para sudo** (`mo touchid`), autocompletado, actualización propia, lanzadores Raycast/Alfred | **Rechazar** (salvo `airy://` + atajo si se quiere) | Airy usa el diálogo de contraseña del sistema; no es función de producto. |

### Las 10 mayores carencias, en una línea

1. Embudo único de borrado con validación de ruta y comprobación de identidad al borrar (#1).
2. Guardián de proceso en tres estados antes de limpiar cada familia (#2).
3. Lista de protecciones duras mucho más amplia, siempre re-mezclada (#3).
4. Lista blanca de usuario ("proteger esto") compartida con el MCP (#4).
5. Vista previa y registro exportable de operaciones, también para agentes (#5).
6. Diagnóstico de rendimiento por reglas con causas reales (#6).
7. Instaladores `.dmg/.pkg/.iso/.xip/.zip` como objetivo ámbar (#7).
8. Catálogo de artefactos de proyecto ampliado con guardias de Git, claves y repos anidados (#8).
9. Limpieza fina de navegadores Chromium y heurística de caché regenerable en Application Support (#9).
10. Reglas precisas de huérfanos por bundle id (#10).

---

## 7. Cosas que Airy ya hace mejor que Mole (conviene conservar)

- **Docker:** prunes oficiales de builder, imágenes, contenedores y redes. Mole solo avisa. Mantener el veto a volúmenes.
- **Confirmación única con lista completa**, selección múltiple y "Borrar todo": Mole mezcla borrado directo y selección en TUI.
- **Papelera por defecto** para archivos: Mole vacía la Papelera y purga permanentemente `node_modules` y similares. Airy es recuperable.
- **Criterio de "proyecto sin tocar ≥ 3 meses"** frente a los 7 días de actividad dentro del artefacto.
- **Perfil de uso** que reordena sin bajar riesgos: Mole es igual para todos.
- **Modelos de IA (Ollama, HF, whisper)**: Mole los protege o solo los revisa; Airy los trata como parte del catálogo con comprobación de referencias.
- **Instantáneas locales de Time Machine**: Mole solo las cuenta.
- **MCP** para agentes: Mole solo tiene CLI y `--json`.
- **Sin placebos** de optimización: la decisión de no tener "liberar RAM" queda respaldada por el propio historial de Mole.
