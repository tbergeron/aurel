// The first-run window's content. Onboarding (Aurel.swift) owns the window, talks to OnboardingModel with calls (set, prefs,
// keys, …) and gets {do: …} messages back.
import AppKit
import SwiftUI

// MARK: - Tokens

struct SetupTheme {
    let dark: Bool
    var fg: Color { dark ? Color(hex: 0xf5f5f7) : Color(hex: 0x1d1d1f) }
    var fg2: Color { dark ? Color(hex: 0xa1a1a6) : Color(hex: 0x6e6e73) }
    var fg3: Color { dark ? Color(hex: 0x98989d) : Color(hex: 0x6e6e73) }
    var card: Color { dark ? .white(0.06) : .white(0.62) }
    var line: Color { dark ? .white(0.08) : .black(0.08) }
    var keyTop: Color { dark ? Color(hex: 0x3a3a3c) : Color(hex: 0xfdfdfd) }
    var keyBot: Color { dark ? Color(hex: 0x2c2c2e) : Color(hex: 0xe8e8ed) }
    var keyEdge: Color { dark ? .black(0.55) : .black(0.16) }
    let accent = Color(hex: 0x0a84ff), green = Color(hex: 0x28c840)
    var glow: Color { dark ? .rgba(110, 130, 255, 0.22) : .rgba(120, 140, 255, 0.28) }
    var sheet: Color { dark ? Color(hex: 0x2a2a2c) : Color(hex: 0xfbfbfd) }
    var field: Color { dark ? .white(0.07) : Color(hex: 0xffffff) }
    var track: Color { .rgba(120, 120, 128, dark ? 0.32 : 0.18) }
    var on: Color { dark ? Color(hex: 0x636366) : Color(hex: 0xffffff) }
    var warn: Color { dark ? Color(hex: 0xff9f0a) : Color(hex: 0xc93400) }
}
private struct SetupThemeKey: EnvironmentKey { static let defaultValue = SetupTheme(dark: false) }
extension EnvironmentValues { var setupTheme: SetupTheme { get { self[SetupThemeKey.self] } set { self[SetupThemeKey.self] = newValue } } }
func spring(_ s: Double, delay: Double = 0) -> Animation? { css(0.34, 1.56, 0.64, 1, s, delay: delay) }   // --spring

let setupPages = ["welcome", "perms", "agents", "try", "mac", "text", "dictate", "point", "work", "done"]

// Rows: id, name, why, icon colour, glyph (viewBox 24).
struct SetupRow { let id, name, why: String; let color: UInt32; let icon: [String] }
private let gear = [circle(12, 12, 3), "M12 2.5v3M12 18.5v3M2.5 12h3M18.5 12h3M5.3 5.3l2.1 2.1M16.6 16.6l2.1 2.1M5.3 18.7l2.1-2.1M16.6 7.4l2.1-2.1"]
private let micGlyph = [rect(9, 3, 6, 11, 3), "M5.5 11a6.5 6.5 0 0 0 13 0M12 17.5V21"]
private let axGlyph = [circle(12, 4.5, 1.6), "M5 8.5l7 1.5 7-1.5M12 10v4.5M12 14.5l-3 6M12 14.5l3 6"]
private let screenGlyph = [rect(3, 4.5, 18, 12, 2), "M8.5 20h7M12 16.5V20"]
private let chromeGlyph = [circle(12, 12, 9), circle(12, 12, 3.5), "M12 8.5h8.2M9 13.7L4.9 6.6M15 13.7l-4.1 7.1"]
let permRows = [
    SetupRow(id: "claude", name: "AI Provider", why: "Checking…", color: 0xd97757, icon: SectionIcon.brain),
    SetupRow(id: "mic", name: "Microphone", why: "Listens when you start a voice request.", color: 0xff9f0a, icon: micGlyph),
    SetupRow(id: "speech", name: "Speech Recognition", why: "Turns your words into text, on this Mac.", color: 0x8e8e93, icon: ["M4 10v4M8 7v10M12 4v16M16 8v8M20 11v2"]),
    SetupRow(id: "ax", name: "Accessibility", why: "Moves windows and clicks buttons for you.", color: 0x0a84ff, icon: axGlyph),
    SetupRow(id: "screen", name: "Screen Recording", why: "Looks at your screen when you say “this”.", color: 0xbf5af2, icon: screenGlyph),
    SetupRow(id: "chrome", name: "Chrome Pages", why: "Reads and clicks web pages in Chrome, in the background.", color: 0x34c759, icon: chromeGlyph),
    SetupRow(id: "auto", name: "Automation", why: "Pick the apps Aurel can control, all at once.", color: 0x636366, icon: gear),
]
let ownRows = [
    SetupRow(id: "tools", name: "Your Claude Code tools", why: "MCP servers, skills and plugins you already use.", color: 0xd97757, icon: ["M14.5 5.5l4 4-9 9H5.5v-4z", "M12.5 7.5l4 4"]),
    SetupRow(id: "chrome", name: "Page reading in Chrome", why: "Reads and clicks pages in the background.", color: 0x34c759, icon: chromeGlyph),
]
let yourRows = [
    SetupRow(id: "ax", name: "Accessibility", why: "Clicks and types in apps for an agent.", color: 0x0a84ff, icon: axGlyph),
    SetupRow(id: "screen", name: "Screen Recording", why: "Shows an agent’s window live on its chip.", color: 0xbf5af2, icon: screenGlyph),
    SetupRow(id: "auto", name: "Automation", why: "Lets an agent script your apps.", color: 0x636366, icon: gear),
    SetupRow(id: "calendar", name: "Calendar", why: "Reads and updates events when you ask.", color: 0xff453a, icon: [rect(4, 5, 16, 15, 2.5), "M4 10h16M8.5 3v4M15.5 3v4"]),
    SetupRow(id: "connectors", name: "Claude connectors", why: "Checking your Claude account…", color: 0x5e5ce6, icon: ["M9 15l6-6M10.5 6.5l1-1a4 4 0 0 1 5.7 5.7l-1 1M13.5 17.5l-1 1a4 4 0 0 1-5.7-5.7l1-1"]),
]

// MARK: - Model: what the page kept (prefs, last, provider, planOK…)

final class OnboardingModel: ObservableObject {
    var post: ([String: String]) -> Void = { _ in }
    @Published var cur = ""
    @Published var leaving = ""
    @Published var prefs: [String: Any] = [:]
    @Published var perms: [String: Bool] = [:]
    @Published var provider = "local"
    @Published var planOK = false
    @Published var planText = "Checking…"
    @Published var planNeed = ""
    var want: String? = nil
    @Published var toggleMode = false
    @Published var held = ""
    @Published var tried = false
    @Published var walking: String? = nil
    @Published var connected = false
    @Published var connText = "Checking your Claude account…"
    @Published var recording = false
    @Published var recLabel: (label: String, text: String)? = nil
    @Published var dcWarn: String? = nil
    @Published var waiting: [String: Date] = [:]
    @Published var sheet = false
    @Published var pick = "local"
    @Published var reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    var warnTimer: Timer?

    func pstr(_ k: String) -> String { prefs[k] as? String ?? "" }
    func pbool(_ k: String) -> Bool { prefs[k] as? Bool ?? false }
    func skip(_ id: String) -> Bool { provider == "local" && ["agents", "work"].contains(id) }   // background agents need Claude Code
    var status: [String: Bool] { var s = perms; s["claude"] = planOK; return s }

    func go(_ to: String) {
        var id = to
        while skip(id), let i = setupPages.firstIndex(of: id), i + 1 < setupPages.count { id = setupPages[i + 1] }
        if recording { post(["do": "cancelRecord"]) }
        if id == "agents" && provider != "local" { post(["do": "connectors"]) }
        leaving = cur
        withAnimation(nil) { cur = id }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { if self.leaving != self.cur { self.leaving = "" } }
    }
    func back() {
        guard var i = setupPages.firstIndex(of: cur) else { return }
        i -= 1; while i > 0 && skip(setupPages[i]) { i -= 1 }
        go(setupPages[max(0, i)])
    }

    // ob.* — Aurel.swift calls these by name, as it did the page's.
    func receive(_ call: String, _ v: Any) {
        let arg = (v as? [Any]).flatMap { $0.count == 1 ? $0[0] : nil } ?? v
        switch call {
        // keys come 20×/s and the rest 1×/s, mostly unchanged: only a change is published.
        case "mode": let t = arg as? Bool ?? false; if t != toggleMode { toggleMode = t }
        case "keys": let h = arg as? String ?? ""; if cur == "try" && !tried && h != held { held = h }
        case "tried": if cur == "try" && !tried { tried = true; held = "" }
        case "plan":
            let c = arg as? [String: Any] ?? [:]
            if let w = want, c["client"] as? String != w { return }
            want = nil; planOK = c["ok"] as? Bool ?? false; provider = c["client"] as? String ?? "local"
            planText = c["text"] as? String ?? ""; planNeed = c["need"] as? String ?? ""
        case "walk": walking = (arg as? String).flatMap { $0.isEmpty ? nil : $0 }
        case "motion": reduce = arg as? Bool ?? false
        case "connectors":
            let c = arg as? [String: Any] ?? [:], conn = c["connected"] as? [String] ?? [], s = (c["signin"] as? [Any] ?? []).count
            connected = !conn.isEmpty
            connText = !conn.isEmpty ? conn.prefix(2).joined(separator: ", ") + (conn.count > 2 ? " and \(conn.count - 2) more" : "") + " connected" + (s > 0 ? " · \(s) need sign-in" : "")
                : s > 0 ? "\(s) need sign-in in Claude" : "Gmail, Drive and more, from your Claude account."
        case "prefs": if (arg as? NSDictionary) != (prefs as NSDictionary) { prefs = arg as? [String: Any] ?? [:] }
        case "set": let p = (arg as? [String: Any] ?? [:]).mapValues { ($0 as? Bool) ?? (($0 as? NSNumber)?.boolValue ?? false) }; if p != perms { perms = p }
        case "rec": if recording { let m = arg as? String ?? ""; recLabel = m.hasPrefix("Add") || m.isEmpty ? ("", m.isEmpty ? "Type Shortcut" : m) : (m, "") }
        case "taken":
            let a = v as? [Any] ?? [], own = a.count > 1 ? (a[1] as? Bool ?? false) : false
            dcWarn = own ? "That’s already your Aurel shortcut. Kept your old one." : "Another app already uses that shortcut. Kept your old one."
            warnTimer?.invalidate(); warnTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { [weak self] _ in self?.dcWarn = nil }
        case "recorded": recording = false; recLabel = nil; prefs["dictateHotkeyLabel"] = arg as? String ?? ""
        default: break
        }
    }

