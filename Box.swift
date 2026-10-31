// The box (the overlay that shows your words live and the thinking orb). App (Aurel.swift) calls BoxModel.receive (listen, words,
// line, …) and gets messages back through post. The panel never activates, so the view never sees real hover or clicks: native tracking sends pointer() and tap(),
// and elements here say where they are (boxTarget) so those land on the right one, as elementFromPoint did.
import AppKit
import SwiftUI

// MARK: - Tokens (always dark)

enum BX {
    static let fg = Color(hex: 0xf5f5f7), fg2 = Color(hex: 0xe8e8ea), accent = Color(hex: 0x006bd6), blue = Color(hex: 0x0a84ff)
    static let green = Color(hex: 0x30d158), link = Color(hex: 0xc6eeff), orange = Color(hex: 0xff9f0a), red = Color(hex: 0xff453a)
    static func ease(_ s: Double, delay: Double = 0) -> Animation? { css(0.2, 0.8, 0.2, 1, s, delay: delay) }
    static func spring(_ s: Double, delay: Double = 0) -> Animation? { css(0.34, 1.56, 0.64, 1, s, delay: delay) }
}

// MARK: - Hit targets: where each clickable thing is, in the box's own top-left coordinates

enum TargetKind {
    case button(() -> Void), field(() -> Void), answer, question, tip, tipOff, mode, link((CGPoint) -> Bool), area
}
final class TargetEntry: Equatable {
    let id: String, rect: CGRect, hand: Bool, kind: TargetKind
    init(_ id: String, _ rect: CGRect, _ hand: Bool, _ kind: TargetKind) { self.id = id; self.rect = rect; self.hand = hand; self.kind = kind }
    static func == (a: TargetEntry, b: TargetEntry) -> Bool { a.id == b.id && a.rect == b.rect && a.hand == b.hand }
}
struct TargetsKey: PreferenceKey {
    static var defaultValue: [TargetEntry] = []
    static func reduce(value: inout [TargetEntry], nextValue: () -> [TargetEntry]) { value += nextValue() }
}
extension View {
    // Box clicks come through tap(); the typing row's are left to SwiftUI for its text field, so its buttons (mic, Point, model) take the click themselves.
    @ViewBuilder func boxTarget(_ id: String, hand: Bool = true, kind: TargetKind = .area) -> some View {
        let v = background(GeometryReader { g in Color.clear.preference(key: TargetsKey.self, value: [TargetEntry(id, g.frame(in: .named("box")), hand, kind)]) })
        if case .button(let f) = kind { v.onTapGesture(perform: f) } else { v }
    }
}
private struct RectKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) { value.merge(nextValue()) { $1 } }
}
private extension View {
    func report(_ id: String) -> some View { background(GeometryReader { g in Color.clear.preference(key: RectKey.self, value: [id: g.frame(in: .named("box"))]) }) }
}

// MARK: - What the thread holds

struct Step: Identifiable { let id = UUID(); var text: String; var state: String }   // live, done, cut, ""
struct MemItem { let c: String; let label: String; let t: String; let add: Bool }
struct PickOption { let label: String; let sub: String; let path: String; let img: NSImage?; let kind: String }
struct Made { let url, title, sub: String; let icon: [String] }
struct KeyAction { let label: String; let key: String?; let go: Bool; let esc: Bool; let msg: [String: Any] }

enum CardKind {
    case approval(q: String, cmd: String)
    case retry(q: String, p: String, details: String?)
    case paused, worker
    case pick(q: [MDBlock], options: [PickOption], pics: Bool)
    case agent(eyebrow: String, title: String, answer: [MDBlock], learned: String?, made: [Made], actions: [KeyAction], cost: String?, id: String)
}
struct Card: Identifiable {
    let id = UUID(); var kind: CardKind; var gone = false; var full = false
    var open: Int? = nil, other = "", hidden = false, retryBusy = false, born = Date()
}
enum Part: Identifiable {
    case shot(UUID, NSImage), sel(UUID, String), q(UUID), qReply(UUID, String, Bool), mini(UUID), steps(UUID), answer(UUID), clock(UUID)
    case card(Card), mem(UUID, [MemItem]), tip(UUID, String, Bool), rewrite(UUID, String, [(String, String)], String, Bool), note(UUID, String)
    var id: UUID {
        switch self {
        case .shot(let i, _), .sel(let i, _), .q(let i), .qReply(let i, _, _), .mini(let i), .steps(let i), .answer(let i), .clock(let i), .mem(let i, _), .tip(let i, _, _), .rewrite(let i, _, _, _, _), .note(let i, _): return i
        case .card(let c): return c.id
        }
    }
}
struct MiniState { var on = false; var live = false; var done = false; var title = ""; var tag = "Working"; var icon: NSImage?; var born = Date(); var point: (kind: String, x: CGFloat, y: CGFloat, dx: CGFloat, dy: CGFloat, id: UUID)? }
struct Turn: Identifiable {
    let id = UUID(); var dict = false; var old = false; var loose = false
    var parts: [Part] = []
    var q = ""; var qLive = true; var qHear = false; var qEmpty = true
    var steps: [Step] = []; var more = 0
    var mini: MiniState? = nil
    var aKind = "normal"   // normal, streaming, draft, cancel, stopped, ack
    var aText = "", aBlocks: [MDBlock] = [], aAnswer: String? = nil, aOrb = false
    var reveal = Reveal()
    var said: [(key: String, text: String)] = [], started: [String: [String]] = [:]   // said: in the order it was said
    var redo = false; var preview = false; var clock: String? = nil   // clock: frozen once a later turn starts its own
    var shotBig = false; var memOpen: Set<UUID> = []
}

// MARK: - Model: the page's state and window.ui

final class BoxModel: ObservableObject {
    var post: ([String: Any]) -> Void = { _ in }
    var onSize: ([CGFloat]) -> Void = { _ in }
    var onMini: ([String: Any]) -> Void = { _ in }

    @Published var orbState = "breathing"
    @Published var orbScale: CGFloat = 1
    var boost = 1.0   // the orb spins faster with the microphone level; orbScale, set with it, redraws
    @Published var status = ""
    @Published var statusLive = false
    @Published var statusToken = 0
    @Published var agents = 0
    @Published var agentsAttention = false
    @Published var safeOff = false
    @Published var folded = false
    @Published var turns: [Turn] = []
    @Published var compOpen = false
    @Published var pickRow = false
    @Published var ask = ""
    @Published var focusAsk = 0
    @Published var focusOther = 0
    @Published var models: [String] = []
    @Published var modelPick = ""
    @Published var pointState: String? = nil   // on, marked, coach
    @Published var pointHint = ""
    @Published var pointThumb: NSImage? = nil
    @Published var pointActive = false
    @Published var pointMarked = false
    @Published var dictate = false
    @Published var hearing = false
    @Published var locked = false
    @Published var pill = ""
    @Published var dn = ""
    @Published var dnTick = false
    @Published var dnButtons: [(String, () -> Void)] = []
    @Published var wave: [CGFloat] = Array(repeating: 3, count: 9)
    @Published var visible = true
    @Published var screenHeight: CGFloat = 10000
    @Published var threadMax: CGFloat = 420
    @Published var held: CGFloat? = nil
    @Published var again = false
    @Published var popToken = 0
    @Published var hot: Set<String> = []
    @Published var bodyHot = false
    @Published var clockStart: Double? = nil
    @Published var clockHeld: Double? = nil
    @Published var clockFinal: String? = nil
    @Published var hf = false
    var listening = false, working = false, hover = false, coachPending = false, atBottom = true
    var targets: [TargetEntry] = []
    var rects: [String: CGRect] = [:]
    var scrollTo: (() -> Void)?   // to the bottom: the newest line stays in view unless the user scrolled up
    var lastSize: [CGFloat] = []
    var miniTimer: DispatchWorkItem?, miniEnd = false
    var defaultEnabled = false

    // MARK: helpers (the page's turn(), part(), status(), fit()…)

    var last: Int? { turns.indices.last }
    func edit(_ f: (inout Turn) -> Void) { guard let i = last else { return }; f(&turns[i]) }
    func setStatus(_ s: String, _ live: Bool = false) {
        status = (!s.isEmpty && listening) ? "Listening…" : s; statusLive = live; statusToken += 1
    }
    func setState(_ s: String) { orbState = s }
    func settle() { edit { t in for i in t.steps.indices where t.steps[i].state == "live" { t.steps[i].state = "done" } } }
    func unstream() { for i in turns.indices where turns[i].aKind == "streaming" { turns[i].aKind = "normal"; turns[i].aBlocks = []; turns[i].aText = "" } }
    func fit() {
        let enabled = defaultButton() != nil
        if enabled != defaultEnabled { defaultEnabled = enabled; post(["agentDefault": enabled]) }
    }
    func appendCard(_ c: Card) {
        if let i = last, !turns[i].loose { turns[i].parts.append(.card(c)) } else { var t = Turn(); t.loose = true; t.parts = [.card(c)]; turns.append(t) }
    }
    func mapCards(_ f: (inout Card) -> Void) {
        for i in turns.indices { for j in turns[i].parts.indices { if case .card(var c) = turns[i].parts[j] { f(&c); turns[i].parts[j] = .card(c) } } }
    }
    func removeParts(_ match: (Part) -> Bool) {
        for i in turns.indices { turns[i].parts.removeAll(where: match) }
        turns.removeAll { $0.loose && $0.parts.isEmpty }
    }
    func isCard(_ p: Part, _ test: (CardKind) -> Bool) -> Bool { if case .card(let c) = p { return test(c.kind) }; return false }
    func goneCard(_ id: UUID, after: Double = 0.36) {
        mapCards { if $0.id == id { $0.gone = true } }
        DispatchQueue.main.asyncAfter(deadline: .now() + after) { self.removeParts { $0.id == id } }
    }
    func liveCard(_ test: (CardKind) -> Bool) -> Card? {
        for t in turns { for p in t.parts { if case .card(let c) = p, !c.gone, test(c.kind) { return c } } }
        return nil
    }
    var hasPick: Bool { liveCard { if case .pick = $0 { return true }; return false } != nil }
    func defaultButton() -> KeyAction? {
        guard visible, !folded, ask.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        if liveCard({ if case .agent = $0 { return false }; return true }) != nil { return nil }
        guard let c = liveCard({ if case .agent = $0 { return true }; return false }), case .agent(_, _, _, _, _, let acts, _, _) = c.kind else { return nil }
        return acts.first { $0.go }
    }

    // clock: time Aurel spent working; waiting for a pick or approval does not count
    func clockBegin() {
        guard clockStart == nil, clockHeld == nil, let i = last, !turns[i].loose else { return }
        turns[i].clock = nil   // earlier turns keep the time clockStop gave them
        if !turns[i].parts.contains(where: { if case .clock = $0 { return true }; return false }) { turns[i].parts.append(.clock(UUID())) }
        clockFinal = nil; clockStart = CACurrentMediaTime()
    }
    func clockText(_ now: Double) -> String {
        if let f = clockFinal { return f }
        let t = clockHeld ?? (clockStart.map { now - $0 } ?? 0)
        return t < 60 ? String(format: "%.2f s", t) : "\(Int(t / 60)):" + String(format: "%05.2f", t.truncatingRemainder(dividingBy: 60))
    }
    func clockStop() {
        if clockStart != nil || clockHeld != nil { clockFinal = clockText(CACurrentMediaTime()); if let i = last { turns[i].clock = clockFinal } }   // the turn keeps it after a later one starts
        clockStart = nil; clockHeld = nil
    }
    func clockHold() { guard let s = clockStart else { return }; clockHeld = CACurrentMediaTime() - s; clockStart = nil }
    func clockGo() { guard let h = clockHeld else { return }; clockStart = CACurrentMediaTime() - h; clockHeld = nil }

    // composer
    func comp(_ on: Bool, focus: Bool = false) {
        if folded { if on && focus { foldBox(false) } else { return } }
        if compOpen != on { withAnimation(BX.ease(0.24)) { compOpen = on } }
        if on && focus { focusAsk += 1 }
        if on { coachShow() } else if pointState == "coach" { pointState = nil }
    }
    func drop() {
        if listening { listening = false; hearing = false; if let i = last { turns.remove(at: i) }; setState("breathing"); setStatus(""); boost = 1; orbScale = 1 }
        post(["type": 1])
    }
    var threadY: CGFloat = 0, restoreY: CGFloat?   // where the thread was scrolled: minimize, then restore, comes back there
    func foldBox(_ on: Bool) { if folded != on { if !on { restoreY = threadY }; withAnimation(BX.ease(0.3)) { folded = on } } }
    func coachShow() { if coachPending && pointState == nil { pointState = "coach" } }
    func coachDone() {
        if coachPending { coachPending = false; post(["pointCoached": 1]) }
        if pointState == "coach" { pointState = nil }
    }
    func send() {
        let t = ask.trimmingCharacters(in: .whitespaces)
        if working && liveCard({ if case .pick = $0 { return false }; if case .retry = $0 { return false }; return true }) == nil && !hasPick && liveCard({ if case .retry = $0 { return true }; return false }) == nil {
            setStatus("Finish or stop the current answer first"); return
        }
        if !t.isEmpty && !respond(t) { post(["send": t]) }
    }

    // MARK: window.ui

