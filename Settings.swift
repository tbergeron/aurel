// The Settings window's content. SettingsWindow (Aurel.swift) owns the window, talks to SettingsModel with calls (load, state,
// perms, …) and gets {do: …} messages back.
import AppKit
import SwiftUI

// MARK: - Tokens

struct PrefsTheme {
    let dark: Bool
    var fg: Color { dark ? Color(hex: 0xf5f5f7) : Color(hex: 0x1d1d1f) }
    var fg2: Color { dark ? Color(hex: 0xa1a1a6) : Color(hex: 0x6e6e73) }
    var fg3: Color { dark ? Color(hex: 0x98989d) : Color(hex: 0x6e6e73) }
    var card: Color { dark ? Color(hex: 0x2a2a2c) : Color(hex: 0xffffff) }
    var bg: Color { dark ? Color(hex: 0x1e1e20) : Color(hex: 0xf5f5f7) }
    var ctl: Color { dark ? .white(0.1) : Color(hex: 0xffffff) }
    var well: Color { dark ? .white(0.07) : .black(0.045) }
    var line: Color { dark ? .white(0.08) : .black(0.08) }
    var side: Color { dark ? .black(0.12) : .white(0.28) }
    var sel: Color { dark ? .white(0.08) : .black(0.06) }
    let accent = Color(hex: 0x0a84ff), green = Color(hex: 0x34c759)
    var track: Color { .rgba(120, 120, 128, dark ? 0.36 : 0.24) }
    var okText: Color { dark ? Color(hex: 0x34c759) : Color(hex: 0x1f7a35) }
    var warn: Color { dark ? Color(hex: 0xff9f0a) : Color(hex: 0xc93400) }
    var danger: Color { dark ? Color(hex: 0xff453a) : Color(hex: 0xd70015) }
    var on: Color { dark ? Color(hex: 0x636366) : Color(hex: 0xffffff) }
    var pop: Color { dark ? .rgba(44, 44, 46, 0.96) : .white(0.96) }
    var hover: Color { dark ? .rgba(50.12, 50.12, 52.12, 1) : .rgba(245.96, 245.96, 246.04, 1) }   // color-mix(fg 4%, card)
    var lift: Double { dark ? 1.2 : 0.96 }
}
private struct ThemeKey: EnvironmentKey { static let defaultValue = PrefsTheme(dark: false) }
extension EnvironmentValues { var prefsTheme: PrefsTheme { get { self[ThemeKey.self] } set { self[ThemeKey.self] = newValue } } }

let outCurve = (0.16, 1.0, 0.3, 1.0), easeCurve = (0.4, 0.0, 0.2, 1.0)   // --out, --ease
func out(_ s: Double) -> Animation? { css(outCurve.0, outCurve.1, outCurve.2, outCurve.3, s) }
func eased(_ s: Double) -> Animation? { css(easeCurve.0, easeCurve.1, easeCurve.2, easeCurve.3, s) }

// The sidebar's icons, from the page's <svg> elements (viewBox 24).
enum SectionIcon {
    static let general = [circle(12, 12, 3), "M12 2.5v3M12 18.5v3M2.5 12h3M18.5 12h3M5.3 5.3l2.1 2.1M16.6 16.6l2.1 2.1M5.3 18.7l2.1-2.1M16.6 7.4l2.1-2.1"]
    static let dictation = [rect(9, 3, 6, 12, 3), "M6 11v1a6 6 0 0 0 12 0v-1M12 18v3M8 21h8"]
    static let brain = ["M12 3v18M3 12h18M5.6 5.6l12.8 12.8M18.4 5.6L5.6 18.4"]
    static let memory = ["M6 4h12v16l-6-4-6 4z"]
    static let account = [circle(12, 8.5, 3.5), "M5 20a7 7 0 0 1 14 0"]
    static let about = ["M12 4v10M8 10l4 4 4-4M5 19h14"]
    static let apps = [rect(4, 4, 6.5, 6.5, 1.6), rect(13.5, 4, 6.5, 6.5, 1.6), rect(4, 13.5, 6.5, 6.5, 1.6), rect(13.5, 13.5, 6.5, 6.5, 1.6)]
}
// Row actions (viewBox 16, stroke 1.5).
enum RowIcon {
    static let trash = ["M3 4.5h10M6.5 4.5V3h3v1.5M4.5 4.5l.6 8.5h5.8l.6-8.5M7 7v3.5M9 7v3.5"]
    static let copy = ["M6.5 5.5h6a1 1 0 0 1 1 1v6a1 1 0 0 1-1 1h-6a1 1 0 0 1-1-1v-6a1 1 0 0 1 1-1zM10.5 5.5V3.5a1 1 0 0 0-1-1h-6a1 1 0 0 0-1 1v6a1 1 0 0 0 1 1h2"]
    static let check = ["M3.5 8.5l3 3 6-7"]
}
struct NavItem { let id, title: String; let color: UInt32; let icon: [String] }
let navItems = [
    NavItem(id: "general", title: "General", color: 0x8e8e93, icon: SectionIcon.general),
    NavItem(id: "dictation", title: "Dictation", color: 0xff375f, icon: SectionIcon.dictation),
    NavItem(id: "brain", title: "Intelligence", color: 0xd97757, icon: SectionIcon.brain),
    NavItem(id: "memory", title: "Memory", color: 0xff9f0a, icon: SectionIcon.memory),
    NavItem(id: "account", title: "Privacy & Safety", color: 0x0a84ff, icon: SectionIcon.account),
    NavItem(id: "about", title: "About & Updates", color: 0xbf5af2, icon: SectionIcon.about),
]

// MARK: - Model: what the page kept in P, dictations, asks, W, L, APPS…

final class SettingsModel: ObservableObject {
    var post: ([String: Any]) -> Void = { _ in }
    @Published var P: [String: Any] = [:]
    @Published var section = "general"
    @Published var risen = true
    @Published var recording = ""
    @Published var hotkeyTaken = false
    @Published var dictateHotkeyTaken = false
    @Published var schint: (String, String)? = nil   // a warning or live recording text, and its class
    var recFields: [String: CGRect] = [:]   // the two shortcut fields: a click anywhere else cancels a recording
    @Published var dictatehint: (String, String)? = nil
    @Published var recCaps: (label: String, hint: String)? = nil
    @Published var recKeys: (label: String, text: String)? = nil
    @Published var icon: NSImage?
    @Published var version = "Aurel"
    @Published var managedUpdates = false
    @Published var sharingUnavailable = false
    @Published var update = "Never checked this session."
    @Published var mics: [(id: String, name: String)] = []
    @Published var globe = false
    @Published var words: [String] = []
    @Published var history: [[String: Any]] = []
    @Published var stats: [String: Any] = [:]
    @Published var asks: [[String: Any]] = []
    @Published var rules: [String] = []
    @Published var skills: [[String: Any]] = []
    @Published var facts: [[String: Any]] = []
    @Published var plan: (ok: Bool, text: String)? = nil
    @Published var W: [String: Any]? = nil
    @Published var L: [String: Any]? = nil
    @Published var perms: [String: Bool] = [:]
    @Published var connText = "Checking your Claude account…"
    @Published var connected = false
    @Published var apps: [[String: Any]] = []
    @Published var pick: Set<String>? = nil
    @Published var asking = 0
    @Published var total = 0
    @Published var appView = "key"
    @Published var appQuery = ""
    @Published var notice: (text: String, action: String?, run: (() -> Void)?)? = nil
    @Published var pending: (msg: [String: Any], key: String)? = nil
    @Published var hiddenRows: Set<String> = []
    @Published var profileStatus = ""
    @Published var profileStatusFix: String? = nil
    @Published var profileBusy = false
    @Published var walking: String? = nil
    @Published var reduce = false
    @Published var search = ""
    @Published var openProfile: Set<String> = []
    @Published var flash: String? = nil
    @Published var newRule = ""
    var want: [String: Any]? = nil, painted = false, noticeTimer: Timer?, takenTimers: [String: Timer] = [:]
    var scroll: ((String) -> Void)?

    func str(_ k: String) -> String { P[k] as? String ?? "" }
    func bool(_ k: String) -> Bool { (P[k] as? Bool) ?? ((P[k] as? NSNumber)?.boolValue ?? false) }
    func num(_ k: String) -> Double { (P[k] as? NSNumber)?.doubleValue ?? 0 }
    var local: Bool { str("client") == "local" }
    var routing: String {
        if let r = P["routing"] as? String, !r.isEmpty { return r }
        return str("model") != "" && str("model") != "haiku" ? "capable" : (P["escalate"] as? Bool == false || P["escalateAuto"] as? Bool == false) ? "cheapest" : "balanced"
    }

    func set(_ k: String, _ v: Any) { P[k] = v; post(["do": "set", "k": k, "v": v]) }

    // st.* — Aurel.swift calls these by name, as it did the page's.
    func receive(_ call: String, _ v: Any) {
        switch call {
        case "load": load(v as? [String: Any] ?? [:])
        case "state": state(v as? [String: Any] ?? [:])
        // The 1.5 s poll repeats itself: only a change is published, so the views don't recompute for nothing.
        case "perms": let p = (v as? [String: Any] ?? [:]).mapValues { ($0 as? Bool) ?? (($0 as? NSNumber)?.boolValue ?? false) }; if p != perms { perms = p }
        case "mics":
            let m = (v as? [[String: Any]] ?? []).map { (id: ($0["uid"] as? String) ?? "", name: ($0["name"] as? String) ?? "") }
            if !m.elementsEqual(mics, by: { $0 == $1 }) { mics = m }
        case "globe": let g = (v as? Bool) ?? false; if g != globe { globe = g }
        case "dictation":
            let d = v as? [String: Any] ?? [:]
            words = d["words"] as? [String] ?? []; history = d["history"] as? [[String: Any]] ?? []; stats = d["stats"] as? [String: Any] ?? [:]
        case "parakeet": if (v as? NSDictionary) != (W as NSDictionary?) { W = v as? [String: Any] }
        case "llm": if (v as? NSDictionary) != (L as NSDictionary?) { L = v as? [String: Any] }
        case "motion": reduce = (v as? Bool) ?? false
        case "tab": openSection(v as? String ?? "general")
        case "reveal": want = v as? [String: Any]; reveal()
        case "notice": showNotice((v as? [String: Any])?["text"] as? String ?? "")
        case "walk": walking = v as? String
        case "connectors":
            let c = v as? [String: Any] ?? [:], conn = c["connected"] as? [String] ?? [], signin = c["signin"] as? [Any] ?? []
            let n = conn.count, s = signin.count
            connText = n > 0 ? conn.prefix(3).joined(separator: ", ") + (n > 3 ? " and \(n - 3) more" : "") + " connected" + (s > 0 ? " · \(s) need sign-in" : "") : s > 0 ? "\(s) need sign-in" : "Gmail, Drive and more."
            connected = n > 0
        case "apps":
            if asking > 0 { return }
            let list = v as? [[String: Any]] ?? []
            if pick == nil { pick = Set(list.filter { $0["suggested"] as? Bool == true && $0["status"] as? String == "new" }.compactMap { $0["id"] as? String }) }
            apps = list
        case "appStatus":
            guard let a = v as? [Any], a.count == 2, let id = a[0] as? String, let status = a[1] as? String, let i = apps.firstIndex(where: { $0["id"] as? String == id }) else { return }
            apps[i]["status"] = status
            if status != "asking" { asking = max(0, asking - 1); pick?.remove(id) }
        case "allowDone": asking = 0; post(["do": "apps"])
        case "profileImport": profileImported(v as? [String: Any] ?? [:])
        case "rec": rec(v as? String ?? "")
        case "taken": if let a = v as? [Any] { taken(a.first as? String ?? "", a.count > 1 ? (a[1] as? Bool ?? false) : false) } else { taken(v as? String ?? "", false) }
        case "flush": _ = flush(send: false)
        default: break
        }
    }