    func grant(_ id: String) {
        waiting[id] = Date()
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { if let d = self.waiting[id], Date().timeIntervalSince(d) >= 11.9 { self.waiting[id] = nil } }   // gave up in System Settings
        post(["do": "grant", "id": id])
    }
    func set(_ k: String, _ v: String) { prefs[k] = v; post(["do": "set", "k": k, "v": v]) }
    func useProvider() {
        post(["do": "provider", "client": pick == "local" ? "local" : "claude"])
        want = pick; provider = pick; planOK = false; planText = "Checking…"; planNeed = ""
        sheet = false
    }
    var recField: CGRect = .null   // the dictation shortcut field: a click anywhere else cancels its recording
    func clicked(_ p: CGPoint) { if recording && !recField.contains(p) { post(["do": "cancelRecord"]) } }
    func toggleRecord() {
        if recording { return post(["do": "cancelRecord"]) }
        recording = true; recLabel = ("", "Type Shortcut"); post(["do": "recordDictate"])
    }
}

// MARK: - Pieces

private struct ST: View {   // text with the page's metrics
    let s: String; var size: CGFloat = 13; var weight = 400; var lh: CGFloat? = nil; var em: CGFloat = 0; var color: Color? = nil; var italic = false
    @Environment(\.setupTheme) var th
    var body: some View {
        Text(s).font(cssFont(size, weight)).italic(italic).tracking(em * size).foregroundColor(color ?? th.fg).lineHeight(size, lh)
            .fixedSize(horizontal: false, vertical: true)
    }
}
private struct Rise: ViewModifier {   // .r: children rise in one after another when their page comes on
    let on: Bool; let index: Int
    func body(content: Content) -> some View {
        content.opacity(on ? 1 : 0).offset(y: on ? 0 : 12)
            .animation(on ? css(0.4, 0, 0.2, 1, 0.5, delay: Double(index) * 0.07) : nil, value: on)
    }
}
private extension View { func rise(_ on: Bool, _ i: Int) -> some View { modifier(Rise(on: on, index: i)) } }

