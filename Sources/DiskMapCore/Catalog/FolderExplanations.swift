import Foundation

/// Explicaciones breves de carpetas conocidas que no tienen ficha en el catálogo.
public enum FolderExplanations {
    private static let system: [String: String] = [
        "/Applications": "Tus aplicaciones.",
        "/System": "El sistema operativo; no se toca.",
        "/Users": "Las carpetas personales de cada usuario de este Mac.",
        "/Library": "Ajustes y componentes que comparten todas las apps y usuarios.",
        "/private": "Datos internos del sistema: memoria virtual, temporales y registros.",
        "/private/var": "Datos variables del sistema: registros, cachés y memoria virtual.",
        "/private/var/vm": "Memoria virtual y la imagen de reposo del Mac; la gestiona macOS.",
        "/usr": "Herramientas de Unix del sistema y lo que instalan algunos programas.",
        "/opt": "Software instalado aparte del sistema.",
        "/opt/homebrew": "Homebrew y los paquetes que has instalado con él.",
        "/Volumes": "Discos externos y volúmenes montados.",
        "/cores": "Volcados de memoria de programas que se cerraron de golpe.",
    ]

    private static let home: [String: String] = [
        "": "Tu carpeta personal.",
        "Library": "Ajustes, cachés y datos de las apps.",
        "Library/Application Support": "Datos que guardan las apps para funcionar.",
        "Library/Containers": "Datos de las apps que funcionan en entorno aislado.",
        "Library/Group Containers": "Datos que comparten varias apps del mismo desarrollador.",
        "Documents": "Tus documentos.",
        "Desktop": "Lo que tienes en el escritorio.",
        "Downloads": "Lo que has descargado.",
        "Movies": "Tus vídeos y proyectos de vídeo.",
        "Pictures": "Tus fotos, incluida la fototeca.",
        "Music": "Tu música y bibliotecas de audio.",
        "Applications": "Apps instaladas solo para tu usuario.",
        ".Trash": "La Papelera: no libera espacio hasta que la vacías.",
    ]

    public static func text(for path: String, home homePath: String = NSHomeDirectory()) -> String? {
        if let text = system[path] { return text }
        let base = homePath.hasSuffix("/") ? String(homePath.dropLast()) : homePath
        if path == base { return home[""] }
        guard path.hasPrefix(base + "/") else { return nil }
        return home[String(path.dropFirst(base.count + 1))]
    }
}