    func load(_ d: [String: Any]) {
        var p: [String: Any] = ["talkMode": "hold", "dictateMode": "verbatim", "dictateHotkeyLabel": "", "microphone": "automatic", "parakeetModel": "v3",
                                "localModel": "gemma4", "unloadAfter": 5, "bigAsks": "local", "claudeSees": false, "client": "local"]
        p.merge(d["prefs"] as? [String: Any] ?? [:]) { $1 }
        p["routines"] = d["routines"] as? [[String: Any]] ?? []
        P = p; recording = ""; recCaps = nil; recKeys = nil
        if schint?.1 != "warn" { schint = nil }; if dictatehint?.1 != "warn" { dictatehint = nil }   // a finished recording puts back the hint
        hotkeyTaken = d["hotkeyTaken"] as? Bool ?? false; dictateHotkeyTaken = d["dictateHotkeyTaken"] as? Bool ?? false
        if let i = imageFromDataURL(d["icon"] as? String) { icon = i }
        if let v = d["version"] as? String, !v.isEmpty { version = "Version " + v } else { version = "Aurel" }
        managedUpdates = d["managedUpdates"] as? Bool ?? false; sharingUnavailable = d["sharingUnavailable"] as? Bool ?? false
        update = (d["update"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Never checked this session."
        if let m = d["mics"] { receive("mics", m) }
        globe = d["globeTaken"] as? Bool ?? false
        if let s = d["state"] as? [String: Any] { state(s) }
    }

    func state(_ s: [String: Any]) {
        rules = s["rules"] as? [String] ?? []; skills = s["skills"] as? [[String: Any]] ?? []
        facts = (s["me"] as? [String: Any])?["facts"] as? [[String: Any]] ?? []
        if let p = s["plan"] as? [String: Any] { plan = (p["ok"] as? Bool ?? false, p["text"] as? String ?? "") }
        asks = s["asks"] as? [[String: Any]] ?? []
        let counts = sourceCounts, imported = (counts["contacts"] ?? 0) + (counts["mail"] ?? 0)
        if imported > 0 && profileStatus.isEmpty { profileStatus = "\(counts["contacts"] ?? 0) from Contacts · \(counts["mail"] ?? 0) from Mail" }
        painted = true; reveal()
    }
    var sourceCounts: [String: Int] { facts.reduce(into: [:]) { $0[$1["source"] as? String ?? "", default: 0] += 1 } }

    func openSection(_ s: String) {
        cancelRecord()
        section = s; scroll?("top")
        risen = false
        DispatchQueue.main.async { withAnimation(out(0.35)) { self.risen = true } }
        if s == "apps" { post(["do": "apps"]) }
    }
    var navOn: String { navItems.contains { $0.id == section } ? section : "account" }   // Apps opens from Privacy & Safety

    // One status line for the whole window, with an optional action. It fades on its own; a waiting deletion happens when it goes.
    func showNotice(_ text: String, _ action: String? = nil, _ run: (() -> Void)? = nil) {
        _ = flush(); noticeTimer?.invalidate()
        notice = text.isEmpty ? nil : (text, action, run)
        if !text.isEmpty { noticeTimer = Timer.scheduledTimer(withTimeInterval: 6, repeats: false) { [weak self] _ in self?.showNotice("") } }
    }
    func flush(send: Bool = true) -> [String: Any]? {
        let m = pending?.msg; pending = nil; hiddenRows = []
        if let m, send { post(m) }
        return m
    }
    func undoable(_ msg: [String: Any], key: String, _ text: String) {
        showNotice(text, "Undo") { [weak self] in self?.pending = nil; self?.hiddenRows.remove(key) }
        pending = (msg, key); hiddenRows.insert(key)
    }

    // Shortcut recording: Aurel.swift records; these show what it sees.
    var shortcutHint: String {
        hotkeyTaken ? "Another app uses this shortcut. Change it to use Aurel." : str("input") == "type" ? "Press to type. Return sends."
            : str("talkMode") == "toggle" ? "Press to listen. Press again to send." : "Hold it, talk, let go."
    }
    var dictateHint: String { dictateHotkeyTaken ? "Another app uses this shortcut. Record another." : "Hold to talk. Double-tap to lock." }
    func toggleRecord() {
        if !recording.isEmpty { return cancelRecord() }
        recording = "main"; recCaps = ("", "Recording — press your shortcut")
        schint = ("Press a key combo, a modifier on its own, or an F-key. Esc or click away cancels.", "")
        post(["do": "record"])
    }
    func toggleRecordDictate() {
        if !recording.isEmpty { return cancelRecord() }
        recording = "dictate"; recKeys = ("", "Type Shortcut")
        dictatehint = ("Press a key combo, a modifier on its own, or an F-key. Esc cancels.", "")
        post(["do": "recordDictate"])
    }
    func clicked(_ p: CGPoint) { if !recFields.values.contains(where: { $0.contains(p) }) { cancelRecord() } }
    func cancelRecord() {
        if recording.isEmpty { return }
        recording = ""; recCaps = nil; recKeys = nil
        if schint?.1 != "warn" { schint = nil }
        if dictatehint?.1 != "warn" { dictatehint = nil }
        post(["do": "cancelRecord"])
    }
    func rec(_ m: String) {
        if recording == "dictate" { recKeys = m.hasPrefix("Add") || m.isEmpty ? ("", m.isEmpty ? "Type Shortcut" : m) : (m, "") }
        else if !recording.isEmpty { recCaps = m.hasPrefix("Add") ? ("", m) : (m, m.isEmpty ? "Press your shortcut" : "") }
    }
    func taken(_ kind: String, _ own: Bool) {
        let dictate = kind == "dictate"
        let text = own ? "That’s already your \(dictate ? "Aurel" : "dictation") shortcut. Kept your old one." : "Another app already uses that shortcut. Kept your old one."
        if dictate { dictatehint = (text, "warn") } else { schint = (text, "warn") }
        takenTimers[kind]?.invalidate()
        takenTimers[kind] = Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { [weak self] _ in if dictate { self?.dictatehint = nil } else { self?.schint = nil } }
    }

    // st.reveal({c, t}): a receipt in the box was clicked. Open its category, scroll to the item and let it glow.
    func reveal() {
        guard let w = want, painted, let c = w["c"] as? String else { return }
        let t = w["t"] as? String ?? ""
        let isProfile = profileCategories.contains { $0.0 == c }
        guard isProfile || c == "rules" else { return }
        want = nil
        if isProfile { openProfile.insert(c) }
        let target: String
        if c == "rules", let i = rules.firstIndex(of: t) { target = "rule-\(i)" }
        else if isProfile, let f = facts.first(where: { $0["category"] as? String == c && "\($0["kind"] ?? ""): \($0["value"] ?? "")" == t }) { target = "fact-\(f["id"] ?? "")" }
        else { target = isProfile ? "cat-\(c)" : "rules" }
        DispatchQueue.main.async { self.scroll?(target); self.flash = nil; DispatchQueue.main.async { self.flash = target } }
    }

    func profileImported(_ r: [String: Any]) {
        profileBusy = false
        let errors = r["errors"] as? [String] ?? [], counts = r["counts"] as? [String: Int] ?? [:]
        let name = { (e: String) in ["contacts": "Contacts", "mail": "Mail"][e] ?? e }
        let failed = errors.map(name).joined(separator: " and ")
        var s = errors.count == 2 ? "Couldn’t read Contacts or Mail. Nothing changed. "
            : "\(counts["contacts"] ?? 0) from Contacts · \(counts["mail"] ?? 0) from Mail\(errors.isEmpty ? "" : " · Couldn’t read \(failed). ")"
        let reasons = r["errorReasons"] as? [String: String] ?? [:], denied = errors.filter { reasons[$0] == "automation" }
        if errors.contains(where: { !denied.contains($0) }) { s += " Try importing again. " }
        profileStatus = s
        profileStatusFix = denied.isEmpty ? nil : "Allow \(denied.map(name).joined(separator: " and ")) in Automation"
    }

    // Apps
    var shownApps: [[String: Any]] {
        let q = appQuery.trimmingCharacters(in: .whitespaces).lowercased()
        return !q.isEmpty ? apps.filter { ($0["name"] as? String ?? "").lowercased().contains(q) } : appView == "key" ? apps.filter { $0["suggested"] as? Bool == true } : apps
    }
    var allowCount: Int { apps.filter { $0["status"] as? String == "new" && (pick?.contains($0["id"] as? String ?? "") ?? false) }.count }
    func allowTapped() {
        if asking > 0 {
            post(["do": "stopAllow"]); asking = 0
            for i in apps.indices where apps[i]["status"] as? String == "asking" { apps[i]["status"] = "new" }
            return
        }
        let ids = apps.filter { $0["status"] as? String == "new" && (pick?.contains($0["id"] as? String ?? "") ?? false) }.compactMap { $0["id"] as? String }
        asking = ids.count; total = ids.count; post(["do": "allow", "ids": ids])
    }
}

let profileCategories = [("basics", "Basics", "name: Saarth"), ("contact", "Contact", "email: me@example.com"), ("places", "Places", "home address: …"),
                         ("school_work", "School & work", "school: …"), ("links", "Links & handles", "website: …"), ("preferences", "Preferences", "answers: concise"),
                         ("people", "People", "dad: Sunil Ranka"), ("notes", "Notes", "Anything else")]

// MARK: - Pieces the page drew with CSS classes

private struct T: View {   // text with the page's metrics: size, weight, line-height, letter-spacing (in em)
    let s: String; var size: CGFloat = 13; var weight = 400; var lh: CGFloat? = nil; var em: CGFloat = 0; var color: Color? = nil; var tabular = false
    @Environment(\.prefsTheme) var th
    var body: some View {
        Text(s).font(cssFont(size, weight)).monospacedDigit(tabular).tracking(em * size).foregroundColor(color ?? th.fg).lineHeight(size, lh)
            .fixedSize(horizontal: false, vertical: true)
    }
}
private extension Text { func monospacedDigit(_ on: Bool) -> Text { on ? self.monospacedDigit() : self } }
private extension View { func monospacedDigit(_ on: Bool) -> some View { Group { if on { self.monospacedDigit() } else { self } } } }

// The ⓘ that sat inline in a hint: an 11px ring with a 600 8px "i", 1px below the baseline.
private func infoImage(_ color: NSColor) -> NSImage {
    NSImage(size: NSSize(width: 13, height: 11), flipped: true) { _ in
        let ring = NSBezierPath(ovalIn: NSRect(x: 2.5, y: 0.5, width: 10, height: 10)); color.setStroke(); ring.lineWidth = 1; ring.stroke()
        let s = NSAttributedString(string: "i", attributes: [.font: NSFont.systemFont(ofSize: 8, weight: .semibold), .foregroundColor: color])
        let sz = s.size(); s.draw(at: NSPoint(x: 2 + (11 - sz.width) / 2, y: (11 - sz.height) / 2)); return true
    }
}
private struct Hint: View {   // .row .t span
    let s: String; var info: String? = nil; var color: Color? = nil
    @Environment(\.prefsTheme) var th
    var body: some View {
        let c = color ?? th.fg3
        Group {
            if let info { (Text(s + " ") + Text(Image(nsImage: infoImage(NSColor(c)))).baselineOffset(-1)).help(info) } else { Text(s) }
        }
        .font(cssFont(11.5)).foregroundColor(c).lineHeight(11.5, 1.35).fixedSize(horizontal: false, vertical: true)
        .padding(.top, 2)
    }
}

private struct Group_<Content: View>: View {   // .group
    @Environment(\.prefsTheme) var th
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) { content }
            .background(th.card).clipShape(rr(11))
            .insetRing(rr(11), th.line)
            .cssShadow(.black(0.04), y: 1, blur: 2)
    }
}
private struct Row<Content: View>: View {   // .row: min 44 tall, 8/14 padding, a hairline above every row but the first
    var first = false; var minHeight: CGFloat = 44; var dim = false; var now = false; var hoverBG = false; var align: VerticalAlignment = .center
    var padding = EdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 14)
    @ViewBuilder var content: (Bool) -> Content
    @State private var hovered = false
    @Environment(\.prefsTheme) var th
    var body: some View {
        HStack(alignment: align, spacing: 14) { content(hovered) }
            .padding(padding)
            .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .leading)
            .background(now ? Color.rgba(10, 132, 255, 0.1) : hoverBG && hovered ? th.hover : .clear)
            .overlay(alignment: .top) { if !first { Rectangle().fill(th.line).frame(height: 0.5) } }
            .opacity(dim ? 0.45 : 1).animation(eased(0.2), value: dim)
            .onHover { hovered = $0 }
    }
}
private struct Title: View {   // .row .t
    let b: String; var span: String? = nil; var info: String? = nil; var spanColor: Color? = nil; var weight = 500
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            T(s: b, weight: weight)
            if let span { Hint(s: span, info: info, color: spanColor) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
private struct H1: View {
    let s: String; var icon: NavItem? = nil
    var body: some View {
        HStack(spacing: 11) {
            if let icon { Tile(item: icon, side: 32, radius: 8, glyph: 19).insetRing(rr(8), .black(0.08)) }
            T(s: s, size: 24, weight: 700, lh: 1.15, em: -0.02)
        }.padding(.bottom, icon == nil ? 4 : 8)
    }
}
private struct Lede: View {
    let s: String; var size: CGFloat = 13; var bottom: CGFloat = 22
    @Environment(\.prefsTheme) var th
    var body: some View { T(s: s, size: size, lh: 1.45, color: th.fg2).padding(.bottom, bottom).frame(maxWidth: .infinity, alignment: .leading) }
}
private struct H3: View {
    let s: String
    var body: some View { T(s: s, weight: 600, em: -0.005).padding(.horizontal, 2).padding(.bottom, 9).frame(maxWidth: .infinity, alignment: .leading) }
}
struct Tile: View {   // .ni: a coloured rounded square with a white stroked glyph
    let item: NavItem; var side: CGFloat = 22, radius: CGFloat = 6, glyph: CGFloat = 14
    var body: some View {
        ZStack { rr(radius).fill(Color(hex: item.color)); Icon(paths: item.icon, stroke: 1.9, color: .white).frame(width: glyph, height: glyph) }
            .frame(width: side, height: side)
    }
}

struct Switch: View {   // .sw
    let on: Bool; let toggle: () -> Void
    @Environment(\.prefsTheme) var th
    var body: some View {
        ZStack(alignment: .leading) {
            rr(11).fill(on ? th.green : th.track).animation(eased(0.2), value: on)
            Circle().fill(Color.white).frame(width: 18, height: 18).cssShadow(.black(0.25), y: 1, blur: 3)
                .offset(x: on ? 18 : 2).animation(out(0.22), value: on)
        }
        .frame(width: 38, height: 22).contentShape(Rectangle()).onTapGesture(perform: toggle)
        .accessibilityElement().accessibilityAddTraits(.isToggle).accessibilityValue(on ? "On" : "Off").accessibilityAction(.default, toggle)   // VoiceOver reads it with its row
    }
}
struct Seg: View {   // .seg
    let options: [(String, String)]; let value: String; var disabled = false; let pick: (String) -> Void
    @Environment(\.prefsTheme) var th
    var body: some View {
        HStack(spacing: 0) { ForEach(options, id: \.0) { o in SegButton(label: o.1, on: o.0 == value) { pick(o.0) } } }
            .padding(2).background(rr(8).fill(th.track)).fixedSize()
            .opacity(disabled ? 0.4 : 1).allowsHitTesting(!disabled)
    }
}
private struct SegButton: View {
    let label: String, on: Bool, tap: () -> Void
    @State private var hover = false
    @Environment(\.prefsTheme) var th
    var body: some View {
        Text(label).font(cssFont(12)).lineHeight(12, nil).foregroundColor(th.fg).padding(.vertical, 4).padding(.horizontal, 11)
            .background { if on { rr(6).fill(th.on).insetRing(rr(6), th.line).cssShadow(.black(0.15), y: 1, blur: 3) } else if hover { rr(6).fill(th.sel) } }
            .animation(Ease.ease(0.2), value: on)
            .contentShape(Rectangle()).onHover { hover = $0 }.onTapGesture(perform: tap)
            .accessibilityElement().accessibilityLabel(label).accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton).accessibilityAction(.default, tap)
    }
}
struct Btn: View {   // .btn, .btn.blue, .btn.red
    let label: String; var kind = ""; var height: CGFloat = 26; var disabled = false; let tap: () -> Void
    @State private var hover = false
    @State private var down = false
    @Environment(\.prefsTheme) var th
    var body: some View {
        let blue = kind == "blue", stop = kind == "stop"
        Text(label).font(cssFont(12.5, 500)).lineHeight(12.5, nil).foregroundColor(blue || stop ? .white : kind == "red" ? th.danger : th.fg)
            .padding(.horizontal, 12).frame(height: height)
            .background {
                if blue || stop { rr(7).fill(stop ? Color(hex: 0xff453a) : th.accent) }
                else { rr(7).fill(th.ctl).insetRing(rr(7), th.line).cssShadow(.black(0.05), y: 1, blur: 1) }
            }
            .brightness(hover && !disabled ? (th.lift - 1) : 0)
            .scaleEffect(down ? 0.97 : 1).animation(Ease.ease(0.1), value: down)
            .opacity(disabled ? 0.45 : 1)
            .fixedSize()
            .contentShape(Rectangle())
            .onHover { hover = $0 }
            .gesture(DragGesture(minimumDistance: 0).onChanged { _ in down = true }.onEnded { _ in down = false; if !disabled { tap() } })
            .pressable(label, disabled: disabled, tap)
    }
}
private struct Cap: View {   // .cap keycap
    let s: String; var size: CGFloat = 12, height: CGFloat = 26, minW: CGFloat = 26, pad: CGFloat = 7, radius: CGFloat = 6, weight = 500
    @Environment(\.prefsTheme) var th
    var body: some View {
        Text(s).font(cssFont(size, weight)).foregroundColor(th.dark ? Color(hex: 0xf5f5f7) : Color(hex: 0x1d1d1f))
            .padding(.horizontal, pad).frame(minWidth: minW).frame(height: height)
            .background(rr(radius).fill(LinearGradient(colors: th.dark ? [Color(hex: 0x48484a), Color(hex: 0x3a3a3c)] : [Color(hex: 0xfdfdfd), Color(hex: 0xe8e8ed)], startPoint: .top, endPoint: .bottom)))
            .background(rr(radius).fill(Color.black(th.dark ? 0.6 : 0.16)).offset(y: 1.5))
            .overlay(rr(radius).inset(by: -0.25).stroke(Color.black(th.dark ? 0.6 : 0.16), lineWidth: 0.5))
    }
}
func capsOf(_ label: String) -> [String] {   // "fn⌃⌥Space" → fn, ⌃, ⌥, Space
    var caps: [String] = [], rest = Substring(label)
    while true {
        if rest.hasPrefix("fn") { caps.append("fn"); rest = rest.dropFirst(2) }
        else if let c = rest.first, "⌃⌥⇧⌘".contains(c) { caps.append(String(c)); rest = rest.dropFirst() }
        else { break }
    }
    if !rest.isEmpty { caps.append(String(rest)) }
    return caps
}
private struct RowX: View {   // .row > .x: a quiet icon at the far right, shown on hover
    let icon: [String]; var shown: Bool; var save = false; var copy = false; let tap: () -> Void
    @State private var hover = false
    @Environment(\.prefsTheme) var th
    var body: some View {
        Icon(paths: icon, box: 16, stroke: 1.5, color: hover ? ((copy || save) ? th.accent : th.danger) : save ? th.accent : th.fg3).frame(width: 15, height: 15)
            .frame(width: 26, height: 26).background(rr(7).fill(hover ? th.sel : .clear))
            .opacity(shown || save ? 1 : 0).offset(x: shown || save ? 0 : 6)
            .animation(eased(0.18), value: shown)
            .contentShape(Rectangle()).onHover { hover = $0 }.onTapGesture(perform: tap)
    }
}
private struct Field: View {   // .field and .add input: a plain text field
    let placeholder: String; @Binding var text: String; var align: TextAlignment = .leading; var blur: (() -> Void)? = nil; var submit: () -> Void = {}
    @Environment(\.prefsTheme) var th
    @FocusState private var focused: Bool
    var body: some View {   // blur: a saved row's edit also saves on leaving it (clicking away, another section), like the page's onchange
        TextField("", text: $text, prompt: Text(placeholder).foregroundColor(th.fg3)).textFieldStyle(.plain).font(cssFont(13)).foregroundColor(th.fg)
            .multilineTextAlignment(align).onSubmit(submit).focused($focused)
            .onChange(of: focused) { _, f in if !f { blur?() } }.onDisappear { blur?() }
    }
}
private struct AddRow: View {   // .add: an input in a well, and a blue button
    let placeholder: String; let button: String; var first = false; var leading: CGFloat = 0; let add: (String) -> Void
    @State private var text = ""
    @Environment(\.prefsTheme) var th
    var body: some View {
        HStack(spacing: 8) {
            Field(placeholder: placeholder, text: $text) { add(text); text = "" }.padding(.horizontal, 10).frame(height: 28).background(rr(7).fill(th.well))
            Btn(label: button, kind: "blue") { add(text); text = "" }
        }
        .padding(EdgeInsets(top: 9, leading: 14, bottom: 9, trailing: 10))
        .overlay(alignment: .top) { if !first { Rectangle().fill(th.line).frame(height: 0.5) } }
        .padding(.leading, leading)
    }
}
private struct Select: View {   // <select>: the value and a chevron on a light control; a click opens the menu WebKit opened
    let options: [(String, String)]; let value: String; let pick: (String) -> Void
    @Environment(\.prefsTheme) var th
    var body: some View {
        let label = options.first { $0.0 == value }?.1 ?? options.first?.1 ?? ""
        HStack(spacing: 5) {
            Text(label).font(cssFont(13)).lineHeight(13, nil).foregroundColor(th.fg)
            Icon(paths: ["M3 6l5 5 5-5"], box: 16, stroke: 1.6, color: th.fg).frame(width: 9, height: 9)
        }
        .padding(.vertical, 3).padding(.leading, 6).padding(.trailing, 6)
        .background(rr(6).fill(th.ctl).insetRing(rr(6), th.line).cssShadow(.black(0.05), y: 1, blur: 1))
        .fixedSize()
        .overlay(PopUp(options: options, value: value, pick: pick))
    }
}
private struct PopUp: NSViewRepresentable {   // an invisible view that pops the menu up over the control, the current item under the pointer
    let options: [(String, String)]; let value: String; let pick: (String) -> Void
    func makeNSView(context: Context) -> PopView { PopView() }
    func updateNSView(_ v: PopView, context: Context) { v.options = options; v.value = value; v.pick = pick }
    final class PopView: NSView {
        var options: [(String, String)] = [], value = "", pick: (String) -> Void = { _ in }
        override func mouseDown(with e: NSEvent) {
            let menu = NSMenu(); var current: NSMenuItem?
            for o in options { let i = NSMenuItem(title: o.1, action: #selector(chose(_:)), keyEquivalent: ""); i.target = self; i.representedObject = o.0; menu.addItem(i); if o.0 == value { current = i; i.state = .on } }
            menu.font = .systemFont(ofSize: 13)
            menu.popUp(positioning: current, at: NSPoint(x: 0, y: bounds.height - 3), in: self)
        }
        @objc func chose(_ i: NSMenuItem) { pick(i.representedObject as? String ?? "") }
        override var isFlipped: Bool { false }
    }
}
private struct Pill: View {   // .pill
    let s: String; let kind: String
    @Environment(\.prefsTheme) var th
    @State private var dim = false
    var body: some View {
        Text(s).font(cssFont(11.5, 500)).lineHeight(11.5, nil).foregroundColor(kind == "ok" ? th.okText : kind == "no" ? th.warn : th.fg2)
            .padding(.vertical, 3).padding(.horizontal, 9)
            .background(rr(10).fill(kind == "ok" ? Color.rgba(52, 199, 89, 0.13) : kind == "no" ? .rgba(255, 159, 10, 0.14) : th.sel))
            .opacity(kind == "wait" && dim ? 0.45 : 1)
            .onAppear { if kind == "wait" { withAnimation(.easeInOut(duration: 0.6).repeatForever()) { dim = true } } }
            .fixedSize()
    }
}
private struct Dot: View { let bad: Bool; @Environment(\.prefsTheme) var th
    var body: some View { Circle().fill(bad ? Color(hex: 0xff9f0a) : th.green).frame(width: 8, height: 8) } }

// MARK: - The window's content

struct SettingsView: View {
    @ObservedObject var m: SettingsModel
    @Environment(\.colorScheme) var scheme
    var body: some View {
        let th = PrefsTheme(dark: scheme == .dark)
        HStack(spacing: 0) {
            Nav(m: m).frame(width: 208)
            Main(m: m)
        }
        .overlay(alignment: .bottom) { Notice(m: m).padding(.leading, 208) }
        .environment(\.prefsTheme, th)
        .transaction { if m.reduce { $0.animation = nil } }
        .coordinateSpace(.named("prefs"))
        .simultaneousGesture(SpatialTapGesture(coordinateSpace: .named("prefs")).onEnded { m.clicked($0.location) })
        .ignoresSafeArea()   // the page ran under the transparent title bar
    }
}

private struct Nav: View {
    @ObservedObject var m: SettingsModel
    @Environment(\.prefsTheme) var th
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 10) {
                Group { if let i = m.icon { Image(nsImage: i).resizable() } else { Color.clear } }.frame(width: 38, height: 38)
                VStack(alignment: .leading, spacing: 0) {
                    T(s: "Aurel", size: 14, weight: 600)
                    T(s: "Just ask.", size: 11, color: th.fg3)
                }
            }.padding(EdgeInsets(top: 4, leading: 8, bottom: 16, trailing: 8))
            ForEach(navItems, id: \.id) { item in NavButton(item: item, on: m.navOn == item.id) { m.openSection(item.id) } }
            Spacer(minLength: 0)
            T(s: m.version, size: 11, color: th.fg3).padding(.horizontal, 8)
        }
        .padding(EdgeInsets(top: 46, leading: 10, bottom: 14, trailing: 10))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(th.side)
        .overlay(alignment: .trailing) { Rectangle().fill(th.line).frame(width: 0.5) }
    }
}
private struct NavButton: View {
    let item: NavItem; let on: Bool; let tap: () -> Void
    @State private var hover = false
    @Environment(\.prefsTheme) var th
    var body: some View {
        HStack(spacing: 9) { Tile(item: item); Text(item.title).font(cssFont(13)).lineHeight(13, nil).foregroundColor(on ? .white : th.fg) }
            .padding(.horizontal, 8).frame(maxWidth: .infinity, minHeight: 30, maxHeight: 30, alignment: .leading)
            .background(rr(7).fill(on ? th.accent : hover ? th.sel : .clear)).animation(Ease.ease(0.15), value: hover)
            .contentShape(Rectangle()).onHover { hover = $0 }.onTapGesture(perform: tap).pressable(item.title, selected: on, tap)
    }
}