private struct PillButton: View {   // .btn and .btn.quiet
    let label: String; var quiet = false; var plain = false; var height: CGFloat = 36; var pad: CGFloat = 22; var size: CGFloat = 14; var disabled = false; let tap: () -> Void
    @State private var hover = false
    @State private var down = false
    @Environment(\.setupTheme) var th
    var body: some View {
        Text(label).font(cssFont(size, 500)).foregroundColor(plain ? th.fg2 : quiet ? th.fg : .white)
            .padding(.horizontal, pad).frame(height: height)
            .background(Capsule().fill(plain ? .clear : quiet ? th.card : th.accent))
            .overlay { if plain { } else if quiet { Capsule().strokeBorder(th.line, lineWidth: 0.5) } else { Capsule().strokeBorder(Color.white(0.25), lineWidth: 0.5).mask(VStack { Rectangle().frame(height: 1); Spacer() }) } }
            .cssShadow(quiet ? .clear : .black(0.15), y: 1, blur: 2)
            .brightness(hover && !quiet ? 0.08 : 0).scaleEffect(down ? 0.97 : 1).animation(css(0.4, 0, 0.2, 1, 0.12), value: down)
            .opacity(disabled ? 0.45 : 1).fixedSize().contentShape(Capsule())
            .onHover { hover = $0 }
            .gesture(DragGesture(minimumDistance: 0).onChanged { _ in down = true }.onEnded { _ in down = false; if !disabled { tap() } })
            .pressable(label, disabled: disabled, tap)
    }
}
private struct IconTile: View {   // .ic
    let color: UInt32; let icon: [String]
    var body: some View {
        ZStack { rr(7).fill(Color(hex: color)); Icon(paths: icon, stroke: 1.8, color: .white).frame(width: 17, height: 17) }
            .frame(width: 30, height: 30)
            .overlay(rr(7).strokeBorder(Color.white(0.3), lineWidth: 0.5).mask(VStack { Rectangle().frame(height: 1); Spacer() }))
            .shadow(color: .black(0.2), radius: 0.5, y: 0.5)
    }
}
private struct CheckMark: View {   // .check: the circle pops in, then the tick draws itself
    var size: CGFloat = 22; var delay: Double = 0
    @State private var shown = false
    @Environment(\.setupTheme) var th
    var body: some View {
        ZStack {
            Circle().fill(th.green).scaleEffect(shown ? 1 : 0.3).opacity(shown ? 1 : 0).animation(spring(0.45, delay: delay), value: shown)
            SVGPath(d: "M6.5 11.3l3 3 6-6.3", box: 22).trim(from: 0, to: shown ? 1 : 0)
                .stroke(Color.white, style: StrokeStyle(lineWidth: 2.2 * size / 22, lineCap: .round, lineJoin: .round))
                .animation(css(0.4, 0, 0.2, 1, 0.35, delay: delay + 0.15), value: shown)
        }
        .frame(width: size, height: size).onAppear { shown = true }
    }
}
private struct Spinner: View {
    @State private var turn = false
    var body: some View {
        Circle().trim(from: 0, to: 0.75).stroke(lineWidth: 1.5).frame(width: 10, height: 10).rotationEffect(.degrees(turn ? 360 : 0))
            .onAppear { withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) { turn = true } }
    }
}
private struct PermRowView: View {   // .row in the lists: icon, what and why, Allow (or a check)
    @ObservedObject var m: OnboardingModel
    let row: SetupRow; let index: Int; let shown: Bool; var label = "Allow"; var name: String? = nil; var why: String? = nil; var alt: (() -> Void)? = nil
    var first: Bool { index == 0 }
    @State private var hover = false
    @Environment(\.setupTheme) var th
    var body: some View {
        let ok = m.status[row.id] ?? (row.id == "connectors" ? m.connected : false)
        let now = m.walking == row.id, wait = m.waiting[row.id] != nil
        HStack(spacing: 12) {
            IconTile(color: row.color, icon: row.icon)
            VStack(alignment: .leading, spacing: 0) {
                ST(s: name ?? row.name, weight: 500)
                ST(s: why ?? row.why, size: 12, color: th.fg3).padding(.top, 1)
                if let alt { Text("Change provider").font(cssFont(11.5, 500)).foregroundColor(th.accent).underline(hover).padding(.top, 3).onHover { hover = $0 }.onTapGesture(perform: alt) }
            }.frame(maxWidth: .infinity, alignment: .leading)
            if ok { CheckMark().padding(.horizontal, 21) }
            else {
                HStack(spacing: 6) { Text(wait || now ? "Waiting" : label); if wait || now { Spinner() } }
                    .font(cssFont(12, 500)).foregroundColor(wait || now ? th.fg3 : th.accent)
                    .padding(.horizontal, 12).frame(minWidth: 64, minHeight: 26, maxHeight: 26)
                    .background(Capsule().fill(wait || now ? .clear : Color.rgba(10, 132, 255, 0.12)))
                    .contentShape(Capsule()).onTapGesture { if !(wait || now) { m.grant(row.id) } }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
        .background(now ? Color.rgba(10, 132, 255, 0.08) : .clear)
        .overlay(alignment: .top) { if !first { Rectangle().fill(th.line).frame(height: 0.5) } }
        .opacity(shown ? 1 : 0).offset(y: shown ? 0 : 8)
        .animation(shown ? css(0.4, 0, 0.2, 1, 0.45, delay: 0.25 + Double(index) * 0.06) : nil, value: shown)
    }
}
private struct ListCard<Content: View>: View {   // #list, .list
    var maxWidth: CGFloat = 480
    @ViewBuilder var content: Content
    @Environment(\.setupTheme) var th
    var body: some View {
        VStack(spacing: 0) { content }.frame(maxWidth: maxWidth).background(th.card).clipShape(rr(12))
            .overlay(rr(12).strokeBorder(th.line, lineWidth: 0.5)).cssShadow(.black(0.04), y: 1, blur: 3)
    }
}
private struct Keycap: View {   // .key
    let s: String; var big = false; var down = false; var lit = false; var yes = false
    @Environment(\.setupTheme) var th
    var body: some View {
        let wide = s.count > 3
        let h: CGFloat = big ? 52 : 40, minW: CGFloat = wide ? (big ? 160 : 120) : (big ? 52 : 40), size: CGFloat = wide ? (big ? 15 : 13) : (big ? 19 : 15)
        let fill: [Color] = yes ? [Color(hex: 0x4fd86a), th.green] : lit ? [Color(hex: 0x3d9bff), th.accent] : [th.keyTop, th.keyBot]
        Text(s).font(cssFont(size, 500)).foregroundColor(yes || lit ? .white : down ? th.fg : th.fg2)
            .padding(.horizontal, 12).frame(minWidth: minW).frame(height: h)
            .background(rr(big ? 11 : 9).fill(LinearGradient(colors: fill, startPoint: .top, endPoint: .bottom)))
            .background(rr(big ? 11 : 9).fill(th.keyEdge).offset(y: down || lit ? 0 : 2))
            .overlay(rr(big ? 11 : 9).stroke(yes || lit ? Color.black(0.3) : th.keyEdge, lineWidth: 0.5))
            .shadow(color: yes ? Color.rgba(40, 200, 64, 0.4) : lit ? Color.rgba(10, 132, 255, 0.45) : .black(down ? 0.1 : 0.08), radius: yes || lit ? 12 : down ? 1.5 : 5, y: yes || lit ? 0 : down ? 1 : 4)
            .offset(y: down || lit ? 2 : 0)
            .animation(css(0.4, 0, 0.2, 1, yes ? 0.35 : 0.14), value: down || lit || yes)
    }
}
private struct Glow: View {   // the soft glow behind the orb, drifting
    let inset: CGFloat
    @State private var drift = false
    @Environment(\.setupTheme) var th
    var body: some View {
        GeometryReader { g in Circle().fill(RadialGradient(colors: [th.glow, th.glow.opacity(0)], center: .center, startRadius: 0, endRadius: g.size.width / 2)) }   // closest-side
            .scaleEffect(drift ? 1.06 : 1).offset(x: drift ? 6 : 0, y: drift ? -4 : 0)
            .padding(-inset)
            .onAppear { if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { withAnimation(.easeInOut(duration: 3.5).repeatForever()) { drift = true } } }
    }
}
struct OrbRep: NSViewRepresentable {   // the thinking orb, breathing
    var state = "breathing"; var size = 64; var dpr = 4; var running = true; var capped = false; var boost = 1.0
    func makeNSView(context: Context) -> OrbView { OrbView(state: state, size: size, dpr: dpr, capped: capped) }
    func updateNSView(_ v: OrbView, context: Context) { v.state = state; v.running = running; v.boost = boost }
}

// MARK: - The window's content

struct OnboardingView: View {
    @ObservedObject var m: OnboardingModel
    @Environment(\.colorScheme) var scheme
    var body: some View {
        let th = SetupTheme(dark: scheme == .dark)
        ZStack {
            ZStack {
                ForEach(setupPages, id: \.self) { id in
                    PageView(m: m, id: id)
                }
            }.blur(radius: m.sheet ? 4 : 0).animation(eased(0.25), value: m.sheet)   // backdrop-filter: blur(8px) under the sheet
            VStack {
                HStack {
                    if (setupPages.firstIndex(of: m.cur) ?? 0) >= 1 { PillButton(label: "Back", quiet: true, plain: true, height: 30, pad: 10) { m.back() } }
                    Spacer()
                    if (setupPages.firstIndex(of: m.cur) ?? 0) < setupPages.firstIndex(of: "done")! { PillButton(label: "Skip All", quiet: true, plain: true, height: 30, pad: 10) { m.go("done") } }
                }.padding(.horizontal, 22).padding(.top, 18)
                Spacer()
                Dots(m: m).padding(.bottom, 24)
            }
            if m.sheet { ProviderSheet(m: m).transition(.opacity) }
        }
        .environment(\.setupTheme, th)
        .coordinateSpace(.named("setup"))
        .simultaneousGesture(SpatialTapGesture(coordinateSpace: .named("setup")).onEnded { m.clicked($0.location) })
        .ignoresSafeArea()
    }
}
private struct Dots: View {
    @ObservedObject var m: OnboardingModel
    @Environment(\.setupTheme) var th
    var body: some View {
        HStack(spacing: 6) {
            ForEach(setupPages.filter { !m.skip($0) }, id: \.self) { p in
                Capsule().fill(th.fg3).frame(width: p == m.cur ? 18 : 6, height: 6).opacity(p == m.cur ? 0.8 : 0.35)
                    .animation(out(0.45), value: m.cur)
            }
        }
    }
}

private struct PageView: View {   // .page: slides and un-blurs in from the right, leaves to the left
    @ObservedObject var m: OnboardingModel
    let id: String
    @State private var on = false
    @State private var gone = false
    @State private var tall: CGFloat = 0
    var body: some View {
        let active = m.cur == id
        // A page taller than the window (more rows, the Globe key hint) shrinks to fit, keeping its last button above the page dots.
        let fit = tall > 0 ? min(1, (612 - 56) / (tall - 24)) : 1
        ScrollView(.vertical) {
            VStack(spacing: 0) { content(active: on) }
                .padding(id == "done" ? EdgeInsets(top: 22, leading: 32, bottom: 18, trailing: 32) : EdgeInsets(top: id == "perms" ? 24 : 40, leading: 56, bottom: 40, trailing: 56))
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { tall = $0 }
                .scaleEffect(fit, anchor: .top)
                .frame(maxWidth: .infinity).frame(minHeight: 612 - 56)
        }
        .scrollIndicators(.never).scrollDisabled(true)
        .frame(height: 612 - 56).frame(maxHeight: .infinity, alignment: .top)
        .opacity(on ? 1 : 0).offset(x: on ? 0 : gone ? -40 : 40).blur(radius: on ? 0 : 3)
        .allowsHitTesting(active)
        .onChange(of: m.cur) { _, c in
            if c == id { gone = false; withAnimation(out(0.6)) { on = true } }
            else if on { withAnimation(css(0.16, 1, 0.3, 1, 0.35)) { on = false; gone = true }; DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { gone = false } }
        }
        .onAppear { if active { withAnimation(out(0.6)) { on = true } } }
    }
    @ViewBuilder func content(active: Bool) -> some View {
        switch id {
        case "welcome": Welcome(m: m, on: active)
        case "perms": Perms(m: m, on: active)
        case "agents": Agents(m: m, on: active)
        case "try": Try(m: m, on: active)
        case "mac": Feature(m: m, on: active, kicker: "Your whole Mac, by voice", title: "Say it. It’s done.", sub: "Run apps, arrange windows and play music in the background. When the work is out of sight, a live mini screen shows it; click it to open that window.", next: "text") { MacStage(run: active, reduce: m.reduce) } extra: {
            Says(items: ["“Open Spotify and play lo-fi”", "“Make Chrome full screen”", "“Volume to 30%”", "“Turn on dark mode”"])
            if m.prefs["safe"] as? Bool != false { Note(s: "Safe mode is on: deleting, sending or buying asks you first.") }
        }
        case "text": Feature(m: m, on: active, kicker: "Any text, any app", title: "Select it. Say what to do.", sub: "Rewrite, reply, translate or delete. You see it first, then click Replace.", next: "dictate") { TextStage(run: active, reduce: m.reduce) } extra: {
            Pad()
            Note(s: "Your turn: select this line, hold the keys, say “make this polite”.")
        }
        case "dictate": DictatePage(m: m, on: active)
        case "point": Feature(m: m, on: active, kicker: "Draw on screen", title: "It shows you, right on screen", sub: "Ask how to do something and Aurel marks each spot, one step at a time. Ask it to explain something and draw it, and the drawing builds up like a whiteboard.", next: "work") { PointStage(run: active, reduce: m.reduce) } extra: {
            MtRow(color: 0xff375f, icon: [circle(12, 12, 8), circle(12, 12, 3)], title: "Draw on screen to show you", hint: "Then ask “how do I…?” or “explain this and draw it”. Esc clears it.") {
                SetupSwitch(on: m.pbool("draw")) { m.prefs["draw"] = !m.pbool("draw"); m.post(["do": "set", "k": "draw", "v": String(m.pbool("draw"))]) }
            }
        }
        case "work": WorkPage(m: m, on: active)
        default: Done(m: m, on: active)
        }
    }
}

private struct Welcome: View {
    @ObservedObject var m: OnboardingModel
    let on: Bool
    @State private var down = false
    @Environment(\.setupTheme) var th
    var body: some View {
        VStack(spacing: 0) {
            ZStack { Glow(inset: 60); OrbRep(running: on && !m.reduce).frame(width: 128, height: 128) }.frame(width: 128, height: 128).rise(on, 0)
            ST(s: "Meet Aurel", size: 34, weight: 600, lh: 1.1, em: -0.025).padding(.top, 18).padding(.bottom, 10).rise(on, 1)
            Sub(s: (m.toggleMode ? "Press the shortcut, speak, press again to send." : "Hold the shortcut, speak, release to send.") + " Your Mac does the rest.").rise(on, 2)
            HStack(spacing: 8) {
                let caps = capsOf(m.pstr("hotkeyLabel").isEmpty ? "⌃⌥Space" : m.pstr("hotkeyLabel"))
                ForEach(caps.indices, id: \.self) { i in Keycap(s: caps[i], down: down).animation(css(0.4, 0, 0.2, 1, 0.14, delay: Double(i) * 0.13), value: down) }
            }.padding(.top, 26).rise(on, 3)
            PillButton(label: "Get Started") { m.go("perms") }.padding(.top, 30).rise(on, 4)
        }
        .task(id: "\(on)-\(m.reduce)") {   // the keys press in, hold, let go: the gesture itself
            guard on, !m.reduce else { down = false; return }
            try? await Task.sleep(for: .seconds(1.2))
            while !Task.isCancelled {
                down = true; try? await Task.sleep(for: .seconds(2.1)); down = false; try? await Task.sleep(for: .seconds(1.5))
            }
        }
    }
}
private struct Sub: View {   // p.sub
    let s: String; var maxWidth: CGFloat = 400
    @Environment(\.setupTheme) var th
    var body: some View { Balanced { ST(s: s, size: 14, lh: 1.5, color: th.fg2).multilineTextAlignment(.center) }.frame(maxWidth: maxWidth) }
}
struct Balanced: Layout {   // text-wrap: balance — the narrowest width that keeps the same number of lines
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let v = subviews.first else { return .zero }
        let maxW = proposal.width ?? 10_000, full = v.sizeThatFits(ProposedViewSize(width: maxW, height: nil))
        var lo = maxW / 2, hi = maxW
        for _ in 0..<12 { let mid = (lo + hi) / 2; if v.sizeThatFits(ProposedViewSize(width: mid, height: nil)).height > full.height + 0.5 { lo = mid } else { hi = mid } }
        return v.sizeThatFits(ProposedViewSize(width: hi, height: nil))
    }
    func placeSubviews(in b: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: CGPoint(x: b.midX, y: b.midY), anchor: .center, proposal: ProposedViewSize(width: b.width, height: b.height))
    }
}
private struct H2: View {
    let s: String
    var body: some View { ST(s: s, size: 24, weight: 600, lh: 1.15, em: -0.02).multilineTextAlignment(.center).padding(.bottom, 8) }
}
private struct Note: View {   // .done-note
    let s: String
    @Environment(\.setupTheme) var th
    var body: some View { ST(s: s, size: 12.5, color: th.fg3).frame(minHeight: 18).padding(.top, 12) }
}

private struct Perms: View {
    @ObservedObject var m: OnboardingModel
    let on: Bool
    @Environment(\.setupTheme) var th
    var body: some View {
        let s = m.status, n = permRows.filter { s[$0.id] ?? false }.count, all = n == permRows.count
        VStack(spacing: 0) {
            H2(s: "Give Aurel a hand").rise(on, 0)
            Sub(s: "macOS asks once for each one. You can change them any time in System Settings.").rise(on, 1)
            ListCard {
                ForEach(permRows.indices, id: \.self) { i in
                    let r = permRows[i]
                    if r.id == "claude" {
                        PermRowView(m: m, row: r, index: i, shown: on, label: ["install": "Install", "login": "Sign In", "upgrade": "Upgrade", "download": "Download"][m.planNeed] ?? "Allow",
                                    name: m.provider == "claude" ? "Claude Plan" : "Local Model", why: m.planText) { m.pick = m.provider; withAnimation(eased(0.25)) { m.sheet = true } }
                    } else { PermRowView(m: m, row: r, index: i, shown: on) }
                }
            }.padding(.top, 22).rise(on, 2)
            ST(s: all ? "All set" : "\(n) of \(permRows.count) allowed", size: 12, color: all ? th.green : th.fg3).monospacedDigit().padding(.top, 12).rise(on, 3)
            PillButton(label: all ? "Continue" : "Skip for Now", quiet: !all) { m.go("agents") }.padding(.top, 16).rise(on, 4)
        }
    }
}

