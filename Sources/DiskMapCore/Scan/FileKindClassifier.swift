import Foundation

/// Assigns a `ContentKind` to files (by extension) and to well-known folders (by name or path).
public enum FileKindClassifier {
    private static let extensionKinds: [String: ContentKind] = {
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

    private static let dockerDirectory = "com.docker.docker"

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