    func receive(_ call: String, _ v: Any) {
        let arg: Any = v is NSNull ? NSNull() : v
        switch call {
        case "agentDefaultAction": tapAction(defaultButton())
        case "movePending": removeParts { isCard($0) { if case .pick = $0 { return true }; if case .agent = $0 { return false }; return true } }; setStatus("Moving to an agent…", true)
        case "moveFailed": setStatus("Could not move")
        case "paused":
            removeParts { isCard($0) { if case .paused = $0 { return true }; return false } }
            if arg as? Bool == false { setStatus("Aurel resumed"); return }
            var t = Turn(); t.loose = true; t.parts = [.card(Card(kind: .paused))]; turns.append(t); setStatus("Paused")
        case "workerFailed":
            working = false; clockStop(); settle(); setStatus("Couldn’t start"); appendCard(Card(kind: .worker))
        case "agentDone": agentCard(arg as? [String: Any] ?? [:])
        case "agentCancelled":
            removeParts { isCard($0) { if case .agent = $0 { return true }; return false } }
            if !working && !listening && clockStart == nil && clockHeld == nil { setStatus("Ready") }
        case "agentStarted": agentStarted(arg as? [String: Any])
        case "agentSteered":
            working = false; listening = false; settle(); edit { $0.qLive = false; $0.qHear = false }; setState("breathing"); setStatus(""); clockStop()
            if let row = arg as? [String: Any] {
                let steer = row["steer"] as? [String: Any]
                agentSay(row, key: "told " + (row["id"] as? String ?? ""), "Told the \(row["title"] as? String ?? "") agent: " + ((steer?["text"] as? String) ?? (steer?["ack"] as? String) ?? "Got it"))
            } else if let s = arg as? String { agentSay(nil, key: "told ", s) }
        case "agentCount":
            if let n = arg as? Int { agents = n; agentsAttention = false }
            else if let d = arg as? [String: Any] { agents = d["count"] as? Int ?? 0; agentsAttention = d["attention"] as? Bool ?? false }
        case "agentEscape":
            if let c = liveCard({ if case .agent = $0 { return true }; return false }), case .agent(_, _, _, _, _, let acts, _, _) = c.kind, let esc = acts.first(where: { $0.esc }) { post(esc.msg); removeParts { $0.id == c.id } }
            else { post(["agentGone": true]) }
        case "selected":
            let t = (arg as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty, last != nil else { return }
            edit { $0.parts.insert(.sel(UUID(), "Selected: “" + t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression) + "”"), at: 0) }
        case "rewrite":
            guard let a = arg as? [Any], a.count >= 3, let draft = a[0] as? String, let mode = a[1] as? String else { return }
            let editable = a[2] as? Bool ?? false
            edit { $0.aKind = "draft" }
            removeParts { if case .rewrite = $0 { return true }; return false }
            let actions: [(String, String)] = ["replace": [("Replace", "replace"), ("Try again", "retry"), ("Copy", "copy")], "delete": [("Delete", "replace"), ("Try again", "retry")],
                                               "draft": editable ? [("Insert", "replace"), ("Copy", "copy"), ("Try again", "retry")] : [("Copy", "copy"), ("Try again", "retry")]][mode] ?? []
            edit { t in
                let bar = Part.rewrite(UUID(), mode, actions, draft, editable)
                if let k = t.parts.firstIndex(where: { if case .clock = $0 { return true }; return false }) { t.parts.insert(bar, at: k) } else { t.parts.append(bar) }
            }
        case "replaced":
            let ok = arg as? Bool ?? false
            edit { t in
                guard let k = t.parts.firstIndex(where: { if case .rewrite = $0 { return true }; return false }), case .rewrite(let id, let mode, let acts, let draft, _) = t.parts[k] else { return }
                t.parts.removeAll { if case .note = $0 { return true }; return false }
                let draftMode = mode == "draft"
                let note = ok ? (["delete": "Deleted", "draft": "Inserted"][mode] ?? "Replaced") : draftMode ? "Your cursor moved. Click where it goes and ask again, or use Copy." : "Selection changed or this app cannot replace it. Select the text and ask again, or use Copy."
                t.parts[k] = .rewrite(id, mode, acts, draft, false)
                t.parts.insert(.note(UUID(), note), at: k + 1)
            }
        case "mini": miniUpdate(arg as? [String: Any] ?? [:])
        case "point": point(arg as? [String: Any])
        case "pointCoach": coachPending = true; if arg as? Bool == true { comp(true) } else if compOpen { coachShow() }
        case "finished": clockStop(); miniFinish(false); unstream()
        case "dictate": dictateMode(arg as? Bool ?? false)
        case "locked": locked = arg as? Bool ?? false
        case "visible": visible = arg as? Bool ?? true; if !visible { clockStop(); miniClear() }
        case "limit": screenHeight = CGFloat((arg as? NSNumber)?.doubleValue ?? 10000); if let h = held { held = min(h, screenHeight) }
        case "reset": miniClear(); clockStop(); turns = []; threadMax = 420; held = nil; again = false; popToken += 1
        case "quietListen": hf = arg as? Bool ?? false
        case "listen": listen(arg)
        case "level":
            let v = min(1, max(0, (arg as? NSNumber)?.doubleValue ?? 0))
            boost = 0.5 + v * 2.5; orbScale = 1 + v * 0.1
            let w = sqrt(max(0, v - 0.02) / 0.98)
            wave = Array(wave.dropFirst()) + [3 + w * 23]
        case "words":
            let w = arg as? String ?? ""
            edit { $0.q = w; $0.qEmpty = w.trimmingCharacters(in: .whitespaces).isEmpty }
        case "think":
            clockBegin(); listening = false; hearing = false; working = true; boost = 1; orbScale = 1; setState("solving")
            edit { $0.qLive = false; $0.qHear = false }; setStatus("Thinking…", true)
        case "finishing":
            listening = false; boost = 1; orbScale = 1; locked = false; hearing = false; setState("solving")
            setPill("finishing", arg as? String ?? "")
        case "dictated": dictated(arg as? [String: Any] ?? [:])
        case "learned":
            let word = arg as? String ?? ""
            setPill("said", "Learned “\(word)”", ok: true)
            dnButtons = [("Undo", { [weak self] in self?.post(["learnedUndo": true]); self?.dnButtons = [] })]
        case "line": line(arg as? String ?? "")
        case "msg": msg(arg as? String ?? "")
        case "stopped": stopped(arg as? String ?? "")
        case "hover":
            hover = arg as? Bool ?? false
            if hover { comp(true) } else if ask.isEmpty && !askFocused { comp(false) }
        case "compose": let on = arg as? Bool ?? false; comp(on, focus: on)
        case "draft": ask = arg as? String ?? ""; comp(true, focus: true)
        case "tap": if let p = arg as? [NSNumber], p.count == 2 { tap(CGPoint(x: p[0].doubleValue, y: p[1].doubleValue)) }
        case "size": threadMax = CGFloat((arg as? NSNumber)?.doubleValue ?? 420)
        case "hold": hold(CGFloat((arg as? NSNumber)?.doubleValue ?? 300))
        case "resizeDone": held = nil
        case "pickHear": pickHear(arg as? String)
        case "respond": _ = respond(arg as? String ?? "")
        case "notice": setStatus(arg as? String ?? "", true)
        case "ask": ask(arg as? [Any] ?? [])
        case "pick": pick(arg as? [String: Any] ?? [:])
        case "mode": safeOff = !(arg as? Bool ?? true)
        case "models":
            let d = arg as? [String: Any] ?? [:]
            models = d["list"] as? [String] ?? []; modelPick = d["pick"] as? String ?? ""
        case "copied":
            setStatus("Copied to clipboard")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { if self.status == "Copied to clipboard" { self.setStatus("") } }
        default: break
        }
        fit()
    }
    var askFocused = false
    func modelName(_ v: String) -> String {
        ["cheapest": "Cheapest", "balanced": "Balanced", "capable": "Most capable"][v] ?? (["haiku", "sonnet", "opus"].contains(v) ? v.prefix(1).uppercased() + v.dropFirst() : v)
    }

    func listen(_ mode: Any) {
        hf = false
        let keep = mode as? Bool == true, dict = mode as? String == "dict"
        dictateMode(dict)
        miniClear(); clockStop()
        removeParts { if case .rewrite = $0 { return true }; return self.isCard($0) { if case .paused = $0 { return true }; if case .worker = $0 { return true }; return false } }
        hover = false; listening = !keep; hearing = listening; working = false
        if keep { ask = "" } else { comp(false) }
        if !turns.isEmpty { again = true }
        if !dict { for i in turns.indices { turns[i].old = true } }
        while turns.count > 5 { turns.removeFirst() }
        var t = Turn(); t.dict = dict; t.qHear = !keep
        t.parts = [.q(UUID()), .steps(UUID()), .answer(UUID())]
        if !dictate, pointMarked, let img = pointThumb { t.parts.insert(.shot(UUID(), img), at: 0) }
        turns.append(t); atBottom = true; clockFinal = nil
        setState("listening"); boost = 1; setStatus("Listening…", true)
    }
    func dictateMode(_ on: Bool) {
        foldBox(false)
        dictate = on; locked = false; hearing = false
        turns.removeAll { $0.dict }
        wave = Array(repeating: 3, count: 9); setPill("")
    }
    func setPill(_ state: String, _ s: String = "", ok: Bool = false) { pill = state; dn = s; dnTick = ok; dnButtons = [] }
    func dictated(_ d: [String: Any]) {
        listening = false; boost = 1; orbScale = 1; locked = false; hearing = false; setState("breathing")
        if let text = d["text"] as? String, !text.isEmpty { setPill("said", text, ok: d["ok"] as? Bool ?? false) } else { setPill("done", "Inserted") }
        if let words = d["words"] as? String, !words.isEmpty {
            let k = dnButtons.count
            dnButtons.append(("Copy", { [weak self] in
                guard let self else { return }
                post(["copy": words]); if dnButtons.indices.contains(k) { dnButtons[k].0 = "Copied" }
            }))
        }
        if d["history"] as? Bool == true { dnButtons.append(("History", { [weak self] in self?.post(["dictationHistory": true]) })) }
    }