private struct Agents: View {
    @ObservedObject var m: OnboardingModel
    let on: Bool
    @Environment(\.setupTheme) var th
    var body: some View {
        let s = m.status
        let left = (ownRows + yourRows).filter { $0.id == "connectors" ? !m.connected : !(s[$0.id] ?? false) }.count
        VStack(spacing: 0) {
            H2(s: "Agents keep working while you do").rise(on, 0)
            Sub(s: "Hand off a bigger task and keep asking. An agent uses these only when a task needs them.", maxWidth: 430).rise(on, 1)
            Cap(s: "Aurel turns these on").padding(.top, 18).rise(on, 2)
            ListCard { ForEach(ownRows.indices, id: \.self) { i in PermRowView(m: m, row: ownRows[i], index: i, shown: on, label: "Turn On", why: walkWhy(ownRows[i], own: true)) } }.padding(.top, 20 - 14).rise(on, 3)
            Cap(s: "Only you can allow these. macOS and Claude ask you directly.").padding(.top, 14).rise(on, 4)
            ListCard {
                ForEach(yourRows.indices, id: \.self) { i in
                    let r = yourRows[i]
                    PermRowView(m: m, row: r, index: i, shown: on, label: r.id == "connectors" ? "Connect" : "Allow", why: r.id == "connectors" ? m.connText : walkWhy(r, own: false))
                }
            }.padding(.top, 22 - 14).rise(on, 5)
            HStack(spacing: 10) {
                PillButton(label: left > 0 ? "Skip for Now" : "Continue", quiet: left > 0) { m.go("try") }
                if left > 0 { PillButton(label: m.walking != nil ? "Enabling…" : "Enable All", disabled: m.walking != nil) { m.post(["do": "enableAll", "connected": String(m.connected)]) } }
            }.padding(.top, 26).rise(on, 6)
        }
    }
    func walkWhy(_ r: SetupRow, own: Bool) -> String { m.walking == r.id ? (own ? "Turning it on…" : "Turn on Aurel in System Settings.") : r.why }
}
private struct Cap: View {   // .cap: a small heading over a list
    let s: String
    @Environment(\.setupTheme) var th
    var body: some View { ST(s: s, size: 11, weight: 600, color: th.fg3).frame(maxWidth: 480, alignment: .leading) }
}

private struct Try: View {
    @ObservedObject var m: OnboardingModel
    let on: Bool
    @Environment(\.setupTheme) var th
    @State private var yes: Set<Int> = []
    var body: some View {
        let caps = capsOf(m.pstr("hotkeyLabel").isEmpty ? "⌃⌥Space" : m.pstr("hotkeyLabel"))
        VStack(spacing: 0) {
            H2(s: "Try it now").rise(on, 0)
            Sub(s: (m.toggleMode ? "Press the shortcut anywhere. Say what you need, then press again to send." : "Hold the keys anywhere, say what you need, then let go.") + " Try one now.").rise(on, 1)
            HStack(spacing: 10) {
                ForEach(caps.indices, id: \.self) { i in
                    let c = caps[i], mod = c == "fn" || "⌃⌥⇧⌘".contains(c)
                    Keycap(s: c, big: true, lit: !yes.contains(i) && mod && m.held.contains(c), yes: yes.contains(i))
                }
            }.padding(.top, 30).rise(on, 2)
            ST(s: m.tried ? "That’s it. Aurel is on it." : (m.toggleMode ? "Press the shortcut" : "Hold the keys") + " and say “open Calculator”.", color: m.tried ? th.green : th.fg3)
                .frame(height: 18).padding(.top, 22).rise(on, 3)
            HStack(spacing: 10) {
                if m.tried { PillButton(label: "Next") { m.go("mac") } } else { PillButton(label: "Skip", quiet: true) { m.go("mac") } }
            }.padding(.top, 26).rise(on, 4)
        }
        .onChange(of: m.tried) { _, t in   // keys go green one after another
            guard t else { return }
            for i in caps.indices { DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.07) { yes.insert(i) } }
        }
    }
}

private struct Feature<Stage: View, Extra: View>: View {   // a feature page: kicker, title, a looping preview, then one thing to try
    @ObservedObject var m: OnboardingModel
    let on: Bool; let kicker, title, sub, next: String
    @ViewBuilder var stage: Stage
    @ViewBuilder var extra: Extra
    var body: some View {
        VStack(spacing: 0) {
            Kicker(s: kicker).rise(on, 0)
            H2(s: title).rise(on, 1)
            Sub(s: sub).rise(on, 2)
            StageBox(height: 178) { stage }.padding(.top, 22).rise(on, 3)
            VStack(spacing: 0) { extra }.rise(on, 4)
            HStack(spacing: 10) { PillButton(label: "Skip", quiet: true) { m.go(next) }; PillButton(label: "Next") { m.go(next) } }.padding(.top, 26).rise(on, 5)
        }
    }
}
private struct Kicker: View {
    let s: String
    @Environment(\.setupTheme) var th
    var body: some View { ST(s: s.uppercased(), size: 11, weight: 600, em: 0.08, color: th.accent).padding(.bottom, 8) }
}
private struct StageBox<Content: View>: View {   // .stage
    var height: CGFloat
    @ViewBuilder var content: Content
    @Environment(\.setupTheme) var th
    var body: some View {
        ZStack(alignment: .topLeading) { content }
            .frame(width: 420, height: height, alignment: .topLeading)
            .background(LinearGradient(stops: [.init(color: .rgba(120, 140, 255, 0.14), location: 0), .init(color: .rgba(191, 90, 242, 0.08), location: 0.6), .init(color: .clear, location: 1)],
                                       startPoint: UnitPoint(x: 0.33, y: 0), endPoint: UnitPoint(x: 0.67, y: 1)))
            .background(th.card).clipShape(rr(16))
            .overlay(rr(16).strokeBorder(th.line, lineWidth: 0.5)).cssShadow(.black(0.12), y: 10, blur: 30)
    }
}
private struct Fake<Content: View>: View {   // .fake: a dark Aurel box inside a preview
    var shown = true
    @ViewBuilder var content: Content
    var body: some View {
        content.font(cssFont(12)).foregroundColor(Color(hex: 0xf5f5f7)).lineSpacing(12 * 0.4 - (naturalLineHeight(12) - 12))
            .background(rr(10).fill(Color.rgba(28, 28, 30, 0.92)))
            .overlay(rr(10).strokeBorder(Color.white(0.12), lineWidth: 0.5)).cssShadow(.black(0.3), y: 8, blur: 24)
            .opacity(shown ? 1 : 0).offset(y: shown ? 0 : 8).scaleEffect(shown ? 1 : 0.97)
            .animation(out(0.55), value: shown)
    }
}
private struct Says: View {   // .says: example phrases
    let items: [String]
    @Environment(\.setupTheme) var th
    var body: some View {
        WrapRow(spacing: 6) { ForEach(items, id: \.self) { s in Chip(s: s) } }.frame(maxWidth: 440).padding(.top, 14)
    }
}
private struct Chip: View {
    let s: String; var pressed = false; var tap: (() -> Void)? = nil
    @State private var hover = false
    @Environment(\.setupTheme) var th
    var body: some View {
        Text(s).font(cssFont(12)).foregroundColor(pressed ? th.accent : th.fg2).padding(.vertical, 5).padding(.horizontal, 11)
            .background(Capsule().fill(pressed ? Color.rgba(10, 132, 255, 0.12) : hover && tap != nil ? Color.rgba(127, 127, 127, 0.12) : th.card))
            .overlay(Capsule().strokeBorder(pressed ? .clear : th.line, lineWidth: 0.5))
            .onHover { hover = $0 }.onTapGesture { tap?() }
    }
}
private struct Pad: View {   // #pad: the practice line
    @State private var text = "hey can u send me the notes from today, thx"
    @FocusState private var focused: Bool
    @Environment(\.setupTheme) var th
    var body: some View {
        TextField("", text: $text).textFieldStyle(.plain).font(cssFont(13)).foregroundColor(th.fg).focused($focused)
            .padding(.horizontal, 14).frame(width: 420, height: 44)
            .background(rr(10).fill(th.card)).overlay(rr(10).strokeBorder(focused ? th.accent : th.line, lineWidth: focused ? 1 : 0.5))
            .background(rr(10).inset(by: -3).fill(focused ? Color.rgba(10, 132, 255, 0.18) : .clear))
            .padding(.top, 14)
    }
}
private struct MtRow<Trailing: View>: View {   // .mt-row: one setting under a preview
    let color: UInt32; let icon: [String]; let title: String; let hint: String; var warn = false
    @ViewBuilder var trailing: Trailing
    @Environment(\.setupTheme) var th
    var body: some View {
        HStack(spacing: 12) {
            IconTile(color: color, icon: icon)
            VStack(alignment: .leading, spacing: 0) { ST(s: title, weight: 500); ST(s: hint, size: 12, color: warn ? th.warn : th.fg3).padding(.top, 1) }.frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .padding(.horizontal, 14).padding(.vertical, 10).frame(width: 420)
        .background(rr(12).fill(th.card)).overlay(rr(12).strokeBorder(th.line, lineWidth: 0.5)).padding(.top, 14)
    }
}
private struct SetupSwitch: View {
    let on: Bool; let toggle: () -> Void
    @Environment(\.setupTheme) var th
    var body: some View {
        ZStack(alignment: .leading) {
            rr(11).fill(on ? th.green : Color.rgba(127, 127, 127, 0.3)).animation(css(0.4, 0, 0.2, 1, 0.25), value: on)
            Circle().fill(Color.white).frame(width: 18, height: 18).cssShadow(.black(0.25), y: 1, blur: 3).offset(x: on ? 18 : 2).animation(spring(0.3), value: on)
        }.frame(width: 38, height: 22).contentShape(Rectangle()).onTapGesture(perform: toggle)
        .accessibilityElement().accessibilityAddTraits(.isToggle).accessibilityValue(on ? "On" : "Off").accessibilityAction(.default, toggle)
    }
}
private struct SetupSeg: View {
    let options: [(String, String)]; let value: String; var disabled = false; let pick: (String) -> Void
    @Environment(\.setupTheme) var th
    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.0) { o in
                Text(o.1).font(cssFont(12)).foregroundColor(th.fg).padding(.vertical, 4).padding(.horizontal, 10)
                    .background { if o.0 == value { rr(6).fill(th.on).overlay(rr(6).strokeBorder(th.line, lineWidth: 0.5)).cssShadow(.black(0.15), y: 1, blur: 3) } }
                    .contentShape(Rectangle()).onTapGesture { pick(o.0) }
                    .accessibilityElement().accessibilityLabel(o.1).accessibilityAddTraits(o.0 == value ? [.isButton, .isSelected] : .isButton).accessibilityAction(.default) { pick(o.0) }
            }
        }.padding(2).background(rr(8).fill(th.track)).fixedSize().opacity(disabled ? 0.45 : 1).allowsHitTesting(!disabled)
    }
}