private struct Main: View {
    @ObservedObject var m: SettingsModel
    @Environment(\.prefsTheme) var th
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    Group {
                        switch m.section {
                        case "dictation": DictationSection(m: m)
                        case "brain": BrainSection(m: m)
                        case "memory": MemorySection(m: m)
                        case "apps": AppsSection(m: m)
                        case "account": AccountSection(m: m)
                        case "about": AboutSection(m: m)
                        default: GeneralSection(m: m)
                        }
                    }
                    .frame(maxWidth: 600).frame(maxWidth: .infinity)
                    .opacity(m.risen ? 1 : 0).offset(y: m.risen ? 0 : 6)
                }
                .padding(EdgeInsets(top: 40, leading: 34, bottom: 40, trailing: 34))
                .background(alignment: .top) { Color.clear.frame(height: 0).id("top") }
                .background(alignment: .bottom) { Color.clear.frame(height: 0).id("bottom") }
            }
            .background(th.bg)
            .overlay(alignment: .leading) { Rectangle().fill(th.line).frame(width: 0.5) }
            .onAppear { m.scroll = { id in withAnimation(nil) { proxy.scrollTo(id, anchor: id == "bottom" ? .bottom : id == "top" ? .top : .center) } } }
        }
    }
}

// MARK: Sections

