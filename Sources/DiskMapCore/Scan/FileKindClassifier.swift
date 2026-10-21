import Foundation

/// Assigns a `ContentKind` to files (by extension) and to well-known folders (by name or path).
public enum FileKindClassifier {
    fileprivate static let extensionKinds: [String: ContentKind] = {
        var map: [String: ContentKind] = [:]
        func add(_ kind: ContentKind, _ extensions: String) {
            for ext in extensions.split(separator: " ") { map[String(ext)] = kind }
        }
        add(.video, "mp4 mov mkv avi m4v webm")
        add(.images, "jpg jpeg png heic gif tiff raw cr2 psd webp")
        add(.code, "swift py js ts rs go java c cpp h json lock")
        add(.aiModels, "gguf safetensors pt pth bin ckpt onnx mlmodel npz ort")
        add(.containers, "vmdk qcow2 img dmg iso")
        add(.documents, "pdf doc docx xls xlsx ppt pptx key pages numbers txt md")
        return map
    }()

    private static let directoryNameKinds: [String: ContentKind] = [
        "node_modules": .code, ".git": .code, ".venv": .code, "target": .code, ".build": .code,
        "Caches": .caches, ".cache": .caches, "DerivedData": .caches,
        "huggingface": .aiModels, ".ollama": .aiModels, "whisper": .aiModels,
        "com.docker.docker": .containers,
    ]

    private static let systemPaths: Set<String> = ["/System", "/usr", "/private", "/Library"]

    fileprivate static let dockerDirectory = "com.docker.docker"

    public static func kind(forFileNamed name: String) -> ContentKind {
        let ext = (name as NSString).pathExtension.lowercased()
        return extensionKinds[ext] ?? .other
    }

    /// Variant with context: a `.raw` inside `com.docker.docker` is the VM's disk, not a photo.
    static func kind(forFileNamed name: String, inDirectoryPath directory: String) -> ContentKind {
        if (name as NSString).pathExtension.lowercased() == "raw",
           directory.split(separator: "/").contains(Substring(dockerDirectory)) {
            return .containers
        }
        return kind(forFileNamed: name)
    }

    public static func kind(forDirectoryPath path: String) -> ContentKind? {
        if systemPaths.contains(path) { return .system }
        let name = (path as NSString).lastPathComponent
        if name.hasSuffix(".app") { return .apps }
        return directoryNameKinds[name]
    }
}

extension FileKindClassifier {
    /// Longest extension in `extensionKinds` ("safetensors").
    private static let longestExtension = 11

    /// The same answer as `kind(forFileNamed:inDirectoryPath:)` for the raw UTF-8 bytes of a name, without
    /// building a `String` or going through `NSString`: the usual case (a plain ASCII letters-and-digits extension
    /// after a name that does not start with a dot) is resolved here; anything else asks `NSString`.
    static func kind(forFileNameBytes name: UnsafeBufferPointer<UInt8>, inDirectoryPath directory: String) -> ContentKind {
        let dot = UInt8(ascii: ".")
        guard let last = name.lastIndex(of: dot) else { return .other }   // no extension
        guard last > 0, name[0] != dot, last < name.count - 1 else {
            return kind(forFileNamed: String(decoding: name, as: UTF8.self), inDirectoryPath: directory)
        }
        let tail = UnsafeBufferPointer(rebasing: name[(last + 1)...])
        for byte in tail {
            switch byte {
            case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"): continue
            default:
                return kind(forFileNamed: String(decoding: name, as: UTF8.self), inDirectoryPath: directory)
            }
        }
        guard tail.count <= longestExtension else { return .other }
        // Short enough to be a small (inline) string: no allocation.
        let ext = String(unsafeUninitializedCapacity: tail.count) { buffer in
            for (index, byte) in tail.enumerated() {
                buffer[index] = byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z") ? byte + 32 : byte
            }
            return tail.count
        }
        if ext == "raw", directory.split(separator: "/").contains(Substring(dockerDirectory)) { return .containers }
        return extensionKinds[ext] ?? .other
    }
}