// MARK: Previews: short scripted loops, run only while their page shows (the last frame under Reduce Motion)

private func pause(_ s: Double) async -> Bool { try? await Task.sleep(for: .seconds(s)); return !Task.isCancelled }

private struct MacStage: View {   // two windows snap side by side, then music starts
    let run: Bool; let reduce: Bool
    @State private var snapped = false
    @State private var box = false
    @State private var play = false
    @State private var q = "“Chrome left, Notes right”"
    @Environment(\.setupTheme) var th
    var body: some View {
        ZStack(alignment: .topLeading) {
            MiniWindow(title: "Chrome", lines: [1, 0.6, 0.75]).frame(width: snapped ? 193 : 200, height: snapped ? 150 : 110).offset(x: snapped ? 14 : 40, y: snapped ? 14 : 16)
            MiniWindow(title: "Notes", lines: [0.5, 1]).frame(width: snapped ? 193 : 170, height: snapped ? 150 : 110).offset(x: snapped ? 213 : 170, y: snapped ? 14 : 40)
            Fake(shown: play) {
                HStack(spacing: 8) {
                    rr(5).fill(LinearGradient(colors: [Color(hex: 0x1ed760), Color(hex: 0x0a84ff)], startPoint: .topLeading, endPoint: .bottomTrailing)).frame(width: 26, height: 26)
                    VStack(alignment: .leading, spacing: 0) { Text("Lo-fi beats"); Text("Spotify").font(cssFont(10)).foregroundColor(Color(hex: 0x8e8e93)) }
                    EQ()
                }.padding(EdgeInsets(top: 7, leading: 7, bottom: 7, trailing: 10))
            }.frame(maxWidth: .infinity, alignment: .trailing).padding(.trailing, 22).offset(y: 22)
            Fake(shown: box) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(q).font(cssFont(11)).foregroundColor(Color(hex: 0x8e8e93))
                    HStack(spacing: 8) { Text("Spotify · Live").foregroundColor(Color(hex: 0x8e8e93)); Text("Lo-fi beats").fontWeight(.medium).frame(maxWidth: .infinity, alignment: .leading); EQ() }
                        .font(cssFont(10)).padding(9).background(rr(8).fill(Color.white(0.055))).overlay(rr(8).strokeBorder(Color.white(0.08), lineWidth: 0.5)).padding(.vertical, 7)
                    Text("Done.")
                }.padding(EdgeInsets(top: 8, leading: 11, bottom: 8, trailing: 11)).frame(width: 250, alignment: .leading)
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom).padding(.bottom, 14)
        }
        .animation(out(0.6), value: snapped)
        .task(id: "\(run)-\(reduce)") {
            if reduce { snapped = true; play = true; box = true; return }
            while run && !Task.isCancelled {
                snapped = false; box = false; play = false; q = "“Chrome left, Notes right”"
                guard await pause(0.6) else { return }; box = true
                guard await pause(0.7) else { return }; snapped = true
                guard await pause(1.5) else { return }; box = false
                guard await pause(0.4) else { return }; q = "“Play lo-fi on Spotify”"; box = true
                guard await pause(0.7) else { return }; play = true
                guard await pause(2.6) else { return }
            }
        }
    }
}
private struct MiniWindow: View {   // .mw
    let title: String; let lines: [CGFloat]
    @Environment(\.setupTheme) var th
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) { ForEach(0..<3, id: \.self) { _ in Circle().fill(Color.rgba(127, 127, 127, 0.4)).frame(width: 6, height: 6) }; Text(title).font(cssFont(9.5, 500)).foregroundColor(th.fg3).padding(.leading, 6) }
                .padding(.leading, 7).frame(maxWidth: .infinity, minHeight: 16, maxHeight: 16, alignment: .leading)
                .overlay(alignment: .bottom) { Rectangle().fill(th.line).frame(height: 0.5) }
            GeometryReader { g in
                VStack(alignment: .leading, spacing: 8) { ForEach(lines.indices, id: \.self) { i in Capsule().fill(Color.rgba(127, 127, 127, 0.18)).frame(width: (g.size.width - 18) * lines[i], height: 6) } }
                    .padding(.horizontal, 9).padding(.top, 8)
            }
        }
        .background(rr(8).fill(th.card)).clipShape(rr(8)).overlay(rr(8).strokeBorder(th.line, lineWidth: 0.5)).cssShadow(.black(0.12), y: 4, blur: 12)
    }
}
private struct EQ: View {   // .eq: three bars bouncing
    var color = Color(hex: 0x1ed760)
    var body: some View {
        TimelineView(.animation) { t in
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<3, id: \.self) { i in
                    let p = (t.date.timeIntervalSinceReferenceDate + Double(i) * 0.2).truncatingRemainder(dividingBy: 0.9) / 0.9
                    Capsule().fill(color).frame(width: 2, height: 3 + 9 * (0.5 - 0.5 * cos(p * 2 * .pi)))
                }
            }.frame(height: 12, alignment: .bottom)
        }.padding(.leading, 4)
    }
}

private struct TextStage: View {   // a line gets selected, the box offers a rewrite, Replace swaps it in
    let run: Bool; let reduce: Bool
    @State private var sel = false
    @State private var box = false
    @State private var press = false
    @State private var polite = false
    @State private var fade = false
    @Environment(\.setupTheme) var th
    var body: some View {
        ZStack(alignment: .topLeading) {
            Text(polite ? "Hi! Could you send me today’s notes? Thank you." : "hey can u send me the notes from today, thx")
                .font(cssFont(13.5)).foregroundColor(th.fg).lineHeight(13.5, 1.45)
                .background(alignment: .leading) { rr(3).fill(Color.rgba(10, 132, 255, 0.32)).padding(EdgeInsets(top: -1, leading: -2, bottom: -1, trailing: -2)).scaleEffect(x: sel ? 1 : 0, anchor: .leading).animation(css(0.4, 0, 0.2, 1, 0.9), value: sel) }
                .opacity(fade ? 0 : 1).animation(.linear(duration: 0.3), value: fade)
                .padding(EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14)).frame(width: 376, alignment: .leading)
                .background(rr(10).fill(th.card)).overlay(rr(10).strokeBorder(th.line, lineWidth: 0.5)).offset(x: 22, y: 22)
            Fake(shown: box) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("“make this polite”").font(cssFont(11)).foregroundColor(Color(hex: 0x8e8e93)).padding(.bottom, 4)
                    Text("Hi! Could you send me today’s notes? Thank you.")
                    HStack(spacing: 6) {
                        ForEach(["Replace", "Try again", "Copy"], id: \.self) { a in
                            Text(a).font(cssFont(11, 500)).padding(.vertical, 3).padding(.horizontal, 10)
                                .background(Capsule().fill(a == "Replace" ? (press ? Color(hex: 0x3d9bff) : Color(hex: 0x0a84ff)) : Color.white(0.1)))
                                .scaleEffect(a == "Replace" && press ? 0.92 : 1).animation(.easeInOut(duration: 0.2), value: press)
                        }
                    }.padding(.top, 8)
                }.padding(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12)).frame(width: 376, alignment: .leading)
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom).padding(.bottom, 16)
        }
        .task(id: "\(run)-\(reduce)") {
            if reduce { box = true; sel = true; return }
            while run && !Task.isCancelled {
                sel = false; polite = false; box = false; fade = false
                guard await pause(0.7) else { return }; sel = true
                guard await pause(1.3) else { return }; box = true
                guard await pause(1.9) else { return }; press = true
                guard await pause(0.22) else { return }; press = false; box = false; sel = false; fade = true
                guard await pause(0.3) else { return }; polite = true; fade = false
                guard await pause(2.4) else { return }
            }
        }
    }
}

// Dictate's examples: what you say, then what Clean up types. [Brackets] mark the words that go.
private let dcExamples = [("Fillers", "[Um,] I was, [like, you know,] thinking we could leave.", "I was thinking we could leave."),
                          ("Scratch that", "[Table for six, scratch that,] table for eight.", "Table for eight."),
                          ("Actually…", "Meet me at [four, actually] five.", "Meet me at five."),
                          ("Lists", "Shopping list: eggs, milk, and bread.", "Shopping list:\n- Eggs\n- Milk\n- Bread"),
                          ("New line", "Hi Sam [new line] can you review this [question mark]", "Hi Sam\nCan you review this?")]