    func line(_ l: String) {
        guard let tag = l.first else { return }
        let s = l.count > 2 ? String(l.dropFirst(2)) : ""
        if tag != "…" && tag != "✓" { unstream() }
        switch tag {
        case "…":
            guard let i = last, turns[i].aAnswer == nil else { break }
            clockBegin()
            if s.isEmpty { unstream(); break }
            var text = s.replacingOccurrences(of: "\u{2028}", with: "\n")
            if let r = text.range(of: #"\S+$"#, options: .regularExpression) { text.removeSubrange(r) }   // its last word may still be arriving
            let keep = turns[i].aKind == "streaming"
            setAnswer(i, shutAnswer(text), keep: keep, streaming: true); turns[i].aKind = "streaming"
        case "▣": if let j = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any] { miniUpdate(j) }
        case "@": miniPoint(s)
        case "·": setStatus(s, true)
        case "▸":
            clockBegin(); settle()
            edit { t in
                let verb = { (x: String) in String(x.split(whereSeparator: { $0 == " " || $0 == "→" }).first ?? "") }
                if let k = t.steps.indices.last, verb(t.steps[k].text) == verb(s) { t.steps[k].text = s; t.steps[k].state = "live" }
                else {
                    t.steps.append(Step(text: s, state: "live"))
                    while t.steps.count > 4 { t.steps.removeFirst(); t.more += 1 }   // long tasks: a quiet count, not a wall of steps
                }
            }
            setStatus(s, true)
            setState(s.range(of: #"^(Searching|Reading|Looking|Taking|Checking|Finding|Waiting)"#, options: .regularExpression) != nil ? "searching"
                     : s.range(of: #"^(Moving|Opening|Using|Clicking|Scrolling|Pressing|Dragging|Typing)"#, options: .regularExpression) != nil ? "working" : "connecting")
        case "✓":
            miniFinish(); clockStop(); working = false; settle()
            edit { $0.qLive = false }; setStatus("")
            let bare = { (x: String) in x.trimmingCharacters(in: .whitespaces.union(.punctuationCharacters)).lowercased() }
            edit { t in if t.steps.count == 1, t.more == 0, bare(t.steps[0].text) == bare(s) { t.steps = [] } }   // "Opened Muse." once, not as its own step too
            if let i = last, !turns[i].loose {
                let shown = turns[i].aKind == "streaming"
                if shown { turns[i].aKind = "normal" }
                turns[i].aAnswer = s
                if turns[i].aKind != "draft" { setAnswer(i, s, keep: shown) } else { turns[i].aText = s }
            }
            setState("breathing")
            for i in turns.indices { turns[i].redo = false }
            if let i = last, !turns[i].qEmpty, !turns[i].q.trimmingCharacters(in: .whitespaces).isEmpty, turns[i].parts.contains(where: { if case .clock = $0 { return true }; return false }),
               !turns[i].parts.contains(where: { if case .rewrite = $0 { return true }; return false }) { turns[i].redo = true }   // the rewrite bar has its own Try again
        case "✎":
            if let j = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [[String: Any]], !j.isEmpty, let i = last {
                let items = j.map { MemItem(c: $0["c"] as? String ?? "", label: $0["label"] as? String ?? "", t: $0["t"] as? String ?? "", add: $0["add"] as? Bool ?? false) }
                let part = Part.mem(UUID(), items)
                if let k = turns[i].parts.firstIndex(where: { if case .answer = $0 { return true }; return false }) { turns[i].parts.insert(part, at: k + 1) } else { turns[i].parts.append(part) }
            }
        case "i":
            guard let i = last else { break }
            let learned = s.hasPrefix("Learned: "), id = UUID()
            turns[i].parts.append(.tip(id, learned ? String(s.dropFirst(9)) : s, learned))
            DispatchQueue.main.asyncAfter(deadline: .now() + 9) { self.goneTip(id) }   // never sticks around
        default: break
        }
        if atBottom { scrollTo?() }
    }
    func answerID(_ i: Int) -> UUID? { turns[i].parts.first { if case .answer = $0 { return true }; return false }?.id }
    func setAnswer(_ i: Int, _ text: String, keep: Bool, streaming: Bool = false) {
        turns[i].aText = text
        let blocks = streaming ? trimUnworded(parseMarkdown(text)) : parseMarkdown(text)
        turns[i].aBlocks = blocks
        turns[i].reveal.update(answerWords(blocks), keep: keep)
    }
    func goneTip(_ id: UUID) {
        edit { _ in }
        for i in turns.indices { for j in turns[i].parts.indices { if case .tip(let tid, let s, let l) = turns[i].parts[j], tid == id { turns[i].parts[j] = .tip(tid, "\u{0}" + s, l) } } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.removeParts { $0.id == id } }
    }

    func msg(_ s: String) {
        if dictate { return dictated(["text": s]) }
        miniFinish(false); clockStop(); listening = false; working = false; settle(); edit { $0.qLive = false }; setState("breathing"); setStatus("")
        hearing = false; boost = 1; orbScale = 1
        if let i = last, turns[i].qEmpty, !turns[i].loose { turns.remove(at: i); setStatus(s) }
        else { edit { $0.aKind = "cancel"; $0.aText = s; $0.aBlocks = [] } }
    }
    func stopped(_ s: String) {
        miniClear(); clockStop(); listening = false; hearing = false; working = false
        removeParts { p in if case .card = p { return true }; if case .rewrite = p { return true }; return false }
        edit { t in for k in t.steps.indices where t.steps[k].state == "live" { t.steps[k].state = "cut" } }
        setState("breathing"); setStatus(""); boost = 1; orbScale = 1
        guard let i = last, !turns[i].loose, !turns[i].qEmpty else { if let i = last, !turns[i].loose { turns.remove(at: i) }; setStatus(s); return }
        turns[i].qLive = false; turns[i].aKind = "stopped"; turns[i].aText = s; turns[i].aBlocks = []
    }
    func respond(_ text: String) -> Bool {
        if let c = liveCard({ if case .pick = $0 { return true }; return false }) {   // a choices card: the main box works like its "Something else" field
            pickHear(nil); ask = ""; pickDone(c.id, -1, "Got it", own: String(text.prefix(300))); return true
        }
        guard let c = liveCard({ if case .retry = $0 { return true }; return false }) else { return false }
        var t = text.lowercased().replacingOccurrences(of: #"[.!?,]+"#, with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: #"^\s*(?:um+|uh+|okay|ok|yeah|so)\s+"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\s+please\s*$"#, with: "", options: .regularExpression).replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        let value = ["retry", "try again", "yes"].contains(t) ? "r" : ["not now", "no", "cancel"].contains(t) ? "n" : ""
        if !value.isEmpty { ask = ""; answerRetry(c.id, value) } else { ask = text; setStatus("Say “Retry” or “Not now”", true) }
        return true
    }
    func ask(_ a: [Any]) {
        let q = a.count > 0 ? a[0] as? String ?? "" : "", cmd = a.count > 1 ? a[1] as? String ?? "" : ""
        let retry = a.count > 2 && !((a[2] as? String ?? "").isEmpty) && (a[2] as? Bool) != false, details = a.count > 3 ? a[3] as? String : nil
        removeParts { isCard($0) { if case .approval = $0 { return true }; if case .retry = $0 { return true }; if case .paused = $0 { return true }; if case .worker = $0 { return true }; if case .agent = $0 { return true }; return false } }
        unpin(); unstream()
        let c = Card(kind: retry ? .retry(q: q, p: cmd, details: (details?.isEmpty ?? true) ? nil : details) : .approval(q: q, cmd: cmd))
        appendCard(c); setState("breathing"); setStatus("Waiting for you"); clockHold()
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
            guard let live = self.liveCard({ _ in true }), live.id == c.id else { return }
            self.post(retry ? ["pick": "n"] : ["allow": false]); self.clockGo(); self.removeParts { $0.id == c.id }
            self.setStatus(retry ? "Offer expired" : "Approval expired", true); self.setState("solving")
        }
    }
    func answerApproval(_ id: UUID, _ ok: Bool) {
        guard liveCard({ _ in true }) != nil else { return }
        post(["allow": ok]); clockGo(); setStatus(ok ? "Allowed" : "Not allowed", true); setState("solving"); goneCard(id)
    }
    func answerRetry(_ id: UUID, _ v: String) {
        post(["pick": v]); clockGo(); setStatus(v == "r" ? "Trying again" : "Not now", true); setState("solving"); goneCard(id)
    }
    func pick(_ d: [String: Any]) {
        removeParts { isCard($0) { if case .pick = $0 { return true }; return false } }; unstream()
        let opts = (d["options"] as? [[String: Any]] ?? []).map {
            PickOption(label: $0["label"] as? String ?? "", sub: $0["sub"] as? String ?? "", path: $0["path"] as? String ?? "", img: imageFromDataURL($0["img"] as? String) ?? ($0["img"] as? String).flatMap { NSImage(contentsOfFile: $0) }, kind: $0["kind"] as? String ?? "")
        }
        let pics = (d["options"] as? [[String: Any]] ?? []).contains { ($0["img"] as? String)?.isEmpty == false }
        let c = Card(kind: .pick(q: parseMarkdown(d["q"] as? String ?? ""), options: opts, pics: pics))
        appendCard(c); setState("breathing"); setStatus("Waiting for you"); clockHold()
        DispatchQueue.main.asyncAfter(deadline: .now() + 105) { self.pickDone(c.id, -1, "Pick expired") }   // the brain stops waiting at 110 s; pickDone skips a pick already answered
    }
    func pickDone(_ id: UUID, _ i: Int, _ s: String? = nil, own: String? = nil) {
        guard let c = liveCard({ if case .pick = $0 { return true }; return false }), c.id == id, case .pick(_, let options, _) = c.kind else { return }
        post(["pick": own.map { "=" + $0 } ?? (i < 0 ? "" : String(i))]); clockGo()
        if own != nil || i >= 0 { edit { $0.steps.append(Step(text: own.map { "You said: " + $0 } ?? "Picked " + options[i].label, state: "done")) } }
        setStatus(s ?? (i < 0 ? "None of these" : "Picked"), true); setState("solving"); goneCard(id)
    }
    func pickHear(_ w: String?) {
        guard let w else {
            guard turns.contains(where: { $0.parts.contains { if case .qReply = $0 { return true }; return false } }) else { return }
            removeParts { if case .qReply = $0 { return true }; return false }
            listening = false; hearing = false; boost = 1; orbScale = 1
            if let c = liveCard({ if case .pick = $0 { return true }; return false }) { mapCards { if $0.id == c.id { $0.hidden = false } }; setState("breathing"); setStatus("Waiting for you") }
            return
        }
        guard let c = liveCard({ if case .pick = $0 { return true }; return false }) else { return }
        let has = turns.contains { $0.parts.contains { if case .qReply = $0 { return true }; return false } }
        if !has && listening { ask = w; comp(true, focus: true); return }   // a hands-free follow-up already shows its own turn
        if !has {
            for i in turns.indices { if let k = turns[i].parts.firstIndex(where: { $0.id == c.id }) { turns[i].parts.insert(.qReply(UUID(), w, true), at: k) } }
            mapCards { if $0.id == c.id { $0.hidden = true } }; comp(false); listening = true; hearing = true; setState("listening"); setStatus("Listening…", true)
        } else {
            for i in turns.indices { for j in turns[i].parts.indices { if case .qReply(let id, _, _) = turns[i].parts[j] { turns[i].parts[j] = .qReply(id, w, true) } } }
        }
    }
    func agentStarted(_ row: [String: Any]?) {
        for i in turns.indices { for j in turns[i].parts.indices { if case .card(var c) = turns[i].parts[j], case .agent = c.kind { c.gone = true; turns[i].parts[j] = .card(c); let id = c.id; DispatchQueue.main.asyncAfter(deadline: .now() + 0.36) { self.removeParts { $0.id == id } } } } }
        working = false; listening = false; settle(); edit { $0.qLive = false; $0.qHear = false }; setState("breathing"); clockStop()
        let queued = row?["status"] as? String == "queued", key = queued ? "queued" : "started"
        setStatus(queued ? "Agent queued" : "Agent started")
        if let title = row?["title"] as? String, !title.isEmpty, visible, let i = last, !turns[i].loose, turns[i].aText.trimmingCharacters(in: .whitespaces).isEmpty || !turns[i].said.isEmpty {
            var named = turns[i].started[key] ?? []; named.append("“\(title)”"); turns[i].started[key] = named
            let list = ListFormatter.localizedString(byJoining: named), many = named.count > 1
            agentSay(row, key: key, queued ? (many ? "Queued agents for \(list). They start when others finish." : "Queued an agent for \(list). It starts when another one finishes.")
                                     : many ? "I started agents on \(list). I’ll ping you when they’re done." : "I started an agent on \(list). I’ll ping you when it’s done.")
        }
        if ask.isEmpty { comp(false) }
    }
    func agentSay(_ row: [String: Any]?, key: String, _ text: String) {
        edit { t in
            if let k = t.said.firstIndex(where: { $0.key == key }) { t.said[k].text = text } else { t.said.append((key, text)) }
            let all = t.said.map(\.text)
            t.aKind = "ack"; t.aOrb = row?["id"] != nil
            t.aText = all.map { all.count > 1 && !($0.hasSuffix(".") || $0.hasSuffix("!") || $0.hasSuffix("?") || $0.hasSuffix("…")) ? $0 + "." : $0 }.joined(separator: " ")
            t.aBlocks = []
        }
    }
    func agentCard(_ row: [String: Any]) {
        removeParts { isCard($0) { if case .agent = $0 { return true }; return false } }
        let answer = (row["result"] as? String ?? "").replacingOccurrences(of: #"\[agent-result\b[\s\S]*$"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        let said = answer.isEmpty ? (row["summary"] as? String ?? "Done") : answer
        let id = row["id"] as? String ?? "", things = agentMade(row, said: said), missing = !(row["missingConnector"] as? String ?? "").isEmpty   // the connector it needs, by name
        var acts: [KeyAction] = []
        if !things.isEmpty && !missing { acts.append(KeyAction(label: "Details", key: nil, go: false, esc: false, msg: ["agentOpen": id])) }
        acts.append(KeyAction(label: "Later", key: "esc", go: false, esc: true, msg: ["agentLater": id]))
        if missing { acts.append(KeyAction(label: "Connect in Claude", key: "↩", go: true, esc: false, msg: ["agentConnect": id])) }
        else if let first = things.first { acts.append(KeyAction(label: "Open", key: "↩", go: true, esc: false, msg: ["agentOpen": id, "target": first.url])) }
        else { acts.append(KeyAction(label: "Details", key: "↩", go: true, esc: false, msg: ["agentOpen": id])) }
        let cost = (row["cost"] as? NSNumber)?.doubleValue ?? 0
        let costText = cost > 0 ? "≈" + (cost < 1 ? String(format: cost < 0.1 ? "%.2f¢" : "%.1f¢", cost * 100) : String(format: "$%.2f", cost)) + " at API prices" : nil
        edit { $0.parts.removeAll { if case .clock = $0 { return true }; return false } }   // the work moves to the agent; this box's timer has nothing to say
        appendCard(Card(kind: .agent(eyebrow: missing ? "Agent needs a connector" : "Agent done", title: row["title"] as? String ?? "", answer: parseMarkdown(said),
                                     learned: row["learned"] as? String, made: things, actions: acts, cost: costText, id: id)))
        working = false; clockStop(); setState("breathing"); setStatus("Done")
    }
    func agentMade(_ row: [String: Any], said: String) -> [Made] {
        let kinds: [(String, String, [String])] = [
            (#"spreadsheet|\.(csv|xlsx?|numbers)$"#, "Spreadsheet", [rect(2, 2, 12, 12, 1.5), "M2 6h12M2 10h12M6 2v12"]),
            (#"presentation|\.(pptx?|key)$"#, "Presentation", [rect(1.5, 3, 13, 8.5, 1.5), "M8 11.5v2.5M5.5 14h5"]),
            (#"document|\.(docx?|md|txt|pages|rtf)$"#, "Document", ["M4 1.5h5l3 3v10H4z", "M6 8h4M6 10.5h4"]),
            (#"calendar|event"#, "Event", [rect(2, 3, 12, 11, 2), "M2 6.5h12M5.5 1.5v3M10.5 1.5v3"]),
            (#"mail|draft"#, "Message", [rect(1.5, 3, 13, 10, 2), "m2 4 6 5 6-5"]),
            (#"^/"#, "File", ["M4 1.5h5l3 3v10H4z", "M9 1.5v3h3"])]
        let link = ["M7 9a3 3 0 0 0 4.2 0l2-2a3 3 0 0 0-4.2-4.2l-.8.8M9 7a3 3 0 0 0-4.2 0l-2 2a3 3 0 0 0 4.2 4.2l.8-.8"]
        let list = (row["made"] as? [[String: Any]]).flatMap { $0.isEmpty ? nil : $0 } ?? (row["links"] as? [String] ?? []).map { ["url": $0, "title": ""] }
        var out: [Made] = []
        for m in list {
            let url = m["url"] as? String ?? "", title = m["title"] as? String ?? "", path = url.components(separatedBy: CharacterSet(charactersIn: "?#")).first ?? url
            let k = kinds.first { (((m["type"] as? String) ?? "") + " " + path).range(of: $0.0, options: [.regularExpression, .caseInsensitive]) != nil }
            if k == nil && title.isEmpty && said.contains(url) { continue }   // an untitled page the answer already links to is a source
            let host = URL(string: url)?.host?.replacingOccurrences(of: #"^www\."#, with: "", options: .regularExpression) ?? "", file = url.hasPrefix("/")
            out.append(Made(url: url, title: !title.isEmpty ? title : (file ? (url as NSString).lastPathComponent : host.isEmpty ? url : host), sub: (k?.1 ?? "Link") + " · " + (file ? "In its folder" : host), icon: k?.2 ?? link))
            if out.count == 3 { break }
        }
        return out
    }

    // mini screen: a live picture of the window being worked on, drawn natively under this view
    func miniUpdate(_ m: [String: Any]) {
        guard let i = last, (m["pid"] as? Int ?? 0) > 0, (m["windowID"] as? String)?.allSatisfy(\.isNumber) == true, let f = m["windowFrame"] as? [NSNumber], f.count == 4, f[2].doubleValue > 0, f[3].doubleValue > 0 else { return }
        miniEnd = false
        if turns[i].mini == nil {
            turns[i].mini = MiniState()
            if let k = turns[i].parts.firstIndex(where: { if case .steps = $0 { return true }; return false }) { turns[i].parts.insert(.mini(UUID()), at: k) }
        }
        miniTarget = m
        turns[i].mini?.done = false; turns[i].mini?.live = m["live"] as? Bool ?? false
        turns[i].mini?.title = (m["window"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (m["app"] as? String) ?? "Window"
        turns[i].mini?.icon = imageFromDataURL(m["icon"] as? String)
        turns[i].mini?.tag = (m["app"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Working"
        let shown = m["shown"] as? Bool != false
        miniTimer?.cancel()
        let apply = DispatchWorkItem { [weak self] in
            guard let self, let i = self.last, self.turns[i].mini != nil, !self.miniEnd else { return }
            withAnimation(BX.ease(0.42)) { self.turns[i].mini?.on = shown; self.turns[i].preview = shown }
        }
        let wait = 0.5 - Date().timeIntervalSince(turns[i].mini?.born ?? Date())   // a task done in under half a second never flashes a mini screen
        if !shown || wait <= 0 { apply.perform() } else { miniTimer = apply; DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: apply) }
    }
    var miniTarget: [String: Any]?
    func miniClear() {
        miniTimer?.cancel(); miniEnd = false
        for i in turns.indices where turns[i].mini != nil { turns[i].mini = nil; turns[i].preview = false; turns[i].parts.removeAll { if case .mini = $0 { return true }; return false } }
        miniTarget = nil; onMini(["rect": [0, 0, 0, 0], "clip": [0, 0, 0, 0]])
    }
    func miniFinish(_ ok: Bool = true) {
        guard let i = turns.lastIndex(where: { $0.mini != nil }), !miniEnd else { return }
        if turns[i].mini?.on != true { return miniClear() }   // finished before it ever showed
        turns[i].mini?.done = ok; if ok { turns[i].mini?.tag = "Done" }
        miniEnd = true; unpin()
    }
    func unpin() { for i in turns.indices { turns[i].preview = false } }
    func miniPoint(_ s: String) {
        guard let m = miniTarget, let i = last, turns[i].mini?.on == true, let r = rects["mini-view"] else { return }
        let p = s.split(separator: " ").compactMap { Double($0) }, f = (m["windowFrame"] as? [NSNumber] ?? []).map(\.doubleValue)
        guard p.count == 2, f.count == 4, p[0] >= f[0], p[1] >= f[1], p[0] <= f[0] + f[2], p[1] <= f[1] + f[3] else { return }
        let scale = min(r.width / f[2], r.height / f[3])
        let action = m["action"] as? String ?? "", dir = m["direction"] as? String ?? ""
        let id = UUID()
        turns[i].mini?.point = (action == "scroll" ? "scroll" : action == "type" ? "type" : "click", (r.width - f[2] * scale) / 2 + (p[0] - f[0]) * scale, (r.height - f[3] * scale) / 2 + (p[1] - f[1]) * scale,
                                ["left": -14, "right": 14][dir] ?? 0, ["up": -14, "down": 14][dir] ?? 0, id)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.85) { if self.turns.indices.contains(i), self.turns[i].mini?.point?.id == id { self.turns[i].mini?.point = nil } }
    }
    func reportMini() {   // the page's miniRect: where the picture goes, clipped to the thread
        guard let v = rects["mini-view"], let t = rects["thread"], let on = turns.last(where: { $0.mini != nil })?.mini?.on else { onMini(["rect": [0, 0, 0, 0], "clip": [0, 0, 0, 0]]); return }
        let c = v.intersection(t)
        onMini(["rect": [v.minX, v.minY, v.width, v.height], "clip": c.isNull ? [0, 0, 0, 0] : [c.minX, c.minY, c.width, c.height], "opacity": on ? 1 : 0])
    }

    func point(_ v: [String: Any]?) {
        let active = v?["active"] as? Bool ?? false, marked = v?["marked"] as? Bool ?? false, was = status
        pointActive = active; pointMarked = marked
        if let t = v?["thumb"] as? String { pointThumb = t.isEmpty ? nil : imageFromDataURL(t) }
        if !marked { pointThumb = nil }
        if active || marked { coachDone() }
        pointState = active || marked ? (active ? "on" : "marked") : nil
        pointHint = active && !marked ? "Click, circle or scribble on anything, then ask" : ""
        if active { setStatus("Pointing…"); comp(true, focus: true) }
        else if marked { setStatus("Marked"); if v?["picked"] as? Bool == true { comp(true, focus: true) } }
        else if was == "Pointing…" || was == "Marked" { setStatus("") }
    }

    func hold(_ h: CGFloat) {   // pin the panel to the pointer while an edge is being dragged
        let h = min(h, screenHeight)
        let card = rects["card"]?.height ?? h, thread = rects["thread"]?.height ?? 0
        let chrome = card - thread
        threadMax = max(60, h - chrome); held = h
        post(["boxH": threadMax])
    }

    // MARK: native pointer and clicks (the page's ui.pointer and ui.tap)

    func pointer(_ p: CGPoint?, overX: Bool) -> Bool {
        var now: Set<String> = []
        if overX { now = ["x"] }
        else if let p { for t in targets where t.rect.contains(p) { now.insert(t.id) } }
        if now != hot { hot = now }
        bodyHot = p != nil || overX
        if overX { return true }
        guard let p else { return false }
        return targets.filter { $0.rect.contains(p) }.min { $0.rect.width * $0.rect.height < $1.rect.width * $1.rect.height }?.hand ?? false
    }
    func tap(_ p: CGPoint) {
        let under = targets.filter { $0.rect.contains(p) }.sorted { $0.rect.width * $0.rect.height < $1.rect.width * $1.rect.height }
        for t in under { if case .link(let open) = t.kind, open(CGPoint(x: p.x - t.rect.minX, y: p.y - t.rect.minY)) { return } }
        if let t = under.first(where: { if case .field = $0.kind { return true }; return false }), case .field(let f) = t.kind { return f() }
        if let t = under.first(where: { if case .button = $0.kind { return true }; return false }), case .button(let f) = t.kind { return f() }
        if folded || dictate { return }
        if under.contains(where: { if case .mode = $0.kind { return true }; return false }) { return enableSafeMode() }
        if pickRow { withAnimation(BX.ease(0.3)) { pickRow = false } }
        if let t = under.first(where: { if case .tipOff = $0.kind { return true }; return false }) {
            post(["off": "tips"]); removeParts { $0.id.uuidString == t.id.dropFirst(4) }; setStatus("Tips off · Settings → General turns them back on"); return
        }
        if let t = under.first(where: { if case .tip = $0.kind { return true }; return false }) { removeParts { $0.id.uuidString == t.id.dropFirst(4) }; return }
        let answer = under.first { if case .answer = $0.kind { return true }; return false }, q = under.first { if case .question = $0.kind { return true }; return false }
        drop()
        if let a = answer, let id = UUID(uuidString: String(a.id.dropFirst(2))), let t = turns.first(where: { $0.parts.contains { $0.id == id } }), let text = t.aAnswer, t.aKind != "stopped", t.aKind != "cancel" { post(["copy": text]) }
        else { if let q, let id = UUID(uuidString: String(q.id.dropFirst(2))), let t = turns.first(where: { $0.parts.contains { $0.id == id } }) { ask = t.q }; comp(true, focus: true) }
    }
    func tapAction(_ a: KeyAction?) {
        guard let a, let c = liveCard({ if case .agent = $0 { return true }; return false }) else { return }
        post(a.msg); removeParts { $0.id == c.id }
    }
    func enableSafeMode() { setStatus("Safe mode on · Settings turns it off"); post(["safe": true]) }
}

// MARK: - Views


struct BoxView: View {
    @ObservedObject var m: BoxModel
    var body: some View {
        VStack(spacing: 0) {
            Card_(m: m)
                .fixedSize(horizontal: m.dictate, vertical: true)
                .frame(maxWidth: m.dictate ? nil : .infinity)
                .background(GeometryReader { g in Color.clear.preference(key: RectKey.self, value: ["card": g.frame(in: .named("box"))]) })
            Spacer(minLength: 0)
        }
        .coordinateSpace(name: "box")
        .onPreferenceChange(TargetsKey.self) { m.targets = $0 }
        .onPreferenceChange(RectKey.self) { r in
            m.rects = r
            guard let card = r["card"] else { return }
            let size = m.dictate ? [card.width, card.height] : [card.height]
            if size != m.lastSize { m.lastSize = size; m.onSize(size) }
            m.post(["comp": !m.folded && m.compOpen ? card.height - (r["comp"]?.minY ?? card.height) + 4 : 0])
            m.reportMini()
        }
        .environment(\.colorScheme, .dark)
    }
}

private struct Card_: View {
    @ObservedObject var m: BoxModel
    @State private var popped = false
    var body: some View {
        Group {
            if m.dictate { Pill(m: m) }
            else {
                VStack(alignment: .leading, spacing: 0) {
                    Head(m: m)
                    if !m.folded {
                        Thread(m: m)
                        if m.held != nil { Spacer(minLength: 0) }
                        PointBar(m: m)
                        Composer(m: m)
                    }
                }
                .padding(m.folded ? EdgeInsets(top: 6, leading: 20, bottom: 6, trailing: 20) : EdgeInsets(top: 14, leading: 20, bottom: 18, trailing: 20))
                .frame(minHeight: m.held, maxHeight: m.screenHeight, alignment: .top)
                .overlay(alignment: .bottomTrailing) {
                    if !m.folded { Icon(paths: ["M11 4L4 11M11 8L8 11"], box: 12, stroke: 1.2, color: .white).frame(width: 12, height: 12).padding(4).opacity(m.bodyHot ? 0.45 : 0).animation(.linear(duration: 0.25), value: m.bodyHot) }
                }
            }
        }
        .scaleEffect(popped || m.again ? 1 : 0.94).offset(y: popped || m.again ? 0 : -6).opacity(popped || m.again ? 1 : 0)
        .onAppear { withAnimation(BX.spring(0.42)) { popped = true } }
        .onChange(of: m.popToken) { _, _ in popped = false; withAnimation(BX.spring(0.42)) { popped = true } }
    }
}

private struct Head: View {
    @ObservedObject var m: BoxModel
    var body: some View {
        HStack(spacing: 7) {
            OrbRep(state: m.orbState, size: 64, dpr: 2, running: m.visible, capped: true, boost: m.boost).frame(width: 44, height: 44).scaleEffect(m.orbScale).animation(BX.ease(0.35), value: m.orbScale)
                .padding(.leading, -4).report("orb").onAppear { }
            StatusLine(m: m).frame(minWidth: 64, maxWidth: .infinity, alignment: .leading)
            if m.agents > 0 && !m.folded {   // folded: only the orb, the status, fold and ×
                HStack(spacing: 6) {
                    PulseDot(color: m.agentsAttention ? BX.orange : BX.blue, period: 1.8)
                    Text("\(m.agents) agent\(m.agents == 1 ? "" : "s")").font(cssFont(11, 500)).monospacedDigit().foregroundColor(m.hot.contains("agents") ? .white : Color(hex: 0xd1d1d6)).lineLimit(1)
                }
                .padding(.leading, 8).padding(.trailing, 9).frame(height: 22)
                .background(Capsule().fill(Color.white(m.hot.contains("agents") ? 0.12 : 0.07))).overlay(Capsule().strokeBorder(Color.white(0.12), lineWidth: 0.5))
                .fixedSize().boxTarget("agents", kind: .button { m.post(["agents": true]) }).help(m.agentsAttention ? "An agent needs you" : "Open Agents")
                .transition(.opacity.combined(with: .offset(y: 5)))
            }
            if m.safeOff && !m.folded {
                HStack(spacing: 5) { Circle().fill(BX.orange).frame(width: 5, height: 5); Text("Full access").font(cssFont(11, 500)).foregroundColor(Color(hex: 0xffb340)) }
                    .padding(.horizontal, 9).frame(height: 22)
                    .background(Capsule().fill(Color.rgba(255, 159, 10, m.hot.contains("mode") ? 0.16 : 0.13))).overlay(Capsule().strokeBorder(Color.rgba(255, 159, 10, 0.32), lineWidth: 0.5))
                    .scaleEffect(m.hot.contains("mode") ? 1.05 : 1).animation(BX.spring(0.3), value: m.hot.contains("mode"))
                    .fixedSize().boxTarget("mode", kind: .mode).help("Safe mode is off. Click to turn it on.")
            }
            if !m.folded || m.bodyHot {
                Icon(paths: ["M3.5 8h9"], box: 16, stroke: 2, color: m.hot.contains("fold") ? BX.fg : BX.fg2).frame(width: 10, height: 10).frame(width: 26, height: 18)
                    .contentShape(Rectangle()).boxTarget("fold", kind: .button { m.foldBox(!m.folded) }).help(m.folded ? "Expand answer" : "Minimize answer")
            }
            let x = m.hot.contains("x")
            Icon(paths: ["M1 1L9 9M9 1L1 9"], box: 10, stroke: 1.6, color: .white(x ? 1 : 0.75)).frame(width: 8, height: 8).rotationEffect(.degrees(x ? 90 : 0))
                .frame(width: 22, height: 22).glassEffect(x ? .regular.tint(.white(0.15)) : .regular, in: .circle)
                .scaleEffect(x ? 1.28 : 1).animation(BX.spring(0.45), value: x)
        }
        .frame(height: 44)
    }
}
private struct StatusLine: View {   // #status: one line, the live kind shimmering
    @ObservedObject var m: BoxModel
    @State private var shown = false
    var body: some View {
        let s = m.status.isEmpty && m.folded ? "Done" : m.status
        Group {
            if m.statusLive && m.visible && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {   // a hidden box's shimmer still ticks every frame
                TimelineView(.animation) { t in
                    let p = t.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.5) / 1.5
                    Text(s).font(cssFont(12.5)).lineLimit(1).truncationMode(.tail)
                        .foregroundStyle(LinearGradient(stops: [.init(color: BX.fg2, location: 0), .init(color: .white, location: 0.225), .init(color: BX.fg2, location: 0.45)],
                                                        startPoint: UnitPoint(x: 1 - 2 * p, y: 0), endPoint: UnitPoint(x: 3 - 2 * p, y: 0)))
                }
            } else { Text(s).font(cssFont(12.5)).foregroundColor(m.statusLive ? BX.fg : BX.fg2).lineLimit(1).truncationMode(.tail) }
        }
        .frame(height: 22).id(m.statusToken)
        .transition(.opacity.combined(with: .offset(y: 5)))
        .animation(BX.ease(0.35), value: m.statusToken)
    }
}
private struct PulseDot: View {   // a 6 px dot with a glow, fading to .3 and back
    let color: Color; var period = 1.2; var size: CGFloat = 6
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)) { t in
            let p = t.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
            Circle().fill(color).frame(width: size, height: size).shadow(color: color.opacity(0.8), radius: 3).opacity(1 - 0.7 * (0.5 - 0.5 * cos(p * 2 * .pi)))
        }
    }
}

private struct Thread: View {
    @ObservedObject var m: BoxModel
    @State private var contentH: CGFloat = 0
    @State private var userScrolling = false
    @State private var position = ScrollPosition()
    var body: some View {
        let shownH = min(contentH, m.threadMax, max(60, m.screenHeight - 140))
        if !m.turns.isEmpty {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(m.turns.enumerated()), id: \.element.id) { i, _ in
                            TurnView(m: m, i: i)
                                .padding(.top, m.turns[i].loose ? 0 : i == 0 ? 12 : 18)
                                .overlay(alignment: .top) { if i > 0 && !m.turns[i].loose { Rectangle().fill(Color.white(0.08)).frame(height: 0.5) } }
                                .padding(.top, i == 0 || m.turns[i].loose ? 0 : 18)
                        }
                        Color.clear.frame(height: 0).id("end")
                    }
                    .padding(.top, 2)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentH = $0 }
                }
                .onChange(of: contentH) { _, _ in if m.atBottom && !userScrolling { proxy.scrollTo("end", anchor: .bottom) } }   // after layout: new lines are in view, not the old bottom
                .frame(height: shownH)
                .scrollPosition($position)
                .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, y in m.threadY = y }
                // The user's own scroll decides whether new lines follow: back at the bottom they do, anywhere else they stay put.
                .onScrollPhaseChange { _, phase in userScrolling = phase == .interacting || phase == .decelerating || phase == .tracking }
                .onScrollGeometryChange(for: Bool.self) { $0.contentOffset.y + $0.containerSize.height >= $0.contentSize.height - 4 } action: { _, end in
                    if userScrolling { m.atBottom = end }
                }
                .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: min(1, 14 / max(1, min(contentH, m.threadMax))))], startPoint: .top, endPoint: .bottom))
                .report("thread")
                .onAppear {
                    if let y = m.restoreY { m.restoreY = nil; DispatchQueue.main.async { position.scrollTo(y: y) } }
                    m.scrollTo = { proxy.scrollTo("end", anchor: .bottom) }
                }
            }
        }
    }
}
private struct HeightKey: PreferenceKey { static var defaultValue: CGFloat = 0; static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() } }