private struct GeneralSection: View {
    @ObservedObject var m: SettingsModel
    @Environment(\.prefsTheme) var th
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            H1(s: "General", icon: navItems[0])
            Lede(s: "Your shortcut. Your way to talk.")
            H3(s: "Shortcut").padding(.top, 8)
            ShortcutCard(m: m)
            Group_ {
                Row(first: true) { _ in Title(b: "Shortcut opens"); Seg(options: [("voice", "Voice"), ("type", "Typing")], value: m.str("input")) { m.set("input", $0) } }
                if m.str("input") != "type" {
                    Row { _ in Title(b: "Shortcut behavior", span: m.str("talkMode") == "toggle" ? "Pauses keep listening." : "Esc cancels.")
                        Seg(options: [("hold", "Hold to talk"), ("toggle", "Press to toggle")], value: m.str("talkMode")) { m.set("talkMode", $0) } }
                }
                Row { _ in Title(b: "Wake word: say “Aurel”", span: "Listen on this Mac. Close the box to end hands-free chat."); Switch(on: m.bool("wakeWord")) { m.set("wakeWord", !m.bool("wakeWord")) } }
            }.padding(.top, 12)
            H3(s: "Aurel").padding(.top, 30)
            Group_ {
                Row(first: true) { _ in Title(b: "Sound volume"); VolumeSlider(m: m)
                    T(s: "\(Int((m.num("volume") / 0.6 * 100).rounded()))%", color: th.fg2, tabular: true).frame(width: 44, alignment: .trailing) }
                Row { _ in Title(b: "Free memory after", span: "Unloads the speech and AI models when idle.")
                    Select(options: [("1", "1 minute"), ("5", "5 minutes"), ("15", "15 minutes"), ("60", "1 hour"), ("0", "Never")], value: "\(Int(m.num("unloadAfter")))") { m.set("unloadAfter", Int($0) ?? 5) } }
                Row { _ in Title(b: "Open at login"); Switch(on: m.bool("login")) { m.set("login", !m.bool("login")) } }
                Row { _ in Title(b: "Pause Aurel"); Switch(on: m.bool("paused")) { m.set("paused", !m.bool("paused")) } }
                Row { _ in Title(b: "Show in menu bar", span: "Hidden? Open it from Spotlight."); Switch(on: m.bool("menuIcon")) { m.set("menuIcon", !m.bool("menuIcon")) } }
                Row { _ in Title(b: "Quit Aurel", span: "Reopen it from Spotlight."); Btn(label: "Quit", kind: "red") { m.post(["do": "quit"]) } }
            }
            H3(s: "Answers").padding(.top, 30)
            Group_ {
                Row(first: true) { _ in Title(b: "Show answers", span: "Word by word as Aurel writes, or all at the end.")
                    Seg(options: [("stream", "As they arrive"), ("once", "All at once")], value: m.str("showAnswers")) { m.set("showAnswers", $0) } }
                Row { _ in Title(b: "Read answers aloud", span: "Esc stops it."); Switch(on: m.bool("speak")) { m.set("speak", !m.bool("speak")) } }
                Row { _ in Title(b: "Draw on screen to show you", span: "Esc clears. To mark a spot yourself, use Point at your screen."); Switch(on: m.bool("draw")) { m.set("draw", !m.bool("draw")) } }
            }
            H3(s: "Scheduled routines").padding(.top, 30)
            Routines(m: m)
        }
    }
}
private struct VolumeSlider: View {   // <input type=range> with accent-color: WebKit drew the system slider
    @ObservedObject var m: SettingsModel
    var body: some View {
        Slider(value: Binding(get: { m.num("volume") }, set: { m.P["volume"] = ($0 / 0.02).rounded() * 0.02 }), in: 0...0.6) { editing in   // step .02, without tick marks
            if !editing { m.set("volume", m.num("volume")); m.post(["do": "preview", "sound": (m.str("soundDone") == "None" ? "Glass" : m.str("soundDone"))]) }
        }
        .tint(Color(hex: 0x0a84ff)).frame(width: 150)
    }
}
private struct ShortcutCard: View {
    @ObservedObject var m: SettingsModel
    @Environment(\.prefsTheme) var th
    @State private var blink = false
    var body: some View {
        let rec = m.recording == "main"
        let caps = rec ? capsOf(m.recCaps?.label ?? "") : capsOf(m.str("hotkeyLabel"))
        let hint = rec ? (m.recCaps?.hint ?? "") : ""
        VStack(spacing: 14) {
            HStack(spacing: 7) {
                ForEach(caps.indices, id: \.self) { i in
                    let c = caps[i], wide = c.count > 2
                    Cap(s: c, size: wide ? 14 : 16, height: 40, minW: wide ? 96 : 40, pad: 12, radius: 9)
                }
                if !hint.isEmpty { T(s: hint, size: 14, color: th.fg2).opacity(blink ? 0.45 : 1).onAppear { withAnimation(.easeInOut(duration: 0.7).repeatForever()) { blink = true } } }
            }.frame(minHeight: 40)
            let line = m.schint ?? (m.shortcutHint, m.hotkeyTaken ? "taken" : "")
            T(s: line.0, size: 11.5, color: line.1.isEmpty ? th.fg3 : th.warn).multilineTextAlignment(.center)
            HStack(spacing: 8) {
                Btn(label: rec ? "Cancel Recording" : "Change Shortcut", kind: "blue") { m.toggleRecord() }
                if m.str("hotkeyLabel") != "⌃⌥Space" { Btn(label: "Use Default") { m.post(["do": "resetHotkey"]) } }
            }
        }
        .padding(EdgeInsets(top: 26, leading: 16, bottom: 18, trailing: 16)).frame(maxWidth: .infinity)
        .background(rr(11).fill(th.card))
        .overlay(rr(11).strokeBorder(rec ? th.accent : th.line, lineWidth: rec ? 2 : 0.5))
        .background(rr(11).inset(by: -4).fill(rec ? Color.rgba(10, 132, 255, 0.15) : .clear))
        .animation(Ease.ease(0.25), value: rec)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("prefs")) } action: { m.recFields["main"] = $0 }
        .onDisappear { m.recFields["main"] = nil }
    }
}
private struct Routines: View {
    @ObservedObject var m: SettingsModel
    @Environment(\.prefsTheme) var th
    var body: some View {
        let list = m.P["routines"] as? [[String: Any]] ?? []
        if list.isEmpty { T(s: "No routines yet. Ask Aurel to schedule one.", size: 12, color: th.fg3).padding(EdgeInsets(top: 2, leading: 2, bottom: 0, trailing: 2)) }
        else {
            Group_ {
                ForEach(list.indices, id: \.self) { i in
                    let r = list[i], title = routineTitle(r)
                    Row(first: i == 0, hoverBG: true) { hovered in
                        HStack(spacing: 10) {
                            Title(b: title, span: "\(r["ask"] as? String ?? "") · \(r["mode"] as? String == "capable" ? "Most capable" : r["mode"] as? String == "balanced" ? "Balanced" : "Cheapest")")
                            RowX(icon: RowIcon.trash, shown: hovered) { m.post(["do": "routineRemove", "id": r["id"] ?? ""]) }
                        }
                    }
                }
            }
        }
    }
    func routineTitle(_ r: [String: Any]) -> String {
        if r["kind"] as? String == "interval" {
            let every = (r["every"] as? NSNumber)?.doubleValue ?? 3600, hours = every / 3600, minutes = every / 60
            return hours == hours.rounded() ? "Every \(hours == 1 ? "" : "\(Int(hours)) ")hour\(hours == 1 ? "" : "s")" : "Every \(minutes.formatted()) minutes"
        }
        let parts = (r["at"] as? String ?? "0:0").split(separator: ":").map { Int($0) ?? 0 }, hour = parts[0], minute = parts.count > 1 ? parts[1] : 0
        return "\(r["days"] as? String == "weekdays" ? "Weekdays" : "Every day") at \(hour % 12 == 0 ? 12 : hour % 12):\(String(format: "%02d", minute)) \(hour < 12 ? "AM" : "PM")"
    }
}

