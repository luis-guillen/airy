#!/usr/bin/env swift
// Genera el icono de Airy con CoreGraphics.
//
//   swift scripts/make-icon.swift Resources/
//
// Escribe en la carpeta indicada:
//   Airy-1024.png   maestro de 1024×1024
//   Airy.icns       todos los tamaños (16…1024, @1x/@2x)
//
// Los tamaños de 64 px en adelante salen del maestro con `sips`. Los de 16 y 32 px se dibujan
// directamente a su tamaño con una versión simplificada (menos bloques, separaciones de 1 px
// alineadas a píxel), porque el treemap de 6 bloques reducido se convierte en una mancha.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: Colores

struct RGB {
    var r, g, b: CGFloat
    init(_ hex: UInt32) {
        r = CGFloat((hex >> 16) & 0xFF) / 255
        g = CGFloat((hex >> 8) & 0xFF) / 255
        b = CGFloat(hex & 0xFF) / 255
    }
    init(r: CGFloat, g: CGFloat, b: CGFloat) { self.r = r; self.g = g; self.b = b }
    func mixed(with o: RGB, _ t: CGFloat) -> RGB {
        RGB(r: r + (o.r - r) * t, g: g + (o.g - g) * t, b: b + (o.b - b) * t)
    }
    func cg(_ a: CGFloat = 1) -> CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
}

let white = RGB(0xFFFFFF)
let black = RGB(0x000000)

// Paleta del proyecto (global-constraints).
let video = RGB(0xFF375F)
let code = RGB(0x0A84FF)
let apps = RGB(0xBF5AF2)
let aiModels = RGB(0x64D2FF)
let caches = RGB(0x30D158)
let documents = RGB(0xFFD60A)

let bgTop = RGB(0x1C1C2E)
let bgBottom = RGB(0x0B0B12)

// MARK: Formas

/// Rectángulo con esquinas "continuas" de Apple: cada esquina es un cuarto de superelipse en lugar
/// de un arco de circunferencia. La curva empieza a ≈1,53·radio del vértice (como las esquinas
/// continuas del sistema) y n≈3,3 deja el punto a 45° donde estaría el de un arco de `radius`,
/// así que el tamaño aparente coincide pero sin el salto de curvatura en la unión con los lados.
func continuousRect(_ r: CGRect, radius: CGFloat) -> CGPath {
    let rho = min(radius * 1.528, min(r.width, r.height) / 2)
    let n: CGFloat = 3.3
    let p = CGMutablePath()
    // Centros de las esquinas en orden: arriba-dcha, abajo-dcha, abajo-izda, arriba-izda (origen arriba).
    let corners: [(CGPoint, CGFloat)] = [
        (CGPoint(x: r.maxX - rho, y: r.minY + rho), -.pi / 2),
        (CGPoint(x: r.maxX - rho, y: r.maxY - rho), 0),
        (CGPoint(x: r.minX + rho, y: r.maxY - rho), .pi / 2),
        (CGPoint(x: r.minX + rho, y: r.minY + rho), .pi),
    ]
    let steps = 48
    var first = true
    for (c, start) in corners {
        for i in 0...steps {
            let t = start + CGFloat(i) / CGFloat(steps) * (.pi / 2)
            let ct = cos(t), st = sin(t)
            let x = c.x + rho * (ct < 0 ? -1 : 1) * pow(abs(ct), 2 / n)
            let y = c.y + rho * (st < 0 ? -1 : 1) * pow(abs(st), 2 / n)
            if first { p.move(to: CGPoint(x: x, y: y)); first = false } else { p.addLine(to: CGPoint(x: x, y: y)) }
        }
    }
    p.closeSubpath()
    return p
}

