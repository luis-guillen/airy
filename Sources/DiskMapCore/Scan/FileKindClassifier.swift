import Foundation

/// Asigna un `ContentKind` a archivos (por extensión) y a carpetas conocidas (por nombre o ruta).
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

    /// Variante con contexto: un `.raw` dentro de `com.docker.docker` es el disco de la VM, no una foto.
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