private struct TurnView: View {
    @ObservedObject var m: BoxModel
    let i: Int
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if m.turns.indices.contains(i) { ForEach(m.turns[i].parts) { p in PartView(m: m, turn: i, part: p) } }
        }
        .transition(.opacity.combined(with: .offset(y: 5)))
    }
}

private struct PartView: View {
    @ObservedObject var m: BoxModel
    let turn: Int; let part: Part
    var body: some View {
        if m.turns.indices.contains(turn) {
            let t = m.turns[turn]
            switch part {
            case .shot(_, let img):
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                    .frame(maxWidth: t.shotBig ? 400 : 120, maxHeight: t.shotBig ? 220 : 72)
                    .clipShape(rr(10)).overlay(rr(10).strokeBorder(Color.white(0.12), lineWidth: 0.5))
                    .frame(maxWidth: .infinity, alignment: .trailing).padding(.bottom, 4)
                    .boxTarget("shot\(turn)", kind: .button { withAnimation(BX.ease(0.3)) { m.turns[turn].shotBig.toggle() } })
            case .sel(_, let s):
                Text(s).font(cssFont(11.5)).foregroundColor(BX.fg2).lineLimit(1).truncationMode(.tail).padding(.leading, 8)
                    .overlay(alignment: .leading) { Rectangle().fill(Color.rgba(10, 132, 255, 0.6)).frame(width: 2) }.padding(.bottom, 10)
            case .q(let id): Bubble(text: t.q, live: t.qLive, hear: t.qHear, empty: t.qEmpty).boxTarget("q:\(id.uuidString)", kind: .question)
            case .qReply(_, let w, _): Bubble(text: w, live: true, hear: true, empty: w.trimmingCharacters(in: .whitespaces).isEmpty).padding(.top, 14)
            case .mini: if let mini = t.mini { Mini(m: m, mini: mini) }
            case .steps: StepsView(steps: t.steps, more: t.more, preview: t.preview)
            case .answer(let id): AnswerPart(m: m, t: t).boxTarget("a:\(id.uuidString)", hand: false, kind: .answer)
            case .clock: ClockRow(m: m, redo: t.redo && !t.parts.contains { if case .rewrite = $0 { return true }; return false }, q: t.q, frozen: t.clock)
            case .card(let c): if !c.hidden { CardView(m: m, card: c) }
            case .mem(let id, let items): Receipt(m: m, id: id, items: items, open: t.memOpen.contains(id)) { if m.turns[turn].memOpen.contains(id) { m.turns[turn].memOpen.remove(id) } else { m.turns[turn].memOpen.insert(id) } }
            case .tip(let id, let s, let learned): TipView(id: id, text: s, learned: learned)
            case .rewrite(_, let mode, let actions, let draft, let editable): RewriteBar(m: m, mode: mode, actions: actions, draft: draft, editable: editable)
            case .note(_, let s): Text(s).font(cssFont(12)).foregroundColor(BX.fg2).padding(.top, 10).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct Bubble: View {   // .q: what you said, on the right
    let text: String; let live: Bool; let hear: Bool; let empty: Bool
    var body: some View {
        if !(empty && !hear) {
            HStack(spacing: 2) {
                Text(empty ? "Listening…" : text).font(cssFont(live ? 15 : 13.5)).foregroundColor(empty ? BX.fg2 : live ? .white : Color(hex: 0xe5e5ea)).lineHeight(live ? 15 : 13.5, 1.45)
                    .fixedSize(horizontal: false, vertical: true)
                if live && !empty { Caret() }
            }
            .padding(.vertical, 9).padding(.horizontal, 14)
            .background(UnevenRoundedRectangle(topLeadingRadius: 16, bottomLeadingRadius: 16, bottomTrailingRadius: 5, topTrailingRadius: 16, style: .circular).fill(Color.white(0.09)))
            .overlay(UnevenRoundedRectangle(topLeadingRadius: 16, bottomLeadingRadius: 16, bottomTrailingRadius: 5, topTrailingRadius: 16, style: .circular).strokeBorder(Color.white(0.12), lineWidth: 0.5))
            .containerRelativeFrame(.horizontal, alignment: .trailing) { w, _ in w * 0.8 }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .animation(BX.ease(0.3), value: live)
        }
    }
}
private struct Caret: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { t in Rectangle().fill(Color.white).frame(width: 1.5, height: 15).opacity(Int(t.date.timeIntervalSinceReferenceDate * 2) % 2 == 0 ? 1 : 0) }
            .padding(.leading, 2)
    }
}

private struct StepsView: View {
    let steps: [Step]; let more: Int; let preview: Bool
    var body: some View {
        if !steps.isEmpty {
            VStack(alignment: .leading, spacing: preview ? 4 : 6) {
                if more > 0 && !preview { Text("+\(more) earlier").font(cssFont(11)).foregroundColor(BX.fg2).padding(.leading, 12) }
                ForEach(steps) { s in
                    HStack(spacing: 7) {
                        Group {
                            if s.state == "live" { PulseDot(color: .white, period: 1, size: 5).shadow(radius: 0) }
                            else { Circle().fill(s.state == "done" ? BX.green : Color(hex: 0x636366)).frame(width: 5, height: 5) }
                        }
                        Text(s.text).font(cssFont(12)).foregroundColor(s.state == "live" ? BX.fg : BX.fg2).lineLimit(1).truncationMode(.tail)
                            .strikethrough(s.state == "cut", color: .white(0.2))
                    }
                    .frame(height: 16).transition(.opacity.combined(with: .offset(y: 5)))
                }
            }
            .animation(preview ? css(0.2, 0.8, 0.2, 1, 0.35) : BX.ease(0.35), value: steps.map(\.id))
            .frame(height: preview ? 56 : nil, alignment: .bottom).clipped()
            .mask(LinearGradient(stops: [.init(color: preview ? .clear : .black, location: 0), .init(color: .black, location: preview ? 20 / 56 : 0)], startPoint: .top, endPoint: .bottom))
            .padding(.top, preview ? 6 : 14)
        }
    }
}

private struct AnswerPart: View {
    @ObservedObject var m: BoxModel
    let t: Turn
    var body: some View {
        Group {
            switch t.aKind {
            case "cancel": if !t.aText.isEmpty { Text(t.aText).font(cssFont(12.5)).foregroundColor(BX.fg2).fixedSize(horizontal: false, vertical: true) }
            case "stopped":
                HStack(spacing: 8) {
                    rr(2).fill(BX.red).frame(width: 7, height: 7).shadow(color: .rgba(255, 69, 58, 0.6), radius: 4)
                    Text(t.aText).font(cssFont(12.5)).tracking(0.1).foregroundColor(BX.fg2)
                }.frame(height: 16)
            case "ack":
                HStack(alignment: .top, spacing: 7) {
                    if t.aOrb, let img = orbImage(orbFrame("breathing", 32, 0), size: 32, dpr: 2) { Image(decorative: img, scale: 2).resizable().frame(width: 24, height: 24) }
                    Text(t.aText).font(cssFont(15)).foregroundColor(t.old ? BX.fg2 : BX.fg).lineHeight(15, 1.6).fixedSize(horizontal: false, vertical: true)
                }
            case "draft": if !t.aText.isEmpty { Text(t.aText).font(cssFont(15)).foregroundColor(t.old ? BX.fg2 : BX.fg).lineHeight(15, 1.6).fixedSize(horizontal: false, vertical: true) }
            default:
                if !t.aBlocks.isEmpty {
                    AnswerView(blocks: t.aBlocks, style: AnswerStyle(color: t.old ? BX.fg2 : BX.fg), reveal: t.reveal) { m.post(["link": $0]) }
                }
            }
        }
        .padding(.top, t.aText.isEmpty && t.aBlocks.isEmpty ? 0 : 16)
    }
}

private struct ClockRow: View {   // .elapsed: the stopwatch, Listening dots, Try again
    @ObservedObject var m: BoxModel
    let redo: Bool; let q: String; let frozen: String?
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            TimelineView(.animation(minimumInterval: 1 / 30, paused: frozen != nil || m.clockStart == nil)) { tl in
                Text(frozen ?? m.clockText(CACurrentMediaTime())).font(cssFont(10.5)).monospacedDigit().foregroundColor(BX.fg2)
            }
            if m.hf { HfDots().padding(.leading, 8) }
            Spacer(minLength: 0)
            if redo {
                Text("Try again").font(cssFont(11, 500)).foregroundColor(m.hot.contains("redo") ? BX.fg : BX.fg2)
                    .boxTarget("redo", kind: .button { m.post(["send": "That's wrong, try again: \(q)\n(If it isn't clear what to change, ask me what was wrong.)"]); if let i = m.last { m.turns[i].redo = false } })
            }
        }
        .frame(height: 16).padding(.top, 16).help("Time Aurel spent working. Waiting for your pick or approval is not counted.")
    }
}
private struct HfDots: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20)) { t in
            HStack(spacing: 0) {
                Text("Listening")
                ForEach(0..<3, id: \.self) { i in
                    let p = (t.date.timeIntervalSinceReferenceDate - Double(i) * 0.2).truncatingRemainder(dividingBy: 1.4) / 1.4
                    Text(".").opacity(p < 0.25 ? p / 0.25 : p < 0.6 ? 1 : p < 0.85 ? 1 - (p - 0.6) / 0.25 : 0)
                }
            }.font(cssFont(10.5)).foregroundColor(BX.fg2)
        }
    }
}