private func saidWords(_ s: String) -> [(String, Bool)] {
    var out: [(String, Bool)] = [], rest = Substring(s)
    while let c = rest.first {
        if c == " " { rest = rest.dropFirst(); continue }
        if c == "[", let end = rest.firstIndex(of: "]") { out += rest[rest.index(after: rest.startIndex)..<end].split(separator: " ").map { (String($0), true) }; rest = rest[rest.index(after: end)...] }
        else { let end = rest.firstIndex(where: { $0 == " " || $0 == "[" }) ?? rest.endIndex; out.append((String(rest[..<end]), false)); rest = rest[end...] }
    }
    return out
}
private struct DictatePage: View {
    @ObservedObject var m: OnboardingModel
    let on: Bool
    @State private var at = 0
    @State private var gen = 0
    @Environment(\.setupTheme) var th
    var body: some View {
        let key = m.pstr("dictateHotkeyLabel"), rec = m.recording
        VStack(spacing: 0) {
            Kicker(s: "Dictate anywhere").rise(on, 0)
            H2(s: "Talk instead of typing").rise(on, 1)
            Sub(s: key.isEmpty ? "Give dictation a shortcut. Hold it to talk, double-tap to lock." : "Hold \(key) to talk. Double-tap to lock.").rise(on, 2)
            StageBox(height: 178) { DictateStage(run: on, reduce: m.reduce, key: key.isEmpty ? "fn" : key, at: $at, gen: gen) }.padding(.top, 22).rise(on, 3)
            WrapRow(spacing: 6) { ForEach(dcExamples.indices, id: \.self) { i in Chip(s: dcExamples[i].0, pressed: i == at) { at = i; gen += 1 } } }.frame(maxWidth: 440).padding(.top, 14).rise(on, 4)
            MtRow(color: 0xff9f0a, icon: micGlyph, title: "Dictation shortcut",
                  hint: m.dcWarn ?? (rec ? "Press a key combo, a modifier on its own, or an F-key. Esc cancels." : key.isEmpty ? "Click, then press the keys you want." : "In any text field, your words land at the cursor."), warn: m.dcWarn != nil) {
                SetupKeyField(m: m)
            }.rise(on, 5)
            if m.pbool("globeTaken") {
                HStack {
                    Text("Set Press 🌐 key to Do Nothing"); Spacer()
                    Text("Open Keyboard Settings").foregroundColor(th.accent).onTapGesture { m.post(["do": "globeKey"]) }
                }.font(cssFont(12)).foregroundColor(th.fg2).padding(.horizontal, 14).frame(width: 420).padding(.top, 10).rise(on, 5)
            }
            HStack(spacing: 12) {
                ST(s: "Clean up tidies it as shown. Verbatim types every word.", size: 12, color: th.fg2).multilineTextAlignment(.center).frame(maxWidth: .infinity)
                SetupSeg(options: [("verbatim", "Verbatim"), ("cleanup", "Clean up")], value: m.pstr("dictateMode")) { m.set("dictateMode", $0) }
            }.padding(.horizontal, 14).frame(width: 420).padding(.top, 10).opacity(key.isEmpty ? 0.45 : 1).rise(on, 5)
            HStack(spacing: 10) { PillButton(label: "Skip", quiet: true) { m.go("point") }; PillButton(label: "Next") { m.go("point") } }.padding(.top, 26).rise(on, 6)
        }
    }
}
private struct SetupKeyField: View {   // .keyfield, as in Settings
    @ObservedObject var m: OnboardingModel
    @State private var blink = false
    @State private var hoverX = false
    @Environment(\.setupTheme) var th
    var body: some View {
        let rec = m.recording, label = rec ? (m.recLabel?.label ?? "") : m.pstr("dictateHotkeyLabel")
        let text = rec ? (m.recLabel?.text ?? "Type Shortcut") : "Record Shortcut", set = !label.isEmpty && !rec
        ZStack(alignment: .trailing) {
            HStack(spacing: 4) {
                if label.isEmpty { Text(text).font(cssFont(12.5, 500)).foregroundColor(rec ? th.fg2 : th.accent).opacity(rec && blink ? 0.35 : 1) }
                else {
                    ForEach(capsOf(label), id: \.self) { c in
                        Text(c).font(cssFont(11, 500)).foregroundColor(th.fg).padding(.horizontal, 5).frame(minWidth: 20).frame(height: 20)
                            .background(rr(4).fill(LinearGradient(colors: [th.keyTop, th.keyBot], startPoint: .top, endPoint: .bottom)))
                            .background(rr(4).fill(th.keyEdge).offset(y: 1)).overlay(rr(4).stroke(th.keyEdge, lineWidth: 0.5))
                    }
                }
            }
            .padding(.leading, 10).padding(.trailing, set ? 30 : 10).frame(minWidth: 140, minHeight: 28, maxHeight: 28)
            .background(rr(7).fill(th.field).cssShadow(.black(0.05), y: 1, blur: 1))
            .overlay(rr(7).strokeBorder(rec ? th.accent : th.line, lineWidth: rec ? 1.5 : 0.5))
            .background(rr(7).inset(by: -3).fill(rec ? Color.rgba(10, 132, 255, 0.18) : .clear))
            .contentShape(Rectangle()).onTapGesture { m.toggleRecord() }
            if set {
                Text("×").font(cssFont(15)).foregroundColor(hoverX ? Color(hex: 0xff453a) : th.fg3).frame(width: 22, height: 22)
                    .background(Circle().fill(hoverX ? Color.rgba(127, 127, 127, 0.14) : .clear)).onHover { hoverX = $0 }
                    .onTapGesture { m.prefs["dictateHotkeyLabel"] = ""; m.post(["do": "clearDictate"]) }.padding(.trailing, 4)
            }
        }
        .fixedSize()
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("setup")) } action: { m.recField = $0 }
        .onChange(of: rec) { _, r in if r { withAnimation(.easeInOut(duration: 0.7).repeatForever()) { blink = true } } else { blink = false } }
    }
}
private struct DictateStage: View {   // what you say beside the pill (a wave, then the orb, then a check), the slips strike out, the clean text lands at the cursor
    let run: Bool; let reduce: Bool; let key: String
    @Binding var at: Int
    let gen: Int
    @State private var heard: [(String, Bool)] = []
    @State private var struck = false
    @State private var words = ""
    @State private var pill = "gone"   // gone, wave, work, done
    @State private var down = false
    @Environment(\.setupTheme) var th
    var body: some View {
        ZStack(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 0) {
                Text("To: Sam").font(cssFont(11)).foregroundColor(th.fg3).padding(.bottom, 3)
                (Text(words) + Text(" ")).font(cssFont(13)).foregroundColor(th.fg).lineHeight(13, 1.45)
                    .overlay(alignment: .bottomTrailing) { Caret() }
            }
            .padding(EdgeInsets(top: 9, leading: 14, bottom: 9, trailing: 14)).frame(width: 376, height: 178 - 14 - 52, alignment: .topLeading)
            .background(rr(10).fill(th.card)).overlay(rr(10).strokeBorder(th.line, lineWidth: 0.5)).offset(x: 22, y: 14)
            HStack(spacing: 0) {
                Fake(shown: pill != "gone") { DictPill(state: pill) }.frame(width: 56, alignment: .leading)
                Group {
                    if !heard.isEmpty {
                        Text("“") + heard.enumerated().reduce(Text("")) { t, e in t + Text((e.offset > 0 ? " " : "") + e.element.0).strikethrough(struck && e.element.1).foregroundColor(struck && e.element.1 ? th.fg2.opacity(0.4) : th.fg2) } + Text("”")
                    }
                }.font(cssFont(12)).italic().foregroundColor(th.fg2).lineLimit(1).truncationMode(.tail).padding(.leading, 10).frame(maxWidth: .infinity, alignment: .leading)
                Keycap(s: key, down: down).scaleEffect(32.0 / 40).frame(width: 40, height: 32)
            }
            .padding(.horizontal, 22).frame(width: 420, height: 32).offset(y: 178 - 12 - 32)
        }
        .task(id: "\(run)-\(gen)-\(reduce)") {
            if reduce || !run { if reduce { show(at) }; return }
            while !Task.isCancelled {
                let i = at
                words = ""; heard = []; struck = false; pill = "gone"; down = false
                guard await pause(0.6) else { return }; down = true; pill = "wave"
                for w in saidWords(dcExamples[i].1) { heard.append(w); guard await pause(0.21) else { return } }
                guard await pause(0.35) else { return }; down = false; pill = "work"; struck = true
                guard await pause(1.0) else { return }; words = dcExamples[i].2; pill = "done"
                guard await pause(0.8) else { return }; pill = "gone"
                guard await pause(2.4) else { return }; at = (i + 1) % dcExamples.count
            }
        }
    }
    func show(_ i: Int) { heard = saidWords(dcExamples[i].1); struck = true; pill = "done"; words = dcExamples[i].2 }
}
private struct Caret: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { t in
            Rectangle().fill(Color(hex: 0x0a84ff)).frame(width: 1.5, height: 16).opacity(Int(t.date.timeIntervalSinceReferenceDate * 2) % 2 == 0 ? 1 : 0)
        }.offset(x: -2, y: -1)
    }
}
private struct DictPill: View {   // #dc-pill
    let state: String
    var body: some View {
        ZStack {
            if state == "wave" { HStack(spacing: 2) { ForEach(0..<5, id: \.self) { i in EQBar(delay: Double(i % 3) * 0.2) } }.frame(height: 12) }
            if state == "work" { Circle().fill(RadialGradient(colors: [.white, Color(hex: 0x64d2ff), Color(hex: 0x5e5ce6)], center: UnitPoint(x: 0.35, y: 0.3), startRadius: 0, endRadius: 9)).frame(width: 14, height: 14) }
            if state == "done" { ZStack { Circle().fill(Color(hex: 0x30d158)); SVGPath(d: "M6.5 11.3l3 3 6-6.3", box: 22).stroke(.white, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)) }.frame(width: 20, height: 20) }
        }
        .frame(width: state == "wave" ? 56 : 32, height: 32).animation(css(0.4, 0, 0.2, 1, 0.22), value: state)
    }
}
private struct EQBar: View {
    let delay: Double
    var body: some View {
        TimelineView(.animation) { t in
            let p = (t.date.timeIntervalSinceReferenceDate + delay).truncatingRemainder(dividingBy: 0.9) / 0.9
            Capsule().fill(Color(hex: 0x0a84ff)).frame(width: 3, height: 3 + 9 * (0.5 - 0.5 * cos(p * 2 * .pi)))
        }
    }
}