private struct DictationSection: View {
    @ObservedObject var m: SettingsModel
    @Environment(\.prefsTheme) var th
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            H1(s: "Dictation", icon: navItems[1])
            Lede(s: "Your voice, in any text field.")
            Stats(m: m)
            H3(s: "Dictate anywhere").padding(.top, 30)
            Group_ {
                Row(first: true) { _ in
                    let line = m.dictatehint ?? (m.dictateHint, m.dictateHotkeyTaken ? "taken" : "")
                    Title(b: "Dictation shortcut", span: line.0, spanColor: line.1.isEmpty ? nil : th.warn)
                    KeyField(m: m)
                }
                if m.globe { Row { _ in Title(b: "Set Press 🌐 key to Do Nothing"); Btn(label: "Open Keyboard Settings") { m.post(["do": "globeKey"]) } } }
                Row(dim: m.str("dictateHotkeyLabel").isEmpty) { _ in Title(b: "Dictated text", span: "Clean up drops fillers, fixes misheard words.")
                    Seg(options: [("verbatim", "Verbatim"), ("cleanup", "Clean up")], value: m.str("dictateMode")) { m.set("dictateMode", $0) } }
                Row(dim: m.str("dictateMode") == "cleanup") { _ in Title(b: "Type as I talk", span: m.str("dictateMode") == "cleanup" ? "Verbatim only: Clean up needs the whole sentence." : "Words go in at each pause.")
                    Switch(on: m.bool("dictateLive")) { m.set("dictateLive", !m.bool("dictateLive")) } }
            }
            H3(s: "Speech").padding(.top, 30)
            Group_ {
                Row(first: true) { _ in Title(b: "Microphone")
                    let opts = [("automatic", "Automatic (recommended)")] + m.mics.map { ($0.id, $0.name) }
                    Select(options: opts, value: opts.contains { $0.0 == m.str("microphone") } ? m.str("microphone") : "automatic") { m.set("microphone", $0) } }
                Row { _ in Title(b: "Speech model", span: "Parakeet is fastest and most accurate. All stay on this Mac.", info: "Speech: free, English (US), on this Mac. Dictation: the model your keyboard’s mic uses. Parakeet: free, fastest, 25 European languages, runs on this Mac’s Neural Engine.")
                    Seg(options: [("speech", "Speech"), ("dictation", "Dictation"), ("parakeet", "Parakeet")], value: m.str("speechModel")) { m.set("speechModel", $0) } }
                if m.str("speechModel") == "parakeet" {
                    Row { _ in Title(b: "Parakeet model", span: "Light is the smallest download.", info: "Multilingual, Most accurate and Light: 25 European languages, detected automatically. Most accurate is a larger download at the same speed. Light is the smallest; it runs on the graphics chip, so it is slower on older Macs. English: English only. Downloaded once, then runs offline.")
                        Select(options: [("v3", "Multilingual · 469 MB"), ("ultra", "Most accurate · 613 MB"), ("redux", "Light · 213 MB"), ("v2", "English · 451 MB")], value: m.str("parakeetModel")) { m.set("parakeetModel", $0) } }
                    ModelStatus(m: m, title: "Parakeet status", parakeet: true)
                }
            }
            H3(s: "Dictionary").padding(.top, 30)
            Group_ {
                AddRow(placeholder: "Add a word or phrase", button: "Add Word", first: true) { m.post(["do": "dictationWord", "word": $0]) }
                ForEach(m.words.indices, id: \.self) { i in WordRow(m: m, word: m.words[i]) }
            }
            T(s: m.words.isEmpty ? "No words yet. Add names, slang or product names." : "Names, slang and product names.", size: 11.5, lh: 1.45, color: th.fg3)
                .padding(EdgeInsets(top: 9, leading: 2, bottom: 0, trailing: 2))
            HStack {
                T(s: "History", weight: 600, em: -0.005)
                Spacer()
                if !m.history.isEmpty { Text("Clear Dictations…").font(cssFont(11.5, 500)).lineHeight(11.5, nil).foregroundColor(th.fg3).onTapGesture { m.showNotice("Clear all saved dictations?", "Clear all") { m.post(["do": "dictationClear"]) } } }
            }.padding(EdgeInsets(top: 30, leading: 2, bottom: 9, trailing: 2))
            PrefsSearch(placeholder: "Search dictations and asks", text: $m.search, height: 32, radius: 8).padding(.bottom, 8)
            History(m: m)
            Group_ {
                Row(first: true) { _ in Title(b: "Save dictation history", span: "Only on this Mac.", info: "Last 500 dictations, up to 30 days. Turning off keeps what’s saved.")
                    Switch(on: m.bool("dictateHistory")) { m.set("dictateHistory", !m.bool("dictateHistory")) } }
            }.padding(.top, 12)
        }
    }
}
private struct Stats: View {
    @ObservedObject var m: SettingsModel
    @Environment(\.prefsTheme) var th
    var body: some View {
        let n = m.stats, mins = (n["minutes"] as? NSNumber)?.doubleValue ?? 0
        let cells: [(String, String, String)] = [("Today", fmt(n["today"]), "words"), ("All time", fmt(n["words"]), "words"),
            ("Time saved", mins < 60 ? fmt(mins) : (mins / 60).formatted(.number.precision(.fractionLength(0...1))), mins < 60 ? "minutes" : "hours"),
            ("Sessions", fmt(n["sessions"]), "dictations")]
        GeometryReader { g in
            let two = g.size.width + 68 + 208 <= 800   // @media (max-width: 800px): the window, not the card
            let cols = two ? 2 : 4
            VStack(spacing: 0) {
                ForEach(0..<(4 / cols), id: \.self) { r in
                    HStack(spacing: 0) {
                        ForEach(0..<cols, id: \.self) { c in
                            let cell = cells[r * cols + c]
                            VStack(alignment: .leading, spacing: 0) {
                                T(s: cell.0.uppercased(), size: 11, weight: 600, em: 0.04, color: th.fg3)
                                T(s: cell.1, size: 24, weight: 600, em: -0.02, tabular: true).lineLimit(1).padding(.top, 6).padding(.bottom, 2)
                                T(s: cell.2, size: 12, color: th.fg2)
                            }
                            .padding(EdgeInsets(top: 14, leading: 16, bottom: 13, trailing: 16)).frame(maxWidth: .infinity, alignment: .leading)
                            .overlay(alignment: .leading) { if c > 0 { Rectangle().fill(th.line).frame(width: 0.5) } }
                            .overlay(alignment: .top) { if r > 0 { Rectangle().fill(th.line).frame(height: 0.5) } }
                        }
                    }
                }
            }
            .background(th.card).clipShape(rr(11)).insetRing(rr(11), th.line).cssShadow(.black(0.04), y: 1, blur: 2)
            .background(GeometryReader { h in Color.clear.preference(key: StatsHeight.self, value: h.size.height) })
        }
        .frame(height: statsHeight).onPreferenceChange(StatsHeight.self) { statsHeight = $0 }
    }
    @State private var statsHeight: CGFloat = 190
    func fmt(_ v: Any?) -> String {
        let d = (v as? NSNumber)?.doubleValue ?? 0
        return d >= 1e5 ? d.formatted(.number.notation(.compactName).precision(.fractionLength(0...1))) : Int(d).formatted()
    }
}
private struct StatsHeight: PreferenceKey { static var defaultValue: CGFloat = 0; static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) } }
private struct KeyField: View {   // .keyfield: the dictation shortcut, recorded like the big one, with a clear button
    @ObservedObject var m: SettingsModel
    @Environment(\.prefsTheme) var th
    @State private var blink = false
    var body: some View {
        let rec = m.recording == "dictate", label = rec ? (m.recKeys?.label ?? "") : m.str("dictateHotkeyLabel")
        let text = rec ? (m.recKeys?.text ?? "") : "Record Shortcut", set = !label.isEmpty && !rec
        let bad = m.dictateHotkeyTaken && !rec
        ZStack(alignment: .trailing) {
            HStack(spacing: 4) {
                if label.isEmpty { T(s: text, size: 12.5, weight: 500, color: rec ? th.fg2 : th.accent).opacity(rec && blink ? 0.45 : 1) }
                else { ForEach(capsOf(label), id: \.self) { Cap(s: $0, size: 11, height: 20, minW: 20, pad: 5, radius: 4) } }
            }
            .padding(.leading, 10).padding(.trailing, set ? 30 : 10).frame(minWidth: 140, minHeight: 28, maxHeight: 28)
            .background(rr(7).fill(th.ctl).cssShadow(.black(0.05), y: 1, blur: 1))
            .overlay(rr(7).strokeBorder(rec ? th.accent : bad ? Color(hex: 0xff9f0a) : th.line, lineWidth: rec || bad ? 1.5 : 0.5))
            .background(rr(7).inset(by: -3).fill(rec ? Color.rgba(10, 132, 255, 0.18) : .clear))
            .contentShape(Rectangle()).onTapGesture { m.toggleRecordDictate() }
            if set { XButton { m.post(["do": "clearDictate"]) }.padding(.trailing, 4) }
        }
        .fixedSize()
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("prefs")) } action: { m.recFields["dictate"] = $0 }
        .onDisappear { m.recFields["dictate"] = nil }
        .onChange(of: rec) { _, r in if r { withAnimation(.easeInOut(duration: 0.7).repeatForever()) { blink = true } } else { blink = false } }
    }
}
private struct XButton: View {   // .x: a 22px round ×
    let tap: () -> Void
    @State private var hover = false
    @Environment(\.prefsTheme) var th
    var body: some View {
        Text("×").font(cssFont(15)).lineHeight(15, nil).foregroundColor(hover ? th.danger : th.fg3).frame(width: 22, height: 22)
            .background(Circle().fill(hover ? th.sel : .clear)).contentShape(Circle()).onHover { hover = $0 }.onTapGesture(perform: tap)
    }
}
private struct ModelStatus: View {   // Parakeet or local model: a dot, a line, and Download / Cancel / Delete
    @ObservedObject var m: SettingsModel
    let title: String; let parakeet: Bool
    @Environment(\.prefsTheme) var th
    var body: some View {
        let s = parakeet ? m.W : m.L, id = parakeet ? (m.str("parakeetModel").isEmpty ? "v3" : m.str("parakeetModel")) : (m.str("localModel").isEmpty ? "gemma4" : m.str("localModel"))
        let model = (s?["models"] as? [[String: Any]])?.first { $0["id"] as? String == id }
        let progress = (model?["progress"] as? NSNumber)?.doubleValue ?? (parakeet ? nil : (s?["runtime"] as? NSNumber)?.doubleValue)
        let dl = progress != nil, have = model?["have"] as? Bool ?? false, server = s?["server"] as? Bool ?? false, error = s?["error"] as? String
        let big = !parakeet && id == "qwen36" && ((s?["ram"] as? NSNumber)?.doubleValue ?? 99) < 32
        let btn = s == nil ? "" : dl ? "cancel" : parakeet ? (!server ? "" : !have ? "download" : "delete") : (!have || !server ? "download" : "delete")
        let text = s == nil ? "Checking…" : dl ? "Downloading \(Int(((progress ?? 0) * 100).rounded()))%…"
            : error ?? (parakeet ? (!server ? "The Parakeet helper is missing. Run ./build.sh again." : !have ? "Model not downloaded." : "Ready. Runs on this Mac.")
                                 : (!have || !server ? "Not downloaded." : big ? "Needs a Mac with 32 GB of memory." : "Ready. Runs on this Mac."))
        let bad = s == nil || dl || error != nil || !server || !have || big
        let prefix = parakeet ? "parakeet" : "local", size = model?["size"] as? String
        Row { _ in
            VStack(alignment: .leading, spacing: 0) {
                T(s: title, weight: 500)
                HStack(spacing: 8) { Dot(bad: bad); T(s: text, size: 11.5, lh: 1.35, color: th.fg3) }.padding(.top, 2)
            }.frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) {
                if btn == "download" { Btn(label: size.map { "Download \($0)" } ?? "Download", kind: "blue") { m.post(["do": prefix + "Download", "id": id]) } }
                if btn == "cancel" { Btn(label: "Cancel") { m.post(["do": prefix + "Cancel", "id": id]) } }
                if btn == "delete" { Btn(label: "Delete", kind: "red") { m.post(["do": prefix + "Delete", "id": id]) } }
            }
        }
    }
}
private struct WordRow: View {
    @ObservedObject var m: SettingsModel
    let word: String
    @State private var text = ""
    var body: some View {
        Row(hoverBG: true) { hovered in
            Field(placeholder: "", text: $text) { m.post(["do": "dictationWord", "old": word, "word": text]) }
            if text != word { RowX(icon: RowIcon.check, shown: true, save: true) { m.post(["do": "dictationWord", "old": word, "word": text]) } }
            RowX(icon: RowIcon.trash, shown: hovered) { m.post(["do": "dictationWordDelete", "word": word]) }.padding(.leading, text != word ? -10 : 0)
        }
        .onAppear { text = word }
    }
}
private struct PrefsSearch: View {
    let placeholder: String; @Binding var text: String; var height: CGFloat = 28; var radius: CGFloat = 7
    @Environment(\.prefsTheme) var th
    @FocusState private var focused: Bool
    var body: some View {
        TextField("", text: $text, prompt: Text(placeholder).foregroundColor(th.fg3)).textFieldStyle(.plain).font(cssFont(13)).foregroundColor(th.fg).focused($focused)
            .padding(.horizontal, height == 32 ? 12 : 10).frame(height: height)
            .background(rr(radius).fill(th.ctl).insetRing(rr(radius), th.line).cssShadow(.black(height == 32 ? 0.04 : 0.05), y: 1, blur: 1))
            .background(rr(radius).inset(by: -3).fill(focused ? Color.rgba(10, 132, 255, 0.35) : .clear))
    }
}
private let askDate: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime, .withDashSeparatorInDate]; f.timeZone = .current; return f }()
private struct History: View {
    @ObservedObject var m: SettingsModel
    @Environment(\.prefsTheme) var th
    var body: some View {
        let q = m.search.lowercased()
        let said: [[String: Any]] = m.asks.map { a in
            let at = (a["at"] as? String ?? "").replacingOccurrences(of: " ", with: "T")
            return ["ask": true, "timestamp": askDate.date(from: at)?.timeIntervalSince1970 ?? 0, "text": a["task"] ?? "", "reply": a["reply"] ?? ""]
        }
        let rows = (m.history + said).filter { r in "\(r["text"] ?? "") \((r["raw"] as? String) ?? (r["reply"] as? String) ?? "") \(r["app"] ?? "")".lowercased().contains(q) || q.isEmpty }
            .sorted { ((($0["timestamp"] as? NSNumber)?.doubleValue ?? ($0["timestamp"] as? Double) ?? 0)) > ((($1["timestamp"] as? NSNumber)?.doubleValue ?? ($1["timestamp"] as? Double) ?? 0)) }
        ScrollView(.vertical) {
            VStack(spacing: 0) {
                ForEach(rows.indices, id: \.self) { i in HistRow(m: m, item: rows[i], first: i == 0) }
                if rows.isEmpty { T(s: q.isEmpty ? "Your dictations and asks will appear here." : "Nothing matches.", color: th.fg3).padding(14).frame(maxWidth: .infinity, alignment: .leading) }
            }
        }
        .frame(maxHeight: 440).fixedSize(horizontal: false, vertical: rows.count < 6)
        .background(th.card).clipShape(rr(11)).insetRing(rr(11), th.line).cssShadow(.black(0.04), y: 1, blur: 2)
    }
}
private let histDate: DateFormatter = { let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("MMMd jmm"); return f }()   // "Oct 19, 9:30 AM", as toLocaleString gave
private struct HistRow: View {
    @ObservedObject var m: SettingsModel
    let item: [String: Any]; let first: Bool
    @State private var hover = false
    @State private var copied = false
    @Environment(\.prefsTheme) var th
    var body: some View {
        let ask = item["ask"] as? Bool ?? false, ts = (item["timestamp"] as? NSNumber)?.doubleValue ?? (item["timestamp"] as? Double) ?? 0
        let meta = "\(histDate.string(from: Date(timeIntervalSince1970: ts))) · \(ask ? "Ask" : (item["app"] as? String ?? ""))"
        ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: 0) {
                T(s: meta, size: 11, color: th.fg3, tabular: true).padding(.bottom, 3)
                T(s: item["text"] as? String ?? "", lh: 1.45)
                if let raw = item["raw"] as? String, !raw.isEmpty { RawDetails(raw: raw) }
                if ask, let reply = item["reply"] as? String, !reply.isEmpty { T(s: reply, size: 12, color: th.fg2).lineLimit(3).padding(.top, 4) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 0) {
                RowX(icon: copied ? RowIcon.check : RowIcon.copy, shown: hover, copy: true) {
                    m.post(["do": "copy", "text": (ask ? item["reply"] : item["text"]) ?? ""]); copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                }
                if !ask { RowX(icon: RowIcon.trash, shown: hover) { m.post(["do": "dictationDelete", "id": item["id"] ?? ""]) } }
            }
            .background(hover ? th.hover : th.card).padding(.top, -4).padding(.trailing, -4)
        }
        .padding(EdgeInsets(top: 10, leading: 14, bottom: 11, trailing: 14))
        .background(hover ? th.hover : .clear)
        .overlay(alignment: .top) { if !first { Rectangle().fill(th.line).frame(height: 0.5) } }
        .onHover { hover = $0 }
    }
}
private struct RawDetails: View {
    let raw: String
    @State private var open = false
    @Environment(\.prefsTheme) var th
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) { Text("▸").rotationEffect(.degrees(open ? 90 : 0)); Text("Raw transcript") }.font(cssFont(11.5)).lineHeight(11.5, nil).foregroundColor(th.fg3).onTapGesture { open.toggle() }
            if open { T(s: raw, size: 11.5, color: th.fg2) }
        }.padding(.top, 6)
    }
}

