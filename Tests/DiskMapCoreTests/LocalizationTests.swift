import Foundation
import Testing
@testable import DiskMapCore

/// DiskMapCore's text is English in source; Spanish comes from `Localizable.xcstrings` and the `"es"` objects of
/// catalog.json and apps.json. These tests pin the Spanish lookups explicitly (never through the process's
/// language), so they pass on any machine.
/// `true` when the build compiled the String Catalog into `.lproj` tables. Some toolchains (e.g. the Swift
/// 6.3 SwiftPM on GitHub's runners) copy the `.xcstrings` without compiling it; the release app is built
/// with a toolchain that does. `catalogSourceHasEverySpanishTranslation` checks the source either way.
private let compiledTablesAvailable =
    Bundle.airyCore(language: "es").url(forResource: "Localizable", withExtension: "strings") != nil

@Suite struct LocalizationTests {
    private let spanish = Bundle.airyCore(language: "es")

    @Test(.enabled(if: compiledTablesAvailable)) func riskLabelsResolveInSpanish() {
        #expect(String(localized: "Safe to remove", bundle: spanish) == "Sin problema")
        #expect(String(localized: "Your call", bundle: spanish) == "Tú decides")
        #expect(String(localized: "Don't delete", bundle: spanish) == "No borrar")
    }

    @Test func englishAndUnsupportedLanguagesGiveTheSourceStrings() {
        #expect(String(localized: "Safe to remove", bundle: .airyCore(language: "en")) == "Safe to remove")
        #expect(String(localized: "Your call", bundle: .airyCore(language: "fr")) == "Your call")
        // The test process ships no localizations of its own, so it runs in English.
        #expect(Risk.safe.label == "Safe to remove")
    }

    @Test(.enabled(if: compiledTablesAvailable)) func interpolatedStringsKeepTheirArguments() {
        let size = "2 GB"
        #expect(String(localized: "Freed \(size)", bundle: spanish) == "Liberados 2 GB")
        let count = 3
        #expect(String(localized: "Partial scan: \(count) folders could not be read", bundle: spanish)
                == "Análisis parcial: no se pudieron leer 3 carpetas")
    }

    @Test(.enabled(if: compiledTablesAvailable)) func everyEnglishKeyHasASpanishTranslation() throws {
        func table(_ language: String) throws -> [String: String] {
            let bundle = Bundle.airyCore(language: language)
            let url = try #require(bundle.url(forResource: "Localizable", withExtension: "strings"),
                                   "\(language).lproj/Localizable.strings is missing")
            return try #require(NSDictionary(contentsOf: url) as? [String: String])
        }
        let english = try table("en"), spanish = try table("es")
        #expect(!english.isEmpty)
        #expect(Set(english.keys) == Set(spanish.keys))
        #expect(spanish.values.allSatisfy { !$0.isEmpty })
    }

    @Test func catalogSourceHasEverySpanishTranslation() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/DiskMapCore/Resources/Localizable.xcstrings")
        let root = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(root["sourceLanguage"] as? String == "en")
        let strings = try #require(root["strings"] as? [String: [String: Any]])
        #expect(!strings.isEmpty)
        for (key, value) in strings {
            let unit = ((value["localizations"] as? [String: Any])?["es"] as? [String: Any])?["stringUnit"] as? [String: Any]
            let variations = ((value["localizations"] as? [String: Any])?["es"] as? [String: Any])?["variations"]
            #expect(unit?["state"] as? String == "translated" || variations != nil, "\(key)")
        }
        let labels = ["Safe to remove": "Sin problema", "Your call": "Tú decides", "Don't delete": "No borrar",
                      "Airy won’t delete this whole folder, but you can clean what’s inside.":
                        "Airy no borrará la carpeta entera, pero sí puedes limpiar lo que hay dentro.",
                      "Neither this folder nor anything inside it is deleted.": "Ni esta carpeta ni lo que contiene se borran."]
        for (key, expected) in labels {
            let unit = ((strings[key]?["localizations"] as? [String: Any])?["es"] as? [String: Any])?["stringUnit"] as? [String: Any]
            #expect(unit?["value"] as? String == expected, "\(key)")
        }
    }

    @Test func languageResolutionFallsBackToEnglish() {
        #expect(AiryLanguage.resolve(["es-ES", "en-ES"]) == "es")
        #expect(AiryLanguage.resolve(["fr-FR", "en-GB"]) == "en")
        #expect(AiryLanguage.resolve(["de"]) == "en")
        #expect(AiryLanguage.resolve([]) == "en")
        #expect(AiryLanguage.englishName(of: "es") == "Spanish")
    }

    @Test func catalogEntryResolvesInSpanishAndKeepsEverythingElse() throws {
        let english = try #require(try Catalog.bundled(language: "en").entry(id: "docker-build-cache"))
        let spanish = try #require(try Catalog.bundled(language: "es").entry(id: "docker-build-cache"))
        #expect(english.title == "Docker build cache")
        #expect(spanish.title == "Caché de compilación de Docker")
        #expect(spanish.shortReason == "Docker la vuelve a descargar o construir cuando la necesita.")
        #expect(spanish.language == "es" && english.language == "en")
        #expect(spanish.id == english.id && spanish.risk == english.risk && spanish.paths == english.paths)
        #expect(spanish.cleanup == english.cleanup)
        // Back to English, and encoding always writes the English base fields plus the translation.
        #expect(spanish.localized(to: "en").title == english.title)
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(spanish)) as? [String: Any])
        #expect(object["title"] as? String == "Docker build cache")
        #expect((object["es"] as? [String: Any])?["title"] as? String == "Caché de compilación de Docker")
    }

    @Test func everyCatalogAndAppEntryHasASpanishExplanation() throws {
        for entry in try Catalog.bundled(language: "en").entries {
            #expect(entry.translations["es"]?.explanation?.isEmpty == false, "\(entry.id)")
        }
        let apps = try AppCatalog.bundled(executableURL: nil, searchProcessBundles: true, language: "es")
        for entry in apps.entries {
            #expect(entry.language == "es" && entry.translations["es"]?.explanation != nil, "\(entry.id)")
        }
        #expect(apps.entry(bundleID: "com.google.Chrome", processName: "")?.explanation.hasPrefix("Navegador de Google") == true)
    }

    @Test func claudeIsAskedToReplyInTheUsersLanguage() {
        #expect(AIAssistant.systemPrompt(language: "es").contains("Always reply in Spanish"))
        #expect(AIAssistant.performanceSystemPrompt(language: "es").contains("Always reply in Spanish"))
        #expect(AIAssistant.systemPrompt.contains("Always reply in English"))
    }
}
