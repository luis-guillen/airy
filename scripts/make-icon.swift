#!/usr/bin/env swift
// Genera el icono de Airy con CoreGraphics.
//
//   swift scripts/make-icon.swift Resources/
//
// Escribe en la carpeta indicada:
//   Airy-1024.png   maestro de 1024×1024
//   Airy.icns       todos los tamaños (16…1024, @1x/@2x)
//
// Logo: remolino de viento (arcos concéntricos blancos translúcidos) con hojas sobre un squircle
// turquesa → índigo. Los tamaños de hasta 64 px (16, 16@2x, 32, 32@2x) se dibujan directamente a
// su tamaño con una variante simplificada (un arco grueso y una hoja, alineados a píxel); de 128 px
// en adelante salen del maestro de 1024 con `sips`.

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

// Paleta Airy (AiryPalette.logoTop / logoBottom).
let logoTop = RGB(0x2fd0ff)
let logoBottom = RGB(0x2a3bd9)

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

// logo-geometry: airy-logo-v1|full-arc:300,34,-20,250,0.9|full-arc:220,30,70,250,0.7|full-arc:140,26,160,250,0.5|full-leaf:300,230,132,62,ffffff|full-leaf:220,320,112,52,bfe9ff|full-leaf:140,50,92,44,ffffff|small-arc:230,86,-30,270,0.95|small-leaf:230,240,230,110,ffffff
struct ArcSpec { var radius, lineWidth, start, sweep, opacity: CGFloat }
struct LeafSpec { var radius, angle, length, width: CGFloat; var tint: UInt32 }

let fullArcs = [ArcSpec(radius: 300, lineWidth: 34, start: -20, sweep: 250, opacity: 0.90),
                ArcSpec(radius: 220, lineWidth: 30, start: 70, sweep: 250, opacity: 0.70),
                ArcSpec(radius: 140, lineWidth: 26, start: 160, sweep: 250, opacity: 0.50)]
let fullLeaves = [LeafSpec(radius: 300, angle: 230, length: 132, width: 62, tint: 0xFFFFFF),
                  LeafSpec(radius: 220, angle: 320, length: 112, width: 52, tint: 0xBFE9FF),
                  LeafSpec(radius: 140, angle: 50, length: 92, width: 44, tint: 0xFFFFFF)]
let smallArcs = [ArcSpec(radius: 230, lineWidth: 86, start: -30, sweep: 270, opacity: 0.95)]
let smallLeaves = [LeafSpec(radius: 230, angle: 240, length: 230, width: 110, tint: 0xFFFFFF)]

/// Hoja centrada en el origen a lo largo de +x (misma curva que AiryLogoGeometry.leafPath).
func leafPath(length l: CGFloat, width w: CGFloat) -> CGPath {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: -l / 2, y: 0))
    p.addQuadCurve(to: CGPoint(x: l / 2, y: 0), control: CGPoint(x: 0, y: -w))
    p.addQuadCurve(to: CGPoint(x: -l / 2, y: 0), control: CGPoint(x: 0, y: 0.6 * w))
    p.closeSubpath()
    return p
}

/// Dibuja el icono en un lienzo de `px`×`px` píxeles. Todo se expresa en la rejilla de 1024
/// de Apple y se escala; `small` activa la variante simplificada alineada a píxel.
func renderIcon(px: Int, small: Bool) -> CGImage {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let k = CGFloat(px) / 1024  // píxeles por unidad de la rejilla
    let u = 1 / k               // unidades de la rejilla por píxel
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
    ctx.setFillColor(logoBottom.mixed(with: black, 0.5).cg())
    ctx.fillPath()
    ctx.restoreGState()

    // 2. Fondo: degradado turquesa (arriba-izquierda) → índigo (abajo-derecha).
    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()
    linear(ctx, [(logoTop, 1, 0), (logoBottom, 1, 1)],
           from: CGPoint(x: 100, y: 100), to: CGPoint(x: 924, y: 924))
    // Brillo especular arriba.
    radial(ctx, [(white, 0.16, 0), (white, 0.05, 0.55), (white, 0, 1)],
           center: CGPoint(x: 512, y: 70), radius: 520)

    // Sombra interior suave: un marco grande con el squircle como hueco, que proyecta sombra hacia dentro.
    ctx.saveGState()
    let frame = CGMutablePath()
    frame.addRect(squircleRect.insetBy(dx: -200, dy: -200))
    frame.addPath(squircle)
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * k), blur: 40 * k, color: black.cg(0.40))
    ctx.addPath(frame)
    ctx.setFillColor(black.cg())
    ctx.fillPath(using: .evenOdd)
    ctx.restoreGState()
    ctx.restoreGState()

    // 3. Remolino: arcos blancos translúcidos con extremos redondeados.
    func snap(_ v: CGFloat) -> CGFloat { small ? max(1, (v / u).rounded()) * u : v }
    func polar(_ radius: CGFloat, _ degrees: CGFloat) -> CGPoint {
        let a = degrees * .pi / 180
        return CGPoint(x: 512 + radius * cos(a), y: 512 + radius * sin(a))
    }
    for arc in small ? smallArcs : fullArcs {
        let r = snap(arc.radius)
        let path = CGMutablePath()
        let steps = 180
        for i in 0...steps {
            let p = polar(r, arc.start + arc.sweep * CGFloat(i) / CGFloat(steps))
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        ctx.saveGState()
        ctx.addPath(path)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setLineWidth(snap(arc.lineWidth))
        ctx.setStrokeColor(white.cg(arc.opacity))
        ctx.strokePath()
        ctx.restoreGState()
    }

    // 4. Hojas en el extremo de cada arco, con sombra suave.
    for leaf in small ? smallLeaves : fullLeaves {
        ctx.saveGState()
        shadow(dy: small ? 3 : 8, blur: small ? 6 : 18, alpha: 0.25)
        let c = polar(snap(leaf.radius), leaf.angle)
        ctx.translateBy(x: c.x, y: c.y)
        ctx.rotate(by: (leaf.angle + 90) * .pi / 180)
        ctx.addPath(leafPath(length: leaf.length, width: leaf.width))
        ctx.setFillColor(RGB(leaf.tint).cg())
        ctx.fillPath()
        ctx.restoreGState()
    }

    // 5. Filo de luz en el borde del squircle (como el cristal de los iconos de macOS).
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
    if px <= 64 {
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
