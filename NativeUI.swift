// What the native windows share: the CSS values the HTML pages used, translated literally (px = pt, sRGB hex, weights, letter-spacing,
// line-height, cubic-bezier curves), the controls those pages drew, and the SVG icons, copied from the pages as path strings.
import AppKit
import SwiftUI

// MARK: - A surface the screenshot harness (tests/shoot_native.swift) can drive

protocol NativeSurface {
    var view: NSView { get }
    func receive(_ call: String, _ value: Any)
    func freeze(at ms: Double?)
}

func nativeSurface(_ name: String, frame: NSRect) -> NativeSurface {
    switch name {
    case "settings": return SettingsSurface(frame: frame)
    case "onboarding": return OnboardingSurface(frame: frame)
    case "box": return BoxSurface(frame: frame)
    default: fatalError("no native \(name) yet")
    }
}

// MARK: - CSS values

extension Color {
    init(hex: UInt32, _ alpha: Double = 1) {   // #rrggbb
        self.init(.sRGB, red: Double(hex >> 16 & 255) / 255, green: Double(hex >> 8 & 255) / 255, blue: Double(hex & 255) / 255, opacity: alpha)
    }
    static func rgba(_ r: Double, _ g: Double, _ b: Double, _ a: Double) -> Color { Color(.sRGB, red: r / 255, green: g / 255, blue: b / 255, opacity: a) }
    static func white(_ a: Double) -> Color { .rgba(255, 255, 255, a) }
    static func black(_ a: Double) -> Color { .rgba(0, 0, 0, a) }
}

// cubic-bezier(x1, y1, x2, y2) over a duration, as CSS transitions and animations ran.
func css(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double, _ seconds: Double, delay: Double = 0) -> Animation? {
    if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || UIClock.frozen != nil { return nil }
    return Animation.timingCurve(x1, y1, x2, y2, duration: seconds).delay(delay)
}
enum Ease {
    static func ease(_ s: Double, delay: Double = 0) -> Animation? { css(0.25, 0.1, 0.25, 1, s, delay: delay) }   // CSS `ease`
    static func linear(_ s: Double) -> Animation? { css(0, 0, 1, 1, s) }
}

// The system font as WebKit sets it: -apple-system at a pixel size, with a CSS weight.
func cssFont(_ size: CGFloat, _ weight: Int = 400) -> Font {
    .system(size: size, weight: weight >= 700 ? .bold : weight >= 600 ? .semibold : weight >= 500 ? .medium : .regular)
}
func naturalLineHeight(_ size: CGFloat) -> CGFloat {   // CSS line-height: normal, from the font's own ascent, descent and gap
    let f = NSFont.systemFont(ofSize: size)
    return f.ascender - f.descender + f.leading
}

extension View {
    // CSS `line-height` on text: each line box is size × mult tall, the glyphs centred in it (half-leading above and below).
    func lineHeight(_ size: CGFloat, _ mult: CGFloat?) -> some View {
        let gap = mult.map { size * $0 - naturalLineHeight(size) } ?? 0
        return self.lineSpacing(max(0, gap)).padding(.vertical, gap / 2)
    }
    // box-shadow: x y blur color. CSS blur is twice the Gaussian's deviation; SwiftUI's radius is the deviation.
    func cssShadow(_ color: Color, x: CGFloat = 0, y: CGFloat, blur: CGFloat) -> some View {
        self.shadow(color: color, radius: blur / 2, x: x, y: y)
    }
    // box-shadow: inset 0 0 0 w color — a hairline just inside the shape.
    func insetRing<S: InsettableShape>(_ shape: S, _ color: Color, _ width: CGFloat = 0.5) -> some View {
        self.overlay(shape.strokeBorder(color, lineWidth: width))
    }
    @ViewBuilder func hidden(_ hide: Bool) -> some View { if !hide { self } }
    // A drawn control VoiceOver finds as a button and presses like a click (the page had real <button>s).
    func pressable(_ label: String, selected: Bool = false, disabled: Bool = false, _ tap: @escaping () -> Void) -> some View {
        accessibilityElement(children: .ignore).accessibilityLabel(label).accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction(.default) { if !disabled { tap() } }
    }
}
func rr(_ r: CGFloat) -> RoundedRectangle { RoundedRectangle(cornerRadius: r, style: .circular) }   // CSS border-radius is a circular arc

// MARK: - SVG icons, drawn from the pages' own path data

struct SVGPath: Shape {
    let d: String
    let box: CGFloat   // the viewBox side: 16 or 24 in the pages
    func path(in rect: CGRect) -> Path {
        var p = svgPath(d)
        p = p.applying(CGAffineTransform(scaleX: rect.width / box, y: rect.height / box))
        return p.offsetBy(dx: rect.minX, dy: rect.minY)
    }
}

