// Draws "Stay Awake"'s app icon FROM CODE, at build time: no binary asset in
// the repo, because a .png is a blob nobody can diff and nothing regenerates,
// while a hundred lines of CoreGraphics edits like source.
//
// Usage: icon <output-dir>
// Writes, into <output-dir>:
//   AppIcon.icon/            an Icon Composer package (icon.json + Assets/) —
//                            the ONLY format that carries light/dark appearance
//                            variants, compiled to Assets.car by actool
//   AppIcon.iconset/         the ten legacy tiles, for `iconutil -c icns` when
//                            actool is absent (it ships with Xcode, not with
//                            the Command Line Tools, which is all a fresh Mac
//                            has during bootstrap)
//
// The glyph is a cup and saucer with steam, because that is already the app's
// own vocabulary: main.swift draws `cup.and.heat.waves.fill` (a steaming cup)
// in the menu bar when the toggle is on, and the mechanism underneath is
// literally `caffeinate`.

import AppKit

struct Appearance {
    let name: String
    let tileTop: NSColor
    let tileBottom: NSColor
    let glyph: NSColor
}

// Amber cup in light; espresso with a cream cup in dark. The glyph inverts
// rather than merely shifting, which is what the appearance variant is FOR: the
// same drawing at the same contrast against two different desktops.
let light = Appearance(
    name: "light",
    tileTop: NSColor(srgbRed: 0.98, green: 0.74, blue: 0.34, alpha: 1),
    tileBottom: NSColor(srgbRed: 0.87, green: 0.44, blue: 0.15, alpha: 1),
    glyph: NSColor(srgbRed: 0.26, green: 0.13, blue: 0.06, alpha: 1))
let dark = Appearance(
    name: "dark",
    tileTop: NSColor(srgbRed: 0.25, green: 0.16, blue: 0.10, alpha: 1),
    tileBottom: NSColor(srgbRed: 0.10, green: 0.07, blue: 0.05, alpha: 1),
    glyph: NSColor(srgbRed: 0.98, green: 0.90, blue: 0.78, alpha: 1))

// MARK: - Drawing primitives

// Apple's icon corner is a continuous curve, not a circular arc, and AppKit has
// no public API for one. A superellipse |x|^n + |y|^n = 1 at n = 5 tracks it
// closely enough that the difference is invisible below 512 pt, and it costs a
// loop instead of a dependency.
func squircle(in r: NSRect, n: CGFloat = 5) -> NSBezierPath {
    let p = NSBezierPath()
    let a = r.width / 2, b = r.height / 2
    let cx = r.midX, cy = r.midY
    let steps = 720
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let ct = cos(t), st = sin(t)
        let x = cx + a * copysign(pow(abs(ct), 2 / n), ct)
        let y = cy + b * copysign(pow(abs(st), 2 / n), st)
        if i == 0 { p.move(to: NSPoint(x: x, y: y)) } else { p.line(to: NSPoint(x: x, y: y)) }
    }
    p.close()
    return p
}

func render(_ px: Int, _ body: (CGFloat) -> Void) -> Data {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)
    else { fatalError("cannot allocate a \(px)x\(px) bitmap") }
    rep.size = NSSize(width: px, height: px)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.shouldAntialias = true
    body(CGFloat(px))
    NSGraphicsContext.restoreGraphicsState()
    guard let png = rep.representation(using: .png, properties: [:]) else {
        fatalError("cannot encode a \(px)x\(px) PNG")
    }
    return png
}

// MARK: - The glyph