private struct BrainSection: View {
    @ObservedObject var m: SettingsModel
    var body: some View {
        let local = m.local
        VStack(alignment: .leading, spacing: 0) {
            H1(s: "Intelligence", icon: navItems[2])
            Lede(s: local ? "Aurel thinks with a model that runs on this Mac. Nothing leaves it." : "Aurel thinks with Claude, on your Claude plan.")
            H3(s: "Model").padding(.top, 8)
            Group_ {
                Row(first: true) { _ in Title(b: "AI client", span: local ? "Free, private, works offline." : "No API key needed.")
                    Seg(options: [("local", "Local"), ("claude", "Claude")], value: m.str("client")) { m.set("client", $0) } }
                if local {
                    Row { _ in Title(b: "Local model", span: "Gemma is fast on any Mac.", info: "Gemma 4 E4B: fast, good at commands, fits 16 GB Macs. Qwen 3.6 35B: much stronger at long tasks, needs 32 GB or more. Downloaded once, then runs offline.")
                        Select(options: [("gemma4", "Gemma 4 E4B · 5.2 GB"), ("qwen36", "Qwen 3.6 35B · 22.1 GB")], value: m.str("localModel")) { m.set("localModel", $0) } }
                    ModelStatus(m: m, title: "Local model status", parakeet: false)
                    Row { _ in Title(b: "Bigger asks", span: m.str("bigAsks") == "claude" ? "Aurel sends only big asks to Claude. Needs Claude Code." : "Everything stays on this Mac.")
                        Seg(options: [("local", "Local"), ("claude", "Claude")], value: m.str("bigAsks")) { m.set("bigAsks", $0) } }
                    Row { _ in Title(b: "Use Claude to see pictures", span: "The local model can't see. Asks with a picture, like what you point at, go to Claude. Needs Claude Code.")
                        Switch(on: m.bool("claudeSees")) { m.set("claudeSees", !m.bool("claudeSees")) } }
                } else {
                    Row { _ in Title(b: "Intelligence", span: ["cheapest": "Haiku for everything. Fastest.", "balanced": "Haiku for quick asks, work model for real work.", "capable": "Work model for everything. Slower."][m.routing] ?? "")
                        Seg(options: [("cheapest", "Cheapest"), ("balanced", "Balanced"), ("capable", "Most capable")], value: m.routing) { m.set("routing", $0) } }
                    if m.routing != "cheapest" {
                        Row { _ in Title(b: "Work model", span: "Opus is stronger, uses more of your plan.")
                            Seg(options: [("sonnet", "Sonnet"), ("opus", "Opus")], value: m.str("model") == "haiku" ? (m.str("agentModel") == "opus" ? "opus" : "sonnet") : m.str("model")) { m.set("model", $0) } }
                    }
                }
            }
            if !local {
                H3(s: "Background agents").padding(.top, 30)
                Group_ { Row(first: true) { _ in Title(b: "Use my Claude Code tools", span: "MCP servers, skills and plugins."); Switch(on: m.bool("agentUserTools")) { m.set("agentUserTools", !m.bool("agentUserTools")) } } }
            }
        }
    }
}