private struct Mini: View {   // .mini: the live picture sits under this frame; the frame draws its ring, tag and hint
    @ObservedObject var m: BoxModel
    let mini: MiniState
    var body: some View {
        GeometryReader { g in
            let hot = m.hot.contains("mini")
            ZStack(alignment: .topLeading) {
                if !mini.live {
                    ZStack {
                        Color.rgba(18, 18, 20, 0.96)
                        RadialGradient(colors: [.white(0.07), .clear], center: .top, startRadius: 0, endRadius: g.size.width * 0.6)
                        VStack(spacing: 10) {
                            if let i = mini.icon { Image(nsImage: i).resizable().frame(width: 34, height: 34).shadow(color: .black(0.4), radius: 5, y: 4) }
                            Text(mini.title).font(cssFont(11.5)).foregroundColor(BX.fg2).lineLimit(1).frame(maxWidth: g.size.width * 0.8)
                        }
                        Sweep()
                    }.transition(.opacity)
                }
                HStack(spacing: 6) {
                    if mini.done { Icon(paths: ["M1 5l3 3 6-6"], box: 11, stroke: 1.5, color: BX.green).frame(width: 9, height: 7) } else { PulseDot(color: BX.blue) }
                    Text(mini.tag).lineLimit(1).truncationMode(.tail)
                }
                .font(cssFont(11, 500)).foregroundColor(BX.fg).padding(.horizontal, 9).frame(height: 22).frame(maxWidth: g.size.width - 90, alignment: .leading)
                .background(Capsule().fill(Color.rgba(20, 20, 22, 0.72))).overlay(Capsule().strokeBorder(Color.white(0.14), lineWidth: 0.5)).shadow(color: .black(0.3), radius: 4, y: 2)
                .fixedSize().padding(8)
                Text("Open ↗").font(cssFont(11, 500)).foregroundColor(BX.fg).padding(.horizontal, 9).frame(height: 22)
                    .background(Capsule().fill(Color.rgba(20, 20, 22, 0.72))).overlay(Capsule().strokeBorder(Color.white(0.14), lineWidth: 0.5))
                    .opacity(hot ? 1 : 0).offset(y: hot ? 0 : -3).animation(BX.ease(0.24), value: hot)
                    .frame(maxWidth: .infinity, alignment: .trailing).padding(8)
                if let p = mini.point { MiniPoint(kind: p.kind, dx: p.dx, dy: p.dy).position(x: p.x, y: p.y).id(p.id) }
            }
            .clipShape(rr(12))
            .overlay(rr(12).strokeBorder(Color.white(hot ? 0.3 : 0.14), lineWidth: hot ? 1 : 0.5))
            .shadow(color: .black(hot ? 0.36 : 0.28), radius: hot ? 14 : 12, y: hot ? 10 : 8)
            .report("mini-view")
            .boxTarget("mini", kind: .button { m.post(["miniOpen": true]); if m.miniEnd { m.miniClear() } })
        }
        .aspectRatio(1.6, contentMode: .fit)
        .padding(.top, mini.on ? 10 : 0)
        .frame(maxHeight: mini.on ? nil : 0, alignment: .top).clipped()
        .opacity(mini.on ? 1 : 0).scaleEffect(mini.on ? 1 : 0.96, anchor: .topLeading)
        .animation(BX.ease(0.42), value: mini.on)
    }
}
private struct Sweep: View {
    var body: some View {
        TimelineView(.animation) { t in
            GeometryReader { g in
                let p = t.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.8) / 1.8
                LinearGradient(stops: [.init(color: .clear, location: 0.3), .init(color: .white(0.05), location: 0.5), .init(color: .clear, location: 0.7)], startPoint: .leading, endPoint: .trailing)
                    .offset(x: (p * 2 - 1) * g.size.width)
            }
        }
    }
}
private struct MiniPoint: View {   // a click ripple, a scroll streak or a typing caret, where Aurel acted
    let kind: String; let dx: CGFloat; let dy: CGFloat
    @State private var t = false
    var body: some View {
        Group {
            switch kind {
            case "scroll": Capsule().fill(LinearGradient(colors: [.clear, .rgba(10, 132, 255, 0.45), .clear], startPoint: .top, endPoint: .bottom)).frame(width: 44, height: 16)
                .offset(x: t ? dx : 0, y: t ? dy : 0).opacity(t ? 0 : 1)
            case "type": rr(1).fill(BX.blue).frame(width: 2, height: 18).opacity(t ? 0 : 0.9)
            default: Circle().fill(Color.rgba(10, 132, 255, 0.18)).overlay(Circle().strokeBorder(Color.rgba(10, 132, 255, 0.8), lineWidth: 1)).shadow(color: .rgba(10, 132, 255, 0.3), radius: 7)
                .frame(width: 24, height: 24).scaleEffect(t ? 1.8 : 0.5).opacity(t ? 0 : 0.9)
            }
        }
        .onAppear { withAnimation(BX.ease(kind == "scroll" ? 0.65 : 0.8)) { t = true } }
    }
}