func linear(_ ctx: CGContext, _ stops: [(RGB, CGFloat, CGFloat)], from a: CGPoint, to b: CGPoint) {
    let colors = stops.map { $0.0.cg($0.1) } as CFArray
    let locs = stops.map { $0.2 }
    let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: locs)!
    ctx.drawLinearGradient(g, start: a, end: b, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

func radial(_ ctx: CGContext, _ stops: [(RGB, CGFloat, CGFloat)], center: CGPoint, radius: CGFloat) {
    let colors = stops.map { $0.0.cg($0.1) } as CFArray
    let locs = stops.map { $0.2 }
    let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: locs)!
    ctx.drawRadialGradient(g, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
}

// MARK: Dibujo

struct Block {
    var color: RGB
    var x0, y0, x1, y1: CGFloat  // fracciones del panel (origen arriba-izquierda)
}

/// Treemap completo: 6 tipos, como un mapa real (vídeo domina).
let fullLayout: [Block] = [
    Block(color: video, x0: 0, y0: 0, x1: 0.58, y1: 0.60),
    Block(color: code, x0: 0.58, y0: 0, x1: 1, y1: 0.36),
    Block(color: apps, x0: 0.58, y0: 0.36, x1: 1, y1: 0.60),
    Block(color: aiModels, x0: 0, y0: 0.60, x1: 0.36, y1: 1),
    Block(color: caches, x0: 0.36, y0: 0.60, x1: 0.72, y1: 1),
    Block(color: documents, x0: 0.72, y0: 0.60, x1: 1, y1: 1),
]

/// Versión para 16/32 px: 4 bloques grandes y legibles.
let smallLayout: [Block] = [
    Block(color: video, x0: 0, y0: 0, x1: 0.58, y1: 0.58),
    Block(color: code, x0: 0.58, y0: 0, x1: 1, y1: 0.58),
    Block(color: caches, x0: 0, y0: 0.58, x1: 0.42, y1: 1),
    Block(color: documents, x0: 0.42, y0: 0.58, x1: 1, y1: 1),
]

/// Dibuja el icono en un lienzo de `px`×`px` píxeles. Todo se expresa en la rejilla de 1024
/// de Apple y se escala; `small` activa la variante simplificada con separaciones a píxel.
func renderIcon(px: Int, small: Bool) -> CGImage {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let k = CGFloat(px) / 1024  // píxeles por unidad de la rejilla
    ctx.interpolationQuality = .high
    ctx.setShouldAntialias(true)
    // Origen arriba-izquierda, en unidades de 1024.
    ctx.translateBy(x: 0, y: CGFloat(px))
    ctx.scaleBy(x: k, y: -k)

    // Las sombras van en espacio de dispositivo (no les afecta la CTM): y negativa = hacia abajo.
    func shadow(dy: CGFloat, blur: CGFloat, alpha: CGFloat) {
        ctx.setShadow(offset: CGSize(width: 0, height: -dy * k), blur: blur * k, color: black.cg(alpha))
    }

    // Rejilla de Apple: 100 px de margen, radio continuo ≈185 px.
    let squircleRect = CGRect(x: 100, y: 100, width: 824, height: 824)
    let squircle = continuousRect(squircleRect, radius: 185)

    // 1. Sombra del squircle (como los iconos de Apple: suave, desplazada hacia abajo).
    ctx.saveGState()
    shadow(dy: small ? 6 : 12, blur: small ? 14 : 28, alpha: 0.42)
    ctx.addPath(squircle)
    ctx.setFillColor(bgBottom.cg())
    ctx.fillPath()
    ctx.restoreGState()

    // 2. Fondo: degradado profundo.
    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()
    linear(ctx, [(bgTop, 1, 0), (bgTop.mixed(with: bgBottom, 0.55), 1, 0.55), (bgBottom, 1, 1)],
           from: CGPoint(x: 512, y: 100), to: CGPoint(x: 512, y: 924))
    // Resplandor de color muy tenue tras el mapa (une los bloques con el fondo).
    radial(ctx, [(RGB(0x3A3A7A), 0.30, 0), (RGB(0x3A3A7A), 0, 1)], center: CGPoint(x: 512, y: 470), radius: 470)
    // Brillo especular arriba.
    radial(ctx, [(white, 0.16, 0), (white, 0.05, 0.55), (white, 0, 1)],
           center: CGPoint(x: 512, y: 70), radius: 520)

    // Sombra interior suave: un marco grande con el squircle como hueco, que proyecta sombra hacia dentro.
    ctx.saveGState()
    let frame = CGMutablePath()
    frame.addRect(squircleRect.insetBy(dx: -200, dy: -200))
    frame.addPath(squircle)
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * k), blur: 40 * k, color: black.cg(0.55))
    ctx.addPath(frame)
    ctx.setFillColor(black.cg())
    ctx.fillPath(using: .evenOdd)
    ctx.restoreGState()
    ctx.restoreGState()

    // 3. Treemap.
    let blocks = small ? smallLayout : fullLayout
    let panelInset: CGFloat = small ? 206 : 214
    let panel = CGRect(x: panelInset, y: panelInset - 6, width: 1024 - 2 * panelInset, height: 1024 - 2 * panelInset)
    // Separación: fina a 1024; a tamaños pequeños, exactamente 1 píxel (o más) para que no se fundan.
    let gap: CGFloat = small ? max(1.0 / k, 34) : 20
    let radius: CGFloat = small ? 40 : 30

    for b in blocks {
        var r = CGRect(x: panel.minX + b.x0 * panel.width, y: panel.minY + b.y0 * panel.height,
                       width: (b.x1 - b.x0) * panel.width, height: (b.y1 - b.y0) * panel.height)
        r = r.insetBy(dx: gap / 2, dy: gap / 2)
        if small {
            // Alinear a la rejilla de píxeles del tamaño final.
            let u = 1 / k
            r = CGRect(x: (r.minX / u).rounded() * u, y: (r.minY / u).rounded() * u,
                       width: (r.width / u).rounded() * u, height: (r.height / u).rounded() * u)
        }
        let path = continuousRect(r, radius: radius)

        // Halo del propio color (luz que el bloque derrama sobre el fondo) y sombra propia (profundidad).
        if !small {
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -14 * k), blur: 60 * k, color: b.color.cg(0.38))
            ctx.addPath(path)
            ctx.setFillColor(b.color.cg())
            ctx.fillPath()
            ctx.restoreGState()
        }
        ctx.saveGState()
        shadow(dy: small ? 4 : 10, blur: small ? 8 : 22, alpha: 0.5)
        ctx.addPath(path)
        ctx.setFillColor(b.color.cg())
        ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        // Degradado propio: más claro arriba, más saturado y algo oscuro abajo.
        linear(ctx, [(b.color.mixed(with: white, 0.28), 1, 0), (b.color, 1, 0.5),
                     (b.color.mixed(with: black, 0.22), 1, 1)],
               from: CGPoint(x: r.minX, y: r.minY), to: CGPoint(x: r.minX + r.width * 0.25, y: r.maxY))
        if !small {
            // Reflejo satinado en la mitad superior.
            linear(ctx, [(white, 0.22, 0), (white, 0.04, 0.5), (white, 0, 1)],
                   from: CGPoint(x: 0, y: r.minY), to: CGPoint(x: 0, y: r.minY + r.height * 0.55))
            // Sombra interior en el borde inferior y luz en el superior: relieve.
            ctx.saveGState()
            let rim = CGMutablePath()
            rim.addRect(r.insetBy(dx: -60, dy: -60))
            rim.addPath(path)
            ctx.setShadow(offset: CGSize(width: 0, height: 6 * k), blur: 14 * k, color: black.cg(0.35))
            ctx.addPath(rim)
            ctx.setFillColor(black.cg())
            ctx.fillPath(using: .evenOdd)
            ctx.restoreGState()
            ctx.addPath(path)
            ctx.setStrokeColor(white.cg(0.30))
            ctx.setLineWidth(3)
            ctx.replacePathWithStrokedPath()
            ctx.clip()
            linear(ctx, [(white, 0.55, 0), (white, 0, 0.35)],
                   from: CGPoint(x: 0, y: r.minY), to: CGPoint(x: 0, y: r.maxY))
        }
        ctx.restoreGState()
    }

    // 4. Filo de luz en el borde del squircle (como el cristal de los iconos de macOS).
    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()
    ctx.addPath(squircle)
    ctx.setLineWidth(small ? 1.0 / k * 0.8 : 4)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    // A 16/32 px un filo de 1 px se ve como un marco gris: allí apenas se insinúa.
    let rim: CGFloat = small ? 0.35 : 1
    linear(ctx, [(white, 0.28 * rim, 0), (white, 0.06 * rim, 0.5), (white, 0.10 * rim, 1)],
           from: CGPoint(x: 512, y: 100), to: CGPoint(x: 512, y: 924))
    ctx.restoreGState()

    return ctx.makeImage()!
}