private struct MemorySection: View {
    @ObservedObject var m: SettingsModel
    @Environment(\.prefsTheme) var th
    var body: some View {
        let counts = m.sourceCounts, imported = (counts["contacts"] ?? 0) + (counts["mail"] ?? 0)
        VStack(alignment: .leading, spacing: 0) {
            H1(s: "Memory", icon: navItems[3])
            HStack(spacing: 12) {
                T(s: "About you", weight: 600, em: -0.005)
                Spacer()
                Btn(label: imported > 0 ? "Refresh" : "Import from your Mac", kind: "blue", disabled: m.profileBusy) {
                    m.profileBusy = true; m.profileStatus = "Importing from Contacts and Mail…"; m.profileStatusFix = nil; m.post(["do": "profileImport"])
                }
            }.padding(EdgeInsets(top: 30 - 4, leading: 2, bottom: 9, trailing: 2))
            Lede(s: "Only your name and answer style go with every ask.", size: 11.5, bottom: 9).padding(.horizontal, 2)
            Group_ { ForEach(profileCategories.indices, id: \.self) { i in ProfileCategory(m: m, cat: profileCategories[i], first: i == 0) } }
            let sources = ["you", "contacts", "mail", "learned"].filter { (counts[$0] ?? 0) > 0 }
            if !sources.isEmpty {
                WrapRow(spacing: 8) { ForEach(sources, id: \.self) { s in Btn(label: "Forget everything from \(s) · \(counts[s] ?? 0)", kind: "red") { m.post(["do": "me", "action": "forget-source", "source": s]) } } }
                    .padding(EdgeInsets(top: 10, leading: 4, bottom: 0, trailing: 4))
            }
            if !m.profileStatus.isEmpty || m.profileStatusFix != nil {
                VStack(alignment: .leading, spacing: 0) {
                    T(s: m.profileStatus, size: 11.5, lh: 1.4, color: th.fg3)
                    if let fix = m.profileStatusFix { Btn(label: fix) { m.post(["do": "automation"]) }.padding(.top, 6) }
                }.padding(.top, 6)
            }
            H3(s: "Learning").padding(.top, 30)
            Group_ {
                Row(first: true) { _ in Title(b: "Save chats", span: "Plain conversations, in Agents on this Mac.", info: "Answers that changed nothing. They never go with your asks."); Switch(on: m.bool("saveChats")) { m.set("saveChats", !m.bool("saveChats")) } }
                Row { _ in Title(b: "Learn about me", span: "Keeps lasting facts you say.", info: "Never from screen text, health, money or passwords."); Switch(on: m.bool("learnMe")) { m.set("learnMe", !m.bool("learnMe")) } }
            }
            H3(s: "Rules").padding(.top, 30)
            Group_ {
                if m.rules.isEmpty { T(s: "No rules yet.", color: th.fg3).padding(14).frame(maxWidth: .infinity, alignment: .leading) }
                ForEach(m.rules.indices, id: \.self) { i in
                    if !m.hiddenRows.contains("rule-\(i)") { RuleRow(m: m, index: i, first: i == 0).id("rule-\(i)") }
                }
                AddRow(placeholder: "When I say focus mode, close Slack and open Notes", button: "Add") { v in
                    let t = v.trimmingCharacters(in: .whitespaces); if !t.isEmpty { m.post(["do": "remember", "line": t]) }
                }
            }.id("rules")
            Lede(s: "Say “remember…” or add one here.", size: 11.5, bottom: 0).padding(EdgeInsets(top: 9, leading: 2, bottom: 0, trailing: 2))
            H3(s: "Saved commands and procedures").padding(.top, 30)
            if m.skills.isEmpty { T(s: "None yet. What works lands here.", size: 12, color: th.fg3).padding(EdgeInsets(top: 2, leading: 2, bottom: 0, trailing: 2)) }
            else {
                Group_ {
                    ForEach(m.skills.indices, id: \.self) { i in
                        let k = m.skills[i], key = "skill-\(i)"
                        if !m.hiddenRows.contains(key) {
                            Row(first: i == 0, hoverBG: true) { hovered in
                                HStack(spacing: 10) {
                                    Title(b: "“\(k["say"] as? String ?? "")”", span: k["reply"] as? String ?? "")
                                    RowX(icon: RowIcon.trash, shown: hovered) { m.undoable(["do": "unlearn", "say": k["say"] ?? ""], key: key, "Command forgotten.") }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
private struct RuleRow: View {
    @ObservedObject var m: SettingsModel
    let index: Int; let first: Bool
    @State private var text = ""
    @State private var sent: String?
    var body: some View {
        let old = m.rules[index]
        Row(first: first, hoverBG: true) { hovered in
            HStack(spacing: 10) {
                Field(placeholder: "", text: $text, blur: { save(old) }) { save(old) }
                RowX(icon: RowIcon.trash, shown: hovered) { m.undoable(["do": "forget", "line": old], key: "rule-\(index)", "Rule forgotten.") }
            }
        }
        .flash(m.flash == "rule-\(index)")
        .onAppear { text = old }.onChange(of: old) { _, v in text = v; sent = nil }
    }
    func save(_ old: String) {   // once per change: Return, then leaving the field, saves it once
        let v = text.trimmingCharacters(in: .whitespaces)
        guard v != old, v != sent else { return }
        sent = v; m.post(v.isEmpty ? ["do": "forget", "line": old] : ["do": "rule", "old": old, "text": v])
    }
}
private struct ProfileCategory: View {
    @ObservedObject var m: SettingsModel
    let cat: (String, String, String); let first: Bool
    @Environment(\.prefsTheme) var th
    var body: some View {
        let open = m.openProfile.contains(cat.0)
        let rows = m.facts.filter { $0["category"] as? String == cat.0 }
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("›").font(cssFont(18)).lineHeight(18, nil).foregroundColor(th.fg3).rotationEffect(.degrees(open ? 90 : 0)).animation(eased(0.15), value: open)
                T(s: cat.1, weight: 500).frame(maxWidth: .infinity, alignment: .leading)
                T(s: "\(rows.count)", size: 11.5, color: th.fg3, tabular: true)
            }
            .padding(.horizontal, 14).frame(minHeight: 44).contentShape(Rectangle())
            .onTapGesture { if open { m.openProfile.remove(cat.0) } else { m.openProfile.insert(cat.0) } }
            .flash(m.flash == "cat-\(cat.0)").id("cat-\(cat.0)")
            if open {
                ForEach(rows.indices, id: \.self) { i in
                    let f = rows[i], id = f["id"] as? String ?? ""
                    if !m.hiddenRows.contains("fact-\(id)") { FactRow(m: m, fact: f).id("fact-\(id)") }
                }
                AddRow(placeholder: cat.2, button: "Add", leading: 24) { v in
                    let t = v.trimmingCharacters(in: .whitespaces); if !t.isEmpty { m.post(["do": "me", "action": "add", "category": cat.0, "text": t]) }
                }
            }
        }
        .overlay(alignment: .top) { if !first { Rectangle().fill(th.line).frame(height: 0.5) } }
    }
}
private struct FactRow: View {
    @ObservedObject var m: SettingsModel
    let fact: [String: Any]
    @State private var text = ""
    @State private var saved = ""
    @Environment(\.prefsTheme) var th
    var body: some View {
        let id = fact["id"] as? String ?? ""
        Row(hoverBG: true, padding: EdgeInsets(top: 8, leading: 38, bottom: 8, trailing: 14)) { hovered in
            HStack(spacing: 8) {
                Field(placeholder: "", text: $text, blur: { save(id) }) { save(id) }
                Text("\(fact["source"] as? String ?? "") · \(fact["date"] as? String ?? "")").font(cssFont(10.5)).lineHeight(10.5, nil).foregroundColor(th.fg2).lineLimit(1)
                    .padding(.vertical, 2).padding(.horizontal, 7).background(rr(9).fill(th.sel)).fixedSize()
                RowX(icon: RowIcon.trash, shown: hovered) { m.undoable(["do": "me", "action": "drop", "id": id], key: "fact-\(id)", "Detail deleted.") }
            }
        }
        .flash(m.flash == "fact-\(id)")
        .onAppear { text = "\(fact["kind"] ?? ""): \(fact["value"] ?? "")"; saved = text }
    }
    func save(_ id: String) {   // once per change, on Return or on leaving the field
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, t != saved else { return }
        saved = t; m.post(["do": "me", "action": "set", "id": id, "text": t])
    }
}
private extension View {   // .flash: the item glows once, then settles (2.2s, after .35s)
    func flash(_ on: Bool) -> some View { modifier(Flash(on: on)) }
}
private struct Flash: ViewModifier {
    let on: Bool
    @State private var lit = false
    @Environment(\.prefsTheme) var th
    func body(content: Content) -> some View {
        content.background(lit ? Color.rgba(10, 132, 255, 0.2) : .clear).overlay(alignment: .leading) { if lit { Rectangle().fill(th.accent).frame(width: 2) } }
            .onChange(of: on) { _, v in
                guard v else { return }
                lit = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35 + 2.2 * 0.35) { withAnimation(css(0.4, 0, 0.2, 1, 2.2 * 0.65)) { lit = false } }
            }
    }
}
struct WrapRow: Layout {   // flex-wrap: wrap with a gap
    var spacing: CGFloat
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let w = proposal.width ?? .infinity; var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, maxX: CGFloat = 0
        for s in subviews { let z = s.sizeThatFits(.unspecified); if x > 0 && x + z.width > w { y += line + spacing; x = 0; line = 0 }; x += z.width + spacing; maxX = max(maxX, x - spacing); line = max(line, z.height) }
        return CGSize(width: min(w, maxX), height: y + line)
    }
    func placeSubviews(in b: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = b.minX, y = b.minY, line: CGFloat = 0
        for s in subviews { let z = s.sizeThatFits(.unspecified); if x > b.minX && x + z.width > b.maxX { y += line + spacing; x = b.minX; line = 0 }; s.place(at: CGPoint(x: x, y: y), proposal: .unspecified); x += z.width + spacing; line = max(line, z.height) }
    }
}

private struct AppsSection: View {
    @ObservedObject var m: SettingsModel
    @Environment(\.prefsTheme) var th
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Btn(label: "← Privacy & Safety") { m.openSection("account") }.padding(.bottom, 18)   // a step back, apart from the page's own title
            H1(s: "Apps", icon: NavItem(id: "apps", title: "Apps", color: 0xff453a, icon: SectionIcon.apps))
            Lede(s: "Tick the apps Aurel can control. Allow them now so it won’t stop to ask.")
            HStack(spacing: 8) {
                Seg(options: [("key", "Key Apps"), ("all", "All Apps")], value: m.appView) { m.appView = $0 }
                PrefsSearch(placeholder: "Search all apps", text: $m.appQuery)
                Btn(label: m.asking > 0 ? "Stop · \(m.total - m.asking + 1) of \(m.total)" : m.allowCount > 0 ? "Allow \(m.allowCount) App\(m.allowCount > 1 ? "s" : "")" : "Allow",
                    kind: m.asking > 0 ? "stop" : "blue", height: 28, disabled: m.asking == 0 && m.allowCount == 0) { m.allowTapped() }
            }
            .padding(.vertical, 8).background(th.bg).padding(.bottom, 4)
            let shown = m.shownApps, q = !m.appQuery.trimmingCharacters(in: .whitespaces).isEmpty
            if shown.isEmpty { Group_ { T(s: m.apps.isEmpty ? "Finding your apps…" : "No app matches.", color: th.fg3).padding(14).frame(maxWidth: .infinity, alignment: .leading) } }
            else {
                HStack {
                    T(s: q ? "Matches" : m.appView == "key" ? "Key apps" : "All apps · \(m.apps.count)", weight: 600, em: -0.005)
                    Spacer()
                    if !q && m.appView == "key" && shown.contains(where: { $0["status"] as? String == "new" }) {
                        Text("Select all").font(cssFont(11.5, 500)).lineHeight(11.5, nil).foregroundColor(th.accent).onTapGesture {
                            for a in shown where a["status"] as? String == "new" { m.pick?.insert(a["id"] as? String ?? "") }
                        }
                    }
                }.padding(EdgeInsets(top: 26, leading: 2, bottom: 9, trailing: 2))
                Group_ { ForEach(shown.indices, id: \.self) { i in AppRow(m: m, app: shown[i], first: i == 0) } }
            }
            HStack(spacing: 0) {
                Text("Click OK on each macOS box. To take access away: System Settings → Privacy & Security → Automation. ").foregroundColor(th.fg3)
                + Text("Open it").foregroundColor(th.accent)
            }
            .font(cssFont(11.5)).lineHeight(11.5, 1.45).fixedSize(horizontal: false, vertical: true)
            .padding(EdgeInsets(top: 9, leading: 2, bottom: 0, trailing: 2)).onTapGesture { m.post(["do": "automation"]) }
        }
    }
}
private struct AppRow: View {
    @ObservedObject var m: SettingsModel
    let app: [String: Any]; let first: Bool
    @State private var hover = false
    @Environment(\.prefsTheme) var th
    var body: some View {
        let id = app["id"] as? String ?? "", status = app["status"] as? String ?? "new", ticked = m.pick?.contains(id) ?? false
        Row(first: first, minHeight: 46) { _ in
            Group { if let i = imageFromDataURL(app["icon"] as? String) { Image(nsImage: i).resizable() } else { Color.clear } }.frame(width: 30, height: 30)
            Title(b: app["name"] as? String ?? "", weight: 400)
            switch status {
            case "allowed": Pill(s: "Allowed", kind: "ok")
            case "blocked": Pill(s: "Blocked · Fix", kind: "no").help("macOS won’t ask again. Turn it on in System Settings.").onTapGesture { m.post(["do": "automation"]) }
            case "asking": Pill(s: "Asking…", kind: "wait")
            default: Check(on: ticked)
            }
        }
        .background(hover ? th.sel : .clear).onHover { hover = $0 }
        .contentShape(Rectangle()).onTapGesture { if status == "new" { if ticked { m.pick?.remove(id) } else { m.pick?.insert(id) } } }
    }
}
private struct Check: View {   // .ck
    let on: Bool
    @Environment(\.prefsTheme) var th
    var body: some View {
        ZStack {
            Circle().fill(on ? th.accent : .clear)
            if on { Icon(paths: ["M5.5 10.5l3 3 6-7"], box: 20, stroke: 2.2, color: .white) } else { Circle().strokeBorder(th.track, lineWidth: 1.5) }
        }.frame(width: 20, height: 20).animation(Ease.ease(0.15), value: on)
    }
}

private struct AccountSection: View {
    @ObservedObject var m: SettingsModel
    @Environment(\.prefsTheme) var th
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            H1(s: "Privacy & Safety", icon: navItems[4])
            Lede(s: "What Aurel needs to work.")
            Group_ {
                Row(first: true) { _ in
                    VStack(alignment: .leading, spacing: 0) {
                        T(s: m.local ? "Local model" : "Claude", weight: 500)
                        HStack(spacing: 8) { Dot(bad: !(m.plan?.ok ?? true)); T(s: m.plan?.text ?? "Checking…", size: 11.5, lh: 1.35, color: th.fg3) }.padding(.top, 2)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    if m.plan?.ok == false { Btn(label: "Set Up") { m.post(["do": "setup"]) } }
                }
            }
            H3(s: "Safety").padding(.top, 30)
            Group_ { Row(first: true) { _ in Title(b: "Safe mode", span: "Risky actions need approval. Background agents use a scratch folder."); Switch(on: m.bool("safe")) { m.set("safe", !m.bool("safe")) } } }
            H3(s: "Privacy").padding(.top, 30)
            Group_ {
                Row(first: true) { _ in Title(b: "Look at my screen", span: "Only when you mean it, like “this”.", info: "The picture goes with that one ask.")
                    Seg(options: [("auto", "Automatic"), ("never", "Never")], value: m.str("screen")) { m.set("screen", $0) } }
                Row { _ in Title(b: "Hide from screen sharing", span: m.sharingUnavailable ? "On this macOS version, Aurel windows can appear in screen sharing." : nil)
                    Switch(on: m.bool("hideWhenSharing")) { m.set("hideWhenSharing", !m.bool("hideWhenSharing")) } }
            }
            H3(s: "Permissions").padding(.top, 30)
            Group_ {
                PermRow(m: m, id: "mic", title: "Microphone", span: "To hear you.", first: true)
                PermRow(m: m, id: "speech", title: "Speech Recognition", span: "On this Mac.")
                PermRow(m: m, id: "ax", title: "Accessibility", span: "To click and move windows.")
                PermRow(m: m, id: "screen", title: "Screen Recording", span: "When you say “this”.")
                Row { _ in Title(b: "Apps"); Btn(label: "Choose") { m.openSection("apps") } }
            }
            H3(s: "Agents").padding(.top, 30)
            Group_ {
                Row(first: true) { _ in Title(b: "Set up agents", span: "Asked only when a task needs them."); Btn(label: "Enable All", kind: "blue") { m.post(["do": "enableAll", "connected": String(m.connected)]) } }
                PermRow(m: m, id: "chrome", title: "Page reading in Chrome", span: "Aurel turns this on itself.", okLabel: "On", button: "Turn On")
                PermRow(m: m, id: "auto", title: "Automation", span: "Lets agents script your apps.")
                PermRow(m: m, id: "calendar", title: "Calendar", span: "When you ask.")
                Row { _ in Title(b: "Claude connectors", span: m.connText); Btn(label: "Connect in Claude") { m.post(["do": "connectors"]) } }
            }
        }
    }
}
private struct PermRow: View {
    @ObservedObject var m: SettingsModel
    let id, title, span: String; var first = false; var okLabel = "Allowed"; var button = "Allow"
    var body: some View {
        Row(first: first, now: m.walking == id) { _ in
            Title(b: title, span: span)
            if m.perms[id] ?? false { Pill(s: okLabel, kind: "ok") } else { Btn(label: button) { m.post(["do": "grant", "id": id]) }.opacity(m.walking == id ? 0.5 : 1).allowsHitTesting(m.walking != id) }
        }
    }
}

private struct AboutSection: View {
    @ObservedObject var m: SettingsModel
    @Environment(\.prefsTheme) var th
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 0) {
                Group { if let i = m.icon { Image(nsImage: i).resizable() } else { Color.clear } }.frame(width: 96, height: 96).padding(.bottom, 8)
                T(s: "Aurel", size: 24, weight: 700, lh: 1.15, em: -0.02)
                T(s: m.version, color: th.fg2).padding(.top, 4)
            }.frame(maxWidth: .infinity).padding(.top, 10).padding(.bottom, 6)
            H3(s: "Updates").padding(.top, 30)
            Group_ {
                if !m.managedUpdates { Row(first: true) { _ in Title(b: "Update automatically", span: "Restarts when you’re not using it."); Switch(on: m.bool("autoUpdate")) { m.set("autoUpdate", !m.bool("autoUpdate")) } } }
                Row(first: m.managedUpdates) { _ in Title(b: m.managedUpdates ? "Updates are managed by Nix" : "Check for updates", span: m.update)
                    if !m.managedUpdates { Btn(label: "Check Now") { m.post(["do": "checkUpdate"]) } } }
            }
        }
    }
}

