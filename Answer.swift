// Answers in the box: Markdown and TeX, parsed here and drawn natively, each word fading in (opacity, a 5 pt blur, 3 pt up, .5 s)
// in reading order.
import AppKit
import SwiftUI
#if canImport(SwiftUIMath)
@_spi(Textual) import SwiftUIMath
#endif

// MARK: - Parse

indirect enum Inline {
    case text(String), strong([Inline]), em([Inline]), code(String), link(String, String), math(String), br
}
enum MDBlock {
    case para([Inline]), heading([Inline]), list(ordered: Bool, start: Int, items: [[Inline]]), pre(String)
    case table(head: [[Inline]], rows: [[[Inline]]]), hr, math(String)
}

private let inlineRE = try! NSRegularExpression(pattern: #"((?<!\\)\$\$[\s\S]+?\$\$|\\\[[\s\S]+?\\\]|\\\([\s\S]+?\\\)|(?<!\\)\$(?=\S)(?:\\.|[^$\\\n])+?(?<=\S)\$(?!\d)|\*\*[^*]+\*\*|`[^`]+`|\[[^\]]+\]\((?:https?:|mailto:)[^\s)]+\)|https?://[^\s<>()]+[^\s<>().,;:!?'"]|\*[^*\s][^*]*\*|(?<![\w\\])_[^_\s][^_]*_(?!\w))"#)

func parseInline(_ text: String) -> [Inline] {
    var out: [Inline] = []
    let ns = text as NSString
    func plain(_ s: String) {
        let lines = s.replacingOccurrences(of: "\\$", with: "$").components(separatedBy: "\n")
        for (k, l) in lines.enumerated() { if k > 0 { out.append(.br) }; if !l.isEmpty { out.append(.text(l)) } }
    }
    var at = 0
    for m in inlineRE.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
        plain(ns.substring(with: NSRange(location: at, length: m.range.location - at)))
        let s = ns.substring(with: m.range); at = m.range.location + m.range.length
        if s.hasPrefix("$$") || s.hasPrefix("\\[") { out.append(.math("\u{1}" + String(s.dropFirst(2).dropLast(2)))) }   // \u{1}: display math
        else if s.hasPrefix("$") { out.append(.math(String(s.dropFirst().dropLast()))) }
        else if s.hasPrefix("\\(") { out.append(.math(String(s.dropFirst(2).dropLast(2)))) }
        else if s.hasPrefix("**") { out.append(.strong(parseInline(String(s.dropFirst(2).dropLast(2))))) }
        else if s.hasPrefix("`") { out.append(.code(String(s.dropFirst().dropLast()))) }
        else if s.hasPrefix("["), let k = s.range(of: "](") { out.append(.link(String(s[s.index(after: s.startIndex)..<k.lowerBound]), String(s[k.upperBound...].dropLast()))) }
        else if s.hasPrefix("http") { out.append(.link(s, s)) }
        else { out.append(.em(parseInline(String(s.dropFirst().dropLast())))) }
    }
    plain(ns.substring(from: at))
    return out
}

