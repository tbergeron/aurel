// Compares each PNG in <html dir> with the same name in <native dir>: pass when ≥99.5% of pixels are within 3/255 on every channel
// and no 4×4 block is entirely off (a moved icon or a different glyph fails even when the percentage passes).
// Writes <out>/<name>.png: HTML | native | heat map. Exit 1 when any scene fails.
// usage: imgdiff <html dir> <native dir> <out dir>
import AppKit

let a = CommandLine.arguments
let htmlDir = URL(fileURLWithPath: a[1]), nativeDir = URL(fileURLWithPath: a[2]), outDir = URL(fileURLWithPath: a[3])
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

func pixels(_ url: URL) -> (w: Int, h: Int, px: [UInt8])? {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
    let w = img.width, h = img.height
    var px = [UInt8](repeating: 0, count: w * h * 4)
    let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    return (w, h, px)
}
func image(_ w: Int, _ h: Int, _ px: [UInt8]) -> CGImage {
    var px = px
    let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    return ctx.makeImage()!
}

var failed = 0
let names = ((try? FileManager.default.contentsOfDirectory(atPath: htmlDir.path)) ?? []).filter { $0.hasSuffix(".png") }.sorted()
print(String(format: "%-36@ %8@ %6@ %@", "scene" as NSString, "match" as NSString, "block" as NSString, "result" as NSString))
for name in names {
    guard let h = pixels(htmlDir.appendingPathComponent(name)) else { continue }
    guard let n = pixels(nativeDir.appendingPathComponent(name)) else { print("\(name): no native shot"); failed += 1; continue }
    let w = max(h.w, n.w), hh = max(h.h, n.h)
    var heat = [UInt8](repeating: 0, count: w * hh * 4), off = [Bool](repeating: true, count: w * hh)
    var bad = 0
    for y in 0..<hh { for x in 0..<w {
        let i = (y * w + x) * 4
        var d = 255
        if x < h.w, y < h.h, x < n.w, y < n.h {
            let ih = (y * h.w + x) * 4, inn = (y * n.w + x) * 4
            d = (0..<4).map { abs(Int(h.px[ih + $0]) - Int(n.px[inn + $0])) }.max()!
        }
        let isOff = d > 3
        off[y * w + x] = isOff
        if isOff { bad += 1 }
        let v = UInt8(min(255, d * 4))
        heat[i] = isOff ? 255 : v / 3; heat[i + 1] = isOff ? 0 : v / 3; heat[i + 2] = isOff ? 0 : v / 3; heat[i + 3] = 255
    } }
    var block = false
    outer: for y in 0..<max(0, hh - 3) { for x in 0..<max(0, w - 3) {
        if off[y * w + x] && off[y * w + x + 3] && off[(y + 3) * w + x] && off[(y + 3) * w + x + 3] {
            var all = true
            for dy in 0..<4 { for dx in 0..<4 where !off[(y + dy) * w + x + dx] { all = false } }
            if all { block = true; break outer }
        }
    } }
    let match = 1 - Double(bad) / Double(w * hh)
    let pass = match >= 0.995 && !block && h.w == n.w && h.h == n.h
    if !pass { failed += 1 }
    print(String(format: "%-36@ %7.3f%% %6@ %@", name as NSString, match * 100, (block ? "yes" : "no") as NSString, (pass ? "pass" : "FAIL") as NSString))
    // Triptych: HTML | native | heat map, side by side.
    let ctx = CGContext(data: nil, width: w * 3, height: hh, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(image(h.w, h.h, h.px), in: CGRect(x: 0, y: hh - h.h, width: h.w, height: h.h))
    ctx.draw(image(n.w, n.h, n.px), in: CGRect(x: w, y: hh - n.h, width: n.w, height: n.h))
    ctx.draw(image(w, hh, heat), in: CGRect(x: w * 2, y: 0, width: w, height: hh))
    if let dest = CGImageDestinationCreateWithURL(outDir.appendingPathComponent(name) as CFURL, "public.png" as CFString, 1, nil) {
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil); CGImageDestinationFinalize(dest)
    }
}
print(failed == 0 ? "all \(names.count) scenes pass" : "\(failed) of \(names.count) scenes fail")
exit(failed == 0 ? 0 : 1)