// The path mini-language: M L H V C S Q T A Z, absolute and relative.
func svgPath(_ d: String) -> Path {
    var p = Path()
    var nums: [CGFloat] = [], cmd: Character = "M"
    var cur = CGPoint.zero, start = CGPoint.zero, lastCtrl: CGPoint?, lastCmd: Character = " "
    var i = d.startIndex
    func number() -> CGFloat? {
        while i < d.endIndex, d[i] == " " || d[i] == "," || d[i] == "\n" { i = d.index(after: i) }
        guard i < d.endIndex else { return nil }
        var s = "", seenDot = false, seenE = false
        if d[i] == "-" || d[i] == "+" { s.append(d[i]); i = d.index(after: i) }
        while i < d.endIndex {
            let c = d[i]
            if c.isNumber { s.append(c) }
            else if c == "." && !seenDot && !seenE { seenDot = true; s.append(c) }
            else if (c == "e" || c == "E") && !seenE { seenE = true; s.append(c); let n = d.index(after: i); if n < d.endIndex, d[n] == "-" || d[n] == "+" { i = n; s.append(d[n]) } }
            else { break }
            i = d.index(after: i)
        }
        return Double(s).map { CGFloat($0) }
    }
    func flag() -> CGFloat? {   // arc flags may be written without separators: "0 01"
        while i < d.endIndex, d[i] == " " || d[i] == "," { i = d.index(after: i) }
        guard i < d.endIndex, d[i] == "0" || d[i] == "1" else { return number() }
        let v: CGFloat = d[i] == "1" ? 1 : 0; i = d.index(after: i); return v
    }
    while i < d.endIndex {
        let c = d[i]
        if c.isLetter && c != "e" && c != "E" { cmd = c; i = d.index(after: i) }
        else if c == " " || c == "," || c == "\n" { i = d.index(after: i); continue }
        let rel = cmd.isLowercase, up = Character(cmd.uppercased())
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { rel ? CGPoint(x: cur.x + x, y: cur.y + y) : CGPoint(x: x, y: y) }
        switch up {
        case "Z": p.closeSubpath(); cur = start; lastCtrl = nil; lastCmd = "Z"; continue
        case "M": guard let x = number(), let y = number() else { break }; cur = pt(x, y); start = cur; p.move(to: cur); cmd = rel ? "l" : "L"; lastCtrl = nil
        case "L": guard let x = number(), let y = number() else { break }; cur = pt(x, y); p.addLine(to: cur); lastCtrl = nil
        case "H": guard let x = number() else { break }; cur = CGPoint(x: rel ? cur.x + x : x, y: cur.y); p.addLine(to: cur); lastCtrl = nil
        case "V": guard let y = number() else { break }; cur = CGPoint(x: cur.x, y: rel ? cur.y + y : y); p.addLine(to: cur); lastCtrl = nil
        case "C":
            guard let x1 = number(), let y1 = number(), let x2 = number(), let y2 = number(), let x = number(), let y = number() else { break }
            let c1 = pt(x1, y1), c2 = pt(x2, y2), e = pt(x, y); p.addCurve(to: e, control1: c1, control2: c2); lastCtrl = c2; cur = e
        case "S":
            guard let x2 = number(), let y2 = number(), let x = number(), let y = number() else { break }
            let c1 = (lastCmd == "C" || lastCmd == "S") ? CGPoint(x: 2 * cur.x - (lastCtrl?.x ?? cur.x), y: 2 * cur.y - (lastCtrl?.y ?? cur.y)) : cur
            let c2 = pt(x2, y2), e = pt(x, y); p.addCurve(to: e, control1: c1, control2: c2); lastCtrl = c2; cur = e
        case "Q":
            guard let x1 = number(), let y1 = number(), let x = number(), let y = number() else { break }
            let c = pt(x1, y1), e = pt(x, y); p.addQuadCurve(to: e, control: c); lastCtrl = c; cur = e
        case "T":
            guard let x = number(), let y = number() else { break }
            let c = (lastCmd == "Q" || lastCmd == "T") ? CGPoint(x: 2 * cur.x - (lastCtrl?.x ?? cur.x), y: 2 * cur.y - (lastCtrl?.y ?? cur.y)) : cur
            let e = pt(x, y); p.addQuadCurve(to: e, control: c); lastCtrl = c; cur = e
        case "A":
            guard let rx = number(), let ry = number(), let rot = number(), let large = flag(), let sweep = flag(), let x = number(), let y = number() else { break }
            let e = pt(x, y); arc(&p, from: cur, to: e, rx: rx, ry: ry, rotation: rot, large: large != 0, sweep: sweep != 0); cur = e; lastCtrl = nil
        default: i = d.index(after: i)
        }
        lastCmd = up
        _ = nums
    }
    return p
}
// SVG's endpoint arc as center arcs (SVG 1.1 appendix F.6), in cubic pieces like every renderer.
private func arc(_ p: inout Path, from p0: CGPoint, to p1: CGPoint, rx: CGFloat, ry: CGFloat, rotation: CGFloat, large: Bool, sweep: Bool) {
    if p0 == p1 { return }
    var rx = abs(rx), ry = abs(ry)
    if rx == 0 || ry == 0 { p.addLine(to: p1); return }
    let phi = rotation * .pi / 180, cphi = cos(phi), sphi = sin(phi)
    let dx = (p0.x - p1.x) / 2, dy = (p0.y - p1.y) / 2
    let x1 = cphi * dx + sphi * dy, y1 = -sphi * dx + cphi * dy
    let lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
    if lambda > 1 { rx *= sqrt(lambda); ry *= sqrt(lambda) }
    let num = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1, den = rx * rx * y1 * y1 + ry * ry * x1 * x1
    var co = sqrt(max(0, num / den)); if large == sweep { co = -co }
    let cx1 = co * rx * y1 / ry, cy1 = -co * ry * x1 / rx
    let cx = cphi * cx1 - sphi * cy1 + (p0.x + p1.x) / 2, cy = sphi * cx1 + cphi * cy1 + (p0.y + p1.y) / 2
    func ang(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
        let a = atan2(ux * vy - uy * vx, ux * vx + uy * vy); return a
    }
    let t1 = ang(1, 0, (x1 - cx1) / rx, (y1 - cy1) / ry)
    var dt = ang((x1 - cx1) / rx, (y1 - cy1) / ry, (-x1 - cx1) / rx, (-y1 - cy1) / ry)
    if !sweep && dt > 0 { dt -= 2 * .pi } else if sweep && dt < 0 { dt += 2 * .pi }
    let n = Int(ceil(abs(dt) / (.pi / 2))), step = dt / CGFloat(n)
    let k = 4.0 / 3.0 * tan(step / 4)
    var t = t1
    for _ in 0..<n {
        let c1 = CGPoint(x: cos(t) - k * sin(t), y: sin(t) + k * cos(t)), e = CGPoint(x: cos(t + step), y: sin(t + step))
        let c2 = CGPoint(x: e.x + k * sin(t + step), y: e.y - k * cos(t + step))
        func map(_ q: CGPoint) -> CGPoint { CGPoint(x: cx + rx * q.x * cphi - ry * q.y * sphi, y: cy + rx * q.x * sphi + ry * q.y * cphi) }
        p.addCurve(to: map(e), control1: map(c1), control2: map(c2))
        t += step
    }
}