func parseMarkdown(_ text: String) -> [MDBlock] {
    var out: [MDBlock] = []
    let lines = text.replacingOccurrences(of: "\r", with: "").components(separatedBy: "\n")
    func match(_ re: String, _ s: String) -> [String]? {
        guard let r = try? NSRegularExpression(pattern: re), let m = r.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        return (0..<m.numberOfRanges).map { m.range(at: $0).location == NSNotFound ? "" : (s as NSString).substring(with: m.range(at: $0)) }
    }
    let item = #"^\s*([-*•]|\d+[.)])\s+(.*)"#, row = #"^\s*\|.*\|\s*$"#
    func cells(_ l: String) -> [String] {
        var t = l.trimmingCharacters(in: .whitespaces); if t.hasPrefix("|") { t.removeFirst() }; if t.hasSuffix("|") { t.removeLast() }
        return t.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }
    func isTable(_ i: Int) -> Bool { match(row, lines[i]) != nil && i + 1 < lines.count && match(#"^\s*\|?\s*:?-{2,}"#, lines[i + 1]) != nil }
    var i = 0
    while i < lines.count {
        if lines[i].trimmingCharacters(in: .whitespaces).isEmpty { i += 1; continue }
        if match(#"^\s*```"#, lines[i]) != nil {   // a fenced block keeps its lines
            var code: [String] = []; i += 1
            while i < lines.count && match(#"^\s*```"#, lines[i]) == nil { code.append(lines[i]); i += 1 }
            i += 1; out.append(.pre(code.joined(separator: "\n"))); continue
        }
        if isTable(i) {
            let head = cells(lines[i]).map(parseInline); i += 2
            var rows: [[[Inline]]] = []
            while i < lines.count && match(row, lines[i]) != nil { rows.append(cells(lines[i]).map(parseInline)); i += 1 }
            out.append(.table(head: head, rows: rows)); continue
        }
        if let m = match(#"^\s*#{1,4}\s+(.*)"#, lines[i]) { out.append(.heading(parseInline(m[1]))); i += 1; continue }
        if match(#"^\s*-{3,}\s*$"#, lines[i]) != nil { out.append(.hr); i += 1; continue }
        if let m = match(item, lines[i]) {
            let ordered = m[1].first?.isNumber ?? false, start = Int(m[1].filter(\.isNumber)) ?? 1
            var items: [[Inline]] = []
            while i < lines.count, let m = match(item, lines[i]) { items.append(parseInline(m[2])); i += 1 }
            out.append(.list(ordered: ordered, start: start, items: items)); continue
        }
        var para: [String] = []
        while i < lines.count && !lines[i].trimmingCharacters(in: .whitespaces).isEmpty
                && !(para.count > 0 && (match(item, lines[i]) != nil || match(#"^\s*(#{1,4}\s|```|-{3,}\s*$)"#, lines[i]) != nil || isTable(i))) {
            para.append(lines[i].trimmingCharacters(in: .whitespaces)); i += 1
        }
        // display math in a paragraph stands on its own line, between the text around it
        var run: [Inline] = []
        for x in parseInline(para.joined(separator: "\n")) {
            if case .math(let s) = x, s.hasPrefix("\u{1}") { if !run.isEmpty { out.append(.para(run)); run = [] }; out.append(.math(String(s.dropFirst()))) } else { run.append(x) }
        }
        if !run.isEmpty { out.append(.para(run)) }
    }
    return out
}

// shut(): a streamed line waits at a **bold, `code, [link or $math that has not closed yet, so its marks never flash as symbols.
func shutAnswer(_ s: String) -> String {
    let ns = s as NSString
    let k = ns.range(of: "\n", options: .backwards).location == NSNotFound ? 0 : ns.range(of: "\n", options: .backwards).location + 1
    let l = ns.substring(from: k)
    var b = s
    for m in inlineRE.matches(in: s, range: NSRange(location: 0, length: ns.length)).reversed() {
        b = (b as NSString).replacingCharacters(in: m.range, with: String(repeating: " ", count: m.range.length))
    }
    var open: [Int] = []
    if l.components(separatedBy: "**").count % 2 == 0, let r = l.range(of: "**", options: .backwards) { open.append(l.distance(from: l.startIndex, to: r.lowerBound)) }
    if l.components(separatedBy: "`").count % 2 == 0, let r = l.range(of: "`", options: .backwards) { open.append(l.distance(from: l.startIndex, to: r.lowerBound)) }
    if let r = l.range(of: #"\[[^\]]*$"#, options: .regularExpression) { open.append(l.distance(from: l.startIndex, to: r.lowerBound)) }
    let bl = (b as NSString).substring(from: k)
    if let r = try? NSRegularExpression(pattern: #"(?<!\\)\$(?![\d\s])"#), let m = r.firstMatch(in: bl, range: NSRange(location: 0, length: (bl as NSString).length)) { open.append(m.range.location) }
    var abs = open.map { $0 + k }
    if let r = try? NSRegularExpression(pattern: #"(?<!\\)\$\$|\\[\[(]"#), let m = r.firstMatch(in: b, range: NSRange(location: 0, length: (b as NSString).length)) { abs.append(m.range.location) }
    let fences = (try? NSRegularExpression(pattern: #"^\s*```"#, options: .anchorsMatchLines).numberOfMatches(in: s, range: NSRange(location: 0, length: ns.length))) ?? 0
    guard let cut = abs.min(), fences % 2 == 0 else { return s }
    return ns.substring(to: cut)
}

// MARK: - Math, as an image that sits in a line of text

final class MathCache {
    static let shared = MathCache()
    final class Entry { let value: (NSImage, CGFloat)?; init(_ v: (NSImage, CGFloat)?) { value = v } }
    // Costed in pixel bytes and evicted under memory pressure; answers on screen hold their own images, so only old, unseen formulas go.
    // ponytail: 64 MB is a guess (thousands of formulas); measure a math-heavy session before tightening it.
    let images: NSCache<NSString, Entry> = { let c = NSCache<NSString, Entry>(); c.totalCostLimit = 64 << 20; return c }()
    // TeX in STIX's own family (XITS), 1.12 × the text size, display style even inline, as the page set it. nil: it could not be read (shown as its source).
    @MainActor func image(_ tex: String, size: CGFloat, color: NSColor) -> (NSImage, CGFloat)? {
        let key = "\(tex)|\(size)|\(color.description)"
        if let hit = images.object(forKey: key as NSString) { return hit.value }
        var result: (NSImage, CGFloat)? = nil
        #if canImport(SwiftUIMath)
        let font = Math.Font(name: .xits, size: size * 1.12)
        let b = Math.typographicBounds(for: tex, fitting: .unspecified, font: font, style: .display)
        if b.width > 0 {
            let r = ImageRenderer(content: Math(tex).mathFont(font).mathTypesettingStyle(.display).foregroundStyle(Color(nsColor: color)).frame(width: b.width, height: b.size.height))
            r.scale = 2
            if let cg = r.cgImage { result = (NSImage(cgImage: cg, size: NSSize(width: b.width, height: b.size.height)), b.descent) }
        }
        #endif
        images.setObject(Entry(result), forKey: key as NSString, cost: result.map { Int($0.0.size.width * $0.0.size.height) * 16 } ?? 1)   // 2× scale, 4 bytes a pixel
        return result
    }
}

// MARK: - Words in reading order, each with the moment it starts to fade in

struct WordKey: TextAttribute { let index: Int }
struct LinkKey: TextAttribute { let url: String }

// One answer's fade queue (the page's a.next and each word's u.at).
final class Reveal {
    var words: [String] = []
    var at: [Double] = []
    var next = 0.0
    // New text: words that read the same as before keep their time; the rest queue up, never more than 0.9 s behind.
    func update(_ newWords: [String], keep: Bool) {
        let now = CACurrentMediaTime()
        if !keep { words = []; at = []; next = now }
        var k = 0
        while k < words.count && k < newWords.count && bare(words[k]) == bare(newWords[k]) { k += 1 }
        let queued = newWords.count - k
        let gap = min(0.032, max(0, 0.9 - (next - now)) / Double(max(1, queued)))
        var times = Array(at.prefix(k))
        for _ in 0..<queued { let t = max(now, next); times.append(t); next = t + gap }
        words = newWords; at = times
    }
    func bare(_ s: String) -> String { s.replacingOccurrences(of: #"[*_`]"#, with: "", options: .regularExpression) }
    var done: Bool { (at.last ?? 0) + 0.5 < CACurrentMediaTime() }
}

// Draws each word at its point in the fade: opacity, blur 5 → 0, 3 pt up, over .5 s on the page's ease (.2,.8,.2,1).
struct WordFade: TextRenderer {
    let at: [Double]; let now: Double; let still: Bool
    var links: LinkRects? = nil
    func draw(layout: Text.Layout, in ctx: inout GraphicsContext) {
        links?.rects = []
        for line in layout {
            for run in line {
                if let l = run[LinkKey.self] { links?.rects.append((run.typographicBounds.rect, l.url)) }
                guard !still, let w = run[WordKey.self], w.index < at.count else { ctx.draw(run); continue }
                let p = ease(min(1, max(0, (now - at[w.index]) / 0.5)))
                if p >= 1 { ctx.draw(run); continue }
                var c = ctx
                c.opacity = p
                if p < 1 { c.addFilter(.blur(radius: 5 * (1 - p) / 2)) }
                c.translateBy(x: 0, y: 3 * (1 - p))
                c.draw(run)
            }
        }
    }
    func ease(_ x: Double) -> Double {   // cubic-bezier(.2,.8,.2,1), solved for y at x
        var t = x
        for _ in 0..<8 { let xt = 3 * (1 - t) * (1 - t) * t * 0.2 + 3 * (1 - t) * t * t * 0.2 + t * t * t; let d = 3 * (1 - t) * (1 - t) * 0.2 + 6 * (1 - t) * t * (0.2 - 0.2) + 3 * t * t * (1 - 0.2); if d == 0 { break }; t -= (xt - x) / d; t = min(1, max(0, t)) }
        return 3 * (1 - t) * (1 - t) * t * 0.8 + 3 * (1 - t) * t * t * 1 + t * t * t
    }
}
final class LinkRects { var rects: [(CGRect, String)] = [] }

// MARK: - Views

struct AnswerStyle {
    var size: CGFloat = 15, lh: CGFloat = 1.6, color = Color(hex: 0xf5f5f7), strong = Color.white, code: CGFloat = 13
}

// Builds a Text from inlines, numbering words for the fade as it goes. counter: the next word's index, shared across the answer.
@MainActor func inlineText(_ items: [Inline], style: AnswerStyle, counter: inout Int, bold: Bool = false, italic: Bool = false, mono: Bool = false) -> Text {
    var parts: [Text] = []
    func words(_ s: String, link: String? = nil) {
        // spaces stay between words; each word is its own run so it can fade on its own
        var cur = ""
        func flush() {
            guard !cur.isEmpty else { return }
            var t = Text(cur).customAttribute(WordKey(index: counter)); counter += 1
            if bold { t = t.fontWeight(.semibold).foregroundColor(style.strong) }
            if italic { t = t.italic() }
            if mono { t = t.font(.system(size: style.code, design: .monospaced)) }
            if let link { t = t.foregroundColor(Color(hex: 0x64d2ff)).customAttribute(LinkKey(url: link)) }
            parts.append(t); cur = ""
        }
        for ch in s { if ch == " " || ch == "\t" { flush(); parts.append(Text(String(ch))) } else { cur.append(ch) } }
        flush()
    }
    for x in items {
        switch x {
        case .text(let s): words(s)
        case .br: parts.append(Text("\n"))
        case .strong(let k): parts.append(inlineText(k, style: style, counter: &counter, bold: true, italic: italic, mono: mono))
        case .em(let k): parts.append(inlineText(k, style: style, counter: &counter, bold: bold, italic: true, mono: mono))
        case .code(let s):
            var t = Text(s).font(.system(size: style.code, design: .monospaced)).customAttribute(WordKey(index: counter)); counter += 1
            t = t.foregroundColor(style.color)
            parts.append(Text(" ").font(.system(size: 3)) + t + Text(" ").font(.system(size: 3)))   // the chip's 5 px padding, as hair spaces
        case .link(let label, let url): words(label, link: url)
        case .math(let tex):
            if let (img, descent) = MathCache.shared.image(tex, size: style.size, color: NSColor(style.color)) {
                parts.append(Text(Image(nsImage: img)).baselineOffset(-descent).customAttribute(WordKey(index: counter)))
            } else {
                parts.append(Text(tex).font(.system(size: 13, design: .monospaced)).foregroundColor(Color(hex: 0xe5e5ea)).customAttribute(WordKey(index: counter)))
            }
            counter += 1
        }
    }
    return parts.reduce(Text("")) { $0 + $1 }
}

// A streamed answer so far, without the blocks, list items or table rows that have no word yet: their marker, background or border
// would show before the first word does.
func trimUnworded(_ blocks: [MDBlock]) -> [MDBlock] {
    let worded = { (i: [Inline]) in !answerWords([.para(i)]).isEmpty }
    var out = blocks
    while let b = out.last {
        switch b {
        case .list(let o, let s, var items):
            while let l = items.last, !worded(l) { items.removeLast() }
            if items.isEmpty { out.removeLast(); continue }
            out[out.count - 1] = .list(ordered: o, start: s, items: items)
        case .table(let head, var rows):
            if !head.allSatisfy(worded) { out.removeLast(); continue }
            while let r = rows.last, !r.allSatisfy(worded) { rows.removeLast() }
            out[out.count - 1] = .table(head: head, rows: rows)
        default:
            if answerWords([b]).isEmpty { out.removeLast(); continue }
        }
        return out
    }
    return out
}

// The words of a block list, in the order inlineText numbers them (for Reveal).
func answerWords(_ blocks: [MDBlock]) -> [String] {
    var out: [String] = []
    func walk(_ items: [Inline]) {
        for x in items {
            switch x {
            case .text(let s): out += s.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            case .strong(let k), .em(let k): walk(k)
            case .code(let s): out.append("`" + s)
            case .link(let l, _): out += l.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            case .math(let t): out.append("$" + t)
            case .br: break
            }
        }
    }
    for b in blocks {
        switch b {
        case .para(let i), .heading(let i): walk(i)
        case .list(_, _, let items): items.forEach(walk)
        case .pre(let s): out += s.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).map(String.init)
        case .table(let head, let rows): head.forEach(walk); rows.forEach { $0.forEach(walk) }
        case .hr: break
        case .math(let t): out.append("$" + t)
        }
    }
    return out
}

// An answer: its blocks with the page's spacing, the words fading in on the shared clock.
struct AnswerView: View {
    let blocks: [MDBlock]
    var style = AnswerStyle()
    var reveal: Reveal? = nil
    var onLink: (String) -> Void = { _ in }
    var body: some View {
        let still = reveal == nil || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || UIClock.frozen != nil
        TimelineView(.animation(minimumInterval: nil, paused: still || (reveal?.done ?? true))) { tl in
            let now = UIClock.frozen.map { _ in 1e12 } ?? tl.date.timeIntervalSinceReferenceDate - Date().timeIntervalSinceReferenceDate + CACurrentMediaTime()
            Blocks(blocks: blocks, style: style, at: reveal?.at ?? [], now: now, still: still, onLink: onLink)
        }
    }
}
private struct Blocks: View {
    let blocks: [MDBlock]; let style: AnswerStyle; let at: [Double]; let now: Double; let still: Bool; let onLink: (String) -> Void
    var body: some View {
        var counter = 0
        let built: [(AnyView, CGFloat)] = blocks.enumerated().map { i, b in
            let top: CGFloat = i == 0 ? 0 : { if case .heading = b { return 24 }; if i > 0, case .heading = blocks[i - 1] { return 6 }; if case .math = b { return 12 }; return 14 }()
            return (AnyView(block(b, &counter)), top)
        }
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(built.indices, id: \.self) { i in built[i].0.padding(.top, built[i].1) }
        }
    }
    func fade(_ i: Int) -> Double { still || i >= at.count ? 1 : min(1, max(0, (now - at[i]) / 0.5)) }
    func linked(_ t: some View) -> some View {   // WordFade notes where each link's words land; a click there opens it
        let links = LinkRects()
        return t.textRenderer(WordFade(at: at, now: now, still: still, links: links))
            .boxTarget("link", kind: .link { p in links.rects.first { $0.0.insetBy(dx: -2, dy: -2).contains(p) }.map { onLink($0.1) } != nil })
    }
    func para(_ t: Text, size: CGFloat, lh: CGFloat) -> some View {
        linked(t.font(cssFont(size)).foregroundColor(style.color).lineHeight(size, lh))
            .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
    }
    @MainActor func block(_ b: MDBlock, _ counter: inout Int) -> some View {
        switch b {
        case .para(let items):
            return AnyView(para(inlineText(items, style: style, counter: &counter), size: style.size, lh: style.lh))
        case .heading(let items):
            let first = counter
            let t = inlineText(items.map(upper), style: style, counter: &counter)
            return AnyView(linked(t.font(cssFont(12, 700)).tracking(0.06 * 12).foregroundColor(.white).lineHeight(12, 1.4))
                .fixedSize(horizontal: false, vertical: true).opacity(first < counter ? 1 : 1))
        case .list(let ordered, let start, let items):
            var rows: [(Text, Int)] = []
            for it in items { let f = counter; rows.append((inlineText(it, style: style, counter: &counter), f)) }
            return AnyView(VStack(alignment: .leading, spacing: 6) {
                ForEach(rows.indices, id: \.self) { k in
                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        Text(ordered ? "\(start + k)." : "•").font(cssFont(style.size)).foregroundColor(Color(hex: 0xc7c7cc)).frame(width: 22, alignment: ordered ? .trailing : .center).padding(.trailing, 6)
                            .opacity(fade(rows[k].1))
                        para(rows[k].0, size: style.size, lh: style.lh)
                    }
                }
            })
        case .pre(let s):
            let f = counter
            counter += s.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).count
            return AnyView(ScrollView(.horizontal, showsIndicators: false) {
                Text(s).font(.system(size: 12.5, design: .monospaced)).foregroundColor(style.color).lineHeight(12.5, 1.5).fixedSize()
                    .padding(.vertical, 10).padding(.horizontal, 12)
            }.frame(maxWidth: .infinity, alignment: .leading).background(rr(10).fill(Color.white(0.07))).opacity(fade(f)).blur(radius: 2.5 * (1 - fade(f))))
        case .table(let head, let rows):
            let h = head.map { c in let f = counter; return (inlineText(c, style: style, counter: &counter), f) }
            let r = rows.map { $0.map { c in let f = counter; return (inlineText(c, style: style, counter: &counter), f) } }
            return AnyView(ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
                    GridRow { ForEach(h.indices, id: \.self) { i in cell(h[i].0, header: true, last: r.isEmpty, first: h[i].1) } }
                    ForEach(r.indices, id: \.self) { j in GridRow { ForEach(r[j].indices, id: \.self) { i in cell(r[j][i].0, header: false, last: j == r.count - 1, first: r[j][i].1) } } }
                }
            })
        case .hr:
            return AnyView(Rectangle().fill(Color.white(0.14)).frame(height: 0.5))
        case .math(let tex):
            let f = counter; counter += 1
            return AnyView(Group {
                if let (img, _) = MathCache.shared.image(tex, size: style.size, color: NSColor(style.color)) {
                    ScrollView(.horizontal, showsIndicators: false) { Image(nsImage: img).padding(.vertical, 2) }
                } else {
                    Text(tex).font(.system(size: 13, design: .monospaced)).foregroundColor(Color(hex: 0xe5e5ea)).frame(maxWidth: .infinity)
                }
            }.opacity(fade(f)).blur(radius: 2.5 * (1 - fade(f))).padding(.bottom, 12 - 14 < 0 ? 0 : 0))
        }
    }
    func cell(_ t: Text, header: Bool, last: Bool, first: Int) -> some View {   // its border fades in with its first word
        linked(t.font(cssFont(header ? 11.5 : 13, header ? 600 : 400)).foregroundColor(header ? Color(hex: 0xc7c7cc) : style.color).lineHeight(13, 1.45))
            .padding(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 12))
            .overlay(alignment: .bottom) { if !last || header { Rectangle().fill(Color.white(0.1)).frame(height: 0.5).opacity(fade(first)) } }
    }
    func upper(_ i: Inline) -> Inline {
        switch i { case .text(let s): return .text(s.uppercased()); case .strong(let k): return .strong(k.map(upper)); case .em(let k): return .em(k.map(upper)); default: return i }
    }
}