private struct PointStage: View {   // a guide marks the spot, then an explanation builds up like a whiteboard
    let run: Bool; let reduce: Bool
    @State private var box = false
    @State private var lead = false
    @State private var ring = false
    @State private var wb = false
    @State private var step = 0
    @Environment(\.setupTheme) var th
    var body: some View {
        ZStack(alignment: .topLeading) {
            Group {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 5) { ForEach(0..<3, id: \.self) { _ in Circle().fill(Color.rgba(127, 127, 127, 0.4)).frame(width: 7, height: 7) } }
                        .padding(.leading, 9).frame(maxWidth: .infinity, minHeight: 22, maxHeight: 22, alignment: .leading).overlay(alignment: .bottom) { Rectangle().fill(th.line).frame(height: 0.5) }
                    ForEach([("General", 0x8e8e93), ("Appearance", 0x0a84ff), ("Notifications", 0xff9f0a), ("Battery", 0x30d158)], id: \.0) { it in
                        HStack(spacing: 8) { rr(4).fill(Color(hex: UInt32(it.1))).frame(width: 14, height: 14); Text(it.0).font(cssFont(12)).foregroundColor(th.fg) }
                            .overlay { if it.0 == "Appearance" { PointRing(on: ring).padding(-4) } }
                            .padding(.horizontal, 8).padding(.vertical, 5).padding(.horizontal, 8).padding(.vertical, 2)
                    }
                }
                .frame(width: 230, height: 146, alignment: .topLeading).background(rr(10).fill(th.card)).clipShape(rr(10)).overlay(rr(10).strokeBorder(th.line, lineWidth: 0.5))
                .offset(x: 22, y: 16)
                LeadLine(on: lead).frame(width: 420, height: 178)
                Fake(shown: box) {
                    VStack(alignment: .leading, spacing: 5) { Text("“how do I turn on dark mode?”").font(cssFont(11)).foregroundColor(Color(hex: 0x8e8e93)); Text("Step 1 of 2: click Appearance.") }
                        .padding(EdgeInsets(top: 9, leading: 11, bottom: 9, trailing: 11)).frame(width: 140, alignment: .leading)
                }.offset(x: 420 - 22 - 140, y: 34)
            }.opacity(wb ? 0 : 1)
            Group {
                Whiteboard(step: step).frame(width: 220, height: 146).offset(x: 22, y: 16)
                Fake {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack { Text("Step \(max(step, 1)) of 3"); Spacer(); Text("✕") }.font(cssFont(10.5)).foregroundColor(Color(hex: 0x8e8e93))
                        ForEach(Array(["A right triangle has one square corner.", "Short sides a and b, long side c.", "a² + b² = c². With 3 and 4, c is 5."].enumerated()), id: \.offset) { i, s in
                            if step > i { Text(s).font(cssFont(11)).lineHeight(11, 1.35).padding(.top, 5).transition(.opacity) }
                        }
                    }.padding(EdgeInsets(top: 9, leading: 11, bottom: 9, trailing: 11)).frame(width: 150, alignment: .topLeading).animation(out(0.5), value: step)
                }.offset(x: 420 - 22 - 150, y: 16)
            }.opacity(wb ? 1 : 0)
        }
        .animation(css(0.4, 0, 0.2, 1, 0.45), value: wb)
        .task(id: "\(run)-\(reduce)") {
            if reduce { wb = true; step = 3; return }
            while run && !Task.isCancelled {
                wb = false; step = 0; box = false; ring = false; lead = false
                guard await pause(0.7) else { return }; box = true
                guard await pause(1.1) else { return }; lead = true
                guard await pause(0.4) else { return }; ring = true
                guard await pause(2.6) else { return }; wb = true
                for k in 1...3 { guard await pause(k == 1 ? 0.5 : 1.6) else { return }; step = k }
                guard await pause(3.2) else { return }
            }
        }
    }
}
private struct PointRing: View {   // #pt-ring: a red ring that lands on the spot and breathes
    let on: Bool
    @State private var breathe = false
    var body: some View {
        rr(9).strokeBorder(Color(hex: 0xff375f), lineWidth: 2)
            .shadow(color: .rgba(255, 55, 95, breathe ? 0.6 : 0.5), radius: breathe ? 12 : 9)
            .background(rr(9).inset(by: breathe ? -7 : -4).stroke(Color.rgba(255, 55, 95, breathe ? 0.12 : 0.2), lineWidth: breathe ? 7 : 4))
            .opacity(on ? 1 : 0).scaleEffect(on ? 1 : 1.4).animation(spring(0.5), value: on)
            .onChange(of: on) { _, o in if o { withAnimation(.easeInOut(duration: 0.6).repeatForever().delay(0.5)) { breathe = true } } else { breathe = false } }
    }
}
private struct LeadLine: View {   // the leader: a dotted line from the box to the spot
    let on: Bool
    var body: some View {
        Canvas { ctx, _ in
            var p = Path(); p.move(to: CGPoint(x: 420 - 22 - 140, y: 34 + 26)); p.addLine(to: CGPoint(x: 22 + 8 + 14 + 8 + 80 + 6, y: 16 + 22 + 4 + 24 + 12))
            ctx.stroke(p, with: .linearGradient(Gradient(colors: [Color(hex: 0x0a84ff, 0.1), Color(hex: 0x0a84ff)]), startPoint: CGPoint(x: 258, y: 60), endPoint: CGPoint(x: 138, y: 78)),
                       style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [0.1, 6]))
        }.mask(Rectangle().scaleEffect(x: on ? 1 : 0, anchor: .trailing).animation(out(0.85), value: on))
    }
}
private struct Whiteboard: View {   // #wb: a right triangle, its sides, then the rule
    let step: Int
    let red = Color(hex: 0xff375f)
    var body: some View {
        ZStack(alignment: .topLeading) {
            SVGPath(d: "M30 26V122H150Z", box: 220).trim(from: 0, to: step >= 1 ? 1 : 0).stroke(red, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round)).animation(css(0.4, 0, 0.2, 1, 0.9), value: step)
                .frame(width: 220, height: 220)
            SVGPath(d: "M30 110h12v12", box: 220).stroke(red, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round)).frame(width: 220, height: 220).opacity(step >= 1 ? 1 : 0)
            Group {
                Text("a").offset(x: 14, y: 79 - 13); Text("b").offset(x: 86, y: 140 - 13); Text("c").offset(x: 98, y: 68 - 13)
            }.font(cssFont(13, 600)).foregroundColor(red).opacity(step >= 2 ? 1 : 0)
            Group {
                Text("a² + b² = c²").font(cssFont(13, 600)).offset(x: 116, y: 26 - 13)
                Text("3² + 4² = 5²").font(cssFont(11, 500)).offset(x: 122, y: 44 - 11)
            }.foregroundColor(red).opacity(step >= 3 ? 1 : 0)
        }
        .animation(css(0.4, 0, 0.2, 1, 0.4), value: step)
    }
}

private struct WorkPage: View {
    @ObservedObject var m: OnboardingModel
    let on: Bool
    var body: some View {
        let why = ["cheapest": "Haiku for every ask. Fastest, and uses the least of your plan.", "balanced": "Haiku for quick asks. Your work model takes over real work.",
                   "capable": "Your work model for every ask. Slower, and uses the most of your plan."]
        VStack(spacing: 0) {
            Kicker(s: "Your plan, your pace").rise(on, 0)
            H2(s: "Quick asks stay quick").rise(on, 1)
            Sub(s: "Choose how much of your plan Aurel uses. A long ask moves to a background agent by itself, so you keep working. ⌃⌥↩ moves one sooner.").rise(on, 2)
            StageBox(height: 122) { WorkStage(run: on, reduce: m.reduce) }.padding(.top, 22).rise(on, 3)
            ListCard(maxWidth: 420) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 0) { ST(s: "Intelligence", weight: 500); ST(s: why[m.pstr("routing")] ?? "", size: 12, color: SetupTheme(dark: false).fg3).padding(.top, 1) }.frame(maxWidth: .infinity, alignment: .leading)
                    SetupSeg(options: [("cheapest", "Cheapest"), ("balanced", "Balanced"), ("capable", "Most capable")], value: m.pstr("routing")) { m.set("routing", $0) }
                }.padding(.horizontal, 14).padding(.vertical, 9)
            }.padding(.top, 14).rise(on, 4)
            HStack(spacing: 10) { PillButton(label: "Skip", quiet: true) { m.go("done") }; PillButton(label: "Next") { m.go("done") } }.padding(.top, 26).rise(on, 5)
        }
    }
}
private struct WorkStage: View {   // a long ask offers to move, then runs on as an agent chip
    let run: Bool; let reduce: Bool
    @State private var box = false
    @State private var chip = false
    @State private var done = false
    @State private var line = "Searching the web…"
    var body: some View {
        ZStack(alignment: .topLeading) {
            Fake(shown: box) {
                VStack(alignment: .leading, spacing: 4) { Text("“Find standing desks under $600”").font(cssFont(11)).foregroundColor(Color(hex: 0x8e8e93)); Text(line).foregroundColor(Color(hex: 0xa1a1a6)) }
                    .padding(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12)).frame(width: 208, alignment: .leading)
            }.offset(x: 22, y: 16)
            Fake(shown: chip) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(done ? "Agent · done" : "Agent · working").font(cssFont(11)).foregroundColor(done ? Color(hex: 0x30d158) : Color(hex: 0x8e8e93))
                    Text("Standing desks").fontWeight(.medium)
                }
                .padding(EdgeInsets(top: 9, leading: 11, bottom: 9, trailing: 11)).frame(width: 150, alignment: .leading)
                .overlay(alignment: .bottom) { if !done { Crawl().padding(.horizontal, 11) } }.clipShape(rr(10))
            }.offset(x: 420 - 22 - 150, y: 16)
        }
        .task(id: "\(run)-\(reduce)") {
            if reduce { line = "I started an agent. I’ll ping you when it’s done."; box = true; chip = true; return }
            while run && !Task.isCancelled {
                box = false; chip = false; done = false; line = "Searching the web…"
                guard await pause(0.6) else { return }; box = true
                guard await pause(2.0) else { return }; line = "I started an agent. I’ll ping you when it’s done."; chip = true
                guard await pause(1.8) else { return }; box = false
                guard await pause(2.4) else { return }; done = true
                guard await pause(2.4) else { return }
            }
        }
    }
}
private struct Crawl: View {   // the chip's progress bar
    var body: some View {
        TimelineView(.animation) { t in
            let p = t.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.4) / 2.4
            GeometryReader { g in ZStack(alignment: .leading) { Rectangle().fill(Color.white(0.1)); Rectangle().fill(Color(hex: 0x0a84ff)).frame(width: g.size.width * (0.08 + 0.77 * (1 - pow(1 - p, 2)))) } }
        }.frame(height: 2)
    }
}

