#!/usr/bin/env swift
// Lists the localization keys used in `Sources/Airy` that are missing from `Resources/Localizable.xcstrings`.
//
//   swift scripts/i18n-check.swift
//
// The keys come from the compiler itself (`-emit-localized-strings`), so they match exactly what the app
// looks up at runtime: `Text("…")`, `Button("…")`, `.help("…")`, `String(localized: "…")` and so on, with
// interpolations already turned into format specifiers (`%@`, `%lld`…). The build goes to its own scratch
// folder (`.build/i18n-check`) so it doesn't invalidate the regular `.build`.
// Exit status: 0 if every key is in the catalog with a Spanish translation, 1 otherwise.
import Foundation

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
    .standardizedFileURL
let sources = root.appendingPathComponent("Sources/Airy").path + "/"
let catalogURL = root.appendingPathComponent("Resources/Localizable.xcstrings")
let scratch = root.appendingPathComponent(".build/i18n-check")
let stringsDir = scratch.appendingPathComponent("stringsdata")

// Files compiled only in DEBUG builds: their strings are for development and aren't translated.
let debugOnly: Set<String> = ["Design/MotionGallery.swift", "Shell/DebugSnapshot.swift"]

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

// 1. Build the app target emitting the localizable strings. The build is incremental: only recompiled files
// rewrite their `.stringsdata`, so the folder is kept between runs; without it, the build starts from scratch.
let fileManager = FileManager.default
let existing = (try? fileManager.contentsOfDirectory(atPath: stringsDir.path)) ?? []
if existing.isEmpty { try? fileManager.removeItem(at: scratch) }
try? fileManager.createDirectory(at: stringsDir, withIntermediateDirectories: true)
let build = Process()
build.executableURL = URL(fileURLWithPath: "/usr/bin/env")
build.currentDirectoryURL = root
build.arguments = ["swift", "build", "--target", "Airy", "--scratch-path", scratch.path,
                   "-Xswiftc", "-emit-localized-strings",
                   "-Xswiftc", "-emit-localized-strings-path", "-Xswiftc", stringsDir.path]
let log = Pipe()
build.standardOutput = log
build.standardError = log
do { try build.run() } catch { fail("Couldn't run swift build: \(error)") }
let output = log.fileHandleForReading.readDataToEndOfFile()
build.waitUntilExit()
guard build.terminationStatus == 0 else {
    FileHandle.standardError.write(output)
    fail("swift build failed (status \(build.terminationStatus)).")
}

// 2. Keys used in Sources/Airy, with their first location.
var used: [String: String] = [:]
let files = (try? fileManager.contentsOfDirectory(at: stringsDir, includingPropertiesForKeys: nil)) ?? []
for file in files where file.pathExtension == "stringsdata" {
    guard let data = try? Data(contentsOf: file),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let source = json["source"] as? String, source.hasPrefix(sources) else { continue }
    let relative = String(source.dropFirst(sources.count))
    // A deleted source file can leave its `.stringsdata` behind.
    guard !debugOnly.contains(relative), fileManager.fileExists(atPath: source) else { continue }
    let tables = json["tables"] as? [String: [[String: Any]]] ?? [:]
    for entry in tables["Localizable"] ?? [] {
        guard let key = entry["key"] as? String else { continue }
        // Keys with no letters ("—", "%@", "%lld%%") need no translation.
        guard key.replacingOccurrences(of: "%[0-9$]*(@|lld|ld|d|lf|f)", with: "", options: .regularExpression)
            .rangeOfCharacter(from: .letters) != nil else { continue }
        let line = (entry["location"] as? [String: Any])?["startingLine"] as? Int ?? 0
        if used[key] == nil { used[key] = "\(relative):\(line)" }
    }
}

// 3. Compare with the catalog.
guard let data = try? Data(contentsOf: catalogURL),
      let catalog = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let strings = catalog["strings"] as? [String: [String: Any]] else { fail("Couldn't read \(catalogURL.path).") }

func spanish(_ key: String) -> String? {
    let localizations = strings[key]?["localizations"] as? [String: Any]
    let unit = (localizations?["es"] as? [String: Any])?["stringUnit"] as? [String: Any]
    return unit?["value"] as? String
}

let missing = used.keys.filter { spanish($0) == nil }.sorted()
let unused = strings.keys.filter { used[$0] == nil }.sorted()

for key in missing { print("missing: \(used[key]!)  \(key.debugDescription)") }
if !unused.isEmpty {
    print("\(unused.count) catalog keys not found in Sources/Airy (DiskMapCore or DEBUG-only strings, or stale):")
    for key in unused { print("  unused: \(key.debugDescription)") }
}
print("\(used.count) keys used in Sources/Airy, \(missing.count) missing from the catalog.")
exit(missing.isEmpty ? 0 : 1)