private struct Notice: View {   // #notice
    @ObservedObject var m: SettingsModel
    @Environment(\.prefsTheme) var th
    var body: some View {
        if let n = m.notice {
            HStack(spacing: 12) {
                Text(n.text).font(cssFont(12.5)).lineHeight(12.5, nil).foregroundColor(th.fg)
                if let a = n.action { Btn(label: a) { n.run?(); m.showNotice("") } }
            }
            .padding(EdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 8))
            .background(rr(11).fill(th.pop).insetRing(rr(11), th.line).cssShadow(.black(0.18), y: 6, blur: 20))
            .frame(maxWidth: 420).padding(.bottom, 16)
            .transition(.opacity.combined(with: .offset(y: 6)))
        }
    }
}

// MARK: - Hosting, for SettingsWindow and the screenshot harness

final class SettingsSurface: NativeSurface {
    let model = SettingsModel()
    let host: NSHostingView<SettingsView>
    var view: NSView { host }
    init(frame: NSRect) {
        host = NSHostingView(rootView: SettingsView(m: model)); host.frame = frame; host.autoresizingMask = [.width, .height]
        model.post = { print("post", $0) }
    }
    func receive(_ call: String, _ value: Any) {
        switch call {
        case "_top": model.scroll?("top")
        case "_end": model.scroll?("bottom")
        case "_open": let i = (value as? Int) ?? 0; model.openProfile.insert(profileCategories[i].0)
        default: model.receive(call, value)
        }
    }
    func freeze(at ms: Double?) {}
}