// The things to try that bloom out of the orb on the last page: colour, glyph, words, where it lands (x% of 576, y), stagger index.
private let ideas: [(UInt32, [String], String, CGFloat, CGFloat, Int, Bool)] = [
    (0xa2845e, ["M7 4h10v16l-5-3.5L7 20z"], "“Remember I use Chrome”", 0.25, 15, 10, true),
    (0xff453a, ["M6 16v-5a6 6 0 0 1 12 0v5l1.5 2h-15z", "M10 20.5a2 2 0 0 0 4 0"], "“Tell me when the download finishes”", 0.70, 15, 11, false),
    (0x0a84ff, [rect(3, 5, 8, 14, 1.5), rect(13, 5, 8, 14, 1.5)], "“Chrome left, Terminal right”", 0.20, 53, 6, true),
    (0xff375f, [circle(12, 12, 8), circle(12, 12, 3)], "“How do I export this as a PDF?”", 0.77, 53, 7, false),
    (0x30d158, ["M9 18V6l10-2v12", circle(6.5, 18, 2.5), circle(16.5, 16, 2.5)], "“Play my playlist”", 0.22, 91, 0, true),
    (0x636366, ["M19.5 14.5A8 8 0 0 1 9.5 4.5a8 8 0 1 0 10 10z"], "“Turn on dark mode”", 0.79, 91, 1, false),
    (0xbf5af2, ["M2.5 12s3.5-6.5 9.5-6.5S21.5 12 21.5 12s-3.5 6.5-9.5 6.5S2.5 12 2.5 12z", circle(12, 12, 2.5)], "“What’s on my screen?”", 0.18, 129, 2, true),
    (0xff9f0a, micGlyph, "DICTATE", 0.75, 129, 3, false),
    (0x30d158, ["M9 6v12M15 6v12"], "“Pause the music”", 0.22, 167, 4, true),
    (0xff375f, ["M4 20l4-1 11-11-3-3L5 16z"], "“Explain this and draw it”", 0.79, 167, 5, false),
    (0x8e8e93, ["M4 9.5h3.5L12 5.5v13l-4.5-4H4z", "M15.5 9a4 4 0 0 1 0 6M18 6.5a7.5 7.5 0 0 1 0 11"], "“Read your answers aloud”", 0.21, 205, 8, true),
    (0x30b0c7, [circle(11, 11, 6.5), "M16 16l4.5 4.5"], "“Best headphones under $200?”", 0.77, 205, 9, false),
    (0x5e5ce6, ["M13 3L5 13.5h6L10 21l8-10.5h-6z"], "“When I say work mode, open Notes”", 0.27, 243, 12, true),
    (0xd97757, ["M12 3l1.8 5.2L19 10l-5.2 1.8L12 17l-1.8-5.2L5 10l5.2-1.8z"], "“Compare the top 3 laptops”", 0.75, 243, 13, false),
    (0x30b0c7, ["M4 7h15l-3-3M20 17H5l3 3"], "“Convert this JPEG to PNG”", 0.50, 281, 14, false),
]
private struct Done: View {
    @ObservedObject var m: OnboardingModel
    let on: Bool
    @State private var hi = -1
    @Environment(\.setupTheme) var th
    var body: some View {
        let s = m.status
        let core = [("claude", "AI provider"), ("mic", "Microphone"), ("speech", "Speech Recognition"), ("ax", "Accessibility")]
        let missing = core.filter { !(s[$0.0] ?? false) }.map(\.1), voice = ["claude", "mic", "speech"].allSatisfy { s[$0] ?? false }
        let key = m.pstr("dictateHotkeyLabel")
        let shown = ideas.indices.filter { ideas[$0].2 != "DICTATE" || !key.isEmpty }
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                if missing.isEmpty { if on { CheckMark(size: 16, delay: 0.1) } else { Color.clear.frame(width: 16, height: 16) } } else { Circle().fill(Color(hex: 0xff9f0a)).frame(width: 7, height: 7) }
                Text(missing.isEmpty ? "You’re all set" : voice ? "Voice is ready" : "Setup isn’t finished yet").font(cssFont(12, 500)).foregroundColor(missing.isEmpty ? th.fg2 : th.warn)
            }
            .padding(.leading, missing.isEmpty ? 5 : 10).padding(.trailing, 11).frame(height: 24)
            .background(Capsule().fill(th.card)).overlay(Capsule().strokeBorder(th.line, lineWidth: 0.5)).rise(on, 0)
            ZStack {
                ZStack { Glow(inset: 70); Circle().strokeBorder(th.line, lineWidth: 0.5).padding(-22); OrbRep(running: on && !m.reduce).frame(width: 108, height: 108) }
                    .frame(width: 108, height: 108).position(x: 288, y: 147)
                ForEach(shown, id: \.self) { i in
                    let d = ideas[i]
                    IdeaBubble(color: d.0, icon: d.1, text: d.2, left: d.6, key: key, hi: hi == i)
                        .position(x: on ? 576 * d.3 : 288, y: on ? d.4 : 147)
                        .scaleEffect(on ? 1 : 0.4).opacity(on ? 1 : 0)
                        .animation(on ? out(0.9).map { $0.delay(0.15 + Double(d.5) * 0.045) } : nil, value: on)
                }
            }.frame(width: 576, height: 294).padding(.top, 16).rise(on, 1)
            (Text("Go use Aurel. ") + Text("Be great.").foregroundColor(th.fg3)).font(cssFont(32, 600)).tracking(-0.025 * 32).foregroundColor(th.fg).lineHeight(32, 1.1)
                .padding(.top, 14).padding(.bottom, 6).rise(on, 2)
            Sub(s: missing.isEmpty ? (m.toggleMode ? "Press" : "Hold") + " the shortcut anywhere and try one."
                : (voice ? "Still needed for full Mac control: " : "Still needed: ") + missing.joined(separator: ", ") + ". You can allow \(missing.count == 1 ? "it" : "them") later in Setup & Permissions.", maxWidth: 520).rise(on, 3)
            PillButton(label: voice ? "Start Using Aurel" : "Finish Setup Later") { m.post(["do": "done"]) }.padding(.top, 18).rise(on, 4)
        }
        .task(id: "\(on)-\(m.reduce)") {   // one idea at a time lights up around the orb
            guard on, !m.reduce else { hi = -1; return }
            var k = 0
            while !Task.isCancelled && k < shown.count { guard await pause(k == 0 ? 1.6 : 2.2) else { return }; withAnimation(out(0.4)) { hi = shown[k] }; k += 1 }
        }
    }
}
private struct IdeaBubble: View {
    let color: UInt32; let icon: [String]; let text: String; let left: Bool; let key: String; let hi: Bool
    @State private var hover = false
    @Environment(\.setupTheme) var th
    var body: some View {
        let lift = hi || hover
        HStack(spacing: 7) {
            ZStack { Circle().fill(Color(hex: color)); Icon(paths: icon, stroke: 2.2, color: .white).frame(width: 12, height: 12) }.frame(width: 20, height: 20).scaleEffect(lift ? 1.12 : 1).animation(spring(0.4), value: lift)
            if text == "DICTATE" {
                HStack(spacing: 0) {
                    Text("Hold")
                    ForEach(capsOf(key), id: \.self) { c in
                        Text(c).font(cssFont(11, 500)).padding(.vertical, 1).padding(.horizontal, 5)
                            .background(rr(4).fill(LinearGradient(colors: [th.keyTop, th.keyBot], startPoint: .top, endPoint: .bottom))).overlay(rr(4).stroke(th.keyEdge, lineWidth: 0.5)).padding(.horizontal, 1)
                    }
                    Text("to dictate")
                }
            } else { Text(text) }
        }
        .font(cssFont(12.5)).foregroundColor(th.fg).lineLimit(1).fixedSize()
        .padding(.leading, 5).padding(.trailing, 12).frame(height: 30)
        .background(UnevenRoundedRectangle(topLeadingRadius: 15, bottomLeadingRadius: left ? 15 : 5, bottomTrailingRadius: left ? 5 : 15, topTrailingRadius: 15, style: .circular)
            .fill(lift ? (th.dark ? Color.white(0.13) : th.field) : th.card))
        .overlay(UnevenRoundedRectangle(topLeadingRadius: 15, bottomLeadingRadius: left ? 15 : 5, bottomTrailingRadius: left ? 5 : 15, topTrailingRadius: 15, style: .circular).strokeBorder(th.line, lineWidth: 0.5))
        .shadow(color: .black(lift ? (th.dark ? 0.35 : 0.12) : 0.06), radius: lift ? 14 : 9, y: lift ? 12 : 6)
        .offset(y: lift ? -3 : 0).animation(out(0.4), value: lift)
        .onHover { hover = $0 }
        .modifier(Bob(seed: text.count))
    }
}
private struct Bob: ViewModifier {   // bob: 7 s, up 3 pt at the middle
    let seed: Int
    func body(content: Content) -> some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)) { t in
            let p = (t.date.timeIntervalSinceReferenceDate + Double(seed) * 0.8).truncatingRemainder(dividingBy: 7) / 7
            content.offset(y: -3 * (0.5 - 0.5 * cos(p * 2 * .pi)))
        }
    }
}

private struct ProviderSheet: View {   // Change provider: a sheet over the setup page
    @ObservedObject var m: OnboardingModel
    @Environment(\.setupTheme) var th
    @State private var shown = false
    var body: some View {
        ZStack {
            Color.black(0.18).onTapGesture {}
            VStack(alignment: .leading, spacing: 0) {
                Text("Choose your AI provider").font(cssFont(16, 600)).foregroundColor(th.fg)
                Text("Aurel thinks with one of these. Change it anytime in Settings.").font(cssFont(12)).foregroundColor(th.fg2).padding(.top, 4).padding(.bottom, 14)
                ProviderOption(m: m, id: "local", title: "Local", why: "Runs on this Mac. Free, private, nothing to install.")
                ProviderOption(m: m, id: "claude", title: "Claude", why: "Your Claude Pro or Max plan, through Claude Code.").padding(.top, 6)
                HStack(spacing: 8) {
                    Spacer()
                    PillButton(label: "Cancel", quiet: true, height: 30, pad: 16, size: 13) { close() }
                    PillButton(label: "Use " + (m.pick == "local" ? "Local" : "Claude"), height: 30, pad: 16, size: 13) { m.useProvider() }
                }.padding(.top, 16)
            }
            .padding(20).frame(width: 420)
            .background(rr(16).fill(th.sheet)).overlay(rr(16).strokeBorder(th.line, lineWidth: 0.5)).cssShadow(.black(0.22), y: 18, blur: 50)
            .offset(y: shown ? 0 : 10).scaleEffect(shown ? 1 : 0.98).animation(out(0.35), value: shown)
        }
        .onAppear { shown = true }
        .onExitCommand { close() }
    }
    func close() { withAnimation(eased(0.25)) { m.sheet = false } }
}
private struct ProviderOption: View {
    @ObservedObject var m: OnboardingModel
    let id, title, why: String
    @State private var hover = false
    @Environment(\.setupTheme) var th
    var body: some View {
        let on = m.pick == id
        HStack(spacing: 12) {
            Circle().strokeBorder(on ? th.accent : th.fg3, lineWidth: on ? 5 : 1.5).frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 0) { ST(s: title, weight: 500); ST(s: why, size: 12, color: th.fg3).padding(.top, 2) }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(rr(10).fill(on ? Color.rgba(10, 132, 255, 0.1) : hover ? Color.rgba(127, 127, 127, 0.08) : .clear))
        .overlay(rr(10).strokeBorder(on ? th.accent : th.line, lineWidth: on ? 1.5 : 0.5))
        .contentShape(Rectangle()).onHover { hover = $0 }.onTapGesture { m.pick = id }
    }
}

// MARK: - Hosting, for Onboarding and the screenshot harness

final class OnboardingSurface: NativeSurface {
    let model = OnboardingModel()
    let host: NSHostingView<OnboardingView>
    var view: NSView { host }
    init(frame: NSRect) {
        host = NSHostingView(rootView: OnboardingView(m: model)); host.frame = frame; host.autoresizingMask = [.width, .height]
        model.post = { print("post", $0) }
        model.go("welcome")
    }
    func receive(_ call: String, _ value: Any) {
        switch call {
        case "_go": model.go(value as? String ?? "welcome")
        case "_sheet": model.pick = model.provider; model.sheet = true
        default: model.receive(call, value)
        }
    }
    func freeze(at ms: Double?) {}
}