// Cup, saucer and steam in a `s` x `s` canvas. Every measurement is a fraction
// of the canvas, so the same code renders the 1024 pt layer and a 16 pt tile;
// the shapes are solid masses rather than thin outlines for the same reason —
// a 1 px outline at 16 pt is a smudge.
func drawGlyph(_ s: CGFloat, _ ap: Appearance) {
    ap.glyph.setFill()
    ap.glyph.setStroke()

    // Handle first, so the cup body paints over the joint and the two read as
    // one shape rather than a ring stuck to a box.
    let handle = NSBezierPath()
    handle.appendArc(withCenter: NSPoint(x: s * 0.655, y: s * 0.505),
                     radius: s * 0.093, startAngle: 84, endAngle: -84, clockwise: true)
    handle.lineWidth = s * 0.052
    handle.lineCapStyle = .round
    handle.stroke()

    // Body: a rim-width mouth tapering to a narrower, rounded base.
    let top = s * 0.615, bot = s * 0.335
    let halfTop = s * 0.185, halfBot = s * 0.135
    let cx = s * 0.475
    let body = NSBezierPath()
    body.move(to: NSPoint(x: cx - halfTop, y: top))
    body.line(to: NSPoint(x: cx + halfTop, y: top))
    body.line(to: NSPoint(x: cx + halfBot + s * 0.012, y: bot + s * 0.055))
    body.curve(to: NSPoint(x: cx + halfBot - s * 0.030, y: bot),
               controlPoint1: NSPoint(x: cx + halfBot + s * 0.006, y: bot + s * 0.012),
               controlPoint2: NSPoint(x: cx + halfBot - s * 0.006, y: bot))
    body.line(to: NSPoint(x: cx - halfBot + s * 0.030, y: bot))
    body.curve(to: NSPoint(x: cx - halfBot - s * 0.012, y: bot + s * 0.055),
               controlPoint1: NSPoint(x: cx - halfBot + s * 0.006, y: bot),
               controlPoint2: NSPoint(x: cx - halfBot - s * 0.006, y: bot + s * 0.012))
    body.close()
    body.fill()

    // Saucer: a flat lozenge wider than the cup, which is what separates a cup
    // from a bucket at small sizes.
    let saucer = NSRect(x: s * 0.220, y: s * 0.252, width: s * 0.510, height: s * 0.056)
    NSBezierPath(roundedRect: saucer, xRadius: saucer.height / 2, yRadius: saucer.height / 2).fill()

    // Two steam curls. Offset from each other in both x and phase so they read
    // as rising vapour and not as a pair of quote marks.
    for (dx, h) in [(-s * 0.072, s * 0.150), (s * 0.058, s * 0.185)] {
        let x = cx + dx
        let y0 = s * 0.680
        let curl = NSBezierPath()
        curl.move(to: NSPoint(x: x, y: y0))
        curl.curve(to: NSPoint(x: x, y: y0 + h),
                   controlPoint1: NSPoint(x: x - s * 0.075, y: y0 + h * 0.34),
                   controlPoint2: NSPoint(x: x + s * 0.075, y: y0 + h * 0.66))
        curl.lineWidth = s * 0.040
        curl.lineCapStyle = .round
        curl.stroke()
    }
}

func drawTile(_ s: CGFloat, _ ap: Appearance) {
    let inset = s * 0.008
    let path = squircle(in: NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset))
    let g = NSGradient(starting: ap.tileTop, ending: ap.tileBottom)
    g?.draw(in: path, angle: -90)
    drawGlyph(s, ap)
}

// MARK: - Output

let out = CommandLine.arguments.count > 1
    ? URL(fileURLWithPath: CommandLine.arguments[1])
    : { FileHandle.standardError.write(Data("usage: icon <output-dir>\n".utf8)); exit(2) }()

let fm = FileManager.default
let iconPkg = out.appendingPathComponent("AppIcon.icon")
let assets = iconPkg.appendingPathComponent("Assets")
let iconset = out.appendingPathComponent("AppIcon.iconset")
for d in [assets, iconset] {
    try? fm.removeItem(at: d)
    try! fm.createDirectory(at: d, withIntermediateDirectories: true)
}

// The Icon Composer layers: the tile is the package's `fill`, so the layer PNG
// carries only the glyph on transparency and the system masks, shadows and
// glazes it. One PNG per appearance, swapped by `image-name-specializations`.
for ap in [light, dark] {
    let png = render(1024) { s in drawGlyph(s, ap) }
    try! png.write(to: assets.appendingPathComponent("glyph-\(ap.name).png"))
}

func fill(_ ap: Appearance) -> String {
    func c(_ x: NSColor) -> String {
        let s = x.usingColorSpace(.sRGB)!
        return String(format: "srgb:%.5f,%.5f,%.5f,%.5f",
                      s.redComponent, s.greenComponent, s.blueComponent, s.alphaComponent)
    }
    return "{ \"linear-gradient\" : [ \"\(c(ap.tileTop))\", \"\(c(ap.tileBottom))\" ] }"
}

// Hand-written rather than JSONSerialization so the file reads like the ones
// Icon Composer saves. Schema notes, both learned by compiling and reading the
// result back with assetutil (2026-09-07):
//   - a `*-specializations` array must carry the BASE value as an entry with no
//     `appearance` key. A top-level `fill` plus a dark-only specialization
//     compiles without a word of complaint and silently drops the dark colour.
//   - `shadow`/`translucency` are pinned here rather than left to actool's
//     defaults, so the look cannot drift with the toolchain.
let json = """
{
  "fill-specializations" : [
    { "value" : \(fill(light)) },
    { "appearance" : "dark", "value" : \(fill(dark)) }
  ],
  "groups" : [
    {
      "layers" : [
        {
          "name" : "Cup",
          "image-name-specializations" : [
            { "value" : "glyph-light.png" },
            { "appearance" : "dark", "value" : "glyph-dark.png" }
          ]
        }
      ],
      "shadow" : { "kind" : "neutral", "opacity" : 0.5 },
      "translucency" : { "enabled" : false, "value" : 0.5 }
    }
  ],
  "supported-platforms" : { "squares" : "shared" }
}

"""
try! Data(json.utf8).write(to: iconPkg.appendingPathComponent("icon.json"))

// The legacy set. Each tile is drawn at its own pixel size rather than
// downsampled from 1024, so the 16 pt one keeps its stroke instead of blurring.
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = base * scale
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        let png = render(px) { s in drawTile(s, light) }
        try! png.write(to: iconset.appendingPathComponent(name))
    }
}