// MARK: Cards

private struct OkButton: View {   // .ok button, .pk .bar button, .rewrite button
    let id: String; let label: String; var go = false; var del = false; var disabled = false; @ObservedObject var m: BoxModel; let tap: () -> Void
    var body: some View {
        let hot = m.hot.contains(id) && !disabled
        Text(label).font(cssFont(12.5, 500)).foregroundColor(.white).frame(maxWidth: .infinity).frame(height: 28)
            .background(Capsule().fill(del ? Color(hex: 0xc92b24) : go ? BX.accent : Color.white(0.1)))
            .overlay { if !go && !del { Capsule().strokeBorder(Color.white(0.16), lineWidth: 0.5) } }
            .opacity(disabled ? 0.45 : 1).scaleEffect(hot ? 1.03 : 1).animation(BX.spring(0.3), value: hot)
            .boxTarget(id, hand: !disabled, kind: .button { if !disabled { tap() } }).pressable(label, disabled: disabled, tap)
    }
}
private struct CardBox<Content: View>: View {   // .ok and .pk: a rounded glass card that grows in and folds away
    let card: Card; var hover = false; var cursor = true
    @ViewBuilder var content: Content
    @State private var grown = false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(EdgeInsets(top: 13, leading: 14, bottom: 14, trailing: 14))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(rr(14).fill(Color.white(hover ? 0.09 : 0.07))).overlay(rr(14).strokeBorder(Color.white(0.14), lineWidth: 0.5))
            .clipShape(rr(14))
            .frame(maxHeight: card.gone ? 0 : nil, alignment: .top).opacity(card.gone ? 0 : 1).clipped()
            .padding(.top, card.gone ? 0 : 14)
            .animation(BX.ease(0.34), value: card.gone)
            .scaleEffect(grown ? 1 : 0.97).offset(y: grown ? 0 : -6).opacity(grown ? 1 : 0)
            .onAppear { withAnimation(BX.spring(0.32)) { grown = true } }
    }
}
private struct CardView: View {
    @ObservedObject var m: BoxModel
    let card: Card
    var body: some View {
        let cid = card.id.uuidString
        switch card.kind {
        case .approval(let q, let cmd):
            CardBox(card: card, hover: m.hot.contains("ok" + cid)) {
                Text(q).font(cssFont(13.5, 600)).foregroundColor(BX.fg)
                ScrollView(.vertical, showsIndicators: false) {
                    Text(cmd).font(.system(size: 11, design: .monospaced)).foregroundColor(card.full ? Color(hex: 0xd1d1d6) : BX.fg2).lineSpacing(15 - 13)
                        .lineLimit(card.full ? nil : 1).truncationMode(.tail).frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: card.full)
                }.frame(maxHeight: card.full ? 165 : 15).padding(.top, 4).animation(BX.ease(0.34), value: card.full)
                HStack(spacing: 8) {
                    OkButton(id: "deny" + cid, label: "Don’t Allow", m: m) { m.answerApproval(card.id, false) }
                    OkButton(id: "allow" + cid, label: "Allow", go: true, m: m) { m.answerApproval(card.id, true) }
                }.padding(.top, 11)
            }
            .boxTarget("ok" + cid, kind: .button { m.mapCards { if $0.id == card.id { $0.full.toggle() } } })
        case .retry(let q, let p, let details):
            Offer(m: m, card: card, title: q, text: p, buttons: [("n" + cid, "Not now", false, { m.answerRetry(card.id, "n") }), ("r" + cid, "Retry", true, { m.answerRetry(card.id, "r") })],
                  details: details.map { d in ("Copy Details", { m.post(["copy": d]) }) })
        case .paused:
            Offer(m: m, card: card, title: "Aurel is paused", text: nil, buttons: [("resume" + cid, "Resume", true, { m.post(["resume": true]) })])
        case .worker:
            Offer(m: m, card: card, title: "Aurel’s helper couldn’t start", text: "Retry, or open Setup & Permissions to repair it.",
                  buttons: [("setup" + cid, "Open Setup", false, { m.post(["setup": true]) }),
                            ("wretry" + cid, "Retry", true, { m.mapCards { if $0.id == card.id { $0.retryBusy = true } }; m.setStatus("Starting…", true); m.post(["workerRetry": true]) })],
                  disabled: card.retryBusy ? ["wretry" + cid] : [])
        case .pick(let q, let options, let pics): PickCard(m: m, card: card, q: q, options: options, pics: pics)
        case .agent(let eyebrow, let title, let answer, let learned, let made, let actions, let cost, _):
            AgentCardView(m: m, card: card, eyebrow: eyebrow, title: title, answer: answer, learned: learned, made: made, actions: actions, cost: cost)
        }
    }
}
private struct Offer: View {   // .ok.offer: a question with its two buttons
    @ObservedObject var m: BoxModel
    let card: Card; let title: String; let text: String?
    let buttons: [(String, String, Bool, () -> Void)]
    var details: (String, () -> Void)? = nil
    var disabled: [String] = []
    var body: some View {
        CardBox(card: card) {
            Text(title).font(cssFont(13.5, 600)).foregroundColor(BX.fg)
            if let text { Text(text).font(cssFont(12)).foregroundColor(BX.fg2).lineHeight(12, 1.4).padding(.top, 4).fixedSize(horizontal: false, vertical: true) }
            HStack(spacing: 8) { ForEach(buttons.indices, id: \.self) { i in let b = buttons[i]; OkButton(id: b.0, label: b.1, go: b.2, disabled: disabled.contains(b.0), m: m, tap: b.3) } }.padding(.top, 11)
            if let d = details {
                Text(d.0).font(cssFont(11, 500)).foregroundColor(m.hot.contains("det" + card.id.uuidString) ? BX.fg : BX.fg2).frame(maxWidth: .infinity).padding(.top, 9)
                    .boxTarget("det" + card.id.uuidString, kind: .button(d.1))
            }
        }
    }
}
private struct PickCard: View {   // "which one?": click one to see it big; click outside it for all of them again
    @ObservedObject var m: BoxModel
    let card: Card; let q: [MDBlock]; let options: [PickOption]; let pics: Bool
    var body: some View {
        let cid = card.id.uuidString, open = card.open
        CardBox(card: card) {
            AnswerView(blocks: q, style: AnswerStyle(size: 13.5, lh: 1.45, color: BX.fg)).fontWeight(.semibold).padding(.bottom, 10)
            ScrollView(.vertical, showsIndicators: false) {
                LazyVGrid(columns: pics && open == nil ? [GridItem(.adaptive(minimum: 96), spacing: 8)] : [GridItem(.flexible())], spacing: pics ? 8 : 4) {
                    ForEach(options.indices, id: \.self) { i in
                        if open == nil || open == i { Choice(m: m, cid: cid, i: i, o: options[i], pics: pics, big: open == i) {
                            if !pics { m.pickDone(card.id, i) } else { m.mapCards { if $0.id == card.id { $0.open = $0.open == i ? nil : i } } }
                        } }
                    }
                }.padding(.vertical, 3).padding(.horizontal, 5)
            }
            .frame(maxHeight: open != nil ? nil : min(236, max(96, m.screenHeight - 300))).padding(.horizontal, -5).padding(.vertical, -3)
            if open == nil {
                OtherField(m: m, card: card)
            }
            HStack(spacing: 8) {
                if open == nil { OkButton(id: "none" + cid, label: "None of these", m: m) { m.pickDone(card.id, -1) } }
                else {
                    OkButton(id: "back" + cid, label: "All choices", m: m) { m.mapCards { if $0.id == card.id { $0.open = nil } } }
                    OkButton(id: "use" + cid, label: "Use this", go: true, m: m) { m.pickDone(card.id, open ?? -1) }
                }
            }.padding(.top, 10)
        }
        .animation(BX.ease(0.34), value: open)
        .boxTarget("pk" + cid, hand: false, kind: .button { m.mapCards { if $0.id == card.id { $0.open = nil } } })
    }
}
private struct Choice: View {
    @ObservedObject var m: BoxModel
    let cid: String; let i: Int; let o: PickOption; let pics: Bool; let big: Bool; let tap: () -> Void
    var body: some View {
        let id = "c\(i)" + cid, hot = m.hot.contains(id) && !big
        VStack(alignment: .leading, spacing: 3) {
            if pics {
                ZStack {
                    Color.black(0.28)
                    if let img = o.img { Image(nsImage: img).resizable().aspectRatio(contentMode: .fit) } else { Text(o.kind).font(cssFont(11, 600)).tracking(0.4).foregroundColor(BX.fg2) }
                }
                .frame(height: big ? 200 : nil).aspectRatio(big ? nil : 4 / 3, contentMode: .fit).clipShape(rr(6)).padding(.bottom, 3)
            }
            AnswerView(blocks: parseMarkdown(o.label), style: AnswerStyle(size: big ? 13 : 12, lh: 1.35, color: BX.fg)).lineLimit(pics && !big ? 1 : 2)
            if !o.sub.isEmpty { Text(o.sub).font(cssFont(10.5)).foregroundColor(BX.fg2).lineLimit(big ? nil : 1) }
            if big && !o.path.isEmpty { Text(o.path).font(cssFont(10.5)).foregroundColor(BX.fg2) }
        }
        .padding(pics ? EdgeInsets(top: 5, leading: 5, bottom: 7, trailing: 5) : EdgeInsets(top: 8, leading: 11, bottom: 8, trailing: 11))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rr(10).fill(Color.white(hot ? 0.1 : big ? 0.06 : 0.04))).overlay(rr(10).strokeBorder(Color.white(0.08), lineWidth: 0.5))
        .scaleEffect(hot ? 1.03 : 1).animation(BX.spring(0.3), value: hot)
        .help(o.path.isEmpty ? o.label : o.path + "/" + o.label)
        .boxTarget(id, kind: .button(tap)).pressable(o.sub.isEmpty ? o.label : o.label + ", " + o.sub, tap)
    }
}
private struct OtherField: View {   // "Something else…": type or dictate, then Return
    @ObservedObject var m: BoxModel
    let card: Card
    @FocusState private var focused: Bool
    @State private var text = ""
    var body: some View {
        TextField("", text: $text, prompt: Text("Something else…").foregroundColor(BX.fg2)).textFieldStyle(.plain).font(cssFont(12.5)).foregroundColor(BX.fg).focused($focused)
            .padding(.horizontal, 11).frame(height: 30)
            .background(rr(10).fill(Color.white(focused ? 0.08 : 0.05))).overlay(rr(10).strokeBorder(focused ? BX.blue : Color.white(0.14), lineWidth: focused ? 1 : 0.5))
            .padding(.top, 8)
            .onSubmit { let t = text.trimmingCharacters(in: .whitespaces); if !t.isEmpty { m.pickDone(card.id, -1, "Got it", own: String(t.prefix(300))) } }
            .boxTarget("other" + card.id.uuidString, hand: false, kind: .field { focused = true })
            .onChange(of: m.focusOther) { _, _ in focused = true }
    }
}
private struct Kbd: View {   // a keycap on a button
    let s: String; var go = false
    var body: some View {
        Text(s).font(cssFont(10.5, 500)).foregroundColor(go ? .white : BX.fg).padding(.horizontal, 5).frame(minWidth: 20).frame(height: 18)
            .background(rr(5).fill(go ? Color.black(0.12) : Color.white(0.1))).overlay(rr(5).strokeBorder(Color.white(go ? 0.3 : 0.16), lineWidth: 0.5))
            .shadow(color: .black(0.3), radius: 0, y: 1)
    }
}
private struct AgentCardView: View {
    @ObservedObject var m: BoxModel
    let card: Card; let eyebrow: String; let title: String; let answer: [MDBlock]; let learned: String?; let made: [Made]; let actions: [KeyAction]; let cost: String?
    @State private var more = false
    @State private var cardH: CGFloat = 0
    @State private var shownH: CGFloat = 0
    // The answer gives up what the card overflows the thread by (60 pt at least), so the title and actions stay in view in a short box.
    var cap: CGFloat { max(60, min(260, m.screenHeight - 300, cardH > 0 ? m.threadMax - (cardH - shownH) : 260)) }
    var body: some View {
        let cid = card.id.uuidString, done = eyebrow == "Agent done"
        CardBox(card: card) {
            HStack(spacing: 6) {
                if done { Circle().fill(BX.green).frame(width: 6, height: 6).shadow(color: .rgba(48, 209, 88, 0.5), radius: 4) } else { PulseDot(color: BX.blue, period: 1.8) }
                Text(eyebrow).font(cssFont(10.5, 600)).tracking(0.2).foregroundColor(BX.fg2)
            }.frame(height: 14).padding(.bottom, 5)
            Text(title).font(cssFont(13.5, 600)).foregroundColor(BX.fg)
            ScrollView(.vertical, showsIndicators: false) {
                AnswerView(blocks: answer, style: AnswerStyle(size: 13.5, lh: 1.55, color: BX.fg)) { m.post(["link": $0]) }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { more = $0 > cap + 4 }
            }
            .frame(maxHeight: cap).fixedSize(horizontal: false, vertical: !more)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { shownH = $0 }
            .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: more ? 0.88 : 1), .init(color: more ? .clear : .black, location: 1)], startPoint: .top, endPoint: .bottom))
            .padding(.top, 8)
            if let learned { TipView(id: card.id, text: "Say “\(learned)” any time.", learned: true) }
            if !made.isEmpty {
                VStack(spacing: 6) {
                    ForEach(made.indices, id: \.self) { i in
                        let t = made[i], id = "made\(i)" + cid, hot = m.hot.contains(id)
                        HStack(spacing: 10) {
                            ZStack { rr(8).fill(i == 0 ? BX.blue : Color.white(0.1)); Icon(paths: t.icon, box: 16, stroke: 1.5, color: .white).frame(width: 14, height: 14) }
                                .frame(width: 28, height: 28).shadow(color: i == 0 ? .rgba(10, 132, 255, 0.35) : .clear, radius: 5, y: 3)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(t.title).font(cssFont(12.5, 600)).foregroundColor(BX.fg).lineLimit(1)
                                Text(t.sub).font(cssFont(10.5)).foregroundColor(hot ? Color(hex: 0xe5e5ea) : BX.fg2).lineLimit(1)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            Icon(paths: ["M6 3H3v10h10v-3M9 2.5h4.5V7M13.5 2.5 7.5 8.5"], box: 16, stroke: 1.5, color: hot ? .white : BX.fg2).frame(width: 12, height: 12)
                        }
                        .padding(EdgeInsets(top: 7, leading: 7, bottom: 7, trailing: 9)).background(rr(10).fill(Color.white(hot ? 0.1 : 0.06)))
                        .help(t.url).boxTarget(id, kind: .button { m.post(["agentOpen": actionsID, "target": t.url]); m.removeParts { $0.id == card.id } })
                    }
                }.padding(.top, 10)
            }
            HStack(spacing: 6) {
                Spacer(minLength: 0)
                ForEach(actions.indices, id: \.self) { i in
                    let a = actions[i], id = "act\(i)" + cid, hot = m.hot.contains(id)
                    HStack(spacing: 7) { Text(a.label); if let k = a.key { Kbd(s: k, go: a.go) } }
                        .font(cssFont(12.5, 500)).foregroundColor(a.go || hot ? .white : Color(hex: 0xd1d1d6))
                        .padding(.leading, 11).padding(.trailing, a.key == nil ? 11 : a.go ? 5 : 6).frame(height: 28)
                        .background(rr(9).fill(a.go ? (hot ? Color(hex: 0x0070df) : BX.accent) : hot ? Color.white(0.08) : .clear))
                        .boxTarget(id, kind: .button { m.post(a.msg); m.removeParts { $0.id == card.id } })
                }
            }.padding(.top, 14)
            if let cost { Text(cost).font(cssFont(10)).monospacedDigit().foregroundColor(BX.fg2).padding(.top, 9) }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { cardH = $0 }
    }
    var actionsID: String { if case .agent(_, _, _, _, _, _, _, let id) = card.kind { return id }; return "" }
}
private struct TipView: View {   // .tip: once in a while, one quiet line under the answer
    let id: UUID; let text: String; let learned: Bool
    @State private var shown = false
    var body: some View {
        let gone = text.hasPrefix("\u{0}"), s = gone ? String(text.dropFirst()) : text
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text(learned ? "Learned" : "Tip").font(cssFont(12, 600)).foregroundColor(learned ? Color(hex: 0x30db5b) : BX.link)
            Text(s).font(cssFont(12)).foregroundColor(Color(hex: 0xe5e5ea)).lineHeight(12, 1.4).fixedSize(horizontal: false, vertical: true)
            if !learned { Text("Turn off tips").font(cssFont(11, 500)).foregroundColor(BX.fg2).boxTarget("off:" + id.uuidString, kind: .tipOff) }
        }
        .padding(EdgeInsets(top: 7, leading: 10, bottom: 7, trailing: 12))
        .background(rr(12).fill(learned ? Color.rgba(48, 209, 88, 0.14) : .rgba(10, 132, 255, 0.16)))
        .overlay(rr(12).strokeBorder(learned ? Color.rgba(48, 209, 88, 0.45) : .rgba(10, 132, 255, 0.45), lineWidth: 0.5))
        .boxTarget("tip:" + id.uuidString, kind: .tip)
        .padding(.top, 14)
        .scaleEffect(shown && !gone ? 1 : 0.94).offset(y: gone ? -4 : shown ? 0 : -6).opacity(shown && !gone ? 1 : 0)
        .onAppear { withAnimation(BX.spring(0.5, delay: 0.4)) { shown = true } }
        .animation(.linear(duration: 0.4), value: gone)
    }
}
private struct Receipt: View {   // ✎: what this ask remembered (✓) or forgot (struck through), as one row; Settings opens on the item
    @ObservedObject var m: BoxModel
    let id: UUID; let items: [MemItem]; let open: Bool; let toggle: () -> Void
    var body: some View {
        let adds = items.contains { $0.add }, dels = items.contains { !$0.add }, sid = id.uuidString
        let labels = items.reduce(into: [String]()) { if !$0.contains($1.label) { $0.append($1.label) } }
        let hotH = m.hot.contains("memh" + sid) || open
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                ZStack { Circle().fill(adds ? Color.rgba(48, 209, 88, 0.2) : .rgba(142, 142, 147, 0.22)); Icon(paths: [adds ? "M2 5.3l2 2L8 3" : "M2.5 5h5"], box: 10, stroke: 1.8, color: adds ? BX.green : Color(hex: 0xa1a1a6)).frame(width: 8, height: 8) }.frame(width: 14, height: 14)
                Text(adds && dels ? "Updated" : adds ? "Remembered" : "Forgot").strikethrough(!adds, color: .rgba(161, 161, 166, 0.7))
                Text("· " + labels.joined(separator: ", ")).foregroundColor(BX.fg2)
                Icon(paths: ["M3.5 2l3 3-3 3"], box: 10, stroke: 1.8, color: hotH ? BX.fg : BX.fg2).frame(width: 8, height: 8).opacity(0.7).rotationEffect(.degrees(open ? 90 : 0)).animation(BX.spring(0.38), value: open)
            }
            .font(cssFont(12, 500)).foregroundColor(hotH ? BX.fg : BX.fg2).frame(height: 22)
            .boxTarget("memh" + sid, kind: .button { withAnimation(BX.ease(0.36)) { toggle() } })
            if open {
                VStack(alignment: .leading, spacing: 0) {
                    var n = 0
                    ForEach(labels, id: \.self) { label in
                        Text(label.uppercased()).font(cssFont(10.5, 600)).tracking(0.04 * 10.5).foregroundColor(BX.fg2).padding(EdgeInsets(top: 6, leading: 9, bottom: 2, trailing: 9))
                        ForEach(items.indices.filter { items[$0].label == label }, id: \.self) { k in
                            let it = items[k], iid = "memi\(k)" + sid, hot = m.hot.contains(iid)
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Icon(paths: [it.add ? "M2 5.3l2 2L8 3" : "M2.5 5h5"], box: 10, stroke: 1.8, color: it.add ? BX.green : Color(hex: 0x8e8e93)).frame(width: 9, height: 9).offset(y: 1)
                                Text(it.t).foregroundColor(it.add ? Color(hex: 0xe5e5ea) : BX.fg2).strikethrough(!it.add).frame(maxWidth: .infinity, alignment: .leading)
                                Text("Settings ›").font(cssFont(11, 500)).foregroundColor(BX.fg2).opacity(hot ? 1 : 0)
                            }
                            .font(cssFont(12.5)).lineHeight(12.5, 1.4).padding(.horizontal, 9).padding(.vertical, 6)
                            .background(rr(8).fill(hot ? Color.white(0.07) : .clear))
                            .boxTarget(iid, kind: .button { m.post(["memory": ["c": it.c, "t": it.t]]) })
                            let _ = (n += 1)
                        }
                    }
                }
                .padding(4).background(rr(12).fill(Color.white(0.05))).overlay(rr(12).strokeBorder(Color.white(0.1), lineWidth: 0.5)).padding(.top, 6)
                .transition(.opacity)
            }
        }
        .padding(.top, 12)
    }
}
private struct RewriteBar: View {
    @ObservedObject var m: BoxModel
    let mode: String; let actions: [(String, String)]; let draft: String; let editable: Bool
    var body: some View {
        HStack(spacing: 8) {
            ForEach(actions.indices, id: \.self) { i in
                let (label, action) = actions[i]
                let go = action == "replace" || (mode == "draft" && action == "copy" && !editable)
                OkButton(id: "rw\(i)", label: label, go: go, del: action == "replace" && mode == "delete", disabled: action == "replace" && !editable, m: m) {
                    m.post(action == "copy" ? ["copy": draft] : [action: true])
                }
                .help(action == "replace" ? (!editable ? "This app does not let Aurel edit here. Use Copy." : mode == "draft" ? "Insert at your cursor" : label + " the selected text") : "")
            }
        }.padding(.top, 16)
    }
}

