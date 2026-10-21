import Foundation

/// Casks de Homebrew instalados: nombre del `.app` → token.
public enum HomebrewCasks {
    /// `brew info --cask --installed --json=v2` (60 s) → [nombre del .app: token]. `nil` si brew no está o falla.
    public static func installed(runner: any CommandRunning) async -> [String: String]? {
        guard let brew = await runner.resolve("brew") else { return nil }
        guard let output = try? await runner.run(
            brew, ["info", "--cask", "--installed", "--json=v2"], timeout: 60),
            output.status == 0 else { return nil }
        return parse(output.stdout)
    }

    /// `casks[].token` y `casks[].artifacts[].app` (cadenas u objetos `{"target": …}`).
    static func parse(_ json: String) -> [String: String] {
        guard let root = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let casks = root["casks"] as? [[String: Any]] else { return [:] }
        var result: [String: String] = [:]
        for cask in casks {
            guard let token = cask["token"] as? String, !token.isEmpty,
                  let artifacts = cask["artifacts"] as? [Any] else { continue }
            for artifact in artifacts {
                guard let dict = artifact as? [String: Any], let apps = dict["app"] as? [Any] else { continue }
                for app in apps {
                    var name: String?
                    if let string = app as? String {
                        name = string
                    } else if let object = app as? [String: Any] {
                        name = object["target"] as? String
                    }
                    if let name {
                        let last = (name as NSString).lastPathComponent
                        if last.hasSuffix(".app") { result[last] = token }
                    }
                }
            }
        }
        return result
    }
}