func writePNG(_ img: CGImage, to url: URL) {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, img, [kCGImagePropertyDPIWidth: 72, kCGImagePropertyDPIHeight: 72] as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { fatalError("No se pudo escribir \(url.path)") }
}

@discardableResult
func run(_ tool: String, _ args: [String]) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: tool)
    p.arguments = args
    p.standardOutput = FileHandle.nullDevice
    do { try p.run() } catch { fatalError("No se pudo ejecutar \(tool): \(error)") }
    p.waitUntilExit()
    if p.terminationStatus != 0 { fatalError("\(tool) \(args.joined(separator: " ")) falló (\(p.terminationStatus))") }
    return p.terminationStatus
}

// MARK: Principal

let args = CommandLine.arguments.dropFirst()
let outDir = URL(fileURLWithPath: args.first ?? "Resources", isDirectory: true)
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let master = outDir.appendingPathComponent("Airy-1024.png")
writePNG(renderIcon(px: 1024, small: false), to: master)

let iconset = FileManager.default.temporaryDirectory
    .appendingPathComponent("Airy-\(ProcessInfo.processInfo.processIdentifier).iconset", isDirectory: true)
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

// (nombre en el iconset, píxeles)
let entries: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, px) in entries {
    let url = iconset.appendingPathComponent("\(name).png")
    if px <= 32 {
        writePNG(renderIcon(px: px, small: true), to: url)
    } else if px == 1024 {
        try FileManager.default.copyItem(at: master, to: url)
    } else {
        run("/usr/bin/sips", ["-z", "\(px)", "\(px)", master.path, "--out", url.path])
    }
}
// Vistas previas para revisar a mano los tamaños pequeños.
if ProcessInfo.processInfo.environment["AIRY_ICON_PREVIEW"] != nil {
    for px in [16, 32, 64] {
        try? FileManager.default.removeItem(at: outDir.appendingPathComponent("preview-\(px).png"))
        let src = entries.first { $0.1 == px }!.0
        try FileManager.default.copyItem(at: iconset.appendingPathComponent("\(src).png"),
                                         to: outDir.appendingPathComponent("preview-\(px).png"))
    }
}

let icns = outDir.appendingPathComponent("Airy.icns")
run("/usr/bin/iconutil", ["-c", "icns", iconset.path, "-o", icns.path])
try? FileManager.default.removeItem(at: iconset)
print("Icono generado: \(master.path) y \(icns.path)")
