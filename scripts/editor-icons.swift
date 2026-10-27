// Renders the editor's map icons from Lucide SVGs (lucide-static 0.460.0, ISC): turn
// handles (icon on a dark disc) and the facing arrowhead (filled, dark outline), 64×64
// PNG with alpha; the UI icons (`ui_*.png`, 48×48, white). macOS (AppKit draws the SVGs):
//   swift scripts/editor-icons.swift assets/icons/src assets/icons
import AppKit

let dir = CommandLine.arguments[1]
let out = CommandLine.arguments[2]
var size = 64

func svg(_ name: String, stroke: String, fill: String, width: String) -> NSImage {
    var s = try! String(contentsOfFile: "\(dir)/\(name).svg", encoding: .utf8)
    s = s.replacingOccurrences(of: "stroke=\"currentColor\"", with: "stroke=\"\(stroke)\"")
    s = s.replacingOccurrences(of: "fill=\"none\"", with: "fill=\"\(fill)\"")
    s = s.replacingOccurrences(of: "stroke-width=\"2\"", with: "stroke-width=\"\(width)\"")
    return NSImage(data: s.data(using: .utf8)!)!
}

func write(_ file: String, _ draw: () -> Void) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current!.imageInterpolation = .high
    draw()
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/\(file)"))
}

for (name, file) in [("rotate-ccw", "turn_ccw.png"), ("rotate-cw", "turn_cw.png")] {
    write(file) {
        let disc = NSBezierPath(ovalIn: NSRect(x: 3, y: 3, width: 58, height: 58))
        NSColor(red: 0.09, green: 0.10, blue: 0.13, alpha: 0.92).setFill()
        disc.fill()
        NSColor(white: 1, alpha: 0.35).setStroke()
        disc.lineWidth = 2
        disc.stroke()
        svg(name, stroke: "#ffffff", fill: "none", width: "2.4").draw(in: NSRect(x: 15, y: 15, width: 34, height: 34))
    }
}
write("facing.png") {
    svg("navigation-2", stroke: "#000000", fill: "#ffffff", width: "1.6").draw(in: NSRect(x: 4, y: 4, width: 56, height: 56))
}
// UI icons: white strokes on transparent, 48×48, tinted when drawn (clay image colour).
size = 48
let ui = ["save", "check", "play", "settings", "history", "search", "folder", "chevron-right", "chevron-down",
          "map-pin", "swords", "user", "package", "clapperboard", "volume-2", "plus", "file-text",
          "mouse-pointer-2", "hand", "paintbrush", "pipette", "lightbulb", "square-dashed", "log-out", "crosshair", "camera", "pencil", "code", "message-square", "maximize", "x", "undo-2", "redo-2", "eye", "eye-off", "lock", "lock-open", "layers", "trash-2", "copy", "image", "grid-3x3", "box", "pause", "skip-back", "skip-forward"]
for name in ui {
    write("ui_\(name.replacingOccurrences(of: "-", with: "_")).png") {
        svg(name, stroke: "#ffffff", fill: "none", width: "2").draw(in: NSRect(x: 0, y: 0, width: size, height: size))
    }
}