private struct PointBar: View {   // Point at your screen: one row over the typing box
    @ObservedObject var m: BoxModel
    let pointer = ["M9 8l11 4.5-4.6 1.9L13.5 19z", "M5.1 11.9A5.5 5.5 0 0 1 12.9 4.1"]
    var body: some View {
        if let s = m.pointState {
            HStack(spacing: 8) {
                if m.pointMarked {
                    HStack(spacing: 7) {
                        Group {
                            if let t = m.pointThumb { Image(nsImage: t).resizable().aspectRatio(contentMode: .fill) }
                            else { Icon(paths: pointer, stroke: 1.8, color: BX.fg2).frame(width: 13, height: 13) }
                        }.frame(width: 34, height: 22).background(Color.white(0.1)).clipShape(rr(6))
                        Text("Marked").font(cssFont(12)).foregroundColor(BX.fg)
                        Icon(paths: ["M2 2l6 6M8 2L2 8"], box: 10, stroke: 1.6, color: m.hot.contains("rm") ? .white : BX.fg2).frame(width: 9, height: 9).frame(width: 22, height: 22)
                            .background(rr(6).fill(m.hot.contains("rm") ? Color.white(0.1) : .clear)).boxTarget("rm", kind: .button { m.post(["pointClear": 1]) }).help("Remove mark")
                    }
                    .padding(.horizontal, 3).frame(height: 28).background(rr(9).fill(Color.white(0.08))).overlay(rr(9).strokeBorder(Color.white(0.14), lineWidth: 0.5))
                } else if s == "coach" {
                    (Text("Point at your screen:").fontWeight(.semibold).foregroundColor(BX.fg) + Text(" click ") + Text(Image(nsImage: glyph())).baselineOffset(-2) + Text(" below, then circle, click or scribble on anything and type or say your question."))
                        .font(cssFont(12)).foregroundColor(BX.fg2).lineHeight(12, 1.35).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                    Text("Got it").font(cssFont(12.5, 500)).foregroundColor(.white).padding(.horizontal, 11).frame(height: 28).background(rr(9).fill(m.hot.contains("gotit") ? Color(hex: 0x0070df) : BX.accent))
                        .boxTarget("gotit", kind: .button { m.coachDone() })
                } else {
                    Text(m.pointHint).font(cssFont(12)).foregroundColor(BX.fg2).lineHeight(12, 1.35).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(minHeight: 28).padding(.top, 12)
            .transition(.opacity.combined(with: .offset(y: 5)))
        }
    }
    func glyph() -> NSImage {
        let r = ImageRenderer(content: Icon(paths: pointer, stroke: 1.8, color: BX.fg2).frame(width: 13, height: 13)); r.scale = 2
        return r.nsImage ?? NSImage()
    }
}

private struct Composer: View {   // the typing box: grows in on hover (or the shortcut, in typing mode); the mic goes back to voice
    @ObservedObject var m: BoxModel
    @FocusState private var focused: Bool
    let pointer = ["M9 8l11 4.5-4.6 1.9L13.5 19z", "M5.1 11.9A5.5 5.5 0 0 1 12.9 4.1"]
    var body: some View {
        HStack(spacing: 8) {
            ZStack(alignment: .trailing) {
                TextField("", text: $m.ask, prompt: Text("Ask Aurel…").foregroundColor(BX.fg2)).textFieldStyle(.plain).font(cssFont(13.5)).foregroundColor(.white)
                    .focused($focused).padding(.horizontal, 13).frame(height: 34)
                    .background(Capsule().fill(Color.white(focused ? 0.1 : 0.08))).overlay(Capsule().strokeBorder(Color.white(0.14), lineWidth: 0.5))
                    .overlay(Capsule().inset(by: -3).strokeBorder(Color.accentColor.opacity(focused ? 0.6 : 0), lineWidth: 3))   // the Mac focus ring, in the user's accent color
                    .opacity(m.pickRow ? 0 : 1).scaleEffect(m.pickRow ? 0.97 : 1, anchor: .leading)
                    .onSubmit { m.send() }
                    .onKeyPress(phases: .down) { k in keys(k) }
                    .onChange(of: m.ask) { _, v in if !v.isEmpty { m.drop(); if m.miniEnd { m.post(["miniClear": true]); m.miniClear() } } }
                    .onChange(of: focused) { _, f in m.askFocused = f; m.post(["focus": f]); if !f && !m.hover && m.ask.isEmpty { m.comp(false) } }
                    .onChange(of: m.focusAsk) { _, _ in focused = true }
                if m.pickRow {
                    HStack(spacing: 6) {
                        ForEach(m.models.indices, id: \.self) { i in
                            let v = m.models[i], on = v == m.modelPick, id = "mdl\(i)", hot = m.hot.contains(id)
                            Text(m.modelName(v)).font(cssFont(12, 500)).foregroundColor(on || hot ? .white : BX.fg2).lineLimit(1).padding(.horizontal, 12).frame(height: 34)
                                .background(Capsule().fill(on ? Color.rgba(10, 132, 255, 0.35) : .white(0.08))).overlay(Capsule().strokeBorder(Color.white(0.14), lineWidth: 0.5))
                                .boxTarget(id, kind: .button {
                                    m.modelPick = v; m.post(["model": v])
                                    DispatchQueue.main.asyncAfter(deadline: .now() + (NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.17)) { withAnimation(BX.ease(0.3)) { m.pickRow = false } }   // the pick shows, then the row closes
                                })
                                .transition(.scale(scale: 0.9, anchor: .trailing).combined(with: .opacity))
                        }
                    }
                }
            }
            if !m.models.isEmpty && !m.pickRow {
                Text(m.modelName(m.modelPick)).font(cssFont(12, 500)).foregroundColor(m.hot.contains("model") ? .white : BX.fg2).lineLimit(1).truncationMode(.tail)
                    .padding(.horizontal, 12).frame(height: 34).fixedSize().frame(maxWidth: 132)
                    .background(Capsule().fill(Color.white(0.08))).overlay(Capsule().strokeBorder(Color.white(0.14), lineWidth: 0.5))
                    .boxTarget("model", kind: .button { withAnimation(BX.ease(0.38)) { m.pickRow = true }; m.post(["models": true]) }).help("Model")
            }
            if !m.pickRow {
                bead("point", "Point at your screen", icon: pointer, on: m.pointActive || m.pointMarked, ring: m.pointState == "coach") {
                    if m.working { return m.setStatus("Finish or stop the current answer first") }
                    m.coachDone(); m.post(["point": 1])
                }
                bead("mic", "Talk instead", icon: micGlyphBox, on: false, ring: false) { m.ask = ""; m.comp(false); m.post(["mic": 1]) }
            }
        }
        .padding(4).frame(height: m.compOpen ? 44 : 0, alignment: .top).clipped().opacity(m.compOpen ? 1 : 0)
        .padding(.horizontal, -4).padding(.top, m.compOpen ? 10 - 4 + 4 : 0)
        .report("comp")
        .allowsHitTesting(m.compOpen)
    }
    func bead(_ id: String, _ label: String, icon: [String], on: Bool, ring: Bool, tap: @escaping () -> Void) -> some View {
        let hot = m.hot.contains(id)
        return Icon(paths: icon, stroke: 1.8, color: .white).frame(width: 15, height: 15)
        .frame(width: 34, height: 34).glassEffect(on ? .regular.tint(BX.blue) : hot ? .regular.tint(.white(0.15)) : .regular, in: .circle).overlay { if ring { Circle().inset(by: -2).stroke(Color.rgba(10, 132, 255, 0.8), lineWidth: 2) } }
        .scaleEffect(hot ? 1.1 : 1).animation(BX.spring(0.35), value: hot)
        .boxTarget(id, kind: .button(tap)).pressable(label, tap).help(label)
    }
    func keys(_ k: KeyPress) -> KeyPress.Result {   // into a choices card: 1–9 picks, ↓ moves in; ↑ brings the last ask back
        guard m.ask.isEmpty, k.modifiers.isEmpty else { return .ignored }
        if let d = Int(k.characters), (1...9).contains(d), let c = m.liveCard({ if case .pick = $0 { return true }; return false }), case .pick(_, let o, _) = c.kind, d <= o.count {
            m.pickDone(c.id, d - 1)   // a number picks, pictures too (a click on a picture opens it first)
            return .handled
        }
        if k.key == .upArrow, !m.listening, !m.working, let t = m.turns.last, !t.qEmpty { m.ask = t.q; return .handled }
        return .ignored
    }
}
let micGlyphBox = [rect(9, 3, 6, 11, 3), "M5.5 11a6.5 6.5 0 0 0 13 0M12 17.5V21"]

private struct Pill: View {   // dictation: a pill just wide enough for the orb and its wave (and the lock once locked); then the working orb, then a check
    @ObservedObject var m: BoxModel
    var body: some View {
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion   // Reduce Motion: the states cross-fade instead of morphing
        let morph: AnyTransition = reduce ? .opacity : .scale(scale: 0.5).combined(with: .opacity)
        HStack(spacing: 8) {
            OrbRep(state: m.orbState, size: 64, dpr: 2, running: m.visible, capped: true, boost: m.boost).frame(width: 28, height: 28).report("orb")   // stays: the check sits beside it
            if m.hearing && m.pill.isEmpty {
                HStack(spacing: 2) { ForEach(m.wave.indices, id: \.self) { i in Capsule().fill(BX.accent).frame(width: 3, height: m.wave[i]).animation(BX.ease(0.1), value: m.wave[i]) } }
                    .frame(width: 43, height: 28)
            }
            if m.locked {
                ZStack { SVGPath(d: "M2.5 6V4a2.5 2.5 0 0 1 5 0v2", box: 10).stroke(BX.fg2, style: StrokeStyle(lineWidth: 1.5, lineCap: .round)); rr(2).fill(BX.fg2).frame(width: 10, height: 7.5).offset(y: 2.75) }
                    .frame(width: 10, height: 13).transition(.opacity)
            }
            if m.pill == "done" {
                ZStack { SVGPath(d: "M8 11l3 3 7-7", box: 28).stroke(BX.green, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)) }.frame(width: 28, height: 28)
                    .transition(morph)
            }
            if m.pill == "said" {
                HStack(spacing: 6) {
                    if m.dnTick { SVGPath(d: "M1 3l3 3 6-6", box: 10).stroke(BX.green, style: StrokeStyle(lineWidth: 1.5)).frame(width: 8, height: 5) }
                    Text(m.dn).font(cssFont(12)).foregroundColor(BX.fg).lineHeight(12, 16 / 12).fixedSize(horizontal: false, vertical: true)
                    ForEach(m.dnButtons.indices, id: \.self) { i in
                        Text(m.dnButtons[i].0).font(cssFont(12)).underline().foregroundColor(BX.fg2).padding(.horizontal, 8).padding(.vertical, 3)
                            .boxTarget("dn\(i)", kind: .button(m.dnButtons[i].1))
                    }
                }.frame(maxWidth: 290, alignment: .leading).transition(.opacity)
            }
        }
        .padding(m.pill == "said" ? EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 16) : m.pill == "finishing" || m.pill == "done" ? EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4) : EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 12))
        .frame(minWidth: 36, minHeight: 36)
        .overlay { if m.locked { RoundedRectangle(cornerRadius: 18).strokeBorder(Color.rgba(255, 159, 10, 0.9), lineWidth: 1.5).shadow(color: .rgba(255, 159, 10, 0.35), radius: 6) } }
        .animation(BX.ease(0.3) ?? (reduce && UIClock.frozen == nil ? .easeInOut(duration: 0.2) : nil), value: m.pill)
        .animation(BX.ease(0.3), value: m.locked)
    }
}

// MARK: - Hosting, for App and the screenshot harness

final class BoxSurface: NativeSurface {
    let model = BoxModel()
    let host: NSHostingView<BoxView>
    var view: NSView { host }
    init(frame: NSRect) {
        host = NSHostingView(rootView: BoxView(m: model)); host.frame = frame; host.autoresizingMask = [.width, .height]
        model.post = { _ in }
    }
    func receive(_ call: String, _ value: Any) {
        if call == "_pointer", let p = value as? [Double], p.count == 2 { _ = model.pointer(CGPoint(x: p[0], y: p[1]), overX: false); return }
        model.receive(call, value)
    }
    func freeze(at ms: Double?) {}
}