// An SVG <path>/<circle>/<rect> list as one stroked icon: stroke-width in viewBox units, round caps and joins (every icon in the pages).
struct Icon: View {
    let paths: [String]
    var box: CGFloat = 24, stroke: CGFloat, color: Color
    var body: some View {
        GeometryReader { g in
            let s = g.size.width / box
            ZStack { ForEach(paths.indices, id: \.self) { SVGPath(d: paths[$0], box: box).stroke(color, style: StrokeStyle(lineWidth: stroke * s, lineCap: .round, lineJoin: .round)) } }
        }
    }
}
// <circle cx cy r> and <rect x y width height rx> as path data, so they draw through the same parser.
func circle(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat) -> String { "M\(cx - r) \(cy)A\(r) \(r) 0 1 0 \(cx + r) \(cy)A\(r) \(r) 0 1 0 \(cx - r) \(cy)Z" }
func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> String {
    "M\(x + r) \(y)H\(x + w - r)A\(r) \(r) 0 0 1 \(x + w) \(y + r)V\(y + h - r)A\(r) \(r) 0 0 1 \(x + w - r) \(y + h)H\(x + r)A\(r) \(r) 0 0 1 \(x) \(y + h - r)V\(y + r)A\(r) \(r) 0 0 1 \(x + r) \(y)Z"
}

// MARK: - Images from data: URLs (the pages took the app icon and app icons that way)

func imageFromDataURL(_ s: String?) -> NSImage? {
    guard let s, let comma = s.firstIndex(of: ","), s.hasPrefix("data:") else { return nil }
    let head = s[..<comma], body = String(s[s.index(after: comma)...])
    if head.hasSuffix(";base64") { return Data(base64Encoded: body).flatMap(NSImage.init(data:)) }
    return (body.removingPercentEncoding?.data(using: .utf8)).flatMap(NSImage.init(data:))
}

// MARK: - Hover that works in any window state (WebKit's :hover did)

struct Hover: ViewModifier {
    @Binding var on: Bool
    func body(content: Content) -> some View { content.onHover { on = $0 } }
}
