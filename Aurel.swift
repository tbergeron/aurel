// Aurel overlay: hold to talk and release to send, or press to start and press again to send.
// A box in the top left (Box.swift, with the thinking-orbs orb) shows your words live (Apple on-device speech),
// then Aurel's notes and steps while `aurel.py` works, then the answer. It never takes focus.
// Build: ./build.sh. Kept running by ~/Library/LaunchAgents/com.aurel.app.plist
import Cocoa
import Carbon
import AVFoundation
import Speech
import ScreenCaptureKit
import Vision
import PDFKit
import QuickLookThumbnailing
import UniformTypeIdentifiers
import EventKit
import CoreAudio
import AudioToolbox
import NaturalLanguage
import SwiftUI
#if canImport(Textual)
import Textual   // build.sh builds through Package.swift, which adds it; a plain `swiftc Aurel.swift` (the tests) goes without
#endif

let dir = ProcessInfo.processInfo.environment["AUREL_RESOURCES_DIR"] ?? Bundle.main.resourcePath!   // build.sh copies aurel.py and ui/ in here

// Text stays local; totals survive history deletion and never contain dictated words.
enum DictationData {
    struct Entry: Codable {
        let id: String, timestamp: Double, app: String, text: String
        let raw: String?
    }
    struct Archive: Codable {
        var history: [Entry] = []
        var words = 0, sessions = 0, todayWords = 0
        var day = ""
        var seconds = 0.0
    }
    static var path: String { (Prefs.path as NSString).deletingLastPathComponent + "/dictation.json" }
    static var archive = (try? JSONDecoder().decode(Archive.self, from: Data(contentsOf: URL(fileURLWithPath: path)))) ?? Archive()
    static var words: [String] { Prefs.d["dictateWords"] as? [String] ?? [] }
    static func day(_ date: Date = Date()) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: date)
    }
    static func prune() { archive.history = Array(archive.history.filter { $0.timestamp > Date().timeIntervalSince1970 - 30 * 86400 }.prefix(500)) }
    @discardableResult static func save() -> Bool {
        do {
            let folder = (path as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let data = try JSONEncoder().encode(archive)
            // Set permissions before writing any transcript bytes, including on replacement.
            let tmp = folder + "/.dictation-" + UUID().uuidString
            guard FileManager.default.createFile(atPath: tmp, contents: nil, attributes: [.posixPermissions: 0o600]) else { return false }
            defer { try? FileManager.default.removeItem(atPath: tmp) }
            try data.write(to: URL(fileURLWithPath: tmp))
            guard rename(tmp, path) == 0 else { return false }
            return true
        } catch { return false }
    }
    @discardableResult static func record(_ text: String, raw: String, app: String, seconds: Double) -> Bool {
        let old = archive, count = text.split(whereSeparator: { $0.isWhitespace }).count
        if archive.day != day() { archive.day = day(); archive.todayWords = 0 }
        archive.words += count; archive.todayWords += count; archive.sessions += 1
        archive.seconds += max(0, Double(count) / 40 * 60 - seconds)
        if Prefs.bool("dictateHistory") {
            archive.history.insert(Entry(id: UUID().uuidString, timestamp: Date().timeIntervalSince1970, app: app, text: text, raw: raw == text ? nil : raw), at: 0)
        }
        prune()
        if save() { return true }; archive = old; return false
    }
    static func state() -> [String: Any] {
        let count = archive.history.count
        prune()
        if archive.history.count != count { _ = save() }
        return ["words": words, "history": archive.history.map { e -> [String: Any] in
            var row: [String: Any] = ["id": e.id, "timestamp": e.timestamp, "app": e.app, "text": e.text]
            if let raw = e.raw { row["raw"] = raw }; return row
        }, "stats": ["today": archive.day == day() ? archive.todayWords : 0, "words": archive.words, "sessions": archive.sessions, "minutes": Int(archive.seconds / 60)]]
    }
    @discardableResult static func word(_ value: String, replacing: String? = nil) -> Bool {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 80, !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return false }
        var list = words.filter { $0 != replacing }
        if !list.contains(value) { guard list.count < 500, list.reduce(0, { $0 + $1.count }) + value.count <= 4000 else { return false }; list.append(value) }
        guard Prefs.set("dictateWords", list) else { return false }
        if let replacing, replacing != value { Prefs.set("dictateFixes", fixes.mapValues { $0 == replacing ? value : $0 }) }
        return true
    }
    @discardableResult static func forget(_ word: String) -> Bool {
        guard Prefs.set("dictateWords", words.filter { $0 != word }) else { return false }
        Prefs.set("dictateFixes", fixes.filter { $0.value != word }); return true
    }
    // Heard spelling (lowercased) → the user's spelling, swapped in whole words before dictation is inserted.
    static var fixes: [String: String] { Prefs.d["dictateFixes"] as? [String: String] ?? [:] }
    static func known(_ word: String) -> Bool { NSSpellChecker.shared.checkSpelling(of: word, startingAt: 0).location == NSNotFound }
    // Every heard form is kept: cleanup gets it as a hint, and one that is no real word is also swapped here.
    @discardableResult static func fix(_ heard: String, _ word: String) -> Bool {
        let key = heard.lowercased()
        guard key != word, words.contains(word), fixes.count < 500 else { return false }
        var list = fixes; list[key] = word
        return Prefs.set("dictateFixes", list)
    }
    // A heard form that is itself real words ("cash" for "cache", "start" for a name) is never swapped blindly: only cleanup, with context, may.
    static func fixed(_ text: String) -> String {
        fixes.reduce(text) { text, fix in
            guard let re = try? NSRegularExpression(pattern: "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: fix.key) + "(?![\\p{L}\\p{N}])", options: .caseInsensitive) else { return text }
            let out = NSMutableString(string: text)
            let matches = re.matches(in: text, range: NSRange(location: 0, length: out.length))
            if matches.isEmpty || known(fix.key) { return text }
            for m in matches.reversed() {
                let found = out.substring(with: m.range), value = fix.value
                // A sentence-start capital stays when the learned spelling is lowercase.
                out.replaceCharacters(in: m.range, with: found.first?.isUppercase == true && value.first?.isLowercase == true ? value.prefix(1).uppercased() + value.dropFirst() : value)
            }
            return out as String
        }
    }
    // The words fit where they land: a space before them unless the cursor follows a space or an opening mark, one after
    // before more text, lowercase mid-sentence, and no period ahead of the rest of a sentence. Speech models write every
    // phrase as "Its own sentence." Words that keep their case: I, acronyms, iPhone-style names and Dictionary words.
    // Without the field's text (apps that hide it), the words go in as heard.
    static func fit(_ heard: String, before: String, after: String) -> String {
        var out = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !out.isEmpty, !(before + after).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return out }
        let closing = ".,!?;:)]}\"'”’…", opening = "([{\"'“‘/—-"
        let last = before.last(where: { !$0.isWhitespace }), gap = before.reversed().prefix(while: \.isWhitespace)
        let sentenceStart = last == nil || gap.contains(where: \.isNewline) || ".!?".contains(last!)
        let word = String(out.prefix(while: { $0.isLetter || $0 == "'" || $0 == "’" }))
        let keep = word == "I" || word.hasPrefix("I'") || word.hasPrefix("I’") || word.count > 1 && word == word.uppercased()
            || word.dropFirst().contains(where: \.isUppercase) || words.contains(word)
        if let first = out.first, first.isLetter, !keep {
            out = (sentenceStart ? first.uppercased() : first.lowercased()) + out.dropFirst()
        }
        let next = after.first(where: { !$0.isWhitespace })
        if out.hasSuffix("."), !out.hasSuffix(".."), let next, next.isLowercase || next.isNumber {
            out.removeLast()   // more of the same sentence follows
        }
        if let b = before.last, !b.isWhitespace, !opening.contains(b), let f = out.first, !closing.contains(f) { out = " " + out }
        if let a = after.first, !a.isWhitespace, !closing.contains(a) { out += " " }
        return out
    }
    static func distance(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        var row = Array(0...y.count)
        for (i, c) in x.enumerated() {
            var next = [i + 1]
            for (j, d) in y.enumerated() { next.append(min(next[j] + 1, row[j + 1] + 1, row[j] + (c == d ? 0 : 1))) }
            row = next
        }
        return row[y.count]
    }
    // How a word sounds, roughly: vowels drop and Soundex-like classes merge (t/d, lips b/p/f/v, nasals m/n),
    // so "Saarth", "Sarda" and "sort" become "srt", and "somebody" sits one sound from "some of you".
    // Same rule as dictate_sound in aurel.py.
    static func sound(_ text: String) -> String {
        var s = String(text.lowercased().folding(options: .diacriticInsensitive, locale: nil).filter { $0.isLetter })
        for (a, b) in [("ph", "f"), ("th", "t"), ("ck", "k"), ("sh", "s"), ("qu", "k")] { s = s.replacingOccurrences(of: a, with: b) }
        let merge: [Character: Character] = ["d": "t", "b": "p", "f": "p", "v": "p", "n": "m", "g": "k", "c": "k", "q": "k", "z": "s", "x": "s"]
        var out = ""
        for (i, c) in s.enumerated() {
            let k: Character? = "aeiouyhw".contains(c) ? (i == 0 ? "a" : nil) : merge[c] ?? c
            if let k, out.last != k { out.append(k) }
        }
        return out
    }
    static func sounds(_ a: String, _ b: String) -> Bool {
        let x = sound(a), y = sound(b)
        return x.count >= 2 && x.first == y.first && (x == y || min(x.count, y.count) >= 3 && distance(x, y) <= 1)
    }
    // A fix is one to three dictated words retyped as one word that is spelled or sounds alike ("Sarda", "start to" → "Saarth", "some of you" → "Semva"); a new idea is neither.
    // An everyday lowercase word is no name to learn.
    static func correction(_ original: String, _ edited: String) -> (heard: String, word: String)? {
        var a = original.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        var b = edited.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        while let x = a.first, x == b.first { a.removeFirst(); b.removeFirst() }
        while let x = a.last, x == b.last { a.removeLast(); b.removeLast() }
        guard (1...3).contains(a.count), b.count == 1 else { return nil }
        let trim = CharacterSet.punctuationCharacters
        let old = a.joined(separator: " ").trimmingCharacters(in: trim), new = b[0].trimmingCharacters(in: trim)
        guard old != new, (2...64).contains(new.count), new.unicodeScalars.allSatisfy({ CharacterSet.letters.contains($0) || $0 == "'" || $0 == "-" }) else { return nil }
        let near = a.count == 1 && distance(old.lowercased(), new.lowercased()) <= max(1, max(old.count, new.count) / 3)   // several heard words must sound like it
        guard near || sounds(old, new), !(new == new.lowercased() && known(new)) else { return nil }
        return (old, new)
    }
    // The user's keys replayed over inserted words where the field can't be read back (terminals, some Electron apps).
    // key returns false once a key's effect on the text is unknown (Return, a shortcut, leaving the dictated words).
    struct Replay {
        var chars: [Character], at: Int
        init(_ text: String) { chars = Array(text); at = chars.count }
        var text: String { String(chars) }
        func wordStart() -> Int { var i = at; while i > 0, chars[i - 1].isWhitespace { i -= 1 }; while i > 0, !chars[i - 1].isWhitespace { i -= 1 }; return i }
        func wordEnd() -> Int { var i = at; while i < chars.count, chars[i].isWhitespace { i += 1 }; while i < chars.count, !chars[i].isWhitespace { i += 1 }; return i }
        mutating func key(_ code: Int, _ typed: String, option: Bool, control: Bool, command: Bool) -> Bool {
            if command { return false }
            switch (code, option, control) {
            case (51, false, false), (4, false, true):   // delete, ⌃H
                guard at > 0 else { return false }; at -= 1; chars.remove(at: at)
            case (51, true, false), (13, false, true):   // ⌥delete, ⌃W
                let start = wordStart(); guard start < at else { return false }; chars.removeSubrange(start..<at); at = start
            case (117, false, false): guard at < chars.count else { return false }; chars.remove(at: at)
            case (123, false, false): guard at > 0 else { return false }; at -= 1
            case (124, false, false): guard at < chars.count else { return false }; at += 1
            case (123, true, false): at = wordStart()
            case (124, true, false): at = wordEnd()
            default:   // arrows up/down, function keys, Return, Tab and Escape type control or private-use characters
                guard !control, !typed.isEmpty, !typed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || (0xF700...0xF8FF).contains($0.value) }) else { return false }
                chars.insert(contentsOf: typed, at: at); at += typed.count
            }
            return true
        }
    }
}

// Settings, shared with aurel.py (model, screen, openOn, instant): ~/.config/aurel/settings.json
enum Prefs {
    static let path = (ProcessInfo.processInfo.environment["AUREL_DIR"] ?? NSString(string: "~/.config/aurel").expandingTildeInPath) + "/settings.json"
    static let defaults: [String: Any] = ["hotkeyCode": 49, "hotkeyMods": controlKey | optionKey, "hotkeyLabel": "⌃⌥Space", "login": true, "paused": false, "corner": "top-left", "linger": "normal",
        "soundStart": "Pop", "soundRelease": "Bottle", "soundDone": "Glass", "soundStop": "Tink", "volume": 0.16, "client": "local", "model": "haiku", "instant": true,
        "wakeWord": false, "microphone": "automatic", "quietAudio": false, "quietLevel": 0.18, "agentModel": "sonnet", "localModel": "gemma4", "agentUserTools": true, "fixSetup": false,
        "selection": true, "ahead": true, "aheadDelay": 0.7, "live": true, "screen": "auto", "openOn": "here", "workIn": "back", "miniScreen": true, "draw": true, "guideSteps": "auto", "pageJS": false,
        "speak": false, "showAnswers": "stream", "autoCopy": false, "hideWhenSharing": true, "menuIcon": true, "autoUpdate": true,
        "learn": true, "safe": true, "pointer": false, "learnMe": true, "saveChats": true, "stats": true, "tips": true, "askMe": true, "input": "voice", "talkMode": "hold", "speechModel": "speech", "parakeetModel": "v3", "unloadAfter": 5, "improve": false, "improveAsked": false, "draftInsert": "ask",
        "dictateHotkeyCode": -1, "dictateHotkeyMods": 0, "dictateHotkeyLabel": "", "dictateMode": "cleanup", "dictateLive": false, "dictateHistory": true, "dictateLearn": true, "dictateWords": [], "dictateFixes": [String: String](), "boxW": 500, "boxH": 420]
    // Settings → General → Free memory after: idle seconds before the speech and AI models unload, nil for Never.
    static func unloadAfter() -> Double? { let m = num("unloadAfter"); return m > 0 ? m * 60 : nil }
    static let retiredKeys = ["quietAudio", "quietLevel", "autoCopy", "askMe", "corner", "linger", "soundStart", "soundRelease", "soundDone", "soundStop",
        "instant", "live", "ahead", "aheadDelay", "learn", "selection", "guideSteps", "workIn", "openOn", "miniScreen", "draftInsert",
        "fixSetup", "dictateLearn"]
    static var d: [String: Any] = {
        let saved = (try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path)))) as? [String: Any] ?? [:]
        var values = defaults.merging(saved) { $1 }
        if !["cheapest", "balanced", "capable"].contains(values["routing"] as? String ?? "") {
            values["routing"] = values["model"] as? String != "haiku" ? "capable" :
                (values["escalate"] as? Bool != false && values["escalateAuto"] as? Bool != false ? "balanced" : "cheapest")
        }
        if values["speechModel"] as? String == "whisper" { values["speechModel"] = "parakeet" }   // Whisper was replaced by Parakeet (Oct 29, 2026)
        if ["devin", "pi"].contains(values["client"] as? String ?? "") { values["client"] = "local" }   // Devin and Pi were removed (Oct 29, 2026)
        for k in ["apiBase", "apiKey", "apiModel", "agentApiModel"] { values[k] = nil }   // custom servers were removed (Oct 29, 2026); Local replaces them
        for (k, old) in [("boxW", 460.0), ("boxH", 360.0)] where (values[k] as? NSNumber)?.doubleValue == old { values[k] = defaults[k] }   // every write saves the defaults too: the old size untouched is no choice
        // No dictation shortcut, never cleared on purpose: fn alone (code -2, aurelFnKey), unless the talk shortcut already holds fn.
        if values["dictateHotkeyLabel"] as? String == "", values["dictateHotkeyOff"] as? Bool != true, (values["hotkeyMods"] as? Int ?? 0) & (1 << 20) == 0 {
            values["dictateHotkeyCode"] = -2; values["dictateHotkeyMods"] = 1 << 20; values["dictateHotkeyLabel"] = "fn"
        }
        return values   // persisted with the next preference write; legacy keys remain readable
    }()
    @discardableResult static func set(_ k: String, _ v: Any) -> Bool {   // false: not on disk, so the old value stays too
        let old = d[k]; d[k] = v
        do {
            try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: d, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path), options: .atomic)
        } catch { d[k] = old; return false }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        return true
    }
    static func bool(_ k: String) -> Bool { d[k] as? Bool ?? false }
    static func str(_ k: String) -> String { d[k] as? String ?? "" }
    static func num(_ k: String) -> Double { (d[k] as? NSNumber)?.doubleValue ?? 0 }
}

func applySharing(_ window: NSWindow) {
    window.sharingType = sharingType(hidden: Prefs.bool("hideWhenSharing"), majorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion)
}

func sharingType(hidden: Bool, majorVersion: Int) -> NSWindow.SharingType {
    // Work around reported macOS 27 blank content with .none; preserve the saved preference.
    hidden && majorVersion < 27 ? .none : .readOnly
}

func profileName(_ path: String) -> String {
    guard let profile = (try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path)))) as? [String: Any] else { return "" }
    guard let facts = profile["facts"] as? [[String: Any]] else { return profile["name"] as? String ?? "" }
    for source in ["you", "contacts", "mail", "learned"] {
        if let value = facts.first(where: { $0["category"] as? String == "basics" && ($0["kind"] as? String)?.lowercased() == "name" && $0["source"] as? String == source })?["value"] as? String {
            return value
        }
    }
    return ""
}

func audioProp<T>(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector, _ zero: T) -> [T] {
    var a = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain), size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(obj, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
    var out = [T](repeating: zero, count: Int(size) / MemoryLayout<T>.stride)
    return AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &out) == noErr ? out : []
}

func audioString(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String? {
    var a = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var value: Unmanaged<CFString>?, size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &value) == noErr, let value else { return nil }
    return value.takeRetainedValue() as String
}

struct MicrophoneDevice {
    let id: AudioDeviceID, uid: String, name: String, transport: UInt32
}
func microphones() -> [MicrophoneDevice] {
    audioProp(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices, AudioDeviceID(0)).compactMap { id in
        var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain), size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size) == noErr, size > 0,
              let uid = audioString(id, kAudioDevicePropertyDeviceUID), let name = audioString(id, kAudioObjectPropertyName) else { return nil }
        return MicrophoneDevice(id: id, uid: uid, name: name, transport: audioProp(id, kAudioDevicePropertyTransportType, UInt32(0)).first ?? 0)
    }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
}
func chooseMic(_ preferred: String, _ devices: [MicrophoneDevice], _ defaultID: AudioDeviceID) -> MicrophoneDevice? {
    if preferred != "automatic", let picked = devices.first(where: { $0.uid == preferred }) { return picked }
    guard let standard = devices.first(where: { $0.id == defaultID }) else { return devices.first }
    let bluetooth = [kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE].contains(standard.transport)
    return bluetooth ? devices.first(where: { $0.transport == kAudioDeviceTransportTypeBuiltIn }) ?? standard : standard
}
func listenMic() -> MicrophoneDevice? {
    let sys = AudioObjectID(kAudioObjectSystemObject)
    return chooseMic(Prefs.str("microphone"), microphones(), audioProp(sys, kAudioHardwarePropertyDefaultInputDevice, AudioDeviceID(0)).first ?? 0)
}
// Opens only the chosen mic. AVAudioEngine opens the default input first, which flips Bluetooth headphones into call mode and keeps them there.
final class Mic: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    private var session: AVCaptureSession?, onBuffer: ((AVAudioPCMBuffer) -> Void)?
    private let queue = DispatchQueue(label: "aurel.mic")
    private static let sessionQueue = DispatchQueue(label: "aurel.mic.session")   // serialize device release before another Mic opens it
    private var generation = 0
    private(set) var isRunning = false
    func start(_ device: AVCaptureDevice, sampleRate: Double, _ onBuffer: @escaping (AVAudioPCMBuffer) -> Void, completion: @escaping (Result<Void, Error>) -> Void) {
        stop()
        isRunning = true; let g = generation
        Self.sessionQueue.async { [self] in
            let result: Result<Void, Error>
            do {
                let s = AVCaptureSession(), input = try AVCaptureDeviceInput(device: device), out = AVCaptureAudioDataOutput()
                guard s.canAddInput(input), s.canAddOutput(out) else { throw NSError(domain: "Mic", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(device.localizedName) can't be opened"]) }
                s.addInput(input); s.addOutput(out)
                out.audioSettings = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1,
                                     AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: true]
                out.setSampleBufferDelegate(self, queue: queue)
                queue.sync { self.onBuffer = onBuffer }; session = s
                s.startRunning()
                guard s.isRunning else { throw NSError(domain: "Mic", code: 2, userInfo: [NSLocalizedDescriptionKey: "\(device.localizedName) could not start"]) }
                result = .success(())
            } catch { result = .failure(error) }
            DispatchQueue.main.async { [self] in
                guard generation == g else { return }
                if case .failure = result { stop() }
                completion(result)
            }
        }
    }
    func stop(completion: @escaping () -> Void = {}) {
        generation += 1; isRunning = false
        Self.sessionQueue.async { [self] in
            session?.stopRunning(); session = nil   // release the device so headphones return to music mode
            queue.sync { onBuffer = nil }
            DispatchQueue.main.async(execute: completion)
        }
    }
    func captureOutput(_ output: AVCaptureOutput, didOutput sample: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let onBuffer, let desc = sample.formatDescription, let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc),
              let format = AVAudioFormat(streamDescription: asbd),
              let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sample.numSamples)) else { return }
        buf.frameLength = buf.frameCapacity
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(sample.numSamples), into: buf.mutableAudioBufferList) == noErr else { return }
        onBuffer(buf)
    }
}
// MARK: Parakeet
// Settings → Speech model → Parakeet: NVIDIA's Parakeet on the Neural Engine, through the aurel-parakeet helper (parakeet/, FluidAudio)
// that build.sh puts next to Aurel. The helper skips audio with no voice in it, so silence never turns into words.
// The mic's 16 kHz mono Float32 samples for it, filled on the mic queue and read while the key is held.
final class ParakeetAudio: @unchecked Sendable {
    private let lock = NSLock(); private var samples: [Float] = []
    func reset() { lock.lock(); samples = []; lock.unlock() }
    func append(_ b: AVAudioPCMBuffer) {
        guard let ch = b.floatChannelData?[0] else { return }
        lock.lock(); samples.append(contentsOf: UnsafeBufferPointer(start: ch, count: Int(b.frameLength))); lock.unlock()
    }
    func snapshot() -> [Float] { lock.lock(); defer { lock.unlock() }; return samples }
    var seconds: Double { lock.lock(); defer { lock.unlock() }; return Double(samples.count) / 16000 }
    func take() -> [Float] { lock.lock(); defer { samples = []; lock.unlock() }; return samples }
}

// Owns one `aurel-parakeet serve` on pipes: it exits when Aurel closes them or dies (no orphans), and the idle time in
// Settings stops it; the next key-down starts it again in ~0.3 s. Requests run one at a time on `queue`, so answers come back in order.
final class Parakeet: @unchecked Sendable {
    static let shared = Parakeet()
    struct Model { let id, name, size: String }
    static var models = [Model(id: "v3", name: "Multilingual", size: "469 MB"), Model(id: "ultra", name: "Most accurate", size: "613 MB"),
                         Model(id: "redux", name: "Light", size: "213 MB"), Model(id: "v2", name: "English", size: "451 MB")]   // the first is the default; tests/evals/speech_bench.sh times them
    static func model(_ id: String) -> Model { models.first { $0.id == id } ?? models[0] }
    static var dir: String { (Prefs.path as NSString).deletingLastPathComponent + "/parakeet" }
    static func marker(_ m: Model) -> String { dir + "/" + m.id }   // the helper writes the model's folder here once it is downloaded
    static let cache = NSHomeDirectory() + "/Library/Application Support/FluidAudio/Models/"   // where FluidAudio keeps models
    static func helperPath() -> String? {   // next to Aurel in the app; tests point AUREL_PARAKEET at another one
        let p = ProcessInfo.processInfo.environment["AUREL_PARAKEET"] ?? ((Bundle.main.executablePath ?? "") as NSString).deletingLastPathComponent + "/aurel-parakeet"
        return FileManager.default.isExecutableFile(atPath: p) ? p : nil
    }
    struct Failed: LocalizedError { let errorDescription: String?; init(_ why: String) { errorDescription = why } }
    static let offline = "Download failed. Check your connection and try again."

    // One running helper and its pipes. line() blocks, so it runs only on `queue`.
    private final class Conn: @unchecked Sendable {
        let proc: Process, input: FileHandle, output: FileHandle; var buf = Data()
        init(_ proc: Process, _ input: FileHandle, _ output: FileHandle) { self.proc = proc; self.input = input; self.output = output }
        func line() -> String? {
            while true {
                if let i = buf.firstIndex(of: 10) { let s = String(decoding: buf[..<i], as: UTF8.self); buf = Data(buf[(i + 1)...]); return s }
                let d = output.availableData
                if d.isEmpty { return nil }   // the helper quit
                buf.append(d)
            }
        }
    }
    private struct Download { let proc: Process; var progress = 0.0, pinged = Date.distantPast, why = "", rest = "" }
    private let lock = NSLock(), queue = DispatchQueue(label: "aurel.parakeet")
    private var conn: Conn?, serving: String?, up: Task<Bool, Never>?, idle: DispatchWorkItem?
    private var helper: String?, have: Set<String> = [], downloads: [String: Download] = [:], error: String?

    private init() {
        refresh()
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in self?.stop() }
    }

    // File checks happen here (settings open, downloads, deletes); `ready` runs on key-down and only reads the cache.
    private func refresh() {
        let h = Self.helperPath(), got = Set(Self.models.filter { FileManager.default.fileExists(atPath: Self.marker($0)) }.map(\.id))
        lock.lock(); helper = h; have = got; lock.unlock()
    }
    var ready: Bool {   // a miss looks again: a model may have finished downloading since
        let ok = { self.lock.withLock { self.helper != nil && self.have.contains(Self.model(Prefs.str("parakeetModel")).id) } }
        if ok() { return true }
        refresh(); return ok()
    }

    func status() -> [String: Any] {
        refresh()
        lock.lock(); defer { lock.unlock() }
        return ["server": helper != nil, "model": Self.model(Prefs.str("parakeetModel")).id, "running": conn?.proc.isRunning == true, "error": error ?? NSNull(),
                "models": Self.models.map { m -> [String: Any] in
                    ["id": m.id, "name": m.name, "size": m.size, "have": have.contains(m.id), "progress": downloads[m.id].map { $0.progress as Any } ?? NSNull()] }]
    }

    // `aurel-parakeet download` fetches the model and its voice detector, readies them for the Neural Engine, then writes the
    // marker: a half download never looks installed.
    func download(_ id: String, changed: @escaping @Sendable () -> Void) {
        guard let m = Self.models.first(where: { $0.id == id }), let bin = Self.helperPath() else { return }
        lock.lock()
        guard downloads[id] == nil, !have.contains(id) else { lock.unlock(); return }
        try? FileManager.default.createDirectory(atPath: Self.dir, withIntermediateDirectories: true)
        let p = Process(), out = Pipe()
        p.executableURL = URL(fileURLWithPath: bin); p.arguments = ["download", m.id, Self.marker(m)]
        p.standardOutput = out; p.standardError = FileHandle.nullDevice
        out.fileHandleForReading.readabilityHandler = { [weak self] h in   // "progress 0.42" and "error <why>" lines
            let d = h.availableData
            guard let self, !d.isEmpty else { h.readabilityHandler = nil; return }
            lock.lock()
            guard var dl = downloads[id], dl.proc === p else { lock.unlock(); return }
            var lines = (dl.rest + String(decoding: d, as: UTF8.self)).components(separatedBy: "\n")
            dl.rest = lines.removeLast()
            for l in lines {
                if l.hasPrefix("progress "), let f = Double(l.dropFirst(9)) { dl.progress = min(1, f) }
                if l.hasPrefix("error ") { dl.why = String(l.dropFirst(6)) }
            }
            let ping = Date().timeIntervalSince(dl.pinged) >= 0.25   // ≤4 page updates a second
            if ping { dl.pinged = Date() }
            downloads[id] = dl; lock.unlock()
            if ping { changed() }
        }
        p.terminationHandler = { [weak self] p in
            guard let self else { return }
            lock.lock()
            if let dl = downloads[id], dl.proc === p {   // cancelled meanwhile: no error
                downloads[id] = nil
                if p.terminationStatus != 0 { error = dl.why.isEmpty ? Self.offline : dl.why }
            }
            lock.unlock(); refresh(); changed()
        }
        downloads[id] = Download(proc: p); error = nil
        lock.unlock()
        do { try p.run() } catch { lock.withLock { downloads[id] = nil; self.error = "Couldn’t start the Parakeet helper." } }
        changed()
    }
    func cancel(_ id: String) {
        lock.lock(); let d = downloads.removeValue(forKey: id); lock.unlock()
        d?.proc.terminate()   // its termination handler repaints
    }
    func delete(_ id: String) {
        guard let m = Self.models.first(where: { $0.id == id }) else { return }
        lock.lock(); let using = serving == id; error = nil; lock.unlock()
        if using { stop() }
        // only a folder in FluidAudio's model cache: the marker is a plain file
        if let folder = try? String(contentsOfFile: Self.marker(m), encoding: .utf8), folder.hasPrefix(Self.cache), !folder.contains("/../") {
            try? FileManager.default.removeItem(atPath: folder)
        }
        try? FileManager.default.removeItem(atPath: Self.marker(m)); refresh()
    }

    func warm() { _ = try? ensure() }
    func restart() { lock.lock(); let was = conn != nil; lock.unlock(); stop(); if was { warm() } }   // only a running helper moves to the new model
    func stop() {
        lock.lock(); defer { lock.unlock() }
        idle?.cancel(); idle = nil; up?.cancel(); up = nil
        conn?.proc.terminate(); conn = nil; serving = nil
    }
    private func drop(_ c: Conn) { lock.lock(); let mine = conn === c; lock.unlock(); if mine { stop() } }   // a newer helper stays

    private func ensure() throws -> (Task<Bool, Never>, Conn) {
        lock.lock(); defer { lock.unlock() }
        let m = Self.model(Prefs.str("parakeetModel"))
        touch()
        if let up, let conn, conn.proc.isRunning, serving == m.id { return (up, conn) }
        guard let bin = Self.helperPath() else { throw Failed("The Parakeet helper is missing. Run ./build.sh again.") }
        guard FileManager.default.fileExists(atPath: Self.marker(m)) else { throw Failed("The \(m.name) model isn’t downloaded.") }
        up?.cancel(); conn?.proc.terminate()   // only the helper this Aurel started
        let p = Process(), i = Pipe(), o = Pipe()
        p.executableURL = URL(fileURLWithPath: bin); p.arguments = ["serve", m.id]
        p.standardInput = i; p.standardOutput = o; p.standardError = FileHandle.nullDevice
        fcntl(i.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)   // a helper that quit makes the write throw, not kill Aurel
        try p.run()
        let c = Conn(p, i.fileHandleForWriting, o.fileHandleForReading), q = queue
        conn = c; serving = m.id
        let t = Task.detached { await withCheckedContinuation { k in q.async { k.resume(returning: c.line() == "ready") } } }
        up = t; return (t, c)
    }
    private func touch() {   // caller holds lock
        idle?.cancel(); idle = nil
        guard let after = Prefs.unloadAfter() else { return }   // Never: stays loaded until Aurel quits
        let w = DispatchWorkItem { [weak self] in self?.stop() }
        idle = w; DispatchQueue.main.asyncAfter(deadline: .now() + after, execute: w)
    }

    func transcribe(_ pcm: [Float]) async throws -> String {
        guard pcm.count > 16000 * 3 / 10 else { return "" }   // under 0.3 s is a tap
        let (up, c) = try ensure()
        guard await up.value else { drop(c); throw Failed("Parakeet didn’t start.") }   // the next try starts a fresh one
        let body = Self.request(pcm)
        let reply: String? = await withCheckedContinuation { k in queue.async { k.resume(returning: (try? c.input.write(contentsOf: body)) == nil ? nil : c.line()) } }
        lock.withLock { touch() }
        guard let reply, let json = (try? JSONSerialization.jsonObject(with: Data(reply.utf8))) as? [String: String] else { drop(c); throw Failed("Parakeet stopped.") }
        if let why = json["error"] { throw Failed(why) }
        return (json["text"] ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
    static func request(_ pcm: [Float]) -> Data {   // UInt32 sample count, then the Float32 samples, little-endian
        var d = Data(capacity: 4 + pcm.count * 4)
        withUnsafeBytes(of: UInt32(pcm.count).littleEndian) { d.append(contentsOf: $0) }
        for v in pcm { withUnsafeBytes(of: v.bitPattern.littleEndian) { d.append(contentsOf: $0) } }
        return d
    }
}
// MARK: end Parakeet
// MARK: Local AI
import CryptoKit   // here, not at the top: tests compile slices of this file that include this block
// Settings → Intelligence → Local: llama.cpp's llama-server and one GGUF model, both downloaded once by Aurel (checksum-pinned)
// into ~/.config/aurel/llm. Nothing else to install. Aurel runs the server on a free 127.0.0.1 port and gives aurel.py
// its address as AUREL_LLM. A tiny sh wrapper kills it when Aurel dies (no orphans); the idle time in Settings stops it too.
final class LocalAI: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    static let shared = LocalAI()
    struct Model { let id, name, url, file, sha256: String; let bytes: Int64 }
    #if arch(arm64)
    static var runtime = Model(id: "runtime", name: "llama.cpp", url: "https://github.com/ggml-org/llama.cpp/releases/download/b11606/llama-b11606-bin-macos-arm64.tar.gz",
                               file: "llama-b11606.tar.gz", sha256: "a39c5a9c4bbb5b989ed9274300629d5feb5920e52c3257a8e615f3868db44f35", bytes: 11_000_000)
    #else
    static var runtime = Model(id: "runtime", name: "llama.cpp", url: "https://github.com/ggml-org/llama.cpp/releases/download/b11606/llama-b11606-bin-macos-x64.tar.gz",
                               file: "llama-b11606.tar.gz", sha256: "bd7c149424dc6350e2501bdfdb676dbe4f4f34580b0d890f3e8f963cc2acbbc5", bytes: 11_000_000)
    #endif
    static var models = [   // the first is the default; the router benchmark (tests/evals/local_router_bench.py) picked it
        Model(id: "gemma4", name: "Gemma 4 E4B", url: "https://huggingface.co/google/gemma-4-E4B-it-qat-q4_0-gguf/resolve/4b4a2c1d584be7264f87aac328a1bc739ce81b6c/gemma-4-E4B_q4_0-it.gguf",
              file: "gemma-4-E4B_q4_0-it.gguf", sha256: "676c35070db6dbe52f93e9c864ee0fba4eddea94b9c875d9cb10daff453fbaee", bytes: 5_154_941_280),
        Model(id: "qwen36", name: "Qwen 3.6 35B", url: "https://huggingface.co/unsloth/Qwen3.6-35B-A3B-GGUF/resolve/a483e9e6cbd595906af30beda3187c2663a1118c/Qwen3.6-35B-A3B-UD-Q4_K_M.gguf",
              file: "Qwen3.6-35B-A3B-UD-Q4_K_M.gguf", sha256: "ac0e2c1189e055faa36eff361580e79c5bd6f8e76bffb4ce547f167d53e31a61", bytes: 22_134_528_992)]
    static func model(_ id: String) -> Model { models.first { $0.id == id } ?? models[0] }
    static var dir: String { (Prefs.path as NSString).deletingLastPathComponent + "/llm" }
    static func path(_ m: Model) -> String { dir + "/" + m.file }
    static var server: String { dir + "/llama-b11606/llama-server" }   // the runtime, unpacked
    struct Failed: LocalizedError { let errorDescription: String?; init(_ why: String) { errorDescription = why } }
    static let offline = "Download failed. Check your connection and try again."

    private struct Download { let task: URLSessionDownloadTask, changed: @Sendable () -> Void; var progress = 0.0, pinged = Date.distantPast }
    private let lock = NSLock()
    private var proc: Process?, port = 0, serving: String?, idle: DispatchWorkItem?
    private struct User { weak var p: Process? }
    private var users: [User] = [], used = Date()   // foreground workers using the server: idle time starts when the last one ends
    private var hasRuntime = false, have: Set<String> = [], downloads: [String: Download] = [:], error: String?
    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)   // touched under lock

    private override init() {
        super.init(); refresh()
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in self?.stop() }
    }

    // File checks happen here (settings open, downloads, deletes); `ready` only reads the cache.
    private func refresh() {
        let r = FileManager.default.isExecutableFile(atPath: Self.server), h = Set(Self.models.filter { FileManager.default.fileExists(atPath: Self.path($0)) }.map(\.id))
        lock.lock(); hasRuntime = r; have = h; lock.unlock()
    }
    var ready: Bool {   // a miss looks again: a download may have finished since
        let ok = { self.lock.withLock { self.hasRuntime && self.have.contains(Self.model(Prefs.str("localModel")).id) } }
        if ok() { return true }
        refresh(); return ok()
    }

    func status() -> [String: Any] {
        refresh()
        lock.lock(); defer { lock.unlock() }
        return ["server": hasRuntime, "runtime": downloads[Self.runtime.id].map { $0.progress as Any } ?? NSNull(), "model": Self.model(Prefs.str("localModel")).id,
                "running": proc?.isRunning == true, "error": error ?? NSNull(), "ram": ProcessInfo.processInfo.physicalMemory >> 30,
                "models": Self.models.map { m -> [String: Any] in
                    ["id": m.id, "name": m.name, "size": ByteCountFormatter.string(fromByteCount: m.bytes, countStyle: .file), "have": have.contains(m.id),
                     "progress": downloads[m.id].map { $0.progress as Any } ?? NSNull()] }]
    }

    // A model's Download also fetches the runtime the first time. Each goes to <file>.part, has its sha256 checked, then is
    // renamed into place (the runtime is unpacked instead): a half or wrong file never looks installed.
    func download(_ id: String, changed: @escaping @Sendable () -> Void) {
        guard let m = Self.models.first(where: { $0.id == id }) else { return }
        refresh()
        lock.lock()
        let fetch = (hasRuntime ? [] : [Self.runtime]) + (have.contains(id) ? [] : [m])
        for f in fetch where downloads[f.id] == nil {
            guard let url = URL(string: f.url) else { continue }
            let t = session.downloadTask(with: url); t.taskDescription = f.id
            downloads[f.id] = Download(task: t, changed: changed); t.resume()
        }
        if !fetch.isEmpty { error = nil }
        lock.unlock(); changed()
    }
    func cancel(_ id: String) {
        lock.lock(); let d = [id, Self.runtime.id].compactMap { downloads.removeValue(forKey: $0) }; lock.unlock()
        for x in d { x.task.cancel(); try? FileManager.default.removeItem(atPath: Self.path(x.task.taskDescription == Self.runtime.id ? Self.runtime : Self.model(id)) + ".part") }
        d.first?.changed()
    }
    func delete(_ id: String) {
        guard let m = Self.models.first(where: { $0.id == id }) else { return }
        lock.lock(); let using = serving == id; error = nil; lock.unlock()
        if using { stop() }
        try? FileManager.default.removeItem(atPath: Self.path(m)); refresh()
    }
    private func item(_ id: String) -> Model { id == Self.runtime.id ? Self.runtime : Self.model(id) }

    func urlSession(_ s: URLSession, downloadTask t: URLSessionDownloadTask, didWriteData _: Int64, totalBytesWritten done: Int64, totalBytesExpectedToWrite all: Int64) {
        guard let id = t.taskDescription else { return }
        lock.lock()
        guard var d = downloads[id], d.task === t else { lock.unlock(); return }
        d.progress = min(1, Double(done) / Double(all > 0 ? all : item(id).bytes))
        let ping = Date().timeIntervalSince(d.pinged) >= 0.25   // ≤4 page updates a second
        if ping { d.pinged = Date() }
        downloads[id] = d; lock.unlock()
        if ping { d.changed() }
    }
    func urlSession(_ s: URLSession, downloadTask t: URLSessionDownloadTask, didFinishDownloadingTo tmp: URL) {
        guard let id = t.taskDescription else { return }
        let m = item(id), dest = Self.path(m), part = dest + ".part", fm = FileManager.default
        var why: String?
        if (t.response as? HTTPURLResponse)?.statusCode != 200 { why = Self.offline } else {
            try? fm.createDirectory(atPath: Self.dir, withIntermediateDirectories: true); try? fm.removeItem(atPath: part)
            if (try? fm.moveItem(at: tmp, to: URL(fileURLWithPath: part))) == nil { why = "Couldn’t save the download. Check free space and try again." }
            else if Self.sha256(part) != m.sha256 { why = "The download didn’t match. Try again." }
        }
        lock.lock(); let live = downloads[id]?.task === t; if live { error = why }; lock.unlock()   // cancelled meanwhile: drop it
        if live && why == nil && id == Self.runtime.id {
            if !Self.unpack(part) { lock.withLock { error = "Couldn’t unpack llama.cpp. Try again." } }
            try? fm.removeItem(atPath: part); return
        }
        if !live || why != nil || rename(part, dest) != 0 { try? fm.removeItem(atPath: part) }
    }
    func urlSession(_ s: URLSession, task t: URLSessionTask, didCompleteWithError e: Error?) {
        guard let id = t.taskDescription else { return }
        lock.lock()
        guard let d = downloads[id], d.task === t else { lock.unlock(); return }
        downloads[id] = nil
        if e != nil { error = Self.offline }
        lock.unlock()
        refresh(); d.changed()
    }
    static func unpack(_ tarball: String) -> Bool {   // into a scratch folder, then swapped in whole
        let fm = FileManager.default, scratch = dir + "/.unpack", final = (server as NSString).deletingLastPathComponent
        try? fm.removeItem(atPath: scratch); try? fm.createDirectory(atPath: scratch, withIntermediateDirectories: true)
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/tar"); p.arguments = ["-xzf", tarball, "-C", scratch]
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        let unpacked = scratch + "/" + (final as NSString).lastPathComponent
        guard p.terminationStatus == 0, fm.isExecutableFile(atPath: unpacked + "/llama-server") else { try? fm.removeItem(atPath: scratch); return false }
        try? fm.removeItem(atPath: final)
        defer { try? fm.removeItem(atPath: scratch) }
        return (try? fm.moveItem(atPath: unpacked, toPath: final)) != nil
    }
    static func sha256(_ path: String) -> String? {   // streamed: a 5 GB model never sits in memory
        guard let f = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? f.close() }
        var h = SHA256()
        while let chunk = try? f.read(upToCount: 1 << 22), !chunk.isEmpty { h.update(data: chunk) }
        return h.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // The server's address for aurel.py, starting it if needed; aurel.py waits for /health. Empty when nothing is downloaded.
    func address() -> String { (try? ensure()).map { "http://127.0.0.1:\($0)" } ?? "" }
    func restart() { lock.lock(); let was = proc != nil; lock.unlock(); stop(); if was { _ = address() } }   // only a running server moves to the new model
    func stop() {
        lock.lock(); defer { lock.unlock() }
        idle?.cancel(); idle = nil
        proc?.terminate(); proc = nil; serving = nil   // the wrapper's trap takes its server down with it
        try? FileManager.default.removeItem(atPath: Self.dir + "/address")
    }

    private func ensure() throws -> Int {
        lock.lock(); defer { lock.unlock() }
        let m = Self.model(Prefs.str("localModel")), file = Self.path(m)
        touch()
        if proc?.isRunning == true, serving == m.id { return port }
        guard FileManager.default.isExecutableFile(atPath: Self.server) else { throw Failed("llama.cpp isn’t downloaded.") }
        guard FileManager.default.fileExists(atPath: file) else { throw Failed("The \(m.name) model isn’t downloaded.") }
        guard let free = Self.freePort() else { throw Failed("No free port for the local model.") }
        proc?.terminate()   // only the server this Aurel started
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Two slots, so the router's prompt and the full ask's each stay cached; -c: 16K each for the prompt, window text and
        // a few steps. Thinking off: a voice ask can't wait for it.
        p.arguments = ["-c", """
            "$0" -m "$1" --host 127.0.0.1 --port \(free) -c 32768 -np 2 -ngl 99 --no-webui --reasoning-budget 0 & s=$!
            trap 'kill $s 2>/dev/null; exit 0' TERM INT
            while kill -0 \(getpid()) 2>/dev/null && kill -0 $s 2>/dev/null; do sleep 1 & wait $!; done
            kill $s 2>/dev/null
            """, Self.server, file]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try p.run()
        proc = p; port = free; serving = m.id
        try? "http://127.0.0.1:\(free)".write(toFile: Self.dir + "/address", atomically: true, encoding: .utf8)   // local agents outlive one server: they re-read it
        return free
    }
    func use(_ p: Process) { lock.withLock { users.append(User(p: p)) } }
    private func touch() { used = Date(); arm() }   // caller holds lock
    private func arm() {   // caller holds lock; looks every 20 s at most, so a long ask keeps the server it is using
        idle?.cancel(); idle = nil
        guard let after = Prefs.unloadAfter() else { return }   // Never: stays loaded until Aurel quits
        let w = DispatchWorkItem { [weak self] in self?.idleCheck(after) }
        idle = w; DispatchQueue.main.asyncAfter(deadline: .now() + min(after, 20), execute: w)
    }
    private func idleCheck(_ after: TimeInterval) {
        lock.lock()
        if users.contains(where: { $0.p?.isRunning == true }) { used = Date() }
        users.removeAll { $0.p.map { $0.processIdentifier != 0 && !$0.isRunning } ?? true }   // ended; one not started yet stays
        let quiet = Date().timeIntervalSince(used) >= after
        if !quiet { arm() }
        lock.unlock()
        if quiet { stop() }
    }
    static func freePort() -> Int? {   // the kernel picks an unused port; the server binds it right after
        let s = socket(AF_INET, SOCK_STREAM, 0); guard s >= 0 else { return nil }
        defer { close(s) }
        var a = sockaddr_in(); a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); a.sin_family = sa_family_t(AF_INET); a.sin_addr.s_addr = inet_addr("127.0.0.1")
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ok = withUnsafeMutablePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(s, $0, len) == 0 && getsockname(s, $0, &len) == 0 } }
        return ok ? Int(UInt16(bigEndian: a.sin_port)) : nil
    }
}
// MARK: end Local AI
func microphoneChoices() -> [[String: String]] { microphones().map { ["uid": $0.uid, "name": $0.name] } }

struct AudioVolumeSnapshot: Codable, Equatable {
    let uid: String, selector: UInt32, volume: Float32
    let owner: Int32
}
protocol AudioVolumeLayer {
    func snapshot() -> AudioVolumeSnapshot?
    @discardableResult func set(_ snapshot: AudioVolumeSnapshot, volume: Float32) -> Bool
}
struct CoreAudioVolume: AudioVolumeLayer {
    func snapshot() -> AudioVolumeSnapshot? {
        let sys = AudioObjectID(kAudioObjectSystemObject)
        guard let device = audioProp(sys, kAudioHardwarePropertyDefaultOutputDevice, AudioDeviceID(0)).first,
              device != 0, let uid = audioString(device, kAudioDevicePropertyDeviceUID) else { return nil }
        for selector in [kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyVolumeScalar] {
            var a = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
            var settable: DarwinBoolean = false, value: Float32 = 0, size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectHasProperty(device, &a), AudioObjectIsPropertySettable(device, &a, &settable) == noErr, settable.boolValue,
               AudioObjectGetPropertyData(device, &a, 0, nil, &size, &value) == noErr {
                return AudioVolumeSnapshot(uid: uid, selector: selector, volume: value, owner: getpid())
            }
        }
        return nil   // HDMI and other fixed-volume outputs cannot be safely quieted.
    }
    func set(_ snapshot: AudioVolumeSnapshot, volume: Float32) -> Bool {
        guard let device = audioProp(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices, AudioDeviceID(0)).first(where: {
            audioString($0, kAudioDevicePropertyDeviceUID) == snapshot.uid
        }) else { return false }
        var a = AudioObjectPropertyAddress(mSelector: snapshot.selector, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var value = volume
        return AudioObjectSetPropertyData(device, &a, 0, nil, UInt32(MemoryLayout<Float32>.size), &value) == noErr
    }
}
final class AudioQuiet {
    let layer: any AudioVolumeLayer
    var changed: (AudioVolumeSnapshot?) -> Void
    private let later: (TimeInterval, @escaping () -> Void) -> Void
    private var original: AudioVolumeSnapshot?, scale: Float32 = 1, generation = 0, active = false
    init(layer: any AudioVolumeLayer, changed: @escaping (AudioVolumeSnapshot?) -> Void = { _ in },
         later: @escaping (TimeInterval, @escaping () -> Void) -> Void = { delay, work in DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work) }) {
        self.layer = layer; self.changed = changed; self.later = later
    }
    func begin(_ enabled: Bool, level: Float32 = 0.18) {
        guard enabled else { return }
        if original == nil {
            guard let snapshot = layer.snapshot() else { return }
            original = snapshot; scale = 1; changed(snapshot)
        }
        active = true; ramp(to: level)
    }
    func end(immediate: Bool = false) {
        guard let snapshot = original, active || immediate else { return }
        active = false
        if immediate {
            generation += 1; scale = 1
            if layer.set(snapshot, volume: snapshot.volume) { original = nil; changed(nil) }
            else { later(1) { [weak self] in self?.end(immediate: true) } }
            return
        }
        ramp(to: 1)
    }
    private func ramp(to target: Float32) {
        guard original != nil else { return }
        generation += 1; let mine = generation, from = scale, steps = 6
        for step in 1...steps {
            later(Double(step) * 0.025) { [weak self] in
                guard let self, generation == mine, let original else { return }
                scale = from + (target - from) * Float32(step) / Float32(steps)
                let restored = layer.set(original, volume: original.volume * scale)
                if step == steps, target == 1, restored { self.original = nil; changed(nil) }
                if step == steps, target == 1, !restored { later(1) { [weak self] in self?.end(immediate: true) } }
            }
        }
    }
    deinit { end(immediate: true) }
}
enum AudioRecovery {
    static var marker: URL?
    static let prefix = ".aurel-audio-"
    static var folder: URL { URL(fileURLWithPath: (Prefs.path as NSString).deletingLastPathComponent, isDirectory: true) }
    static func read(_ url: URL) -> AudioVolumeSnapshot? { try? JSONDecoder().decode(AudioVolumeSnapshot.self, from: Data(contentsOf: url)) }
    static func restore(_ url: URL) {
        guard let snapshot = read(url), CoreAudioVolume().set(snapshot, volume: snapshot.volume) else { return }
        try? FileManager.default.removeItem(at: url)
    }
    static func changed(_ snapshot: AudioVolumeSnapshot?) {
        if let snapshot {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent(prefix + UUID().uuidString + ".json")
            guard let data = try? JSONEncoder().encode(snapshot), (try? data.write(to: url, options: .atomic)) != nil else { return }
            marker = url
            let watcher = Process(); watcher.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            watcher.arguments = ["--restore-audio", url.path, String(snapshot.owner)]; try? watcher.run()
        } else if let marker {
            try? FileManager.default.removeItem(at: marker); self.marker = nil
        }
    }
    static func start() {
        let args = CommandLine.arguments
        if args.count == 4, args[1] == "--restore-audio", let owner = Int32(args[3]) {
            let url = URL(fileURLWithPath: args[2])
            while FileManager.default.fileExists(atPath: url.path), kill(owner, 0) == 0 { usleep(100_000) }
            restore(url); exit(0)
        }
        recoverStale()
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in recoverStale() }
    }
    static func recoverStale() {
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] where name.hasPrefix(prefix) {
            let url = folder.appendingPathComponent(name)
            if let snapshot = read(url), kill(snapshot.owner, 0) != 0 { restore(url) }
        }
    }
}
AudioRecovery.start()

// What read-aloud says: an answer's words without its Markdown marks, its TeX math read loosely ("root 7 over 8").
func spoken(_ answer: String) -> String {
    var s = answer
    let math = try! NSRegularExpression(pattern: #"\$\$([\s\S]+?)\$\$|\\\(([\s\S]+?)\\\)|\\\[([\s\S]+?)\\\]|(?<!\\)\$(?=\S)([^$\n]+?)(?<=\S)\$(?!\d)"#)   // the page's rule: "$5 or $10" is money
    for m in math.matches(in: s, range: NSRange(s.startIndex..., in: s)).reversed() {
        guard let whole = Range(m.range, in: s), let inner = (1...4).lazy.compactMap({ Range(m.range(at: $0), in: s) }).first else { continue }
        var t = String(s[inner])
        for _ in 0..<3 { t = t.replacingOccurrences(of: #"\\sqrt\{([^{}]*)\}"#, with: " root $1 ", options: .regularExpression).replacingOccurrences(of: #"\\[dt]?frac\{([^{}]*)\}\{([^{}]*)\}"#, with: " $1 over $2 ", options: .regularExpression) }
        for (p, r) in [(#"\\(cdot|times)"#, " times "), (#"\^"#, " to the "), (#"\\[a-zA-Z]+|[{}_\\&]"#, " ")] { t = t.replacingOccurrences(of: p, with: r, options: .regularExpression) }
        s.replaceSubrange(whole, with: t)
    }
    s = (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))).map { String($0.characters) } ?? s
    return s.replacingOccurrences(of: #"(?m)^#{1,4}\s+"#, with: "", options: .regularExpression).replacingOccurrences(of: #" {2,}"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
}

// Read-aloud uses the Mac's saved voice explicitly: bare say can ignore Spoken Content.
struct ReadAloudVoice {
    let name: String, language: String, quality: AVSpeechSynthesisVoiceQuality
    var identifier: String = ""
}
func bestEnglishVoice(_ voices: [ReadAloudVoice], region: String?) -> ReadAloudVoice? {
    func rank(_ q: AVSpeechSynthesisVoiceQuality) -> Int { q == .premium ? 2 : q == .enhanced ? 1 : 0 }
    return voices.filter { $0.language.lowercased().hasPrefix("en") && ($0.quality == .premium || $0.quality == .enhanced) }.sorted {
        let quality = rank($0.quality) - rank($1.quality)
        if quality != 0 { return quality > 0 }
        let local = Locale(identifier: $0.language).region?.identifier == region
        let other = Locale(identifier: $1.language).region?.identifier == region
        return local != other ? local : $0.name < $1.name
    }.first
}
func sayVoiceNames(_ output: String) -> Set<String> {
    Set(output.split(separator: "\n").compactMap { line in
        line.range(of: #"\s+[a-z]{2,3}_[A-Z0-9]{2,3}\s+#"#, options: .regularExpression).map { String(line[..<$0.lowerBound]) }
    })
}
func sayVoiceName(_ name: String, names: Set<String>) -> String? {
    if names.contains(name) { return name }
    for quality in ["Premium", "Enhanced"] where names.contains("\(name) (\(quality))") { return "\(name) (\(quality))" }
    return names.sorted().first { $0.hasPrefix(name + " (") }
}
// "" means bare say: before macOS 27 it speaks a saved system voice that neither list shows (such as Siri).
func preferredReadAloudVoice(_ selections: [Any], voices: [ReadAloudVoice], names: Set<String>, selected: String, region: String?, majorVersion: Int, language: String = "en") -> String? {
    func sayName(_ voice: ReadAloudVoice) -> String? {
        let quality = voice.quality == .premium ? "Premium" : voice.quality == .enhanced ? "Enhanced" : ""
        let qualified = "\(voice.name) (\(quality))"
        return !quality.isEmpty && names.contains(qualified) ? qualified : sayVoiceName(voice.name, names: names)
    }
    func base(_ code: String) -> String { String(code.lowercased().prefix { $0.isLetter }) }   // "en-US" -> "en"
    if !selected.isEmpty, names.contains(selected) { return selected }
    var byLanguage: [String: String] = [:], key = ""   // saved as ["en", {voiceId}, "es", {voiceId}]
    for entry in selections {
        if let k = entry as? String { key = base(k) }
        else if let id = (entry as? [String: Any])?["voiceId"] as? String, byLanguage[key] == nil { byLanguage[key] = id }
    }
    let saved = [base(language), "en"].compactMap { byLanguage[$0] }   // the answer's language first, then English
    for id in saved {
        if let voice = voices.first(where: { $0.identifier == id }), let name = sayName(voice) { return name }
        if id == byLanguage[base(language)], base(language) != "en" { return "" }   // the answer's language saved as a voice say can't name (Siri): the system's, not an English one
    }
    if !saved.isEmpty && majorVersion < 27 { return "" }
    let usable = voices.filter { sayName($0) != nil }
    return bestEnglishVoice(usable, region: region).flatMap { sayName($0) }
}
// Listed once per launch, as before: a voice downloaded later is used after Aurel relaunches.
let installedSayVoices: Set<String>? = {
    let p = Process(), out = Pipe()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/say"); p.arguments = ["-v", "?"]; p.standardOutput = out
    do { try p.run() } catch { return nil }
    let names = sayVoiceNames(String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    p.waitUntilExit()
    return p.terminationStatus == 0 ? names : nil
}()
func usableReadAloudVoice(_ words: String) -> String? {
    guard let names = installedSayVoices else { return nil }
    let voices = AVSpeechSynthesisVoice.speechVoices().map {
        ReadAloudVoice(name: $0.name, language: $0.language, quality: $0.quality, identifier: $0.identifier)
    }
    // shortcut: Apple's selection schema is undocumented; use an installed fallback until a public selection API exists.
    let selections = CFPreferencesCopyAppValue("SpokenContentDefaultVoiceSelectionsByLanguage" as CFString, "com.apple.Accessibility" as CFString) as? [Any] ?? []
    return preferredReadAloudVoice(selections, voices: voices, names: names, selected: Prefs.str("voice"), region: Locale.current.region?.identifier, majorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
                                   language: NLLanguageRecognizer.dominantLanguage(for: words)?.rawValue ?? "en")
}
func readAloudArguments(_ words: String, pick: (String) -> String? = usableReadAloudVoice, compactTip: () -> Void) -> [String] {
    let voice = pick(words)
    if voice == nil { compactTip() }
    return (voice.flatMap { $0.isEmpty ? nil : ["-v", $0] } ?? []) + ["--", words]
}

// The talk shortcut, any key plus modifiers, recorded in Settings: Carbon modifiers to register, and the
// modifier keys whose release ends listening (none for a lone F-key: its own key-up ends it).
let aurelFnKey = 1 << 20   // Carbon has no Fn bit; Fn shortcuts use the event monitor below.
func shortcutModifiers(_ f: NSEvent.ModifierFlags) -> Int {
    (f.contains(.command) ? cmdKey : 0) | (f.contains(.shift) ? shiftKey : 0) |
    (f.contains(.option) ? optionKey : 0) | (f.contains(.control) ? controlKey : 0) |
    (f.contains(.function) ? aurelFnKey : 0)
}
func shortcutModifierLabel(_ f: NSEvent.ModifierFlags) -> String {
    (f.contains(.function) ? "fn" : "") + (f.contains(.control) ? "⌃" : "") +
    (f.contains(.option) ? "⌥" : "") + (f.contains(.shift) ? "⇧" : "") + (f.contains(.command) ? "⌘" : "")
}
func configuredHotkey(_ stem: String = "hotkey") -> (code: Int, mods: Int, flags: NSEvent.ModifierFlags) {
    let m = Int(Prefs.num(stem + "Mods"))
    var f: NSEvent.ModifierFlags = []
    if m & cmdKey != 0 { f.insert(.command) }; if m & shiftKey != 0 { f.insert(.shift) }
    if m & optionKey != 0 { f.insert(.option) }; if m & controlKey != 0 { f.insert(.control) }
    if m & aurelFnKey != 0 { f.insert(.function) }
    return (Int(Prefs.num(stem + "Code")), m, f)
}
func hotkey() -> (code: Int, mods: Int, flags: NSEvent.ModifierFlags) { configuredHotkey() }
func dictateHotkey() -> (code: Int, mods: Int, flags: NSEvent.ModifierFlags) { configuredHotkey("dictateHotkey") }
// Dictation is fn alone and macOS's own "Press 🌐 key to" action (emoji, input source, its dictation) fires on that press too.
// 0 is Do Nothing; unset means the system default action.
func globeKeyTaken() -> Bool {
    let h = dictateHotkey(), domain = "com.apple.HIToolbox" as CFString
    guard !Prefs.str("dictateHotkeyLabel").isEmpty, h.code < 0, h.mods == aurelFnKey else { return false }
    CFPreferencesAppSynchronize(domain)
    return (CFPreferencesCopyAppValue("AppleFnUsageType" as CFString, domain) as? Int ?? 1) != 0
}

func transcriptKey(_ s: String) -> String {
    s.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: " .,!?:;"))
}

func stitchTranscript(_ prefix: String, _ suffix: String) -> String {
    let a = prefix.split(whereSeparator: { $0.isWhitespace }), b = suffix.split(whereSeparator: { $0.isWhitespace })
    guard !a.isEmpty else { return suffix }
    guard !b.isEmpty else { return prefix }
    func key(_ word: Substring) -> String { word.lowercased().trimmingCharacters(in: .punctuationCharacters) }
    let limit = min(24, a.count, b.count)
    let overlap = stride(from: limit, through: 1, by: -1).first { n in
        zip(a.suffix(n), b.prefix(n)).allSatisfy { key($0) == key($1) }
    } ?? 0
    return (a + b.dropFirst(overlap)).joined(separator: " ")
}

final class SpeechInputs: @unchecked Sendable {
    private let lock = NSLock()
    private var feeds: [UUID: AsyncStream<AnalyzerInput>.Continuation] = [:]
    func add(_ feed: AsyncStream<AnalyzerInput>.Continuation) -> UUID {
        let id = UUID(); lock.lock(); feeds[id] = feed; lock.unlock(); return id
    }
    func yield(_ input: AnalyzerInput) {
        lock.lock(); let current = Array(feeds.values); lock.unlock()
        current.forEach { $0.yield(input) }
    }
    func finish(_ id: UUID) {
        lock.lock(); let feed = feeds.removeValue(forKey: id); lock.unlock(); feed?.finish()
    }
    func finishAll() {
        lock.lock(); let current = Array(feeds.values); feeds.removeAll(); lock.unlock()
        current.forEach { $0.finish() }
    }
}

// aurel.py with whatever python3 this Mac has (Homebrew's first, else Apple's); its sh header runs it from cached bytecode.
func py(_ args: [String], _ extra: [String: String] = [:]) -> Process {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = [dir + "/aurel.py"] + args
    var env = ProcessInfo.processInfo.environment
    env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
    env["AUREL_APP"] = Bundle.main.executablePath
    // the workers that think get the local model's address; asking for it starts the server, so others don't
    let thinks = ["--wait", "--dictate-cleanup-wait", "--agents"]
    if Prefs.str("client") == "local", let first = args.first, thinks.contains(first) {
        env["AUREL_LLM"] = LocalAI.shared.address()
        if first != "--agents" { LocalAI.shared.use(p) }   // agents keep it loaded their own way (Agents.tick)
    }
    if Prefs.str("client") == "local", LocalAI.shared.ready { env["AUREL_LLM_READY"] = "1" }   // setup checks: nothing left to download
    env.merge(extra) { $1 }
    p.environment = env
    return p
}

func telemetry(_ args: [String]) {
    guard Prefs.bool("stats") else { return }
    let p = py(["--telemetry"] + args)
    p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
    try? p.run()   // its curl child outlives this helper; never wait on an ask
}


// The screen under the mouse, else the main one.
var mouseScreen: NSScreen { NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main! }
// Every floating surface's one follow check: where a frame jumps once the pointer is on another display (same nearer side and
// offsets, clamped there), or nil to stay. Callers set it without an animator so it never shows on both displays or crosses the gap.
func pointerFollow(_ f: NSRect) -> NSRect? {
    let to = mouseScreen.visibleFrame
    guard NSEvent.pressedMouseButtons == 0, let from = NSScreen.screens.first(where: { $0.frame.contains(NSPoint(x: f.midX, y: f.midY)) })?.visibleFrame, from != to else { return nil }
    return PanelFrame.clamp(PanelFrame.follow(f, from, to, right: f.midX > from.midX, top: f.midY > from.midY), to)
}

// Freeze the display where the ask began before live actions can move the cursor or box.
func currentRequestScreen(_ box: NSWindow? = nil) -> String {
    ((box?.isVisible == true ? box?.screen : nil) ?? mouseScreen).localizedName
}

func axAttribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}
// AX has no public window-number attribute ("AXWindowNumber" is always nil); this private call is the one Rectangle/yabai/AltTab use.
@_silgen_name("_AXUIElementGetWindow") func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError
func axWindowNumber(_ element: AXUIElement) -> NSNumber? {
    var id: CGWindowID = 0
    return _AXUIElementGetWindow(element, &id) == .success && id > 0 ? NSNumber(value: id) : nil
}

// A paste borrows the clipboard for one ⌘V: the text is marked transient (clipboard managers skip it), and the returned
// restore puts back the user's own items, every type, unless something else was copied meanwhile. nil: nothing was borrowed.
func borrowPasteboard(_ text: String, _ pb: NSPasteboard = .general) -> (() -> Void)? {
    let saved = pb.pasteboardItems?.map { i in i.types.compactMap { t in i.data(forType: t).map { (t, $0) } } } ?? []
    let put = { pb.clearContents(); _ = pb.writeObjects(saved.map { pairs in let i = NSPasteboardItem(); pairs.forEach { i.setData($1, forType: $0) }; return i }) }
    pb.clearContents()
    guard pb.setString(text, forType: .string) else { put(); return nil }
    pb.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
    let changed = pb.changeCount
    return { if pb.changeCount == changed { put() } }
}

struct TextSelection {
    let element: AXUIElement, focus: AXUIElement, app: NSRunningApplication, text: String, range: CFRange?
    enum Delivery { case landed, unchanged, unknown }
    static let settle: TimeInterval = 0.05
    static func string(_ value: CFTypeRef?) -> String? {
        value as? String ?? (value as? NSAttributedString)?.string
    }
    static func parent(_ element: AXUIElement) -> AXUIElement? {
        guard let value = axAttribute(element, kAXParentAttribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
    static func capture(_ app: NSRunningApplication? = NSWorkspace.shared.frontmostApplication, enabled: Bool = Prefs.bool("selection"), allowEmpty: Bool = false, keyboardFallback: Bool = false, onSecure: (() -> Void)? = nil) -> TextSelection? {
        guard enabled, AXIsProcessTrusted(), let app,
              app != .current else { return nil }
        let target = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(target, 0.15)
        var secure = false
        func focusedSelection() -> TextSelection? {
            guard let focused = axAttribute(target, kAXFocusedUIElementAttribute) else { return nil }
            let focus = focused as! AXUIElement
            var element: AXUIElement? = focus
            for _ in 0..<16 {
                guard let candidate = element else { break }
                AXUIElementSetMessagingTimeout(candidate, 0.15)
                if axAttribute(candidate, kAXSubroleAttribute) as? String == kAXSecureTextFieldSubrole { secure = true; onSecure?(); return nil }
                let range = selectedRange(candidate), value = string(axAttribute(candidate, kAXValueAttribute))
                let derived = range.flatMap { r -> String? in
                    guard let value, r.location >= 0, r.length >= 0, r.location + r.length <= (value as NSString).length else { return nil }
                    return (value as NSString).substring(with: NSRange(location: r.location, length: r.length))
                }
                if let text = string(axAttribute(candidate, kAXSelectedTextAttribute)) ?? derived ?? (allowEmpty && range != nil ? "" : nil),
                   allowEmpty || text.count <= 6000 {
                    let selection = TextSelection(element: candidate, focus: focus, app: app, text: text, range: range)
                    // nothing highlighted: keep it only as a cursor in a text box, where a draft can go
                    if !text.isEmpty && !allowEmpty || range != nil && (selection.editable || selection.pastable) { return selection }
                }
                guard let next = parent(candidate) else { break }
                element = next
            }
            return nil
        }
        if let selection = focusedSelection() { return selection }
        guard !secure else { return nil }
        for key in ["AXManualAccessibility"] {   // not AXEnhancedUserInterface: it makes Chrome and Electron window moves animate and lag
            if let value = axAttribute(target, key), CFEqual(value, kCFBooleanTrue) { continue }
            _ = AXUIElementSetAttributeValue(target, key as CFString, kCFBooleanTrue)
        }
        if let selection = focusedSelection() { return selection }
        guard !secure, keyboardFallback, NSWorkspace.shared.frontmostApplication == app else { return nil }
        return TextSelection(element: target, focus: target, app: app, text: "", range: nil)
    }
    var caret: Bool { text.isEmpty && range?.length == 0 }
    static func selectedRange(_ element: AXUIElement) -> CFRange? {
        guard let value = axAttribute(element, kAXSelectedTextRangeAttribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        return AXValueGetValue(value as! AXValue, .cfRange, &range) ? range : nil
    }
    var editable: Bool {
        var settable = DarwinBoolean(false)
        return range != nil && AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable) == .success && settable.boolValue
    }
    var keyboardOnly: Bool { range == nil && text.isEmpty && CFEqual(element, focus) }
    // Chrome, Electron and web editors often refuse an AX write; a text field there still takes a paste.
    var pastable: Bool {
        keyboardOnly || ["AXTextArea", "AXTextField", "AXComboBox", "AXSearchField", "AXWebArea"].contains {
            $0 == axAttribute(element, kAXRoleAttribute) as? String || $0 == axAttribute(focus, kAXRoleAttribute) as? String
        }
    }
    func apply(_ draft: String, preserveFocus: Bool = false, valid: @escaping () -> Bool, done: @escaping (Bool) -> Void) {
        guard valid() else { done(false); return }
        let before = value
        func confirm(until deadline: Date, _ finished: @escaping (Delivery) -> Void) {
            let result = delivery(draft, before)
            if case .landed = result { finished(result); return }
            guard Date() < deadline, valid() else { finished(result); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.settle) { confirm(until: deadline, finished) }
        }
        func paste(_ attempt: Int = 0) {
            guard pastable, !app.isTerminated, range != nil || keyboardOnly else { done(false); return }
            let target = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(target, 0.15)
            func focusMatches() -> Bool {
                if keyboardOnly { return true }
                guard let focused = axAttribute(target, kAXFocusedUIElementAttribute) else { return false }
                return CFEqual(focused, focus)
            }
            guard valid(), !app.isTerminated, NSWorkspace.shared.frontmostApplication == app,
                  !keyboardOnly || !IsSecureEventInputEnabled(),   // an app-wide keyboard target cannot see a password box: secure input on anywhere = no paste
                  focusMatches(),
                  keyboardOnly || selectionMatches(),
                  pastable,
                  focusMatches(),
                  NSWorkspace.shared.frontmostApplication == app else { done(false); return }
            guard let down = CGEvent(keyboardEventSource: nil, virtualKey: draft.isEmpty ? 51 : 9, keyDown: true),
                  let up = CGEvent(keyboardEventSource: nil, virtualKey: draft.isEmpty ? 51 : 9, keyDown: false) else { done(false); return }
            // One clipboard borrower at a time across Aurel processes; while a hands helper pastes, check again shortly.
            let clipboard = draft.isEmpty ? nil : try? Hands.lease("clipboard.lock", wait: false)
            if !draft.isEmpty && clipboard == nil {
                if attempt < 40 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { paste(attempt + 1) } } else { done(false) }
                return
            }
            let restore = draft.isEmpty ? nil : borrowPasteboard(draft)
            let release = { if let clipboard { Hands.unlock(clipboard) } }
            guard draft.isEmpty || restore != nil else { release(); done(false); return }
            let finish = { (ok: Bool) in restore?(); release(); done(ok) }
            // The box is a non-activating panel: while it holds the keyboard, a system ⌘V lands in its own field, not the target.
            for e in [down, up] { e.flags = draft.isEmpty ? [] : .maskCommand; if NSApp.keyWindow == nil { e.post(tap: .cghidEventTap) } else { e.postToPid(app.processIdentifier) } }
            // Posted after every check passed: it went in. Web and Electron fields often read back empty or stale, so the
            // read-back only decides when the clipboard can come back, never whether the paste failed.
            confirm(until: Date().addingTimeInterval(0.45)) { _ in finish(true) }
        }
        let fallback = {
            if preserveFocus { paste() }
            else {   // Aurel may be front (the user clicked its box): wait up to 1 s for the target app to come back
                app.activate()
                func ready(_ tries: Int) { NSWorkspace.shared.frontmostApplication == app || tries >= 20 ? paste() : DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { ready(tries + 1) } }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { ready(0) }
            }
        }
        // A successful AX call can update slowly. Retry only after proving it changed nothing; an unverifiable retry can insert twice.
        guard editable, before != nil, replace(draft) else { fallback(); return }
        confirm(until: Date().addingTimeInterval(0.45)) { result in
            switch result {
            case .landed, .unknown: done(true)   // the write succeeded and the field changed; an odd read-back is no failure
            case .unchanged: valid() ? fallback() : done(false)
            }
        }
    }
    var value: String? { Self.string(axAttribute(element, kAXValueAttribute)) }
    func selectionMatches() -> Bool {
        guard let range, let current = Self.selectedRange(element),
              current.location == range.location, current.length == range.length else { return false }
        if let selected = Self.string(axAttribute(element, kAXSelectedTextAttribute)) { return selected == text }
        guard let value, range.location >= 0, range.length >= 0, range.location + range.length <= (value as NSString).length else { return true }
        return (value as NSString).substring(with: NSRange(location: range.location, length: range.length)) == text
    }
    func landed(_ draft: String, _ before: String?) -> Bool {
        guard let before, let now = value, let range else { return false }
        let source = before as NSString
        guard range.location >= 0, range.length >= 0, range.location + range.length <= source.length else { return false }
        return now == source.replacingCharacters(in:NSRange(location:range.location,length:range.length),with:draft)
    }
    func delivery(_ draft: String, _ before: String?) -> Delivery {
        if landed(draft, before) { return .landed }
        guard let range, let current = Self.selectedRange(element) else { return .unknown }
        let expected = range.location + (draft as NSString).length
        if current.location == expected && current.length == 0 { return .landed }
        return value == before && current.location == range.location && current.length == range.length ? .unchanged : .unknown
    }
    func replace(_ draft: String) -> Bool {
        guard !app.isTerminated, selectionMatches() else { return false }
        // Set only the saved selection; never paste into whichever app happens to be focused.
        return AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, draft as CFString) == .success
    }
}

// Sees the mouse over the box without taking clicks or focus (clicks go to the monitors in App).
final class Tracker: NSView {
    var onMove: ((NSPoint) -> Void)?, onExit: (() -> Void)?
    override func hitTest(_ p: NSPoint) -> NSView? { nil }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
                                       owner: self))
    }
    override func mouseMoved(with e: NSEvent) { onMove?(convert(e.locationInWindow, from: nil)) }
    override func mouseEntered(with e: NSEvent) { onMove?(convert(e.locationInWindow, from: nil)) }
    override func mouseExited(with e: NSEvent) { onExit?() }
}

// Screen drawings use Quartz points throughout; each flipped view translates its own display origin.
final class DrawingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
struct DrawingShape: Codable {
    let kind: String
    var rect: [Double]?, at: [Double]?, points: [[Double]]?, text: String?, color: String?, size: String?, fill: Bool?
}
struct DrawingStep: Codable {
    let id: String?, say: String?, target: String?, shapes: [DrawingShape]
    let wait: Bool?, hit: [Double]?, timeout: Double?
}
struct DrawingRequest: Decodable {
    let steps: [DrawingStep], teaching: Bool, target: DrawingWindow, state: String
    let receipt: String?
}
struct DrawingWindow: Decodable {
    let pid: Int32, windowID: String, windowFrame: [Double]
    var bounds: CGRect { CGRect(x:windowFrame[0], y:windowFrame[1], width:windowFrame[2], height:windowFrame[3]) }
    var valid: Bool { pid > 0 && UInt32(windowID).map { $0 > 0 } == true && ScreenDrawing.validRect(windowFrame) }
}
final class DrawingView: NSView {
    override var isFlipped: Bool { true }
    var origin = CGPoint.zero
    var inputStart: ((CGPoint) -> Void)?, inputMove: ((CGPoint) -> Void)?, inputEnd: ((CGPoint) -> Void)?, inputHover: ((CGPoint?) -> Void)?
    var pick: ((CGPoint) -> Void)?
    var hits: [(area: CGPath, step: Int, shape: Int)] = []   // local points: what a click on each mark selects
    func reset() { layer?.sublayers?.forEach { $0.removeFromSuperlayer() }; hits = [] }
    func mark(at p: CGPoint) -> (bounds: CGRect, step: Int, shape: Int)? {
        let l = CGPoint(x:p.x-origin.x, y:p.y-origin.y)
        return hits.last { $0.area.contains(l) }.map { ($0.area.boundingBoxOfPath.offsetBy(dx:origin.x,dy:origin.y), $0.step, $0.shape) }
    }
    var hitBounds: [CGRect] { hits.map { $0.area.boundingBoxOfPath.offsetBy(dx:origin.x,dy:origin.y) } }
    func highlight(_ selected: (step: Int, shape: Int)?) {   // the selected mark: an accent ring, like a selection anywhere on the Mac
        layer?.sublayers?.filter { $0.name == "pick" }.forEach { $0.removeFromSuperlayer() }
        guard let selected else { return }
        for h in hits where h.step == selected.step && h.shape == selected.shape {
            let ring = CAShapeLayer(); ring.name = "pick"
            ring.path = CGPath(roundedRect:h.area.boundingBoxOfPath.insetBy(dx:-5,dy:-5),cornerWidth:8,cornerHeight:8,transform:nil)
            ring.fillColor = NSColor.controlAccentColor.withAlphaComponent(0.16).cgColor; ring.strokeColor = NSColor.controlAccentColor.cgColor; ring.lineWidth = 2
            layer?.addSublayer(ring)
        }
    }
    // A whiteboard of large text lines on one dark panel; earlier steps' lines stay, a little quieter.
    func renderBoard(_ frame: CGRect, _ lines: [ScreenDrawing.BoardLine], current: Int, animate: Bool) {
        wantsLayer = true
        guard bounds.offsetBy(dx:origin.x,dy:origin.y).intersects(frame) else { return }
        let local = frame.offsetBy(dx:-origin.x,dy:-origin.y), bg = CAShapeLayer()
        bg.path = CGPath(roundedRect:local,cornerWidth:14,cornerHeight:14,transform:nil); bg.fillColor = NSColor(calibratedWhite:0.08,alpha:0.94).cgColor
        bg.strokeColor = NSColor.white.withAlphaComponent(0.22).cgColor; bg.lineWidth = 0.5
        bg.shadowColor = NSColor.black.cgColor; bg.shadowOpacity = 0.35; bg.shadowRadius = 8; bg.shadowOffset = .zero; bg.shadowPath = bg.path
        layer?.addSublayer(bg)
        for line in lines {
            let text = CATextLayer(); text.string = line.text; text.isWrapped = true; text.contentsScale = window?.backingScaleFactor ?? 2
            text.frame = line.rect.offsetBy(dx:-origin.x,dy:-origin.y)
            if line.step < current { text.opacity = 0.7 }
            else if animate {
                let fade = CABasicAnimation(keyPath:"opacity"); fade.fromValue = 0; fade.toValue = 1; fade.duration = 0.3; text.add(fade,forKey:"write")
            }
            layer?.addSublayer(text); hits.append((CGPath(rect:text.frame.insetBy(dx:-4,dy:-2),transform:nil),line.step,line.shape))
        }
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    func inputPoint(_ event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from:nil)
        return CGPoint(x:origin.x + p.x, y:origin.y + p.y)
    }
    var pointing: Bool { inputStart != nil && window?.ignoresMouseEvents == false }
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); trackingAreas.forEach(removeTrackingArea)
        if inputStart != nil { addTrackingArea(NSTrackingArea(rect:.zero,options:[.activeAlways,.mouseMoved,.mouseEnteredAndExited,.cursorUpdate,.inVisibleRect],owner:self)) }
    }
    override func cursorUpdate(with event: NSEvent) { if pointing { NSCursor.crosshair.set() } else { super.cursorUpdate(with:event) } }   // Aurel never activates, so set it on every move too
    override func mouseEntered(with event: NSEvent) { if pointing { NSCursor.crosshair.set() } }
    override func mouseMoved(with event: NSEvent) { inputHover?(inputPoint(event)); if pointing { NSCursor.crosshair.set() } }
    override func mouseExited(with event: NSEvent) { inputHover?(nil) }
    override func mouseDown(with event: NSEvent) { if pointing { NSCursor.crosshair.set() }; inputStart?(inputPoint(event)); pick?(inputPoint(event)) }
    override func mouseDragged(with event: NSEvent) { inputMove?(inputPoint(event)) }
    override func mouseUp(with event: NSEvent) { inputEnd?(inputPoint(event)) }
    // Returns what it drew, in global points. avoid: more of what the marks point at (a click target); dim: an earlier whiteboard step.
    @discardableResult func render(_ shapes: [DrawingShape], animate: Bool, previous: CGPoint?, append: Bool = false, avoid: [CGRect] = [], dim: Bool = false, step: Int = 0) -> CGRect {
        wantsLayer = true
        if !append { reset() }
        let colors = ScreenDrawing.colors
        func local(_ p: CGPoint) -> CGPoint { CGPoint(x:p.x-origin.x, y:p.y-origin.y) }
        let targets = shapes.compactMap { $0.rect.map(ScreenDrawing.rect) } + avoid
        let keepOff = targets.map { $0.insetBy(dx:-ScreenDrawing.gap,dy:-ScreenDrawing.gap) } + shapes.compactMap { s in s.rect.map { ScreenDrawing.ring(ScreenDrawing.rect($0),circle:s.kind == "circle") } }
        let screen = bounds.offsetBy(dx:origin.x,dy:origin.y)
        var drawn = CGRect.null
        func add(_ l: CALayer, _ frame: CGRect) {
            let global = frame.offsetBy(dx:origin.x,dy:origin.y)
            guard screen.intersects(global) else { return }
            if dim { l.opacity = 0.5 }; layer?.addSublayer(l); drawn = drawn.union(global.intersection(screen))
        }
        func hit(_ area: CGPath, _ shape: Int) {   // strokes take clicks near the line only, so the target inside a ring stays clickable
            if screen.intersects(area.boundingBoxOfPath.offsetBy(dx:origin.x,dy:origin.y)) { hits.append((area,step,shape)) }
        }
        for (i, shape) in shapes.enumerated() where shape.kind != "text" {
            let color = colors[shape.color ?? "red"] ?? .systemRed
            let path = CGMutablePath()
            if let r = shape.rect {
                let bounds = ScreenDrawing.rect(r)
                let frame = (shape.fill == true ? bounds : ScreenDrawing.ring(bounds,circle:shape.kind == "circle")).offsetBy(dx:-origin.x,dy:-origin.y)
                if shape.kind == "circle" { path.addEllipse(in:frame) } else { path.addRoundedRect(in:frame,cornerWidth:6,cornerHeight:6) }
            } else if let points = shape.points?.map({ CGPoint(x:$0[0],y:$0[1]) }), let first = points.first {
                var points = points
                if shape.kind == "arrow" { points[points.count-1] = ScreenDrawing.arrowTip(from:first,to:points[points.count-1],avoiding:targets) }
                path.addLines(between:points.map(local))
                if shape.kind == "arrow", let last = points.last {
                    let p = local(last), angle = atan2(last.y-first.y,last.x-first.x)
                    for delta in [-0.5, 0.5] { path.move(to:p); path.addLine(to:CGPoint(x:p.x-13*cos(angle+delta),y:p.y-13*sin(angle+delta))) }
                }
            } else if let at = shape.at {
                let point = CGPoint(x:at[0],y:at[1])
                if shape.kind == "label" {
                    guard screen.contains(point) else { continue }
                    let light = ["green","yellow","white"].contains(shape.color ?? "red")
                    let font = NSFont.systemFont(ofSize:["s":12,"m":15,"l":19][shape.size ?? "m"] ?? 15,weight:.semibold)
                    let attributes: [NSAttributedString.Key:Any] = [.font:font,.foregroundColor:light ? NSColor.black : NSColor.white]
                    let text = NSAttributedString(string:shape.text ?? "",attributes:attributes)
                    let measured = text.boundingRect(with:CGSize(width:bounds.width-30,height:.greatestFiniteMagnitude),options:[.usesLineFragmentOrigin,.usesFontLeading]).size
                    let textSize = CGSize(width:ceil(measured.width)+2,height:ceil(measured.height)), size = CGSize(width:textSize.width+16,height:textSize.height+10)
                    // a label set near a mark but off it sits right beside that mark; with an arrow or line it stays where the model put it
                    let edges = shapes.contains { ["arrow","line","path"].contains($0.kind) } ? [] : targets.map { CGPoint(x:min(max(point.x,$0.minX),$0.maxX),y:min(max(point.y,$0.minY),$0.maxY)) }
                    let near = edges.min { hypot($0.x-point.x,$0.y-point.y) < hypot($1.x-point.x,$1.y-point.y) }
                    let anchor = near.map { hypot($0.x-point.x,$0.y-point.y) < 160 ? $0 : point } ?? point
                    let box = ScreenDrawing.labelBox(size,at:anchor,keepOff:keepOff,in:screen.insetBy(dx:6,dy:6)).offsetBy(dx:-origin.x,dy:-origin.y)
                    let bg = CAShapeLayer(); bg.path = CGPath(roundedRect:box,cornerWidth:7,cornerHeight:7,transform:nil); bg.fillColor = (light ? color : color.blended(withFraction:0.2,of:.black) ?? color).cgColor
                    add(bg,box); hit(CGPath(rect:box,transform:nil),i)
                    let label = CATextLayer(); label.string = text; label.contentsScale = window?.backingScaleFactor ?? 2
                    label.frame = CGRect(x:box.minX+8,y:box.midY-textSize.height/2,width:box.width-16,height:textSize.height); label.isWrapped = true
                    add(label,box); continue
                }
                let p = local(ScreenDrawing.beside(point,targets))
                let dot = CAShapeLayer(); dot.path = CGPath(ellipseIn:CGRect(x:-5,y:-5,width:10,height:10),transform:nil)
                dot.fillColor = color.cgColor; dot.strokeColor = NSColor.white.cgColor; dot.lineWidth = 2; dot.position = p
                add(dot,CGRect(x:p.x-6,y:p.y-6,width:12,height:12)); hit(CGPath(ellipseIn:CGRect(x:p.x-10,y:p.y-10,width:20,height:20),transform:nil),i)
                if animate, let previous {
                    let move = CABasicAnimation(keyPath:"position"); move.fromValue = NSValue(point:CGPoint(x:previous.x-origin.x,y:previous.y-origin.y)); move.toValue = NSValue(point:p); move.duration = 0.25; dot.add(move,forKey:"move")
                }
                continue
            }
            let stroke = CAShapeLayer(); stroke.path = path; stroke.fillColor = shape.fill == true ? color.withAlphaComponent(0.18).cgColor : NSColor.clear.cgColor
            stroke.strokeColor = color.cgColor; stroke.lineWidth = 3; stroke.lineCap = .round; stroke.lineJoin = .round
            stroke.shadowColor = NSColor.black.cgColor; stroke.shadowOpacity = 0.45; stroke.shadowRadius = 2
            add(stroke,path.boundingBoxOfPath.insetBy(dx:-3,dy:-3))
            hit(shape.fill == true ? path : path.copy(strokingWithWidth:12,lineCap:.round,lineJoin:.round,miterLimit:2),i)
            if animate { let draw = CABasicAnimation(keyPath:"strokeEnd"); draw.fromValue = 0; draw.toValue = 1; draw.duration = 0.28; stroke.add(draw,forKey:"draw") }
        }
        return drawn
    }
}
// One step's text beside its marks: a dark card whose notch points at them, with Back / Next.
final class DrawingCalloutView: NSView {
    var onBack: (() -> Void)?, onNext: (() -> Void)?, onClose: (() -> Void)?
    static let font = NSFont.systemFont(ofSize:14,weight:.medium), notch: CGFloat = 7, margin: CGFloat = 12
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    static func body(_ text: String, width: CGFloat) -> NSTextView {
        let view = NSTextView(frame:CGRect(x:0,y:0,width:width,height:0))
        view.string = text; view.font = font; view.textColor = .white; view.drawsBackground = false
        view.isEditable = false; view.isSelectable = true; view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.containerSize = NSSize(width:width,height:.greatestFiniteMagnitude)
        view.layoutManager!.ensureLayout(for:view.textContainer!)
        view.setFrameSize(NSSize(width:width,height:ceil(view.layoutManager!.usedRect(for:view.textContainer!).height)))
        return view
    }
    static func size(_ text: String, total: Int) -> CGSize {   // the card alone, without notch or shadow margin
        let measured = (text as NSString).boundingRect(with:CGSize(width:300,height:CGFloat.greatestFiniteMagnitude),
            options:[.usesLineFragmentOrigin,.usesFontLeading],attributes:[.font:font]).size
        let width = max(total > 1 ? 232 : 180,ceil(measured.width)+34)
        let height = text.isEmpty ? 0 : min(240,body(text,width:width-32).frame.height) + 12
        return CGSize(width:width, height:14 + (total > 1 ? 24 : 0) + height + 26 + 14)
    }
    static func bubble(_ card: CGRect, side: NSRectEdge?, tip: CGFloat) -> CGPath {   // flipped coordinates; tip runs along the facing edge
        let p = CGMutablePath(), r: CGFloat = 12, n = notch
        let along = side == .minX || side == .maxX ? (card.minY, card.maxY) : (card.minX, card.maxX)
        let t = min(max(tip,along.0+r+n),along.1-r-n)
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x:x,y:y) }
        func tooth(_ points: [CGPoint]) { points.forEach { p.addLine(to:$0) } }   // addLines(between:) would start a new subpath
        p.move(to:pt(card.minX+r,card.minY))
        if side == .minY { tooth([pt(t-n,card.minY),pt(t,card.minY-n),pt(t+n,card.minY)]) }
        p.addArc(tangent1End:pt(card.maxX,card.minY),tangent2End:pt(card.maxX,card.maxY),radius:r)
        if side == .maxX { tooth([pt(card.maxX,t-n),pt(card.maxX+n,t),pt(card.maxX,t+n)]) }
        p.addArc(tangent1End:pt(card.maxX,card.maxY),tangent2End:pt(card.minX,card.maxY),radius:r)
        if side == .maxY { tooth([pt(t+n,card.maxY),pt(t,card.maxY+n),pt(t-n,card.maxY)]) }
        p.addArc(tangent1End:pt(card.minX,card.maxY),tangent2End:pt(card.minX,card.minY),radius:r)
        if side == .minX { tooth([pt(card.minX,t+n),pt(card.minX-n,t),pt(card.minX,t-n)]) }
        p.addArc(tangent1End:pt(card.minX,card.minY),tangent2End:pt(card.maxX,card.minY),radius:r)
        p.closeSubpath(); return p
    }
    init(frame: CGRect, card: CGRect, side: NSRectEdge?, tip: CGFloat, text: String, step: Int, total: Int) {
        super.init(frame: frame)
        wantsLayer = true
        let shape = CAShapeLayer(), path = Self.bubble(card,side:side,tip:tip)
        shape.path = path; shape.fillColor = NSColor(calibratedWhite:0.08,alpha:0.94).cgColor
        shape.strokeColor = NSColor.white.withAlphaComponent(0.22).cgColor; shape.lineWidth = 0.5
        shape.shadowColor = NSColor.black.cgColor; shape.shadowOpacity = 0.35; shape.shadowRadius = 8; shape.shadowOffset = .zero; shape.shadowPath = path
        layer?.addSublayer(shape)
        setAccessibilityElement(true); setAccessibilityRole(.group); setAccessibilityLabel(total > 1 ? "Guide, step \(step) of \(total)" : "Guide")
        var y = card.minY + 14
        if total > 1 {
            let progress = NSTextField(labelWithString:"Step \(step) of \(total)")
            progress.font = .systemFont(ofSize:11,weight:.semibold); progress.textColor = NSColor.white.withAlphaComponent(0.68)
            progress.frame = CGRect(x:card.minX+16,y:y,width:card.width-64,height:16); addSubview(progress)
            let close = NSButton(image:NSImage(systemSymbolName:"xmark",accessibilityDescription:"Close guide") ?? NSImage(),target:self,action:#selector(closeGuide))
            close.isBordered = false; close.contentTintColor = NSColor.white.withAlphaComponent(0.6); close.toolTip = "Close guide"
            close.frame = CGRect(x:card.maxX-34,y:y-1,width:18,height:18); addSubview(close)
            y += 24
        }
        if !text.isEmpty {
            let height = card.maxY - 14 - 26 - 12 - y
            let scroll = NSScrollView(frame:CGRect(x:card.minX+16,y:y,width:card.width-32,height:height))
            scroll.drawsBackground = false; scroll.borderType = .noBorder; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
            scroll.scrollerStyle = .overlay
            scroll.documentView = Self.body(text,width:scroll.contentSize.width); addSubview(scroll)
            y += height + 12
        }
        let last = step >= total
        let next = NSButton(title:last ? "Done" : "Next",target:self,action:#selector(nextStep))
        next.bezelStyle = .rounded; next.bezelColor = .systemBlue; next.frame = CGRect(x:card.maxX-16-68,y:y,width:68,height:26)
        next.setAccessibilityLabel(last ? "Done" : "Next step"); addSubview(next)
        if total > 1 {
            let back = NSButton(title:"Back",target:self,action:#selector(backStep))
            back.bezelStyle = .rounded; back.isEnabled = step > 1; back.frame = CGRect(x:next.frame.minX-8-68,y:y,width:68,height:26)
            back.setAccessibilityLabel("Previous step"); addSubview(back)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc func closeGuide() { onClose?() }
    @objc func nextStep() { onNext?() }
    @objc func backStep() { onBack?() }
}
final class ScreenDrawing {
    var panels: [DrawingPanel] = [], request: DrawingRequest?, index = 0
    var inputPanels: [DrawingPanel] = []   // Point at your screen draws under the guide, so a guide stays up while the user marks
    var calloutPanel: DrawingPanel?
    struct BoardLine { let text: NSAttributedString, rect: CGRect, step: Int, shape: Int }   // global points
    var board: (frame: CGRect, pad: CGFloat, lines: [BoardLine])?
    var selected: (step: Int, shape: Int)?, overMark = false
    var picked: ((CGRect, String) -> Void)?   // a click on a mark: its screen area and what it is
    var changed: (() -> Void)?   // marks appeared, moved or went: the box gets out of their way
    var occupied: [CGRect] = []   // global points the drawing covers: marks, their targets, the step card
    var manual = false   // Back or Next was pressed: auto steps stop for this guide
    var autoSteps: () -> Bool = { true }
    var timer: Timer?, monitors: [Any] = [], voice: Process?, element: AXUIElement?, originalValue: CFTypeRef?
    var target: DrawingWindow?, hit: CGRect?, deadline = Date.distantPast, ready = Date.distantPast, advanceAt = Date.distantPast
    var previousPointer: CGPoint?
    var focus: CGRect?   // the shown step's marks (global points): the box's leader line aims here
    var inputPath: [CGPoint] = [], inputMode = false
    var inputDone: (([CGPoint]) -> Void)?, inputCleared: (() -> Void)?, inputAway: (() -> Void)?
    var resolve: ((String,String) throws -> (CGRect,AXUIElement?,DrawingWindow))?
    var readValue: (AXUIElement) -> CFTypeRef? = { e in
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(e,kAXValueAttribute as CFString,&value) == .success ? value : nil
    }
    var cleanup: (() -> Void)?
    var status: ((String) -> Void)?
    var speechEnabled: () -> Bool = { false }
    var sayArguments: (String) -> [String] = { ["--", $0] }
    var active: Bool { request != nil }
    var hasInput: Bool { inputMode || !inputPath.isEmpty }
    var summary: [String:Any]? {   // what is on screen, for the next ask to build on
        guard let r = request, let data = try? JSONEncoder().encode(r.steps), let steps = try? JSONSerialization.jsonObject(with:data) else { return nil }
        return ["steps":steps, "shown":index+1]
    }
    // Keep board text readable without oversized type on large displays.
    static func textSize(_ size: String?, display: CGRect) -> CGFloat { min(32,max(22,min(28,display.height/40)) * (["s":0.8,"l":1.2][size ?? ""] ?? 1)) }
    // Every text line of the guide on one panel, laid out once so it grows in place: at the first line's `at`, else beside the other marks.
    static let colors: [String:NSColor] = ["red":.systemRed, "blue":.systemBlue, "green":.systemGreen, "yellow":.systemYellow, "white":.white]
    static func board(_ steps: [DrawingStep], near: CGRect) -> (frame: CGRect, pad: CGFloat, lines: [BoardLine])? {
        let texts = steps.enumerated().flatMap { s in s.element.shapes.enumerated().filter { $0.element.kind == "text" }.map { (s.offset,$0.offset,$0.element) } }
        guard let first = texts.first?.2 else { return nil }
        let anchor = first.at.map { CGPoint(x:$0[0],y:$0[1]) } ?? CGPoint(x:near.midX,y:near.midY), top = NSScreen.screens.first?.frame.maxY ?? 0
        func display(_ s: NSScreen) -> CGRect { CGDisplayBounds(s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? CGMainDisplayID()) }
        guard let screen = NSScreen.screens.first(where: { display($0).contains(anchor) }) ?? NSScreen.main ?? NSScreen.screens.first else { return nil }
        let v = screen.visibleFrame, area = CGRect(x:v.minX,y:top-v.maxY,width:v.width,height:v.height).insetBy(dx:12,dy:12)
        let base = textSize(nil,display:display(screen)), pad = round(base*0.7), gap = round(base*0.3), wrap = max(200,min(area.width*0.5,820))
        var y = pad, width: CGFloat = 0, sized: [(NSAttributedString,CGSize,Int,Int)] = []
        for (step,shape,s) in texts {
            let font = NSFont.systemFont(ofSize:textSize(s.size,display:display(screen)),weight:.medium)
            let text = NSAttributedString(string:s.text ?? "",attributes:[.font:font,.foregroundColor:s.color.flatMap { colors[$0] } ?? .white])
            let size = text.boundingRect(with:CGSize(width:wrap,height:.greatestFiniteMagnitude),options:[.usesLineFragmentOrigin,.usesFontLeading]).size
            sized.append((text,CGSize(width:ceil(size.width)+2,height:ceil(size.height)),step,shape)); width = max(width,ceil(size.width)+2)
        }
        let height = sized.reduce(pad) { $0 + $1.1.height + gap } - gap + pad
        let size = CGSize(width:min(area.width,width+2*pad), height:min(area.height,height))
        let origin = first.at.map { CGPoint(x:min(max($0[0],area.minX),area.maxX-size.width), y:min(max($0[1],area.minY),area.maxY-size.height)) }
            ?? calloutFrame(size,marks:near,avoid:[],in:area).card.origin
        let lines = sized.map { line in defer { y += line.1.height + gap }; return BoardLine(text:line.0,rect:CGRect(x:origin.x+pad,y:origin.y+y,width:line.1.width,height:line.1.height),step:line.2,shape:line.3) }
        return (CGRect(origin:origin,size:size), pad, lines)
    }
    // Follow the active step down a long board; Back pages earlier lines into view again.
    static func boardPage(_ board: (frame: CGRect, pad: CGFloat, lines: [BoardLine]), through step: Int) -> (frame: CGRect, lines: [BoardLine])? {
        let shown = board.lines.filter { $0.step <= step }
        guard let last = shown.last else { return nil }
        let offset = max(0, last.rect.maxY + board.pad - board.frame.maxY)
        let viewport = board.frame.insetBy(dx: 0, dy: board.pad)
        let lines = shown.compactMap { line -> BoardLine? in
            let rect = line.rect.offsetBy(dx: 0, dy: -offset)
            return rect.intersects(viewport) ? BoardLine(text: line.text, rect: rect, step: line.step, shape: line.shape) : nil
        }
        guard let visible = lines.last else { return nil }
        let frame = offset > 0 ? board.frame : CGRect(x: board.frame.minX, y: board.frame.minY, width: board.frame.width,
                                                      height: visible.rect.maxY + board.pad - board.frame.minY)
        return (frame, lines)
    }
    static func numbers(_ v: [Double], _ n: Int) -> Bool { v.count == n && v.allSatisfy { $0.isFinite && abs($0) <= 100000 } }
    static func validRect(_ v: [Double]) -> Bool { numbers(v,4) && v[2] > 0 && v[3] > 0 }
    static func rect(_ v: [Double]) -> CGRect { CGRect(x:v[0],y:v[1],width:v[2],height:v[3]) }
    // Marks sit around or beside what they mark, never on it: `gap` is the clear space they keep.
    static let gap: CGFloat = 6
    static func ring(_ r: CGRect, circle: Bool) -> CGRect {   // the 3-point stroke lies outside the target; an ellipse passes outside its corners
        let out = r.insetBy(dx:-(gap+1.5),dy:-(gap+1.5))
        return circle ? out.insetBy(dx:-out.width*(sqrt(2)-1)/2,dy:-out.height*(sqrt(2)-1)/2) : out
    }
    static func arrowTip(from a: CGPoint, to b: CGPoint, avoiding targets: [CGRect]) -> CGPoint {   // the head stops at the target's edge
        guard let box = targets.map({ $0.insetBy(dx:-gap-2,dy:-gap-2) }).first(where: { $0.contains(b) && !$0.contains(a) }) else { return b }
        var lo: CGFloat = 0, hi: CGFloat = 1
        func at(_ s: CGFloat) -> CGPoint { CGPoint(x:a.x+(b.x-a.x)*s,y:a.y+(b.y-a.y)*s) }
        for _ in 0..<24 { let m = (lo+hi)/2; if box.contains(at(m)) { hi = m } else { lo = m } }
        return at(lo)
    }
    static func leader(from box: CGRect, to target: CGRect) -> (CGPoint, CGPoint)? {   // the box edge nearest the target, to just outside it; nil when close
        let aim = CGPoint(x:target.midX,y:target.midY)
        let a = CGPoint(x:min(max(aim.x,box.minX),box.maxX),y:min(max(aim.y,box.minY),box.maxY))
        let b = arrowTip(from:a,to:aim,avoiding:[target])
        return hypot(b.x-a.x,b.y-a.y) > 60 ? (a,b) : nil
    }
    static func beside(_ p: CGPoint, _ targets: [CGRect]) -> CGPoint {   // a pointer on a target rests at its lower-right corner
        guard let t = targets.first(where: { $0.contains(p) }) else { return p }
        return CGPoint(x:t.maxX+gap,y:t.maxY+gap)
    }
    static func labelBox(_ size: CGSize, at p: CGPoint, keepOff: [CGRect], in area: CGRect) -> CGRect {
        var spots = [CGPoint(x:p.x+12,y:p.y-size.height-4), CGPoint(x:p.x+12,y:p.y+8), CGPoint(x:p.x-12-size.width,y:p.y-size.height-4), CGPoint(x:p.x-12-size.width,y:p.y+8)]
        for t in keepOff where t.contains(p) {   // anchored on a target: beside it instead
            spots += [CGPoint(x:t.maxX+4,y:t.midY-size.height/2), CGPoint(x:t.minX-4-size.width,y:t.midY-size.height/2),
                      CGPoint(x:t.midX-size.width/2,y:t.minY-4-size.height), CGPoint(x:t.midX-size.width/2,y:t.maxY+4)]
        }
        func clear(_ box: CGRect) -> Bool {   // outside every mark, or well inside a large one (an area model's "x²"), never across an edge
            area.contains(box) && !keepOff.contains { $0.intersects(box) && !$0.insetBy(dx:2*gap,dy:2*gap).contains(box) }
        }
        if let spot = spots.first(where: { clear(CGRect(origin:$0,size:size)) }) {
            return CGRect(origin:spot,size:size)
        }
        return CGRect(x:max(area.minX,min(area.maxX-size.width,spots[0].x)),y:max(area.minY,min(area.maxY-size.height,spots[0].y)),width:size.width,height:size.height)
    }
    // The card beside the step's marks (right, left, below, above), clear of them and, if it can, of earlier steps; else the far corner.
    static func calloutFrame(_ size: CGSize, marks: CGRect, avoid: [CGRect], in area: CGRect) -> (card: CGRect, side: NSRectEdge?) {
        let g = DrawingCalloutView.notch + 8
        func x(_ v: CGFloat) -> CGFloat { min(max(v,area.minX),area.maxX-size.width) }
        func y(_ v: CGFloat) -> CGFloat { min(max(v,area.minY),area.maxY-size.height) }
        var options: [(CGPoint,NSRectEdge)] = []   // each side centred on the marks, then lined up with their start or end
        for v in [marks.midY-size.height/2, marks.minY, marks.maxY-size.height].map(y) { options += [(CGPoint(x:marks.maxX+g,y:v),.minX), (CGPoint(x:marks.minX-g-size.width,y:v),.maxX)] }
        for v in [marks.midX-size.width/2, marks.minX, marks.maxX-size.width].map(x) { options += [(CGPoint(x:v,y:marks.maxY+g),.minY), (CGPoint(x:v,y:marks.minY-g-size.height),.maxY)] }
        for keep in [avoid + [marks], [marks]] {
            for (origin,side) in options {
                let card = CGRect(origin:origin,size:size)
                if area.contains(card) && !keep.contains(where: { $0.intersects(card) }) { return (card,side) }
            }
        }
        return (CGRect(x:marks.midX < area.midX ? area.maxX-size.width : area.minX, y:marks.midY < area.midY ? area.maxY-size.height : area.minY, width:size.width, height:size.height), nil)
    }
    // The box's spot (Cocoa points): where it is if clear of every mark, else the nearest clear spot fully on any display, else nil (it stays).
    static func clearSpot(_ box: CGRect, avoiding marks: [CGRect], in screens: [CGRect]) -> CGPoint? {
        let keep = marks.map { $0.insetBy(dx:-32,dy:-32) }
        func clear(_ r: CGRect) -> Bool { !keep.contains { $0.intersects(r) } }
        if clear(box) { return box.origin }
        // no fully clear spot: the one covering the least drawing, nearest first
        func covered(_ r: CGRect) -> CGFloat { keep.reduce(0) { let i = $1.intersection(r); return $0 + (i.isNull ? 0 : i.width*i.height) } }
        var best: CGPoint?, distance = CGFloat.infinity, least = covered(box)
        for screen in screens {
            let a = screen.insetBy(dx:8,dy:8)
            guard a.width >= box.width, a.height >= box.height else { continue }
            let xs = [box.minX, a.minX, a.maxX-box.width] + keep.flatMap { [$0.maxX, $0.minX-box.width] }
            let ys = [box.minY, a.minY, a.maxY-box.height] + keep.flatMap { [$0.maxY, $0.minY-box.height] }
            for x in xs where x >= a.minX && x <= a.maxX-box.width {
                for y in ys where y >= a.minY && y <= a.maxY-box.height {
                    let d = hypot(x-box.minX, y-box.minY), c = covered(CGRect(x:x,y:y,width:box.width,height:box.height))
                    if c < least || c == least && best != nil && d < distance { best = CGPoint(x:x,y:y); distance = d; least = c }
                }
            }
        }
        return best
    }
    static func valid(_ r: DrawingRequest) -> Bool {
        guard r.target.valid, (1...12).contains(r.steps.count) else { return false }
        let teaching = r.steps.allSatisfy { $0.wait != true && $0.target == nil && $0.hit == nil }
        guard r.teaching == teaching, !teaching || r.steps.allSatisfy({ $0.say?.isEmpty == false }) else { return false }
        return r.steps.allSatisfy { step in
            guard (1...40).contains(step.shapes.count), (5...120).contains(step.timeout ?? 60), (step.say?.count ?? 0) <= 1000,
                  step.hit.map(validRect) ?? true, step.wait != true || step.target != nil || step.hit != nil else { return false }
            return step.shapes.allSatisfy { s in
                guard ["red","blue","green","yellow","white"].contains(s.color ?? "red"),
                      s.rect == nil || ["rect","circle"].contains(s.kind), s.at == nil || ["pointer","label","text"].contains(s.kind),
                      s.points == nil || ["arrow","line","path"].contains(s.kind), s.text == nil || ["label","text"].contains(s.kind),
                      s.size == nil || ["label","text"].contains(s.kind) && ["s","m","l"].contains(s.size!),
                      s.fill == nil || ["rect","circle"].contains(s.kind) else { return false }
                switch s.kind {
                case "rect","circle": return s.rect.map(validRect) ?? (step.target != nil)
                case "pointer","label": return (s.at.map { numbers($0,2) } ?? (step.target != nil)) && (s.kind != "label" || (1...120).contains(s.text?.count ?? 0))
                case "text": return (s.at.map { numbers($0,2) } ?? true) && (1...300).contains(s.text?.count ?? 0)
                case "arrow","line","path": return s.points.map { (2...(s.kind == "path" ? 256 : 2)).contains($0.count) && $0.allSatisfy { numbers($0,2) } } ?? false
                default: return false
                }
            }
        }
    }
    static func onDisplays(_ r: DrawingRequest) -> Bool {
        let displays = NSScreen.screens.map { screen in CGDisplayBounds(screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? CGMainDisplayID()) }
        func point(_ p: [Double]) -> Bool { displays.contains { p[0] >= $0.minX && p[0] <= $0.maxX && p[1] >= $0.minY && p[1] <= $0.maxY } }
        func rect(_ v: [Double]) -> Bool { point([v[0],v[1]]) && point([v[0]+v[2],v[1]+v[3]]) }
        return r.steps.allSatisfy { step in
            (step.hit.map(rect) ?? true) && step.shapes.allSatisfy { shape in
                (shape.at.map(point) ?? true) && (shape.rect.map(rect) ?? true) && (shape.points?.allSatisfy(point) ?? true)
            }
        }
    }
    @discardableResult func receive(_ data: Data) -> Bool {
        guard let r = try? JSONDecoder().decode(DrawingRequest.self,from:data), Self.valid(r), Self.onDisplays(r) else { return false }
        clear(); request = r; index = 0
        board = Self.board(r.steps,near:shapeBounds(r.steps.flatMap { $0.shapes.filter { $0.kind != "text" } }) ?? r.target.bounds)
        let click: (NSEvent) -> Void = { [weak self] event in
            guard let self, event.window !== calloutPanel, !panels.contains(where: { $0 === event.window }), let point = event.cgEvent?.location else { return }   // a click on a mark selects it, never the app under it
            if request?.teaching == true { return }
            guard let target else { return }
            let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly,kCGNullWindowID) as? [[String:Any]] ?? []
            let clickedWindow = windows.first { info in
                guard (info[kCGWindowLayer as String] as? Int) == 0,
                      let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                      let frame = CGRect(dictionaryRepresentation:bounds) else { return false }
                return frame.contains(point)
            }
            guard (clickedWindow?[kCGWindowNumber as String] as? NSNumber)?.stringValue == target.windowID else { return }
            clicked(point)
        }
        if let m = NSEvent.addGlobalMonitorForEvents(matching:.leftMouseDown,handler:click) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching:.leftMouseDown,handler:{ e in click(e); return e }) { monitors.append(m) }
        showStep()
        let shown = active && (!r.teaching || calloutPanel?.isVisible == true)
        if let path = r.receipt { try? (shown ? "shown" : "The target changed; read again.").write(toFile:path,atomically:true,encoding:.utf8) }
        if active { timer = Timer.scheduledTimer(withTimeInterval:0.15,repeats:true) { [weak self] _ in self?.tick() } }
        return active
    }
    func clear() {
        let wasActive = active
        timer?.invalidate(); timer = nil; monitors.forEach(NSEvent.removeMonitor); monitors.removeAll()
        stopVoice(); panels.forEach { $0.close() }; panels.removeAll(); calloutPanel?.close(); calloutPanel = nil
        request = nil; target = nil; hit = nil; element = nil; originalValue = nil; previousPointer = nil; focus = nil
        advanceAt = .distantPast; manual = false; board = nil; selected = nil; occupied = []
        if overMark { overMark = false; NSCursor.arrow.set() }
        clearInput()
        cleanup?()
        if wasActive { changed?() }
    }
    func clearInput() {   // the user's own mark only; a guide stays
        let hadInput = hasInput
        inputPanels.forEach { $0.close() }; inputPanels.removeAll()
        inputPath = []; inputMode = false; inputDone = nil
        if hadInput { NSCursor.arrow.set(); inputCleared?() }
    }
    func hold() { stopVoice(); manual = true }   // the user is asking about it: no more talking or stepping on
    func pick(_ point: CGPoint) {
        guard let r = request, let m = panels.lazy.compactMap({ ($0.contentView as? DrawingView)?.mark(at:point) }).first,
              r.steps.indices.contains(m.step), r.steps[m.step].shapes.indices.contains(m.shape) else { return }
        clearInput(); hold()
        selected = (m.step,m.shape); panels.forEach { ($0.contentView as? DrawingView)?.highlight(selected) }
        let step = r.steps[m.step], shape = step.shapes[m.shape]
        picked?(m.bounds, "\(shape.kind)\(shape.text.map { " \"\($0)\"" } ?? "") in step \(m.step+1) of \(r.steps.count)\(step.say.map { ": " + $0 } ?? "")")
    }
    func deselect() {
        guard selected != nil else { return }
        selected = nil; panels.forEach { ($0.contentView as? DrawingView)?.highlight(nil) }
    }
    // Marks take a click only while the pointer is on one; everywhere else clicks reach the user's apps.
    func hoverMarks() {
        guard NSEvent.pressedMouseButtons == 0, let p = CGEvent(source:nil)?.location else { return }
        let mouse = NSEvent.mouseLocation, mine = panels + inputPanels
        let onBox = NSApp?.windows.contains { w in w.isVisible && !w.ignoresMouseEvents && w.frame.contains(mouse) && !mine.contains { $0 === w } } == true   // the box or a card keeps its clicks
        var over = false
        for panel in panels {
            let on = !onBox && (panel.contentView as? DrawingView)?.mark(at:p) != nil
            if panel.ignoresMouseEvents == on { panel.ignoresMouseEvents = !on }
            over = over || on
        }
        if over { NSCursor.pointingHand.set() } else if overMark { NSCursor.arrow.set() }
        overMark = over
    }
    func beginInput(_ done: @escaping ([CGPoint]) -> Void) {
        clearInput(); inputMode = true; inputDone = done
        for screen in NSScreen.screens {
            let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? CGMainDisplayID()
            let panel = DrawingPanel(contentRect:screen.frame,styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
            panel.isReleasedWhenClosed = false
            panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false; panel.ignoresMouseEvents = false; panel.acceptsMouseMovedEvents = true
            panel.hidesOnDeactivate = false; panel.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary,.ignoresCycle]
            panel.level = NSWindow.Level(rawValue:NSWindow.Level.statusBar.rawValue - 1)   // under Aurel's own panels even after a click raises it: the box, its cards and buttons take their clicks
            applySharing(panel)
            let view = DrawingView(frame:CGRect(origin:.zero,size:screen.frame.size)); view.origin = CGDisplayBounds(displayID).origin
            view.inputStart = { [weak self] in self?.startInput($0) }
            view.inputMove = { [weak self] in self?.moveInput($0) }
            view.inputEnd = { [weak self] in self?.endInput($0) }
            view.inputHover = { [weak self] in self?.hoverInput($0) }
            panel.contentView = view; panel.orderFrontRegardless(); inputPanels.append(panel)
        }
    }
    func startInput(_ point: CGPoint) { guard inputMode else { return }; inputPath = [point]; renderInput() }   // a new stroke replaces the last one
    func moveInput(_ point: CGPoint) {
        guard inputMode, !inputPath.isEmpty else { return }
        if inputPath.count < 256 && hypot(point.x - inputPath.last!.x, point.y - inputPath.last!.y) >= 2 { inputPath.append(point); renderInput() }
    }
    func endInput(_ point: CGPoint) {
        guard inputMode, !inputPath.isEmpty else { return }
        moveInput(point); renderInput(); inputDone?(inputPath)
    }
    func hoverInput(_ point: CGPoint?) {   // once marked, moving off the mark ends pointing; a stroke near it still redraws
        guard inputMode, !inputPath.isEmpty, NSEvent.pressedMouseButtons & 1 == 0 else { return }
        let xs = inputPath.map(\.x), ys = inputPath.map(\.y)
        let near = CGRect(x:xs.min()!,y:ys.min()!,width:xs.max()!-xs.min()!,height:ys.max()!-ys.min()!).insetBy(dx:-60,dy:-60)
        if point.map(near.contains) != true { inputAway?() }
    }
    func finishInput() {   // the mark stays on screen until the ask is sent; clicks reach the user's apps again
        guard inputMode else { return }
        if inputPath.isEmpty { clearInput(); return }
        inputMode = false; inputDone = nil; inputPanels.forEach { $0.ignoresMouseEvents = true }; NSCursor.arrow.set()
    }
    func renderInput() {
        guard let first = inputPath.first else { return }
        let shape = inputPath.count == 1
            ? DrawingShape(kind:"circle",rect:[Double(first.x-8),Double(first.y-8),16,16],color:"red")
            : DrawingShape(kind:"path",points:inputPath.map { [Double($0.x),Double($0.y)] },color:"red")
        for panel in inputPanels { (panel.contentView as? DrawingView)?.render([shape],animate:false,previous:nil) }
    }
    func stopVoice() { if let voice, voice.isRunning { voice.terminate() }; voice = nil }
    func shapeBounds(_ shapes: [DrawingShape]) -> CGRect? {
        var result = CGRect.null
        for shape in shapes {
            if let r = shape.rect { result = result.union(Self.rect(r)) }
            if let p = shape.at { result = result.union(CGRect(x:p[0],y:p[1],width:1,height:1)) }
            for p in shape.points ?? [] { result = result.union(CGRect(x:p[0],y:p[1],width:1,height:1)) }
        }
        return result.isNull ? nil : result
    }
    func showCallout(_ text: String, step: Int, total: Int, marks: CGRect, avoid: [CGRect]) {
        calloutPanel?.close(); calloutPanel = nil
        let screens = NSScreen.screens, top = screens.first?.frame.maxY ?? 0
        func display(_ s: NSScreen) -> CGRect { CGDisplayBounds(s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? CGMainDisplayID()) }
        guard let screen = screens.first(where: { display($0).contains(CGPoint(x:marks.midX,y:marks.midY)) }) ?? NSScreen.main ?? screens.first else { return }
        let v = screen.visibleFrame, area = CGRect(x:v.minX,y:top-v.maxY,width:v.width,height:v.height).insetBy(dx:12,dy:12)
        var size = DrawingCalloutView.size(text,total:total); size.width = min(size.width,area.width); size.height = min(size.height,area.height)
        let (card,side) = Self.calloutFrame(size,marks:marks,avoid:avoid,in:area)
        let frame = card.insetBy(dx:-DrawingCalloutView.margin,dy:-DrawingCalloutView.margin)   // Quartz points; the margin holds the notch and shadow
        let local = card.offsetBy(dx:-frame.minX,dy:-frame.minY)
        let tip = side == .minX || side == .maxX ? marks.midY-frame.minY : marks.midX-frame.minX
        let panel = DrawingPanel(contentRect:CGRect(x:frame.minX,y:top-frame.maxY,width:frame.width,height:frame.height),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        panel.isReleasedWhenClosed = false; panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.appearance = NSAppearance(named:.darkAqua)
        panel.ignoresMouseEvents = false; panel.hidesOnDeactivate = false; panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary,.ignoresCycle]; applySharing(panel)
        let callout = DrawingCalloutView(frame:CGRect(origin:.zero,size:frame.size),card:local,side:side,tip:tip,text:text,step:step,total:total)
        callout.onClose = { [weak self] in self?.clear() }
        callout.onNext = { [weak self] in self?.next() }
        callout.onBack = { [weak self] in self?.back() }
        panel.contentView = callout; calloutPanel = panel
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { panel.orderFrontRegardless() }
        else { panel.alphaValue = 0; panel.orderFrontRegardless(); NSAnimationContext.runAnimationGroup { $0.duration = 0.18; panel.animator().alphaValue = 1 } }
    }
    func showStep(forward: Bool = true) {
        guard let r = request, r.steps.indices.contains(index) else { clear(); return }
        stopVoice(); calloutPanel?.close(); calloutPanel = nil
        let step = r.steps[index]; target = r.target; hit = step.hit.map(Self.rect); element = nil; originalValue = nil
        var shapes = step.shapes
        if let label = step.target {
            do {
                guard let resolve else { clear(); return }
                let (frame,e,window) = try resolve(label,r.state)
                guard Self.validRect([frame.minX,frame.minY,frame.width,frame.height]), window.valid else { clear(); return }
                target = window; hit = frame; element = e
                if let e { originalValue = readValue(e) }
                for i in shapes.indices {
                    if ["rect","circle"].contains(shapes[i].kind), shapes[i].rect == nil { shapes[i].rect = [frame.minX,frame.minY,frame.width,frame.height] }
                    if ["label","pointer"].contains(shapes[i].kind), shapes[i].at == nil { shapes[i].at = [frame.midX,frame.midY] }
                }
            } catch { status?("The screen changed. Ask again to continue."); clear(); return }
        }
        guard let target else { clear(); return }
        if !r.teaching || index == 0 {
            guard Self.current(target) else { clear(); return }
        }
        let animate = forward && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if panels.count != NSScreen.screens.count {
            panels.forEach { $0.close() }; panels.removeAll()
            for screen in NSScreen.screens {
                let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? CGMainDisplayID()
                let panel = DrawingPanel(contentRect:screen.frame,styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
                panel.isReleasedWhenClosed = false
                panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false; panel.ignoresMouseEvents = true
                panel.hidesOnDeactivate = false; panel.level = .statusBar; panel.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary,.ignoresCycle]
                applySharing(panel)
                let view = DrawingView(frame:CGRect(origin:.zero,size:screen.frame.size)); view.origin = CGDisplayBounds(displayID).origin
                view.pick = { [weak self] in self?.pick($0) }
                panel.contentView = view; panel.orderFrontRegardless(); panels.append(panel)
            }
        }
        // Each show redraws from scratch, so Back removes this step's marks; a whiteboard keeps earlier steps, quieter.
        var marks = CGRect.null, earlier: [CGRect] = []
        let page = board.flatMap { Self.boardPage($0, through: index) }
        let lines = page?.lines ?? []
        let boardFrame = page?.frame
        for panel in panels {
            guard let view = panel.contentView as? DrawingView else { continue }
            view.reset()
            if r.teaching { earlier += r.steps[..<index].enumerated().map { view.render($0.element.shapes,animate:false,previous:nil,append:true,dim:true,step:$0.offset) }.filter { !$0.isNull } }
            if let boardFrame { view.renderBoard(boardFrame,lines,current:index,animate:animate) }
            marks = marks.union(view.render(shapes,animate:animate,previous:forward ? previousPointer : nil,append:true,avoid:hit.map { [$0] } ?? [],step:index))
            view.highlight(selected)
        }
        if let boardFrame { if lines.contains(where: { $0.step == index }) { marks = marks.union(boardFrame) } else { earlier.append(boardFrame) } }
        guard !marks.isNull else { clear(); return }
        focus = marks
        if let point = shapes.last(where: { $0.kind == "pointer" })?.at { previousPointer = CGPoint(x:point[0],y:point[1]) }
        let now = Date(); deadline = r.teaching ? .distantFuture : now.addingTimeInterval(step.timeout ?? 60); ready = now.addingTimeInterval(0.35)
        let words = step.say ?? ""
        advanceAt = now.addingTimeInterval(max(3,min(12,1.5+Double(words.split(separator:" ").count)/3.5)))   // long enough to read the callout
        if !words.isEmpty || r.steps.count > 1 {
            showCallout(words,step:index+1,total:r.steps.count,marks:marks.isNull ? shapeBounds(shapes) ?? target.bounds : marks,avoid:earlier + (hit.map { [$0] } ?? []))
        }
        if !words.isEmpty, speechEnabled() {
            let p = Process(); p.executableURL = URL(fileURLWithPath:"/usr/bin/say"); p.arguments = sayArguments(words)
            try? p.run(); voice = p
        }
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        occupied = panels.flatMap { ($0.contentView as? DrawingView)?.hitBounds ?? [] } + [boardFrame, hit].compactMap { $0 }
            + (calloutPanel.map { f in [CGRect(x:f.frame.minX,y:top-f.frame.maxY,width:f.frame.width,height:f.frame.height)] } ?? [])
        changed?()
    }
    func advance() {
        guard let r = request else { return }
        if index+1 < r.steps.count { index += 1; showStep() } else if !r.teaching { clear() }
    }
    func next() {   // the user's Next ("next" by voice or typing too); on the last step it is Done
        guard let r = request else { return }
        manual = true
        if index+1 < r.steps.count { index += 1; showStep() } else { clear() }
    }
    func back() {
        guard request != nil, index > 0 else { return }
        manual = true; index -= 1; showStep(forward:false)
    }
    func clicked(_ point: CGPoint) {
        guard let r = request, Date() >= ready else { return }
        let step = r.steps[index]
        guard step.wait != true || hit?.contains(point) == true else { return }
        advance()
    }
    static func current(_ target: DrawingWindow) -> Bool {
        let infos = CGWindowListCopyWindowInfo(.optionOnScreenOnly,kCGNullWindowID) as? [[String:Any]] ?? []
        guard let info = infos.first(where: { ($0[kCGWindowNumber as String] as? NSNumber)?.stringValue == target.windowID && ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == target.pid }),
              let bounds = info[kCGWindowBounds as String] as? NSDictionary, let frame = CGRect(dictionaryRepresentation:bounds), frame == target.bounds else { return false }
        return true
    }
    func tick() {
        guard let r = request, let target else { return }
        hoverMarks()
        if !r.teaching {
            guard Self.current(target) else { status?("The screen changed. Ask again to continue."); clear(); return }
            if Date() >= deadline { clear(); return }
        }
        let step = r.steps[index]
        if step.wait == true, Date() >= ready, let element {
            if let value = readValue(element), let originalValue, !CFEqual(value,originalValue) { advance() }
        } else if step.wait != true, !manual, autoSteps(), index+1 < r.steps.count, Date() >= advanceAt, voice?.isRunning != true { advance() }
    }
}

// The box can take typing (canBecomeKey) without pulling Aurel forward (nonactivating): the user's app stays in front.
final class KeyPanel: NSPanel { override var canBecomeKey: Bool { true } }

// Mini screen: local window-only buffers stay in a native layer, underneath the transparent web controls.
final class PassView: NSView { override func hitTest(_ point: NSPoint) -> NSView? { nil } }   // shows, never takes the click
final class MiniScreen: NSObject, SCStreamOutput, SCStreamDelegate {
    static var captureStop: Task<Void,Never>?   // a new preview waits until the previous stream has actually stopped
    let clip = PassView(), picture = AVSampleBufferDisplayLayer(), previous = AVSampleBufferDisplayLayer()
    var lastSample: CMSampleBuffer?, transitioning = false
    var stream: SCStream?, target: [String:Any]?, timer: Timer?, ending: DispatchWorkItem?
    var forcePreview = false, captureAllowed: (() -> Bool)?
    var publish: (([String:Any]) -> Void)?
    var retry = Date.distantPast
    var generation = 0, shown = false, live = false, starting = false, failed = false, frames = 0
    override init() {
        super.init()
        clip.wantsLayer = true; clip.layer?.masksToBounds = true; clip.isHidden = true
        picture.videoGravity = .resizeAspect; picture.cornerRadius = 12; picture.masksToBounds = true
        picture.backgroundColor = NSColor.black.cgColor; clip.layer?.addSublayer(picture)
        previous.videoGravity = .resizeAspect; previous.cornerRadius = 12; previous.masksToBounds = true
        previous.backgroundColor = NSColor.black.cgColor; previous.opacity = 0; clip.layer?.addSublayer(previous)
    }
    static func activate(_ pid: Int32) {
        // System Events addresses the running process; cooperative AppKit activation can be refused from our background panel.
        _ = NSRunningApplication(processIdentifier: pid)?.activate()
        let p = Process(); p.executableURL = URL(fileURLWithPath:"/usr/bin/osascript")
        p.arguments = ["-e", "tell application \"System Events\" to set frontmost of (first application process whose unix id is \(pid)) to true"]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        let timeout = DispatchWorkItem { if p.isRunning { p.terminate() } }
        p.terminationHandler = { process in process.terminationHandler = nil; timeout.cancel() }
        guard (try? p.run()) != nil else { p.terminationHandler = nil; return }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2, execute: timeout)
    }
    static var workInFront: Bool { Prefs.str("workIn") == "front" || ProcessInfo.processInfo.environment["AUREL_FOCUS_REQUESTED"] == "1" }
    static func work(_ app: NSRunningApplication) {
        guard workInFront, NSWorkspace.shared.frontmostApplication != app else { return }
        DistributedNotificationCenter.default().postNotificationName(.init("aurel.raise"), object: "user", deliverImmediately: true)
        usleep(50_000); activate(app.processIdentifier)
    }
    static func bounds(_ info: [String:Any]) -> CGRect? {
        (info[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation:$0) }
    }
    // Visible = on displays and at most 10% under normal windows in front of it: input reaches it without raising it.
    static func visible(_ r: CGRect, displays: [CGRect], above: [CGRect]) -> Bool {
        let area = { (a: CGRect) in a.isNull ? 0 : a.width * a.height }
        return area(r) > 0 && displays.reduce(0) { $0 + area($1.intersection(r)) } >= area(r) * 0.9 && above.reduce(0) { $0 + area($1.intersection(r)) } <= area(r) * 0.1
    }
    // Where a window (top-left points) lands in its display's 1280-wide --look picture, in CoreGraphics' bottom-up drawing space.
    static func paintRect(_ w: CGRect, display d: CGRect, pictureHeight: Int) -> CGRect {
        let s = 1280 / d.width
        return CGRect(x: (w.minX - d.minX) * s, y: CGFloat(pictureHeight) - (w.maxY - d.minY) * s, width: w.width * s, height: w.height * s)
    }
    static func windowTarget(_ app: NSRunningApplication, title: String = "", frame: [Double] = [], screen: CGRect? = nil, windows: [[String:Any]]) -> [String:Any]? {
        if !frame.isEmpty && (frame.count != 4 || !frame.allSatisfy(\.isFinite)) { return nil }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        let elements = axAttribute(root, kAXWindowsAttribute) as? [AXUIElement] ?? []
        let preferred = axAttribute(root,kAXFocusedWindowAttribute).flatMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? axWindowNumber($0 as! AXUIElement) : nil }
        let named = windows.map { info -> [String:Any] in
            var value = info
            if (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == app.processIdentifier,
               info[kCGWindowName as String] == nil, let number = info[kCGWindowNumber as String] as? NSNumber,
               let w = elements.first(where: { axWindowNumber($0) == number }) {
                value[kCGWindowName as String] = axAttribute(w,kAXTitleAttribute) as? String
            }
            return value
        }
        let candidates = named.filter {
            ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == app.processIdentifier &&
            ($0[kCGWindowLayer as String] as? Int) == 0 && bounds($0).map { $0.width > 1 && $0.height > 1 && ($0.height > 40 || $0.width < $0.height * 10) } == true &&
            (title.isEmpty || ($0[kCGWindowName as String] as? String ?? "").localizedCaseInsensitiveContains(title)) &&
            (frame.isEmpty || bounds($0).map { abs($0.minX-frame[0]) < 2 && abs($0.minY-frame[1]) < 2 && abs($0.width-frame[2]) < 2 && abs($0.height-frame[3]) < 2 } == true) &&
            (screen == nil || bounds($0).map { screen!.contains(CGPoint(x:$0.midX,y:$0.midY)) } == true)
        }
        if !frame.isEmpty && candidates.count != 1 { return nil }   // indistinguishable windows are not a safe preview target
        let real = Set(elements.compactMap(axWindowNumber))   // apps own invisible full-width strips; AX lists only real windows
        let area = { (w: [String:Any]) in bounds(w).map { $0.width * $0.height } ?? 0 }
        guard let w = candidates.first(where: { ($0[kCGWindowNumber as String] as? NSNumber) == preferred })
                ?? candidates.first(where: { ($0[kCGWindowNumber as String] as? NSNumber).map(real.contains) == true })
                ?? candidates.max(by: { area($0) < area($1) }),   // no AX (other Space): the strips are always the smallest
              let frame = bounds(w), let number = w[kCGWindowNumber as String] as? NSNumber else { return nil }
        let minimized = elements.contains { axWindowNumber($0) == number && axAttribute($0,kAXMinimizedAttribute) as? Bool == true }
        return ["pid":app.processIdentifier,"windowID":number.stringValue,"windowFrame":[frame.minX,frame.minY,frame.width,frame.height],
                "window":w[kCGWindowName as String] as? String ?? app.localizedName ?? "Window","app":app.localizedName ?? "App","minimized":minimized]
    }
    var pid: Int32 { (target?["pid"] as? NSNumber)?.int32Value ?? 0 }
    var id: UInt32 { UInt32(target?["windowID"] as? String ?? "") ?? 0 }
    var holds: Bool { target != nil && shown && timer == nil }
    func receive(_ value: [String:Any]) {
        guard let p = value["pid"] as? NSNumber, p.int32Value > 0,
              let w = value["windowID"] as? String, UInt32(w).map({ $0 > 0 }) == true,
              let f = value["windowFrame"] as? [Double], f.count == 4, f.allSatisfy(\.isFinite), f[2] > 0, f[3] > 0 else { return }
        ending?.cancel(); ending = nil
        failed = false
        let icon = pid == p.int32Value ? target?["icon"] as? String : nil
        let changed = pid != p.int32Value || id != UInt32(w)!
        if changed {
            let old = lastSample; stopCapture(clear:false); failed = false; frames = 0
            if let old { previous.sampleBufferRenderer.enqueue(old); previous.opacity = 1; transitioning = true }
        }
        target = value
        if let icon { target?["icon"] = icon }
        else if let app = NSRunningApplication(processIdentifier:p.int32Value), let icon = app.icon,
           let data = icon.tiffRepresentation, let bitmap = NSBitmapImageRep(data:data), let png = bitmap.representation(using:.png,properties:[:]) {
            target?["icon"] = "data:image/png;base64," + png.base64EncodedString()
        }
        if timer == nil { timer = Timer.scheduledTimer(withTimeInterval:0.5,repeats:true) { [weak self] _ in self?.refresh() } }
        refresh(force:true)
    }
    // Preview a window the user can't see: not on screen (other Space, minimized, hidden, behind full screen), or over a quarter
    // of it off every awake display or under other windows. The quarter lets near-transparent overlays (dictation HUDs) and an
    // app's own toolbar strips sit on top without counting as cover; CGWindow info can't tell a transparent window apart.
    static func needsPreview(pid: Int32, id: UInt32, windows: [[String:Any]], displays: [CGRect]) -> Bool {
        guard let index = windows.firstIndex(where: { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == id && ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid }),
              let frame = bounds(windows[index]), frame.width > 0, frame.height > 0 else { return true }
        let covers = windows.prefix(index).compactMap { w -> CGRect? in
            guard (w[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value != ProcessInfo.processInfo.processIdentifier,
                  (w[kCGWindowAlpha as String] as? Double ?? 1) > 0, let b = bounds(w), b.width > 1, b.height > 1 else { return nil }
            return b
        }
        let n = 20, hidden = (0..<n*n).filter { k in
            let p = CGPoint(x:frame.minX + frame.width * (Double(k % n) + 0.5) / Double(n), y:frame.minY + frame.height * (Double(k / n) + 0.5) / Double(n))
            return !displays.contains { $0.contains(p) } || covers.contains { $0.contains(p) }
        }.count
        return hidden * 4 > n * n
    }
    func refresh(force: Bool = false) {
        guard target != nil, ending == nil else { return }
        let oldFrame = target?["windowFrame"] as? [Double]
        let oldMinimized = target?["minimized"] as? Bool ?? false
        let elements = axAttribute(AXUIElementCreateApplication(pid), kAXWindowsAttribute) as? [AXUIElement] ?? []
        if let w = elements.first(where: { axWindowNumber($0)?.uint32Value == id }) { target?["minimized"] = axAttribute(w,kAXMinimizedAttribute) as? Bool ?? false }
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly,.excludeDesktopElements],kCGNullWindowID) as? [[String:Any]] ?? []
        if let window = windows.first(where: { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == id && ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid }), let f = Self.bounds(window), f.width > 0, f.height > 0 {
            target?["windowFrame"] = [f.minX,f.minY,f.width,f.height].map(Double.init)
            if let oldFrame, oldFrame[2] != f.width || oldFrame[3] != f.height, let s = stream { Task { try? await s.updateConfiguration(Self.configuration(f)) } }
        }
        var ids = [CGDirectDisplayID](repeating:0,count:16), count: UInt32 = 0
        CGGetActiveDisplayList(16,&ids,&count)
        let displays = ids.prefix(Int(count)).filter { CGDisplayIsAsleep($0) == 0 }.map(CGDisplayBounds)
        let next = forcePreview || Self.needsPreview(pid:pid,id:id,windows:windows,displays:displays)
        let changed = shown != next; shown = next
        if failed && Date() >= retry { failed = false }
        if !shown || captureAllowed?() == false { stopCapture(clear:false) }
        else if target?["minimized"] as? Bool == true { stopCapture(clear:true) }
        else if stream == nil && !starting && !failed && CGPreflightScreenCaptureAccess() { startCapture() }
        if force || changed || oldFrame != target?["windowFrame"] as? [Double] || oldMinimized != (target?["minimized"] as? Bool ?? false) { send() }
    }
    func send() {
        guard var value = target else { return }; value["shown"] = shown; value["live"] = live || transitioning; publish?(value)
    }
    static func configuration(_ frame: CGRect) -> SCStreamConfiguration {
        let cfg = SCStreamConfiguration(), scale = min(600 / max(1,frame.width),375 / max(1,frame.height))
        cfg.width = max(1,Int((frame.width * scale).rounded())); cfg.height = max(1,Int((frame.height * scale).rounded()))
        cfg.minimumFrameInterval = CMTime(value:1,timescale:12); cfg.showsCursor = false
        cfg.ignoreShadowsSingleWindow = true; cfg.queueDepth = 3; cfg.scalesToFit = true; cfg.preservesAspectRatio = true
        return cfg   // matching the window aspect leaves letterboxing to the centered native layer
    }
    func startCapture() {
        generation += 1; let token = generation, windowID = id, processID = pid
        starting = true
        Task { @MainActor [weak self] in
            await Self.captureStop?.value
            let all = try? await SCShareableContent.excludingDesktopWindows(true,onScreenWindowsOnly:false)
            guard let self, generation == token, shown else { return }
            guard let w = all?.windows.first(where: { $0.windowID == windowID && $0.owningApplication?.processID == processID }) else { starting = false; failed = true; retry = Date().addingTimeInterval(3); stopCapture(clear:false); send(); return }
            let cfg = Self.configuration(w.frame)
            let s = SCStream(filter:SCContentFilter(desktopIndependentWindow:w),configuration:cfg,delegate:self)
            do {
                try s.addStreamOutput(self,type:.screen,sampleHandlerQueue:.main); stream = s
                try await s.startCapture()
                if generation != token { try? await s.stopCapture() }
            } catch { if generation == token { failed = true; retry = Date().addingTimeInterval(3); stopCapture(clear:false); send() } }
        }
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard self.stream === stream, type == .screen, sample.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sample,createIfNecessary:false) as? [[SCStreamFrameInfo:Any]],
              let status = attachments.first?[.status] as? Int, status == SCFrameStatus.complete.rawValue else { return }
        if picture.sampleBufferRenderer.status == .failed { picture.sampleBufferRenderer.flush(removingDisplayedImage:false) }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample,createIfNecessary:true) as? [NSMutableDictionary], let info = attachments.first { info[kCMSampleAttachmentKey_DisplayImmediately] = true }
        picture.sampleBufferRenderer.enqueue(sample); lastSample = sample; frames += 1
        if transitioning {
            transitioning = false
            let fade = CABasicAnimation(keyPath:"opacity"); fade.fromValue = 1; fade.toValue = 0; fade.duration = 0.24
            previous.opacity = 0; previous.add(fade,forKey:"switch")
            let token = generation
            DispatchQueue.main.asyncAfter(deadline:.now() + 0.25) { [weak self] in if self?.generation == token { self?.previous.sampleBufferRenderer.flush(removingDisplayedImage:true) } }
        }
        if !live { live = true; starting = false; send() }
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.stream === stream else { return }; failed = true; retry = Date().addingTimeInterval(3); stopCapture(clear:false); send()
        }
    }
    func stopCapture(clear: Bool) {
        generation += 1; starting = false
        if let s = stream {
            stream = nil; let previous = Self.captureStop
            Self.captureStop = Task { await previous?.value; try? await s.stopCapture() }
        }
        if clear { live = false; transitioning = false; lastSample = nil; picture.sampleBufferRenderer.flush(removingDisplayedImage:true); previous.removeAllAnimations(); previous.opacity = 0; previous.sampleBufferRenderer.flush(removingDisplayedImage:true); clip.isHidden = true }
    }
    func finish() {
        guard target != nil, ending == nil else { return }
        timer?.invalidate(); timer = nil; stopCapture(clear:false)   // freeze the last buffer; it stays until the next ask, typing, or a click on it (the page clears it)
    }
    func reset() {
        ending?.cancel(); ending = nil; timer?.invalidate(); timer = nil
        stopCapture(clear:true); target = nil; shown = false; failed = false
    }
    func layout(_ value: [String:Any]) {
        guard let r = value["rect"] as? [Double], r.count == 4, r.allSatisfy(\.isFinite),
              let c = value["clip"] as? [Double], c.count == 4, c.allSatisfy(\.isFinite), let height = clip.superview?.bounds.height else { clip.isHidden = true; return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        clip.frame = NSRect(x:c[0],y:height - c[1] - c[3],width:max(0,c[2]),height:max(0,c[3]))
        picture.frame = CGRect(x:r[0] - c[0],y:c[3] - (r[1] - c[1]) - r[3],width:max(0,r[2]),height:max(0,r[3]))
        picture.cornerRadius = min(12,max(0,r[3]) / 4); picture.videoGravity = value["fill"] as? Bool == true ? .resizeAspectFill : .resizeAspect   // a chip thumbnail fills its little tile
        previous.frame = picture.frame; previous.cornerRadius = picture.cornerRadius; previous.videoGravity = picture.videoGravity
        clip.layer?.opacity = Float(value["opacity"] as? Double ?? 1)
        clip.isHidden = !(live || transitioning) || r[2] <= 0 || r[3] <= 0
        CATransaction.commit()
    }
    func open() {
        guard (CGWindowListCopyWindowInfo(.optionAll,kCGNullWindowID) as? [[String:Any]] ?? []).contains(where: {
            ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == id && ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid
        }) else { return }
        guard let a = NSRunningApplication(processIdentifier:pid), !a.isTerminated, let f = target?["windowFrame"] as? [Double], f.count == 4 else { return }
        let processID = pid, windowID = id
        let raise = {
            let windows = axAttribute(AXUIElementCreateApplication(processID),kAXWindowsAttribute) as? [AXUIElement] ?? []
            let direct = windows.filter { axWindowNumber($0)?.uint32Value == windowID }
            let matches = direct.isEmpty ? windows.filter {
                guard let p = axAttribute($0,kAXPositionAttribute), let s = axAttribute($0,kAXSizeAttribute), CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return false }
                var origin = CGPoint.zero, size = CGSize.zero
                guard AXValueGetValue(p as! AXValue,.cgPoint,&origin), AXValueGetValue(s as! AXValue,.cgSize,&size) else { return false }
                return abs(origin.x - f[0]) < 2 && abs(origin.y - f[1]) < 2 && abs(size.width - f[2]) < 2 && abs(size.height - f[3]) < 2
            } : direct
            if matches.count == 1 {
                AXUIElementSetAttributeValue(matches[0],kAXMinimizedAttribute as CFString,kCFBooleanFalse)
                AXUIElementPerformAction(matches[0],kAXRaiseAction as CFString)
            }
        }
        Self.activate(processID); raise()
        DispatchQueue.main.asyncAfter(deadline:.now()+0.3) {   // AX windows on another Space can appear after activation returns
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == processID { raise() }
        }
    }
}

func boxWidth(_ saved: Double, _ bounds: NSRect) -> CGFloat {
    min(CGFloat(min(900, max(340, saved.isFinite ? saved : 500))), bounds.width - 16)
}

final class App: NSObject {
    let mini = MiniScreen()
    let quietAudio = AudioQuiet(layer: CoreAudioVolume(), changed: AudioRecovery.changed)
    let panel = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: boxWidth(Prefs.num("boxW"), mouseScreen.visibleFrame), height: 76),
                        styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
    let boxModel: BoxModel, boxView: NSHostingView<BoxView>   // the box (Box.swift): the model takes each call, the view draws it
    let engine = Mic()
    // Speech: Apple's SpeechAnalyzer (macOS 26+), on-device and free; punctuates and capitalizes.
    var feed: AsyncStream<AnalyzerInput>.Continuation?, analyzer: SpeechAnalyzer?, reading: Task<Void, Never>?
    var speechInputs: SpeechInputs?, speechInputID: UUID?, speechSegment = 0, activeSpeechSegment = 0
    var speechText: [Int: (base: String, done: String, live: String)] = [:]
    var nextFeed: AsyncStream<AnalyzerInput>.Continuation?, nextAnalyzer: SpeechAnalyzer?, nextReading: Task<Void, Never>?
    var nextSpeechInputID: UUID?, nextSpeechSegment = 0, nextSpeechRollover = 50.0
    var speechFormat: AVAudioFormat?, preparingSpeech = false   // what the model wants (found at launch and when the model changes)
    var quietFollowUp = false
    var handsFreeIdle = 0
    func fadeIdleHandsFree() {   // a hands-free chat nobody talks to fades after 90 s; a moved or resized box stays (pinned)
        handsFreeIdle += 1; let id = handsFreeIdle
        DispatchQueue.main.asyncAfter(deadline: .now() + 90) { [self] in
            guard id == handsFreeIdle, handsFree, !pinned, !busy, !engine.isRunning else { return }
            handsFree = false; followUp = false; hide(after: 0)
        }
    }
    var handsFree = false, followUp = false, wakeSleeping = false, wakeInactive = false
    var wakeSuspended: Bool { wakeSleeping || wakeInactive }
    let wakeMic = Mic()
    var wakeRecognizer: SFSpeechRecognizer?
    var wakeTask: SFSpeechRecognitionTask?, wakeRequest: SFSpeechAudioBufferRecognitionRequest?
    var wakeID = 0, wakeRetry = Date.distantPast, wakeBegan = Date.distantPast, wakeDevice = ""
    var wakeBackoff = 1.0, wakePermissionID = 0, wakeWhy = "?"
    // "Aurel" is rare, so the recognizer is told to expect it, and the ways it spells the name count too: Aural, Orel, Oriel,
    // Aurelle… anywhere; words people say anyway (oral, Laurel, Ariel) only right after a greeting: "hey Laurel".
    static func hasWakeWord(_ text: String) -> Bool {
        text.range(of: #"(?i)(?<![\p{L}\p{N}_])(?:(?:au|o)r{1,2}(?:e|ie|ea)l{1,2}e?|aural|(?:hey|hi|ok|okay|yo),? (?:oral|laurel|ariel|arial|or el|our el))(?:['’]s)?(?![\p{L}\p{N}_])"#, options: .regularExpression) != nil
    }
    // A hands-free chat ends when the whole utterance says so ("close", "that's all, thanks"); "close Safari" is still an ask.
    static func endsChat(_ text: String) -> Bool {
        let words = text.lowercased().replacingOccurrences(of: "’", with: "'").components(separatedBy: CharacterSet.letters.union(.init(charactersIn: "'")).inverted).filter { !$0.isEmpty }.joined(separator: " ")
        return words.range(of: #"^(?:(?:ok|okay|thanks|thank you|hey|aurel) )*(?:close|close it|stop|stop listening|goodbye|bye|bye bye|that's all|that's it|i'm done|we're done|nothing else|never mind|nevermind)(?: (?:thanks|thank you|aurel))*$"#, options: .regularExpression) != nil
    }
    func stopWake() {
        wakeID += 1
        let task = wakeTask, request = wakeRequest
        wakeTask = nil; wakeRequest = nil; wakeRecognizer = nil
        wakeMic.stop { task?.cancel(); request?.endAudio() }   // drain audio callbacks before ending their request
    }
    func wakeFailed() {
        if Date().timeIntervalSince(wakeBegan) > 10 { wakeBackoff = 1 }
        stopWake(); wakeRetry = Date().addingTimeInterval(wakeBackoff); wakeBackoff = min(30, wakeBackoff * 2)
    }
    func clickMicrophone(quiet: Bool = false) {
        clickTalk = true; start(dictate: false, quiet: quiet); if !engine.isRunning { clickTalk = false }
    }
    func wakeTick() {
        let waits: [(String, Bool)] = [("off", !Prefs.bool("wakeWord")), ("paused", Prefs.bool("paused")), ("asleep", wakeSleeping), ("inactive", wakeInactive),
            ("busy", busy), ("talking", engine.isRunning), ("dictating", dictating), ("typing", composing),
            ("shortcut", shortcutDown || dictateShortcutDown), ("box", panel.isVisible && !handsFree),
            ("speaking", voice?.isRunning == true || drawing.voice?.isRunning == true), ("sound", cueSound?.isPlaying == true || Date() < cueEnds),
            ("onboarding", onboarding.win != nil), ("mic permission", AVCaptureDevice.authorizationStatus(for: .audio) != .authorized),
            ("speech permission", SFSpeechRecognizer.authorizationStatus() != .authorized)]
        // A hands-free follow-up opens the mic itself: an empty focused Ask field (typing hushes it), the wake word setting
        // and Apple speech permission (Parakeet needs none; start() checks) are the wake listener's waits, not its.
        let why = waits.first { $0.1 && !(handsFree && followUp && ["off", "box", "typing", "speech permission"].contains($0.0)) }?.0 ?? ""
        if why != wakeWhy { wakeWhy = why; NSLog("Wake word: %@", why.isEmpty ? "listening" : "waits (\(why))") }   // app.err shows why it is not listening
        guard why.isEmpty else {
            if wakeRequest != nil { stopWake() }; return
        }
        if handsFree && followUp {
            followUp = false; stopWake(); clickMicrophone(quiet: true); return
        }
        let device = listenMic().flatMap { AVCaptureDevice(uniqueID: $0.uid) } ?? AVCaptureDevice.default(for: .audio)
        if wakeRequest != nil {
            if device?.uniqueID != wakeDevice || Date().timeIntervalSince(wakeBegan) > 50 { wakeFailed() }
            return
        }
        guard Date() >= wakeRetry else { return }   // waiting out a backoff must not push the retry later
        guard let device,
              let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else { NSLog("Wake word: no on-device recognizer or mic, retry in 30 s"); wakeRetry = Date().addingTimeInterval(30); return }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true; request.shouldReportPartialResults = true; request.contextualStrings = ["Aurel", "Hey Aurel"]
        wakeRecognizer = recognizer; wakeRequest = request; wakeID += 1; let id = wakeID
        wakeBegan = Date(); wakeDevice = device.uniqueID
        wakeTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            DispatchQueue.main.async { [weak self] in
                guard let self, wakeID == id else { return }
                if let result, result.transcriptions.contains(where: { Self.hasWakeWord($0.formattedString) }) {   // its other guesses too: a rare name is often second
                    wakeBackoff = 1
                    stopWake(); handsFree = true; clickMicrophone()
                } else if error != nil || result?.isFinal == true {
                    if let error { NSLog("Wake word: recognizer error %@", error.localizedDescription) }
                    if error == nil { wakeBackoff = 1 }; wakeFailed()
                }
            }
        }
        wakeMic.start(device, sampleRate: 16000, { request.append($0) }) { [weak self] result in
            guard let self, wakeID == id else { return }
            if case .failure(let error) = result { NSLog("Wake word: mic error %@", error.localizedDescription); wakeFailed() }
        }
    }
    func enableWakeWord() {
        wakePermissionID += 1; let id = wakePermissionID
        let finish: () -> Void = { [weak self] in DispatchQueue.main.async { [weak self] in
            guard let self, wakePermissionID == id, Prefs.bool("wakeWord") else { return }
            let mic = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
            let speech = SFSpeechRecognizer.authorizationStatus() == .authorized
            if !mic || !speech {
                Prefs.set("wakeWord", false)
                Aurel.settings.send("notice", ["text": "Allow Aurel in System Settings → Privacy & Security → \(mic ? "Speech Recognition" : "Microphone")."])
            } else if SFSpeechRecognizer(locale: Locale(identifier: "en-US"))?.supportsOnDeviceRecognition != true {
                Prefs.set("wakeWord", false)
                Aurel.settings.send("notice", ["text": "On-device Speech Recognition is unavailable on this Mac."])
            }
            Aurel.settings.push(); wakeTick()
        } }
        let speech: () -> Void = {
            if SFSpeechRecognizer.authorizationStatus() == .notDetermined { SFSpeechRecognizer.requestAuthorization { _ in finish() } }
            else { finish() }
        }
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined { AVCaptureDevice.requestAccess(for: .audio) { _ in speech() } }
        else { speech() }
    }
    // Parakeet: the mic fills parakeetAudio; the listen timer re-transcribes it a few times a second for live words, and a segment
    // closes on a pause after 25 s (hard at 30 s) so each pass stays short. Final passes queue on parakeetChain, in order.
    let parakeetAudio = ParakeetAudio()
    var parakeetListen = false, parakeetBusy = false, parakeetAsk = 0, parakeetSent = 0.0, parakeetQueued = 0.0
    var parakeetAsked = Date.distantPast, parakeetVoice = Date.distantPast, wordsChanged = Date.distantPast, parakeetChain: Task<Void, Never>?
    // Settings → Speech model: Apple's newer SpeechTranscriber, or the Dictation model the keyboard mic uses.
    // Dictation drops fastResults / frequentFinalization (Apple: faster but less accurate); asks keep them for live commands.
    func speechModule(dictate: Bool = false) -> any SpeechModule {
        let en = Locale(identifier: "en-US"), locale = en   // SpeechTranscriber rejects the Mac locale ("unsupported locale") even when SFSpeechRecognizer lists it: every voice ask died (1.5.0)
        if Prefs.str("speechModel") == "dictation" {
            return dictate ? DictationTranscriber(locale: en, contentHints: [.shortForm], transcriptionOptions: [.punctuation], reportingOptions: [.volatileResults], attributeOptions: [])
                : DictationTranscriber(locale: locale, preset: .progressiveShortDictation)
        }
        return dictate ? SpeechTranscriber(locale: en, transcriptionOptions: [], reportingOptions: [.volatileResults], attributeOptions: [])
            : SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
    }
    func prepareSpeech() {   // make sure the speech model is installed, and learn its audio format
        if Prefs.str("speechModel") == "parakeet" { Parakeet.shared.warm(); return }   // the local helper: no Apple asset; start() records 16 kHz mono for it
        Parakeet.shared.stop()
        guard !preparingSpeech else { return }
        preparingSpeech = true
        let m = speechModule()
        Task { [weak self] in
            if let r = try? await AssetInventory.assetInstallationRequest(supporting: [m]) { try? await r.downloadAndInstall() }
            let f = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [m])
            await MainActor.run { self?.speechFormat = f; self?.preparingSpeech = false }
        }
    }
    var text = "", answer = "", busy = false, speechFailed = false, gen = 0
    var agentCard = ""   // the hand-off or done card on screen: Esc picks its quiet choice
    var replyAgent = ""   // the agent whose done card was up when this ask began: talking clears the card, so it is kept here
    var showAgent = ""   // the task this ask showed (--agent-show): its work comes up when the ask ends
    var defaultKeys: [EventHotKeyRef] = []
    var defaultWanted = false, defaultObservers: [NSObjectProtocol] = []
    var proc: Process?, escRef: EventHotKeyRef?, warm: (p: Process, input: FileHandle, commit: String)?
    var commit = "", listenID = 0
    var consumed = 0, fastBusy = false, did: [String] = [], pause: DispatchWorkItem?   // "Act while I'm talking": commands done mid-sentence
    var fastProc: Process?, consumedText = "", liveRevised = false, targetScreen = ""
    var ahead = "", aheadItem: DispatchWorkItem?   // words the AI already started on while the user was still holding the keys
    var stops = 0   // each key release; tells a late "words landed" from a current one
    var dragging = false, fromTop = false   // moving or resizing the box; fromTop: dragging the top edge, so the bottom stays put
    var followTimer: Timer?
    var began = Date()   // when recording began, for the recording limit
    var composing = false, compH: CGFloat = 0, clickTalk = false, quiet: DispatchWorkItem?   // typing box focused / its height from the bottom; mic button = talk without keys
    var toggleTalk = false, shortcutDown = false, pausedNotice = Date.distantPast
    var dictating = false, dictateCleanup = false, dictateShortcutDown = false, dictateSelectionPending = false
    var dictatePressed = Date.distantPast, dictateTap: DispatchWorkItem?   // dictateTap: a quick tap waiting to see if a second one locks
    var dictateSelection: TextSelection?, dictationTargetApp: NSRunningApplication?, dictateProcess: Process?, dictateInput: FileHandle?, dictateOutput: FileHandle?, dictateID = 0, dictateBefore = ""
    var dictateSelectionRetried = false
    var askFile = ""   // safe mode: where the Allow / Don't Allow answer goes (aurel.py's gate waits on it)
    var askNeed: [String:Any] = [:]
    var agentMoveFile = "" { didSet { moveKey() } }   // set while aurel.py watches it: the running ask can move to an agent
    var moveRef: EventHotKeyRef?
    var retryOffer = false, offerText: String?   // answering a choices or failure card preserves its original request
    var picking: Bool { retryOffer && askNeed["pick"] != nil }   // a choices card waits: the shortcut hides it while the user says the answer
    var hovering = false, pinned = false, stuck = false, lastDone = Date.distantPast   // pinned: the user clicked the box, so only Esc / click-out / ✕ close it; stuck: the user dragged it, so only ✕
    var screenFrames = NSScreen.screens.map(\.frame)   // last display layout; a change in it makes an on-screen drawing stale
    var selection: TextSelection?, replacement: String?, mode = "replace", warmSel = ""   // mode: replace · delete · draft
    var selectionID = 0, selectionPending = false, replacing = false
    var mine = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""   // the app the user's in, never Aurel itself
    var userApp = NSWorkspace.shared.frontmostApplication, guardUntil = Date.distantPast, allowUntil = Date.distantPast, userSwitch = Date.distantPast
    var allowUserApp = false
    var hiddenAtStart = Set<pid_t>()   // re-activating the user's app does not cover an app that unhid itself (an empty desktop shows it)
    func noteHidden() { hiddenAtStart = Set(NSWorkspace.shared.runningApplications.filter(\.isHidden).map(\.processIdentifier)) }
    let focusFile = (Prefs.path as NSString).deletingLastPathComponent + "/focus"   // aurel.py touches it when the user asked to see an app
    var focusFree: Bool { (try? FileManager.default.attributesOfItem(atPath: focusFile)[.modificationDate] as? Date).map { Date().timeIntervalSince($0) < 60 } ?? false }
    static func focusGuardActive(busy: Bool, recording: Bool, now: Date, until: Date, focusFree: Bool, workInFront: Bool = false) -> Bool {
        !workInFront && (busy || recording || now < until) && !focusFree
    }
    // An app raised for a hands click is not the user's app; recording it made the guard pull that app (an agent's Amazon tab) back forward.
    static func isUserApp(now: Date, allowUntil: Date, userSwitch: Date, allowUserApp: Bool = false) -> Bool {
        now > allowUntil || allowUserApp || now.timeIntervalSince(userSwitch) <= 0.6
    }
    let recent = (Prefs.path as NSString).deletingLastPathComponent + "/recent.jsonl"
    // ⌘-Tab, a Space swipe and Spotlight never reach a global event monitor, so the guard took them for an app jumping forward and pulled
    // the user back. Hardware ⌘/⌥ releases, clicks and gestures in the last second mean the user switched; plain typing does not.
    // Letting go of Aurel's own ⌃⌥ shortcut is a modifier change too, so one within 0.6 s of that release is not a switch.
    static var keysUp = Date.distantPast
    static func userJustSwitched() -> Bool {
        let ours = Date().timeIntervalSince(keysUp)
        return ([CGEventType.flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown] + [29, 20].compactMap { CGEventType(rawValue: $0) }).contains {
            let ago = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0)
            return ago < 1 && !($0 == .flagsChanged && ago >= ours - 0.6 && ago <= ours + 0.1)
        }
    }
    func frame(_ requested: NSRect, on target: NSScreen? = nil, animate: Bool = false) {   // keep the close button and composer reachable on every display
        let screen = target ?? NSScreen.screens.max { a, b in
            let x = a.visibleFrame.intersection(requested), y = b.visibleFrame.intersection(requested)
            return x.width * x.height < y.width * y.height
        } ?? NSScreen.main
        guard let screen else { return }
        let bounds = screen.visibleFrame.insetBy(dx: 8, dy: 8)
        var f = requested
        // A temporary screen clamp is not a resize: restore the preferred width when space returns.
        if !pillOn && !dragging {
            let w = boxWidth(Prefs.num("boxW"), screen.visibleFrame)
            if Prefs.str("corner") == "top-right" { f.origin.x = f.maxX - w }
            f.size.width = w
        }
        f = PanelFrame.clamp(f, bounds)
        (animate ? panel.animator() : panel).setFrame(f, display: true); panel.invalidateShadow()
        js("limit", bounds.height)
    }
    // Which edges the point is on (window coordinates): 6 px edges, 14 px corners.
    func edges(_ p: NSPoint) -> (l: Bool, r: Bool, t: Bool, b: Bool)? {
        guard panel.frame.width >= 340 else { return nil }   // the dictation pill keeps its size; dragging it only moves it
        let w = panel.frame.width, h = panel.frame.height, c: CGFloat = 14
        let l = p.x < 6 || (p.x < c && (p.y < c || p.y > h - c)), r = p.x > w - 6 || (p.x > w - c && (p.y < c || p.y > h - c))
        let b = p.y < 6 || (p.y < c && (p.x < c || p.x > w - c)), t = p.y > h - 6 || (p.y > h - c && (p.x < c || p.x > w - c))
        return l || r || t || b ? (l, r, t, b) : nil
    }
    func overX(_ p: NSPoint) -> Bool { !pillOn && p.x > panel.frame.width - 42 && p.y > panel.frame.height - 42 }   // the pill has no ✕ corner: its own buttons sit there
    // Words the recognizer should expect: the user's app names plus a few of the user's own (free, on-device).
    var hints: [String] {
        let config = (Prefs.path as NSString).deletingLastPathComponent
        let shortcuts = (try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: config + "/skills.json")))) as? [String: Any] ?? [:]
        var seen = Set<String>()
        return Array((DictationData.words + ["Aurel", profileName(config + "/me.json")] + shortcuts.keys.sorted() +
        [NSHomeDirectory() + "/Applications", "/Applications", "/System/Applications", "/System/Applications/Utilities"].flatMap {
            ((try? FileManager.default.contentsOfDirectory(atPath: $0)) ?? []).filter { $0.hasSuffix(".app") }.map { String($0.dropLast(4)) }
        }).filter { !$0.isEmpty && seen.insert($0).inserted }.prefix(DictationData.words.count + 100))
    }
    var cueSound: NSSound?, cueEnds = Date.distantPast
    func sound(_ name: String, _ v: Float) {
        let s = NSSound(named: name); s?.volume = v
        if s?.play() == true { cueSound = s; cueEnds = max(cueEnds, Date().addingTimeInterval((s?.duration ?? 0) + 0.3)) }
    }
    func followUpSoon() {   // hands-free: listen again right when the done sound ends, not on the next 1 s tick
        guard followUp else { return }
        DispatchQueue.main.async { [weak self] in self?.listenAgain() }   // at once, over the done sound: the next words start right away
    }
    // The next instruction: the mic opens here, not through the wake listener's waits (a focused Ask field, its own setting).
    func listenAgain() {
        guard handsFree, followUp, !busy, !engine.isRunning, !dictating, !Prefs.bool("paused") else { return }
        if voice?.isRunning == true || drawing.voice?.isRunning == true {   // an answer still being spoken
            return DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.listenAgain() }
        }
        followUp = false; stopWake(); clickMicrophone(quiet: true)
    }
    // The heard words still start with what Aurel acted on, maybe split differently ("Open" again as "O Pen"):
    // how many words that is now, or nil when the words changed.
    func actedWords() -> Int? {
        let key = { (s: String) in transcriptKey(s).filter { $0.isLetter || $0.isNumber } }, want = key(consumedText), w = words()
        return (0...w.count).first { key(w.prefix($0).joined(separator: " ")) == want }
    }
    func cue(_ k: String) { let n = Prefs.str(k); if n != "None" { sound(n, Float(Prefs.num("volume"))) } }   // soundStart / soundRelease / soundDone / soundStop
    let drawing = ScreenDrawing()
    var drawingReply = false
    var pointContext: [String:Any]?
    var voice: Process?   // `say`, with a validated installed voice
    func voiceQualityTip() {
        guard !UserDefaults.standard.bool(forKey: "voiceQualityTip") else { return }
        UserDefaults.standard.set(true, forKey: "voiceQualityTip")
        show(); js("notice", "Voice sounds robotic? This Mac has no natural voice yet. Get one: System Settings → Accessibility → Read & Speak → System voice → Manage Voices → download an Enhanced or Premium voice, then pick it as the System voice."); hide(after: 14)
    }
    @discardableResult func shush() -> Bool {
        guard let v = voice else { return false }; voice = nil
        guard v.isRunning else { return false }; v.terminate(); return true
    }
    func deliver(_ a: String, aloud: Bool = true) {   // Settings: read answers aloud, copy them
        if Prefs.bool("autoCopy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(a, forType: .string) }
        if Prefs.bool("speak") && aloud {
            stopWake()
            let arguments = readAloudArguments(spoken(a)) { voiceQualityTip() }
            shush(); let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/say"); p.arguments = arguments
            p.terminationHandler = { [weak self] _ in DispatchQueue.main.async {
                guard let self, self.voice === p else { return }; self.voice = nil; self.cueEnds = max(self.cueEnds, Date().addingTimeInterval(0.3)); self.hide(after: 2)
            } }
            try? p.run(); voice = p
        }
    }
    func linger(_ s: Double) -> Double { s * (["short": 0.5, "long": 2][Prefs.str("linger")] ?? 1) }
    func clearPointContext() {
        if let path = pointContext?["image"] as? String { try? FileManager.default.removeItem(atPath:path) }
        pointContext = nil; drawing.deselect(); js("point", false)
    }
    // While a drawing is up, the box glides to the nearest spot clear of its marks, and back home when it goes.
    var boxHome: NSPoint?   // where the box was before a drawing moved it; nil once the user drags it
    func avoidDrawing() {
        guard panel.isVisible, !dragging else { return }
        guard drawing.active else {
            DispatchQueue.main.async { [self] in   // a replaced drawing clears, then draws again at once
                guard !drawing.active else { return }
                if let home = boxHome { boxHome = nil; var f = panel.frame; f.origin = home; glide(f) }
                hide(after: 3)
            }
            return
        }
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        let marks = drawing.occupied.map { CGRect(x:$0.minX,y:top-$0.maxY,width:$0.width,height:$0.height) }
        guard let spot = ScreenDrawing.clearSpot(panel.frame, avoiding:marks, in:NSScreen.screens.map(\.visibleFrame)), spot != panel.frame.origin else { return }
        if boxHome == nil { boxHome = panel.frame.origin }
        var f = panel.frame; f.origin = spot; glide(f)
    }
    func glide(_ f: NSRect, done: (() -> Void)? = nil) {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { frame(f); done?(); return }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.3; $0.timingFunction = CAMediaTimingFunction(name:.easeInEaseOut); panel.animator().setFrame(f, display:true) },
                                             completionHandler: { [weak self] in guard let self else { return }; if !dragging { frame(panel.frame) }; done?() })   // keeps it on a display and updates its height limit
    }
    func followPointerScreen() {   // the box, typing box, answer and dictation pill alike
        guard panel.isVisible, !dragging, !hovering, let f = pointerFollow(panel.frame) else { return }
        boxHome = nil; frame(f)
    }
    func startFollowingPointerScreen() {
        guard followTimer == nil else { return }
        followTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.followPointerScreen() }
    }
    func pointElement(_ point: CGPoint) -> String {
        guard AXIsProcessTrusted(), let app = userApp, !app.isTerminated else { return "" }
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateApplication(app.processIdentifier),Float(point.x),Float(point.y),&element) == .success,
              let element else { return "" }
        let role = Hands.attribute(element,kAXRoleAttribute) as? String ?? "element"
        let label = Hands.mask(Hands.name(element))
        return String("\(app.localizedName ?? "App") \(role)\(label.isEmpty ? "" : ": " + label)".prefix(500))
    }
    // mark: one of Aurel's own marks the user clicked (points are its corners); the same context as a mark the user drew.
    func finishPoint(_ points: [CGPoint], mark: String = "") {
        guard let first = points.first else { drawing.clearInput(); return }
        let screen = NSScreen.screens.first {
            let id = $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? CGMainDisplayID()
            return CGDisplayBounds(id).contains(first)
        }
        guard let screen else { drawing.clearInput(); return }
        let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? CGMainDisplayID()
        let display = CGDisplayBounds(id), xs = points.map(\.x), ys = points.map(\.y)
        var region = CGRect(x:xs.min()!,y:ys.min()!,width:max(1,xs.max()!-xs.min()!),height:max(1,ys.max()!-ys.min()!)).insetBy(dx:-24,dy:-24)
        region = region.intersection(display)
        let path = NSTemporaryDirectory() + "aurel-point-" + UUID().uuidString + ".jpg"
        let capture = Process(); capture.executableURL = URL(fileURLWithPath:"/usr/sbin/screencapture")
        capture.arguments = ["-x","-R\(Int(region.minX)),\(Int(region.minY)),\(max(1,Int(region.width))),\(max(1,Int(region.height)))","-t","jpg",path]
        let capturing = (try? capture.run()) != nil
        if capturing { capture.waitUntilExit() }
        var context: [String:Any] = [
            "bounds":[Double(region.minX),Double(region.minY),Double(region.width),Double(region.height)],
            "path":points.map { [Double($0.x),Double($0.y)] },
            "element":pointElement(CGPoint(x:region.midX,y:region.midY))
        ]
        if !mark.isEmpty { context["mark"] = String(mark.prefix(1000)) }
        if capturing && capture.terminationStatus == 0 && FileManager.default.fileExists(atPath:path) { context["image"] = path }
        if context["image"] == nil && mark.isEmpty && (context["element"] as? String)?.isEmpty != false {
            drawing.clearInput(); js("notice","Couldn’t capture that mark."); return
        }
        if let old = pointContext?["image"] as? String { try? FileManager.default.removeItem(atPath:old) }   // a redrawn mark replaces the last crop
        pointContext = context
        if !mark.isEmpty { pinned = true; show() }
        js("point", ["active":drawing.inputMode,"marked":true,"picked":!mark.isEmpty,"thumb":(context["image"] as? String).map(pointThumb) ?? ""])
    }
    func pointThumb(_ path: String) -> String {   // the box's chip and the sent bubble's picture: a data URL, since the page can't read temporary files
        guard let image = NSImage(contentsOfFile:path), image.size.width > 0, image.size.height > 0 else { return "" }
        let scale = min(1, 480 / image.size.width, 300 / image.size.height)
        let small = NSImage(size:NSSize(width:image.size.width * scale,height:image.size.height * scale),flipped:false) { image.draw(in:$0); return true }
        guard let tiff = small.tiffRepresentation, let jpg = NSBitmapImageRep(data:tiff)?.representation(using:.jpeg,properties:[.compressionFactor:0.7]) else { return "" }
        return "data:image/jpeg;base64," + jpg.base64EncodedString()
    }
    func startPointing() {
        guard panel.isVisible else { return }
        guard !busy, !engine.isRunning else { js("notice","Finish or stop listening first."); return }
        drawing.beginInput { [weak self] points in self?.finishPoint(points) }
        pinned = true; js("point", ["active":true,"marked":false])
    }
    func finishPointing() {
        drawing.finishInput()
        if pointContext != nil { js("point", ["active":false,"marked":true]) }
    }

    override init() {
        let model = BoxModel(); boxModel = model
        boxView = NSHostingView(rootView: BoxView(m: model))
        boxView.frame = NSRect(x: 0, y: 0, width: boxWidth(Prefs.num("boxW"), mouseScreen.visibleFrame), height: 76)
        boxView.sizingOptions = []   // the panel sizes itself from what the box reports
        super.init()
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.5)   // main-thread AX polls (mini screen, drawings, dictation learning): a hung app costs 0.5 s, not 6 s
        drawing.resolve = { label, state in try Hands.drawAnchor(label,state:state) }
        drawing.cleanup = Hands.restoreAccessibility
        drawing.status = { [weak self] words in self?.js("msg",words) }
        drawing.speechEnabled = { Prefs.bool("speak") }
        drawing.sayArguments = { [weak self] words in self?.stopWake(); return readAloudArguments(words) { self?.voiceQualityTip() } }
        drawing.autoSteps = { Prefs.str("guideSteps") != "next" }
        drawing.inputCleared = { [weak self] in self?.clearPointContext() }
        drawing.inputAway = { [weak self] in self?.finishPointing() }
        drawing.picked = { [weak self] r, words in self?.finishPoint([CGPoint(x:r.minX,y:r.minY),CGPoint(x:r.maxX,y:r.maxY)],mark:words) }
        drawing.changed = { [weak self] in self?.avoidDrawing() }
        boxModel.post = { [weak self] in self?.handle($0) }
        boxModel.onSize = { [weak self] in self?.size($0) }
        boxModel.onMini = { [weak self] in self?.mini.layout($0) }
        boxView.autoresizingMask = [.width, .height]
        let bg = NSVisualEffectView(frame: boxView.frame)
        bg.material = .hudWindow; bg.state = .active; bg.wantsLayer = true; bg.autoresizingMask = [.width, .height]
        bg.appearance = NSAppearance(named: .darkAqua)   // stays dark over white pages, so the orb shows
        bg.layer?.cornerRadius = 18; bg.layer?.masksToBounds = true
        bg.maskImage = NSImage(size: NSSize(width: 37, height: 37), flipped: false) { NSColor.black.setFill(); NSBezierPath(roundedRect: $0, xRadius: 18, yRadius: 18).fill(); return true }
        bg.maskImage?.capInsets = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18); bg.maskImage?.resizingMode = .stretch
        let tint = NSView(frame:boxView.frame); tint.wantsLayer = true; tint.autoresizingMask = [.width,.height]
        tint.layer?.backgroundColor = NSColor(calibratedRed:18/255,green:18/255,blue:20/255,alpha:0.85).cgColor   // light enough for the blur to show; over white it keeps small text AA (tests/test_box_native.py)
        bg.addSubview(tint); bg.addSubview(mini.clip)
        mini.publish = { [weak self] value in self?.js("mini",value) }
        mini.captureAllowed = { agentsUI.mini.target == nil }
        bg.addSubview(boxView)
        let tracker = Tracker(frame: boxView.frame)
        tracker.autoresizingMask = [.width, .height]
        tracker.onMove = { [weak self] p in
            guard let self else { return }
            if !hovering { js("hover", true) }
            hovering = true
            pointer(CGPoint(x: p.x, y: boxView.frame.height - p.y), overX: overX(p) && edges(p) == nil)   // the × is native's corner, wider than its dot
        }
        tracker.onExit = { [weak self] in
            guard let self else { return }
            hovering = false; js("hover", false); pointer(nil, overX: false)
            if !busy { hide(after: 3) }   // mouse gone for a few seconds = close
        }
        bg.addSubview(tracker)
        panel.acceptsMouseMovedEvents = true
        panel.contentView = bg
        panel.level = .statusBar; panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        applySharing(panel)
        DispatchQueue.main.async { [weak self] in self?.handle(["ready": 1]) }   // the native box is ready at once
        // Click anywhere else closes the box once the answer is up; on the box: ✕ closes, elsewhere copies the answer.
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, !handsFree, panel.isVisible, !busy, !engine.isRunning, !stuck, !drawing.active, !drawing.hasInput else { return }
            close(clear: false)
        }
        var grab: (mouse: NSPoint, origin: NSPoint)?, moved = false
        var sizing: (mouse: NSPoint, frame: NSRect, e: (l: Bool, r: Bool, t: Bool, b: Bool))?   // dragging an edge or corner
        NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] e in
            guard let self else { return e }
            switch e.type {
            case .leftMouseDown:
                guard e.window == panel else { return e }
                let p = e.locationInWindow
                if let ed = edges(p), !(overX(p) && !ed.r && !ed.t) { sizing = (NSEvent.mouseLocation, panel.frame, ed); fromTop = ed.t; pinned = true; dragging = true }
                else if overX(p) { close(clear: true) }
                else if p.y < compH { if !panel.isKeyWindow && replacement == nil { selection = TextSelection.capture() }; pinned = true; panel.makeKey(); panel.makeFirstResponder(boxView); return e }   // the typing box: a normal click; a waiting Insert/Replace keeps its target
                else { if !pillOn { pinned = true }; grab = (NSEvent.mouseLocation, panel.frame.origin); moved = false; dragging = true }   // the pill is not a box to keep
            case .leftMouseDragged:
                if let z = sizing {   // width from the side edges, height from the top/bottom; a corner does both
                    let m = NSEvent.mouseLocation, dx = m.x - z.mouse.x, dy = m.y - z.mouse.y
                    let w = min(900, max(340, z.frame.width + (z.e.r ? dx : z.e.l ? -dx : 0)))
                    var f = panel.frame; f.size.width = w; f.origin.x = z.e.l ? z.frame.maxX - w : z.frame.minX; frame(f)
                    Prefs.d["boxW"] = w
                    if z.e.t || z.e.b { js("hold", min(1000, max(120, z.frame.height + (z.e.b ? -dy : dy)))) }   // the page sets the height
                    return nil
                }
                guard let g = grab else { return e }
                let m = NSEvent.mouseLocation
                if abs(m.x - g.mouse.x) + abs(m.y - g.mouse.y) > 3 { moved = true; if !pillOn { stuck = true }; boxHome = nil }   // the user placed it: a drawing never moves it back
                var f = panel.frame; f.origin = NSPoint(x: g.origin.x + m.x - g.mouse.x, y: g.origin.y + m.y - g.mouse.y); frame(f)
            default:
                dragging = false
                if sizing != nil { sizing = nil; js("resizeDone"); DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.fromTop = false }; Prefs.set("boxH", Prefs.num("boxH")); return nil }   // saves both
                guard grab != nil else { return e }
                grab = nil
                if !moved {   // a click, not a drag: the page decides (answer = copy, anywhere else = type)
                    panel.makeKey(); panel.makeFirstResponder(boxView)
                    js("tap", [e.locationInWindow.x, panel.frame.height - e.locationInWindow.y])
                }
            }
            return nil
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            guard let self else { return }
            composing = false   // the page may not get a blur; the box must still be able to fade
            if !hovering && !busy { hide(after: 3) }
        }
        // Focus guard: while a task runs (and 2 s after it), an app that comes forward by itself (Spotify on play, open -a, a launch)
        // goes straight back behind the user's app. Not when the user asked to see it, switched apps themselves, or a menu press raises it.
        // Agents need no guard: their input is delivered in the background and their launches go behind (keep_behind).
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let self, let a = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication, a != .current else { return }
            let now = Date()
            let workInFront = Prefs.str("workIn") == "front"
            if Self.focusGuardActive(busy:busy, recording:engine.isRunning, now:now, until:guardUntil, focusFree:focusFree, workInFront:workInFront),
               now > allowUntil, now.timeIntervalSince(userSwitch) > 0.6, !Self.userJustSwitched(),
               let u = userApp, !u.isTerminated, u != a { MiniScreen.activate(u.processIdentifier); if hiddenAtStart.contains(a.processIdentifier) { a.hide() }; return }
            if Self.isUserApp(now:now, allowUntil:allowUntil, userSwitch:userSwitch, allowUserApp:allowUserApp || workInFront) { mine = a.localizedName ?? ""; userApp = a }
        }
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] e in
            if e.type != .keyDown || e.modifierFlags.contains(.command) { self?.userSwitch = Date() }   // a click or ⌘-Tab: the user is choosing
        }
        DistributedNotificationCenter.default().addObserver(forName: .init("aurel.raise"), object: nil, queue: .main) { [weak self] n in
            self?.allowUntil = Date().addingTimeInterval(3)   // hands raise an app for a mouse click, then put the user's app back
            self?.allowUserApp = n.object as? String == "user"   // a voice focus request changes the user's app; a temporary hands raise does not
        }
        SFSpeechRecognizer.requestAuthorization { _ in }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            let frames = NSScreen.screens.map(\.frame), moved = frames != screenFrames   // Dock/menu-bar changes also post this; only real display changes stale a drawing
            screenFrames = frames
            let hadDrawing = moved && (drawing.active || drawing.hasInput)
            let wasDictating = dictating, interrupted = hadDrawing && (engine.isRunning || dictating || busy)
            if interrupted { hush() }
            if hadDrawing { drawing.clear() }
            frame(panel.frame, on: panel.screen ?? mouseScreen)
            if interrupted {
                let message = "The screen changed. Ask again to continue."
                if wasDictating { js("dictated", ["text": message, "ok": false]) } else { js("stopped", message) }
                hide(after: 3)
            } else if hadDrawing { js("notice", "The screen changed. Ask again to continue.") }
        }
        prepareSpeech()
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
    }

    // What the box asks for: copy, send, allow, a pick… (the page's "c" messages)
    func handle(_ b: [String: Any]) {
        do {
            if b["learnedUndo"] != nil, let word = learnedWord {
                if DictationData.forget(word) {
                    learnedWord = nil; js("dictated", ["text": "Forgot that spelling", "ok": true]); hide(after: 2)
                    Aurel.settings.send("dictation", DictationData.state())
                }
            }
            if b["dictationHistory"] != nil { hide(after: 0); Aurel.settings.open(tab: "dictation") }
            if let enabled = b["agentDefault"] as? Bool { defaultKey(enabled) }
            if let value = b["miniRect"] as? [String:Any] { mini.layout(value) }
            // a click on the mini screen = the user wants to see it: the focus guard stands aside
            if b["miniOpen"] != nil { allowUntil = Date().addingTimeInterval(3); allowUserApp = true; userSwitch = Date(); mini.open(); if !busy { mini.reset(); hide(after:3) } }
            if b["miniClear"] != nil { mini.reset() }
            if let h = b["comp"] as? NSNumber { compH = CGFloat(h.doubleValue) }
            if let h = b["boxH"] as? NSNumber { Prefs.d["boxH"] = h.doubleValue }   // saved when the drag ends
            if let f = b["focus"] as? Bool {
                composing = f
                if !f && !hovering && !busy { hide(after: 3) }
            }
            if b["type"] != nil {   // typing wins; a pending failure card keeps its worker
                if engine.isRunning { if retryOffer { stopOfferInput() } else { hush() } }
                else if busy && proc == nil && offerText == nil && !dictating && text.isEmpty { hush(); js("msg", "") }   // released, nothing heard, still finalizing
            }
            if let s = b["link"] as? String, let url = URL(string: s), ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") {   // a link in an answer: the user's browser
                allowUntil = Date().addingTimeInterval(3); allowUserApp = true; NSWorkspace.shared.open(url)
            }
            if let a = b["copy"] as? String, !a.isEmpty {
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(a, forType: .string); js("copied")
            }
            if ["agentOpen","agentLater","agentConnect"].contains(where:{ b[$0] != nil }) { agentCard = ""; defaultKey(false) }
            if b["agentGone"] != nil { agentCard = ""; escape() }   // the card left another way: Esc does its usual job
            if let id = b["agentOpen"] as? String {
                if let target = b["target"] as? String { agentsUI.open(id,target:target) }
                else { agentsUI.openView(id) }   // the done card's Return action opens the report; its artifact buttons open artifacts
                agentsUI.dismissPing(id)
            }
            if let id = b["agentLater"] as? String { agentsUI.dismissPing(id) }
            if let id = b["agentConnect"] as? String { NSWorkspace.shared.open(URL(string:"https://claude.ai/settings/connectors")!); agentsUI.dismissPing(id) }
            if b["agents"] != nil { agentsUI.openView() }
            if b["setup"] != nil { onboarding.open() }
            if b["workerRetry"] != nil, !busy { pinned = false; typed(text, keep: true) }
            if b["resume"] != nil {
                Aurel.settings.apply("paused", false); Aurel.settings.push()
                if !Prefs.bool("paused") { js("paused", false); hide(after: 1.5) }
            }
            if b["replace"] != nil, !busy { applyReplacement() }
            if b["retry"] != nil, !busy, !engine.isRunning { typed(text, keep: true) }
            if let t = b["send"] as? String { typed(t, keep: true) }
            if b["point"] != nil { drawing.inputMode ? finishPointing() : startPointing() }
            if b["pointClear"] != nil { if drawing.hasInput { drawing.clearInput() } else { clearPointContext() } }   // a drawn mark, or a selected one of Aurel's
            if b["pointCoached"] != nil { Prefs.set("pointCoached", true) }
            if b["mic"] != nil && (!busy || retryOffer) && (!engine.isRunning || quietFollowUp) { if quietFollowUp { hush() }; clickMicrophone() }
            if b["ready"] != nil { js("size", Prefs.num("boxH")); if Prefs.bool("tips") && !Prefs.bool("pointCoached") { js("pointCoach") } }
            if b["safe"] != nil { Prefs.set("safe", true); js("mode", true); Aurel.settings.push() }
            if let m = b["model"] as? String {   // picked in the box: the same setting Settings shows; a worker warmed on the old model goes
                Aurel.settings.apply("routing", m); Aurel.settings.push()
            }
            if let i = b["pick"] as? String, !askFile.isEmpty {
                if retryOffer {
                    stopOfferInput(); retryOffer = false
                }
                try? i.write(toFile: askFile, atomically: true, encoding: .utf8); askFile = ""
            }   // an index, or "" = none; failure cards also use r/n
            if let k = b["off"] as? String, k == "tips" { Aurel.settings.apply(k, false); Aurel.settings.push() }   // a tip's own "Turn off"; never safe mode
            if let v = b["improve"] as? Bool { Aurel.settings.apply("improve", v); Aurel.settings.push() }
            if let item = b["memory"] as? [String: Any] { Aurel.settings.reveal(item) }   // a receipt's item: Settings → Memory, at that item
            if let ok = b["allow"] as? Bool, !askFile.isEmpty { allow(ok) }
        }
    }
    // The box reports its height (and the dictation pill its width); grow the box down from the top-left corner.
    func size(_ size: [CGFloat]) {
        guard let h = size.last, h > 0 else { return }
        var f = panel.frame
        if !fromTop { f.origin.y = f.maxY - h }   // grows down from the top, unless the user is dragging the top edge
        f.size.height = h
        let pillWidth = size.count == 2 && pillOn ? size[0] : nil   // a late one from before pill(false) must not shrink the box
        if let w = pillWidth, w > 0 { if Prefs.str("corner") == "top-right" { f.origin.x = f.maxX - w }; f.size.width = w }
        guard f != panel.frame else { return }
        if pillWidth != nil && panel.isVisible && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {   // the pill morphs between its states
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.22; $0.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut); frame(f, animate: true) },
                                                 completionHandler: { [self] in panel.invalidateShadow() })
        } else { frame(f) }
        if drawing.active && !stuck && !dragging { avoidDrawing() }   // grew onto a mark; a box the user placed waits for the next step
    }

    func js(_ call: String, _ arg: Any? = nil) { boxModel.receive(call, arg ?? NSNull()) }
    var pointerHand = false
    func pointer(_ p: CGPoint?, overX: Bool) {   // Aurel never activates, so the box tracks the mouse itself: hover states, and whether the cursor is a hand
        let hand = boxModel.pointer(p, overX: overX)
        if hand != pointerHand { pointerHand = hand; (hand ? NSCursor.pointingHand : NSCursor.arrow).set() }
    }

    func modelChoices() -> [String: Any] {
        if Prefs.str("client") != "claude" { return ["list": [], "pick": ""] }
        return ["list": ["cheapest", "balanced", "capable"], "pick": Prefs.str("routing")]
    }
    func show() {
        gen += 1; js("visible", true); js("mode", Prefs.bool("safe")); js("models", modelChoices())
        startFollowingPointerScreen()
        if panel.isVisible {   // still up: stay where the user dragged it
            NSAnimationContext.runAnimationGroup { $0.duration = 0.18; panel.animator().alphaValue = 1 }
            return
        }
        defer { if drawing.active { avoidDrawing() } }
        let screen = mouseScreen, vf = screen.visibleFrame   // open where the user is looking: the cursor's screen
        var f = panel.frame
        if !pillOn { f.size.width = boxWidth(Prefs.num("boxW"), vf) }
        f.origin = NSPoint(x: Prefs.str("corner") == "top-right" ? vf.maxX - f.width - 14 : vf.minX + 14, y: vf.maxY - f.height - 10)
        frame(f, on: screen)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        if escRef == nil {
            RegisterEventHotKey(UInt32(kVK_Escape), 0, EventHotKeyID(signature: 0x41545443, id: 2), GetApplicationEventTarget(), 0, &escRef)
        }
        NSAnimationContext.runAnimationGroup { $0.duration = 0.18; panel.animator().alphaValue = 1 }
    }

    func hide(after s: Double) {
        let g = gen
        DispatchQueue.main.asyncAfter(deadline: .now() + s) { [self] in
            guard g == gen, !handsFree, !busy, !engine.isRunning, !hovering else { return }
            guard !pinned, !stuck, !composing, !mini.holds, !drawing.active, !drawing.hasInput, ringGone == nil, voice?.isRunning != true else {   // moved or drawn on: only ✕ (Esc for a drawing); an answer's ring keeps its text up
                if pillOn && !dictating { pill(false) }   // the box stays up for its answer or drawing: give it back, not a pill stuck on its check
                return
            }
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.3; panel.animator().alphaValue = 0 },
                                                 completionHandler: { [self] in if g == gen { gone() } })
        }
    }

    func defaultKey(_ enabled: Bool) {
        defaultWanted = enabled
        if defaultObservers.isEmpty {
            for name in [NSWindow.didBecomeKeyNotification,NSWindow.didResignKeyNotification] {
                defaultObservers.append(NotificationCenter.default.addObserver(forName:name,object:nil,queue:.main) { [weak self] _ in DispatchQueue.main.async { self?.refreshDefaultKeys() } })
            }
        }
        refreshDefaultKeys()
    }
    func refreshDefaultKeys() {
        defaultKeys.forEach { UnregisterEventHotKey($0) }; defaultKeys = []
        guard defaultWanted, panel.isVisible, NSApp.keyWindow == nil || NSApp.keyWindow === panel else { return }
        for (code,id) in [(kVK_Return,3),(kVK_ANSI_KeypadEnter,4)] {
            var ref: EventHotKeyRef?
            if RegisterEventHotKey(UInt32(code),0,EventHotKeyID(signature:0x41545443,id:UInt32(id)),GetApplicationEventTarget(),0,&ref) == noErr, let ref { defaultKeys.append(ref) }
        }
    }
    func defaultAction() {
        guard panel.isVisible, !defaultKeys.isEmpty else { return }
        defaultKey(false); js("agentDefaultAction")
    }
    // ⌃⌥↩ moves the running ask to an agent from any app; held only while there is one to move
    func moveKey() {
        if let r = moveRef { UnregisterEventHotKey(r); moveRef = nil }
        guard !agentMoveFile.isEmpty else { return }
        RegisterEventHotKey(UInt32(kVK_Return), UInt32(controlKey | optionKey), EventHotKeyID(signature: 0x41545443, id: 5), GetApplicationEventTarget(), 0, &moveRef)
    }
    func moveToAgent() {   // a card waiting for the user goes with the ask: the agent asks again itself
        guard busy, !agentMoveFile.isEmpty else { return }
        do { try "go".write(toFile:agentMoveFile,atomically:true,encoding:.utf8); agentMoveFile = ""; askFile = ""; retryOffer = false; js("movePending") }
        catch { js("moveFailed") }
    }
    func gone() {
        defaultKey(false)
        mini.reset()
        followTimer?.invalidate(); followTimer = nil
        panel.orderOut(nil); agentCard = ""; pinned = false; stuck = false; boxHome = nil; composing = false; js("compose", false); js("visible", false)
        if hovering { hovering = false; js("hover", false); pointer(nil, overX: false) }   // a hidden panel gets no mouseExited
        pill(false)
        if let r = escRef { UnregisterEventHotKey(r); escRef = nil }
    }
    var pillOn = false
    func pill(_ on: Bool) {   // dictation is a pill the page sizes (a hidden one starts as the dot it grows from); the box gets its saved width back
        pillOn = on; js("dictate", on)
        guard !on || !panel.isVisible else { return }
        let w = on ? 36 : boxWidth(Prefs.num("boxW"), (panel.isVisible ? panel.screen : nil)?.visibleFrame ?? mouseScreen.visibleFrame)
        var f = panel.frame; guard f.width != w || on && f.height != w else { return }
        if Prefs.str("corner") == "top-right" { f.origin.x = f.maxX - w }
        if on { f.origin.y = f.maxY - w; f.size.height = w }
        f.size.width = w; frame(f)
    }

    func allow(_ ok: Bool) {
        let path = askFile, need = askNeed["need"] as? String ?? "", app = askNeed["app"] as? String ?? ""
        if ok && need == "page-js" { Prefs.set("pageJS", true) }
        guard ok, !need.isEmpty, need != "page-js" else {
            try? (ok ? "y" : "n").write(toFile:path, atomically:true, encoding:.utf8); askFile = ""; return
        }
        onboarding.allow(need, app:app)
        var tries = 0
        Timer.scheduledTimer(withTimeInterval:1, repeats:true) { [weak self] t in
            tries += 1
            guard let self, self.askFile == path, tries < 900 else { t.invalidate(); return }
            DispatchQueue.global().async {
                if Onboarding.granted(need, app:app) { DispatchQueue.main.async {
                    guard self.askFile == path else { return }
                    try? "y".write(toFile:path, atomically:true, encoding:.utf8); self.askFile = ""; t.invalidate()
                } }
            }
        }
    }

    // Esc: stop listening, stop the answer, or close the box.
    // One layer per press: the user's mark, voice, listening, a card, the answer, then the drawing, then the box.
    func escape() {
        if handsFree { close(clear: false); return }
        if drawing.hasInput { drawing.clearInput(); return }
        if shush() { return }
        if dictating { return cancel() }
        if engine.isRunning && picking { stopOfferInput(); cue("soundStop") }
        else if engine.isRunning {
            hush(); cue("soundStop"); js("stopped", "Stopped listening"); hide(after: 1.5)
        } else if !agentCard.isEmpty, panel.isVisible {
            js("agentEscape")
        } else if busy {
            cancel()
        } else if drawing.active {
            drawing.clear()
        } else if panel.isVisible {
            close(clear: false)
        }
    }

    func hush() { hush(keepReply: false) }
    func hush(keepReply: Bool, keepWarm: Bool = false) {   // stop listening, drop what was heard, say nothing; a drawing stays until Esc, its ✕ or close
        if !keepReply { drawingReply = false }
        mini.reset()
        engine.stop(); speechInputs?.finishAll(); reading?.cancel(); nextReading?.cancel(); pause?.cancel()
        if !keepWarm { unwarm() }
        quietAudio.end()
        if quietFollowUp { js("quietListen", false) }
        quietFollowUp = false; clickTalk = false; toggleTalk = false; quiet?.cancel(); stops += 1   // stops: a late "words landed" from this listen does nothing
        listenID += 1; selectionID += 1; selectionPending = false; replacing = false
        dictating = false; dictateID += 1; dictateSelectionPending = false; dictateSelection = nil
        stopDictationCleanup()
        cancelFast()
        aheadItem?.cancel(); dropAhead()
        if picking { js("pickHear") }
        proc?.terminate(); proc = nil; askFile = ""; agentMoveFile = ""; replacement = nil; retryOffer = false
        if let old = offerText { text = old }; offerText = nil
        let an = analyzer, next = nextAnalyzer
        nextFeed = nil; nextAnalyzer = nil; nextReading = nil; nextSpeechInputID = nil; nextSpeechSegment = 0
        Task { await an?.cancelAndFinishNow(); await next?.cancelAndFinishNow() }
        busy = false   // an early start dropped above never reports back (its exit handler sees proc changed)
    }

    func stopOfferInput() {
        engine.stop()
        unwarm()
        quietAudio.end()
        speechInputs?.finishAll(); reading?.cancel(); nextReading?.cancel(); quiet?.cancel(); clickTalk = false; toggleTalk = false; listenID += 1; stops += 1
        if let old = offerText { text = old }; offerText = nil
        if picking { js("pickHear") }
        let an = analyzer, next = nextAnalyzer
        nextFeed = nil; nextAnalyzer = nil; nextReading = nil; nextSpeechInputID = nil; nextSpeechSegment = 0
        Task { await an?.cancelAndFinishNow(); await next?.cancelAndFinishNow() }
    }

    func dismiss() {   // the shortcut again before anything happened: say so, then go
        if engine.isRunning && picking { return stopOfferInput() }
        if engine.isRunning { hush() }
        cue("soundStop"); js("stopped", "Answer stopped")
        let g = gen; DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in if g == gen { close(clear: false) } }
    }

    func cancel() {
        if dictating { cue("soundStop"); return close(clear: false) }   // listening or finishing: fade out, nothing inserted
        hush(); shush()
        cue("soundStop"); js("stopped", "Answer stopped"); hide(after: 1.5)
    }

    // ✕ also ends the conversation; clicking away or timing out keeps it for 5 minutes.
    func close(clear: Bool) {
        handsFree = false; followUp = false; stopWake()
        let pending = clear || replacement == nil ? nil : (replacement, selection)
        shush(); hush(); drawing.clear(); unpoint()   // gone means quiet: no mic, no voice, no answer, no drawing or ring
        if let pending { replacement = pending.0; selection = pending.1 }   // a hidden Insert/Replace keeps its validated target
        if clear { try? FileManager.default.removeItem(atPath: recent); lastDone = .distantPast }
        gen += 1
        let g = gen
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.2; panel.animator().alphaValue = 0 },
                                             completionHandler: { [self] in if g == gen { gone() } })
    }

    func shortcut(_ pressed: Bool) {
        if !pressed {
            shortcutDown = false; Self.keysUp = Date()
            guard engine.isRunning && !toggleTalk && !clickTalk else { return }
            // a tap: nobody spoke in 0.3 s, so stop now instead of waiting on the recognizer to report nothing
            if text.isEmpty && offerText == nil && Date().timeIntervalSince(began) < 0.3 { hush(); js("msg", ""); return hide(after: 0.2) }
            stop()
            return
        }
        guard !shortcutDown else { return }   // one action per physical press, including key repeat
        shortcutDown = true
        followUp = false
        guard !Prefs.bool("paused") else {
            if Date().timeIntervalSince(pausedNotice) > 4 { pausedNotice = Date(); js("paused"); show(); hide(after: 4) }
            return
        }
        if shush() { return }
        if quietFollowUp { hush() }
        if engine.isRunning { return toggleTalk ? stop() : dismiss() }
        if busy && !retryOffer && !drawing.active { return cancel() }
        start()
    }

    func prepareForInactiveSession() {
        stopWake(); followUp = false
        shortcutDown = false; dictateShortcutDown = false
        dictateTap?.cancel(); dictateTap = nil
        let transient = engine.isRunning || dictating || drawing.active || drawing.hasInput
        if engine.isRunning || dictating { hush() }
        if drawing.active || drawing.hasInput { drawing.clear() }
        quietAudio.end(immediate: true)
        if transient { gone() }
    }

    // Hold to talk, release to insert. A quick tap waits a moment: a second tap locks it on until the next press (toggleTalk).
    func dictateShortcut(_ pressed: Bool) {
        if !pressed {
            dictateShortcutDown = false; Self.keysUp = Date()
            guard engine.isRunning, dictating, !toggleTalk, dictateTap == nil else { return }
            if Date().timeIntervalSince(dictatePressed) > 0.3 { return stop() }
            let id = listenID, tap = DispatchWorkItem { [weak self] in
                guard let self else { return }
                dictateTap = nil; if listenID == id { stop() }
            }
            dictateTap = tap; DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: tap)
            return
        }
        guard !dictateShortcutDown else { return }
        dictateShortcutDown = true
        handsFree = false; followUp = false
        if quietFollowUp { hush() }
        guard !Prefs.bool("paused") else { return }
        if let tap = dictateTap {
            tap.cancel(); dictateTap = nil
            if engine.isRunning && dictating { toggleTalk = true; js("locked", true); return }
        }
        if engine.isRunning { if dictating { if toggleTalk { stop() } else { dismiss() } }; return }
        if busy { if dictating { cancel() }; return }
        dictatePressed = Date()
        startDictation()
    }
    // A modifier-only dictation shortcut held for another key (fn+Delete, fn+←): that key's own shortcut, so a press
    // that has heard nothing yet goes away quietly. Once words are heard it stays dictation.
    func dictateChord() -> Bool {
        guard dictateShortcutDown, dictating, !toggleTalk, text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        dictateShortcutDown = false; dictateTap?.cancel(); dictateTap = nil
        close(clear: false); return true
    }

    func review(_ message: String) {
        hush(); js("msg", message)
        pinned = true; panel.makeKey(); panel.makeFirstResponder(boxView); js("draft", text)
    }

    func recordingLimit() {
        if let old = offerText { let partial = text; stopOfferInput(); text = old; if !picking { js("draft", partial) }; return }
        if toggleTalk { review("Recording paused after 60 seconds. Review your words and press Return to send.") }
        else { stop() }
    }

    func captureSelection() {
        selectionID += 1; let id = selectionID
        selection = nil; selectionPending = Prefs.bool("selection")
        guard selectionPending else { return }
        let front = NSWorkspace.shared.frontmostApplication
        DispatchQueue.global().async { [weak self] in
            let selected = TextSelection.capture(front, enabled: true)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.selectionID == id else { return }
                self.selectionPending = false; self.selection = Prefs.bool("selection") ? selected : nil
                if !self.quietFollowUp, let selection = self.selection { self.js("selected", selection.text) }
                if self.warm != nil && self.warmSel != self.selKey { self.unwarm(); self.warm = self.spawn() }
            }
        }
    }

    var selKey: String { Prefs.bool("selection") ? selection.map { $0.caret ? "\u{1}" : $0.text } ?? "" : "" }   // \u{1}: no highlight, the cursor sits in a text box

    func captureDictationSelection(retry: Bool = false) {
        if !retry {
            dictateSeconds = 0
            dictationTargetApp = NSWorkspace.shared.frontmostApplication
            dictationAppName = dictationTargetApp?.localizedName ?? "App"
            dictateID += 1; dictateSelection = nil; dictateBefore = ""; dictateSelectionRetried = false
        }
        let id = dictateID, front = dictationTargetApp, cleanup = dictateCleanup
        dictateSelectionPending = true
        DispatchQueue.global().async { [weak self] in
            var secureField = false
            let selected = TextSelection.capture(front, enabled: true, allowEmpty: true, keyboardFallback: !retry, onSecure: { secureField = true })   // the retry only counts a real text box
            // Clean up reads the text before the cursor for names and terms.
            let before = selected.flatMap { s -> String? in
                guard cleanup, let value = s.value as NSString?, let r = s.range, r.location >= 0, r.location <= value.length else { return nil }
                return String(value.substring(to: r.location).suffix(600))
            } ?? ""
            DispatchQueue.main.async { [weak self] in
                guard let self, dictating, dictateID == id, !retry || dictateSelectionPending else { return }   // a retry that ran out of time already moved on
                if secureField {
                    hush(); js("dictated", ["text": "Dictation is off in secure fields", "ok": false]); hide(after: 3); return
                }
                dictateSelectionPending = false
                guard let selected else {   // no text field: the words still go to History ("Nothing selected to insert")
                    if AXIsProcessTrusted() {
                        if retry { finishDictation() }
                        return
                    }
                    hush(); js("dictated", ["text": "Allow Accessibility in System Settings → Privacy & Security → Accessibility", "ok": false]); hide(after: 6); return
                }
                dictateSelection = selected
                dictateBefore = before
                if retry { finishDictation() }
            }
        }
    }

    func start() { start(dictate: false) }
    func startDictation() { start(dictate: true) }
    func beginSpeechSegment(_ base: String, listeningID: Int) -> (feed: AsyncStream<AnalyzerInput>.Continuation, inputID: UUID, analyzer: SpeechAnalyzer, reading: Task<Void, Never>, segment: Int) {
        let tr = speechModule(dictate: dictating)
        let (stream, cont) = AsyncStream<AnalyzerInput>.makeStream()
        let an = SpeechAnalyzer(modules: [tr])
        speechSegment += 1; let segment = speechSegment
        speechText[segment] = (base, "", "")
        let inputID = speechInputs!.add(cont)
        let ctx = AnalysisContext(); ctx.contextualStrings[.general] = hints
        Task { try? await an.setContext(ctx); try? await an.start(inputSequence: stream) }
        let rd = Task { [weak self] in
            do {
                if let d = tr as? DictationTranscriber {
                    for try await r in d.results {
                        await MainActor.run { self?.speechPiece(String(r.text.characters), final: r.isFinal, segment: segment, listeningID: listeningID) }
                    }
                } else if let t = tr as? SpeechTranscriber {
                    for try await r in t.results {
                        await MainActor.run { self?.speechPiece(String(r.text.characters), final: r.isFinal, segment: segment, listeningID: listeningID) }
                    }
                }
            } catch {
                await MainActor.run {
                    if self?.listenID == listeningID && (self?.activeSpeechSegment == segment || self?.nextSpeechSegment == segment) { self?.speechFailed = true }
                }
            }
        }
        return (cont, inputID, an, rd, segment)
    }

    func speechPiece(_ piece: String, final: Bool, segment: Int, listeningID: Int) {
        guard self.listenID == listeningID, var part = speechText[segment] else { return }
        if final { part.done += piece; part.live = "" } else { part.live = piece }
        speechText[segment] = part
        if activeSpeechSegment == segment { heard(stitchTranscript(part.base, part.done + part.live)) }
        if final && dictating { typeLive() }
    }

    func rolloverSpeech(listeningID: Int) {
        guard dictating, engine.isRunning, nextAnalyzer == nil, self.listenID == listeningID else { return }
        let next = beginSpeechSegment(text, listeningID: listeningID)
        nextFeed = next.feed; nextSpeechInputID = next.inputID; nextAnalyzer = next.analyzer
        nextReading = next.reading; nextSpeechSegment = next.segment
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self, self.listenID == listeningID, engine.isRunning,
                  let nextFeed, let nextSpeechInputID, let nextAnalyzer, let nextReading else { return }
            let oldAnalyzer = analyzer, oldReading = reading, oldSegment = activeSpeechSegment
            if let oldID = speechInputID { speechInputs?.finish(oldID) }
            if var part = speechText[nextSpeechSegment] { part.base = text; speechText[nextSpeechSegment] = part }
            feed = nextFeed; speechInputID = nextSpeechInputID; analyzer = nextAnalyzer; reading = nextReading
            activeSpeechSegment = nextSpeechSegment
            self.nextFeed = nil; self.nextSpeechInputID = nil; self.nextAnalyzer = nil; self.nextReading = nil; self.nextSpeechSegment = 0
            if let part = speechText[activeSpeechSegment] { heard(stitchTranscript(part.base, part.done + part.live)) }
            Task {
                try? await oldAnalyzer?.finalizeAndFinishThroughEndOfInput()
                await oldReading?.value
                await MainActor.run { self.speechText.removeValue(forKey: oldSegment) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { Task { await oldAnalyzer?.cancelAndFinishNow() } }
        }
    }

    func beginParakeetSegment(_ base: String) {
        speechSegment += 1; activeSpeechSegment = speechSegment; speechText[speechSegment] = (base, "", ""); parakeetSent = 0
    }
    // Every 0.15 s while Parakeet listens: close a long segment on a pause, else re-transcribe it for live words about three
    // times a second (a pass takes ~0.1 s; sooner once the voice stops, so commands and the early AI start see the whole phrase).
    func parakeetTick(_ listeningID: Int) {
        guard !parakeetBusy else { return }
        let secs = parakeetAudio.seconds, quiet = Date().timeIntervalSince(parakeetVoice)
        let pauseCut = dictating && dictateLive && secs >= 1.5 && quiet >= 0.7 && !(speechText[activeSpeechSegment]?.live.isEmpty ?? true)
        if secs >= 30 || secs >= 25 && quiet >= 0.4 || pauseCut {
            return parakeetFinal(listeningID) { [weak self] _ in
                guard let self, engine.isRunning else { return }
                parakeetBusy = false; beginParakeetSegment(text)
            }
        }
        guard secs - parakeetSent >= 0.25, Date().timeIntervalSince(parakeetAsked) >= 0.3 || quiet >= 0.3 && parakeetVoice > parakeetAsked else { return }
        let pcm = parakeetAudio.snapshot(), segment = activeSpeechSegment
        parakeetAsk += 1; let ask = parakeetAsk; parakeetBusy = true; parakeetAsked = Date(); parakeetSent = Double(pcm.count) / 16000
        Task { [weak self] in
            let r = try? await Parakeet.shared.transcribe(pcm)   // a failed live pass only skips a beat
            await MainActor.run {
                guard let self, self.parakeetAsk == ask else { return }   // a final pass or a new listen took over
                self.parakeetBusy = false
                if let r { self.speechPiece(r, final: false, segment: segment, listeningID: listeningID) }
            }
        }
    }
    // The rest of the segment's audio, transcribed for good; passes run one after another so text stays in order.
    func parakeetFinal(_ listeningID: Int, then: @escaping (Bool) -> Void) {
        let pcm = parakeetAudio.take(), segment = activeSpeechSegment, prev = parakeetChain, secs = Double(pcm.count) / 16000
        parakeetAsk += 1; parakeetBusy = true; parakeetQueued += secs
        parakeetChain = Task { [weak self] in
            await prev?.value
            let r = try? await Parakeet.shared.transcribe(pcm)
            await MainActor.run {
                guard let self, self.listenID == listeningID else { return }   // cancelled, hushed or timed out meanwhile
                self.parakeetQueued -= secs
                if let r { self.speechPiece((self.speechText[segment]?.done.isEmpty ?? true) || r.isEmpty ? r : " " + r, final: true, segment: segment, listeningID: listeningID) }
                else { self.speechFailed = true }
                then(r != nil)
            }
        }
    }

    func start(dictate: Bool, quiet: Bool = false) {
        handsFreeIdle += 1
        stopWake()
        if dictate && !AXIsProcessTrusted() {
            pill(true); show()
            js("dictated", ["text": "Allow Accessibility in System Settings → Privacy & Security → Accessibility", "ok": false])
            hide(after: 6); return
        }
        drawingReply = !dictate && drawing.active
        let replying = drawingReply || retryOffer && !askFile.isEmpty
        replyAgent = dictate || (retryOffer && !askFile.isEmpty) ? "" : agentCard
        if !replying { if !dictate && !drawing.hasInput { drawing.clear() }; mini.reset(); try? FileManager.default.removeItem(atPath: focusFile) }   // a new ask: "show it" from the last one no longer counts
        guard !Prefs.bool("paused") else { dictating = false; return }
        dictating = dictate
        unpoint(false)   // a new ask replaces the held answer; do not schedule that old answer's delayed hide
        shush()
        if drawingReply { hush(keepReply: true); drawing.hold() }
        dictating = dictate   // hush invalidates the previous listen before this one starts
        if engine.isRunning { return dismiss() }   // the shortcut stops click-to-talk
        if busy && !replying {   // pressed again while it works = cancel
            return cancel()
        }
        cancelFast(); noteHidden()
        if dictate {
            dictateCleanup = Prefs.str("dictateMode") == "cleanup"
            dictateFellBack = false; dictateTimedOut = false; liveTyped = ""; liveTyping = false
            captureDictationSelection(); replacement = nil
            if dictateCleanup { warmDictationCleanup() }
        } else if replying { offerText = text } else { captureSelection(); replacement = nil }
        if !dictate && !drawingReply { targetScreen = currentRequestScreen(panel) }   // a guide may have moved the box to another display
        text = ""; ahead = ""; speechFailed = false; consumed = 0; consumedText = ""; liveRevised = false; did = []
        if !panel.isVisible && Date().timeIntervalSince(lastDone) > 300 { js("reset"); try? FileManager.default.removeItem(atPath: recent) }
        quietFollowUp = quiet
        if !dictate { handsFree = true }   // a spoken ask is a conversation: after each answer it listens again until "close", ✕, Esc or quiet
        if !quiet { pill(dictate) }
        if !dictate {
            if !replying && Prefs.str("input") == "type" && !clickTalk {   // Settings: the shortcut opens the box ready to type
                if composing && panel.isVisible { return dismiss() }   // pressed again = put it away
                unwarm(); warm = spawn()
                onboarding.tried(); show()
                panel.makeKey(); panel.makeFirstResponder(boxView); js("compose", true)
                return
            }
        }
        toggleTalk = !clickTalk && !dictate && Prefs.str("talkMode") == "toggle"   // dictation locks with a double tap instead
        if !quiet { cue("soundStart") }
        if !dictate && (!replying || drawingReply) { unwarm(); warm = spawn() }
        if !quiet {
            hovering = false
            if dictate { js("listen", "dict") }
            else if replying && !drawingReply { js(picking ? "pickHear" : "draft", "") } else { js("listen"); if let s = selection { js("selected", s.text) } }   // talking about a drawing still shows the listening orb
            show()
        }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            if replying { stopOfferInput() } else { hush() }; js("msg", "Allow Aurel in System Settings → Privacy & Security → Microphone."); hide(after: 6); return
        }
        let parakeet = Prefs.str("speechModel") == "parakeet"   // runs on this Mac outside Apple's speech service: no Speech Recognition permission
        guard !parakeet || Parakeet.shared.ready else {
            if replying { stopOfferInput() } else { hush() }; js("msg", "Parakeet isn’t set up yet. Open Settings → Dictation to download a model."); hide(after: 6)
            Aurel.settings.open(tab: "dictation"); return
        }
        guard parakeet || dictate || SFSpeechRecognizer.authorizationStatus() == .authorized else {
            if replying { stopOfferInput() } else { hush() }; js("msg", "Allow Aurel in System Settings → Privacy & Security → Speech Recognition."); hide(after: 6); return
        }
        guard let device = listenMic().flatMap({ AVCaptureDevice(uniqueID: $0.uid) }) ?? AVCaptureDevice.default(for: .audio) else {
            if replying { stopOfferInput() } else { hush() }; js("msg", "No microphone is available. Connect one and try again."); hide(after: 6); return
        }
        if !quiet && !dictate && !replying && onboarding.win == nil && Prefs.bool("tips") && !Prefs.bool("pointCoached") { Prefs.set("pointCoached", true); js("pointCoach", true) }   // the first ask after setup (mic and speech allowed): one look at the Point button
        onboarding.tried()
        if !quiet { quietAudio.begin(Prefs.bool("quietAudio"), level: Float32(Prefs.num("quietLevel"))) }
        listenID += 1; let listeningID = listenID; began = Date()   // key-down until the mic is ready; a release in that gap is a tap
        speechInputs = SpeechInputs(); speechText = [:]; speechSegment = 0; nextSpeechRollover = 50
        parakeetListen = parakeet; parakeetBusy = false; parakeetAsk += 1; parakeetQueued = 0; parakeetVoice = .distantPast; parakeetAudio.reset()
        if parakeet {
            feed = nil; speechInputID = nil; analyzer = nil; reading = nil
            Parakeet.shared.warm()
            beginParakeetSegment("")
        } else {
            let first = beginSpeechSegment("", listeningID: listeningID)
            feed = first.feed; speechInputID = first.inputID; analyzer = first.analyzer; reading = first.reading; activeSpeechSegment = first.segment
        }
        let want = parakeet ? AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)! : speechFormat ?? AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let pcm = parakeetAudio   // Parakeet takes raw samples: AnalyzerInput traps on a plain 16 kHz Float32 buffer
        var conv: AVAudioConverter?, convFrom: AVAudioFormat?
        var n = 0
        let onBuffer: (AVAudioPCMBuffer) -> Void = { [weak self] buf in
            if buf.format != want, convFrom != buf.format { conv = AVAudioConverter(from: buf.format, to: want); convFrom = buf.format }
            if buf.format != want, let conv, let out = AVAudioPCMBuffer(pcmFormat: want, frameCapacity: AVAudioFrameCount(Double(buf.frameLength) * want.sampleRate / buf.format.sampleRate) + 1) {
                var given = false
                conv.convert(to: out, error: nil) { _, status in
                    if given { status.pointee = .noDataNow; return nil }
                    given = true; status.pointee = .haveData; return buf
                }
                if parakeet { pcm.append(out) } else { self?.speechInputs?.yield(AnalyzerInput(buffer: out)) }
            } else {
                if parakeet { pcm.append(buf) } else { self?.speechInputs?.yield(AnalyzerInput(buffer: buf)) }
            }
            n += 1
            guard n % 2 == 0, let ch = buf.floatChannelData?[0], buf.frameLength > 0 else { return }
            var sum: Float = 0
            for i in 0..<Int(buf.frameLength) { sum += ch[i] * ch[i] }
            let v = Double(min(1, sqrt(sum / Float(buf.frameLength)) * 14))
            DispatchQueue.main.async { if self?.listenID == listeningID, self?.engine.isRunning == true { if self?.quietFollowUp == false { self?.js("level", v) }; if parakeet && v > 0.1 { self?.parakeetVoiced() } } }
        }
        engine.start(device, sampleRate: want.sampleRate, onBuffer) { [weak self] result in
            guard let self, listenID == listeningID else { return }
            if case .failure(let error) = result { telemetry(["error", "native", "mic_start"]); if replying { stopOfferInput() } else { hush() }; js("msg", "Mic error: \(error.localizedDescription)"); hide(after: 3); return }
            began = Date()   // measure the limit from when the mic is ready
            if quietFollowUp { js("quietListen", true) }   // only now: words said before the mic opened would be lost
            Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] t in
                guard let self, listenID == listeningID, engine.isRunning else { return t.invalidate() }
                let f = (dictating ? dictateHotkey() : hotkey()).flags, held = Date().timeIntervalSince(began)
                // nothing said: stop the mic quietly; a hands-free chat keeps listening until "close", ✕, Esc or 2 min of quiet
                if clickTalk && text.isEmpty && held > (quietFollowUp ? 120 : 8) { t.invalidate(); if quietFollowUp { hush(); fadeIdleHandsFree(); return }; if offerText != nil { stopOfferInput(); return }; hush(); js("stopped", ""); return hide(after: 3) }
                if parakeet && clickTalk && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && parakeetDone(Self.endPause) { t.invalidate(); return stop() }   // heard() is too late for the end pause
                if parakeet { parakeetTick(listeningID) }
                else if dictating && held >= nextSpeechRollover { nextSpeechRollover += 50; rolloverSpeech(listeningID: listeningID) }
                if !dictating && held > 60 { t.invalidate(); recordingLimit(); return }
                if !toggleTalk && !clickTalk && !f.isEmpty && !NSEvent.modifierFlags.isSuperset(of: f) { if dictating { dictateShortcut(false) } else { t.invalidate(); stop() } }
            }
        }
    }

    func heard(_ now: String) {
        guard engine.isRunning || busy else { return }
        if quietFollowUp {
            guard !now.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            quietFollowUp = false
            quietAudio.begin(Prefs.bool("quietAudio"), level: Float32(Prefs.num("quietLevel")))
            js("listen"); if let s = selection { js("selected", s.text) }; show()
        }
        if now != text { wordsChanged = Date() }
        text = now
        if dictating { scheduleDictateAhead(); return }   // cleanup starts on a pause; the pill still shows only the wave
        if offerText != nil {
            js(drawingReply ? "words" : picking ? "pickHear" : "draft", now)
            if clickTalk && !parakeetListen { quiet?.cancel(); let q = DispatchWorkItem { [weak self] in self?.stop() }; quiet = q; DispatchQueue.main.asyncAfter(deadline: .now() + Self.endPause, execute: q) }
            return   // card replies never enter live commands or early AI thinking
        }
        js("words", text)
        let wait = pauseWait()   // nil: Parakeet still hears a voice
        if consumed > 0 { if let n = actedWords() { consumed = n } else { liveRevised = true } }
        if Prefs.bool("live") {   // instant commands (open, move, search, play) run mid-sentence; the AI still waits for confirmed words
            pause?.cancel()   // only after a pause: "search amazon" mid-word is the start of "search amazon for e-bikes"
            let item = DispatchWorkItem { [weak self] in self?.tryFast() }
            pause = item
            if let wait { DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: item) }
        }
        if clickTalk && !parakeetListen {   // no keys to let go of: the end pause ends it (Parakeet: the listen timer, on the audio)
            quiet?.cancel(); let q = DispatchWorkItem { [weak self] in self?.stop() }; quiet = q
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.endPause, execute: q)
        }
        if !ahead.isEmpty && transcriptKey(rest()) != transcriptKey(ahead) { dropAhead() }   // the user kept talking: that start was for half a sentence
        aheadItem?.cancel()   // a longer pause = the user is probably done: start the AI now, keys still held
        guard Prefs.bool("ahead"), let wait else { return }
        let go = DispatchWorkItem { [weak self] in self?.startAhead() }
        aheadItem = go
        DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: go)
    }
    // Parakeet's live words trail the voice by a beat: wait out only what is left of the pause, and none while still talking.
    func pauseWait() -> Double? {
        guard parakeetListen else { return Prefs.num("aheadDelay") }
        let quiet = Date().timeIntervalSince(parakeetVoice)
        return quiet < 0.3 ? nil : max(0.05, Prefs.num("aheadDelay") - quiet)
    }
    func parakeetVoiced() { parakeetVoice = Date(); pause?.cancel(); aheadItem?.cancel(); dictateAheadItem?.cancel() }   // still talking: nothing pause-based fires

    func scheduleDictateAhead() {
        dictateAheadItem?.cancel()
        guard dictateCleanup, engine.isRunning, pauseWait() != nil else { return }
        let go = DispatchWorkItem { [weak self] in
            guard self?.engine.isRunning == true else { return }
            self?.startDictateAhead(early: true)
        }
        dictateAheadItem = go
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: go)
    }

    func words() -> [Substring] { text.split(separator: " ") }
    func rest() -> String { let w = words(); return w.count > consumed ? w[consumed...].joined(separator: " ") : "" }

    func startAhead() {
        if drawing.hasInput || pointContext != nil { return }   // the marked crop belongs to the confirmed request, not a discarded speculative start
        if engine.isRunning && selectionPending {
            let item = DispatchWorkItem { [weak self] in self?.startAhead() }; aheadItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: item); return
        }
        let r = rest()
        guard engine.isRunning, !selectionPending, !fastBusy, !liveRevised, !r.isEmpty, transcriptKey(r) != transcriptKey(ahead) else { return }
        let core = r.lowercased().replacingOccurrences(of: #"^(?:(?:hey|ok|okay|aurel|please|can you|could you|would you|also|and|now|then)[,\s]+)+"#, with: "", options: .regularExpression)
        if ["open", "launch", "start", "pull up", "bring up", "focus", "switch to", "go to", "snap", "move", "put", "throw", "send", "make", "play", "search", "google", "look up"].contains(where: { core.hasPrefix($0 + " ") }) || hints.contains(where: { transcriptKey($0) == transcriptKey(r) }) { return }
        dropAhead()
        ahead = r
        run(r, speculative: true)
        warm = spawn()   // ready again in case the user keeps talking
    }

    // Runs `aurel.py --fast` on the words not yet used; exit 0 means it was a simple command and it is done.
    func cancelFast() { fastProc?.terminate(); fastProc = nil; fastBusy = false }

    func tryFast() {
        let w = words()
        guard Prefs.bool("live"), Prefs.bool("instant"), engine.isRunning, !drawing.hasInput, !fastBusy, !liveRevised, w.count > consumed else { return }
        let seg = w[consumed...].joined(separator: " "), n = w.count, prefix = transcriptKey(w.joined(separator: " "))
        let p = py(["--fast", seg], ["AUREL_FRONT": mine, "AUREL_SCREEN": targetScreen, "AUREL_LIVE": "1", "AUREL_FOCUS_GUARD": "1"]), out = Pipe()
        p.standardOutput = out
        do { try p.run() } catch { return }
        fastProc = p
        fastBusy = true
        DispatchQueue.global().async { [weak self] in
            let line = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            p.waitUntilExit()
            DispatchQueue.main.async { [weak self] in
                guard let self, fastProc === p else { return }
                fastProc = nil; fastBusy = false
                if p.terminationStatus == 0 && line.hasPrefix("✓") {
                    consumed = n; consumedText = prefix
                    if let now = actedWords() { consumed = now } else { liveRevised = true }
                    did.append(String(line.dropFirst(2)))
                    js("line", "▸ " + line.dropFirst(2))
                    if toggleTalk || clickTalk { endWhenQuiet(listenID) }
                }
            }
        }
    }
    // Toggle and hands-free listens have no key to let go of: once an instant command used every word, a second of quiet ends the ask.
    func endWhenQuiet(_ id: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, listenID == id, engine.isRunning, words().count <= consumed else { return }   // more words: the rest is for the AI
            if parakeetListen && !parakeetDone(1) { return endWhenQuiet(id) }   // Parakeet's words trail the voice
            stop()
        }
    }
    // With no key to let go of, this much quiet ends what was said: long enough for a pause to think mid-sentence.
    static let endPause = 2.5
    // A noisy room never reads as silent on the level alone: words that stopped changing for a second past the pause mean the user is done too.
    func parakeetDone(_ pause: Double) -> Bool { Date().timeIntervalSince(parakeetVoice) >= pause || Date().timeIntervalSince(wordsChanged) >= max(2, pause + 1) }

    func dropAhead() {
        if !ahead.isEmpty { proc?.terminate(); proc = nil; ahead = ""; if engine.isRunning { busy = false } }
    }

    func stop() {
        guard engine.isRunning, !clickTalk || text.isEmpty == false else { return }
        let inputs = speechInputs
        if dictating { dictateSeconds = Date().timeIntervalSince(began); dictateReleased = Date(); startDictateAhead() }   // cleanup runs while the last words finalize
        var parakeetFlush: (() -> Void)?   // Parakeet's last pass waits for the mic's last buffer
        engine.stop { inputs?.finishAll(); parakeetFlush?() }
        quietAudio.end()
        clickTalk = false; toggleTalk = false; quiet?.cancel()
        busy = true
        if dictating { cue("soundRelease"); js("finishing", dictateCleanup ? "Cleaning up…" : "") }
        else if offerText == nil { js("think") }   // card replies keep the response clock paused
        let an = analyzer, rd = reading, next = nextAnalyzer
        nextReading?.cancel(); nextFeed = nil; nextAnalyzer = nil; nextReading = nil; nextSpeechInputID = nil; nextSpeechSegment = 0
        Task { await next?.cancelAndFinishNow() }
        stops += 1
        let g = stops
        let once: (Bool) -> Void = { [weak self] confirmed in
            guard let self, g == stops else { return }
            stops += 1; listenID += 1; pause?.cancel()
            if confirmed || dictating && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { dictating ? finishDictation() : finish() }
            else {
                if let old = offerText { let partial = text; text = old; offerText = nil; busy = proc?.isRunning == true; picking ? js("pickHear") : js("draft", partial); return }   // a drawing reply has no worker; a card's keeps waiting
                if dictating { hush(); cue("soundStop"); return hide(after: 0.2) }
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { hush(); js("msg", ""); return hide(after: 0.2) }   // nothing to review
                review("Couldn’t confirm your words. Check them and press Return.")
            }
        }
        if parakeetListen {   // Parakeet: one last pass over the audio no final pass has taken; the wait grows with the audio left
            let id = listenID, wait = min(15, 4 + 0.15 * (parakeetAudio.seconds + parakeetQueued))
            parakeetFlush = { [weak self] in self?.parakeetFinal(id) { ok in once(ok && self?.speechFailed == false) } }
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
                guard let self, g == stops else { return }
                once(false)
            }
            return
        }
        Task {   // let the model finish the last words, then act
            guard let an else { return await MainActor.run { once(false) } }
            do {
                try await an.finalizeAndFinishThroughEndOfInput()
                await rd?.value
                await MainActor.run { once(!speechFailed) }
            } catch { await MainActor.run { once(false) } }
        }
        // Finalizing can hang: offer the partial transcript for review instead of executing it. Dictation shares this wait:
        // a shorter one inserts its volatile words before the final result.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, g == stops else { return }
            rd?.cancel(); Task { await an?.cancelAndFinishNow() }
            once(false)
        }
    }

    // Replace / Delete / Insert: the text goes to the saved selection, or for a draft to the saved cursor.
    func applyReplacement() {
        guard let draft = replacement, !replacing else { return }
        guard Prefs.bool("selection"), let selection, mode != "draft" || selection.caret else { js("replaced", false); return }
        replacing = true; let id = selectionID
        selection.apply(mode == "delete" ? "" : draft, valid: { [weak self] in
            self?.selectionID == id && self?.replacing == true && Prefs.bool("selection") && !Prefs.bool("paused")
        }) { [weak self] ok in
            guard let self, selectionID == id else { return }
            replacing = false
            if ok { replacement = nil; self.selection = nil }
            js("replaced", ok)
        }
    }

    var correctionTimer: Timer?, learnedWord: String?, dictationAppName = "App", dictateSeconds = 0.0, lastDictation: String?
    var dictateFellBack = false, dictateTimedOut = false
    @discardableResult func saveDictation(_ value: String, appName: String) -> Bool {
        let saved = DictationData.record(value, raw: text.trimmingCharacters(in: .whitespacesAndNewlines), app: appName, seconds: dictateSeconds > 0 ? dictateSeconds : Date().timeIntervalSince(began))
        if !saved { js("dictated", ["text": "Your words are ready. Couldn’t save history or stats.", "ok": false]) }
        Aurel.settings.send("dictation", DictationData.state())
        return saved
    }
    // Settings → Dictation → Type as I talk (Verbatim only): at each pause the words no recognizer will revise go in, so text
    // shows while the user keeps talking. Typed words are never changed afterward (deleting inside someone else's app fights
    // the cursor); key-up types only what is left.
    var liveTyped = "", liveTyping = false
    var dictateLive: Bool { Prefs.bool("dictateLive") && !dictateCleanup }
    func finalTranscript() -> String {   // earlier segments and this one's final part
        guard let part = speechText[activeSpeechSegment] else { return "" }
        return stitchTranscript(part.base, part.done).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    func typeLive() {
        guard dictateLive, dictating, !liveTyping, let app = dictationTargetApp, NSWorkspace.shared.frontmostApplication == app else { return }
        let ready = finalTranscript()
        guard ready.count > liveTyped.count, ready.hasPrefix(liveTyped), let target = TextSelection.capture(app, enabled: true) else { return }
        let id = dictateID
        liveTyping = true
        target.apply(fitted(DictationData.fixed(String(ready.dropFirst(liveTyped.count))), into: target), preserveFocus: true, valid: { [weak self] in
            self?.dictateID == id && self?.dictating == true && NSWorkspace.shared.frontmostApplication == app
        }) { [weak self] ok in
            guard let self, dictateID == id else { return }
            liveTyping = false
            guard ok else { return }   // key-up types it with the rest
            liveTyped = ready; typeLive()   // more may have become final meanwhile
        }
    }
    func liveRest(_ heard: String) -> String {   // the words not typed at a pause yet
        let all = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !liveTyped.isEmpty else { return all }
        if all.hasPrefix(liveTyped) { return String(all.dropFirst(liveTyped.count)).trimmingCharacters(in: .whitespacesAndNewlines) }
        return all.split(separator: " ").dropFirst(liveTyped.split(separator: " ").count).joined(separator: " ")   // the end was reworded: go by word count
    }

    // The text on each side of the cursor (or of the words it replaces), for DictationData.fit; none when the app hides it.
    func fitted(_ words: String, into target: TextSelection) -> String {
        guard let whole = target.value as NSString?, let r = target.range, r.location >= 0, r.length >= 0, r.location + r.length <= whole.length else { return words }
        return DictationData.fit(words, before: whole.substring(to: r.location), after: whole.substring(from: r.location + r.length))
    }

    func prepareDictation(_ value: String, target: TextSelection, whole: String? = nil) -> () -> Void {
        let before = axAttribute(target.element, kAXSubroleAttribute) as? String == kAXSecureTextFieldSubrole ? nil : target.value
        let range = target.range, words = whole ?? value.trimmingCharacters(in: .whitespacesAndNewlines)
        return { [weak self] in
            guard let self else { return }
            lastDictation = words
            saveDictation(words, appName: target.app.localizedName ?? "App")
            stopReplay()
            guard Prefs.bool("dictateLearn"), axAttribute(target.element, kAXSubroleAttribute) as? String != kAXSecureTextFieldSubrole else { return }
            let readable = before.flatMap { before -> (String, String)? in
                guard let range, range.location >= 0, range.length >= 0, range.location + range.length <= (before as NSString).length else { return nil }
                let prefix = (before as NSString).substring(to: range.location)
                let suffix = (before as NSString).substring(from: range.location + range.length)
                return target.value == prefix + value + suffix ? (prefix, suffix) : nil
            }
            guard let readable else { NSLog("Dictation learning: field unreadable, watching keys"); return replayEdits(value, app: target.app) }
            NSLog("Dictation learning: watching the field")
            let (prefix, suffix) = readable, deadline = Date().addingTimeInterval(20), id = dictateID
            var last = value, changed = Date()
            correctionTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self] timer in
                guard let self, Date() < deadline, dictateID == id, !engine.isRunning, !busy,
                      Prefs.bool("dictateLearn"), !Prefs.bool("paused"), NSWorkspace.shared.frontmostApplication == target.app,
                      let focused = axAttribute(AXUIElementCreateApplication(target.app.processIdentifier), kAXFocusedUIElementAttribute),
                      CFEqual(focused, target.focus),
                      axAttribute(target.element, kAXSubroleAttribute) as? String != kAXSecureTextFieldSubrole,
                      let current = target.value, current.count <= 100000,
                      current.hasPrefix(prefix), current.hasSuffix(suffix), current.count >= prefix.count + suffix.count else { timer.invalidate(); return }
                let span = String(current.dropFirst(prefix.count).dropLast(suffix.count))
                if span != last { last = span; changed = Date(); return }
                guard Date().timeIntervalSince(changed) > 2, learnFix(value, span) else { return }
                timer.invalidate()
            }
        }
    }
    @discardableResult func learnFix(_ value: String, _ edited: String) -> Bool {
        guard let fix = DictationData.correction(value, edited), !DictationData.words.contains(fix.word) else { return false }
        let word = fix.word
        guard DictationData.word(word) else { return false }
        DictationData.fix(fix.heard, word)
        learnedWord = word; pill(true); show(); js("learned", word); hide(after: 6)
        Aurel.settings.send("dictation", DictationData.state())
        return true
    }
    // No readable field: the next keys in that app, held in memory only, for 20 s; a click, secure input or another app ends it.
    var editKeys: Any?, replayIdle: Timer?
    func replayEdits(_ value: String, app: NSRunningApplication) {
        var replay = DictationData.Replay(value), keys = 0, learned = false
        let id = dictateID
        let check = { [weak self] in
            guard let self, !learned, replay.text != value, learnFix(value, replay.text) else { return }
            learned = true; NSLog("Dictation learning (keys): learned after %d keys", keys); stopReplay()
        }
        // Why learning ended, never the words: app.err, for "nothing was learned".
        let end = { [weak self] (why: String) in
            check()
            if !learned { NSLog("Dictation learning (keys): %@ after %d keys, %@", why, keys, replay.text == value ? "no edit" : "not a spelling fix") }
            self?.stopReplay()
        }
        correctionTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: false) { _ in end("20 s passed") }
        editKeys = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) { [weak self] e in
            guard let self else { return }
            let f = e.modifierFlags
            let why = dictateID != id ? "next dictation" : engine.isRunning || busy ? "Aurel busy" : !Prefs.bool("dictateLearn") || Prefs.bool("paused") ? "off" :
                NSWorkspace.shared.frontmostApplication != app ? "app changed" : IsSecureEventInputEnabled() ? "secure input" : e.type != .keyDown ? "click" : nil
            guard why == nil, replay.key(Int(e.keyCode), e.characters ?? "", option: f.contains(.option), control: f.contains(.control), command: f.contains(.command)) else {
                return end(why ?? "key \(e.keyCode)")   // Return after a fix still learns it
            }
            keys += 1
            replayIdle?.invalidate()
            replayIdle = Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { _ in check() }   // a shorter pause can land mid-word: "Saart"
        }
    }
    func stopReplay() {
        correctionTimer?.invalidate(); replayIdle?.invalidate()
        if let editKeys { NSEvent.removeMonitor(editKeys) }
        editKeys = nil
    }

    // ⌃⌘V, like Willow Voice: the last dictation goes in at the cursor wherever it is now; the user's clipboard comes back after.
    func pasteLastDictation(_ tries: Int = 0) {
        if NSEvent.modifierFlags.contains(.control) && tries < 50 {   // ⌃ still held from the shortcut turns ⌘V into ⌃⌘V in apps that read live modifiers
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in self?.pasteLastDictation(tries + 1) }; return
        }
        guard !Prefs.bool("paused"), !dictating, let value = lastDictation ?? DictationData.archive.history.first?.text, !value.isEmpty,
              let clipboard = try? Hands.lease("clipboard.lock", wait: false) else { NSSound.beep(); return }
        guard let restore = borrowPasteboard(value) else { Hands.unlock(clipboard); NSSound.beep(); return }
        let front = NSWorkspace.shared.frontmostApplication
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: down) else { continue }
            e.flags = .maskCommand
            if NSApp.keyWindow == nil || front == nil || front == .current { e.post(tap: .cghidEventTap) } else { e.postToPid(front!.processIdentifier) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { restore(); Hands.unlock(clipboard) }
    }

    func stopDictationCleanup() {
        stopDictationWorker()
        dictateAheadItem?.cancel(); dictateAheadItem = nil
        dictateRun?.process.terminate(); dictateRun = nil; dictateAheadRuns = 0
    }

    // One transcript handed to a cleanup worker. key is its words only, so final words that match reuse a run started early.
    final class DictationCleanup {
        let key: String, process: Process
        var result: String??, done: ((String?) -> Void)?
        init(_ key: String, _ process: Process) { self.key = key; self.process = process }
        func finish(_ value: String?) { result = .some(value); done?(value) }
        func then(_ f: @escaping (String?) -> Void) { if let result { f(result) } else { done = f } }
    }
    var dictateRun: DictationCleanup?, dictateAheadItem: DispatchWorkItem?, dictateReleased = Date(), dictateAheadRuns = 0
    static func dictationKey(_ s: String) -> String {
        s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
    }
    static func dictationChangedMeaningfully(_ old: String, _ new: String) -> Bool {
        Array(new.split(separator: " ")).difference(from: old.split(separator: " ")).count >= 3
    }

    func stopDictationWorker() {
        try? dictateInput?.close()
        dictateProcess?.terminate()
        dictateProcess = nil; dictateInput = nil; dictateOutput = nil
    }

    // The warm worker takes one transcript; nil when none could start.
    func sendDictationCleanup(_ source: String) -> DictationCleanup? {
        if dictateProcess?.isRunning != true { warmDictationCleanup() }
        guard let p = dictateProcess, let input = dictateInput, let output = dictateOutput else { return nil }
        dictateProcess = nil; dictateInput = nil; dictateOutput = nil
        do {
            try input.write(contentsOf: Data((dictateBefore + "\u{0}" + source).utf8))
            try input.close()
        } catch { p.terminate(); return nil }
        let run = DictationCleanup(Self.dictationKey(source), p)
        DispatchQueue.global().async {
            // The worker closes its output before it stops Claude, so this returns without waiting for the exit.
            let cleaned = String(data: output.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            DispatchQueue.main.async { run.finish(cleaned.isEmpty ? nil : cleaned) }
        }
        return run
    }

    // At most two pause runs; key-up always gets the warm spare, then final speech can use one last run if it changed.
    func startDictateAhead(early: Bool = false) {
        if !early { dictateAheadItem?.cancel(); dictateAheadItem = nil }
        let source = text.trimmingCharacters(in: .whitespacesAndNewlines), key = Self.dictationKey(source)
        guard dictating, dictateCleanup, !dictateSelectionPending, !early || dictateAheadRuns < 2,
              key.split(separator: " ").count >= 3, key != dictateRun?.key else { return }
        if early {
            if let run = dictateRun, run.result == nil && !Self.dictationChangedMeaningfully(run.key, key) { return }
        }
        guard
              let run = sendDictationCleanup(source) else { return }
        dictateRun?.process.terminate()
        dictateRun = run
        dictateAheadRuns += 1
        warmDictationCleanup()   // final speech words may still revise after key-up
    }

    func warmDictationCleanup() {
        stopDictationWorker()
        let p = py(["--dictate-cleanup-wait"]), input = Pipe(), output = Pipe()
        p.standardInput = input; p.standardOutput = output
        fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        do {
            try p.run()
            dictateProcess = p
            dictateInput = input.fileHandleForWriting
            dictateOutput = output.fileHandleForReading
        } catch {
            stopDictationWorker()
        }
    }

    func finishDictation() {
        if dictateSelectionPending {
            let id = dictateID
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                if self?.dictateID == id { self?.finishDictation() }
            }
            return
        }
        if dictateSelection == nil, !dictateSelectionRetried, let app = dictationTargetApp,
           NSWorkspace.shared.frontmostApplication == app {
            dictateSelectionRetried = true
            captureDictationSelection(retry: true)   // lazy AX can miss at key-down; try the same app once more before giving up
            let id = dictateID
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in   // a slow app gets 1 s, then the words go on (History when there is no box)
                guard let self, dictateID == id, dictateSelectionPending else { return }
                dictateSelectionPending = false; finishDictation()
            }
            return
        }
        let spoken = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = spoken
        guard !source.isEmpty else {
            stopDictationCleanup()
            busy = false; dictating = false; cue("soundStop"); hide(after: 0.2)
            return
        }
        if !dictateCleanup { return insertDictation(source) }
        let early = dictateRun?.key == Self.dictationKey(source)
        if !early { dictateRun?.process.terminate(); dictateRun = sendDictationCleanup(source) }
        stopDictationWorker()
        guard let run = dictateRun else { dictateFellBack = true; return insertDictation(source) }   // cleanup could not start: the heard words still go in
        let id = dictateID
        run.then { [weak self] cleaned in
            guard let self, dictateID == id, dictateRun === run else { return }
            dictateRun = nil
            dictateFellBack = cleaned == nil
            NSLog("Dictation cleanup: %.2f s after key-up%@", Date().timeIntervalSince(dictateReleased), early ? " (started early)" : "")
            insertDictation(cleaned ?? source)
        }
        // A cleanup that hangs (offline, Claude retrying) never holds the words: 8 s (a cold worker can take 3-5 s) plus time for long text, then the heard words go in.
        let limit = 8 + Double(source.split(separator: " ").count) / 50
        DispatchQueue.main.asyncAfter(deadline: .now() + limit) { [weak self] in
            guard let self, dictateID == id, dictateRun === run else { return }
            NSLog("Dictation cleanup: no answer in %.1f s, inserting the heard words", limit)
            dictateFellBack = true; dictateTimedOut = true
            dictateRun = nil; run.process.terminate()
            insertDictation(source)
        }
    }

    func recordDictationEvent(_ insert: String) {
        telemetry(["dictation", dictateCleanup ? "cleanup" : "verbatim",
                   String(max(0, Date().timeIntervalSince(dictateReleased))),
                   dictateCleanup && !dictateFellBack ? "1" : "0",
                   dictateFellBack ? "1" : "0", dictateTimedOut ? "1" : "0", insert])
    }

    func dictationDeliveryFailed(_ value: String) {
        let failed = dictateSelection == nil ? "No text field." : "Couldn’t insert."
        recordDictationEvent(dictateSelection == nil ? "no box" : "failed")
        busy = false; dictating = false; dictateSelection = nil; lastDictation = value
        let paste = pasteHotkeyRegistered ? " Press ⌃⌘V to paste it." : ""
        cue("soundStop")
        // Never the clipboard: the user's own copy stays. History keeps the words; with it off (or unsaved) they stay on screen.
        guard Prefs.bool("dictateHistory") && saveDictation(value, appName: dictationAppName) else {
            js("dictated", ["text": failed + (paste.isEmpty ? " Your words are still here." : paste), "ok": false, "words": value]); return
        }
        js("dictated", ["text": failed + (paste.isEmpty ? " Saved to History." : paste), "ok": false, "history": true]); hide(after: 6)
    }

    func insertDictation(_ heard: String) {
        if liveTyping {   // a pause's words are still going in: the rest follows them
            let id = dictateID
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in if self?.dictateID == id { self?.insertDictation(heard) } }
            return
        }
        if !liveTyped.isEmpty, let app = dictationTargetApp { dictateSelection = TextSelection.capture(app, enabled: true) ?? dictateSelection }   // the cursor moved
        guard let target = dictateSelection else {
            dictationDeliveryFailed(DictationData.fixed(heard)); return
        }
        let rest = liveRest(heard)
        let value = rest.isEmpty ? "" : fitted(DictationData.fixed(rest), into: target)
        let id = dictateID, inserted = prepareDictation(value, target: target, whole: liveTyped.isEmpty ? nil : DictationData.fixed(heard))
        if value.isEmpty {   // every word already went in at the pauses
            recordDictationEvent("ok"); liveTyped = ""
            busy = false; dictating = false; dictateSelection = nil
            cue("soundDone"); js("dictated", ["text": "", "ok": true]); hide(after: 0.8); inserted(); return
        }
        target.apply(value, preserveFocus: true, valid: { [weak self] in
            self?.dictateID == id && self?.dictating == true && !Prefs.bool("paused") &&
            NSWorkspace.shared.frontmostApplication == target.app
        }) { [weak self] ok in
            guard let self, dictateID == id else { return }
            if !ok { dictationDeliveryFailed(value); return }
            recordDictationEvent("ok"); liveTyped = ""
            busy = false; dictating = false; dictateSelection = nil
            cue("soundDone"); js("dictated", ["text": "", "ok": true]); hide(after: 0.8); inserted()
        }
    }

    func typed(_ t: String, keep: Bool = false, heard: Bool = false) {   // the typing box (keep: it stays open for the next one; heard: spoken about a drawing, its turn already shows)
        if drawing.active {   // a follow-up keeps the drawing; only a new drawing replaces it
            if transcriptKey(t) == "next" { drawing.next(); return }
            drawing.hold()
            if busy { cancel() }
        }
        if retryOffer && !askFile.isEmpty { js("respond", t); return }
        if quietFollowUp { hush() }
        guard !busy, !engine.isRunning else { return }
        if selectionPending {
            let id = selectionID
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                if self?.selectionID == id { self?.typed(t, keep: keep, heard: heard) }
            }
            return
        }
        if !panel.isKeyWindow { selection = TextSelection.capture() }
        if !Prefs.bool("selection") { selection = nil }
        if !drawing.active { targetScreen = currentRequestScreen(panel) }   // follow-ups stay with the guide, not its relocated box
        text = t; replacement = nil
        if !heard { replyAgent = agentCard }   // a spoken drawing reply keeps the done card captured at key-down
        if !heard { js("listen", keep); if let s = selection { js("selected", s.text) } }; show(); js("words", t); run(t)
    }

    func finish() {
        guard busy else { return }   // cancelled while the last words landed
        if let old = offerText {
            let response = text; text = old; offerText = nil
            if drawingReply {
                drawingReply = false
                if transcriptKey(response) == "next" { unwarm(); drawing.next(); busy = proc?.isRunning == true; return }
                hush(keepReply: false, keepWarm: true); typed(response, heard: true); return
            }
            js("respond", response); return
        }
        if handsFree && Self.endsChat(text) { cue("soundStop"); return close(clear: false) }
        if fastBusy || selectionPending {
            let g = stops
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [self] in if g == stops { finish() } }; return
        }
        aheadItem?.cancel()
        if liveRevised {
            hush(); js("msg", "Your words changed after Aurel acted. Check them, then press Return.")
            pinned = true; panel.makeKey(); panel.makeFirstResponder(boxView); js("draft", text)
            if handsFree { followUp = true; followUpSoon() }   // still a conversation: say it again instead
            return
        }
        let rest = rest()
        if did.isEmpty, !rest.isEmpty && transcriptKey(rest) == transcriptKey(ahead), proc?.isRunning == true {   // already started on exactly this while the user talked
            ahead = ""; unwarm()
            do { try "go".write(toFile: commit, atomically: true, encoding: .utf8) }
            catch { cancel(); js("msg", "Could not confirm the request. Please try again.") }
            return
        }
        dropAhead()
        // the rest keeps the whole sentence: "for e-bikes, open the cheapest" alone lost "on Amazon"
        if !rest.isEmpty { return run(did.isEmpty ? rest : text, remaining: did.isEmpty ? nil : rest) }
        busy = false; guardUntil = Date().addingTimeInterval(2); unwarm()   // nothing left for the AI; an app an instant command started can still jump forward
        if did.isEmpty { js("msg", ""); return hide(after: 0.2) }   // nothing heard: end quietly, no error line
        answer = "✓ " + did.joined(separator: " ")
        followUp = handsFree
        js("line", answer); deliver(did.joined(separator: " ")); lastDone = Date(); cue("soundDone"); followUpSoon(); hide(after: linger(5))
    }

    // aurel.py --wait, started at key-down so Claude is up by the time the user lets go; run() hands it the words.
    func spawn() -> (p: Process, input: FileHandle, commit: String)? {
        let commit = NSTemporaryDirectory() + "aurel-commit-" + UUID().uuidString
        warmSel = selKey
        let p = py(["--wait"], ["AUREL_UI": "1", "AUREL_FRONT": mine, "AUREL_SCREEN": targetScreen, "AUREL_COMMIT": commit, "AUREL_SELECTION": warmSel == "\u{1}" ? "" : warmSel, "AUREL_CARET": warmSel == "\u{1}" ? "1" : "", "AUREL_FOCUS_GUARD": "1"])
        let pipe = Pipe(), inp = Pipe(); p.standardOutput = pipe; p.standardInput = inp
        fcntl(inp.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)   // a worker can exit before we write; let the catch handle EPIPE
        var buffer = Data(), guided = false   // guided: this ask put a guide on screen, whose callouts carry the explanation
        let feed = { [weak self] (d: Data) in
            DispatchQueue.main.async {
                guard let self, self.proc === p else { return }   // buffered output from a cancelled request stays cancelled
                buffer += d
                while let i = buffer.firstIndex(of: 10) {
                    let line = String(decoding: buffer[..<i], as: UTF8.self); buffer.removeSubrange(...i)
                    if line == "! setup" { onboarding.open(automatic: true); continue }   // Claude not installed, signed out or no plan
                    if line == "! improve" { self.js("improve"); continue }   // the one-time "help make Aurel better?" card
                    if line.hasPrefix("▣ "), let value = try? JSONSerialization.jsonObject(with:Data(line.dropFirst(2).utf8)) as? [String:Any] { if Prefs.d["miniScreen"] as? Bool ?? true { self.mini.receive(value) }; continue }
                    if line.hasPrefix("✎ ") {
                        if Prefs.bool("draw"), self.drawing.receive(Data(line.dropFirst(2).utf8)) {
                            self.shush(); guided = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in   // once the box has glided clear of the marks
                                guard let self, panel.isVisible, let m = drawing.focus else { return }
                                let top = NSScreen.screens.first?.frame.maxY ?? 0
                                lead(from: panel.frame, to: CGRect(x: m.minX, y: top - m.maxY, width: m.width, height: m.height))
                            }
                        }
                        else { self.js("line", line) }
                        continue
                    }
                    if line.hasPrefix("@ ") {   // "show me where": an answer's point leads from the box and stays; a click's spot goes to the mini screen if it is up
                        if line.hasSuffix(" answer") { pointAt(line, from: self.panel.isVisible ? self.panel.frame : nil, hold: self.linger(20)) { [weak self] in self?.hide(after: 3) } }
                        else if self.mini.target != nil { self.js("line",line) } else { pointAt(line) }
                        continue
                    }
                    if line.hasPrefix("? ") {   // safe mode: "? <question>\t<command>\t<answer file>"
                        let p = line.dropFirst(2).components(separatedBy: "\t")
                        guard (3...6).contains(p.count) else { continue }
                        self.retryOffer = p.count >= 5 && p[4] == "retry"
                        self.askNeed = p.count == 6 && !self.retryOffer ? (try? JSONSerialization.jsonObject(with:Data(p[5].utf8))) as? [String:Any] ?? [:] : [:]
                        self.askFile = p[2]; self.show(); self.js("ask", [p[0], p[1], self.retryOffer ? "retry" : "", self.retryOffer && p.count == 6 ? p[5] : ""]); continue
                    }
                    if line.hasPrefix("⚙ ") {   // "⚙ <key> <true|false>": the AI flips one of Aurel's switches; never pause, and Safe mode only on
                        let p = line.split(separator: " ").map(String.init)
                        if p.count == 3, Prefs.defaults[p[1]] is Bool, p[1] != "paused", p[1] != "safe" || p[2] == "true" { Aurel.settings.apply(p[1], p[2] == "true"); Aurel.settings.push() }
                        else if p.count == 3, Prefs.d[p[1]] is String, !p[1].hasPrefix("hotkey") { Aurel.settings.apply(p[1], p[2]); Aurel.settings.push() }   // a choice setting ("workIn front")
                        continue
                    }
                    if line.hasPrefix("◇ "), let j = try? JSONSerialization.jsonObject(with: Data(line.dropFirst(2).utf8)) as? [String: Any] {   // "which one?": the choices card
                        self.retryOffer = true; self.askNeed = ["pick": true]; self.askFile = j["a"] as? String ?? ""; self.show(); self.js("pick", j); continue
                    }
                    if line.hasPrefix("▤ ") { self.showAgent = String(line.dropFirst(2)); continue }
                    if line.hasPrefix("⇢ "), let value = try? JSONSerialization.jsonObject(with:Data(line.dropFirst(2).utf8)) as? [String:Any] {   // movable: ⌃⌥↩ moves it / {}: no longer movable
                        self.agentMoveFile = self.busy ? value["a"] as? String ?? "" : ""; continue
                    }
                    if line.hasPrefix("⤴ "), let brief = try? JSONSerialization.jsonObject(with: Data(line.dropFirst(2).utf8)) as? [String: Any] {
                        self.agentMoveFile = ""; self.busy = false; self.js("finished")
                        let r = self.boxModel.rects["orb"]   // where the swim starts
                        agentsUI.prepare(brief, from: r.map { [$0.minX, $0.minY, $0.width, $0.height] })
                        continue
                    }
                    if line.hasPrefix("↺ ") {
                        guard let j = try? JSONSerialization.jsonObject(with: Data(line.dropFirst(2).utf8)) as? [String: Any], let draft = j["t"] as? String else { continue }
                        let now = j["mode"] as? String == "insert"   // the user asked to put it in: no Insert click needed
                        self.replacement = draft; self.mode = now ? "draft" : j["mode"] as? String ?? "replace"; self.pinned = true
                        let target = self.selection.map { ($0.editable || $0.pastable) && (self.mode != "draft" || $0.caret) } ?? false
                        self.js("rewrite", [draft, self.mode, target])
                        if self.mode == "draft" && target && (now || Prefs.str("draftInsert") == "auto") { self.applyReplacement() }
                        continue
                    }
                    if line.hasPrefix("✓") {
                        let result = self.replacement.flatMap { $0.isEmpty ? nil : $0 } ?? line.dropFirst(2).replacingOccurrences(of: "\u{2028}", with: "\n")
                        let finish = self.drawing.request?.steps.count == 1 ? "Done. It’s on your screen." : "Done. Steps are on screen."
                        self.mini.finish(); self.answer = "✓ " + (guided ? finish : result); self.js("line", self.answer)
                        self.deliver(guided ? finish : result, aloud: !guided); continue   // after the line: finding the read-aloud voice must not delay the answer; a guide's steps speak for themselves
                    }
                    if line.hasPrefix("! ") { self.js("msg", String(line.dropFirst(2))) }
                    else { self.js("line", line) }
                }
            }
        }
        pipe.fileHandleForReading.readabilityHandler = { feed($0.availableData) }
        p.terminationHandler = { [weak self] _ in
            pipe.fileHandleForReading.readabilityHandler = nil
            feed(pipe.fileHandleForReading.readDataToEndOfFile())   // the answer may still be in the pipe
            DispatchQueue.main.async {
                try? FileManager.default.removeItem(atPath: commit)
                guard let self, self.proc === p else { return }   // a cancelled run ending late must not touch the next one
                if !self.ahead.isEmpty { self.proc = nil; self.ahead = ""; self.busy = !self.engine.isRunning; return }
                // Exit 70 means Python already reported the crash; a signal is always an unreported process death.
                if p.terminationReason == .uncaughtSignal || (p.terminationStatus != 0 && p.terminationStatus != 70) { telemetry(["error", "worker_exit", "python", String(p.terminationStatus)]) }
                self.busy = false; self.agentMoveFile = ""; self.guardUntil = Date().addingTimeInterval(2); self.proc = nil; self.mini.finish(); self.js("finished")   // Spotify jumps ~0.5 s after play returns
                self.lastDone = Date(); self.followUp = self.handsFree
                if !self.answer.isEmpty { self.cue("soundDone") }
                self.followUpSoon()
                if !self.showAgent.isEmpty { agentsUI.show(self.showAgent); self.showAgent = "" }
                Apps.q.async { Apps.sync() }
                self.hide(after: self.linger(max(6, min(30, Double(self.answer.count) / 12))))   // longer answers stay longer
            }
        }
        do { try p.run() } catch { return nil }
        return (p, inp.fileHandleForWriting, commit)
    }

    func unwarm() { warm?.p.terminate(); warm = nil }

    func run(_ t: String, speculative: Bool = false, remaining: String? = nil) {
        let point = pointContext, drawn = drawing.summary
        pointContext = nil; unpoint(false)
        if point != nil { js("point", false) }   // the mark went with this ask (its picture is in the bubble): the chip must not wait for the next one
        drawing.clearInput(); drawing.deselect(); mini.reset(); if !busy && !engine.isRunning { noteHidden() }; busy = true; agentMoveFile = ""; answer = ""; showAgent = ""; try? FileManager.default.removeItem(atPath: focusFile)
        if !speculative { js("think") }
        if let w = warm, !w.p.isRunning { try? w.input.close(); warm = nil }
        if warm != nil && warmSel != selKey { unwarm() }   // spawned before the selection changed
        guard let w = warm ?? spawn() else {
            if let path = point?["image"] as? String { try? FileManager.default.removeItem(atPath:path) }
            busy = false
            if speculative { ahead = ""; return }
            telemetry(["error", "worker_exit", "python", "-1"])
            pinned = true; js("workerFailed"); show(); return
        }
        warm = nil; proc = w.p; commit = w.commit
        if !speculative {
            do { try "go".write(toFile: commit, atomically: true, encoding: .utf8) }
            catch { cancel(); js("msg", "Could not confirm the request. Please try again."); return }
        }
        do {
            var request: [String:Any] = ["front":mine, "task":t]
            if let remaining { request["remaining"] = remaining; request["done"] = did }
            if let point { request["point"] = point }
            if let drawn { request["drawing"] = drawn }
            if !replyAgent.isEmpty { request["agentCard"] = replyAgent }
            var data = try JSONSerialization.data(withJSONObject:request); data.append(10)
            try w.input.write(contentsOf:data); try w.input.close()
        } catch {
            if let path = point?["image"] as? String { try? FileManager.default.removeItem(atPath:path) }
            cancel(); js("msg", "The request worker stopped. Please try again.")
        }
    }
}

// MARK: - Agent panels
final class ShelfPanel: NSPanel { override var canBecomeKey: Bool { false } }
// WebKit tracks hover only while the app is active, and Aurel never activates for the shelf, so hover reached the page only
// now and then. This view tracks the mouse itself (active always; the owner must be a view) and hands the page page-space points.
final class PointerView: NSView {
    var onPointer: (([Double]) -> Void)?
    override init(frame: NSRect) {
        super.init(frame:frame)
        addTrackingArea(NSTrackingArea(rect:.zero,options:[.mouseMoved,.mouseEnteredAndExited,.activeAlways,.inVisibleRect],owner:self,userInfo:nil))
    }
    required init?(coder: NSCoder) { nil }
    override func mouseMoved(with e: NSEvent) { send(e) }
    override func mouseEntered(with e: NSEvent) { send(e) }
    override func mouseExited(with e: NSEvent) { here() }
    func here() {
        guard let window else { onPointer?([]); return }
        let p = convert(window.convertPoint(fromScreen:NSEvent.mouseLocation),from:nil)
        onPointer?(bounds.contains(p) ? [p.x,bounds.height-p.y] : [])
    }
    func send(_ e: NSEvent) { let p = convert(e.locationInWindow,from:nil); onPointer?([p.x,bounds.height - p.y]) }
}

final class AgentPanels: NSObject {
    var process: Process?, input: FileHandle?, output: Pipe?, buffer = Data(), restarts = 0
    var shelf: ShelfPanel?, view: NSWindow?, viewHost: NSView?
    let shelfModel = ShelfModel()   // the shelf, native
    let model = AgentViewModel()   // the Agent view, native
    let mini = MiniScreen()
    var rows: [String:[String:Any]] = [:] {   // with no agents the tick sleeps; the first row wakes it
        didSet { if !rows.isEmpty, timer == nil { timer = Timer.scheduledTimer(withTimeInterval:0.1, repeats:true) { [weak self] _ in self?.tick() } } }
    }
    var offers: [String:[String:Any]] = [:], named: [[String:Any]] = []
    var moveFrom: [String:[Double]] = [:], flying: [(String,[Double]?)] = []   // hand-offs (by handoffId) still waiting for their offer; accepted ones waiting for the rest of their ask
    var ping: String?, nearSince: Date?   // ping: a done card the user asked for in the box
    var lastBox: NSDictionary?
    var kept = Date.distantPast   // a local agent keeps the local model loaded past its idle unload
    var hovered = "", miniSurface = "", selected = "", drag: (mouse:NSPoint, frame:NSRect)?
    var dismissed = Set(Prefs.d["agentDismissed"] as? [String] ?? []) {   // chips the user ×'d off the screen; their agents keep working in the badge and Agent view
        didSet { if dismissed != oldValue { Prefs.set("agentDismissed", dismissed.filter { rows[$0].map { Self.live.contains($0["status"] as? String ?? "") || Self.lingers($0) } ?? false }.sorted()) } }   // kept over a restart while it could still show
    }
    var monitor: Any?, keyMonitor: Any?, timer: Timer?, moves: [Any] = [], localKeys: Any?
    override init() {
        super.init()
        DispatchQueue.main.async { [weak self] in self?.start() }   // restore accepted work even if the user never opens Agents
        mini.forcePreview = true
        model.post = { [weak self] in self?.handle($0, surface:"view") }
        shelfModel.post = { [weak self] in self?.handle($0, surface:"shelf") }
        shelfModel.receive("prefs", ["dismissed":Array(dismissed),"stack":Prefs.str("agentStack")])
        shelfModel.onMini = { [weak self] rect, fill in
            guard let self, miniSurface == "shelf" else { return }
            mini.layout(["rect":[rect.minX,rect.minY,rect.width,rect.height],"clip":[rect.minX,rect.minY,rect.width,rect.height],"opacity":1,"fill":fill])
        }
        model.onMini = { [weak self] rect, clip in   // the live window of a window agent, laid over its spot in the page
            guard let self, miniSurface == "view" else { return }
            mini.layout(["rect":[rect.minX,rect.minY,rect.width,rect.height],"clip":[clip.minX,clip.minY,clip.width,clip.height],"opacity":1])
        }
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching:.keyDown) { [weak self] e in
            if ![kVK_Return,kVK_ANSI_KeypadEnter].contains(Int(e.keyCode)), !app.defaultKeys.isEmpty { app.defaultKey(false) }   // typing in another app: its Return is the user's again
            if Int(e.keyCode) == kVK_Escape { self?.js("shelf","blur") }   // the shelf never becomes key, so its page never sees Esc
        }
        localKeys = NSEvent.addLocalMonitorForEvents(matching:.keyDown) { [weak self] e in if Int(e.keyCode) == kVK_Escape { self?.js("shelf","blur") }; return e }
        timer = Timer.scheduledTimer(withTimeInterval:0.1, repeats:true) { [weak self] _ in self?.tick() }
        NotificationCenter.default.addObserver(forName:NSApplication.willTerminateNotification, object:nil, queue:.main) { [weak self] _ in
            self?.process?.terminationHandler = nil; self?.process?.terminate(); self?.mini.reset()
        }
        NotificationCenter.default.addObserver(forName:NSApplication.didChangeScreenParametersNotification, object:nil, queue:.main) { [weak self] _ in
            guard let self else { return }
            if let shelf, let screen = shelf.screen ?? NSScreen.main {
                let f = PanelFrame.clamp(shelf.frame,screen.visibleFrame)
                shelf.setFrame(f,display:true)
            }
            if let view, let screen = view.screen ?? NSScreen.main { view.setFrame(PanelFrame.clamp(view.frame,screen.visibleFrame),display:true) }
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching:[.leftMouseDown,.leftMouseDragged,.leftMouseUp]) { [weak self] e in
            if e.type == .leftMouseDown, e.window !== self?.shelf { self?.js("shelf","blur") }   // a click in another Aurel window
            guard let self, let shelf, e.window === shelf else { return e }
            if e.type == .leftMouseDown { drag = (NSEvent.mouseLocation,shelf.frame) }   // a press anywhere on the shelf can move it; past 3 pt it is a drag and its click does nothing
            if e.type == .leftMouseDragged, let origin = drag {
                let point = NSEvent.mouseLocation
                if !shelfModel.dragging, hypot(point.x - origin.mouse.x, point.y - origin.mouse.y) < 3 { return e }
                shelfModel.dragging = true
                var f = origin.frame; f.origin.x += point.x - origin.mouse.x; f.origin.y += point.y - origin.mouse.y
                let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? shelf.screen ?? NSScreen.main!
                shelf.setFrame(PanelFrame.clamp(f,screen.visibleFrame), display:true)
            } else if e.type == .leftMouseUp, drag != nil {
                if shelfModel.dragging { remember(); DispatchQueue.main.async { [weak self] in self?.shelfModel.dragging = false } }   // after this release's click is ignored
                drag = nil
            }
            return e
        }
        mini.publish = { [weak self] value in self?.js(self?.miniSurface ?? "shelf", "mini", value) }
    }
    func js(_ surface:String, _ call:String, _ value:Any = [:]) {
        if surface == "view" { model.receive(call, value) } else { shelfModel.receive(call, value) }
    }
    func send(_ data:[String:Any]) {
        start()
        guard let json = try? JSONSerialization.data(withJSONObject:data) else { return }
        do { try input?.write(contentsOf:json + Data([10])) }
        catch { process?.terminate() }
    }
    func start() {
        guard process == nil else { return }
        let p = py(["--agents"]), out = Pipe(), inp = Pipe(); p.standardOutput = out; p.standardInput = inp; p.standardError = FileHandle.nullDevice
        fcntl(inp.fileHandleForWriting.fileDescriptor,F_SETNOSIGPIPE,1)
        process = p; input = inp.fileHandleForWriting; output = out
        out.fileHandleForReading.readabilityHandler = { [weak self] file in
            let data = file.availableData
            DispatchQueue.main.async {
                guard let self, self.process === p else { return }; self.buffer += data
                while let newline = self.buffer.firstIndex(of:10) {
                    let data = Data(self.buffer[..<newline]); self.buffer.removeSubrange(...newline)
                    if let event = try? JSONSerialization.jsonObject(with:data) as? [String:Any] { self.receive(event) }
                }
            }
        }
        p.terminationHandler = { [weak self] _ in
            out.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async { [weak self] in
                guard let self, process === p else { return }
                if p.terminationReason == .uncaughtSignal || (p.terminationStatus != 0 && p.terminationStatus != 70) { telemetry(["error", "worker_exit", "python", String(p.terminationStatus)]) }
                // A crash drops its half-read line and box state; a fresh supervisor relists its saved rows.
                process = nil; input = nil; buffer = Data(); lastBox = nil; restarts += 1
                DispatchQueue.main.asyncAfter(deadline:.now() + min(60, pow(2, Double(restarts)))) { [weak self] in self?.start() }
            }
        }
        do { try p.run() }
        catch {
            process = nil; input = nil; restarts += 1
            DispatchQueue.main.asyncAfter(deadline:.now() + min(60, pow(2, Double(restarts)))) { [weak self] in self?.start() }
            return
        }
        send(["action":"list"])
    }
    func prepare(_ brief:[String:Any], from:[Double]? = nil) {
        var brief = brief
        if (brief["steer"] as? String).flatMap({ rows[$0] }) == nil { moveFrom[brief["handoffId"] as? String ?? ""] = from ?? [] }   // words to a live agent get no offer
        ensureShelf(preload:true); send(["action":"prepare","brief":brief])
    }
    var sorted: [[String:Any]] { rows.values.sorted { ($0["created"] as? Double ?? 0) > ($1["created"] as? Double ?? 0) } }
    var badge: [String:Any] { ["count":count,"attention":rows.values.contains { $0["status"] as? String == "needs-you" }] }   // the box pill turns amber when one needs you
    var count: Int { rows.values.filter { $0["status"] as? String == "running" }.count }
    static let live: Set = ["running","needs-you","waiting-screen","queued"]
    var hasLive: Bool { rows.values.contains { Self.live.contains($0["status"] as? String ?? "") } }
    // Pause: queued rows stop first, so stopping a running one cannot start them.
    func stopAll() { rows.filter { Self.live.contains($0.value["status"] as? String ?? "") }.sorted { ($0.value["status"] as? String == "queued") && ($1.value["status"] as? String != "queued") }.forEach { send(["action":"stop","id":$0.key]) } }
    // Allow on an agent's setup card: Aurel does what it can, opens the exact place for the rest, and tells the agent once it is on.
    func allow(_ id:String, _ q:[String:Any]) {
        let need = q["need"] as? String ?? "", app = q["app"] as? String ?? "", ask = q["_a"] as? String ?? ""
        if need == "page-js" { Prefs.set("pageJS",true); return }   // aurel.py turns it on itself
        if need == "connector" { NSWorkspace.shared.open(URL(string:"https://claude.ai/settings/connectors")!); return }   // aurel.py watches for it
        onboarding.allow(need, app:app)
        var tries = 0
        Timer.scheduledTimer(withTimeInterval:1, repeats:true) { [weak self] t in
            tries += 1
            guard let self, tries < 900, (self.rows[id]?["question"] as? [String:Any])?["_a"] as? String == ask else { t.invalidate(); return }
            DispatchQueue.global().async { [weak self] in if Onboarding.granted(need, app:app) { DispatchQueue.main.async { [weak self] in
                guard let self, (self.rows[id]?["question"] as? [String:Any])?["_a"] as? String == ask else { t.invalidate(); return }
                t.invalidate(); self.send(["action":"granted","id":id])
            } } }
        }
    }
    func receive(_ event:[String:Any]) {
        let kind = event["event"] as? String ?? ""
        if kind == "list", let list = event["agents"] as? [[String:Any]] {
            restarts = 0
            rows = Dictionary(uniqueKeysWithValues:list.compactMap { row in (row["id"] as? String).map { ($0,row) } })
            named = event["named"] as? [[String:Any]] ?? []
            if !hovered.isEmpty, rows[hovered] == nil { endPreview() }
            if let ping, rows[ping] == nil { self.ping = nil; app.agentCard = ""; app.pinned = false; app.js("agentCancelled"); app.hide(after:1) }
            if rows.values.contains(where:Self.lingers) { ensureShelf(preload:true) }
            js("shelf","list",sorted); js("view","list",sorted); js("view","named",named)
        } else if kind == "chats" {
            js("view","chats",event["chats"] as? [[String:Any]] ?? [])
        } else if kind == "named" {
            named = event["named"] as? [[String:Any]] ?? []; js("view","named",named)
            if let reply = event["reply"] as? String { js("view","namedReply",reply) }
        }
        if let row = event["agent"] as? [String:Any], let id = row["id"] as? String {
            let question = { (r:[String:Any]?) in (r?["question"] as? [String:Any])?["_a"] as? String }
            let asks = kind == "state" && row["status"] as? String == "needs-you" && question(row) != nil && question(row) != question(rows[id])
            let finished = Self.live.contains(rows[id]?["status"] as? String ?? "") && Self.lingers(row)
            rows[id] = row
            if asks, !quiet { app.sound("Ping",Float(Prefs.num("volume"))) }   // a new question from a working agent: it holds a slot until answered
            if row["status"] as? String == "needs-you" || finished { dismissed.remove(id) }   // a question, or a finish (news, as on the page), always comes back to the screen
            if kind == "state" {
                ensureShelf(preload:Self.lingers(row)); js("shelf","state",row); js("view","state",row)
                if hovered == id, let target = row["target"] as? [String:Any] { preview(id, surface:miniSurface, target:target) }
            } else if kind == "offer" {
                offers[id] = event["followup"] as? Bool == true ? row : [:]
                accept(id, from:moveFrom.removeValue(forKey:row["handoffId"] as? String ?? ""))
            } else if kind == "done" {
                if quiet || row["routine"] != nil { notify(row); rows[id]?["notified"] = true; send(["action":"notified","id":id]) }
            } else if kind == "ping", row["status"] as? String == "done" {   // aurel.py holds it while the box is busy, typing, listening or quiet
                if quiet { if row["notified"] as? Bool != true { notify(row); rows[id]?["notified"] = true; send(["action":"notified","id":id]) } }
                else { expand(id) }
            } else if kind == "steered" {   // the user spoke to this agent from the box: its chip comes back and says what it heard
                dismissed.remove(id); ensureShelf(); js("shelf","state",row); js("view","state",row); js("shelf","visible",true)
                if !quiet { shelf?.orderFrontRegardless() }
                app.js("agentSteered",row)
            }
        } else if kind == "text" { js("view","text",event) }
        app.js("agentCount",badge); tick()
    }
    func accept(_ id:String, from:[Double]? = nil) {
        guard !Prefs.bool("paused") else { return }
        guard var row = rows[id] else { return }
        let full = rows.values.filter { ["running","needs-you","waiting-screen"].contains($0["status"] as? String ?? "") }.count >= 3   // as Agents.running() counts
        row["status"] = full ? "queued" : "running"; row["step"] = full ? "Queued" : "Starting…"; rows[id] = row
        ensureShelf(); placeShelf(app.panel.isVisible ? app.panel.screen : NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) })
        nearSince = nil; shelf?.alphaValue = 1; shelf?.ignoresMouseEvents = false
        js("shelf","arrive",id)   // the chip opens its top slot and waits for the orb
        js("shelf","state",row); js("shelf","visible",true); app.js("agentCount",badge)   // show the chip before the supervisor round trip
        if !quiet { shelf?.orderFrontRegardless() }
        let offer = offers.removeValue(forKey:id) ?? [:]
        let text = (offer["brief"] as? String).map { $0 + "\nKnown context (data):\n" + (offer["context"] as? String ?? "") } ?? ""
        send(["action":"start","id":id,"text":text.isEmpty ? NSNull() as Any : text as Any]); app.pinned = false
        flying.append((id,from))   // agents from one ask all take their places first, or a later chip pushes an earlier orb's landing spot
        if moveFrom.isEmpty { launch() } else { DispatchQueue.main.asyncAfter(deadline:.now() + 0.4) { [weak self] in self?.launch() } }
        app.js("agentStarted",row)   // the box says it started an agent while the orb swims to the chip
        if !quiet { app.sound("Blow",Float(Prefs.num("volume"))) }   // a soft whoosh, apart from Pop (listening) and Glass (done)
        if from != nil { app.mini.reset() }   // its last hidden-window preview belongs to the foreground ask, not the agent
        if from != nil, app.panel.isVisible { app.hide(after:3.5) }   // started from the box: long enough to read its one line
    }
    func launch() {
        moveFrom = [:]   // a hand-off whose offer never came (it failed, or the supervisor restarted) must not hold later swims
        let landing = flying
        DispatchQueue.main.asyncAfter(deadline:.now() + 0.05) { [weak self] in for (id,from) in landing { self?.fly(id,from:from,to:self?.shelfModel.slot(id)) } }   // once SwiftUI has laid out the chips   // after every state above: the page has placed each chip or pill orb
        flying = []
    }
    func placeShelf(_ screen:NSScreen?) {
        guard let shelf, let screen = screen ?? NSScreen.main, !(shelf.isVisible && shelf.screen == screen) else { return }   // already there: keep the side it followed with
        let bounds = screen.visibleFrame, saved = (Prefs.d["agentFrames"] as? [String:[Double]])?[PanelFrame.key(screen)]
        shelf.setFrame(Self.shelfFrame(shelf.frame,bounds,saved),display:true)
    }
    static func shelfFrame(_ frame:NSRect, _ bounds:NSRect, _ saved:[Double]?) -> NSRect {
        var f = frame; f.size.height = max(52,min(f.height,bounds.height))
        f.origin = NSPoint(x:bounds.maxX-f.width-12,y:bounds.maxY-f.height-8)
        if let saved, saved.count == 2, saved.allSatisfy(\.isFinite) { f.origin = NSPoint(x:saved[0],y:saved[1]-f.height) }
        return PanelFrame.clamp(f,bounds)
    }
    // The shelf follows the pointer's display like the box, keeping its side and offsets.
    // An open chip, a drag or the orb's swim holds it.
    func follow() {
        guard let shelf, drag == nil, flight == nil, shelfModel.expanded.isEmpty || !shelf.isVisible, let f = pointerFollow(shelf.frame) else { return }
        shelf.setFrame(f,display:true)
    }
    // The agent's orb lifts off the hand-off card and swims to the shelf's top slot: one transient panel, Core Animation only,
    // so nothing runs per frame in the app or WebKit. Reduce Motion (or no card) skips the swim; the chip cross-fades in.
    var flight: NSPanel?, flightPace = 1.0   // shortcut: pace > 1 is slow motion for VM frame captures only; nothing else sets it
    func fly(_ id:String, from rect:[Double]?, to slot:[Double]? = nil) {
        let land = { [weak self] in self?.js("shelf","land",id) }
        guard !quiet, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, let shelf, let rect, rect.count == 4, rect.allSatisfy(\.isFinite), rect[2] > 0, rect[3] > 0 else { land(); return }
        var r = NSRect(x:rect[0],y:rect[1],width:rect[2],height:rect[3])
        if !app.boxView.isFlipped { r.origin.y = app.boxView.bounds.height - r.maxY }
        let start = app.panel.convertToScreen(app.boxView.convert(r,to:nil)), from = NSPoint(x:start.midX,y:start.midY)
        let at = slot?.count == 2 && slot!.allSatisfy(\.isFinite) ? slot! : [24,26]   // page point of its orb; else the top chip's
        let to = NSPoint(x:shelf.frame.minX + at[0],y:shelf.frame.maxY - at[1])
        let lift = max(50,hypot(to.x - from.x,to.y - from.y) * 0.2)
        let frame = NSRect(x:min(from.x,to.x) - 60,y:min(from.y,to.y) - lift - 60,width:abs(to.x - from.x) + 120,height:abs(to.y - from.y) + lift + 120)
        let panel = ShelfPanel(contentRect:frame,styleMask:[.nonactivatingPanel,.borderless],backing:.buffered,defer:false)
        panel.isReleasedWhenClosed = false; panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false; panel.ignoresMouseEvents = true
        panel.level = .statusBar; applySharing(panel); panel.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary,.ignoresCycle]
        let host = NSView(frame:NSRect(origin:.zero,size:frame.size)); host.wantsLayer = true; panel.contentView = host; host.layer?.speed = Float(1 / flightPace)
        let a = CGPoint(x:from.x - frame.minX,y:from.y - frame.minY), b = CGPoint(x:to.x - frame.minX,y:to.y - frame.minY), low = min(a.y,b.y) - lift
        let path = CGMutablePath(); path.move(to:a)   // a low swoop under both ends, then up into the slot
        path.addCurve(to:b,control1:CGPoint(x:a.x + (b.x - a.x) * 0.3,y:low),control2:CGPoint(x:a.x + (b.x - a.x) * 0.78,y:low + lift * 0.4))
        let blue = NSColor(srgbRed:0.04,green:0.52,blue:1,alpha:1).cgColor, begin = host.layer?.convertTime(CACurrentMediaTime(),from:nil) ?? 0, duration = 0.62
        func blob(_ size:CGFloat, _ opacity:Float, _ delay:Double, squash:Bool) {
            let orb = CAGradientLayer(); orb.type = .radial; orb.frame = CGRect(x:0,y:0,width:size,height:size); orb.cornerRadius = size / 2
            orb.colors = [CGColor(gray:1,alpha:1),blue,NSColor(srgbRed:0.04,green:0.52,blue:1,alpha:0).cgColor]; orb.locations = [0,0.45,1]
            orb.startPoint = CGPoint(x:0.5,y:0.5); orb.endPoint = CGPoint(x:1,y:1)
            orb.shadowColor = blue; orb.shadowRadius = size * 0.45; orb.shadowOpacity = 0.9; orb.shadowOffset = .zero; orb.position = a; orb.opacity = 0
            host.layer?.addSublayer(orb)
            let swim = CAKeyframeAnimation(keyPath:"position"); swim.path = path; swim.calculationMode = .paced; swim.rotationMode = .rotateAuto
            swim.timingFunction = CAMediaTimingFunction(controlPoints:0.5,0,0.2,1)
            let shape = CAKeyframeAnimation(keyPath:"transform")   // lift, stretch along the swim, squash on landing
            shape.values = squash ? [CATransform3DMakeScale(0.35,0.35,1),CATransform3DMakeScale(1.1,0.9,1),CATransform3DMakeScale(1.26,0.82,1),CATransform3DMakeScale(0.84,1.14,1),CATransform3DIdentity].map { NSValue(caTransform3D:$0) }
                                  : [CATransform3DMakeScale(0.5,0.5,1),CATransform3DIdentity,CATransform3DMakeScale(0.6,0.6,1)].map { NSValue(caTransform3D:$0) }
            shape.keyTimes = squash ? [0,0.15,0.5,0.88,1] : [0,0.4,1]
            let fade = CAKeyframeAnimation(keyPath:"opacity"); fade.values = [0,opacity,opacity,0]; fade.keyTimes = [0,0.1,0.86,1]
            let group = CAAnimationGroup(); group.animations = [swim,shape,fade]; group.duration = duration; group.beginTime = begin + delay
            group.fillMode = .both; group.isRemovedOnCompletion = false; orb.add(group,forKey:"swim")
        }
        for i in 1...5 { blob(CGFloat(20 - i * 2),Float(0.42 - Double(i) * 0.07),Double(i) * 0.035,squash:false) }   // the trailing glow
        blob(26,1,0,squash:true)
        flight = panel; panel.orderFrontRegardless()   // agents from one ask swim side by side; each panel orders itself out
        DispatchQueue.main.asyncAfter(deadline:.now() + (duration - 0.08) * flightPace) { land() }
        DispatchQueue.main.asyncAfter(deadline:.now() + (duration + 0.25) * flightPace) { [weak self] in panel.orderOut(nil); if self?.flight === panel { self?.flight = nil } }
    }
    // The chips draw themselves (shadows, glass), so the panel is clear. The PointerView under them feeds hover, as the panel never becomes key.
    func makeShelf(_ panel:NSPanel) {
        let bg = PointerView(frame:NSRect(origin:.zero,size:panel.frame.size)), host = ShelfHost(rootView:AgentShelf(s:shelfModel))
        bg.onPointer = { [weak self] p in
            guard let self else { return }
            let hand = shelfModel.pointer(p)
            if hand != pointerHand { pointerHand = hand; (hand ? NSCursor.pointingHand : NSCursor.arrow).set() }   // Aurel never activates, so nothing else sets the cursor here
        }
        host.frame = bg.bounds; host.autoresizingMask = [.width,.height]; bg.addSubview(host); bg.autoresizingMask = [.width,.height]
        panel.contentView = bg; panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false   // chips cast their own shadows; a window shadow would box them
        panel.hidesOnDeactivate = false
        applySharing(panel); panel.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary,.ignoresCycle]; panel.acceptsMouseMovedEvents = true
    }
    var pointerHand = false
    func ensureShelf(preload:Bool = false) {
        guard shelf == nil, preload || hasLive else { return }
        let screen = mouseScreen
        let bounds = screen.visibleFrame, saved = (Prefs.d["agentFrames"] as? [String:[Double]])?[PanelFrame.key(screen)]
        let f = Self.shelfFrame(NSRect(x:0,y:0,width:260,height:52),bounds,saved)
        let panel = ShelfPanel(contentRect:f,styleMask:[.nonactivatingPanel,.borderless],backing:.buffered,defer:false)
        panel.level = .statusBar; shelf = panel; makeShelf(panel); if !preload { panel.orderFrontRegardless() }
        shelfModel.receive("visible", !preload)
    }
    func remember() {
        guard let shelf, let screen = shelf.screen else { return }
        let bounds = screen.visibleFrame; var f = shelf.frame
        let distances = [abs(f.minX-bounds.minX),abs(bounds.maxX-f.maxX),abs(f.minY-bounds.minY),abs(bounds.maxY-f.maxY)]
        switch distances.firstIndex(of:distances.min()!) {
        case 0: f.origin.x = bounds.minX+8
        case 1: f.origin.x = bounds.maxX-f.width-8
        case 2: f.origin.y = bounds.minY+8
        default: f.origin.y = bounds.maxY-f.height-8
        }
        shelf.setFrame(PanelFrame.clamp(f,bounds),display:true)
        var frames = Prefs.d["agentFrames"] as? [String:[Double]] ?? [:]; frames[PanelFrame.key(screen)] = [f.minX,f.maxY]
        Prefs.set("agentFrames",frames)
    }
    func openView(_ id:String = "") {
        start()
        if view == nil {
            let screen = mouseScreen
            let f = PanelFrame.clamp(NSRect(x:screen.visibleFrame.midX-450,y:screen.visibleFrame.midY-310,width:900,height:620),screen.visibleFrame)
            // A normal window, as Settings is: it activates Aurel, so it comes back from the Dock and ⌘Tab instead of hiding behind other apps (Dock).
            let panel = NSWindow(contentRect:f,styleMask:[.titled,.closable,.miniaturizable,.resizable,.fullSizeContentView],backing:.buffered,defer:false)
            panel.title = "Agents"; panel.titleVisibility = .hidden; panel.titlebarAppearsTransparent = true
            panel.minSize = NSSize(width:560,height:340); panel.isReleasedWhenClosed = false
            applySharing(panel)
            // A sidebar under the traffic lights, the conversation beside it. The live window preview (mini.clip) sits over the conversation's host.
            let split = NSSplitViewController()
            let side = NSSplitViewItem(sidebarWithViewController:NSHostingController(rootView:AgentSidebar(m:model)))
            side.minimumThickness = 220; side.maximumThickness = 360; side.canCollapse = false
            let detail = NSViewController(), host = NSHostingView(rootView:AgentDetail(m:model))
            detail.view = NSView(); host.frame = detail.view.bounds; host.autoresizingMask = [.width,.height]; detail.view.addSubview(host)
            split.addSplitViewItem(side); split.addSplitViewItem(NSSplitViewItem(viewController:detail)); split.splitView.setPosition(260,ofDividerAt:0)
            panel.contentViewController = split; panel.setFrame(f,display:false)
            view = panel; viewHost = detail.view
            send(["action":"chats"])
            NotificationCenter.default.addObserver(forName:NSWindow.willCloseNotification,object:panel,queue:.main) { [weak self] _ in
                self?.closeView()
            }
        }
        js("view","visible",true)
        if let view { Dock.show(view) }
        let id = id.isEmpty ? sorted.first(where:{ ["needs-you","running","waiting-screen","queued"].contains($0["status"] as? String ?? "") })?["id"] as? String ?? "" : id   // menu and pill land on the live agent
        if !id.isEmpty { selected = id; js("view","select",id); preview(id,surface:"view") }
        js("view","list",sorted)
    }
    func preview(_ id:String, surface:String, target:[String:Any]? = nil) {
        let changed = hovered != id || miniSurface != surface
        hovered = id; miniSurface = surface
        guard !id.isEmpty, let row = rows[id], let target = target ?? row["target"] as? [String:Any],
              let bg = surface == "view" ? viewHost : shelf?.contentView else { endPreview(); return }
        if changed { mini.reset() }
        if mini.clip.superview !== bg { mini.clip.removeFromSuperview(); bg.addSubview(mini.clip,positioned:.above,relativeTo:nil) }   // over the chip's glass or the conversation; clicks pass through
        app.mini.timer?.invalidate(); app.mini.timer = nil; app.mini.stopCapture(clear:false)   // main preview yields while an agent is inspected
        mini.receive(target)
        if row["status"] as? String == "done" { mini.finish() }
        if surface == "view" { model.layoutMini() }
    }
    var sharing: Bool { Prefs.bool("agentsHidden") }   // macOS has no public global capture signal; this also covers silent screen-only presentations
    var quiet: Bool { sharing }
    func endPreview() {
        hovered = ""; mini.reset()
        if app.busy, let target = app.mini.target { app.mini.receive(target) }
    }
    var lingering = false   // the page shows finished agents (their chips or the "✓ N done" pill)
    // Finished or last seen in the past 10 minutes, e.g. before a restart: the shelf must exist to show it (ShelfModel.linger).
    static func lingers(_ r:[String:Any]) -> Bool {
        ["done","failed"].contains(r["status"] as? String ?? "") && Date().timeIntervalSince1970 - max(r["ended"] as? Double ?? 0, r["seenAt"] as? Double ?? 0) < 600
    }
    var hasChips: Bool { lingering || rows.values.contains { ["running","needs-you","waiting-screen","queued"].contains($0["status"] as? String ?? "") && !dismissed.contains($0["id"] as? String ?? "") } }
    func closeView() {
        endPreview(); js("view","visible",false); Dock.update()   // Esc hides the window without closing it
        guard hasChips, !quiet else { return }
        shelf?.orderFrontRegardless(); js("shelf","resume")
    }
    func notify(_ row:[String:Any]) {
        let p = py(["--agent-notify", row["summary"] as? String ?? row["title"] as? String ?? "Your task is done"])
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice; try? p.run()
    }
    func dismissPing(_ id:String) {
        send(["action":"seen","id":id]); ping = nil; app.pinned = false; app.hide(after:1)   // answered: it folds into the shelf's "done" pill
    }
    // A main ask that showed it (--agent-show): a done one's card in the box; one still working, or failed, opens in the Agent view.
    func show(_ id:String) {
        guard let row = rows[id] else { return }
        guard row["status"] as? String == "done" else { openView(id); return }
        if let old = ping, old != id { send(["action":"seen","id":old]) }   // the card this one replaces was on screen; unseen, it would ping again after a restart
        ping = id
        app.show()
        app.pinned = true; app.agentCard = id; app.js("agentDone",row)   // seen once the user acts on it (dismissPing, open, or an ask/close over it in tick)
    }
    // A finish shows on its own chip, opened with its result; the box stays as the user left it. Seen once the user opens or hides it.
    func expand(_ id:String) {
        dismissed.remove(id); ensureShelf(preload:true)
        js("shelf","expand",id)
        app.sound("Hero", min(1, Float(Prefs.num("volume")) * 2))   // its own, louder chime: the user is usually busy elsewhere when an agent finishes
    }
    // Near the shelf but not on it for 0.3 s: it fades and lets clicks through. Every mouse move checks it, so it is back as the pointer arrives.
    func fade() {
        guard let shelf, shelf.isVisible else { return }
        let point = NSEvent.mouseLocation, inside = shelf.frame.contains(point), near = shelf.frame.insetBy(dx:-60,dy:-30).contains(point)
        if inside || !near { nearSince = nil } else if nearSince == nil { nearSince = Date() }
        let fade = nearSince.map { Date().timeIntervalSince($0) >= 0.3 } ?? false
        guard shelf.ignoresMouseEvents != fade else { return }
        shelf.ignoresMouseEvents = fade; NSAnimationContext.runAnimationGroup { $0.duration = fade ? 0.2 : 0.08; shelf.animator().alphaValue = fade ? 0.25 : 1 }   // eased, never a snap; back fast: the pointer slows near a chip it aims at, so arrival often finds it faded
        if inside { (shelf.contentView as? PointerView)?.here() }   // AppKit sends no mouseEntered to a window that stops ignoring the mouse under it
    }
    func tick() {
        guard !rows.isEmpty else { shelf?.orderOut(nil); timer?.invalidate(); timer = nil; return }
        let box: [String:Any] = ["action":"box","busy":app.busy,"typing":app.composing,"listening":app.engine.isRunning,"quiet":quiet]
        if lastBox?.isEqual(to:box) != true { lastBox = NSDictionary(dictionary:box); send(box) }
        if Date().timeIntervalSince(kept) > 20, rows.values.contains(where: { $0["status"] as? String == "running" && $0["_requestedModel"] as? String == "local" }) {
            kept = Date(); _ = LocalAI.shared.address()
        }
        if let shelf {
            let hidden = quiet   // never hide in full screen: he works in full-screen apps on both displays
            if hidden || !hasChips {
                if shelf.isVisible { shelf.orderOut(nil); js("shelf","visible",false); _ = shelfModel.pointer([]); if pointerHand { pointerHand = false; NSCursor.arrow.set() } }   // once, not every tick; a hidden panel gets no mouseExited, so its hover, .near and hand cursor end here
                moves.forEach(NSEvent.removeMonitor); moves = []
                if miniSurface == "shelf", mini.target != nil { endPreview() }
            }
            else {
                if !shelf.isVisible { shelf.orderFrontRegardless(); js("shelf","visible",true) }
                if moves.isEmpty {   // only while the shelf is up: a global move monitor wakes the app on every mouse move anywhere
                    moves = [NSEvent.addGlobalMonitorForEvents(matching:.mouseMoved) { [weak self] _ in self?.fade() },   // a faded shelf gets no mouse events: other apps' moves bring it back
                             NSEvent.addLocalMonitorForEvents(matching:.mouseMoved) { [weak self] e in self?.fade(); return e },
                             NSEvent.addGlobalMonitorForEvents(matching:.leftMouseDown) { [weak self] _ in self?.js("shelf","blur") }].compactMap { $0 }   // a click in another app
                }
                fade()
            }
            follow()
        }
        if let id = ping, !app.panel.isVisible || app.busy || app.engine.isRunning {   // the user closed the box or asked over the card
            send(["action":"seen","id":id]); ping = nil; app.agentCard = ""; app.pinned = false; app.defaultKey(false); app.js("agentCancelled")
        }
    }
    func open(_ id:String, target:String? = nil, reveal:Bool = false) {
        guard let row = rows[id] else {
            if let target, let url = URL(string:target), ["https","http"].contains(url.scheme?.lowercased() ?? "") { NSWorkspace.shared.open(url) }
            return
        }
        app.allowUntil = Date().addingTimeInterval(3); app.allowUserApp = true   // a click in our own panel never reaches the global monitor, so the focus guard took this for an app raising itself
        let raw = target ?? ((row["made"] as? [[String:Any]])?.first?["url"] as? String) ?? (row["links"] as? [String])?.first   // the main thing it made
        if let raw {
            if let url = URL(string:raw), ["https","http"].contains(url.scheme?.lowercased() ?? "") { NSWorkspace.shared.open(url); return }
            let path = raw.hasPrefix("file://") ? URL(string:raw)?.path ?? "" : NSString(string:raw).expandingTildeInPath
            let root = row["directory"] as? String ?? ""
            let url = URL(fileURLWithPath:path.hasPrefix("/") ? path : root + "/" + path).standardizedFileURL
            if FileManager.default.fileExists(atPath:url.path) {
                if reveal { NSWorkspace.shared.activateFileViewerSelecting([url]) } else { NSWorkspace.shared.open(url) }; return
            }
        }
        if reveal, let folder = row["directory"] as? String { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath:folder)]); return }
        if let target = row["target"] as? [String:Any] { mini.receive(target); mini.open(); mini.reset() }
        else { openView(id) }
    }
    // What the shelf and the Agent view ask for.
    func handle(_ body:[String:Any], surface:String) {
        guard let action = body["action"] as? String else { return }
        let id = body["id"] as? String ?? ""
        switch action {
        case "size":
            guard surface == "shelf", let shelf, let h = body["h"] as? Double, h.isFinite, let screen = shelf.screen else { return }
            var f = shelf.frame; f.origin.y = f.maxY - max(52,h); f.size.height = max(52,h)
            let next = PanelFrame.clamp(f,screen.visibleFrame); if next != shelf.frame { shelf.setFrame(next,display:false) }   // once per state change; the page already laid out
        case "dismiss":
            if rows[id]?["status"] as? String == "done" { send(["action":"seen","id":id]); rows[id]?["seenAt"] = Date().timeIntervalSince1970 }   // as aurel.py saves it, so the saved list keeps it
            dismissed.insert(id)
            if hovered == id, miniSurface == "shelf" { endPreview() }
        case "stack": Prefs.set("agentStack",body["value"] as? String ?? "")
        case "tab": Prefs.set("agentTab",body["value"] as? String == "chats" ? "chats" : "")
        case "view", "show": openView(id); if rows[id]?["status"] as? String == "done" { send(["action":"seen","id":id]) }   // a finished chip clicked open
        case "lingering": lingering = body["value"] as? Bool ?? false; tick()
        case "close": if surface == "view" { view?.orderOut(nil); closeView() }
        case "ask":   // New Chat's first message: an agent of its own, accepted, so it runs here like any other
            guard let text = body["text"] as? String, !text.isEmpty else { return }
            send(["action":"prepare","brief":["title":text.split(separator:" ").prefix(8).joined(separator:" "),"brief":String(text.prefix(1000)),"request":text,"context":"Asked in the Agents window.","accepted":true]])
        case "hover":
            if id.isEmpty { endPreview() }
            else if hovered != id || miniSurface != surface { preview(id,surface:surface) }
        case "attention": if !quiet { shelf?.orderFrontRegardless() }
        case "open": open(id,target:body["target"] as? String); if rows[id]?["status"] as? String == "done" { send(["action":"seen","id":id]) }
        case "reveal": open(id,reveal:true)
        case "connect": NSWorkspace.shared.open(URL(string:"https://claude.ai/settings/connectors")!)
        case "answer":
            send(body)
            if body["answer"] as? String == "y", let q = rows[id]?["question"] as? [String:Any], q["need"] != nil, q["_a"] as? String == body["question"] as? String { allow(id,q) }
        default: send(body)
        }
    }
}

// ── Agent view (native) ──
// The window AgentPanels.openView shows: agents and saved chats in a sidebar, the selected one's conversation beside it.
// AgentPanels.js "view" calls land in receive; it answers through AgentPanels.handle.
final class AgentViewModel: ObservableObject {
    @Published var rows: [AgentRow] = []
    @Published var chats: [AgentRow] = []
    @Published var named: [[String:Any]] = []
    @Published var picked = ""
    @Published var namedStatus = ""
    @Published var liveText: [String:String] = [:]
    @Published var miniLive = false
    @Published var folds: [String:Bool] = [:]
    @Published var opened = Set<String>()
    @Published var sideEditing = false   // a saved agent's name is being edited in the sidebar
    @Published var composing = false   // New Chat: a blank conversation, until its first message's agent arrives
    @Published var asked = ""   // that first message, sent and waiting for its agent
    var post: ([String:Any]) -> Void = { _ in }
    var miniFrame = CGRect.zero, scrollFrame = CGRect.zero, onMini: (CGRect, CGRect) -> Void = { _, _ in }
    var namedTimer: Timer?
    func receive(_ call: String, _ value: Any) {
        switch call {
        case "list": rows = (value as? [[String:Any]] ?? []).map(AgentRow.init)
        case "chats": chats = (value as? [[String:Any]] ?? []).map(AgentRow.init)
        case "named": named = value as? [[String:Any]] ?? []
        case "namedReply": say(value as? String ?? "")
        case "state":
            guard let r = value as? [String:Any] else { return }
            let row = AgentRow(r), old = rows.firstIndex { $0.id == row.id }
            if let old { if "\(rows[old].r["textVersion"] ?? "")" != "\(r["textVersion"] ?? "")" || row.status != "running" { liveText[row.id] = nil }; rows[old] = row }
            else { rows.insert(row, at:0) }
            if composing, !asked.isEmpty, row.str("brief") == String(asked.prefix(1000)) { picked = row.id; composing = false; asked = "" }   // New Chat's agent: it takes over the blank page
        case "text":
            guard let e = value as? [String:Any], let id = e["id"] as? String, let text = e["text"] as? String else { return }
            liveText[id, default:""] += text
        case "select": picked = value as? String ?? ""
        case "mini": miniLive = (value as? [String:Any])?["live"] as? Bool ?? false
        default: break
        }
    }
    func say(_ text: String) {
        namedStatus = text; namedTimer?.invalidate()
        if !text.isEmpty { namedTimer = Timer.scheduledTimer(withTimeInterval:6, repeats:false) { [weak self] _ in self?.namedStatus = "" } }
    }
    // The one shown: the picked one while it exists, else the live one, else the newest.
    var current: AgentRow? {
        if composing { return nil }
        let all = rows + chats
        return all.first { $0.id == picked } ?? all.sorted { ($0.live ? 1 : 0, $0.num("created")) > ($1.live ? 1 : 0, $1.num("created")) }.first
    }
    func command(_ action: String, _ id: String, _ more: [String:Any] = [:]) { post(["action":action,"id":id].merging(more) { $1 }) }
    func layoutMini() {
        let clip = miniFrame.intersection(scrollFrame)
        onMini(miniFrame, clip.isNull ? .zero : clip)
    }
}

// One row from aurel.py's agent supervisor, or a saved chat (it has turns).
struct AgentRow: Identifiable {
    let r: [String:Any]
    init(_ r: [String:Any]) { self.r = r }
    var id: String { str("id") }
    func str(_ key: String) -> String { r[key] as? String ?? "" }
    func num(_ key: String) -> Double { (r[key] as? NSNumber)?.doubleValue ?? 0 }
    var status: String { str("status") }
    var title: String { str("title") }
    var live: Bool { AgentPanels.live.contains(status) }
    var finished: Bool { status == "done" || status == "failed" }
    var begin: Double { num("started") > 0 ? num("started") : num("created") }
    var steered: Bool { ((r["steer"] as? [String:Any])?["at"] as? NSNumber).map { Date().timeIntervalSince1970 - $0.doubleValue < 4 } ?? false }   // words just sent to it from the box
    var steerAck: String { (r["steer"] as? [String:Any])?["ack"] as? String ?? "" }
    var orbTint: Color? { ["done": .green, "failed": .red, "needs-you": .orange][status] }   // a shelf orb takes its status color
    var turns: [[String:Any]]? { r["turns"] as? [[String:Any]] }
    var question: [String:Any]? { r["question"] as? [String:Any] }
    var word: String { ["needs-you":"Needs you","waiting-screen":"Waiting for the screen","running":"Working","queued":"Queued","offered":"Ready to start","done":"Done","failed":"Couldn’t finish","stopped":"Stopped"][status] ?? status }
    var state: String {
        switch status {
        case "running": return str("step").isEmpty ? "Starting…" : str("step")
        case "failed": return str("step").isEmpty ? "Couldn’t finish" : str("step")
        case "done": return !(r["missingConnector"] as? String ?? "").isEmpty ? "Connect in Claude" : "Done · " + ago
        default: return word
        }
    }
    static func cost(_ u: Double) -> String { "≈" + (u < 1 ? String(format: u < 0.1 ? "%.2f¢" : "%.1f¢", u * 100) : String(format: "$%.2f", u)) + " at API prices" }   // at API list prices
    var subtitle: String {
        switch status {
        case "running", "failed": return state
        case "done": return "Done in " + time
        default: return word
        }
    }
    var when: String {   // like Mail: a time today, then Yesterday, then the date
        let d = Date(timeIntervalSince1970: num("started") > 0 ? num("started") : num("created")), cal = Calendar.current
        return cal.isDateInToday(d) ? d.formatted(date: .omitted, time: .shortened) : cal.isDateInYesterday(d) ? "Yesterday" : d.formatted(.dateTime.month(.abbreviated).day())
    }
    var ago: String { let m = Int((Date().timeIntervalSince1970 - num("ended")) / 60); return m < 1 ? "just now" : m < 60 ? "\(m)m ago" : "\(m / 60)h ago" }
    var time: String {
        let end = num("ended") > 0 ? num("ended") : Date().timeIntervalSince1970, s = max(0, Int(end - (num("started") > 0 ? num("started") : num("created"))))
        return s < 60 ? "\(s)s" : s < 3600 ? "\(s / 60)m \(s % 60)s" : "\(s / 3600)h \(s % 3600 / 60)m"
    }
    // Calendar days, so 11:50 PM is "Yesterday" ten minutes later.
    var begun: String {
        let d = Date(timeIntervalSince1970: num("started") > 0 ? num("started") : num("created")), cal = Calendar.current
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: d), to: cal.startOfDay(for: Date())).day ?? 0
        let clock = d.formatted(date: .omitted, time: .shortened)
        return days < 1 ? clock : days == 1 ? "Yesterday " + clock : d.formatted(.dateTime.month(.abbreviated).day()) + ", " + clock
    }
    var answer: String {
        let result = str("result"), cut = result.range(of: #"\[agent-result\b[\s\S]*$"#, options: .regularExpression).map { String(result[..<$0.lowerBound]) } ?? result
        let said = cut.trimmingCharacters(in: .whitespacesAndNewlines)
        return said.isEmpty ? str("summary") : said
    }
    var sources: [[String:Any]] { r["sources"] as? [[String:Any]] ?? [] }
    // What it made: one card per doc, sheet, event, file or link. An untitled page the answer links to is a source, not a thing.
    var things: [AgentThing] {
        let list = (r["made"] as? [[String:Any]]).flatMap { $0.isEmpty ? nil : $0 } ?? (r["links"] as? [String] ?? []).map { ["url":$0] }
        let said = answer
        return list.compactMap { m in
            let url = m["url"] as? String ?? "", title = m["title"] as? String ?? "", file = url.hasPrefix("/")
            let probe = (m["type"] as? String ?? "") + " " + (url.components(separatedBy: CharacterSet(charactersIn: "?#")).first ?? url)
            let kind = AgentThing.kinds.first { probe.range(of: $0.1, options: [.regularExpression, .caseInsensitive]) != nil } ?? ("link", "", "Link")
            if kind.0 == "link", title.isEmpty, said.contains(url) { return nil }
            let host = agentHost(url)
            return AgentThing(url: url, kind: kind.0, title: title.isEmpty ? (file ? (url as NSString).lastPathComponent : host.isEmpty ? url : host) : title, sub: kind.2 + " · " + (file ? "In its folder" : host))
        }
    }
    // The timeline as steps: a run of the same kind of tool folds into one line with a count.
    var groups: [AgentStep] {
        var out: [AgentStep] = []
        for e in r["timeline"] as? [[String:Any]] ?? [] {
            if e["question"] != nil { continue }
            if let user = e["user"] as? String { out.append(AgentStep(kind:"user", lines:[user], tools:[""])); continue }
            let tool = e["tool"] as? String ?? "", text = e["text"] as? String ?? "", srcs = e["sources"] as? [[String:Any]] ?? []
            let kind = AgentStep.kind(tool, text, made: e["made"] != nil)
            if kind == "sources" { if !out.isEmpty { out[out.count - 1].sources += srcs }; continue }
            if kind == "made" { out.append(AgentStep(kind:kind, lines:(e["made"] as? [[String:Any]] ?? []).map { "Made " + (($0["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? agentHost($0["url"] as? String ?? "")) }, tools:[])); continue }
            if let prev = out.last, prev.kind == "note", !tool.isEmpty, prev.lines == [text] { out.removeLast() }   // the narration line becomes its tool step
            if let last = out.last, kind != "note", last.kind == kind { out[out.count - 1].lines.append(text); out[out.count - 1].tools.append(tool); out[out.count - 1].sources += srcs }
            else { out.append(AgentStep(kind:kind, lines:[kind == "app" && (text.isEmpty || text == "Using a connector") ? AgentStep.appName(tool) : text], tools:[tool], sources:srcs)) }
        }
        return out
    }
}

struct AgentThing: Identifiable {
    let url: String, kind: String, title: String, sub: String
    var id: String { url }
    static let kinds: [(String, String, String)] = [("sheet", #"spreadsheet|/spreadsheets/|\.(csv|xlsx?|numbers|tsv)$"#, "Spreadsheet"), ("slides", #"presentation|\.(pptx?|key)$"#, "Presentation"),
        ("doc", #"document|\.(docx?|md|txt|pages|rtf|html?)$"#, "Document"), ("event", "calendar|event", "Event"), ("mail", "mail|draft", "Message"), ("pdf", "pdf", "PDF"),
        ("image", #"image|\.(png|jpe?g|gif|heic|webp|svg)$"#, "Image"), ("folder", "folder", "Folder"), ("file", "^ ?/", "File")]
}

struct AgentStep {
    var kind: String, lines: [String], tools: [String], sources: [[String:Any]] = []
    // What kind of work a timeline line is, by the tool that did it.
    static func kind(_ tool: String, _ text: String, made: Bool) -> String {
        if tool.isEmpty { return made ? "made" : text.isEmpty ? "sources" : "note" }
        if tool == "ToolSearch" { return "tools" }
        if tool.range(of: "search", options: .caseInsensitive) != nil { return "search" }
        if tool == "WebFetch" || text.hasPrefix("Reading ") { return "read" }
        if ["Read","Grep","Glob","LS"].contains(tool) { return "file" }
        if ["Write","Edit","MultiEdit","NotebookEdit"].contains(tool) { return "write" }
        return tool.hasPrefix("mcp__") ? "app" : "run"
    }
    static func appName(_ tool: String) -> String {
        let parts = tool.components(separatedBy: "__")
        guard parts.count > 2 else { return tool }
        return parts[1].replacingOccurrences(of: "^claude_ai_", with: "", options: .regularExpression).replacingOccurrences(of: "_", with: " ") + ": " + parts[2...].joined(separator: " ").replacingOccurrences(of: "_", with: " ")
    }
    static let symbols = ["search":"magnifyingglass","read":"globe","file":"doc","write":"pencil","run":"terminal","app":"powerplug","tools":"wrench.and.screwdriver","made":"checkmark",
                          "sheet":"tablecells","slides":"rectangle.on.rectangle","doc":"doc.text","event":"calendar","mail":"envelope","pdf":"doc.richtext","image":"photo","folder":"folder","link":"link"]
}

func agentHost(_ url: String) -> String { (URL(string: url)?.host ?? "").replacingOccurrences(of: "^www\\.", with: "", options: .regularExpression) }

// A streamed answer waits at a **bold, `code, [link or $math that has not closed yet, so its marks never flash as symbols (as shutAnswer in Answer.swift).
func agentShut(_ s: String) -> String {
    let ns = s as NSString, all = NSRange(location: 0, length: ns.length)
    if ((try? NSRegularExpression(pattern: "^\\s*```", options: .anchorsMatchLines))?.numberOfMatches(in: s, range: all) ?? 0) % 2 == 1 { return s }   // inside a code block every mark is text
    let closed = try! NSRegularExpression(pattern: #"(?<!\\)\$\$[\s\S]+?\$\$|\\\[[\s\S]+?\\\]|\\\([\s\S]+?\\\)|(?<!\\)\$(?=\S)(?:\\.|[^$\\\n])+?(?<=\S)\$(?!\d)|\*\*[^*]+\*\*|`[^`]+`|\[[^\]]+\]\([^\s)]+\)"#)
    let blank = NSMutableString(string: s)
    for m in closed.matches(in: s, range: all).reversed() { blank.replaceCharacters(in: m.range, with: String(repeating: " ", count: m.range.length)) }
    let k = ns.range(of: "\n", options: .backwards).location == NSNotFound ? 0 : NSMaxRange(ns.range(of: "\n", options: .backwards))
    let line = ns.substring(from: k), b = blank as String
    var open: [Int] = []
    if line.components(separatedBy: "**").count % 2 == 0 { open.append(k + (line as NSString).range(of: "**", options: .backwards).location) }
    if line.components(separatedBy: "`").count % 2 == 0 { open.append(k + (line as NSString).range(of: "`", options: .backwards).location) }
    let first = { (pattern: String, text: String) in (try? NSRegularExpression(pattern: pattern))?.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length))?.range.location }
    if let i = first(#"\[[^\]]*$"#, line) { open.append(k + i) }
    if let i = first(#"(?<!\\)\$(?![\d\s])"#, (b as NSString).substring(from: k)) { open.append(k + i) }   // a $ before a digit is a price and shows at once
    if let i = first(#"(?<!\\)\$\$|\\[\[(]"#, b) { open.append(i) }   // $$, \[ or \( math still open, even lines back
    return open.min().map { ns.substring(to: $0) } ?? s
}

// Textual finds math after Markdown has parsed, so Markdown would eat TeX escapes (\, \{) and read any $ as math.
// Aurel's rules pick the math first (a $ before a digit is a price), shield it from Markdown, and hold every other $ aside as U+E000.
let answerSpan = try! NSRegularExpression(pattern: #"```[\s\S]*?(?:```|\z)|`[^`\n]+`|(?<!\\)\$\$([\s\S]+?)\$\$|\\\[([\s\S]+?)\\\]|\\\(([\s\S]+?)\\\)|(?<!\\)\$(?=\S)((?:\\.|[^$\\\n])+?)(?<=\S)\$(?!\d)"#)
func answerMarkdown(_ text: String) -> String {
    let s = text as NSString, dollar = "\u{E000}"; var out = "", at = 0
    func plain(_ t: String) -> String { t.replacingOccurrences(of: "\\$", with: dollar).replacingOccurrences(of: "$", with: dollar) }
    func tex(_ t: String) -> String { t.unicodeScalars.map { $0.isASCII && CharacterSet.punctuationCharacters.union(.symbols).contains($0) ? "\\\($0)" : String($0) }.joined() }   // Markdown unescapes each back
    for m in answerSpan.matches(in: text, range: NSRange(location: 0, length: s.length)) {
        out += plain(s.substring(with: NSRange(location: at, length: m.range.location - at))); at = NSMaxRange(m.range)
        guard let g = (1...4).first(where: { m.range(at: $0).location != NSNotFound }) else { out += s.substring(with: m.range).replacingOccurrences(of: "$", with: dollar); continue }   // code keeps its $ as text
        let body = s.substring(with: m.range(at: g))
        out += g <= 2 ? "$$" + tex(body) + "$$" : "$" + tex(body.replacingOccurrences(of: "\n", with: " ")) + "$"
    }
    return out + plain(s.substring(from: at))
}

#if canImport(Textual)
// An answer's headings stay close to its text, as the box's do: a card, not a document.
struct AnswerHeading: StructuredText.HeadingStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.textual.fontScale(configuration.headingLevel <= 2 ? 1.15 : 1.05).textual.blockSpacing(.fontScaled(top: 1.1, bottom: 0.45)).fontWeight(.semibold)
    }
}
struct AnswerParser: MarkupParser {
    nonisolated init() {}
    func attributedString(for input: String) throws -> AttributedString {
        var a = try AttributedStringMarkdownParser.markdown(syntaxExtensions: [.math]).attributedString(for: answerMarkdown(input))
        while let i = a.characters.firstIndex(of: "\u{E000}") { a.characters.replaceSubrange(i...i, with: "$") }
        return a
    }
}
#endif

// An answer, a note or a chat turn: Markdown and TeX math, drawn natively. Links open through the agent, never in this window.
struct AnswerText: View {
    let text: String
    var size: CGFloat = 13.5
    var body: some View {
        #if canImport(Textual)
        StructuredText(text, parser: AnswerParser()).textual.textSelection(.enabled).textual.headingStyle(AnswerHeading()).font(.system(size: size))
        #else
        Text((try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)).font(.system(size: size)).textSelection(.enabled)
        #endif
    }
}

struct StatusDot: View {
    let status: String
    var size: CGFloat = 7
    var color: Color { ["running":.accentColor,"queued":.accentColor,"needs-you":.orange,"waiting-screen":.orange,"done":.green,"failed":.red][status] ?? .secondary }
    var body: some View {
        let breathing = AgentPanels.live.contains(status)
        // PhaseAnimator, not a repeating animation: that one would also animate every layout move of the dot, forever.
        PhaseAnimator(breathing ? [1.0, 0.4] : [1.0]) { level in
            Circle().fill(color).frame(width: size, height: size).shadow(color: breathing ? color.opacity(0.7) : .clear, radius: 4).opacity(level)
        } animation: { _ in .easeInOut(duration: status == "running" ? 0.9 : 1.2) }
    }
}

// An agent's orb: a soft glow, tinted per agent (or by its status), breathing while it works.
struct AgentOrb: View {
    let id: String
    var tint: Color? = nil
    var still = false
    @Environment(\.accessibilityReduceMotion) private var reduce
    var body: some View {
        let tint = self.tint ?? Color(hue: 0.586 + Double((Int(id.prefix(4), radix: 16) ?? 0) % 90 - 45) / 360, saturation: 0.95, brightness: 1)
        PhaseAnimator(still || reduce ? [0.92] : [0.84, 1]) { scale in   // as StatusDot: only the breathing animates
            GeometryReader { g in
                Circle().fill(RadialGradient(colors: [.white, tint, tint.opacity(0)], center: .center, startRadius: 0, endRadius: g.size.width / 2))
                    .shadow(color: tint.opacity(0.6), radius: g.size.width / 5).scaleEffect(scale).opacity(0.3 + scale * 0.7)
            }
        } animation: { _ in .easeInOut(duration: 1.6) }
    }
}

// Mail-style: agents in progress, saved agents, earlier ones and chats, each a collapsible section, with a search field on top.
struct AgentSidebar: View {
    @ObservedObject var m: AgentViewModel
    @State private var query = ""
    @State private var renaming = ""
    @State private var newName = ""
    @State private var deleting = ""
    @State private var folded = Set<String>()
    var body: some View {
        let match = { (s: String) in query.isEmpty || s.localizedCaseInsensitiveContains(query) }
        let ordered = m.rows.filter { match($0.title) }.sorted { $0.num("created") > $1.num("created") }
        let now = ordered.filter { $0.live || $0.status == "offered" }, past = ordered.filter { !($0.live || $0.status == "offered") }
        let saved = m.named.filter { match($0["name"] as? String ?? "") }, chats = m.chats.filter { match($0.title) }
        List(selection: Binding(get: { m.current?.id }, set: { m.picked = $0 ?? ""; m.composing = false; m.asked = "" })) {
            if !now.isEmpty { section("now", "In Progress") { ForEach(now) { agentRow($0) } } }
            if !saved.isEmpty { section("saved", "Saved Agents") { ForEach(saved.indices, id: \.self) { savedRow(saved[$0]) } } }
            if !past.isEmpty {
                section("past", "Earlier", menu: AnyView(Menu { Button("Clear Done") { m.command("clear", "") }; Button("Clear Failed") { m.command("clear-failed", "") } } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Clear finished agents"))) { ForEach(past) { agentRow($0) } }
            }
            if !chats.isEmpty { section("chats", "Chats") { ForEach(chats) { chatRow($0) } } }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 6) {
                HStack(spacing: 6) {
                    SearchField(text: $query).frame(height: 28)
                    Button { m.composing = true; m.asked = "" } label: { Image(systemName: "square.and.pencil").font(.system(size: 15)).frame(width: 28, height: 28) }
                        .buttonStyle(.borderless).keyboardShortcut("n").help("New Chat (⌘N)")
                }
                if !m.namedStatus.isEmpty { Text(m.namedStatus).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading) }
            }.padding(.horizontal, 10).padding(.bottom, 4)
        }
        .overlay {
            if now.isEmpty && past.isEmpty && saved.isEmpty && chats.isEmpty {
                VStack(spacing: 4) { Image(systemName: query.isEmpty ? "sparkles" : "magnifyingglass").font(.title2).foregroundStyle(.tertiary); Text(query.isEmpty ? "No agents yet" : "No matches").foregroundStyle(.secondary) }
            }
        }
    }
    func section<V: View>(_ key: String, _ title: String, menu: AnyView? = nil, @ViewBuilder _ rows: () -> V) -> some View {
        Section(isExpanded: Binding(get: { !folded.contains(key) }, set: { if $0 { folded.remove(key) } else { folded.insert(key) } })) { rows() } header: {
            HStack { Text(title); Spacer(); menu }
        }
    }
    func line(_ icon: AgentIcon, _ title: String, _ when: String, _ sub: @escaping () -> String) -> some View {
        HStack(spacing: 10) {
            icon
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                HStack(alignment: .firstTextBaseline, spacing: 6) {   // the title keeps the full width; the time sits with the detail
                    TimelineView(.periodic(from: .now, by: 1)) { _ in Text(sub()).lineLimit(1).monospacedDigit() }
                    Spacer(minLength: 0)
                    Text(when).monospacedDigit().fixedSize()
                }.font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 4)
    }
    func agentRow(_ r: AgentRow) -> some View {
        line(AgentIcon(kind: r.status), r.title, r.when) { r.subtitle }
            .tag(r.id)
            .contextMenu { if ["done","failed","stopped"].contains(r.status) { Button("Remove") { m.command("remove", r.id) } } }
    }
    func chatRow(_ r: AgentRow) -> some View {
        let last = (r.turns?.last?["a"] as? String ?? "").replacingOccurrences(of: #"[*_`#>$\\]|\[|\]\([^)]*\)"#, with: "", options: .regularExpression)
            .split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return line(AgentIcon(kind: "chat"), r.title, r.when) { last }.tag(r.id)
            .contextMenu { Button("Delete…", role: .destructive) { deleting = r.id } }
            .confirmationDialog("Delete “\(r.title)”?", isPresented: Binding(get: { deleting == r.id }, set: { if !$0 { deleting = "" } })) {
                Button("Delete", role: .destructive) { m.command("chat-delete", r.id) }
            } message: { Text("This chat will be deleted. You can’t undo this.") }
    }
    @ViewBuilder func savedRow(_ n: [String:Any]) -> some View {
        let name = n["name"] as? String ?? ""
        if renaming == name {
            TextField("Name", text: $newName).textFieldStyle(.roundedBorder)
                .onSubmit {
                    let value = newName.trimmingCharacters(in: .whitespaces)
                    if value.isEmpty { m.say("Enter a name."); return }
                    renaming = ""
                    if value == name { m.say("Name unchanged.") } else { m.post(["action":"named-rename","name":name,"newName":value]); m.say("Renaming…") }
                }
                .onExitCommand { renaming = "" }
                .onAppear { m.sideEditing = true }.onDisappear { m.sideEditing = false }
        } else {
            line(AgentIcon(kind: "saved"), name, "") { n["brief"] as? String ?? "" }
                .contextMenu { Button("Rename") { newName = name; renaming = name }; Button("Delete…", role: .destructive) { deleting = name } }
                .confirmationDialog("Delete “\(name)”?", isPresented: Binding(get: { deleting == name }, set: { if !$0 { deleting = "" } })) {
                    Button("Delete", role: .destructive) { m.post(["action":"named-delete","name":name]); m.say("Deleting…") }
                }
        }
    }
}

// A row's badge: what the agent is doing, as a tinted symbol. A working one pulses.
struct AgentIcon: View {
    let kind: String
    var body: some View {
        let (symbol, tint): (String, Color) = switch kind {
        case "running": ("sparkles", .accentColor)
        case "queued": ("clock", .accentColor)
        case "offered": ("play.fill", .accentColor)
        case "needs-you", "waiting-screen": ("hand.raised.fill", .orange)
        case "done": ("checkmark", .green)
        case "failed": ("exclamationmark.triangle.fill", .red)
        case "chat": ("text.bubble.fill", .teal)
        case "saved": ("bookmark.fill", .purple)
        default: ("stop.fill", .secondary)
        }
        Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(tint)
            .frame(width: 26, height: 26).background(tint.opacity(0.16), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .symbolEffect(.pulse, isActive: kind == "running" || kind == "queued")
    }
}

struct SearchField: NSViewRepresentable {
    @Binding var text: String
    func makeNSView(context: Context) -> NSSearchField { let f = NSSearchField(); f.placeholderString = "Search"; f.delegate = context.coordinator; return f }
    func updateNSView(_ f: NSSearchField, context: Context) { if f.stringValue != text { f.stringValue = text } }
    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        func controlTextDidChange(_ n: Notification) { text.wrappedValue = (n.object as? NSSearchField)?.stringValue ?? "" }
    }
}

struct AgentDetail: View {
    @ObservedObject var m: AgentViewModel
    @State private var draft = ""
    @State private var title = ""
    @State private var editing = ""
    @State private var hoverTitle = false
    @FocusState private var typing: Bool
    @FocusState private var naming: Bool
    var body: some View {
        let r = m.current
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if m.composing { blank }
                    else if let r { header(r); if !r.str("brief").isEmpty { Text(r.str("brief")).font(.system(size: 12.5)).foregroundStyle(.secondary).textSelection(.enabled) }; content(r) }
                    else { empty }
                }
                .frame(maxWidth: 680, alignment: .leading).padding(.horizontal, 28).padding(.top, 8).padding(.bottom, 28).frame(maxWidth: .infinity)
            }
            .id(r?.id ?? "")   // a new agent opens at its top
            .defaultScrollAnchor(r?.live == true ? .bottom : .top, for: .sizeChanges)   // live words keep the end in view
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("detail")) } action: { m.scrollFrame = $0; m.layoutMini() }
            Divider()
            followUp(r)
        }
        .coordinateSpace(.named("detail"))
        .environment(\.openURL, OpenURLAction { url in m.command("open", m.current?.id ?? "", ["target": url.absoluteString]); return .handled })
        .onExitCommand { m.post(["action":"close"]) }
        .onChange(of: r?.id ?? "", initial: true) { _, id in m.post(["action":"hover","id": m.current?.turns == nil ? id : ""]) }   // a window agent's live window follows the pick
        .onChange(of: m.composing) { if $1 { draft = ""; typing = true } }
    }
    // New Chat: a title and the composer; the first message starts its agent, which then shows here.
    var blank: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("New Chat").font(.system(size: 20, weight: .semibold))
            if m.asked.isEmpty { Text("Ask anything. Aurel works on it right here.").font(.system(size: 11.5)).foregroundStyle(.secondary) }
            else { HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Starting…") }.font(.system(size: 11.5)).foregroundStyle(.secondary) }
        }.padding(.top, 14)
    }
    var empty: some View {
        VStack(spacing: 6) { Text("No agents yet").font(.headline).foregroundStyle(.secondary); Text("Ask Aurel for something that takes a while.").foregroundStyle(.tertiary) }
            .frame(maxWidth: .infinity).padding(.top, 80)
    }
    func header(_ r: AgentRow) -> some View {
        HStack(alignment: .center, spacing: 13) {
            if r.live && r.turns == nil { AgentOrb(id: r.id).frame(width: 38, height: 38) }   // the orb shows work under way; the status dot covers the rest
            VStack(alignment: .leading, spacing: 4) {
                // Read: the title is a button that shows a pencil and a tint on hover. Edit: a real text box with a focus ring,
                // Cancel and Save. Both are inset 8 pt so the words sit exactly where the title was.
                if editing == r.id {
                    HStack(spacing: 8) {
                        TextField("Name", text: $title).textFieldStyle(.plain).font(.system(size: 20, weight: .semibold)).focused($naming)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
                            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.accentColor, lineWidth: 2))
                            .onSubmit { rename(r) }.onExitCommand { editing = "" }.onChange(of: naming) { if !$1 { rename(r) } }   // a click elsewhere saves, as in Finder
                            .onAppear { title = r.title; naming = true }
                        Button("Cancel") { editing = "" }
                        Button("Save") { rename(r) }.buttonStyle(.borderedProminent).disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }.padding(.leading, -8)
                } else {
                    Button { editing = r.id } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 7) {
                            Text(r.title).font(.system(size: 20, weight: .semibold)).lineLimit(2).multilineTextAlignment(.leading)
                            Image(systemName: "pencil").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary).opacity(hoverTitle ? 1 : 0)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(.primary.opacity(hoverTitle ? 0.07 : 0), in: RoundedRectangle(cornerRadius: 7))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).padding(.leading, -8).help("Rename")
                    .onHover { hoverTitle = $0; ($0 ? NSCursor.pointingHand : NSCursor.arrow).set() }
                    .animation(.easeOut(duration: 0.12), value: hoverTitle)
                }
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    HStack(spacing: 6) {
                        if r.turns == nil { StatusDot(status: r.status, size: 6); Text(r.word + " · " + r.time + " · Started " + r.begun) } else { Text("Started " + r.begun) }
                    }.font(.system(size: 11.5)).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                if r.status == "offered" { Button("Start") { m.command("start", r.id) }.buttonStyle(.borderedProminent) }
                if r.live { Button { m.command("stop", r.id) } label: { Label("Stop", systemImage: "stop.fill") } }
                if !r.str("directory").isEmpty { Button { m.command("reveal", r.id) } label: { Image(systemName: "folder") }.help("Show in Finder") }
            }.controlSize(.regular)
        }
    }
    func rename(_ r: AgentRow) {
        guard editing == r.id else { return }
        let value = title.trimmingCharacters(in: .whitespacesAndNewlines); editing = ""
        if !value.isEmpty, value != r.title { m.command("rename", r.id, ["title": value]) }
    }
    @ViewBuilder func content(_ r: AgentRow) -> some View {
        if let turns = r.turns {
            ForEach(turns.indices, id: \.self) { i in
                VStack(alignment: .leading, spacing: 10) { bubble(turns[i]["q"] as? String ?? ""); AnswerText(text: turns[i]["a"] as? String ?? "") }
            }
        } else {
            if r.r["target"] != nil { mini(r) }   // a window agent's live window leads the page
            if let q = r.question { approval(r, q) }
            if r.live && r.question == nil { now(r) }
            if r.status == "failed" { problem(r.state, "Retry") { m.command("start", r.id) } }
            if let need = r.r["missingConnector"] as? String, !need.isEmpty { problem("Needs \(need). Connect it in Claude, then retry.", "Connect in Claude") { m.command("connect", r.id) } }
            let things = r.things
            if !things.isEmpty { section("MADE") { VStack(spacing: 6) { ForEach(things.indices, id: \.self) { thing(r, things[$0], main: $0 == 0) } } } }
            let body = r.status == "done" ? r.answer : "", said = m.liveText[r.id] ?? ""
            if !said.isEmpty && body.isEmpty { section("WRITING…", tint: .accentColor) { AnswerText(text: agentShut(said)) } }   // an unclosed $math, **bold or `code waits, never shown as symbols
            if !body.isEmpty {
                section("RESULT") {
                    VStack(alignment: .leading, spacing: 10) {
                        AnswerText(text: body)
                        if !r.str("changes").isEmpty && !body.contains(r.str("changes")) { AnswerText(text: r.str("changes"), size: 12.5).foregroundStyle(.secondary) }
                        Text((r.num("cost") > 0 ? AgentRow.cost(r.num("cost")) + " · " : "") + r.time).font(.system(size: 11)).foregroundStyle(.tertiary).monospacedDigit()
                    }
                }
            }
            let steps = r.groups
            if !steps.isEmpty { activity(r, steps) }
        }
    }
    func bubble(_ text: String) -> some View {
        HStack { Spacer(minLength: 60); Text(text).textSelection(.enabled).padding(.horizontal, 11).padding(.vertical, 6).background(Color.accentColor.opacity(0.22), in: UnevenRoundedRectangle(cornerRadii: .init(topLeading: 12, bottomLeading: 12, bottomTrailing: 4, topTrailing: 12))) }
    }
    func section<V: View>(_ label: String, tint: Color = .secondary, @ViewBuilder _ content: () -> V) -> some View {
        VStack(alignment: .leading, spacing: 8) { Text(label).font(.system(size: 10.5, weight: .semibold)).kerning(0.3).foregroundStyle(tint); content() }
    }
    func card<V: View>(_ tint: Color, @ViewBuilder _ content: () -> V) -> some View { agentCard(tint, content) }
    func mini(_ r: AgentRow) -> some View {
        let target = r.r["target"] as? [String:Any] ?? [:]
        return RoundedRectangle(cornerRadius: 10).fill(.black.opacity(0.25)).frame(height: 132)
            .overlay { if !m.miniLive { Text(target["window"] as? String ?? target["app"] as? String ?? "Window").font(.caption).foregroundStyle(.secondary) } }
            .contentShape(Rectangle()).onTapGesture { m.command("open", r.id) }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("detail")) } action: { m.miniFrame = $0; m.layoutMini() }
            .onDisappear { m.miniFrame = .zero; m.layoutMini() }
    }
    // ↩ and esc answer the card unless a text field has the keys (Return in a field would press the default button too).
    func approval(_ r: AgentRow, _ q: [String:Any]) -> some View {
        ApprovalCard(q: q, keys: !(typing || naming || m.sideEditing)) { m.command("answer", r.id, ["answer": $0, "question": q["_a"] as Any]) }
    }
    func now(_ r: AgentRow) -> some View {
        let note = r.status == "running" && !r.str("note").isEmpty && r.str("note") == r.str("step"), plan = r.r["plan"] as? [String] ?? [], done = Int(r.num("completed"))
        return card(r.status == "needs-you" || r.status == "waiting-screen" ? .secondary : .accentColor) {
            VStack(alignment: .leading, spacing: 11) {
                if note { AnswerText(text: agentShut(r.str("note")), size: 16) } else { Text(r.state).font(.system(size: 16, weight: .medium)) }
                sources(r, Array(r.sources.suffix(6)))
                if !plan.isEmpty { HStack(spacing: 4) { ForEach(plan.indices, id: \.self) { i in Capsule().fill(i < done ? Color.accentColor : .primary.opacity(0.12)).frame(height: 3).help(plan[i]) } } }
            }
        }
    }
    func problem(_ text: String, _ action: String, _ fn: @escaping () -> Void) -> some View {
        card(.red) { HStack(spacing: 12) { Text(text).font(.system(size: 12.5)).frame(maxWidth: .infinity, alignment: .leading); Button(action, action: fn).buttonStyle(.borderedProminent) } }
    }
    func thing(_ r: AgentRow, _ t: AgentThing, main: Bool) -> some View { ThingCard(t: t, main: main) { m.command("open", r.id, ["target": t.url]) } }
    func sources(_ r: AgentRow, _ items: [[String:Any]], limit: Int = 6) -> some View { SourceChips(items: items, limit: limit) { m.command("open", r.id, ["target": $0]) } }
    func activity(_ r: AgentRow, _ steps: [AgentStep]) -> some View {
        let count = steps.reduce(0) { $0 + $1.lines.count }, sites = Set(steps.flatMap { $0.sources.compactMap { $0["url"] as? String } }).count
        let open = Binding(get: { m.folds[r.id] ?? r.live }, set: { m.folds[r.id] = $0 })
        return DisclosureGroup(isExpanded: open) {
            VStack(alignment: .leading, spacing: 0) { ForEach(steps.indices, id: \.self) { entry(r, steps[$0], $0, last: $0 == steps.count - 1) } }.padding(.top, 8)
        } label: {
            HStack(spacing: 7) {
                Text("ACTIVITY").font(.system(size: 10.5, weight: .semibold)).kerning(0.3)
                Text("\(count) step\(count == 1 ? "" : "s")" + (sites > 0 ? " · \(sites) source\(sites == 1 ? "" : "s")" : "")).font(.system(size: 10.5))
            }.foregroundStyle(.secondary).contentShape(Rectangle()).onTapGesture { open.wrappedValue.toggle() }
        }
    }
    @ViewBuilder func entry(_ r: AgentRow, _ g: AgentStep, _ i: Int, last: Bool) -> some View {
        if g.kind == "user" { bubble(g.lines.last ?? "").padding(.vertical, 5) }
        else {
            let key = r.id + ":\(i)", more = g.lines.count > 1 || g.tools.contains { !$0.isEmpty }, working = last && r.live
            HStack(alignment: .top, spacing: 9) {
                Group { if g.kind == "note" { Circle().fill(.tertiary).frame(width: 5, height: 5) } else { Image(systemName: AgentStep.symbols[g.kind] ?? "wrench.and.screwdriver").font(.system(size: 11)) } }
                    .frame(width: 23, height: 23).background(g.kind == "note" ? Color.clear : .primary.opacity(0.08), in: Circle())
                    .foregroundStyle(working ? Color.accentColor : g.kind == "made" ? .green : .secondary)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 7) {
                        if g.kind == "note" { AnswerText(text: g.lines.last ?? "", size: 12.5) } else { Text(g.lines.last ?? "").font(.system(size: 12.5)).foregroundStyle(working ? .primary : .secondary).lineLimit(1) }
                        if g.lines.count > 1 { Text("\(g.lines.count)").font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 6).padding(.vertical, 1).background(.primary.opacity(0.06), in: Capsule()) }
                        if more {
                            Button { if m.opened.contains(key) { m.opened.remove(key) } else { m.opened.insert(key) } } label: { Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).rotationEffect(.degrees(m.opened.contains(key) ? 90 : 0)) }
                                .buttonStyle(.plain).foregroundStyle(.tertiary).help("Show steps")
                        }
                    }.frame(minHeight: 23)
                    if m.opened.contains(key) {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(g.lines.indices, id: \.self) { j in (Text(g.lines[j] + " ") + Text(g.tools.indices.contains(j) ? g.tools[j] : "").font(.system(size: 10.5, design: .monospaced))).font(.system(size: 11.5)).foregroundStyle(.tertiary).textSelection(.enabled) }
                        }
                    }
                    sources(r, g.sources, limit: 5)
                }
            }.padding(.vertical, 5)
        }
    }
    func followUp(_ r: AgentRow?) -> some View {
        let off = m.composing ? !m.asked.isEmpty : r == nil || r?.turns != nil
        let send = {
            let text = draft.trimmingCharacters(in: .whitespacesAndNewlines); guard !off, !text.isEmpty else { return }
            if m.composing { m.asked = text; m.post(["action":"ask","text":text]) } else if let id = r?.id { m.command("followup", id, ["text": text]) }
            draft = ""
        }
        return HStack(spacing: 6) {
            TextField(m.composing ? "Ask anything…" : r?.live == true ? "Tell it something…" : "Ask a follow-up…", text: $draft, axis: .vertical).textFieldStyle(.plain).lineLimit(1...5).focused($typing)
                .onSubmit(send).disabled(off)
            Button(action: send) { Image(systemName: "arrow.up").font(.system(size: 12, weight: .bold)).frame(width: 26, height: 26).background(Color.accentColor.opacity(draft.isEmpty ? 0.4 : 1), in: Circle()).foregroundStyle(.white) }
                .buttonStyle(.plain).disabled(off || draft.trimmingCharacters(in: .whitespaces).isEmpty).help("Send")
        }
        .padding(.leading, 14).padding(.trailing, 5).padding(.vertical, 5)
        .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 18)).overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(typing ? Color.accentColor.opacity(0.6) : .primary.opacity(0.12), lineWidth: typing ? 1 : 0.5))
        .frame(maxWidth: 680).padding(.horizontal, 20).padding(.vertical, 12).frame(maxWidth: .infinity)
    }
}

// ── Pieces the Agent view and the shelf share ──
func agentCard<V: View>(_ tint: Color, _ content: () -> V) -> some View {
    content().padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 14)).overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(tint.opacity(0.3), lineWidth: 0.5))
}

// The ask: Allow / Don't Allow, a pick, or setup only the user can do. With `keys`, ↩ and esc answer it.
struct ApprovalCard: View {
    let q: [String:Any]
    var keys = false
    let answer: (String) -> Void
    var body: some View {
        let need = q["need"] as? String, mine = need == "page-js", connector = need == "connector", waiting = q["waiting"] as? Bool == true
        let cmd = q["cmd"] as? String ?? ""
        return agentCard(.orange) {
            VStack(alignment: .leading, spacing: 9) {
                Label { Text(q["pick"] as? String ?? q["q"] as? String ?? "Waiting for you").font(.system(size: 12.5, weight: .semibold)) } icon: { Image(systemName: need != nil ? "lock.shield" : "exclamationmark.triangle").foregroundStyle(.orange) }
                if need != nil {
                    if !cmd.isEmpty { Text(cmd).font(.system(size: 12)) }
                    Text(waiting ? (connector ? "Waiting for you to connect it…" : "Waiting for you to turn it on…") : mine ? "Aurel can change this setting itself." : connector ? "Connect it on claude.ai. The agent carries on by itself." : "macOS only lets you flip this one. Aurel shows you the switch.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                } else if !cmd.isEmpty {
                    ScrollView { Text(cmd).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 96).fixedSize(horizontal: false, vertical: true)
                }
                ViewThatFits(in: .horizontal) { HStack(spacing: 6) { buttons(need, mine, connector, waiting) }; VStack(alignment: .leading, spacing: 6) { buttons(need, mine, connector, waiting) } }
            }
        }
    }
    @ViewBuilder func buttons(_ need: String?, _ mine: Bool, _ connector: Bool, _ waiting: Bool) -> some View {
        if need != nil {
            Button(mine ? "No" : "Not now") { answer("n") }.keyboardShortcut(keys ? .cancelAction : nil)
            if !waiting { Button(mine ? "Do it" : connector ? "Connect" : "Allow") { answer("y") }.buttonStyle(.borderedProminent).keyboardShortcut(keys ? .defaultAction : nil) }
        } else if q["pick"] != nil {
            let options = q["options"] as? [String] ?? []
            ForEach(options.indices, id: \.self) { i in
                if i == 0 { Button(options[i]) { answer("0") }.buttonStyle(.borderedProminent) } else { Button(options[i]) { answer(String(i)) } }
            }
            Button("None of these") { answer("") }
        } else {
            Button("Don’t Allow") { answer("n") }.keyboardShortcut(keys ? .cancelAction : nil)
            if q["task"] != nil { Button("Always allow for this task") { answer("task") } }
            Button("Allow") { answer("y") }.buttonStyle(.borderedProminent).keyboardShortcut(keys ? .defaultAction : nil)
        }
    }
}

// One thing it made: a doc, sheet, event, file or link, with Open.
struct ThingCard: View {
    let t: AgentThing
    let main: Bool
    let open: () -> Void
    var body: some View {
        Button(action: open) {
            HStack(spacing: 11) {
                Image(systemName: AgentStep.symbols[t.kind] ?? "link").font(.system(size: 15)).frame(width: 34, height: 34)
                    .background(main ? Color.accentColor : .primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 9)).foregroundStyle(main ? .white : .primary)
                VStack(alignment: .leading, spacing: 2) { Text(t.title).font(.system(size: 12.5, weight: .semibold)).lineLimit(1); Text(t.sub).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1) }
                Spacer(minLength: 4)
                Image(systemName: "arrow.up.right").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Color.accentColor)
            }.padding(9).background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 11)).contentShape(Rectangle())
        }.buttonStyle(.plain).help(t.url)
    }
}

// Favicon chips for the pages it read; at most `limit`, then "+N". Without titles, each shows its site.
struct SourceChips: View {
    let items: [[String:Any]]
    var limit = 6
    var titles = true
    let open: (String) -> Void
    var body: some View {
        let web = items.compactMap { s -> (String, String)? in
            guard let url = s["url"] as? String, let u = URL(string: url), ["http","https"].contains(u.scheme ?? ""), u.user == nil, u.password == nil else { return nil }
            let host = agentHost(url), title = titles ? s["title"] as? String ?? "" : ""
            return (url, title.isEmpty || title == u.host ? host : title)
        }.reduce(into: [(String, String)]()) { seen, s in if !seen.contains(where: { $0.0 == s.0 }) { seen.append(s) } }
        if !web.isEmpty {
            FlowRow {
                ForEach(web.prefix(limit), id: \.0) { s in
                    Button { open(s.0) } label: {
                        HStack(spacing: 6) {
                            AsyncImage(url: URL(string: "https://" + (URL(string: s.0)?.host ?? "") + "/favicon.ico")) { $0.resizable() } placeholder: { Text(String(agentHost(s.0).prefix(1)).uppercased()).font(.system(size: 8.5, weight: .bold)) }
                                .frame(width: 14, height: 14).background(.primary.opacity(0.14)).clipShape(RoundedRectangle(cornerRadius: 4))
                            Text(s.1).lineLimit(1).frame(maxWidth: 150, alignment: .leading)
                        }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.leading, 4).padding(.trailing, 8).frame(height: 22).background(.primary.opacity(0.05), in: Capsule())
                    }.buttonStyle(.plain).help(s.0)
                }
                if web.count > limit { Text("+\(web.count - limit)").font(.system(size: 11)).foregroundStyle(.tertiary).frame(height: 22) }
            }
        }
    }
}

// ── Shelf (native) ──
// Chips in the screen corner for agents at work and just finished; the rest fold into a pill. It never takes focus:
// AgentPanels feeds it its js "shelf" calls (receive) and the pointer from its PointerView.
final class ShelfModel: ObservableObject {
    static let width: CGFloat = 260, linger = 600.0
    @Published var rows: [AgentRow] = []
    @Published var expanded = ""
    @Published var stack = ""   // "": auto, "open": all chips (a peek), "min": all folded into the pill
    @Published var hovered = ""
    @Published var near = false
    @Published var arriving = Set<String>()
    @Published var miniLive = false
    var dismissed = Set<String>(), home = "", held = "", starting = Set<String>(), rested = Set<String>(), popped = "", kept = false
    var onScreen: [String:Double] = [:], attention: [String:String] = [:], listed = false, lingering: Bool?, visible = true, previewing = ""
    var frames: [String:CGRect] = [:], orbs: [String:CGPoint] = [:], minis: [String:CGRect] = [:], thumbs: [String:CGRect] = [:]
    var dragging = false, posted: CGFloat = 0, popTimer: Timer?, shrink: DispatchWorkItem?
    var post: ([String:Any]) -> Void = { _ in }
    var onMini: (CGRect, Bool) -> Void = { _, _ in }
    lazy var clock = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.second() }
    var spring: Animation? { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.86) }

    func receive(_ call: String, _ value: Any) {
        _ = clock
        switch call {
        case "list":
            rows = (value as? [[String:Any]] ?? []).map(AgentRow.init); listed = true
            for r in rows where r.finished && onScreen[r.id] == nil { onScreen[r.id] = age(r) }
            refresh()
        case "state": if let r = value as? [String:Any] { state(AgentRow(r)) }
        case "prefs":
            let p = value as? [String:Any] ?? [:]
            dismissed = Set(p["dismissed"] as? [String] ?? []); stack = p["stack"] as? String == "min" ? "min" : ""; home = stack; refresh()
        case "expand": let id = value as? String ?? ""; popped = id; setExpanded(id); arm()   // a finish: its chip comes up open, out of the pill
        case "blur": blur()
        case "arrive":
            let id = value as? String ?? ""; arriving.insert(id); starting.insert(id); arm()
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.land(id) }   // safety only: native always lands it
        case "land": land(value as? String ?? "")
        case "visible": visible = value as? Bool ?? true
        case "resume": visible = true; previewing = ""; refresh()
        case "mini": miniLive = (value as? [String:Any])?["live"] as? Bool ?? false
        default: break
        }
    }
    func age(_ r: AgentRow) -> Double { min(Self.linger, max(0, Date().timeIntervalSince1970 - max(r.num("ended"), r.num("seenAt")))) }
    func state(_ r: AgentRow) {
        let i = rows.firstIndex { $0.id == r.id }, old = i.map { rows[$0] }
        withAnimation(spring) { if let i { rows[i] = r } else { rows.insert(r, at: 0) } }
        if !r.finished { onScreen[r.id] = nil } else if old == nil || !old!.finished || old!.num("seenAt") != r.num("seenAt") { onScreen[r.id] = age(r) }   // just finished or its card just shown: a fresh 10 minutes
        if let old, !old.finished, r.finished { dismissed.remove(r.id); if hovered == r.id { held = r.id } }   // a finish is news: it shows again, done
        let question = r.question.map { "\($0["_a"] ?? "")\($0["q"] ?? "")" }
        let ask = r.status == "needs-you" && question != nil && attention[r.id] != question
        if ask { attention[r.id] = question; dismissed.remove(r.id) }
        if r.steered { dismissed.remove(r.id); DispatchQueue.main.asyncAfter(deadline: .now() + 4.1) { [weak self] in self?.refresh() } }
        refresh()
        if ask { setExpanded(r.id); post(["action":"attention","id":r.id]) }
    }
    // On screen: working, or finished less than 10 minutes of shown time ago, and not hidden. Working first, newest on top.
    var list: [AgentRow] {
        rows.filter { ($0.live || $0.finished && (onScreen[$0.id] ?? 0) < Self.linger) && !dismissed.contains($0.id) }
            .sorted { a, b in tucked(a) != tucked(b) ? !tucked(a) : tucked(a) ? a.num("ended") > b.num("ended") : a.begin > b.begin }
    }
    func tucked(_ r: AgentRow) -> Bool { r.finished && r.id != held }   // held: it finished under the pointer, so it keeps its place until the pointer leaves
    // Which agents get a chip: minimized → none; auto with 3+ working → the newest one, else two; a peek → all.
    // The open one, a question, words just sent to it, or agents just started always show; the rest fold into the pill.
    func split(_ list: [AgentRow]) -> (shown: [AgentRow], folded: [AgentRow]) {
        let fresh = list.filter { !tucked($0) && !rested.contains($0.id) }
        let keep = Set((stack == "open" ? list : stack == "min" ? [] : Array(fresh.prefix(fresh.count > 2 ? 1 : 2))).map(\.id))
        let shown = list.filter { keep.contains($0.id) || $0.id == expanded || starting.contains($0.id) || $0.question != nil || $0.steered }
        return (shown, list.filter { r in !shown.contains { $0.id == r.id } })
    }
    func refresh() {
        let list = list
        if listed && list.isEmpty && (!stack.isEmpty || !home.isEmpty) { stack = ""; home = ""; post(["action":"stack","value":""]) }   // minimized lasts until the shelf is empty
        let finished = list.contains { $0.finished }
        if finished != lingering { lingering = finished; post(["action":"lingering","value":finished]) }   // native keeps the shelf up for them
        objectWillChange.send(); preview()
    }
    // One live window stream at a time: the open chip's, else the newest window agent on screen.
    func previewID() -> String {
        let shown = split(list).shown
        return (shown.first { $0.id == expanded && $0.r["target"] != nil } ?? shown.first { $0.r["target"] != nil && $0.live })?.id ?? ""
    }
    func preview() {
        let id = previewID()
        if id != previewing { previewing = id; post(["action":"hover","id":id]) }
        let rect = id == expanded ? minis[id] : thumbs[id]
        onMini(rect ?? .zero, id != expanded)
    }
    func command(_ action: String, _ id: String, _ more: [String:Any] = [:]) { guard !dragging else { return }; post(["action":action,"id":id].merging(more) { $1 }) }
    // First click opens a chip in place, the next opens the Agent view.
    func click(_ id: String) {
        guard !dragging else { return }
        if popped == id || starting.contains(id) { kept = true; popTimer?.invalidate() }
        expanded == id ? command("view", id) : setExpanded(id)
    }
    func setExpanded(_ id: String) {
        guard expanded != id else { return }
        if onScreen[id] != nil { onScreen[id] = 0 }
        withAnimation(spring) { expanded = id }
        refresh()
    }
    func setStack(_ value: String) {
        guard !dragging else { return }
        unpop(); hovered = ""; held = ""
        withAnimation(spring) { stack = value; if value == "min" { expanded = "" } }
        if value != "open" { home = value }
        post(["action":"stack","value":home]); refresh()
    }
    func dismiss(_ ids: [String]) {
        guard !dragging else { return }
        for id in ids { dismissed.insert(id); post(["action":"dismiss","id":id]) }
        withAnimation(spring) { if ids.contains(expanded) { expanded = "" }; refresh() }
    }
    func leave(_ id: String) { withAnimation(spring) { if expanded == id { expanded = "" }; refresh() } }
    func land(_ id: String) {
        guard arriving.remove(id) != nil else { return }
        arm(); refresh()
    }
    // A finish pops its chip open and agents starting together all show; 4 s after the last, with the pointer off the shelf, they fold back.
    // The pointer on the shelf holds them; a click on one keeps them until Esc or a click off.
    func unpop() { popTimer?.invalidate(); popped = ""; rested.formUnion(starting); starting = []; kept = false }
    func arm() {
        popTimer?.invalidate()
        guard !popped.isEmpty || !starting.isEmpty, !kept, !near else { return }
        popTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { [weak self] _ in
            guard let self else { return }
            let open = !expanded.isEmpty && expanded == popped; unpop()
            if open { setExpanded("") } else { withAnimation(spring) { self.refresh() } }
        }
    }
    // Esc or a click off the shelf: the open chip closes, a peek and just-started chips fold back.
    func blur() {
        let up = !starting.isEmpty; unpop()
        if stack == "open" { expanded = ""; setStack(home) } else if !expanded.isEmpty { setExpanded("") } else if up { withAnimation(spring) { refresh() } }
    }
    // The panel never becomes key, so hover comes from its PointerView: which chip (or the tray) is under the pointer. True: a hand cursor.
    func pointer(_ p: [Double]) -> Bool {
        let isNear = p.count == 2
        if near != isNear { near = isNear; arm() }
        var target = ""
        if isNear {
            let at = CGPoint(x: p[0], y: p[1])
            target = frames.first { $0.value.contains(at) }?.key ?? ""
            if target.isEmpty, !hovered.isEmpty, frames[hovered]?.insetBy(dx: -6, dy: -6).contains(at) == true { target = hovered }
        }
        if target != hovered { hovered = target; if target.isEmpty, !held.isEmpty { held = ""; withAnimation(spring) { refresh() } } }
        return !target.isEmpty
    }
    // A failure first: it never reads as done, nor is it cut off. Three counts: the working one drops its word (its orb leads).
    static func pillLabel(_ folded: [AgentRow], _ total: Int) -> (label: String, full: String) {
        let done = folded.filter(\.finished).count, bad = folded.filter { $0.status == "failed" }.count, work = folded.count - done
        let w = work > 0 ? (folded.count < total ? "\(work) more" : "\(work) agent\(work == 1 ? "" : "s")") : ""
        let ends = [bad > 0 ? "\(bad) failed" : nil, done > bad ? "\(done - bad) done" : nil].compactMap { $0 }.joined(separator: " · ")
        let full = !w.isEmpty ? [w, ends].filter { !$0.isEmpty }.joined(separator: " · ") : (bad > 0 ? "" : "✓ ") + ends
        return (!w.isEmpty && bad > 0 && done > bad ? "\(work) · \(ends)" : full, full)
    }
    // Where a start orb lands, in panel points from the top left: its chip's orb, else its orb in the pill, else the pill's first.
    func slot(_ id: String) -> [Double]? { (orbs[id] ?? orbs["pill"]).map { [$0.x, $0.y] } }
    // The panel grows at once and shrinks after the motion, so nothing is clipped mid-spring.
    func size(_ h: CGFloat) {
        shrink?.cancel()
        let send = DispatchWorkItem { [weak self] in self?.posted = h; self?.post(["action":"size","h":Double(h)]) }
        if h >= posted { send.perform() } else { shrink = send; DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: send) }
    }
    // The 10 minutes count only while the shelf shows and the pointer is off it.
    func second() {
        guard visible, hovered.isEmpty else { return }
        var gone = false
        for r in list where r.finished { onScreen[r.id, default: 0] += 1; if onScreen[r.id]! >= Self.linger { gone = true } }
        if gone { withAnimation(spring) { refresh() } }
    }
}

final class ShelfHost: NSHostingView<AgentShelf> { override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true } }   // a click acts, never just focuses

struct AgentShelf: View {
    @ObservedObject var s: ShelfModel
    var body: some View {
        let list = s.list, (shown, folded) = s.split(list), finished = list.contains { $0.finished }
        VStack(alignment: .trailing, spacing: 6) {
            if !shown.isEmpty {
                round("chevron.up", "Minimize all agents") { s.setStack("min") }.opacity(s.near ? 1 : 0)
            }
            ForEach(shown) { ShelfChip(s: s, r: $0).transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: -6)), removal: .opacity.combined(with: .scale(scale: 0.92)))) }
            if !folded.isEmpty || finished {
                HStack(spacing: 4) {
                    if finished { round("xmark", "Hide all done (they stay in Agents)") { s.dismiss(list.filter(\.finished).map(\.id)) }.opacity(s.near ? 1 : 0) }
                    if !folded.isEmpty { pill(folded, list.count) }
                }
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("shelf")) } action: { s.frames["tray"] = $0 }
            }
        }
        .padding(4).frame(width: ShelfModel.width, alignment: .trailing)
        .fixedSize(horizontal: false, vertical: true)   // its own height, not the panel's: the panel follows it
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { s.size($0) }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .coordinateSpace(.named("shelf"))
    }
    func round(_ symbol: String, _ help: String, _ act: @escaping () -> Void) -> some View {
        Button(action: act) { Image(systemName: symbol).font(.system(size: 9, weight: .bold)).frame(width: 24, height: 20).background(.regularMaterial, in: Capsule()).overlay(Capsule().strokeBorder(.primary.opacity(0.12), lineWidth: 0.5)) }
            .buttonStyle(.plain).foregroundStyle(.secondary).help(help).animation(.easeOut(duration: 0.15), value: s.near)
    }
    // One orb per state, never per agent: working, done, needs you or failed.
    func pill(_ folded: [AgentRow], _ total: Int) -> some View {
        let groups: [(AgentRow) -> Bool] = [{ $0.live && $0.status != "needs-you" }, { $0.status == "done" }, { $0.status == "needs-you" || $0.status == "failed" }]
        let heads = groups.compactMap { g in folded.first(where: g) }, (label, full) = ShelfModel.pillLabel(folded, total)
        return Button { s.setStack("open") } label: {
            HStack(spacing: 7) {
                HStack(spacing: 2) {
                    ForEach(heads) { r in
                        AgentOrb(id: r.id, tint: r.orbTint, still: !r.live).frame(width: 20, height: 20)
                            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("shelf")) } action: { f in s.orbs[r.id] = CGPoint(x: f.midX, y: f.midY); if r.id == heads.first?.id { s.orbs["pill"] = s.orbs[r.id] } }
                    }
                }
                Text(label).font(.system(size: 11, weight: .semibold)).lineLimit(1)
            }
            .padding(.leading, 7).padding(.trailing, 11).frame(height: 36)
            .background(.regularMaterial, in: Capsule()).overlay(Capsule().strokeBorder(.primary.opacity(0.11), lineWidth: 0.5)).shadow(color: .black.opacity(0.28), radius: 9, y: 6)
        }.buttonStyle(.plain).help(full + ". Show agents")
    }
}

struct ShelfChip: View {
    @ObservedObject var s: ShelfModel
    let r: AgentRow
    var body: some View {
        let open = s.expanded == r.id, hover = s.hovered == r.id
        VStack(alignment: .leading, spacing: 0) {
            head(hover)
            if open { inside.transition(.opacity.combined(with: .offset(y: -4))) }
        }
        .frame(width: ShelfModel.width - 8, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(alignment: .bottom) { progress }
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(r.steered ? Color.accentColor.opacity(0.7) : .primary.opacity(0.11), lineWidth: r.steered ? 1 : 0.5))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: r.steered ? Color.accentColor.opacity(0.3) : .black.opacity(0.28), radius: r.steered ? 6 : 9, y: r.steered ? 0 : 6)
        .opacity(s.arriving.contains(r.id) ? 0 : r.finished && !hover ? 0.85 : 1)
        .contentShape(Rectangle()).onTapGesture { s.click(r.id) }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("shelf")) } action: { s.frames[r.id] = $0 }
        .help(r.title + " · " + r.time)
    }
    func head(_ hover: Bool) -> some View {
        HStack(spacing: 8) {
            Group {
                if let target = r.r["target"] as? [String:Any] {   // a window agent shows its live window where the orb was; the native stream sits over this tile
                    RoundedRectangle(cornerRadius: 7).fill(.black).frame(width: 40, height: 28)
                        .overlay { Text(String((target["app"] as? String ?? "W").prefix(1))).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary) }
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("shelf")) } action: { s.thumbs[r.id] = $0; s.preview() }
                } else {
                    AgentOrb(id: r.id, tint: r.orbTint, still: !r.live).frame(width: 28, height: 28)
                }
            }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("shelf")) } action: { s.orbs[r.id] = CGPoint(x: $0.midX, y: $0.midY) }
            VStack(alignment: .leading, spacing: 1) {
                Text(r.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(r.steered ? r.steerAck : r.state).font(.system(size: 11)).lineLimit(1)
                        .foregroundStyle(r.steered ? Color.accentColor : r.status == "needs-you" ? .orange : r.status == "failed" ? .red : .secondary)
                }
            }
            Spacer(minLength: 0)
            ZStack {
                if hover || s.near {
                    Button { s.dismiss([r.id]) } label: { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).frame(width: 22, height: 22).background(.primary.opacity(0.09), in: Circle()) }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help(r.live ? "Hide (keeps working)" : "Hide (stays in Agents)")
                } else if r.status == "done" {
                    Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.green).frame(width: 18, height: 18).background(.green.opacity(0.16), in: Circle())
                } else if ["needs-you","waiting-screen","failed"].contains(r.status) {
                    StatusDot(status: r.status)
                }
            }.frame(width: 22)
        }
        .padding(.leading, 6).padding(.trailing, 9).frame(height: 44)
    }
    var inside: some View {
        let live = r.live
        return VStack(alignment: .leading, spacing: 10) {
            if r.status != "done" { SourceChips(items: Array(r.sources.suffix(3)), limit: 3, titles: false) { s.command("open", r.id, ["target": $0]) } }
            let steps = Array((r.r["steps"] as? [String] ?? []).suffix(3))
            if !steps.isEmpty && (r.status == "running" || r.status == "queued") {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(steps.indices, id: \.self) { i in
                        Label { Text(steps[i]).lineLimit(1) } icon: { Image(systemName: steps[i].hasPrefix("Search") ? "magnifyingglass" : steps[i].hasPrefix("Reading") ? "globe" : "terminal").font(.system(size: 10)) }
                            .font(.system(size: 11)).foregroundStyle(i == steps.count - 1 ? .secondary : .tertiary)
                    }
                }
            }
            if let target = r.r["target"] as? [String:Any] {
                RoundedRectangle(cornerRadius: 10).fill(.black.opacity(0.25)).frame(height: 132)
                    .overlay { if !(s.miniLive && s.previewing == r.id) { Text(target["window"] as? String ?? target["app"] as? String ?? "Window").font(.caption).foregroundStyle(.secondary) } }
                    .contentShape(Rectangle()).onTapGesture { s.command("open", r.id) }
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("shelf")) } action: { s.minis[r.id] = $0; s.preview() }
            }
            if let q = r.question { ApprovalCard(q: q) { s.command("answer", r.id, ["answer": $0, "question": q["_a"] as Any]) }.controlSize(.small).onTapGesture {} }
            if r.status == "done" {
                let said = r.str("summary").isEmpty ? r.answer : r.str("summary")
                if !said.isEmpty { AnswerText(text: said, size: 13) }
                let things = r.things
                ForEach(things.indices, id: \.self) { i in ThingCard(t: things[i], main: i == 0) { s.command("open", r.id, ["target": things[i].url]) } }
            }
            HStack(spacing: 6) {
                if live { Button { s.command("stop", r.id) } label: { Label("Stop", systemImage: "stop.fill") } }
                if r.status == "failed" { Button("Retry") { s.command("start", r.id) }.buttonStyle(.borderedProminent) }
                if !(r.r["missingConnector"] as? String ?? "").isEmpty { Button("Connect in Claude") { s.command("connect", r.id) }.buttonStyle(.borderedProminent) }
                if live { Button("Open") { s.command("view", r.id) } } else { Button("Open") { s.command("view", r.id) }.buttonStyle(.borderedProminent) }
                Spacer(minLength: 0)
                TimelineView(.periodic(from: .now, by: 1)) { _ in Text(r.time).font(.system(size: 10.5)).foregroundStyle(.tertiary).monospacedDigit() }
            }.controlSize(.small)
        }
        .padding(.horizontal, 12).padding(.top, 2).padding(.bottom, 12)
        .environment(\.openURL, OpenURLAction { url in s.command("open", r.id, ["target": url.absoluteString]); return .handled })   // an answer's links open through the agent
    }
    @ViewBuilder var progress: some View {
        let plan = r.r["plan"] as? [String] ?? []
        if !plan.isEmpty && r.live {
            GeometryReader { g in Capsule().fill(Color.accentColor).frame(width: g.size.width * min(1, r.num("completed") / Double(plan.count))).animation(.spring(response: 0.5), value: r.num("completed")) }
                .frame(height: 2).padding(.horizontal, 14)
        }
    }
}

// Chips that wrap onto the next line.
struct FlowRow: Layout {
    var spacing: CGFloat = 5
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(proposal.width ?? .infinity, subviews)
        return CGSize(width: rows.map { $0.width }.max() ?? 0, height: rows.last.map { $0.y + $0.height } ?? 0)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(bounds.width, subviews) { for (i, x) in row.items { subviews[i].place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + row.y), proposal: .unspecified) } }
    }
    func arrange(_ width: CGFloat, _ subviews: Subviews) -> [(items: [(Int, CGFloat)], width: CGFloat, y: CGFloat, height: CGFloat)] {
        var rows: [(items: [(Int, CGFloat)], width: CGFloat, y: CGFloat, height: CGFloat)] = [], x: CGFloat = 0, y: CGFloat = 0, h: CGFloat = 0, items: [(Int, CGFloat)] = []
        for (i, v) in subviews.enumerated() {
            let size = v.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { rows.append((items, x - spacing, y, h)); y += h + spacing; x = 0; h = 0; items = [] }
            items.append((i, x)); x += size.width + spacing; h = max(h, size.height)
        }
        if !items.isEmpty { rows.append((items, x - spacing, y, h)) }
        return rows
    }
}

// launchd writes one ID when a routine is due. A file event wakes the existing agent supervisor; no timer polls.
final class RoutineWake {
    let path = (Prefs.path as NSString).deletingLastPathComponent + "/routine-queue.jsonl"
    var source: DispatchSourceFileSystemObject?, draining = false, pending = false
    init() {
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath:path) { FileManager.default.createFile(atPath:path, contents:Data(), attributes:[.posixPermissions:0o600]) }
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        source = DispatchSource.makeFileSystemObjectSource(fileDescriptor:fd, eventMask:[.write,.rename,.delete], queue:.main)
        source?.setEventHandler { [weak self] in self?.changed() }
        source?.setCancelHandler { close(fd) }
        source?.resume()
        DispatchQueue.main.async { [weak self] in self?.changed() }
    }
    func changed() { pending = true; drain() }
    func drain() {
        guard !draining else { return }
        draining = true; pending = false
        DispatchQueue.global().async { [weak self] in
            let p = py(["--routine-pop"]), out = Pipe(); p.standardOutput = out
            try? p.run(); let data = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
            let ids = (try? JSONSerialization.jsonObject(with:data)) as? [String] ?? []
            DispatchQueue.main.async {
                guard let self else { return }
                ids.forEach { agentsUI.send(["action":"routine","id":$0]) }
                self.draining = false
                if self.pending { self.drain() }
            }
        }
    }
}

// First-run window (Onboarding.swift draws it): welcome, then each macOS permission with an Allow button, then how to use it.
// Shows until finished once; to see it again: defaults delete com.aurel.app onboarded, then restart the app.
final class Onboarding: NSObject, NSWindowDelegate {
    var win: NSWindow?, model: OnboardingModel?, timer: Timer?   // the content is OnboardingModel and its view (Onboarding.swift)
    var motion: NSObjectProtocol?
    func ob(_ call: String, _ args: [Any]) { model?.receive(call, args) }   // Settings' recorder speaks to setup through this
    var checkingPlan = false, setupShown = false
    var screenInitiallyGranted = false, screenGrantedDuringSetup = false
    let pane = "x-apple.systempreferences:com.apple.preference.security?Privacy_"
    let permissionHelp = PermissionHelp()

    func open(automatic: Bool = false) {
        if automatic && setupShown { return }
        setupShown = true   // closing setup is a choice; repeated failed asks must not reopen it
        guard win == nil else { if let win { Dock.show(win) }; return }
        screenInitiallyGranted = CGPreflightScreenCaptureAccess(); screenGrantedDuringSetup = false
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 640),
                         styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        applySharing(w)
        w.titlebarAppearsTransparent = true; w.titleVisibility = .hidden; w.isMovableByWindowBackground = true
        w.isReleasedWhenClosed = false; w.delegate = self
        let bg = NSVisualEffectView(frame: w.contentRect(forFrameRect: w.frame))
        bg.material = .underWindowBackground; bg.blendingMode = .behindWindow; bg.state = .active
        let m = OnboardingModel(); m.post = { [weak self] in self?.handle($0) }
        let v = NSHostingView(rootView: OnboardingView(m: m))
        v.frame = NSRect(x: 0, y: 0, width: 640, height: 612)   // top 28 pt stays draggable
        bg.addSubview(v); w.contentView = bg
        win = w; model = m
        motion = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak m] _ in
            m?.receive("motion", NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)   // Reduce Motion while setup is open: the previews snap to their last frame
        }
        m.go(automatic ? "perms" : "welcome")   // a sign-in or install problem opens at the Claude row, not the welcome
        w.center(); Dock.show(w)
        var tick = 0
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self, weak w] _ in   // keys 20×/s, permissions 1×/s
            guard let self else { return }
            guard w?.occlusionState.contains(.visible) == true else { tick = 0; return }   // minimized or covered: no polling; back in view, everything refreshes at once
            call("ob.keys", shortcutModifierLabel(NSEvent.modifierFlags))
            tick += 1
            if tick % 20 == 1 { push() }
            if tick % 100 == 1 { checkPlan() }   // every 5 s: it starts Claude Code, too slow for every second
        }
    }

    // Which permissions are on, sent to the page every second (System Settings changes them behind our back).
    func push() {
        DispatchQueue.global().async { [weak self] in
            let s = Onboarding.perms()
            DispatchQueue.main.async {
                if self?.screenInitiallyGranted == false, s["screen"] == true { self?.screenGrantedDuringSetup = true }
                self?.call("ob.set", s)
                self?.call("ob.mode", Prefs.str("talkMode") == "toggle")
                self?.call("ob.prefs", ["draw": Prefs.bool("draw"), "routing": Prefs.str("routing"), "hotkeyLabel": Prefs.str("hotkeyLabel"), "safe": Prefs.bool("safe"),
                                        "dictateMode": Prefs.str("dictateMode"), "dictateHotkeyLabel": Prefs.str("dictateHotkeyLabel"), "globeTaken": globeKeyTaken()])
            }
        }
    }

    static func perms() -> [String: Bool] {
        ["mic": AVCaptureDevice.authorizationStatus(for: .audio) == .authorized, "speech": SFSpeechRecognizer.authorizationStatus() == .authorized,
         "ax": AXIsProcessTrusted(), "screen": CGPreflightScreenCaptureAccess(), "auto": Apps.statuses(["com.apple.systemevents"])["com.apple.systemevents"] == "allowed",
         "calendar": EKEventStore.authorizationStatus(for: .event) == .fullAccess, "tools": Prefs.bool("agentUserTools"),
         "chrome": Prefs.bool("pageJS") || NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome") == nil]   // no Chrome: nothing to turn on   // a live check fails while System Events is quit, so fall back to what was granted
    }

    // Claude Code installed, signed in, on a paid plan? (aurel.py --check)
    static func plan(_ done: @escaping ([String: Any]) -> Void) {
        DispatchQueue.global().async {
            let p = py(["--check"]), out = Pipe(); p.standardOutput = out
            try? p.run(); p.waitUntilExit()
            let j = (try? JSONSerialization.jsonObject(with: out.fileHandleForReading.readDataToEndOfFile())) as? [String: Any]
            DispatchQueue.main.async { done(j ?? ["ok": false, "need": "install", "text": "Could not run Aurel’s helper (python3 missing?)."]) }
        }
    }

    func checkPlan() {
        guard !checkingPlan else { return }
        checkingPlan = true
        Onboarding.plan { [weak self] c in
            self?.checkingPlan = false
            self?.call("ob.plan", c)
        }
    }

    // The plan row's button: install the AI client, sign in, or upgrade, in a Terminal window the user can watch.
    func fixPlan() {
        Onboarding.plan { [weak self] c in
            let need = c["need"] as? String ?? ""
            if need.isEmpty, c["ok"] as? Bool == false { Aurel.settings.open(); return }
            if need == "download" { Aurel.settings.open(tab: "brain"); return }   // Local: its model downloads in Settings
            if need == "upgrade" { NSWorkspace.shared.open(URL(string: "https://claude.ai/upgrade")!); return }
            let cmd = need == "install"
                ? "curl -fsSL https://claude.ai/install.sh | bash && ~/.local/bin/claude auth login"
                : "claude auth login"
            let f = NSTemporaryDirectory() + "aurel-claude.command"
            try? "#!/bin/zsh\nexport PATH=\"$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH\"\necho 'Aurel: setting up Claude Code'\n\(cmd)\necho; echo 'Done. You can close this window.'\n".write(toFile: f, atomically: true, encoding: .utf8)
            chmod(f, 0o755)
            NSWorkspace.shared.open(URL(fileURLWithPath: f))
            self?.checkPlan()
        }
    }

    func tried() { model?.receive("tried", []) }

    // Open the exact privacy pane and point at the switch: Aurel's own row, or an app's row under Aurel (Automation).
    func settings(_ p: String, point label: String = Onboarding.name) {
        guard NSWorkspace.shared.open(URL(string: pane + p)!) else { return }
        help(p, point: label)
        Onboarding.pointSwitch(label, under: label == Onboarding.name ? nil : Onboarding.name)
    }
    func help(_ p: String, point label: String = Onboarding.name) {
        permissionHelp.show(drag: p == "Accessibility" || p == "ScreenCapture", target: label == Onboarding.name ? "Aurel" : "\(label) under Aurel") {
            if p == "Automation", label != Onboarding.name { return Onboarding.granted("automation", app: label) }
            let key = ["Accessibility": "ax", "ScreenCapture": "screen", "Microphone": "mic", "SpeechRecognition": "speech", "Calendars": "calendar", "Automation": "auto"][p] ?? ""
            return Onboarding.perms()[key] == true
        }
    }
    static let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Aurel"

    // Show, don't tell: once the pane is up, ring the switch on the row named `label` (below `under`, when given).
    // Reading System Settings needs Accessibility; without it the pane still opens and the card says what to flip.
    static func pointSwitch(_ label: String, under: String? = nil) {
        DispatchQueue.global().async {
            for _ in 0..<16 {
                Thread.sleep(forTimeInterval: 0.5)   // the pane draws its list a moment after it opens
                guard AXIsProcessTrusted(), let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systempreferences").first else { continue }
                var queue = [AXUIElementCreateApplication(app.processIdentifier)], i = 0, texts: [CGRect] = [], switches: [CGRect] = [], top = -CGFloat.greatestFiniteMagnitude
                while i < queue.count && i < 4000 {
                    let e = queue[i]; i += 1
                    let role = Hands.attribute(e, kAXRoleAttribute) as? String ?? ""
                    if role == "AXStaticText", let v = Hands.attribute(e, kAXValueAttribute) as? String {
                        if v == label { texts.append(Hands.frame(e)) } else if v == under { top = max(top, Hands.frame(e).minY) }
                    }
                    if role == "AXCheckBox" || role == "AXSwitch" { switches.append(Hands.frame(e)) }
                    queue += Hands.children(e)
                }
                guard let row = texts.filter({ $0.minY > top && $0.width > 0 }).min(by: { $0.minY < $1.minY }),
                      let sw = switches.filter({ abs($0.midY - row.midY) < 16 && $0.minX > row.maxX }).min(by: { $0.minX > $1.minX }) else { continue }
                DispatchQueue.main.async { pointAt("@ \(sw.midX) \(sw.midY)") }
                return
            }
        }
    }

    static func bundle(_ app: String) -> String? {
        NSWorkspace.shared.runningApplications.first { $0.localizedName == app }?.bundleIdentifier
            ?? NSWorkspace.shared.fullPath(forApplication: app).flatMap { Bundle(path: $0)?.bundleIdentifier }
    }

    // An agent's "needs you" kinds (aurel.py NEEDS), checked live while its card waits.
    static func granted(_ need: String, app: String) -> Bool {
        if need == "automation" { return bundle(app).map { Apps.check($0, ask: false) == noErr } ?? false }
        return perms()[["accessibility": "ax", "screen": "screen", "microphone": "mic", "calendar": "calendar"][need] ?? ""] ?? false
    }

    // Enable All: Aurel's own settings at once, then each macOS switch in turn, opened and pointed at; what is on is skipped.
    var walk: [String] = [], walkTimer: Timer?, walkSince = Date()
    func enableAll(connected: Bool) {
        grant("tools")
        let p = Onboarding.perms()
        walk = ["ax", "auto", "chrome", "screen", "calendar"].filter { p[$0] != true } + (connected ? [] : ["connectors"])   // page reading needs the first two
        if walk.isEmpty { Aurel.settings.send("notice", ["text": "Everything is already on."]) }   // a click must always answer
        step()
        walkTimer?.invalidate()
        walkTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] t in
            guard let self, let id = walk.first else { t.invalidate(); return }
            DispatchQueue.global().async {
                let on = Onboarding.perms()[id] == true
                DispatchQueue.main.async {   // on, or two minutes without it: the next one
                    if self.walk.first == id, on || Date().timeIntervalSince(self.walkSince) > 120 { self.walk.removeFirst(); self.step() }
                }
            }
        }
    }
    func step() {
        let id = walk.first ?? ""; walkSince = Date()
        call("ob.walk", id); Aurel.settings.send("walk", id)
        switch id {
        case "": break
        case "auto":   // System Events, which page reading and app scripting go through. Apps.allow opens it first: macOS can't ask about an app that isn't running.
            Apps.job += 1; let me = Apps.job
            Apps.q.async {
                Apps.current = me
                Apps.allow(["com.apple.systemevents"]) { _, s in if s == "blocked" || s == "new" { DispatchQueue.main.async { self.settings("Automation", point: "System Events") } } }
            }
        case "connectors": grant(id); walk.removeAll(); step()   // signing in happens on claude.ai; its row updates when Settings or setup opens again
        default: grant(id)
        }
    }
    func call(_ f: String, _ v: Any) { model?.receive(f.hasPrefix("ob.") ? String(f.dropFirst(3)) : f, v) }

    // The user's claude.ai connectors (aurel.py --connectors): {connected: [names], signin: [names]}. Slow (it checks each one), so once per open.
    static func connectors(_ done: @escaping ([String: Any]) -> Void) {
        DispatchQueue.global().async {
            let p = py(["--connectors"]), out = Pipe(); p.standardOutput = out
            try? p.run(); p.waitUntilExit()
            let j = (try? JSONSerialization.jsonObject(with: out.fileHandleForReading.readDataToEndOfFile())) as? [String: Any]
            DispatchQueue.main.async { done(j ?? ["connected": [], "signin": []]) }
        }
    }

    func allow(_ need: String, app: String) {
        switch need {
        case "accessibility": grant("ax")
        case "screen": grant("screen")
        case "microphone": grant("mic")
        case "calendar": grant("calendar")
        case "automation":   // macOS's own prompt if it never asked; its switch under Aurel once it said no
            guard let id = Onboarding.bundle(app) else { return settings("Automation", point: app) }
            DispatchQueue.global().async { if Apps.check(id, ask: true) != noErr { DispatchQueue.main.async { self.settings("Automation", point: app) } } }
        default: break
        }
    }

    func handle(_ b: [String: String]) {
        if b["do"] == "done" { return finish() }
        if b["do"] == "enableAll" { return enableAll(connected: b["connected"] == "true") }
        if b["do"] == "provider", let c = b["client"], ["local", "claude"].contains(c) {   // the plan row's Change provider sheet
            Aurel.settings.apply("client", c)
            Aurel.settings.push(); return checkPlan()
        }
        if b["do"] == "connectors" { return Onboarding.connectors { [weak self] c in self?.call("ob.connectors", c) } }
        if b["do"] == "set", let k = b["k"], let v = b["v"] {   // the feature pages' switches and choices
            let choices = ["routing": ["cheapest", "balanced", "capable"], "dictateMode": ["verbatim", "cleanup"]]
            if ["draw", "improve"].contains(k) { Aurel.settings.apply(k, v == "true") } else if choices[k]?.contains(v) == true { Aurel.settings.apply(k, v) } else { return }
            Aurel.settings.push(); return push()
        }
        if b["do"] == "recordDictate" { return Aurel.settings.record("dictate") { [weak self] call, args in self?.ob(call, args) } }
        if let d = b["do"], ["cancelRecord", "clearDictate", "globeKey"].contains(d) { Aurel.settings.handle(["do": d]); return push() }
        grant(b["id"] ?? "")
    }

    // A permission's Allow button, from setup or Settings. One click shows one thing: macOS's own box the first time
    // (its button lands on the right list), System Settings once macOS won't ask again. Both at once confused people.
    func grant(_ id: String) {
        switch id {
        case "mic":
            if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined { AVCaptureDevice.requestAccess(for: .audio) { _ in } }
            else { settings("Microphone") }
        case "speech":
            if SFSpeechRecognizer.authorizationStatus() == .notDetermined { SFSpeechRecognizer.requestAuthorization { _ in } }
            else { settings("SpeechRecognition") }
        case "ax":
            if UserDefaults.standard.bool(forKey: "askedAX") { if !AXIsProcessTrusted() { settings("Accessibility") } }
            else { UserDefaults.standard.set(true, forKey: "askedAX"); if !AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary) { help("Accessibility") } }
        case "claude":
            fixPlan()
        case "connectors": NSWorkspace.shared.open(URL(string: "https://claude.ai/settings/connectors")!)
        case "tools": Aurel.settings.apply("agentUserTools", true); Aurel.settings.push()
        case "calendar":
            if EKEventStore.authorizationStatus(for: .event) == .notDetermined { calendar.requestFullAccessToEvents { _, _ in } }
            else { settings("Calendars") }
        case "screen":
            // First click: only macOS's own prompt (its button lands on the right list). Opening Settings at the
            // same time put people in the wrong section; later clicks, when macOS won't prompt again, open Settings.
            if UserDefaults.standard.bool(forKey: "askedScreen") { if !CGPreflightScreenCaptureAccess() { settings("ScreenCapture") } }
            else { UserDefaults.standard.set(true, forKey: "askedScreen"); if CGRequestScreenCaptureAccess() { screenGrantedDuringSetup = true } else { help("ScreenCapture") } }
        case "auto":
            Aurel.settings.open(tab: "apps")
        case "chrome":   // clicks Chrome's View > Developer > Allow JavaScript from Apple Events; Aurel keeps it on after this OK
            DispatchQueue.global().async {
                let p = py(["--allow-js"]); try? p.run(); p.waitUntilExit()
                if p.terminationStatus == 0 { DispatchQueue.main.async { Prefs.set("pageJS", true) } }
            }
        default: break
        }
    }

    // Screen Recording only takes effect after a relaunch; launchd (KeepAlive) starts us again right away.
    func finish() {
        UserDefaults.standard.set(true, forKey: "onboarded")
        let relaunch = screenGrantedDuringSetup
        win?.close()
        if relaunch { relaunchSoon() }
    }

    func windowDidResignKey(_ n: Notification) { if Aurel.settings.echo != nil { Aurel.settings.done(nil) } }   // keys typed elsewhere must not become the shortcut

    func windowWillClose(_ n: Notification) {
        permissionHelp.close()
        if Aurel.settings.echo != nil { Aurel.settings.done(nil) }   // closed mid-recording: keep the old shortcut
        timer?.invalidate(); timer = nil
        if let motion { NSWorkspace.shared.notificationCenter.removeObserver(motion); self.motion = nil }
        walkTimer?.invalidate(); walkTimer = nil   // closing setup cancels Enable All: no more Settings panes open later
        if !walk.isEmpty { walk = []; Aurel.settings.send("walk", "") }
        model = nil; win = nil
    }
}

final class PermissionIcon: NSImageView, NSDraggingSource {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {}   // receive mouseDragged without NSImageView's image-only drag
    override func mouseDragged(with event: NSEvent) {
        let item = NSDraggingItem(pasteboardWriter: Bundle.main.bundleURL as NSURL)
        item.setDraggingFrame(bounds, contents: image)
        beginDraggingSession(with: [item], event: event, source: self)
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
}

// The helper watches window metadata, so it works before Accessibility or Screen Recording is allowed.
final class PermissionHelp: NSObject, NSWindowDelegate {
    var panel: NSPanel?, timer: Timer?
    func show(drag: Bool, target: String, granted: @escaping () -> Bool) {
        close()
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        let w = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 110),
                        styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
        applySharing(w)
        w.title = "Allow Aurel"; w.level = .floating; w.hidesOnDeactivate = false
        w.isReleasedWhenClosed = false; w.delegate = self
        let bg = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 360, height: 110))
        bg.material = .popover; bg.state = .active
        let icon = drag ? PermissionIcon(frame: NSRect(x: 16, y: 30, width: 56, height: 56)) : NSImageView(frame: NSRect(x: 16, y: 30, width: 56, height: 56))
        icon.image = NSWorkspace.shared.icon(forFile: Bundle.main.bundleURL.path)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.setAccessibilityLabel(drag ? "Drag Aurel into System Settings" : "Aurel")
        let text = NSTextField(wrappingLabelWithString: drag
            ? "Drag Aurel into the list, then turn it on.\nYou can also use Add (+) to choose Aurel."
            : "Turn on \(target) in the list.\nIf it’s missing, return to setup and click Allow to request access first.")
        text.frame = NSRect(x: 86, y: 14, width: 258, height: 82)
        text.font = .systemFont(ofSize: 13)
        bg.addSubview(icon); bg.addSubview(text); w.contentView = bg; panel = w
        var seen = false, checking = false
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self, weak w] _ in
            guard let self, let w else { return }
            if !checking {
                checking = true
                DispatchQueue.global().async {
                    let allowed = granted()
                    DispatchQueue.main.async {
                        checking = false
                        if self.panel === w, allowed { self.close() }
                    }
                }
            }
            let pid = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systempreferences").first?.processIdentifier
            let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
            let frame = windows.first { ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid && ($0[kCGWindowLayer as String] as? Int) == 0 }.flatMap { MiniScreen.bounds($0) }
            guard let frame, frame.width > 100, frame.height > 100 else {
                if seen { close() }
                return
            }
            if !seen {
                seen = true
                let top = NSScreen.screens.first?.frame.maxY ?? 0
                let f = NSRect(x: frame.midX - w.frame.width / 2, y: top - frame.maxY - w.frame.height - 8, width: w.frame.width, height: w.frame.height)
                let screen = NSScreen.screens.first { $0.frame.contains(NSPoint(x: f.midX, y: top - frame.midY)) } ?? NSScreen.main
                if let screen { w.setFrame(PanelFrame.clamp(f, screen.visibleFrame), display: false) }
                w.orderFrontRegardless()
            }
        }
    }
    func close() { timer?.invalidate(); timer = nil; panel?.close(); panel = nil }
    func windowWillClose(_ n: Notification) { timer?.invalidate(); timer = nil; panel = nil }
}

// `Aurel --look <screen #> <out.jpg> [window id]` (aurel.py --look): the screen without Aurel's own box on it, 1280 px wide.
// With a window id, that window's own capture is painted where it sits, so it shows (and its picture spots click) even when covered or not key.
if [4, 5].contains(CommandLine.arguments.count), CommandLine.arguments[1] == "--look" {
    let a = CommandLine.arguments, done = DispatchSemaphore(value: 0), windowID = a.count == 5 ? UInt32(a[4]) : nil
    let scr = NSScreen.screens[max(0, min((Int(a[2]) ?? 1) - 1, NSScreen.screens.count - 1))]
    let id = scr.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? CGMainDisplayID()
    _ = NSApplication.shared   // ScreenCaptureKit needs a window-server connection; without it the fallback screencapture shows the box
    Task {
        defer { done.signal() }
        guard let all = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: windowID == nil),
              let d = all.displays.first(where: { $0.displayID == id }) ?? all.displays.first else { return }
        // Every Aurel window (box, step card, drawings): the model sees the real screen and so draws on it, not on the box
        let mine = all.windows.filter { $0.owningApplication?.bundleIdentifier == Bundle.main.bundleIdentifier }
        let cfg = SCStreamConfiguration()
        cfg.width = 1280; cfg.height = Int(1280 * Double(d.height) / Double(d.width))
        guard var img = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: d, excludingWindows: mine), configuration: cfg) else { return }
        if let w = all.windows.first(where: { $0.windowID == windowID }) {
            let spot = MiniScreen.paintRect(w.frame, display: d.frame, pictureHeight: img.height)
            let wcfg = SCStreamConfiguration(); wcfg.width = max(1, Int(spot.width)); wcfg.height = max(1, Int(spot.height))
            if let shot = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: w), configuration: wcfg),
               let c = CGContext(data: nil, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                c.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height)); c.draw(shot, in: spot)
                if let painted = c.makeImage() { img = painted; print("window") }
            }
        }
        guard let jpg = NSBitmapImageRep(cgImage: img).representation(using: .jpeg, properties: [.compressionFactor: 0.7]) else { return }
        try? jpg.write(to: URL(fileURLWithPath: a[3]))
    }
    done.wait()
    exit(FileManager.default.fileExists(atPath: a[3]) ? 0 : 1)
}

// `Aurel --text <app> [title words]` (aurel.py --watch): the text in that app's window, read on this Mac, even when covered.
if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--text" {
    let a = CommandLine.arguments, words = a.count > 3 ? a[3].lowercased() : "", done = DispatchSemaphore(value: 0)
    var found = false
    _ = NSApplication.shared   // ScreenCaptureKit needs a window-server connection
    Task {
        defer { done.signal() }
        guard let all = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false) else { return }
        // apps keep hidden helper windows: real ones first (normal layer, on screen, biggest), next one if a capture reads nothing
        let ws = all.windows.filter { ($0.owningApplication?.applicationName ?? "").localizedCaseInsensitiveContains(a[2]) && $0.windowLayer == 0 &&
                (words.isEmpty || ($0.title ?? "").lowercased().contains(words)) && $0.frame.width > 200 && $0.frame.height > 150 }
            .sorted { ($0.isOnScreen ? 1 : 0, $0.frame.width * $0.frame.height) > ($1.isOnScreen ? 1 : 0, $1.frame.width * $1.frame.height) }
        for w in ws.prefix(4) {
            let cfg = SCStreamConfiguration()
            cfg.width = Int(w.frame.width * 2); cfg.height = Int(w.frame.height * 2)   // full detail: small terminal text must read right
            guard let img = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: w), configuration: cfg) else { continue }
            let req = VNRecognizeTextRequest(); req.usesLanguageCorrection = false
            try? VNImageRequestHandler(cgImage: img).perform([req])
            let text = (req.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            if text.isEmpty { continue }
            print(text.map(Hands.mask).joined(separator: "\n")); found = true; return
        }
    }
    done.wait()
    exit(found ? 0 : 1)
}

// "Show me where": a soft pulsing ring at a spot on screen for a few seconds. "@ x y" in top-left screen points.
// An answer's point (gone set): a leader line from the box, and the ring stays until the user clicks or types in another app, or `hold` seconds.
var ring: NSPanel?, ringWatch: Any?, ringGone: (() -> Void)?
func pointAt(_ line: String, from box: NSRect? = nil, hold: Double = 6, gone: (() -> Void)? = nil) {
    let p = line.split(separator: " ").dropFirst().compactMap { Double($0) }
    guard p.count == 2, let main = NSScreen.screens.first else { return }
    let size: CGFloat = 64, c = NSPoint(x: p[0], y: main.frame.height - p[1])   // flip to Cocoa's bottom-left origin
    unpoint()
    let w = NSPanel(contentRect: NSRect(x: c.x - size / 2, y: c.y - size / 2, width: size, height: size),
                    styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    applySharing(w)
    w.level = .screenSaver; w.isOpaque = false; w.backgroundColor = .clear; w.ignoresMouseEvents = true; w.hasShadow = false
    w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    let v = NSView(frame: NSRect(x: 0, y: 0, width: size, height: size)); v.wantsLayer = true
    let l = CAShapeLayer()
    l.path = CGPath(ellipseIn: CGRect(x: 8, y: 8, width: size - 16, height: size - 16), transform: nil)
    l.fillColor = NSColor.systemBlue.withAlphaComponent(0.18).cgColor; l.strokeColor = NSColor.systemBlue.cgColor; l.lineWidth = 3
    l.frame = v.bounds; v.layer?.addSublayer(l)
    let still = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    if !still {
        let pulse = CABasicAnimation(keyPath: "transform.scale"); pulse.fromValue = 0.7; pulse.toValue = 1.1
        pulse.duration = 0.6; pulse.autoreverses = true; pulse.repeatCount = gone == nil ? 6 : 3   // a held ring settles, then waits
        l.anchorPoint = CGPoint(x: 0.5, y: 0.5); l.position = CGPoint(x: size / 2, y: size / 2); l.bounds = v.bounds; l.add(pulse, forKey: "pulse")
    }
    w.contentView = v; w.orderFrontRegardless(); ring = w
    if let box, lead(from: box, to: w.frame.insetBy(dx: 8, dy: 8)) {
        if !still {   // the ring shows as the moving line's head arrives
            w.alphaValue = 0
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { NSAnimationContext.runAnimationGroup { $0.duration = 0.15; w.animator().alphaValue = 1 } }
        }
    }
    if let gone { ringGone = gone; ringWatch = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { _ in unpoint() } }
    DispatchQueue.main.asyncAfter(deadline: .now() + hold) { if ring === w { unpoint() } }
}
func unpoint(_ notify: Bool = true) {
    ring?.orderOut(nil); ring = nil; leader?.orderOut(nil); leader = nil
    if let m = ringWatch { NSEvent.removeMonitor(m); ringWatch = nil }
    let gone = ringGone; ringGone = nil
    if notify { gone?() }
}
// A line from the box to what an answer points at, with an arrowhead: it draws out to the target, stays 3 s, then fades.
// Reduce Motion: it appears already drawn. Cocoa points. No line when the target is near the box or on another display.
var leader: NSPanel?
@discardableResult func lead(from box: NSRect, to target: NSRect) -> Bool {
    leader?.orderOut(nil); leader = nil
    guard let (a, b) = ScreenDrawing.leader(from: box, to: target), let screen = NSScreen.screens.first(where: { $0.frame.contains(a) }), screen.frame.contains(b) else { return false }
    let f = NSRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y)).insetBy(dx: -16, dy: -16)   // room for the head
    let w = NSPanel(contentRect: f, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    applySharing(w)
    w.level = .screenSaver; w.isOpaque = false; w.backgroundColor = .clear; w.ignoresMouseEvents = true; w.hasShadow = false
    w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    let v = NSView(frame: NSRect(origin: .zero, size: f.size)); v.wantsLayer = true
    let p = CGPoint(x: a.x - f.minX, y: a.y - f.minY), q = CGPoint(x: b.x - f.minX, y: b.y - f.minY), path = CGMutablePath()
    path.move(to: p); path.addLine(to: q)
    let angle = atan2(q.y - p.y, q.x - p.x)   // an arrowhead at the target, drawn last so it lands as the line arrives
    for delta in [-0.5, 0.5] { path.move(to: q); path.addLine(to: CGPoint(x: q.x - 14 * cos(angle + delta), y: q.y - 14 * sin(angle + delta))) }
    let still = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    let line = CAShapeLayer(); line.frame = v.bounds; line.path = path; line.fillColor = nil
    line.strokeColor = NSColor.black.cgColor; line.lineWidth = 3; line.lineCap = .round
    let ink = CAGradientLayer(); ink.frame = v.bounds; ink.mask = line   // faint at the box, full at the target
    ink.colors = [NSColor.systemBlue.withAlphaComponent(0.35).cgColor, NSColor.systemBlue.cgColor]
    ink.startPoint = CGPoint(x: p.x / f.width, y: p.y / f.height); ink.endPoint = CGPoint(x: q.x / f.width, y: q.y / f.height)
    v.layer?.addSublayer(ink); w.contentView = v; w.orderFrontRegardless(); leader = w
    if !still {
        let head = CABasicAnimation(keyPath: "strokeEnd"); head.fromValue = 0; head.toValue = 1; head.duration = 0.45
        head.timingFunction = CAMediaTimingFunction(name: .easeOut); line.add(head, forKey: "lead")
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + (still ? 3 : 3.45)) {   // the whole arrow stays 3 s after it lands, then fades
        guard leader === w else { return }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.3; w.animator().alphaValue = 0 }) { if leader === w { w.orderOut(nil); leader = nil } }
    }
    return true
}


// Restart Aurel (Screen Recording only takes effect in a new process); works under launchd or when opened by hand.
func relaunchSoon() {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ProcessInfo.processInfo.environment["AUREL_DIR"] != nil ? ["-c", "sleep 1; exec \"$0\" -onboarded YES", CommandLine.arguments[0]] :
                  ["-c", "sleep 1; launchctl bootout gui/\(getuid())/com.aurel.app >/dev/null 2>&1; sleep 1; launchctl bootstrap gui/\(getuid()) \"$1\" 2>/dev/null || open \"$0\"",
                   Bundle.main.bundlePath, NSHomeDirectory() + "/Library/LaunchAgents/com.aurel.app.plist"]
    try? p.run()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.terminate(nil) }
}

// Updates: build.sh records the source folder (a git clone); Aurel pulls and rebuilds itself from it, then
// restarts once idle. Local edits or a failed build leave the running version alone.
enum Updater {
    static let src = Bundle.main.object(forInfoDictionaryKey: "AurelSource") as? String ?? ""
    static let managedByNix = src.hasPrefix("/nix/store/")
    static var status = "", checking = false
    static func sh(_ script: String, _ args: [String] = []) -> (code: Int32, out: String) {
        let p = Process(), o = Pipe()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh"); p.arguments = ["-c", script, src] + args; p.standardOutput = o; p.standardError = o
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"; env["AUREL_NO_RESTART"] = "1"; p.environment = env
        try? p.run(); p.waitUntilExit()
        return (p.terminationStatus, String(data: o.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
    }
    static let version: String = {
        if managedByNix { return (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown") + " · Nix" }
        return sh(#"cd "$0" 2>/dev/null && git log -1 --format='%h · %cd' --date=format:'%b %-d, %Y'"#).out.trimmingCharacters(in: .whitespacesAndNewlines)
    }()
    static func check(_ done: @escaping () -> Void = {}) {
        if managedByNix { status = "Run nix profile upgrade or nix run again."; done(); return }
        if src.isEmpty || ProcessInfo.processInfo.environment["AUREL_DIR"] != nil { status = "Preview build"; done(); return }
        guard !checking else { done(); return }
        checking = true
        status = "Checking…"; done()
        DispatchQueue.global().async {
            let r = sh(#"""
                cd "$0" 2>/dev/null || exit 3
                [ -z "$(git status --porcelain)" ] || exit 5
                git fetch -q 2>/dev/null || exit 4
                # level or ahead (unpushed local commits): nothing to pull. $1 is the commit this app was built from, so a pulled
                # update whose build failed is built again, and a built one never loops.
                if git merge-base --is-ancestor '@{u}' HEAD 2>/dev/null; then [ "$(git rev-parse HEAD)" = "$1" ] && exit 0
                else git pull -q --ff-only 2>/dev/null || exit 5; fi
                ./build.sh >/dev/null 2>&1 || exit 6
                exit 10
                """#, [Bundle.main.object(forInfoDictionaryKey: "AurelCommit") as? String ?? ""])
            DispatchQueue.main.async {
                checking = false
                status = [0: "Up to date", 3: "Source folder not found (reinstall with build.sh)", 4: "Couldn’t reach GitHub",
                          5: "Skipped: the source folder has local changes", 6: "Update downloaded, but the build failed",
                          10: "Updated. Restarting when you’re not using it…"][r.code] ?? "Update failed"
                done()
                if r.code == 10 { restartWhenIdle() }
            }
        }
    }
    static func restartWhenIdle() {
        if app.busy || agentsUI.hasLive || app.engine.isRunning || app.voice?.isRunning == true || settings.win?.isKeyWindow == true || onboarding.win != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { restartWhenIdle() }
        } else { relaunchSoon() }
    }
    static func schedule() {   // a minute after launch, then every 6 hours
        if managedByNix { status = "Run nix profile upgrade or nix run again."; return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { if Prefs.bool("autoUpdate") { check() } }
        Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { _ in if Prefs.bool("autoUpdate") { check() } }
    }
}

// Opening Aurel again (Spotlight, Finder, Dock) while it runs: setup the first time, Settings after (Agents is the first item there).
final class Delegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        app.hush(); app.drawing.clear(); app.quietAudio.end(immediate: true); app.shush()
        return .terminateNow
    }
    func applicationShouldHandleReopen(_ s: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if let w = Dock.windows.first { Dock.show(w); return false }   // the Dock icon brings back the window it stands for
        UserDefaults.standard.bool(forKey: "onboarded") ? settings.open() : onboarding.open()
        return false
    }
}

// Aurel lives in the menu bar (LSUIElement). While Settings, Agents or setup is open it also gets a Dock icon, ⌘Tab and a menu bar,
// so those windows come back like any app's instead of hiding behind other windows. The box, shelf and pill never count: they never take focus.
enum Dock {
    static var windows: [NSWindow] { [settings.win, agentsUI.view, onboarding.win].compactMap { $0 }.filter { $0.isVisible || $0.isMiniaturized } }
    static func show(_ w: NSWindow) {
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular); NSApp.mainMenu = menu }
        NSApp.activate(ignoringOtherApps: true); w.makeKeyAndOrderFront(nil)
    }
    // After a window closes or hides. The wait lets a closing window finish and keeps the icon from flickering when one window replaces another.
    static func update() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            if windows.isEmpty, NSApp.activationPolicy() == .regular { NSApp.setActivationPolicy(.accessory) }
        }
    }
    static let watch: Void = { NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { _ in update() } }()
    // Settings…, the Agents window, Hide and Quit, and the Edit menu text fields need for ⌘C, ⌘V, ⌘Z and ⌘A.
    static let menu: NSMenu = {
        _ = watch
        let main = NSMenu(), aurel = NSMenu(title: "Aurel"), edit = NSMenu(title: "Edit"), window = NSMenu(title: "Window")
        func add(_ m: NSMenu, _ title: String, _ action: Selector?, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) {
            let item = m.addItem(withTitle: title, action: action, keyEquivalent: key); item.keyEquivalentModifierMask = mods; item.target = target
        }
        add(aurel, "Settings…", #selector(DockActions.settings), ",", target: DockActions.shared)
        add(aurel, "Agents", #selector(DockActions.agents), "0", target: DockActions.shared)
        aurel.addItem(.separator())
        add(aurel, "Hide Aurel", #selector(NSApplication.hide(_:)), "h")
        add(aurel, "Quit Aurel", #selector(NSApplication.terminate(_:)), "q")
        add(edit, "Undo", Selector(("undo:")), "z"); add(edit, "Redo", Selector(("redo:")), "z", [.command, .shift]); edit.addItem(.separator())
        add(edit, "Cut", #selector(NSText.cut(_:)), "x"); add(edit, "Copy", #selector(NSText.copy(_:)), "c"); add(edit, "Paste", #selector(NSText.paste(_:)), "v")
        add(edit, "Select All", #selector(NSText.selectAll(_:)), "a")
        add(window, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"); add(window, "Close", #selector(NSWindow.performClose(_:)), "w")
        for (title, sub) in [("Aurel", aurel), ("Edit", edit), ("Window", window)] { main.addItem(withTitle: title, action: nil, keyEquivalent: "").submenu = sub }
        NSApp.windowsMenu = window
        return main
    }()
}
final class DockActions: NSObject {
    static let shared = DockActions()
    @objc func settings() { Aurel.settings.open() }
    @objc func agents() { agentsUI.openView() }
}

// The menu bar icon: quick actions.
final class MenuBar: NSObject, NSMenuDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    override init() {
        super.init()
        item.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Aurel")
        let m = NSMenu(); m.delegate = self; item.menu = m
        item.isVisible = Prefs.bool("menuIcon")
        paint()
    }
    func paint() { item.button?.appearsDisabled = Prefs.bool("paused"); item.length = NSStatusItem.squareLength }
    func menuNeedsUpdate(_ m: NSMenu) {
        m.removeAllItems()
        let keys = Prefs.str("hotkeyLabel")
        let hint = Prefs.str("input") == "type" ? "Press \(keys) to type" : Prefs.str("talkMode") == "toggle" ? "Press \(keys) to talk · again to send" : "Hold \(keys) and talk"
        let head = NSMenuItem(title: Prefs.bool("paused") ? "Aurel is paused" : hint, action: nil, keyEquivalent: "")
        head.attributedTitle = NSAttributedString(string: head.title, attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold), .foregroundColor: NSColor.secondaryLabelColor])
        head.isEnabled = false; m.addItem(head)
        m.addItem(.separator())
        add(m, "Ask Aurel", #selector(ask), "", "waveform")
        add(m, agentsUI.count > 0 ? "Agents · \(agentsUI.count) running…" : "Agents…", #selector(openAgents), "", "person.2")
        if agentsUI.hasLive || agentsUI.lingering { add(m, Prefs.bool("agentsHidden") ? "Show Agent Shelf" : "Hide Agent Shelf", #selector(hideAgents), "", Prefs.bool("agentsHidden") ? "eye" : "eye.slash") }
        add(m, "Dictation History…", #selector(dictationHistory), "", "clock.arrow.circlepath")
        if pasteHotkeyRegistered && (app.lastDictation ?? DictationData.archive.history.first?.text) != nil {
            add(m, "Paste Last Dictation", #selector(pasteDictation), "v", "doc.on.clipboard"); m.items.last?.keyEquivalentModifierMask = [.control, .command]
        }
        add(m, Prefs.bool("paused") ? "Resume Aurel" : "Pause Aurel", #selector(pause), "", Prefs.bool("paused") ? "play.fill" : "pause.fill")
        m.addItem(.separator())
        add(m, "Settings…", #selector(openSettings), ",", "gearshape")
        m.addItem(.separator())
        add(m, "Quit Aurel", #selector(quit), "q", "power")
    }
    @discardableResult func add(_ m: NSMenu, _ t: String, _ a: Selector?, _ k: String, _ symbol: String) -> NSMenuItem {
        let i = NSMenuItem(title: t, action: a, keyEquivalent: k); i.target = self
        i.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 13, weight: .regular))   // a point size keeps wide symbols' shape
        if #available(macOS 27.0, *) { i.preferredImageVisibility = .visible }   // macOS 27 hides menu symbols by default
        m.addItem(i); return i
    }
    @objc func ask() { app.clickTalk = true; app.start(); if !app.engine.isRunning { app.clickTalk = false } }   // the same box as the shortcut, like its mic button
    @objc func pause() { Prefs.set("paused", !Prefs.bool("paused")); if Prefs.bool("paused") { app.close(clear: false); agentsUI.stopAll() }; paint(); settings.push() }
    @objc func openSettings() { settings.open() }
    @objc func dictationHistory() { settings.open(tab: "dictation") }
    @objc func pasteDictation() { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { app.pasteLastDictation() } }   // after the menu closes and focus returns
    @objc func openAgents() { agentsUI.openView() }
    @objc func hideAgents() { Prefs.set("agentsHidden",!Prefs.bool("agentsHidden")) }
    @objc func quit() { NSApp.terminate(nil) }
}

// Settings window (Settings.swift draws it): every setting lives in Prefs; aurel.py reads the same file.
// Apps Aurel may control. macOS asks once per app, only while that app runs, and has no "allow all". So Settings > Apps
// lists every installed app and asks for all the ticked ones in one go: start each hidden, ask, quit it again.
// macOS only answers "allowed?" for running apps, so what it said is kept in UserDefaults ("allowedApps").
enum Apps {
    static let suggested: Set<String> = ["com.apple.systemevents", "com.apple.finder", "com.apple.Safari", "com.google.Chrome",
        "company.thebrowser.Browser", "com.brave.Browser", "com.apple.Notes", "com.apple.reminders", "com.apple.iCal", "com.apple.Music",
        "com.spotify.client", "com.apple.Terminal", "com.googlecode.iterm2", "com.apple.mail", "com.apple.MobileSMS", "com.apple.Preview",
        "com.apple.TextEdit", "com.apple.systempreferences", "com.microsoft.VSCode", "com.apple.shortcuts", "com.apple.AddressBook",
        "com.apple.Photos", "com.apple.iWork.Pages", "com.apple.iWork.Keynote", "com.apple.iWork.Numbers", "com.microsoft.Word",
        "com.microsoft.Excel", "com.microsoft.Powerpoint", "com.tinyspeck.slackmacgap", "us.zoom.xos", "com.hnc.Discord", "notion.id"]
    static var icons: [String: String] = [:]   // bundle id -> data URL, made once per launch
    static var job = 0, current = 0   // each Allow click is a new job; Stop (or a newer click) ends the one running
    static var stopped: Bool { job != current }
    static let q = DispatchQueue(label: "apps")   // one job at a time: two at once corrupted icons and lost allowed apps (a crash)
    static func wait(_ s: DispatchSemaphore, _ secs: Double) -> Bool {   // true = done; gives up early on Stop
        for _ in 0..<Int(secs * 10) { if s.wait(timeout: .now() + 0.1) == .success { return true }; if stopped { return false } }
        return false
    }

    static var allowed: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "allowedApps") ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: "allowedApps") }
    }
    static func check(_ id: String, ask: Bool) -> OSStatus {   // ask: show macOS's prompt if it never asked (blocks until answered)
        var d = AEAddressDesc()
        _ = id.withCString { AECreateDesc(typeApplicationBundleID, $0, id.utf8.count, &d) }
        defer { AEDisposeDesc(&d) }
        return AEDeterminePermissionToAutomateTarget(&d, typeWildCard, typeWildCard, ask)
    }
    // "allowed" | "blocked" | "new" per app, asked all at once: a busy or frozen app can stall macOS's answer forever,
    // so whatever isn't back in 1.5 s keeps what was saved before.
    static let probeLock = NSLock()
    static var pendingProbes = Set<String>()
    @discardableResult static func statuses(_ ids: [String]) -> [String: String] {
        var codes = [String: OSStatus](); let lock = NSLock(), g = DispatchGroup()
        for id in ids {
            probeLock.lock(); let fresh = pendingProbes.insert(id).inserted; probeLock.unlock()
            guard fresh else { continue }
            g.enter()
            DispatchQueue.global().async {
                let r = check(id, ask: false)
                lock.lock(); codes[id] = r; lock.unlock()
                probeLock.lock(); pendingProbes.remove(id); probeLock.unlock()
                g.leave()
            }
        }
        _ = g.wait(timeout: .now() + 1.5)
        lock.lock(); let got = codes; lock.unlock()
        var a = allowed, out = [String: String]()
        for id in ids {
            if got[id] == noErr { a.insert(id) } else if got[id] == OSStatus(errAEEventNotPermitted) { a.remove(id) }
            out[id] = got[id] == OSStatus(errAEEventNotPermitted) ? "blocked" : a.contains(id) ? "allowed" : "new"
        }
        allowed = a
        return out
    }
    static func sync() {   // after an ask: an app allowed in the moment, at macOS's own prompt, joins the list
        statuses(NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.compactMap(\.bundleIdentifier))
    }
    static func png(_ img: NSImage) -> String {
        guard let r = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                       isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return "" }
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: r)
        img.draw(in: NSRect(x: 0, y: 0, width: 64, height: 64)); NSGraphicsContext.restoreGraphicsState()
        return "data:image/png;base64," + (r.representation(using: .png, properties: [:])?.base64EncodedString() ?? "")
    }
    static func list() -> [[String: Any]] {
        let fm = FileManager.default
        let dirs = ["/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities", NSHomeDirectory() + "/Applications"]
        let paths = dirs.flatMap { d in ((try? fm.contentsOfDirectory(atPath: d)) ?? []).filter { $0.hasSuffix(".app") }.map { d + "/" + $0 } }
            + ["/System/Library/CoreServices/Finder.app", "/System/Library/CoreServices/System Events.app"]
        var seen = Set<String>(), out: [[String: Any]] = []
        for p in paths {
            guard let id = Bundle(path: p)?.bundleIdentifier, id != Bundle.main.bundleIdentifier, seen.insert(id).inserted else { continue }
            if icons[id] == nil { icons[id] = png(NSWorkspace.shared.icon(forFile: p)) }
            var name = fm.displayName(atPath: p); if name.hasSuffix(".app") { name.removeLast(4) }
            out.append(["id": id, "name": name, "icon": icons[id]!, "suggested": suggested.contains(id)])
        }
        let st = statuses(out.map { $0["id"] as! String })
        for i in out.indices { out[i]["status"] = st[out[i]["id"] as! String] }
        return out.sorted { ($0["name"] as! String).localizedCaseInsensitiveCompare($1["name"] as! String) == .orderedAscending }
    }
    static func allow(_ ids: [String], _ progress: @escaping (String, String) -> Void) {   // on q
        for id in ids where !stopped {
            var started: NSRunningApplication?
            if NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                let c = NSWorkspace.OpenConfiguration(); c.activates = false; c.hides = true; c.addsToRecentItems = false
                let done = DispatchSemaphore(value: 0)
                NSWorkspace.shared.openApplication(at: url, configuration: c) { a, _ in started = a; done.signal() }
                _ = wait(done, 15)
            }
            progress(id, "asking")
            // An app that just opened can't be asked yet (procNotFound, and macOS shows nothing): try again for up to 5 s.
            // Some apps (Spotify) never answer: move on after 20 s.
            for _ in 0..<20 where !stopped {
                final class Box { var code = OSStatus(procNotFound) }
                let answered = DispatchSemaphore(value: 0), r = Box()
                DispatchQueue.global().async { r.code = check(id, ask: true); answered.signal() }
                guard wait(answered, 20), r.code == OSStatus(procNotFound) else { break }
                Thread.sleep(forTimeInterval: 0.25)
            }
            progress(id, statuses([id])[id]!)   // before quitting it: a quit app can't be checked, so its answer wouldn't be saved
            started?.terminate()   // only the ones Aurel started
        }
    }
}

final class SettingsWindow: NSObject, NSWindowDelegate {
    var win: NSWindow?, model: SettingsModel?   // the content is SettingsModel and its view (Settings.swift)

    var tab = "", timer: Timer?   // tab: shown once the page loads
    var revealing: [String: Any]?   // a memory item to show once the page loads

    func reveal(_ item: [String: Any]) {
        if win == nil { revealing = item; open(tab: "memory") } else { open(tab: "memory"); send("reveal", item) }
    }

    func open(tab t: String = "") {
        if let w = win { Dock.show(w); push(); refresh(); if !t.isEmpty { model?.openSection(t) }; return }
        tab = t
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 560),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        applySharing(w)
        w.titlebarAppearsTransparent = true; w.titleVisibility = .hidden; w.title = "Aurel Settings"
        w.isReleasedWhenClosed = false; w.delegate = self
        w.contentMinSize = NSSize(width: 700, height: 460); w.contentMaxSize = NSSize(width: 1000, height: 820)   // wider only spreads the page into empty space
        w.collectionBehavior.insert(.fullScreenNone)   // the green button zooms up to the max size
        let bg = NSVisualEffectView(frame: w.contentRect(forFrameRect: w.frame))
        bg.material = .underWindowBackground; bg.blendingMode = .behindWindow; bg.state = .active
        let m = SettingsModel(); m.post = { [weak self] in self?.handle($0) }
        let v = NSHostingView(rootView: SettingsView(m: m))
        v.frame = bg.bounds; v.autoresizingMask = [.width, .height]
        let bar = TitleBar(frame: NSRect(x: 0, y: bg.bounds.height - 28, width: bg.bounds.width, height: 28)); bar.autoresizingMask = [.width, .minYMargin]
        bg.addSubview(v); bg.addSubview(bar); w.contentView = bg
        win = w; model = m
        push(); refresh(); DispatchQueue.global().async { [weak self] in self?.send("perms", Onboarding.perms()) }
        if !tab.isEmpty { m.openSection(tab); tab = "" }; if let r = revealing { send("reveal", r); revealing = nil }
        w.center(); w.setFrameUsingName("AurelSettings"); w.setFrameAutosaveName("AurelSettings")
        let saved = w.contentRect(forFrameRect: w.frame).size   // a frame saved before the max size existed (or full screen) shrinks to fit
        if saved.width > w.contentMaxSize.width || saved.height > w.contentMaxSize.height {
            w.setContentSize(NSSize(width: min(saved.width, w.contentMaxSize.width), height: min(saved.height, w.contentMaxSize.height))); w.center()
        }
        Dock.show(w)
        Onboarding.connectors { [weak self] c in self?.send("connectors", c) }
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self, weak w] _ in   // System Settings changes them behind our back
            guard w?.occlusionState.contains(.visible) == true else { return }   // minimized or covered: the next tick in view catches up
            DispatchQueue.global().async { self?.send("perms", Onboarding.perms()); self?.send("mics", microphoneChoices()); self?.send("globe", globeKeyTaken()); self?.send("parakeet", Parakeet.shared.status()); self?.send("llm", LocalAI.shared.status()) }
        }
    }


    func send(_ call: String, _ v: Any) {
        DispatchQueue.main.async { [weak self] in self?.model?.receive(call, v) }
    }

    func push() {   // the settings, and the app icon for the sidebar
        send("dictation", DictationData.state())
        send("parakeet", Parakeet.shared.status()); send("llm", LocalAI.shared.status())
        model?.receive("motion", NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        var d: [String: Any] = ["prefs": Prefs.d, "mics": microphoneChoices(), "version": Updater.version, "update": Updater.status, "managedUpdates": Updater.managedByNix, "sharingUnavailable": ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27,
                                "hotkeyTaken": !hotkeyRegistered, "dictateHotkeyTaken": !Prefs.str("dictateHotkeyLabel").isEmpty && !dictateHotkeyRegistered, "globeTaken": globeKeyTaken()]
        let routines = (Prefs.path as NSString).deletingLastPathComponent + "/routines.json"
        d["routines"] = (try? JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:routines)))) as? [[String:Any]] ?? []
        if let t = NSApp.applicationIconImage?.tiffRepresentation, let png = NSBitmapImageRep(data: t)?.representation(using: .png, properties: [:]) {
            d["icon"] = "data:image/png;base64," + png.base64EncodedString()
        }
        model?.receive("load", d)
    }

    func refresh() {   // usage, saved rules, Claude plan: aurel.py --state (it runs Claude Code, so off the main thread)
        DispatchQueue.global().async { [weak self] in
            let p = py(["--state"]), out = Pipe(); p.standardOutput = out
            try? p.run(); p.waitUntilExit()
            let s = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            guard s.hasPrefix("{") else { return }
            guard let state = try? JSONSerialization.jsonObject(with: Data(s.utf8)) else { return }
            DispatchQueue.main.async { self?.model?.receive("state", state) }
        }
    }

    // "Change shortcut": the next key chord, including modifier-only and Fn chords, becomes the talk shortcut. Esc cancels.
    var monitor: Any?, recording = "main", recordedModifiers: NSEvent.ModifierFlags = [], echo: ((String, [Any]) -> Void)?   // echo: setup when it records, so it gets the calls Settings would
    func record(_ kind: String = "main", echo: ((String, [Any]) -> Void)? = nil) {
        if monitor != nil { return }
        recording = kind; recordedModifiers = []; self.echo = echo
        if let r = ref { UnregisterEventHotKey(r); ref = nil }
        if let r = dictateRef { UnregisterEventHotKey(r); dictateRef = nil }   // recorded keys must reach Settings, not either shortcut
        stopSpecialHotkeys()
        let fkeys = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90]
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] e in
            guard let self else { return e }
            let f = e.modifierFlags.intersection([.command, .shift, .option, .control, .function])
            let mods = shortcutModifierLabel(f)
            if e.type == .flagsChanged {
                if !f.isEmpty { recordedModifiers.formUnion(f); say("rec", shortcutModifierLabel(recordedModifiers)); return nil }
                guard !recordedModifiers.isEmpty else { return nil }
                let held = recordedModifiers; recordedModifiers = []
                done((-2, shortcutModifiers(held), shortcutModifierLabel(held)))
                return nil
            }
            if e.keyCode == 53 && f.isEmpty { done(nil); return nil }   // Esc
            let fn = fkeys.firstIndex(of: Int(e.keyCode))
            guard !f.isEmpty || fn != nil else { say("rec", "Add ⌃, ⌥, ⇧, ⌘ or fn"); return nil }
            let names: [UInt16: String] = [49: "Space", 36: "Return", 48: "Tab", 51: "Delete", 123: "←", 124: "→", 125: "↓", 126: "↑"]
            let key = fn.map { "F\($0 + 1)" } ?? names[e.keyCode] ?? (e.charactersIgnoringModifiers ?? "?").uppercased()
            recordedModifiers = []
            done((Int(e.keyCode), shortcutModifiers(f), mods + key))
            return nil
        }
    }

    func done(_ new: (code: Int, mods: Int, label: String)?) {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        let stem = recording == "dictate" ? "dictateHotkey" : "hotkey"
        let old = (Prefs.d[stem + "Code"], Prefs.d[stem + "Mods"], Prefs.d[stem + "Label"])
        if let n = new { Prefs.set(stem + "Code", n.code); Prefs.set(stem + "Mods", n.mods); Prefs.set(stem + "Label", n.label) }
        let otherRegistered = recording == "dictate" ? registerHotkey() : registerDictateHotkey()
        let registered = otherRegistered && (recording == "dictate" ? registerDictateHotkey() : registerHotkey())
        if !registered {   // taken by another app or the other Aurel shortcut: keep the old one
            let own = new != nil && !Prefs.str("dictateHotkeyLabel").isEmpty && hotkeysConflict(hotkey(),dictateHotkey())
            Prefs.set(stem + "Code", old.0!); Prefs.set(stem + "Mods", old.1!); Prefs.set(stem + "Label", old.2!)
            registerHotkey(); registerDictateHotkey()
            say("taken", recording, own)
        }
        echo?("recorded", [Prefs.str(stem + "Label")]); echo = nil
        recording = "main"
        push()
    }

    func say(_ call: String, _ args: Any...) {   // setup's recorder, or Settings
        if let echo { echo(call, args) } else { model?.receive(call, args.count == 1 ? args[0] : args) }
    }

    func helper(_ args: [String]) { let p = py(args); try? p.run(); p.waitUntilExit() }

    func importProfile() {
        DispatchQueue.global().async { [weak self] in
            let p = py(["--me", "import"]), out = Pipe(); p.standardOutput = out
            try? p.run(); let data = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
            let result = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? ["errors": ["contacts", "mail"]]
            self?.send("profileImport", result)
            DispatchQueue.main.async { self?.refresh() }
        }
    }

    func apply(_ k: String, _ v: Any) {   // one setting changed, from this window or by voice (aurel.py --set)
        guard Prefs.set(k, v) else { push(); send("notice", ["text": "Couldn’t save that change, so the old setting is back."]); return }
        if k == "wakeWord" {
            if v as? Bool == true { app.enableWakeWord() }
            else {
                app.wakePermissionID += 1; app.stopWake(); app.followUp = false
                if app.handsFree && app.engine.isRunning { app.hush() }
                app.handsFree = false
            }
        }
        if k == "microphone" { app.stopWake() }
        if k == "draw", v as? Bool == false { app.drawing.clear(); app.unwarm() }
        if ["routing", "model", "client"].contains(k) {   // a new key must not reuse a worker started with the old one
            app.unwarm(); app.js("models", app.modelChoices())
        }
        if k == "speechModel" { app.prepareSpeech() }
        if k == "parakeetModel" { Parakeet.shared.restart(); send("parakeet", Parakeet.shared.status()) }
        if k == "localModel" { LocalAI.shared.restart(); send("llm", LocalAI.shared.status()) }
        if k == "client", v as? String != "local" { LocalAI.shared.stop() }   // its memory goes back to the Mac
        if k == "improve" { Prefs.set("improveAsked", true) }   // any answer, here or in setup or the card, is the answer
        if k == "speak", v as? Bool == false { app.shush() }
        if k == "hideWhenSharing" { NSApp.windows.forEach(applySharing) }
        if k == "menuIcon" { bar.item.isVisible = v as? Bool == true }
        if k == "paused" { if v as? Bool == true { app.close(clear: false); agentsUI.stopAll() }; bar.paint() }
        if k == "safe" { app.js("mode", v as? Bool == true) }
        if k == "login" {   // the LaunchAgent build.sh installed: enabled = starts at login
            if ProcessInfo.processInfo.environment["AUREL_DIR"] != nil { Prefs.set("login",false); push(); return }
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            p.arguments = [v as? Bool == true ? "enable" : "disable", "gui/\(getuid())/com.aurel.app"]; try? p.run()
        }
    }


    func confirm(_ title: String, _ detail: String, _ button: String) -> Bool {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = detail; alert.addButton(withTitle: button); alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    func handle(_ b: [String: Any]) {
        guard let what = b["do"] as? String else { return }
        switch what {
        case "parakeetDownload": Parakeet.shared.download(b["id"] as? String ?? "") { [weak self] in Task { @MainActor in self?.send("parakeet", Parakeet.shared.status()) } }   // progress arrives off the main thread
        case "parakeetCancel": Parakeet.shared.cancel(b["id"] as? String ?? "")
        case "parakeetDelete": Parakeet.shared.delete(b["id"] as? String ?? ""); send("parakeet", Parakeet.shared.status())
        case "localDownload": LocalAI.shared.download(b["id"] as? String ?? "") { [weak self] in Task { @MainActor in self?.send("llm", LocalAI.shared.status()) } }
        case "localCancel": LocalAI.shared.cancel(b["id"] as? String ?? "")
        case "localDelete": LocalAI.shared.delete(b["id"] as? String ?? ""); send("llm", LocalAI.shared.status())
        case "set":
            guard let k = b["k"] as? String, let v = b["v"] else { return }
            apply(k, v)
        case "dictationWord":
            if let word = b["word"] as? String, DictationData.word(word, replacing: b["old"] as? String) { send("dictation", DictationData.state()) }
            else { send("notice", ["text": "Couldn’t save that word. Use 1–80 characters, up to 500 words and 4,000 characters total."]) }
        case "dictationWordDelete":
            if let word = b["word"] as? String, DictationData.forget(word) { send("dictation", DictationData.state()) }
            else { send("notice", ["text": "Couldn’t remove that word."]) }
        case "dictationDelete", "dictationClear":
            let old = DictationData.archive
            if what == "dictationClear" { DictationData.archive.history = [] }
            else { DictationData.archive.history.removeAll { $0.id == b["id"] as? String } }
            if !DictationData.save() { DictationData.archive = old; send("notice", ["text": "Couldn’t delete saved dictation."]) }
            send("dictation", DictationData.state())
        case "record": record()
        case "recordDictate": record("dictate")
        case "cancelRecord": if monitor != nil { done(nil) }
        case "clearDictate":
            if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
            Prefs.set("dictateHotkeyOff", true); recording = "dictate"; done((-1, 0, ""))
        case "unlearn":
            guard let say = b["say"] as? String else { return }
            DispatchQueue.global().async { [weak self] in self?.helper(["--unlearn", say]); DispatchQueue.main.async { self?.refresh() } }
        case "checkUpdate": Updater.check { [weak self] in self?.push() }
        case "agents": agentsUI.openView()
        case "routineRemove":
            guard let id = b["id"] as? String else { return }
            DispatchQueue.global().async { [weak self] in self?.helper(["--routine","remove",id]); DispatchQueue.main.async { self?.push() } }
        case "resetHotkey":
            done((49, controlKey | optionKey, "⌃⌥Space"))   // same rollback and warning as a recorded shortcut
        case "preview":
            if let n = b["sound"] as? String { app.sound(n, Float(Prefs.num("volume"))) }
        case "setup": onboarding.open()
        case "copy": if let text = b["text"] as? String { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string); send("notice", ["text": "Copied."]) }
        case "globeKey": NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
        case "openLog": NSWorkspace.shared.open(URL(fileURLWithPath:(Prefs.path as NSString).deletingLastPathComponent + "/log.jsonl"))
        case "profileImport": importProfile()   // the button is the only path that requests Contacts/Mail access
        case "me":
            guard let action = b["action"] as? String else { return }
            var args = ["--me", action]
            switch action {
            case "add":
                guard let category = b["category"] as? String, let text = b["text"] as? String else { return }; args += [category, text]
            case "set":
                guard let id = b["id"] as? String, let text = b["text"] as? String else { return }; args += [id, text]
            case "drop":
                guard let id = b["id"] as? String else { return }; args.append(id)
            case "forget-source":
                guard let source = b["source"] as? String, confirm("Forget everything from \(source)?", "These details are removed from About you. This can’t be undone.", "Forget") else { return }; args.append(source)
            default: return
            }
            DispatchQueue.global().async { [weak self] in self?.helper(args); DispatchQueue.main.async { self?.refresh() } }
        case "forget", "remember":
            guard let line = b["line"] as? String else { return }
            DispatchQueue.global().async { [weak self] in self?.helper(["--" + what, line]); DispatchQueue.main.async { self?.refresh() } }
        case "rule":   // a rule edited in place
            guard let old = b["old"] as? String, let text = b["text"] as? String else { return }
            DispatchQueue.global().async { [weak self] in self?.helper(["--rule", old, text]); DispatchQueue.main.async { self?.refresh() } }
        case "apps": Apps.q.async { [weak self] in self?.send("apps", Apps.list()) }
        case "allow":
            guard let ids = b["ids"] as? [String] else { return }
            Apps.job += 1; let me = Apps.job
            Apps.q.async { [weak self] in
                Apps.current = me
                Apps.allow(ids) { id, s in self?.send("appStatus", [id, s]) }
                self?.send("allowDone", [Any]())
            }
        case "grant": if let id = b["id"] as? String { onboarding.grant(id) }
        case "enableAll": onboarding.enableAll(connected: b["connected"] as? String == "true")
        case "connectors": onboarding.grant("connectors")
        case "stopAllow": Apps.job += 1
        case "automation": onboarding.settings("Automation")
        case "quit": NSApp.terminate(nil)
        default: break
        }
    }

    func windowDidResignKey(_ n: Notification) { if monitor != nil { done(nil) } }

    func windowWillClose(_ n: Notification) {
        onboarding.permissionHelp.close()
        if let b = model?.flush(send: false) { handle(b) }   // a deletion still showing Undo
        if monitor != nil { done(nil) }   // closed mid-recording: keep the old shortcut
        timer?.invalidate(); timer = nil
        win?.setFrameAutosaveName("")   // frees the name for the next window; the frame is already saved
        model = nil; win = nil
    }
}

// The page fills the window under its title bar and would swallow drags; this strip moves the window and double-click zooms.
final class TitleBar: NSView {
    override func mouseDown(with e: NSEvent) {
        guard e.clickCount == 2 else { window?.performDrag(with: e); return }
        switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") { case "Minimize": window?.miniaturize(nil); case "None": break; default: window?.zoom(nil) }
    }
}

// Where floating panels (the box, agent chips) go: kept on screen, following the display they belong to.
enum PanelFrame {
    static func clamp(_ frame: NSRect, _ bounds: NSRect) -> NSRect {
        var f = frame; f.size.width = min(f.width, bounds.width); f.size.height = min(f.height, bounds.height)
        f.origin.x = min(max(f.minX, bounds.minX), bounds.maxX - f.width)
        f.origin.y = min(max(f.minY, bounds.minY), bounds.maxY - f.height)
        return f
    }
    // The same frame on another display: the same distance from the chosen side and from the top or bottom.
    static func follow(_ f: NSRect, _ from: NSRect, _ to: NSRect, right: Bool, top: Bool) -> NSRect {
        var g = f
        g.origin.x = right ? to.maxX - (from.maxX - f.maxX) - f.width : to.minX + (f.minX - from.minX)
        g.origin.y = top ? to.maxY - (from.maxY - f.maxY) - f.height : to.minY + (f.minY - from.minY)
        return g
    }
    static func initial(_ saved: [Double]?, _ bounds: NSRect) -> NSRect {
        let fallback = NSRect(x: bounds.minX + 12, y: bounds.maxY - min(470, bounds.height - 24) - 12, width: min(340, bounds.width - 24), height: min(470, bounds.height - 24))
        guard let s = saved, s.count == 4, s.allSatisfy({ $0.isFinite }), s[2] >= 44, s[3] >= 44 else { return fallback }
        let frame = NSRect(x: s[0], y: s[1], width: s[2], height: s[3])
        guard bounds.contains(frame) else { return fallback }
        return frame
    }
    static func key(_ screen: NSScreen) -> String { String(describing: screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] ?? "main") }
}



// Structured EventKit backend; the Python tool owns picks and approval cards.
enum CalendarTool {
    static func date(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = f.date(from: text) { return date }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: text)
    }
    static func row(_ event: EKEvent) -> [String: Any] {
        let f = ISO8601DateFormatter(); f.timeZone = .current; f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let attendees = (event.attendees ?? []).map { [$0.name ?? "", $0.url.absoluteString.replacingOccurrences(of: "mailto:", with: "")].joined(separator: " ") }
        return ["id": event.eventIdentifier ?? "", "title": event.title ?? "", "start": f.string(from: event.startDate),
                "end": f.string(from: event.endDate), "calendarID": event.calendar.calendarIdentifier,
                "calendar": event.calendar.title, "writable": event.calendar.allowsContentModifications, "allDay": event.isAllDay,
                "attendees": attendees,
                "modified": event.lastModifiedDate.map { f.string(from: $0) } ?? ""]
    }
    static func run(_ data: [String: Any], store: EKEventStore = EKEventStore()) throws -> [String: Any] {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return ["need": "calendar"] }
        let action = data["action"] as? String ?? ""
        if action == "list" {
            guard let start = date(data["from"]), let end = date(data["to"]), end > start,
                  end.timeIntervalSince(start) <= 4 * 365 * 86400 else { return ["error": "Use a valid range shorter than four years."] }
            let query = data["query"] as? String ?? ""
            let events = store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: nil))
                .filter { $0.status != .canceled }.sorted { $0.startDate < $1.startDate }.map { row($0) }
            return ["events": events.filter { query.isEmpty || ([$0["title"] as? String ?? ""] + ($0["attendees"] as? [String] ?? [])).joined(separator: " ").localizedCaseInsensitiveContains(query) }, "calendars": store.calendars(for: .event).map {
                ["id": $0.calendarIdentifier, "title": $0.title, "writable": $0.allowsContentModifications] as [String: Any]
            }]
        }
        guard ["add", "move", "delete"].contains(action) else { return ["error": "Unknown calendar action."] }
        let event: EKEvent
        if action == "add" {
            guard let title = data["title"] as? String, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return ["error": "A title is required."] }
            let target = (data["calendarID"] as? String).flatMap { store.calendar(withIdentifier: $0) } ?? (data["calendarID"] == nil ? store.defaultCalendarForNewEvents : nil)
            guard let target, target.allowsContentModifications else { return ["error": "Choose a writable calendar from list."] }
            event = EKEvent(eventStore: store); event.calendar = target; event.title = title
        } else {
            guard let expected = data["event"] as? [String: Any], let start = date(expected["start"]), let end = date(expected["end"]) else { return ["error": "Read the event before changing it."] }
            // Query the occurrence: recurring events may share an identifier.
            let matches = store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: nil))
                .filter { NSDictionary(dictionary: row($0)).isEqual(to: expected) }
            guard matches.count == 1 else { return ["error": "Event changed or disappeared. Read it again and ask for approval again."] }
            event = matches[0]
            guard event.calendar.allowsContentModifications else { return ["error": "This calendar is read-only."] }
        }
        if action == "delete" {
            try store.remove(event, span: .thisEvent, commit: true)
            return ["deleted": data["event"] ?? [:]]
        }
        guard let start = date(data["start"]), let end = date(data["end"]), end > start else { return ["error": "Use a start and a later end with timezone offsets."] }
        event.startDate = start; event.endDate = end
        try store.save(event, span: .thisEvent, commit: true)
        return ["event": row(event)]
    }
}

// MARK: - Hands (AX first; Quartz only when an app has no accessibility action)
// Hands traversal, ranking and action fallbacks adapt ideas from Plip; see LICENSE-Plip.
enum Hands {
    struct Failure: Error { let message: String; init(_ message: String) { self.message = message } }
    struct Node: Codable {
        var id: Int, role: String, label: String, value: String, frame: [Double], path: [Int], secret: Bool
        var spot: CGPoint { CGPoint(x: frame[0] + frame[2] / 2, y: frame[1] + frame[3] / 2) }
        var line: String {
            "[\(id)] \(role.replacingOccurrences(of: "AX", with: "").replacingOccurrences(of: "TextField", with: "text field")) \(Hands.quote(label))" +
                (value.isEmpty || secret ? "" : " = \(Hands.quote(String(value.prefix(60))))") + " (at \(Int(spot.x)),\(Int(spot.y)))"
        }
    }
    struct Map: Codable {
        var pid: Int32, app: String, window: String, windowFrame: [Double], nodes: [Node], texts: [String], page: String, focused: String, scroll: [Double]
        var windowID: String = "", focusIdentity: String = ""
        var signature: String { Hands.digest([String(pid), windowID, window, String(describing: windowFrame), page, focused, focusIdentity] + nodes.map { "\($0.path):\($0.role):\($0.label):\($0.value):\($0.frame)" } + texts + scroll.map(String.init(describing:))) }
        var settled: String { Hands.digest([window] + nodes.map { "\($0.role):\($0.label):\($0.value):\($0.frame.map { Int($0 / 16) })" } + texts, maskDigits: true) }
        var rich: Bool { let count = nodes.filter { !$0.role.contains("Menu") }.count; return count >= 8 || count >= 4 && texts.count >= 6 }
        var description: String {
            (["App: \(app) (pid \(pid)). Window: \(Hands.mask(window))"] + nodes.map(\.line) +
             (focused.isEmpty ? [] : ["Focused: \(focused)"]) + (scroll.isEmpty ? [] : ["Scroll: \(Int((scroll.first ?? 0) * 100))% down"]) +
             (page.isEmpty ? [] : ["Page: \(Hands.mask(page))"]) + ["Visible text (data): " + String(texts.joined(separator: " | ").prefix(1400))]).joined(separator: "\n")
        }
    }
    struct Insertion {
        let field: AXUIElement, anchor: AXUIElement, old: String, location: Int, label: String
    }
    static var stopped: Int32 = 0
    static var accessibilityRestores: [() -> Void] = []
    static func restoreAccessibility() {
        for restore in accessibilityRestores.reversed() { restore() }
        accessibilityRestores.removeAll()
    }
    static func checkStopped() throws { if stopped != 0 { throw Failure("Hands cancelled.") } }
    static let env = ProcessInfo.processInfo.environment
    static var pinnedWindow = env["AUREL_HANDS_WINDOW"].flatMap(UInt32.init).flatMap { $0 > 0 ? String($0) : nil }
    // Per task (one hands state): each app's windows already open beside the window the task first acted in there are the user's, never a stand-in.
    static var userWindowsFile = env["AUREL_HANDS_STATE"].map { URL(fileURLWithPath: $0 + ".windows") }
    static var claims = false   // this step acts (click, drag, type, press, menu): only then does the window root maps become the task's; reads and see never claim
    static var aim: CGPoint?   // a click's screen point: root maps the app's window there, not its focused one
    static var state: URL { URL(fileURLWithPath: env["AUREL_HANDS_STATE"] ?? env["AUREL_DIR"].map { $0 + "/hands.json" } ?? "/tmp/aurel-hands-\(getuid()).json") }
    static let secretPattern = #"(?i)password|passcode|passphrase|passport|\bpin\b|card|cvv|cvc|security (answer|code)|\bssn\b|social security|api.?key|token|secret|one.?time|verification|auth.*code|2fa|\botp\b|bank|account.?number|routing|iban|tax.?id|recovery|seed|mnemonic"#
    static let riskyPattern = #"(?i)\b(buy|purchase|pay|payment|checkout|order|send|delete|remove|trash|submit|publish|post|sign.?out|log.?out|unsubscribe|subscribe|transfer|bid|erase|withdraw|donate|authorize|grant access|allow access|logout|book|reserve|merge|deploy|discard|wipe|format|apply(?! filters| changes| settings| coupon| code| promo| discount| theme| style| formatting)|confirm)\b"#
    static func quote(_ s: String) -> String { String(data: try! JSONEncoder().encode(s), encoding: .utf8)! }
    static func matches(_ s: String, _ pattern: String) -> Bool { s.range(of: pattern, options: .regularExpression) != nil }
    static func riskyLabel(_ label: String, _ map: Map? = nil) -> Bool {
        if normalized(label) == "cancel" { return false }
        if matches(label,riskyPattern) { return true }
        guard let map else { return matches(label,#"(?i)^\s*(ok|yes|continue|allow|accept|agree|complete|finish|grant)\s*$"#) }   // a map-free menu replay cannot prove a generic confirmation is safe
        let context = ([map.window] + map.texts + map.nodes.filter { ["AXSheet","AXDialog"].contains($0.role) }.map(\.label)).joined(separator:" ")
        return matches(label,#"(?i)^\s*(ok|yes|continue|allow|accept|agree|complete|finish|grant)\s*$"#) && matches(context,riskyPattern)
    }
    static func secret(_ s: String) -> Bool { matches(s, secretPattern) }
    static func mask(_ s: String) -> String {
        var s = s.replacingOccurrences(of: #"\b(?:\d[ -]?){13,19}\b|\b\d{3}[- ]\d{2}[- ]\d{4}\b|\b\d{6,8}\b"#, with: "[SECRET]", options: .regularExpression)
        if matches(s, #"(?i)(one.?time|verification|security|auth|otp|code)\D{0,20}\d{4,8}"#) {
            s = s.replacingOccurrences(of: #"\b\d{4,8}\b"#, with: "[SECRET]", options: .regularExpression)
        }
        return s
    }
    static func digest(_ parts: [String], maskDigits: Bool = false) -> String {
        let s = parts.joined(separator: "\n"), text = maskDigits ? s.replacingOccurrences(of: #"\d"#, with: "#", options: .regularExpression) : s
        // Stable across helper processes (Swift's Hasher is deliberately randomized).
        return String(text.utf8.reduce(UInt64(14695981039346656037)) { ($0 ^ UInt64($1)) &* 1099511628211 }, radix: 16)
    }
    static func normalized(_ s: String) -> String { s.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ").replacingOccurrences(of: "…", with: "...").replacingOccurrences(of: "[\u{2010}-\u{2015}\u{2212}]", with: "-", options: .regularExpression) }   // macOS writes "Wi‑Fi" with a non-breaking hyphen
    static func rank(_ label: String, _ text: String) -> Int {
        let l = normalized(label), t = normalized(text)
        guard !t.isEmpty else { return 0 }
        if l == t { return 4 }; if l.hasPrefix(t) { return 3 }
        if matches(l, #"\b"# + NSRegularExpression.escapedPattern(for: t) + #"\b"#) { return 2 }
        return l.contains(t) ? 1 : 0
    }
    static func keys(_ text: String) throws -> (CGKeyCode, CGEventFlags) {
        let input = normalized(text).replacingOccurrences(of:" ",with:"")
        var parts = (input.hasSuffix("++") ? String(input.dropLast()) + "=" : input).split(separator: "+").map(String.init), flags: CGEventFlags = []
        guard let key = parts.popLast(), !key.isEmpty else { throw Failure("Unknown key.") }
        for part in parts {
            switch part {
            case "cmd", "command", "⌘": flags.insert(.maskCommand)
            case "shift", "⇧": flags.insert(.maskShift)
            case "ctrl", "control", "⌃": flags.insert(.maskControl)
            case "alt", "option", "opt", "⌥": flags.insert(.maskAlternate)
            default: throw Failure("Unknown modifier: \(part)")
            }
        }
        let names: [String: CGKeyCode] = ["return":36,"enter":36,"esc":53,"escape":53,"tab":48,"space":49,"delete":51,"backspace":51,"forwarddelete":117,"pagedown":121,"pageup":116,"home":115,"end":119,"left":123,"right":124,"down":125,"up":126,
            "a":0,"s":1,"d":2,"f":3,"h":4,"g":5,"z":6,"x":7,"c":8,"v":9,"b":11,"q":12,"w":13,"e":14,"r":15,"y":16,"t":17,"1":18,"2":19,"3":20,"4":21,"6":22,"5":23,"=":24,"9":25,"7":26,"-":27,"8":28,"0":29,
            "]":30,"o":31,"u":32,"[":33,"i":34,"p":35,"l":37,"j":38,"'":39,"k":40,";":41,"\\":42,",":43,"/":44,"n":45,"m":46,".":47,"`":50,"f1":122,"f2":120,"f3":99,"f4":118,"f5":96,"f6":97,"f7":98,"f8":100,"f9":101,"f10":109,"f11":103,"f12":111]
        guard let code = names[["plus":"=","zoomin":"=","minus":"-","zoomout":"-" ][key] ?? key] else { throw Failure("Unknown key: \(key)") }
        return (code, flags)
    }
    static func riskyKey(_ text: String) throws -> Bool {
        let (code, flags) = try keys(text)
        return (flags.contains(.maskCommand) && [12,13,36,51,117].contains(code)) || (flags.contains([.maskCommand,.maskShift]) && code == 2) || (flags.contains([.maskCommand,.maskAlternate]) && code == 53)
    }
    static func attribute(_ e: AXUIElement, _ name: String) -> CFTypeRef? { axAttribute(e, name) }
    static func element(_ e: AXUIElement, _ name: String) -> AXUIElement? {
        guard let v = attribute(e, name), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }; return (v as! AXUIElement)
    }
    static func children(_ e: AXUIElement) -> [AXUIElement] { Array(((attribute(e, kAXChildrenAttribute) as? [AXUIElement]) ?? []).prefix(400)) }
    static func frame(_ e: AXUIElement) -> CGRect {
        var p = CGPoint.zero, s = CGSize.zero
        if let v = attribute(e, kAXPositionAttribute), CFGetTypeID(v) == AXValueGetTypeID() { AXValueGetValue(v as! AXValue, .cgPoint, &p) }
        if let v = attribute(e, kAXSizeAttribute), CFGetTypeID(v) == AXValueGetTypeID() { AXValueGetValue(v as! AXValue, .cgSize, &s) }
        return CGRect(origin: p, size: s)
    }
    static func array(_ r: CGRect) -> [Double] { [r.minX, r.minY, r.width, r.height] }
    static func name(_ e: AXUIElement) -> String {
        func direct(_ item: AXUIElement) -> String {
            for key in [kAXTitleAttribute, kAXDescriptionAttribute, "AXLabel", kAXHelpAttribute, "AXPlaceholderValue"] {
                if let s = attribute(item, key) as? String, !s.isEmpty { return String(mask(s).prefix(160)) }
            }
            let role = attribute(item, kAXRoleAttribute) as? String ?? ""
            return ["AXStaticText", "AXHeading"].contains(role) ? String(mask(attribute(item, kAXValueAttribute) as? String ?? "").prefix(160)) : ""
        }
        let own = direct(e), role = attribute(e, kAXRoleAttribute) as? String ?? ""
        if !own.isEmpty && ![normalized(role),normalized(role.replacingOccurrences(of:"AX",with:""))].contains(normalized(own)) { return own }
        guard ["AXRow","AXCell","AXButton","AXCheckBox","AXSwitch","AXRadioButton","AXPopUpButton","AXDisclosureTriangle"].contains(role) else { return "" }
        var queue = children(e), cursor = 0, parts: [String] = []
        if let title = element(e,kAXTitleUIElementAttribute) {
            let text = direct(title)
            if !text.isEmpty { parts.append(text) }
        }
        while cursor < queue.count && cursor < 24 && parts.joined(separator:" ").count < 160 {
            let child = queue[cursor]; cursor += 1
            let text = direct(child)
            if !text.isEmpty && !parts.contains(text) { parts.append(text) }
            queue += children(child)
        }
        if parts.isEmpty, let parent = element(e,kAXParentAttribute) {
            var nearby = children(parent), i = 0
            while i < nearby.count && i < 24 && parts.joined(separator:" ").count < 160 {
                let item = nearby[i]; i += 1
                if !CFEqual(item,e) {
                    let text = direct(item)
                    if !text.isEmpty && !parts.contains(text) { parts.append(text) }
                }
                nearby += children(item)
            }
            // A name borrowed from what sits beside it (Fastmail's unnamed ▾ beside "Compose"): never mistaken for that control itself.
            if !parts.isEmpty { return String(("next to " + parts.joined(separator:" ")).prefix(160)) }
        }
        return String(parts.joined(separator:" ").prefix(160))
    }
    static func trusted() throws { guard AXIsProcessTrusted() else { throw Failure("Allow Aurel in System Settings → Privacy & Security → Accessibility") }; AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(),0.15) }
    static func app(_ request: String? = nil) throws -> NSRunningApplication {
        if let request, !request.isEmpty {
            if let pid = Int32(request), let a = NSRunningApplication(processIdentifier: pid) { MiniScreen.work(a); return a }
            let apps = NSWorkspace.shared.runningApplications.filter { normalized($0.localizedName ?? "") == normalized(request) || $0.bundleIdentifier == request }
            guard apps.count == 1 else { throw Failure("No unique running app named \(request).") }; MiniScreen.work(apps[0]); return apps[0]
        }
        guard let a = NSWorkspace.shared.frontmostApplication else { throw Failure("No front app.") }; return a
    }
    static func windowElement(_ e: AXUIElement, app: AXUIElement) -> Bool {
        !CFEqual(e,app) && ["AXWindow","AXSheet"].contains(attribute(e,kAXRoleAttribute) as? String ?? "")
    }
    // The window's Core Graphics number: its AX number, else the one window of this app with exactly its frame; "" when unknown.
    static func windowNumber(_ a: NSRunningApplication, _ w: AXUIElement) -> String {
        if let number = axWindowNumber(w) { return number.stringValue }
        let wf = frame(w)
        let windows = (CGWindowListCopyWindowInfo(.optionAll,kCGNullWindowID) as? [[String:Any]] ?? []).filter {
            ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == a.processIdentifier && ($0[kCGWindowLayer as String] as? Int) == 0 &&
            ($0[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation:$0) }.map { abs($0.minX - wf.minX) < 2 && abs($0.minY - wf.minY) < 2 && abs($0.width - wf.width) < 2 && abs($0.height - wf.height) < 2 } == true
        }
        return windows.count == 1 ? (windows[0][kCGWindowNumber as String] as? NSNumber)?.stringValue ?? "" : ""
    }
    static func userWindowLists() -> [String: [String]] {
        userWindowsFile.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: [String]] } ?? [:]
    }
    static func keepTaskWindow(_ a: NSRunningApplication, _ w: AXUIElement, _ lists: [String: [String]]) {
        let own = windowNumber(a,w), key = String(a.processIdentifier)
        guard claims, let file = userWindowsFile, lists[key] == nil, !own.isEmpty else { return }
        let others = (CGWindowListCopyWindowInfo(.optionAll,kCGNullWindowID) as? [[String:Any]] ?? []).compactMap {
            ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == a.processIdentifier && ($0[kCGWindowLayer as String] as? Int) == 0 ? ($0[kCGWindowNumber as String] as? NSNumber)?.stringValue : nil
        }
        try? JSONSerialization.data(withJSONObject: lists.merging([key: others.filter { $0 != own }]) { $1 }).write(to: file, options: .atomic)
    }
    static func root(_ a: NSRunningApplication) throws -> (AXUIElement, AXUIElement) {
        try checkStopped()
        guard !a.isTerminated else { throw Failure("The mapped app closed. Run see again.") }
        let e = AXUIElementCreateApplication(a.processIdentifier), start = Date()
        // Unsupported AX attributes are harmless; request lazy accessibility in any app.
        _ = AXUIElementSetAttributeValue(e, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        let enhancedKey = "AXEnhancedUserInterface", oldEnhanced = attribute(e,enhancedKey)
        let changedEnhanced = oldEnhanced.map { !CFEqual($0,kCFBooleanTrue) } ?? false
        if changedEnhanced, let oldEnhanced,
           AXUIElementSetAttributeValue(e,enhancedKey as CFString,kCFBooleanTrue) == .success {
            // Keep lazy AX content available through traversal and action verification.
            accessibilityRestores.append { _ = AXUIElementSetAttributeValue(e,enhancedKey as CFString,oldEnhanced) }
        }
        let axWindows = (attribute(e,kAXWindowsAttribute) as? [AXUIElement]) ?? []
        // A pinned task window resolves exactly or fails: never a stand-in, such as the user's own window of the same app.
        // It is found the same ways as an unpinned one (an app's AX window list can omit its focused window).
        let all = [element(e,kAXFocusedWindowAttribute), element(e,kAXMainWindowAttribute)].compactMap { $0 } + axWindows
        let lists = userWindowLists(), users = Set(lists[String(a.processIdentifier)] ?? [])
        func allowed(_ w: AXUIElement) -> Bool { (pinnedWindow.map { windowNumber(a,w) == $0 } ?? true) && (users.isEmpty || !users.contains(windowNumber(a,w))) }
        if let aim, let n = windowAt(aim, a.processIdentifier).map(String.init), let w = all.first(where: { windowNumber(a,$0) == n }), windowElement(w,app:e) {
            guard allowed(w) else { throw Failure("That point is in the user's other \(a.localizedName ?? "app") window, not this task's. Nothing was done; say so; do not switch windows.") }
            keepTaskWindow(a,w,lists); return (e,w)
        }
        for w in all.filter(allowed) {
            try checkStopped(); if Date().timeIntervalSince(start) >= 0.3 { break }
            if windowElement(w,app:e) { keepTaskWindow(a,w,lists); return (e,w) }
        }
        // Some apps omit AXWindows. Hit-test only this app's own CG window frames.
        let windows = (CGWindowListCopyWindowInfo(.optionAll,kCGNullWindowID) as? [[String:Any]]) ?? []
        for info in windows where (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == a.processIdentifier && (info[kCGWindowLayer as String] as? Int).map({ (0..<20).contains($0) || $0 == 101 }) == true {   // 101: pop-up menu level, where menu bar panels (Bluetooth, Wi-Fi) open; a pin is checked on the window found
            if Date().timeIntervalSince(start) >= 0.3 { break }
            guard let bounds = info[kCGWindowBounds as String] as? NSDictionary, let rect = CGRect(dictionaryRepresentation:bounds) else { continue }
            var hit: AXUIElement?
            AXUIElementCopyElementAtPosition(e,Float(rect.midX),Float(rect.midY),&hit)
            if hit == nil || hit.map({ CFEqual($0,e) }) == true { AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(),Float(rect.midX),Float(rect.midY),&hit) }
            if let hit { var pid:pid_t = 0; AXUIElementGetPid(hit,&pid); if pid != a.processIdentifier { continue } }
            if var current = hit {
                for _ in 0..<40 {
                    try checkStopped(); if Date().timeIntervalSince(start) >= 0.3 { break }
                    if windowElement(current,app:e) { var pid:pid_t = 0; AXUIElementGetPid(current,&pid); if pid == a.processIdentifier && allowed(current) { keepTaskWindow(a,current,lists); return (e,current) } }
                    guard let parent = element(current,kAXParentAttribute), !CFEqual(parent,current) else { break }; current = parent
                }
            }
        }
        if pinnedWindow != nil { throw Failure("This task's \(a.localizedName ?? "app") window closed or changed. Nothing was done; run see again.") }
        if !users.isEmpty { throw Failure("This task's \(a.localizedName ?? "app") window closed. Nothing was done; the other \(a.localizedName ?? "app") windows are the user's, not this task's. Say so; do not switch windows.") }
        // Menu-bar-only apps (Control Center, Wi-Fi, third-party icons at the top right): map their status items instead.
        if let extras = element(e, "AXExtrasMenuBar") { return (e, extras) }
        throw Failure("No accessible window in \(a.localizedName ?? "app").")
    }
    // Read document content independently of the small, visible action map.
    static func documentIdentity(_ a: NSRunningApplication, _ w: AXUIElement) -> String {
        if let number = axWindowNumber(w)?.intValue, number != 0 { return "\(a.processIdentifier):\(number)" }
        let title = normalized(name(w)).replacingOccurrences(of: #"\s+[-–—]\s+[^-–—]+$"#, with:"", options:.regularExpression)
        return "\(a.processIdentifier):0:\(title)"
    }
    static func identify(_ a: NSRunningApplication) throws -> [String: Any] {
        let (_, w) = try root(a)
        return ["identity": documentIdentity(a,w), "app": a.localizedName ?? "app", "window": mask(name(w))]
    }
    static func read(_ a: NSRunningApplication, more: Bool = false, head: Bool = false) throws -> [String: Any] {
        let (_, w) = try root(a)
        let file = state.deletingLastPathComponent().appendingPathComponent("document-read.json")
        let identity = documentIdentity(a,w)
        func resolvePath(_ path: [Int]) throws -> AXUIElement {
            var item = w
            for index in path {
                let children = attribute(item, kAXChildrenAttribute) as? [AXUIElement] ?? []
                guard children.indices.contains(index) else { throw Failure("The document changed. Read again at offset 0.") }
                item = children[index]
            }
            return item
        }
        func signature(_ item: AXUIElement) -> String {
            let role = attribute(item, kAXRoleAttribute) as? String ?? "", label = name(item)
            let hidden = role == "AXSecureTextField" || attribute(item, kAXSubroleAttribute) as? String == "AXSecureTextField" || (["AXTextField", "AXTextArea", "AXSearchField", "AXComboBox"].contains(role) && secret(label))
            let value = hidden ? "" : String(describing: attribute(item, kAXValueAttribute) ?? "" as CFString)
            return digest([role, label, value, String((attribute(item, kAXChildrenAttribute) as? [AXUIElement])?.count ?? 0)])
        }
        var paths: [[Int]] = [[]], guards: [[String: Any]] = [], seen = Set<AXUIElement>()
        if more {
            guard let data = try? Data(contentsOf: file), let saved = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  saved["identity"] as? String == identity, let pending = saved["paths"] as? [[Int]] else { throw Failure("The document changed. Read again at offset 0.") }
            guards = saved["guards"] as? [[String: Any]] ?? []
            for check in guards {
                guard let path = check["path"] as? [Int] else { throw Failure("Read again at offset 0.") }
                let item = try resolvePath(path)
                guard check["signature"] as? String == signature(item) else { throw Failure("The document changed. Read again at offset 0.") }
                seen.insert(item)
            }
            paths = pending
        }
        func orderedPaths(_ item: AXUIElement, _ path: [Int]) -> [[Int]] {
            let items = attribute(item, kAXChildrenAttribute) as? [AXUIElement] ?? []
            let ranked = items.indices.map { index -> (Int,Int,Double) in
                let child = items[index]
                let role = attribute(child,kAXRoleAttribute) as? String ?? "", area = frame(child).width * frame(child).height
                let rank = ["AXTextArea","AXWebArea","AXDocument","AXScrollArea","AXTable","AXOutline"].contains(role) ? 0 :
                           ["AXToolbar","AXMenuBar","AXMenu"].contains(role) ? 2 : 1
                return (index,rank,area)
            }
            return ranked.sorted { $0.1 == $1.1 ? $0.2 > $1.2 : $0.1 < $1.1 }.map { path + [$0.0] }
        }
        let start = Date(), limit = head ? 1500 : 16000, seconds = head ? 0.32 : 5.0
        var cursor = 0, texts: [String] = [], size = 0, page = "", hasWeb = false
        while cursor < paths.count && size < limit && Date().timeIntervalSince(start) < seconds {
            try checkStopped()
            let path = paths[cursor]; cursor += 1
            let item = try resolvePath(path)
            if !seen.insert(item).inserted { continue }
            if !head { guards.append(["path": path, "signature": signature(item)]) }
            let role = attribute(item, kAXRoleAttribute) as? String ?? ""
            let label = [kAXTitleAttribute, kAXDescriptionAttribute, "AXLabel", kAXHelpAttribute, "AXPlaceholderValue"].compactMap { attribute(item, $0) as? String }.first(where: { !$0.isEmpty }) ?? ""
            if role == "AXSecureTextField" || attribute(item, kAXSubroleAttribute) as? String == "AXSecureTextField" ||
               (["AXTextField", "AXTextArea", "AXSearchField", "AXComboBox"].contains(role) && secret(name(item))) ||
               (["AXStaticText", "AXHeading"].contains(role) && secret(name(item))) { continue }
            let raw = attribute(item, kAXValueAttribute)
            let value = raw as? String ?? (raw as? NSAttributedString)?.string ?? (raw as? NSNumber)?.stringValue ?? ""
            func append(_ text: String) {
                guard !text.isEmpty, mask(text) == text else { return }
                let clipped = head ? String(text.prefix(max(0,limit - size))) : text
                if !clipped.isEmpty { texts.append(clipped); size += clipped.count }
            }
            append(label)
            if value != label { append(value) }
            if role == "AXWebArea" {
                hasWeb = true
                if let url = attribute(item, "AXURL") {
                    page = mask((url as? URL)?.absoluteString ?? (url as? String ?? String(describing:url)))
                    append(page)
                }
            }
            if value.isEmpty || !["AXTextField", "AXTextArea", "AXSearchField", "AXComboBox"].contains(role) {
                paths.insert(contentsOf:orderedPaths(item,path),at:cursor)
            }
        }
        if !head {
            let boundedGuards = guards.count <= 64 ? guards : [guards[0]] + guards.suffix(63)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: ["identity": identity, "paths": Array(paths.dropFirst(cursor)), "guards": boundedGuards]).write(to: file, options: .atomic)
            chmod(file.path, 0o600)
        }
        return ["text": texts.joined(separator: "\n"), "incomplete": cursor < paths.count, "identity": identity, "page": page, "web": hasWeb,
                "app": a.localizedName ?? "app", "window": mask(name(w))]
    }
    static func capture(_ a: NSRunningApplication, offscreen: Bool = false) throws -> Map {
        let (e, w) = try root(a), wf = frame(w), start = Date()
        var m = Map(pid: a.processIdentifier, app: a.localizedName ?? "app", window: name(w), windowFrame: array(wf), nodes: [], texts: [], page: "", focused: "", scroll: [])
        m.windowID = windowNumber(a,w)
        var queue: [(AXUIElement, [Int], CGRect)] = [], visited: [AXUIElement] = []
        queue.append((w, [], wf))
        // Keep menus available, but inspect the window's content before global chrome uses the native-app budget.
        if let menu = element(e, kAXMenuBarAttribute) { queue.append((menu, [-1], .null)) }
        for (i, child) in children(e).enumerated() where attribute(child, kAXRoleAttribute) as? String == "AXMenu" { queue.append((child, [-2, i], .null)) }
        let focused = element(e, kAXFocusedUIElementAttribute)
        var cursor = 0, later: [(AXUIElement, [Int], CGRect)] = [], deferring = true
        while true {
            // Web pages last: their links would use up the budget before an app's own toolbar (Chrome's Extensions button). --web reads pages.
            if cursor == queue.count, deferring { deferring = false; queue += later }
            guard cursor < queue.count && cursor < (offscreen ? 6000 : 1800) && Date().timeIntervalSince(start) < 1 else { break }
            try checkStopped()
            let (item, path, clip) = queue[cursor]; cursor += 1
            if visited.contains(where: { CFEqual($0, item) }) { continue }; visited.append(item)
            let role = attribute(item, kAXRoleAttribute) as? String ?? "", bounds = frame(item)
            let visible = clip.isNull ? bounds : bounds.intersection(clip)
            let menu = role.contains("Menu"), shown = offscreen || menu || bounds.isEmpty || (!visible.isNull && visible.width >= 4 && visible.height >= 4)
            if !shown { continue }
            let label = name(item), hidden = role == "AXSecureTextField" || attribute(item, kAXSubroleAttribute) as? String == "AXSecureTextField" || secret(label)
            var value = ""
            if !hidden, let raw = attribute(item, kAXValueAttribute) {
                value = String(mask(raw as? String ?? (raw as? NSNumber)?.stringValue ?? "").prefix(400))
            }
            if role == "AXWebArea", let url = attribute(item, "AXURL") { let s = (url as? URL)?.absoluteString ?? (url as? String ?? ""); if s.hasPrefix("http") { m.page = mask(s) } }
            if role == "AXWebArea", deferring { later.append((item, path, clip)); visited.removeLast(); continue }
            if let focused, CFEqual(focused, item) { m.focused = mask(label.isEmpty ? role : label); m.focusIdentity = "\(role):\(path):\(array(bounds))" }
            if role == "AXScrollArea", let bar = element(item, kAXVerticalScrollBarAttribute), let n = attribute(bar, kAXValueAttribute) as? NSNumber { m.scroll.append(n.doubleValue) }
            if ["AXStaticText", "AXHeading"].contains(role) {
                let text = mask(label.isEmpty ? value : label)
                if !text.isEmpty && !m.texts.contains(text) && m.texts.count < 40 { m.texts.append(text) }
            } else if !["AXApplication","AXWindow","AXGroup","AXScrollArea","AXWebArea","AXUnknown","AXImage","AXMenuBar","AXMenu"].contains(role), !(role.isEmpty && label.isEmpty), m.nodes.count < 70, !bounds.isEmpty || menu {   // a background app's menus have no frame but still open by path
                let r = menu || offscreen ? bounds : visible
                if !m.nodes.contains(where: { $0.role == role && $0.label == mask(label) && $0.frame == array(r) }) {
                    m.nodes.append(Node(id: m.nodes.count + 1, role: role, label: mask(label.isEmpty ? role : label), value: value, frame: array(r), path: path, secret: hidden))
                }
            }
            var childClip = clip
            if !offscreen && ["AXWindow","AXSheet","AXScrollArea","AXWebArea"].contains(role), !bounds.isEmpty { childClip = clip.isNull ? bounds : clip.intersection(bounds) }
            if ["AXTextField","AXTextArea","AXSecureTextField","AXSearchField","AXComboBox"].contains(role) { continue }
            if role == "AXMenuBarItem", (attribute(item, kAXSelectedAttribute) as? Bool) != true { continue }
            let ordered = children(item).enumerated().sorted {
                let priority = { (child: AXUIElement) in
                    let r = attribute(child,kAXRoleAttribute) as? String ?? ""
                    return ["AXSplitGroup","AXOutline","AXTable","AXScrollArea","AXSheet"].contains(r) ? 0 :
                           ["AXToolbar","AXMenuBar","AXMenu"].contains(r) ? 2 : 1
                }
                return priority($0.element) < priority($1.element)
            }
            for (i, child) in ordered { queue.append((child, path + [i], childClip)) }
        }
        return m
    }
    static func save(_ map: Map) throws {
        try FileManager.default.createDirectory(at: state.deletingLastPathComponent(), withIntermediateDirectories: true)
        var stored = try JSONSerialization.jsonObject(with: JSONEncoder().encode(map)) as! [String:Any]
        stored["signature"] = map.signature; stored["rich"] = map.rich
        try JSONSerialization.data(withJSONObject:stored).write(to: state, options: .atomic)
        chmod(state.path, 0o600)
    }
    static func load() throws -> Map {
        guard let data = try? Data(contentsOf: state), let m = try? JSONDecoder().decode(Map.self, from: data) else { throw Failure("Run see first.") }; return m
    }
    static func at(_ path: [Int], _ a: NSRunningApplication) throws -> AXUIElement {
        let (e, w) = try root(a); var current = w, path = path
        if path.first == -1 { guard let menu = element(e, kAXMenuBarAttribute) else { throw Failure("Menu unavailable.") }; current = menu; path.removeFirst() }
        else if path.first == -2 { path.removeFirst(); current = e }
        for i in path { let c = children(current); guard c.indices.contains(i) else { throw Failure("The screen changed. Run see again.") }; current = c[i] }
        return current
    }
    static func drawAnchor(_ label: String, state: String) throws -> (CGRect,AXUIElement?,DrawingWindow) {
        let old = try JSONDecoder().decode(Map.self,from:Data(contentsOf:URL(fileURLWithPath:state)))
        let a = try app(String(old.pid)), fresh = try capture(a)
        guard fresh.windowID == old.windowID, fresh.windowFrame == old.windowFrame else { throw Failure("The window moved. Read again.") }
        let e: AXUIElement?
        if let id = Int(label) {
            guard let oldNode = old.nodes.first(where: { $0.id == id }),
                  let node = fresh.nodes.first(where: { $0.path == oldNode.path }), node.role == oldNode.role, node.label == oldNode.label else { throw Failure("The control changed. Read again.") }
            e = try at(node.path,a)   // a guided value change must not invalidate stable control identities
        } else { e = try resolve(label,map:fresh,a:a).1 }
        guard let e else { throw Failure("No accessible drawing target.") }
        guard let id = UInt32(fresh.windowID),
              let info = (CGWindowListCopyWindowInfo(.optionIncludingWindow,id) as? [[String:Any]])?.first,
              let bounds = MiniScreen.bounds(info) else { throw Failure("The window closed. Read again.") }
        return (visibleFrame(e),e,DrawingWindow(pid:fresh.pid,windowID:fresh.windowID,windowFrame:array(bounds)))
    }
    static func point(_ text: String) throws -> CGPoint? {
        guard matches(text,#"^\s*(?:\d+:)?-?[\d.]+\s*,\s*-?[\d.]+\s*$"#) else { return nil }
        let pieces = text.split(separator: ":", omittingEmptySubsequences: false), pair = pieces.last!.split(separator: ",", omittingEmptySubsequences: false)
        guard pair.count == 2 else { return nil }
        guard let x = Double(pair[0]), let y = Double(pair[1]), x.isFinite, y.isFinite else { throw Failure("Invalid coordinates.") }
        if pieces.count == 1 { return CGPoint(x: x, y: y) }
        guard pieces.count == 2, let n = Int(pieces[0]), NSScreen.screens.indices.contains(n - 1) else { throw Failure("No such screen.") }
        let screen = NSScreen.screens[n - 1], id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? CGMainDisplayID(), r = CGDisplayBounds(id)
        guard x >= 0, y >= 0, x <= 1280, y <= r.height / (r.width / 1280) else { throw Failure("Point is outside that picture.") }
        return picturePoint(x, y, in: r)
    }
    // A --look picture spot (1280 px wide, from this display's top-left) to a global display point; Quartz events use display points.
    static func picturePoint(_ x: Double, _ y: Double, in r: CGRect) -> CGPoint {
        let scale = r.width / 1280
        return CGPoint(x: r.minX + x * scale, y: r.minY + y * scale)
    }
    static func visibleFrame(_ e: AXUIElement) -> CGRect {
        var visible = frame(e), current = e
        for _ in 0..<40 {
            guard let parent = element(current,kAXParentAttribute) else { break }
            let role = attribute(parent,kAXRoleAttribute) as? String ?? ""
            if ["AXWindow","AXScrollArea","AXWebArea","AXSheet"].contains(role), !frame(parent).isEmpty { visible = visible.intersection(frame(parent)) }
            current = parent
        }
        return visible
    }
    static func resolve(_ text: String, map: Map, a: NSRunningApplication, near: String = "") throws -> (Node, AXUIElement?) {
        if let id = Int(text) {
            guard let n = map.nodes.first(where: { $0.id == id }) else { throw Failure("No such control. Run see again.") }; return (n, try at(n.path, a))
        }
        if let p = try point(text) {
            if let n = map.nodes.filter({ CGRect(x:$0.frame[0],y:$0.frame[1],width:$0.frame[2],height:$0.frame[3]).contains(p) }).min(by: { $0.frame[2] * $0.frame[3] < $1.frame[2] * $1.frame[3] }) { return (n, try at(n.path,a)) }
            let (e, _) = try root(a); var hit: AXUIElement?
            AXUIElementCopyElementAtPosition(e, Float(p.x), Float(p.y), &hit)
            if let hit { var pid: pid_t = 0; AXUIElementGetPid(hit, &pid); guard pid == a.processIdentifier else { throw Failure("That point belongs to another app. Run see again.") } }
            if var current = hit {
                for _ in 0..<5 {
                    let role = attribute(current, kAXRoleAttribute) as? String ?? ""
                    if !name(current).isEmpty && !["AXStaticText","AXGroup","AXWindow","AXApplication","AXScrollArea","AXWebArea"].contains(role) {
                        let n = Node(id: 0, role: role, label: mask(name(current)), value: "", frame: [p.x,p.y,0,0], path: [], secret: secret(name(current)))
                        return (n, current)
                    }
                    guard let parent = element(current, kAXParentAttribute) else { break }; current = parent
                }
            }
            let bounds = CGRect(x:map.windowFrame[0],y:map.windowFrame[1],width:map.windowFrame[2],height:map.windowFrame[3])
            guard bounds.contains(p) else { throw Failure("That point is outside the mapped window. Run see again.") }
            return (Node(id:0,role:"AXUnknown",label:"Unidentified screen point \(Int(p.x)),\(Int(p.y))",value:"",frame:[p.x,p.y,0,0],path:[],secret:false),nil)
        }
        let candidates = map.nodes.filter { rank($0.label, text) > 0 }
        var anchor = map.nodes.first { rank($0.label, near) == 4 }
        if anchor == nil, !near.isEmpty, let e = try findText(near,a), rank(name(e),near) == 4 {
            let bounds = visibleFrame(e)
            if !bounds.isNull && bounds.width >= 4 && bounds.height >= 4 { anchor = Node(id:0,role:"AXStaticText",label:near,value:"",frame:array(bounds),path:[],secret:false) }
        }
        func distance(_ n: Node) -> Double { guard let anchor else { return Double(n.id) }; return hypot(n.spot.x - anchor.spot.x, n.spot.y - anchor.spot.y) }
        let sorted = candidates.sorted { rank($0.label, text) == rank($1.label, text) ? distance($0) < distance($1) : rank($0.label, text) > rank($1.label, text) }
        if near.isEmpty && (sorted.first.map { rank($0.label,text) } ?? 0) < 4, let e = try findText(text,a), rank(name(e),text) > (sorted.first.map { rank($0.label,text) } ?? 0) {
            let r = visibleFrame(e)
            if !r.isNull && r.width >= 4 && r.height >= 4 {
                return (Node(id:0,role:attribute(e,kAXRoleAttribute) as? String ?? "AXStaticText",label:mask(name(e)),value:"",frame:array(r),path:[],secret:false),e)
            }
        }
        guard let n = sorted.first else { throw Failure("No visible control named \(quote(mask(text))). Use scroll-to for offscreen text.") }
        if near.isEmpty && sorted.count > 1 && rank(sorted[1].label, text) == rank(n.label, text) {
            let tied = sorted.prefix { rank($0.label, text) == rank(n.label, text) }
            if let row = tied.first(where: { $0.role == "AXRow" }),
               tied.allSatisfy({ $0.id == row.id || ($0.role == "AXCell" && $0.path.starts(with: row.path)) }) {
                return (row, try at(row.path, a))
            }
            throw Failure("More than one control named \(quote(text)); use near.")
        }
        if !near.isEmpty && anchor == nil { throw Failure("No nearby anchor named \(quote(near)).") }
        return (n, try at(n.path, a))
    }
    static func actions(_ e: AXUIElement) -> [String] { var names: CFArray?; AXUIElementCopyActionNames(e, &names); return names as? [String] ?? [] }
    static func perform(_ e: AXUIElement, _ names: [String]) -> Bool {
        let supported = actions(e)
        // cannotComplete: the press opened a modal sheet and the app stopped answering AX; the action ran, so never retry it with the mouse
        return names.contains { supported.contains($0) && [.success, .cannotComplete].contains(AXUIElementPerformAction(e, $0 as CFString)) }
    }
    static func menuItem(_ text: String, _ parent: AXUIElement) throws -> AXUIElement {
        var q = children(parent), i = 0
        while i < q.count && i < 300 {
            let e = q[i]; i += 1
            if rank(name(e), text) == 4 { return e }
            let role = attribute(e, kAXRoleAttribute) as? String ?? ""
            if role == "AXMenu" || role == "AXMenuBarItem" { q += children(e) }
        }
        throw Failure("No menu item named \(quote(text)).")
    }
    static func menu(_ path: String, _ a: NSRunningApplication, act: Bool) throws -> String {
        try checkStopped(); guard !a.isTerminated else { throw Failure("The target app closed.") }
        let e = AXUIElementCreateApplication(a.processIdentifier); AXUIElementSetMessagingTimeout(e,0.15)
        guard var parent = element(e, kAXMenuBarAttribute) else { throw Failure("No accessible menu bar.") }
        let parts = path.components(separatedBy: ">").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count > 1, parts.allSatisfy({ !$0.isEmpty }) else { throw Failure("Invalid menu path.") }
        var restore: (() -> Void)?, lease: Int32?
        if act {   // a press can bring the app forward: tell the focus guard it's on purpose, then put the user's app back
            try keysReachTask(a.processIdentifier)
            lease = try screenLease()
            DistributedNotificationCenter.default().postNotificationName(.init("aurel.raise"), object: nil, deliverImmediately: true)
            usleep(50_000); restore = restoreFocus(a)
        }
        defer { if let restore { usleep(30_000); restore() }; if let lease { flock(lease,LOCK_UN); Darwin.close(lease) } }
        for (index, part) in parts.enumerated() {
            try checkStopped()
            let item = try menuItem(part, parent), label = mask(name(item))
            if act { guard perform(item, ["AXPress","AXPick","AXOpen","AXShowMenu"]) else { throw Failure("Could not open menu \(quote(part)).") }; usleep(15_000) }
            parent = item
            // AX exposes AppKit submenus without opening them; no press occurs during safety resolution.
            if index == parts.count - 1 { return label }
        }
        throw Failure("Invalid menu path.")
    }
    // AXMenuItemCmdModifiers bits: 1 shift, 2 option, 4 control, 8 no command.
    static func isShortcut(_ text: String, cmdChar: String, modifiers: Int) -> Bool {
        guard let (_, flags) = try? keys(text), let key = normalized(text).replacingOccurrences(of:" ",with:"").split(separator:"+",omittingEmptySubsequences:false).last, key.count == 1 else { return false }
        return flags.contains(.maskCommand) && modifiers & 8 == 0 && cmdChar.uppercased() == key.uppercased() &&
            (modifiers & 1 != 0) == flags.contains(.maskShift) && (modifiers & 2 != 0) == flags.contains(.maskAlternate) && (modifiers & 4 != 0) == flags.contains(.maskControl)
    }
    // Background keys reach an app's views but never its menu shortcuts (a background cmd+s saves nothing; trycua/cua-driver found the same),
    // so a native app behind the user's runs the enabled menu item for that shortcut. Web content keeps its keys: the page may handle them.
    static func menuShortcut(_ text: String, _ a: NSRunningApplication) -> (AXUIElement, String)? {
        guard !MiniScreen.workInFront, NSWorkspace.shared.frontmostApplication?.processIdentifier != a.processIdentifier, !webFocused(a.processIdentifier) else { return nil }
        let application = AXUIElementCreateApplication(a.processIdentifier); AXUIElementSetMessagingTimeout(application, 0.15)
        guard let bar = element(application, kAXMenuBarAttribute) else { return nil }
        var queue = children(bar).dropFirst().map { ($0, [name($0)], 0) }, i = 0; let start = Date()   // the Apple menu belongs to the system
        while i < queue.count && i < 2000 && Date().timeIntervalSince(start) < 0.5 {
            let (item, path, depth) = queue[i]; i += 1
            if let char = attribute(item, "AXMenuItemCmdChar") as? String, !char.isEmpty {
                if isShortcut(text, cmdChar: char, modifiers: (attribute(item, "AXMenuItemCmdModifiers") as? NSNumber)?.intValue ?? 0),
                   attribute(item, kAXEnabledAttribute) as? Bool != false { return (item, mask(path.joined(separator: " > "))) }
            } else if depth < 6 {
                for child in children(item) { queue.append((child, attribute(child, kAXRoleAttribute) as? String == "AXMenu" ? path : path + [name(child)], depth + 1)) }
            }
        }
        return nil
    }
    static func sendKeys(_ text: String, pid: Int32, times: Int = 1) throws {
        let (code, flags) = try keys(text)
        guard (1...50).contains(times), let source = CGEventSource(stateID: .privateState) else { throw Failure("Invalid key repeat count.") }
        try keysReachTask(pid)
        let web = !flags.contains(.maskCommand) && NSWorkspace.shared.frontmostApplication?.processIdentifier != pid && webFocused(pid)
        for _ in 0..<times {
            try checkStopped()
            for down in [true, false] { guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { throw Failure("Could not create key event.") }; event.flags = flags; postKey(event, pid: pid, web: web) }
        }
    }
    // Background input: each event goes to the app's process with its window stamped in, so the pointer, the front app,
    // window order and Spaces stay as they are. The SkyLight calls are optional; without them the public per-process post is used.
    static let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    static let stampLocation = dlsym(skyLight, "CGEventSetWindowLocation").map { unsafeBitCast($0, to: (@convention(c) (CGEvent, CGPoint) -> Void).self) }
    static let skyPost = dlsym(skyLight, "SLEventPostToPid").map { unsafeBitCast($0, to: (@convention(c) (pid_t, CGEvent) -> Void).self) }
    // Background web content (Chromium, Electron) takes keys as live input only through SkyLight with an authentication message
    // (macOS 15+; technique from trycua/cua-driver, MIT). Other keys keep the plain post: authenticated keys skip the path menu shortcuts use.
    static let authenticate = dlsym(skyLight, "SLEventSetAuthenticationMessage").map { unsafeBitCast($0, to: (@convention(c) (CGEvent, AnyObject) -> Void).self) }
    static func postKey(_ e: CGEvent, pid: Int32, web: Bool) {
        let factory = NSSelectorFromString("messageWithEventRecord:pid:version:")
        guard web, let skyPost, let authenticate, let type: AnyClass = NSClassFromString("SLSEventAuthenticationMessage"), (type as AnyObject).responds(to: factory),
              let method = (type as AnyObject).method(for: factory),
              let record = Unmanaged.passUnretained(e).toOpaque().load(fromByteOffset: 24, as: UnsafeMutableRawPointer?.self),   // CGEvent: CFRuntimeBase, UInt32, SLSEventRecord *
              let message = unsafeBitCast(method, to: (@convention(c) (AnyClass, Selector, UnsafeMutableRawPointer, Int32, UInt32) -> Unmanaged<AnyObject>?).self)(type, factory, record, pid, 0)?.takeUnretainedValue()
        else { return e.postToPid(pid) }
        authenticate(e, message); skyPost(pid, e)
    }
    // An app hands mouse input to a window's content only while it counts that window as key. This window-server focus record makes it so
    // without raising the window, activating the app or taking key from the user's window (yabai's focus without raise, via cua-driver).
    static let postRecord = dlsym(skyLight, "SLPSPostEventRecordTo").map { unsafeBitCast($0, to: (@convention(c) (UnsafeRawPointer, UnsafeRawPointer) -> Int32).self) }
    static let processForPid = dlsym(dlopen("/System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework/HIServices", RTLD_LAZY), "GetProcessForPID").map { unsafeBitCast($0, to: (@convention(c) (pid_t, UnsafeMutableRawPointer) -> Int32).self) }
    // Off (after the gesture) hands the app back its inactive state.
    static func focusWithoutRaise(_ pid: Int32, _ window: UInt32, on: Bool = true) {
        var psn: [UInt32] = [0, 0], record = [UInt8](repeating: 0, count: 0xF8)
        guard let postRecord, let processForPid, processForPid(pid, &psn) == 0 else { return }
        record[0x04] = 0xF8; record[0x08] = 0x0D; record[0x8A] = on ? 1 : 2
        withUnsafeBytes(of: window.littleEndian) { record.replaceSubrange(0x3C..<0x40, with: $0) }
        usleep(on ? 0 : 50_000)   // the gesture's queued events land while the window is still key
        _ = psn.withUnsafeBytes { p in record.withUnsafeBytes { postRecord(p.baseAddress!, $0.baseAddress!) } }
        usleep(on ? 50_000 : 0)   // AppKit settles its key window before the events arrive
    }
    // A click in a key window brings it in front of its app's other windows: the one that was in front goes back.
    static func keepOrder(_ pid: Int32) -> () -> Void {
        func top() -> UInt32? {
            ((CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String:Any]]) ?? []).first { ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid && ($0[kCGWindowLayer as String] as? Int) == 0 }
                .flatMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value }
        }
        let before = top()
        return {
            usleep(50_000)
            guard let before, top() != before, let a = NSRunningApplication(processIdentifier: pid),
                  let w = (attribute(AXUIElementCreateApplication(pid), kAXWindowsAttribute) as? [AXUIElement])?.first(where: { windowNumber(a, $0) == String(before) }) else { return }
            _ = perform(w, ["AXRaise"])
        }
    }
    static func deliver(_ e: CGEvent, at p: CGPoint, pid: Int32, window: UInt32, fields: [UInt32: Int64] = [:]) {
        e.flags = []; e.location = p; stampLocation?(e, p)
        let routing: [UInt32: Int64] = window == 0 ? [40: Int64(pid)] : [40: Int64(pid), 51: Int64(window), 91: Int64(window), 92: Int64(window)]
        for (field, value) in fields.merging(routing, uniquingKeysWith: { $1 }) { e.setIntegerValueField(CGEventField(rawValue: field)!, value: value) }
        if let skyPost { skyPost(pid, e) } else { e.postToPid(pid) }
    }
    static func targetWindow(_ a: NSRunningApplication) -> UInt32 { (try? root(a)).flatMap { UInt32(windowNumber(a,$0.1)) } ?? 0 }
    // The app's window a real click at p would reach: its topmost visible window there. A task's pinned window always wins.
    static func windowAt(_ p: CGPoint, _ pid: Int32) -> UInt32? {
        windowsAt(p).first { ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid }.flatMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value }
    }
    // Visible app windows (layer 0: never Aurel's own panels) containing p, front to back; none when a task window is pinned.
    static func windowsAt(_ p: CGPoint) -> [[String:Any]] {
        guard pinnedWindow == nil else { return [] }
        return ((CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String:Any]]) ?? []).filter {
            ($0[kCGWindowLayer as String] as? Int) == 0 && ($0[kCGWindowAlpha as String] as? Double ?? 1) > 0 &&
            ($0[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation:$0) }?.contains(p) == true
        }
    }
    // A click or drag at a screen point acts in the window a picture shows there, in any app; other targets use the mapped app.
    static func aimed(_ args: [String], _ old: Map) throws -> NSRunningApplication {
        aim = ["click","drag"].contains(args.first ?? "") && args.count > 1 ? try point(args[1]) : nil
        let owner = aim.flatMap { (windowsAt($0).first?[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value }
        return try app(String(owner ?? old.pid))
    }
    // macOS ignores activate() from a process that isn't active itself (the hands helper never is); Launch Services still does it.
    static func bringForward(_ a: NSRunningApplication) -> Bool {
        func front() -> Bool { NSWorkspace.shared.frontmostApplication?.processIdentifier == a.processIdentifier }
        a.activate(); usleep(30_000)
        if !front(), let url = a.bundleURL {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/open"); p.arguments = ["-a", url.path]; try? p.run(); p.waitUntilExit()
            for _ in 0..<20 where !front() { usleep(50_000) }
        }
        return front()
    }
    static func restoreFocus(_ a: NSRunningApplication) -> () -> Void {
        if MiniScreen.workInFront { return {} }
        let previous = NSWorkspace.shared.frontmostApplication
        let window = previous.flatMap { element(AXUIElementCreateApplication($0.processIdentifier),kAXFocusedWindowAttribute) }
        return {
            guard let previous, previous != a, !previous.isTerminated, NSWorkspace.shared.frontmostApplication == a else { return }
            _ = bringForward(previous)
            if let window { _ = perform(window,["AXRaise"]) }
        }
    }
    static func webFocused(_ pid: Int32) -> Bool {
        let application = AXUIElementCreateApplication(pid); AXUIElementSetMessagingTimeout(application, 0.15)
        var item = element(application, kAXFocusedUIElementAttribute)
        for _ in 0..<64 {
            guard let e = item else { return false }
            if attribute(e, kAXRoleAttribute) as? String == "AXWebArea" { return true }
            item = element(e, kAXParentAttribute).flatMap { CFEqual($0, e) ? nil : $0 }
        }
        return false
    }
    // An app sends keys and menu commands to its own focused window. With a task window pinned, or user windows beside it, they go only when the task's window has the focus.
    static func keysReachTask(_ pid: Int32) throws {
        guard pinnedWindow != nil || userWindowLists()[String(pid)]?.isEmpty == false, let a = NSRunningApplication(processIdentifier: pid) else { return }
        let (e, w) = try root(a)
        func reaches() -> Bool {
            var current = element(e,kAXFocusedUIElementAttribute)
            if current.map({ CFEqual($0,e) }) ?? true { current = element(e,kAXFocusedWindowAttribute) }
            for _ in 0..<64 {
                guard let item = current else { return false }
                if CFEqual(item,w) { return true }
                current = element(item,kAXParentAttribute).flatMap { CFEqual($0,item) ? nil : $0 }
            }
            return false
        }
        if reaches() { return }
        if MiniScreen.workInFront { _ = perform(w,["AXRaise"]); usleep(50_000); if reaches() { return } }   // the user asked to work in front
        throw Failure("Keys would go to another \(a.localizedName ?? "app") window, not this task's. Nothing was pressed.")
    }
    static func mouse(_ from: CGPoint, _ a: NSRunningApplication, double: Bool = false, right: Bool = false, to: CGPoint? = nil, front: Bool = false) throws {
        guard env["AUREL_AX_ONLY"] != "1" else { throw Failure("Quartz mouse actions disabled for this fixture.") }
        let pid = a.processIdentifier, window = windowAt(from, a.processIdentifier) ?? targetWindow(a), gesture = Int64(DispatchTime.now().uptimeNanoseconds % 1_000_000_000)
        if front || window == 0 || MiniScreen.workInFront { return try frontMouse(from, a, double: double, right: right, to: to) }   // no known window: never an unbound event
        guard let source = CGEventSource(stateID: .hidSystemState) else { throw Failure("Could not create mouse event.") }
        // Field 0 carries the gesture phase, 1 the click count, 3 the button, 7 the subtype, 58 one id for the whole gesture.
        func post(_ type: CGEventType, _ p: CGPoint, phase: Int64, count: Int64, subtype: Int64 = 3, wait: UInt32) throws {
            let button: Int64 = [.rightMouseDown, .rightMouseUp, .rightMouseDragged].contains(type) ? 1 : 0
            guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: button == 1 ? .right : .left) else { throw Failure("Could not create mouse event.") }
            deliver(e, at: p, pid: pid, window: window, fields: [0: phase, 1: count, 3: button, 7: subtype, 58: gesture]); usleep(wait * 1000)
        }
        let (down, dragged, up): (CGEventType, CGEventType, CGEventType) = right ? (.rightMouseDown, .rightMouseDragged, .rightMouseUp) : (.leftMouseDown, .leftMouseDragged, .leftMouseUp)
        try checkStopped()
        let restoreOrder = keepOrder(pid); defer { restoreOrder() }
        focusWithoutRaise(pid, window); defer { focusWithoutRaise(pid, window, on: false) }
        var held = false
        defer { if held { try? post(up, to ?? from, phase: 3, count: 1, wait: 0) } }
        // A move primes the window's hit-testing; an off-screen click opens Chromium's user-activation gate for background input.
        try post(.mouseMoved, from, phase: 2, count: 0, wait: 15)
        if !right { try post(.leftMouseDown, CGPoint(x: -1, y: -1), phase: 1, count: 1, wait: 1); try post(.leftMouseUp, CGPoint(x: -1, y: -1), phase: 2, count: 1, wait: 100) }
        if let to {
            try post(down, from, phase: 3, count: 1, subtype: 0, wait: 30); held = true
            for i in 1...20 { try checkStopped(); let t = Double(i) / 20; try post(dragged, CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t), phase: 3, count: 1, subtype: 0, wait: i == 20 ? 50 : 8) }
            try post(up, to, phase: 3, count: 1, subtype: 0, wait: 0); held = false
            return
        }
        for count in 1...(double ? 2 : 1) {
            try checkStopped()
            try post(down, from, phase: 3, count: Int64(count), wait: right ? 28 : 1); held = true
            try post(up, from, phase: 3, count: Int64(count), wait: double && count == 1 ? 80 : 0); held = false
        }
    }
    static func screenLease() throws -> Int32 { try lease("screen.lock") }
    static var leaseWaited = false
    // Locks shared by every Aurel process (the app and each hands helper): the screen, the clipboard, one app's input.
    static func lease(_ name: String, wait: Bool = true) throws -> Int32 {
        let root = (Prefs.path as NSString).deletingLastPathComponent
        let fd = Darwin.open(root + "/" + name, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw Failure("Could not lock \(name).") }
        let waiting = name == "screen.lock" ? env["AUREL_ASK"].map { $0 + "/screen-wait" } : nil
        defer { if let waiting { try? FileManager.default.removeItem(atPath: waiting) } }
        leaseWaited = false
        do {
            while flock(fd, LOCK_EX | LOCK_NB) != 0 {
                guard errno == EWOULDBLOCK, wait else { throw Failure("Could not lock \(name).") }
                leaseWaited = true
                if let waiting { try? Data().write(to: URL(fileURLWithPath: waiting), options: .atomic); try? FileManager.default.setAttributes([.posixPermissions:0o600], ofItemAtPath:waiting) }
                try checkStopped(); usleep(25_000)
            }
            return fd
        } catch { Darwin.close(fd); throw error }
    }
    static func unlock(_ fd: Int32) { flock(fd, LOCK_UN); Darwin.close(fd) }
    static func fingerprint(_ map: Map, around spot: CGPoint? = nil) -> [UInt8] {
        // No disk image is kept. With a spot: the real screen 64x40 points around it, minus Aurel's own ring and box, so a
        // click shows whether it took even when the target window is full screen or on another Space, where a window-only
        // capture returns a stale frame. Without a spot (scroll, settle): the target window's content, 64x40.
        final class Capture { let lock = NSLock(); var image: CGImage? }
        let result = Capture(), done = DispatchSemaphore(value: 0), id = spot.flatMap { windowAt($0, map.pid) } ?? UInt32(map.windowID)
        Task {
            defer { done.signal() }
            guard let all = try? await SCShareableContent.excludingDesktopWindows(true,onScreenWindowsOnly:false) else { return }
            let filter: SCContentFilter, cfg = SCStreamConfiguration(); cfg.width = 64; cfg.height = 40
            if let spot, let display = all.displays.first(where: { $0.frame.contains(spot) }) {
                filter = SCContentFilter(display: display, excludingWindows: all.windows.filter { $0.owningApplication?.bundleIdentifier == Bundle.main.bundleIdentifier })
                cfg.sourceRect = CGRect(x: spot.x - display.frame.minX - 32, y: spot.y - display.frame.minY - 20, width: 64, height: 40)
            } else {
                guard let window = all.windows.first(where: {
                          guard $0.owningApplication?.processID == map.pid && $0.windowLayer == 0 else { return false }
                          if let id { return $0.windowID == id }
                          return array($0.frame) == map.windowFrame
                      }) else { return }
                filter = SCContentFilter(desktopIndependentWindow: window)
            }
            guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg) else { return }
            result.lock.withLock { result.image = image }
        }
        guard done.wait(timeout:.now() + 0.5) == .success else { return [] }
        result.lock.lock(); let captured = result.image; result.lock.unlock()
        guard let image = captured else { return [] }
        var pixels = [UInt8](repeating: 0, count: 64 * 40)
        pixels.withUnsafeMutableBytes { buffer in
            if let c = CGContext(data: buffer.baseAddress, width: 64, height: 40, bitsPerComponent: 8, bytesPerRow: 64, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0) { c.interpolationQuality = .low; c.draw(image, in: CGRect(x: 0,y: 0,width: 64,height: 40)) }
        }
        return pixels
    }
    static func pixelsChanged(_ before: [UInt8], _ after: [UInt8], threshold: Double = 4) -> Bool {
        guard !before.isEmpty, before.count == after.count else { return false }
        return zip(before, after).reduce(0.0) { $0 + abs(Double($1.0) - Double($1.1)) } / Double(before.count) >= threshold
    }
    // The foreground route: the app comes forward and the real pointer acts, then the pointer and the user's app go back.
    // Used for work the user asked to see, a window without a known id, and a scroll nothing else could move.
    static func raise(_ a: NSRunningApplication) throws {
        DistributedNotificationCenter.default().postNotificationName(.init("aurel.raise"), object: nil, deliverImmediately: true)   // tell the focus guard this one is on purpose
        usleep(50_000)   // let the guard hear it before the app comes forward
        let (_, w) = try root(a); _ = perform(w, ["AXRaise"])
        guard bringForward(a) else { throw Failure("Could not focus the mapped app.") }
        _ = perform(w, ["AXRaise"])   // its task window, not whichever one it was showing
    }
    static func frontMouse(_ from: CGPoint, _ a: NSRunningApplication, double: Bool, right: Bool, to: CGPoint?) throws {
        try inFront(a) { try frontClicks(from, double: double, right: right, to: to) }
    }
    // The app forward for a few steps on the real pointer and keys, then the user's app back.
    static func inFront(_ a: NSRunningApplication, _ body: () throws -> Void) throws {
        _ = NSApplication.shared   // the real pointer needs a window-server connection; the hands helper has none until now
        let lease = try screenLease(); defer { unlock(lease) }
        let restore = restoreFocus(a); defer { usleep(30_000); restore() }
        try raise(a)
        try body()
    }
    static func frontClicks(_ from: CGPoint, double: Bool = false, right: Bool = false, to: CGPoint? = nil) throws {
        guard let source = CGEventSource(stateID: .privateState), let saved = CGEvent(source: source)?.location else { throw Failure("Could not create mouse event.") }
        let button: CGMouseButton = right ? .right : .left
        defer { CGWarpMouseCursorPosition(saved) }
        func post(_ type: CGEventType, _ p: CGPoint, _ count: Int) throws {
            guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: button) else { throw Failure("Could not create mouse event.") }
            e.flags = []; e.setIntegerValueField(.mouseEventClickState, value: Int64(count)); e.post(tap: .cghidEventTap)
        }
        var held = false
        defer { if held { try? post(right ? .rightMouseUp : .leftMouseUp, to ?? from, 1) } }
        for count in 1...(double ? 2 : 1) {
            try checkStopped()
            try post(right ? .rightMouseDown : .leftMouseDown, from, count)
            held = true
            if let to {
                for i in 1...20 { try checkStopped(); let t = Double(i) / 20; try post(.leftMouseDragged, CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t), count); usleep(8_000) }
            }
            try post(right ? .rightMouseUp : .leftMouseUp, to ?? from, count)
            held = false
        }
    }
    static func frontWheel(_ direction: String, _ spot: CGPoint, _ a: NSRunningApplication, fraction: Double) throws {
        _ = NSApplication.shared   // the real pointer needs a window-server connection; the hands helper has none until now
        let lease = try screenLease(); defer { unlock(lease) }
        let restore = restoreFocus(a); defer { usleep(30_000); restore() }
        try raise(a)
        guard let source = CGEventSource(stateID: .privateState), let saved = CGEvent(source: source)?.location else { throw Failure("Could not create scroll event.") }
        defer { CGWarpMouseCursorPosition(saved) }; CGWarpMouseCursorPosition(spot)
        let vertical = ["down","up"].contains(direction), amount = Int32(((["down","right"].contains(direction) ? -500.0 : 500.0) * fraction).rounded())
        guard let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2, wheel1: vertical ? amount : 0, wheel2: vertical ? 0 : amount, wheel3: 0) else { throw Failure("Could not create scroll event.") }
        event.flags = []; event.post(tap: .cghidEventTap)
    }
    static func scrollArea(_ a: NSRunningApplication, target: CGPoint? = nil) throws -> AXUIElement {
        let (_, w) = try root(a), start = Date(); var queue = [w], i = 0, found: [AXUIElement] = []
        while i < queue.count && i < 1800 && Date().timeIntervalSince(start) < 0.3 {
            try checkStopped()
            let e = queue[i]; i += 1
            if attribute(e, kAXRoleAttribute) as? String == "AXScrollArea", target == nil || frame(e).contains(target!) { found.append(e) }
            queue += children(e)
        }
        guard let area = found.sorted(by: { target == nil ? frame($0).width * frame($0).height > frame($1).width * frame($1).height : frame($0).width * frame($0).height < frame($1).width * frame($1).height }).first else { throw Failure("No scroll area.") }; return area
    }
    static func wheel(_ direction: String, _ spot: CGPoint, _ a: NSRunningApplication, fraction: Double = 1, front: Bool = false) throws {
        guard env["AUREL_AX_ONLY"] != "1" else { throw Failure("Quartz mouse actions disabled for this fixture.") }
        let pid = a.processIdentifier, window = targetWindow(a)
        if front || window == 0 || MiniScreen.workInFront { return try frontWheel(direction, spot, a, fraction: fraction) }
        guard let source = CGEventSource(stateID: .hidSystemState) else { throw Failure("Could not create scroll event.") }
        let vertical = ["down","up"].contains(direction), amount = Int32(((["down","right"].contains(direction) ? -500.0 : 500.0) * fraction).rounded())
        guard let move = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: spot, mouseButton: .left),
              let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2, wheel1: vertical ? amount : 0, wheel2: vertical ? 0 : amount, wheel3: 0) else { throw Failure("Could not create scroll event.") }
        deliver(move, at: spot, pid: pid, window: window); usleep(12_000)   // the wheel goes to whatever the window last saw under the pointer
        deliver(event, at: spot, pid: pid, window: window)
    }
    static func contentMoved(_ before: Map, _ after: Map) -> Bool {
        let changedText = Set(before.texts).subtracting(after.texts).count >= 3 && Set(after.texts).subtracting(before.texts).count >= 3
        return changedText || before.nodes.contains { n in
            let hits = after.nodes.filter { $0.role == n.role && $0.label == n.label }
            return hits.count == 1 && hypot(n.spot.x - hits[0].spot.x,n.spot.y - hits[0].spot.y) >= 6
        }
    }
    static func pageKeysAllowed(_ a: NSRunningApplication) -> Bool {
        guard let focused = element(AXUIElementCreateApplication(a.processIdentifier),kAXFocusedUIElementAttribute), let role = attribute(focused,kAXRoleAttribute) as? String else { return false }
        return ["AXWebArea","AXScrollArea","AXGroup","AXLayoutArea","AXWindow","AXTable","AXOutline","AXRow","AXCell","AXBrowser","AXStaticText","AXHeading","AXLink","AXButton","AXImage"].contains(role)
    }
    static func scroll(_ direction: String, pages: Double, all: Bool, a: NSRunningApplication, target: CGPoint? = nil) throws -> String {
        guard ["down","up","left","right"].contains(direction), pages.isFinite && pages >= 0.1 && pages <= 50 else { throw Failure("Use scroll down|up|left|right [pages|all] [target].") }
        let area = try (try? scrollArea(a, target: target)) ?? root(a).1, bar = element(area, ["down","up"].contains(direction) ? kAXVerticalScrollBarAttribute : kAXHorizontalScrollBarAttribute)
        let positive = ["down","right"].contains(direction), end = positive ? 1.0 : 0.0
        var moved = false, performed = 0, atEnd = false
        let fraction = min(1,pages)
        for _ in 0..<(all ? 50 : Int(ceil(pages))) {
            try checkStopped()
            let before = try capture(a), value = bar.flatMap { attribute($0, kAXValueAttribute) as? NSNumber }?.doubleValue
            let pixels = value == nil && env["AUREL_AX_ONLY"] != "1" ? fingerprint(before) : []
            if let value, abs(value - end) < 0.001 { atEnd = true; break }
            var methods: [() throws -> Void] = [
                { if fraction == 1 { _ = perform(area, ["AXScroll\(direction.capitalized)ByPage"]) } },
                { if let bar { _ = perform(bar, [positive ? "AXIncrement" : "AXDecrement"]) } },
                { if let bar, let value { _ = AXUIElementSetAttributeValue(bar, kAXValueAttribute as CFString, NSNumber(value: all ? end : max(0,min(1,value + (positive ? 0.15 : -0.15) * fraction)))) } },
                { if fraction == 1 && pageKeysAllowed(a) { try sendKeys(["down":"pagedown","up":"pageup","left":"left","right":"right"][direction]!, pid: a.processIdentifier) } },
                { if env["AUREL_AX_ONLY"] != "1" { try wheel(direction, target ?? CGPoint(x: frame(area).midX,y: frame(area).midY), a, fraction:fraction) } },
                { if env["AUREL_AX_ONLY"] != "1" { try wheel(direction, CGPoint(x: frame(area).midX,y: positive ? frame(area).maxY - 10 : frame(area).minY + 10), a, fraction:fraction) } },
                { if env["AUREL_AX_ONLY"] != "1" { try wheel(direction, target ?? CGPoint(x: frame(area).midX,y: frame(area).midY), a, fraction:fraction, front:true) } }
            ]
            // AX and PID-key paths first; the background wheel next; the foreground wheel only after nothing else moved.
            if all, let bar { var writable = DarwinBoolean(false); AXUIElementIsAttributeSettable(bar,kAXValueAttribute as CFString,&writable); if writable.boolValue { methods.insert({ _ = AXUIElementSetAttributeValue(bar,kAXValueAttribute as CFString,NSNumber(value:end)) },at:0) } }
            var changed = false
            for method in methods {
                try checkStopped(); try method()
                for poll in 0..<3 {
                    usleep(poll == 0 ? 25_000 : 75_000)
                    let after = try capture(a), newValue = bar.flatMap { attribute($0, kAXValueAttribute) as? NSNumber }?.doubleValue
                    if (value != nil && newValue != nil ? abs(newValue! - value!) >= 0.001 : contentMoved(before,after) || (!pixels.isEmpty && pixelsChanged(pixels, fingerprint(after)))) { changed = true; break }
                }
                if changed { break }
            }
            if !changed { break }; moved = true; performed += 1
            if all, let newValue = bar.flatMap({ attribute($0, kAXValueAttribute) as? NSNumber })?.doubleValue, abs(newValue - end) < 0.001 { break }
        }
        let percent = bar.flatMap { attribute($0,kAXValueAttribute) as? NSNumber }.map { " (now \(Int($0.doubleValue * 100))%)" } ?? ""
        return moved ? "Scrolled \(direction) " + (fraction < 1 ? "a bit" : "\(performed) page\(performed == 1 ? "" : "s")") + percent : atEnd ? "Already at the end" : "No scroll movement detected"
    }
    static func findText(_ text: String, _ a: NSRunningApplication) throws -> AXUIElement? {
        let (_, w) = try root(a), start = Date(); var queue = [w], i = 0, best: AXUIElement?, score = 0
        while i < queue.count && i < 6000 && Date().timeIntervalSince(start) < 1 {
            try checkStopped()
            let e = queue[i]; i += 1; let role = attribute(e,kAXRoleAttribute) as? String ?? ""
            if !["AXTextField","AXTextArea","AXSecureTextField"].contains(role) { let r = rank(name(e), text); if r > score { best = e; score = r }; if r == 4 { return e } }
            queue += children(e)
        }
        return best
    }
    static func scrollTo(_ text: String, _ a: NSRunningApplication) throws -> String {
        func visible() throws -> Bool {
            let m = try capture(a)
            return m.texts.contains(where: { rank($0,text) == 4 }) || m.nodes.contains(where: { rank($0.label,text) == 4 })
        }
        if try visible() { return "Found \(quote(mask(text)))" }
        let found = try findText(text,a)
        if let e = found, perform(e,["AXScrollToVisible"]) {
            for _ in 0..<4 { usleep(25_000); if try visible() { return "Revealed \(quote(mask(text)))" } }
        }
        var direction = "down", reversed = false, target: CGPoint?, limit = 15
        if var e = found {
            for _ in 0..<40 {
                if attribute(e,kAXRoleAttribute) as? String == "AXScrollArea" {
                    let bounds = frame(e); target = CGPoint(x:bounds.midX,y:bounds.midY)
                    if let found, frame(found).maxY < bounds.minY { direction = "up" }
                    if let found, bounds.height > 0 { limit = min(60, max(15, Int(abs(frame(found).midY - bounds.midY) / bounds.height) + 3)) }   // far text: enough pages to reach it
                    break
                }
                guard let parent = element(e,kAXParentAttribute) else { break }; e = parent
            }
        }
        for _ in 0..<limit {
            try checkStopped()
            let m = try capture(a)
            if m.texts.contains(where: { rank($0,text) == 4 }) || m.nodes.contains(where: { rank($0.label,text) == 4 }) { return "Found \(quote(mask(text)))" }
            let result = try scroll(direction,pages: 1,all: false,a: a,target:target)
            if result == "Already at the end" { if reversed { break }; direction = direction == "down" ? "up" : "down"; reversed = true }
            else if result == "No scroll movement detected" { break }
        }
        if try visible() { return "Found \(quote(mask(text)))" }
        throw Failure("Could not find \(quote(mask(text))) within \(limit) pages.")
    }
    static func stringValue(_ e: AXUIElement) -> String? {
        let raw = attribute(e,kAXValueAttribute)
        return raw as? String ?? (raw as? NSAttributedString)?.string
    }
    static func selectedRange(_ e: AXUIElement) -> CFRange? {
        guard let value = attribute(e,kAXSelectedTextRangeAttribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        return AXValueGetValue(value as! AXValue,.cfRange,&range) ? range : nil
    }
    static func insertionTarget(_ text: String, _ a: NSRunningApplication) throws -> Insertion {
        guard !text.isEmpty else { throw Failure("The anchor text is empty.") }
        let (_, w) = try root(a), start = Date(); var queue = [w], cursor = 0
        var fields: [(AXUIElement,String,CGRect)] = [], anchors: [AXUIElement] = []
        while cursor < queue.count && cursor < 6000 && Date().timeIntervalSince(start) < 1 {
            try checkStopped()
            let item = queue[cursor]; cursor += 1
            let role = attribute(item,kAXRoleAttribute) as? String ?? "", bounds = visibleFrame(item)
            if let value = stringValue(item), ["AXTextField","AXTextArea","AXComboBox","AXSearchField"].contains(role) {
                fields.append((item,value,bounds))
            }
            let value = stringValue(item) ?? ""
            if rank(name(item),text) == 4 || (!value.isEmpty && (value as NSString).range(of:text).location != NSNotFound) {
                if !anchors.contains(where:{ CFEqual($0,item) }) { anchors.append(item) }
            }
            queue += children(item)
        }
        let inside = fields.compactMap { field, old, _ -> Insertion? in
            let source = old as NSString, hit = source.range(of:text)
            guard hit.location != NSNotFound,
                  source.range(of:text,options:[],range:NSRange(location:hit.location + hit.length,length:source.length - hit.location - hit.length)).location == NSNotFound else { return nil }
            return Insertion(field:field,anchor:field,old:old,location:hit.location + hit.length,label:text)
        }
        if inside.count == 1 { return inside[0] }
        if inside.count > 1 { throw Failure("More than one editable passage contains \(quote(mask(text))). Use a longer exact anchor.") }
        let exact = anchors.filter { rank(name($0),text) == 4 }
        let matches = exact.isEmpty ? anchors : exact
        guard let anchor = matches.min(by: {
            let left = visibleFrame($0), right = visibleFrame($1)
            return left.width * left.height < right.width * right.height
        }) else { throw Failure("No readable text matches \(quote(mask(text))). Read the window again.") }
        let ar = visibleFrame(anchor)
        guard matches.allSatisfy({ visibleFrame($0).intersects(ar) }) else { throw Failure("More than one passage matches \(quote(mask(text))). Use a longer exact anchor.") }
        let empty = fields.filter { $0.1.isEmpty && !$0.2.isNull && $0.2.width >= 4 && $0.2.height >= 4 }.compactMap { item -> (Double,(AXUIElement,String,CGRect))? in
            let r = item.2, sameLine = abs(r.midY - ar.midY) <= max(r.height,ar.height)
            if sameLine && r.midX >= ar.midX { return (r.minX - ar.maxX,item) }
            if r.midY >= ar.midY { return (10_000 + (r.midY - ar.midY) * 10 + abs(r.minX - ar.minX),item) }
            return nil
        }.sorted { $0.0 < $1.0 }
        guard let field = empty.first?.1 else { throw Failure("No empty editable area follows \(quote(mask(text))).") }
        return Insertion(field:field.0,anchor:anchor,old:field.1,location:0,label:text)
    }
    static func insertAfter(_ text: String, _ draft: String, _ a: NSRunningApplication) throws -> String {
        let target = try insertionTarget(text,a), source = target.old as NSString
        let expected = source.replacingCharacters(in:NSRange(location:target.location,length:0),with:draft)
        guard AXUIElementSetAttributeValue(target.field,kAXFocusedAttribute as CFString,kCFBooleanTrue) == .success else { throw Failure("Could not focus the answer location.") }
        var range = CFRange(location:target.location,length:0)
        guard let value = AXValueCreate(.cfRange,&range),
              AXUIElementSetAttributeValue(target.field,kAXSelectedTextRangeAttribute as CFString,value) == .success,
              selectedRange(target.field).map({ $0.location == range.location && $0.length == 0 }) == true else { throw Failure("Could not verify the caret after \(quote(mask(text))).") }
        let write = AXUIElementSetAttributeValue(target.field,kAXSelectedTextAttribute as CFString,draft as CFString)
        if write == .success {
            guard stringValue(target.field) == expected else { throw Failure("Text changed outside the verified caret; undo before continuing.") }
        } else {
            let clipboard = try lease("clipboard.lock"); defer { unlock(clipboard) }   // one clipboard borrower at a time, across Aurel processes
            guard stringValue(target.field) == target.old, selectedRange(target.field).map({ $0.location == range.location && $0.length == 0 }) == true else { throw Failure("The document changed before typing.") }
            let pb = NSPasteboard.general, saved = pb.pasteboardItems?.map { i in i.types.compactMap { t in i.data(forType:t).map { (t,$0) } } } ?? []
            pb.clearContents(); guard pb.setString(draft,forType:.string) else { throw Failure("Could not prepare paste.") }; let changed = pb.changeCount
            defer { if pb.changeCount == changed { pb.clearContents(); pb.writeObjects(saved.map { pairs in let i=NSPasteboardItem(); pairs.forEach { i.setData($1,forType:$0) }; return i }) } }
            try sendKeys("cmd+v",pid:a.processIdentifier); usleep(150_000)
            guard stringValue(target.field) == expected else { throw Failure("Could not verify that the original text was preserved.") }
        }
        guard stringValue(target.anchor).map({ ($0 as NSString).range(of:text).location != NSNotFound }) ?? (rank(name(target.anchor),text) == 4) else { throw Failure("The anchor text changed; undo before continuing.") }
        return "Typed after \(quote(mask(text)))"
    }
    // A childless control drawn around other mapped controls hides its contents from AX: a web chat composer (Muse: its text box,
    // Attach and Send are one button). AXPress clicks the whole container, which can land on any of them (Muse opens Attach),
    // so it gets a real click at its center, where a person's lands: the text box.
    static func wraps(_ n: Node, _ e: AXUIElement, _ map: Map) -> Bool {
        let r = CGRect(x:n.frame[0],y:n.frame[1],width:n.frame[2],height:n.frame[3])
        return children(e).isEmpty && map.nodes.contains { $0.id != n.id && $0.frame[2] * $0.frame[3] < r.width * r.height && r.contains($0.spot) }
    }
    static func typeText(_ text: String, _ n: Node, _ e: AXUIElement, _ a: NSRunningApplication, append: Bool, box: Bool = false) throws {
        guard box || ["AXTextField","AXTextArea","AXComboBox","AXSearchField","AXSecureTextField"].contains(n.role) else { throw Failure("Target is not a text field.") }
        guard box || AXUIElementSetAttributeValue(e,kAXFocusedAttribute as CFString,kCFBooleanTrue) == .success else { throw Failure("Could not focus that field.") }
        let old = attribute(e,kAXValueAttribute) as? String ?? "", draft = append ? old + text : text
        if !box, AXUIElementSetAttributeValue(e,kAXValueAttribute as CFString,draft as CFString) == .success {
            guard attribute(e,kAXValueAttribute) as? String == draft else { throw Failure("Text did not land in the field.") }; return
        }
        let clipboard = try lease("clipboard.lock"); defer { unlock(clipboard) }   // one clipboard borrower at a time, across Aurel processes
        guard attribute(e,kAXValueAttribute) as? String ?? "" == old else { throw Failure("The field changed before typing. Run see again.") }
        // Cmd-Right only reaches the end of the caret's line, so place and verify the caret at the value's end.
        var end = CFRange(location:(old as NSString).length,length:0)
        if append && !box { guard let value = AXValueCreate(.cfRange,&end), AXUIElementSetAttributeValue(e,kAXSelectedTextRangeAttribute as CFString,value) == .success,
                          selectedRange(e).map({ $0.location == end.location && $0.length == 0 }) == true else { throw Failure("Could not verify the caret at the end of that field.") } }
        // PID-directed paste keeps focus in the user’s app; verify the same field before reporting success.
        let pb = NSPasteboard.general, saved = pb.pasteboardItems?.map { i in i.types.compactMap { t in i.data(forType:t).map { (t,$0) } } } ?? []
        pb.clearContents(); guard pb.setString(text,forType:.string) else { throw Failure("Could not prepare paste.") }; let changed = pb.changeCount
        defer { if pb.changeCount == changed { pb.clearContents(); pb.writeObjects(saved.map { pairs in let i = NSPasteboardItem(); pairs.forEach { i.setData($1,forType:$0) }; return i }) } }
        if !append { try sendKeys("cmd+a",pid:a.processIdentifier) }
        try sendKeys("cmd+v",pid:a.processIdentifier); usleep(150_000)
        // A box's text is invisible to AX: its caller checks the screen instead.
        if !box, !n.secret, attribute(e,kAXValueAttribute) as? String != draft { throw Failure("Could not verify the pasted text.") }
    }
    static func settle(_ a: NSRunningApplication, seconds: Double) throws -> Bool {
        let start = Date(), initial = try capture(a); var last = initial.settled, since = Date()
        let usePixels = !initial.rich && env["AUREL_AX_ONLY"] != "1"
        var pixels = usePixels ? fingerprint(initial) : []
        while Date().timeIntervalSince(start) < seconds {
            try checkStopped()
            usleep(50_000); let map = try capture(a), current = map.settled
            let freshPixels = usePixels ? fingerprint(map) : []
            if current != last || pixelsChanged(pixels,freshPixels,threshold:1.5) { since = Date(); last = current }
            pixels = freshPixels
            if Date().timeIntervalSince(since) >= 0.3 { return true }
        }
        return false
    }
    // A receipt tied to this submission: the field let go of its draft (not just a new line in it), the page or window moved on,
    // or the sent words appeared as new text. Another control updating elsewhere in the window is not a receipt.
    static func submitReceipt(_ typed: String?, _ value: String?, _ sent: String, _ before: Map, _ after: Map) -> Bool {
        let consumed = typed.map { typed in value.map { $0 != typed && !$0.hasPrefix(typed) } ?? true } ?? false
        let posted = !sent.isEmpty && after.texts.contains { $0.contains(sent) } && !before.texts.contains { $0.contains(sent) }
        return consumed || posted || after.page != before.page || after.windowID != before.windowID
    }
    static func validate(_ args: [String]) throws {
        guard let verb = args.first else { throw Failure("Use see|click|scroll|scroll-to|press|drag|type|wait.") }
        let rest = Array(args.dropFirst())
        guard !rest.contains(where: { $0.hasPrefix("--") }) else { throw Failure("Hands accepts no flags.") }
        switch verb {
        case "menu": guard rest.count == 2, !rest[0].isEmpty, rest[1].components(separatedBy:">").count > 1, rest[1].components(separatedBy:">").allSatisfy({ !$0.trimmingCharacters(in:.whitespaces).isEmpty }) else { throw Failure("Use menu app path.") }
        case "see": guard rest.count <= 1 else { throw Failure("Use see [app].") }
        case "click": guard !rest.isEmpty, rest.count <= 6 else { throw Failure("Use click target [near label] [double] [right] [front].") }; _ = try clickOptions(rest)
        case "scroll": guard (1...3).contains(rest.count), ["down","up","left","right"].contains(rest[0]), rest.count < 3 || rest[1] == "all" || Double(rest[1]).map({ $0.isFinite && $0 >= 0.1 && $0 <= 50 }) == true else { throw Failure("Use scroll direction [pages|all] [target].") }; if rest.count == 2, let n = Double(rest[1]), !n.isFinite || n < 0.1 || n > 50 { throw Failure("Invalid page count.") }
        case "scroll-to": guard rest.count == 1 else { throw Failure("Use scroll-to text.") }
        case "press": guard (1...2).contains(rest.count) else { throw Failure("Use press keys [times].") }; _ = try keys(rest[0]); if rest.count == 2 { guard let n = Int(rest[1]), (1...50).contains(n) else { throw Failure("Invalid repeat count.") } }
        case "drag": guard rest.count == 2 else { throw Failure("Use drag from to.") }
        case "type": guard (2...4).contains(rest.count), rest.dropFirst(2).allSatisfy({ ["submit","append"].contains($0) }) else { throw Failure("Use type target text [submit] [append].") }
        case "type-after": guard rest.count == 2, !rest[0].isEmpty else { throw Failure("Use type-after anchor text.") }
        case "wait": guard rest.count <= 1, rest.isEmpty || Double(rest[0]).map({ $0.isFinite && $0 > 0 && $0 <= 30 }) == true else { throw Failure("Use wait [seconds, max 30].") }
        default: throw Failure("Unknown hands verb: \(verb)")
        }
    }
    static func clickOptions(_ args: [String]) throws -> (String,Bool,Bool,Bool) {
        var near = "", double = false, right = false, front = false, i = 1
        while i < args.count {
            switch args[i] {
            case "near": guard i + 1 < args.count, near.isEmpty else { throw Failure("Use near label.") }; near = args[i+1]; i += 1
            case "double": guard !double else { throw Failure("Duplicate double.") }; double = true
            case "right": guard !right else { throw Failure("Duplicate right.") }; right = true
            case "front": guard !front else { throw Failure("Duplicate front.") }; front = true
            default: throw Failure("Unknown click option: \(args[i])")
            }; i += 1
        }
        return (near,double,right,front)
    }
    static func targets(_ args: [String]) -> [String] {
        switch args[0] {
        case "click", "type", "type-after": return [args[1]]
        case "drag": return [args[1],args[2]]
        case "scroll": return args.count == 4 ? [args[3]] : args.count == 3 && args[2] != "all" && Double(args[2]) == nil ? [args[2]] : []
        default: return []
        }
    }
    static func freshIDs(_ args: [String], _ old: Map, _ fresh: Map) throws {
        if targets(args).contains(where: { Int($0) != nil }), old.signature != fresh.signature { throw Failure("The screen changed. Run see again.") }
    }
    static func targetsCurrent(_ args: [String], _ map: Map, _ a: NSRunningApplication) -> Bool {
        do {
            let (_, window) = try root(a)
            guard array(frame(window)) == map.windowFrame, mask(name(window)) == mask(map.window) else { return false }
            if let id = axWindowNumber(window)?.stringValue, !map.windowID.isEmpty, id != map.windowID { return false }
            if args[0] == "click", args[1].contains(">") {
                return try menu(args[1],a,act:false) == (try checked(args,map,a)["labels"] as? [String])?.last
            }
            if ["click","drag","type"].contains(args[0]) {
                let near = args[0] == "click" ? try clickOptions(Array(args.dropFirst())).0 : ""
                for target in (args[0] == "drag" ? [args[1],args[2]] : [args[1]]) {
                    let (node, element) = try resolve(target,map:map,a:a,near:near)
                    guard let element else { return false }
                    let role = attribute(element,kAXRoleAttribute) as? String ?? "", rawLabel = name(element)
                    let label = mask(rawLabel.isEmpty ? role : rawLabel)
                    guard role == node.role, label == node.label, array(visibleFrame(element)) == node.frame else { return false }
                    if args[0] == "type", !node.secret {
                        let raw = attribute(element,kAXValueAttribute)
                        let value = String(mask(raw as? String ?? (raw as? NSNumber)?.stringValue ?? "").prefix(400))
                        guard value == node.value else { return false }
                    }
                }
            } else if args[0] == "press" {
                guard let focused = element(AXUIElementCreateApplication(a.processIdentifier),kAXFocusedUIElementAttribute) else { return map.focused.isEmpty }
                let role = attribute(focused,kAXRoleAttribute) as? String ?? "", label = mask(name(focused))
                guard label == map.focused, map.focusIdentity.hasPrefix(role + ":"), map.focusIdentity.hasSuffix(":" + String(describing:array(frame(focused)))) else { return false }
            }
            return true
        } catch { return false }
    }
    static func checked(_ args: [String], _ map: Map, _ a: NSRunningApplication) throws -> [String: Any] {
        var labels: [String] = [], secure = false, at: [String] = []
        let verb = args[0]
        if verb == "click", args[1].contains(">") {
            let (near,double,right,front) = try clickOptions(Array(args.dropFirst()))
            guard near.isEmpty && !double && !right && !front else { throw Failure("Menu paths accept no click options.") }
            labels = args[1].components(separatedBy:">").dropLast().map { mask($0.trimmingCharacters(in:.whitespaces)) } + [try menu(args[1],a,act:false)]
        }
        else if ["click","drag","type"].contains(verb) {
            let near = verb == "click" ? try clickOptions(Array(args.dropFirst())).0 : ""
            for target in (verb == "drag" ? [args[1],args[2]] : [args[1]]) { let (n, _) = try resolve(target,map:map,a:a,near:near); labels.append(n.label); at.append("\(n.frame)"); secure = secure || n.secret }
        } else if verb == "type-after" {
            let target = try insertionTarget(args[1],a); labels = [target.label]; secure = secret(name(target.field))
        } else if verb == "press" {
            labels = [map.focused,args[1]] + (menuShortcut(args[1],a).map { [$0.1] } ?? []); at = [map.focusIdentity]
            let (code, _) = try keys(args[1])
            if [CGKeyCode(51),CGKeyCode(117)].contains(code),
               let focused = element(AXUIElementCreateApplication(a.processIdentifier),kAXFocusedUIElementAttribute),
               selectedRange(focused) != nil { throw Failure("Backspace cannot prove the text belongs to Aurel. Undo Aurel's last edit with cmd+z instead.") }
        }
        let keyRisk = verb == "press" ? try riskyKey(args[1]) : false
        let risk = labels.contains { $0.hasPrefix("Unidentified screen point ") || riskyLabel($0,map) || (verb == "drag" && matches($0,#"(?i)\b(bin|recycle)\b"#)) } || keyRisk || (verb == "type" && args.dropFirst(3).contains("submit"))
        // The approval covers the target and its window, not the whole tree: a clock, or a neighbour an app builds lazily after first contact, must not void it.
        return ["labels":labels,"secure":secure,"risky":risk,"at":at,"pid":map.pid,"args":args,"windowID":map.windowID,"windowFrame":map.windowFrame,"window":mask(map.window),"app":map.app]
    }
    static func cli(_ input: [String]) -> Int32 {
        defer { restoreAccessibility() }
        let started = DispatchTime.now().uptimeNanoseconds
        defer {
            if env["AUREL_HANDS_TIMING"] == "1" {
                let ms = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
                FileHandle.standardError.write(Data("HANDS NET \(String(format:"%.2f",ms)) ms\n".utf8))
            }
        }
        stopped = 0
        signal(SIGTERM) { _ in Hands.stopped = 1 }; signal(SIGINT) { _ in Hands.stopped = 1 }
        do {
            if input.first == "label" { let args = Array(input.dropFirst()); try validate(args); try trusted(); let old = try load(), a = try aimed(args, old), m = try capture(a); try freshIDs(args,old,m); let checked = try checked(args, m, a); print(String(data:try JSONSerialization.data(withJSONObject:checked),encoding:.utf8)!); return 0 }
            if input.first == "identify" {
                guard input.count <= 2 else { throw Failure("Use identify [app].") }
                try trusted()
                print(String(data: try JSONSerialization.data(withJSONObject: identify(try app(input.count > 1 ? input[1] : nil))), encoding: .utf8)!); return 0
            }
            if input.first == "read" {
                guard input.count <= 3 && (input.count < 3 || input[2] == "more") else { throw Failure("Use read [app] [more].") }
                try trusted()
                let text = try read(try app(input.count > 1 ? input[1] : nil), more: input.count == 3, head: env["AUREL_HANDS_HEAD"] == "1")
                print(String(data: try JSONSerialization.data(withJSONObject: text), encoding: .utf8)!); return 0
            }
            try validate(input); try trusted()
            if input[0] == "see" { let m = try capture(try app(input.count > 1 ? input[1] : nil)); try save(m); print(m.description); return 0 }
            if input[0] == "menu" {
                let a = try app(input[1]), label = try menu(input[2],a,act:false)
                guard !Prefs.bool("safe") || !(riskyLabel(input[2]) || riskyLabel(label)) else { throw Failure("This menu action needs the user's Allow card. Use the normal hands click path.") }
                claims = true; if userWindowsFile != nil { _ = try? root(a) }   // a menu command acts in the app's focused window: it claims that one
                let target = MiniScreen.windowTarget(a,windows:CGWindowListCopyWindowInfo(.optionAll,kCGNullWindowID) as? [[String:Any]] ?? [])   // optional AX metadata must not turn a successful press into a timeout and duplicate action
                print("Clicked \(quote(try menu(input[2],a,act:true)))")
                if let target,
                   let data = try? JSONSerialization.data(withJSONObject:target.merging(["action":"click"]) { $1 }), let text = String(data:data,encoding:.utf8) { print("▣ " + text) }
                return 0
            }
            claims = ["click","drag","type","type-after","press"].contains(input[0])
            let old = try load(), a = try aimed(input, old); var before = try capture(a)
            let check = try checked(input, before, a)
            try freshIDs(input,old,before)
            if env["AUREL_HANDS_SESSION"] == "1" {
                print(String(data:try JSONSerialization.data(withJSONObject:check),encoding:.utf8)!); fflush(stdout)
                let answer = String(data:FileHandle.standardInput.readDataToEndOfFile(),encoding:.utf8)?.trimmingCharacters(in:.whitespacesAndNewlines)
                guard answer == "y" else { throw Failure("Action cancelled.") }
                if !targetsCurrent(input,before,a) {
                    let fresh = try capture(a), refreshed = try checked(input,fresh,a)
                    guard NSDictionary(dictionary:refreshed).isEqual(to:check) else {
                        try save(fresh); throw Failure("The screen changed while checking permission. Run see again.")
                    }
                    before = fresh
                }
            } else {
                let data = env["AUREL_HANDS_RECEIPT"] == "1" ? FileHandle.standardInput.readDataToEndOfFile() : Data()
                let receipt = (try? JSONSerialization.jsonObject(with:data)) as? [String:Any]
                if let receipt {
                    guard NSDictionary(dictionary:receipt).isEqual(to:check) else { throw Failure("The screen changed while checking permission. Run see again.") }
                } else if (check["risky"] as? Bool == true && Prefs.bool("safe")) || (input[0] == "type" && check["secure"] as? Bool == true) { throw Failure("Use aurel.py --hands so the user can allow this action.") }
            }
            // One app's input stays whole: another task's action in the same app finishes first, then this target is checked again.
            let inputLock = input[0] == "wait" ? nil : try lease("hands-\(a.bundleIdentifier ?? String(a.processIdentifier)).lock"); defer { if let inputLock { unlock(inputLock) } }
            if inputLock != nil && leaseWaited && !targetsCurrent(input,before,a) { throw Failure("Another task changed this window while this one waited. Nothing was done; run see again.") }
            // Background first; the real pointer for work the user asked to see or a window without a known id. An app can take a
            // background gesture without any visible change, so one is never repeated in front by itself: the reply says how to redo it.
            var background = false
            func gesture(_ asked: Bool = false, _ act: (Bool) throws -> Void) throws {
                let front = asked || MiniScreen.workInFront || targetWindow(a) == 0
                try act(front); background = !front
            }
            var result = "", spot: CGPoint?, spotPixels: [UInt8] = []
            let exact = input[0] == "click" ? try point(input[1]) : nil
            switch input[0] {
            case "click":
                if input[1].contains(">") { let label = try menu(input[1],a,act:true); result = "Clicked \(quote(label))" }
                else {
                    let (near,double,right,front) = try clickOptions(Array(input.dropFirst())), (n,e) = try resolve(input[1],map:before,a:a,near:near), at = exact ?? n.spot; spot = at
                    // Pressing the element around an unmapped point clicks its center, not the point.
                    if let e, exact == nil || n.id != 0, !double && !right && !front, !wraps(n,e,before), perform(e,["AXPress","AXPick","AXConfirm","AXOpen"]) { }
                    else {
                        // A mouse click can change only pixels (a canvas, a map, a video); they show whether it took.
                        if env["AUREL_AX_ONLY"] != "1" { spotPixels = fingerprint(before, around: at) }
                        try gesture(front) { try mouse(at,a,double:double,right:right,front:$0) }
                    }
                    result = "Clicked \(quote(n.label))"
                }
            case "scroll":
                let amount = input.count > 2 ? input[2] : "1", pages = Double(amount) ?? 1
                let target = input.count > 3 ? input[3] : (input.count > 2 && amount != "all" && Double(amount) == nil ? amount : "")
                let p = target.isEmpty ? nil : try resolve(target,map:before,a:a).0.spot
                spot = p ?? CGPoint(x:before.windowFrame[0] + before.windowFrame[2] / 2,y:before.windowFrame[1] + before.windowFrame[3] / 2)
                result = try scroll(input[1],pages:pages,all:amount == "all",a:a,target:p)
            case "scroll-to": result = try scrollTo(input[1],a)
            case "press":
                let times = input.count > 2 ? Int(input[2])! : 1
                if let (item, label) = menuShortcut(input[1],a) {
                    try keysReachTask(a.processIdentifier)   // the menu command acts on the app's focused window, so it must be this task's
                    let lease = try screenLease(); defer { unlock(lease) }   // as menu(): a press can bring the app forward, so put the user's app back
                    DistributedNotificationCenter.default().postNotificationName(.init("aurel.raise"), object: nil, deliverImmediately: true)
                    usleep(50_000); let restore = restoreFocus(a); defer { usleep(30_000); restore() }
                    for _ in 0..<times { try checkStopped(); guard perform(item,["AXPress"]) else { throw Failure("Could not run \(quote(label)).") }; usleep(15_000) }
                    result = "Ran \(quote(label)) for \(quote(input[1])) in \(a.localizedName ?? "app")"
                } else { try sendKeys(input[1],pid:a.processIdentifier,times:times); result = "Pressed \(quote(input[1])) in \(a.localizedName ?? "app")" }
            case "drag": let from = try resolve(input[1],map:before,a:a).0, to = try resolve(input[2],map:before,a:a).0; try gesture { try mouse(from.spot,a,to:to.spot,front:$0) }; spot = to.spot; result = "Dragged \(quote(from.label)) to \(quote(to.label))"
            case "type":
                let (n,e) = try resolve(input[1],map:before,a:a); guard let e else { throw Failure("No editable field.") }
                let box = wraps(n,e,before)
                spot = n.spot
                func typing() throws {
                    // Its text box is hidden from AX: click into it first, and see the words show where they start, left of its middle.
                    let start = CGPoint(x: n.frame[0] + min(80, n.frame[2] / 2), y: n.spot.y)
                    if box { try frontClicks(n.spot); usleep(150_000) }
                    let shown = box ? fingerprint(before, around: start) : []
                    try typeText(input[2],n,e,a,append:input.dropFirst(3).contains("append"),box:box)
                    if box { usleep(100_000) }
                    if box, shown.isEmpty || !pixelsChanged(shown, fingerprint(before, around: start), threshold: 1.5) {
                        throw Failure("Could not see the text land in \(quote(n.label)). Nothing was sent; read the window before typing again.")
                    }
                    if input.dropFirst(3).contains("submit") {
                        let typed = stringValue(e), submitted = try capture(a), deadline = Date().addingTimeInterval(0.5), sent = mask(String(input[2].prefix(60)))
                        try sendKeys("return",pid:a.processIdentifier)
                        var accepted = false
                        repeat {
                            usleep(50_000)
                            accepted = submitReceipt(typed, stringValue(e), sent, submitted, try capture(a))
                        } while !accepted && Date() < deadline
                        if !accepted { throw Failure("Could not verify Return was accepted in the background. Read the window; if it was not sent, click its send button.") }
                    }
                }
                // A web app's composer ignores background clicks and keys: it comes forward for the click, paste and send, then the user's app returns.
                if box { try inFront(a, typing) } else { try typing() }
                result = "Typed into \(quote(n.label))"
            case "type-after": result = try insertAfter(input[1],input[2],a)
            case "wait": result = try settle(a,seconds:input.count > 1 ? Double(input[1])! : 5) ? "Window settled" : "Window did not settle before the timeout"
            default: throw Failure("Unknown hands verb.")
            }
            if input[0] != "wait" { usleep(25_000) }
            let after = try capture(a)
            if input[0] == "click" {
                let (_, w) = try root(a)
                var known = before; if known.page.isEmpty { known.page = after.page }   // a page the reader had not reached yet (a browser builds it lazily) is not a change
                let same = after.signature == known.signature
                if let sheet = (attribute(w,"AXSheets") as? [AXUIElement])?.first ?? (attribute(w,kAXRoleAttribute) as? String == "AXSheet" ? w : nil) { result += " — a sheet opened: \(quote(mask(name(sheet))))" }
                else if same, let spot, !spotPixels.isEmpty, pixelsChanged(spotPixels, fingerprint(after, around: spot), threshold: 1.5) { result += " — the screen changed at that spot" }
                // A background click the screen could not be read for (its window covered, or on another Space): say what happened, not "nothing changed".
                else if same, background, spotPixels.isEmpty { result += " in the background. Its spot could not be read to confirm a change (the window may be covered or on another Space); read the window, or add front to the same click to bring it forward for that click only" }
                // front only on evidence: neither the accessibility tree nor the pixels at the spot changed after a background click
                else if same { result = "Nothing changed after clicking \(quote((check["labels"] as? [String])?.first ?? input[1]))" + (background && !spotPixels.isEmpty ? ". It went in the background; if this app ignores background clicks, add front to the same click: the app comes forward for that click only, then the user's app returns" : "") }
            }
            print(result)
            if let spot { print("@ \(Int(spot.x)) \(Int(spot.y))") }
            let changed = after.nodes.filter { n in !before.nodes.contains { $0.id == n.id && $0.path == n.path && $0.role == n.role && $0.label == n.label && $0.value == n.value && $0.frame == n.frame } }
            let removed = before.nodes.filter { n in !after.nodes.contains { $0.id == n.id && $0.path == n.path && $0.role == n.role && $0.label == n.label } }.map { "Removed: [\($0.id)] \(quote($0.label))" }
            if after.windowID != before.windowID || after.window != before.window || after.windowFrame != before.windowFrame { print(after.description) }
            else { print((["Now: \(mask(after.window))"] + removed + changed.map(\.line) + ["Focused: \(after.focused)"] + (after.scroll.isEmpty ? [] : ["Scroll: \(Int(after.scroll[0] * 100))% down"]) + (after.page == before.page ? [] : ["Page: \(mask(after.page))"]) + [String(after.texts.filter { !before.texts.contains($0) }.joined(separator:" | ").prefix(1400))]).joined(separator:"\n")) }
            try save(after); return 0
        } catch let failure as Failure { print(failure.message); return 1 }
        catch { print("Hands could not finish: \(error.localizedDescription)"); return 1 }
    }
    static func selftest() {
        precondition(rank("Export", "") == 0)
        precondition(rank("Export","export") == 4 && rank("Export PDF","export") == 3 && rank("Start Export Now","export") == 2 && rank("Reexport","export") == 1)
        precondition(try! point("first, second") == nil)
        precondition(mask("4111 1111 1111 1111 / 123-45-6789 / Code 123456") == "[SECRET] / [SECRET] / Code [SECRET]")
        precondition(secret("Password") && secret("one time code") && !secret("Name"))
        let date = "Oct 11, 2026 6:39 PM"
        precondition(!secret(date) && mask(date) == date && !secret("Version 12.34.5678"))
        precondition(mask("4111111111111111") == "[SECRET]")
        let safeMap = Map(pid:123,app:"Fixture",window:"Export options",windowFrame:[0,0,400,400],nodes:[],texts:["Choose a destination"],page:"",focused:"",scroll:[])
        var dangerousMap = safeMap; dangerousMap.texts = ["Delete 3 items?"]
        for label in ["OK","Yes","Continue","Allow","Accept","Agree","Complete","Finish","Grant"] { precondition(!riskyLabel(label,safeMap) && riskyLabel(label,dangerousMap)) }
        precondition(!riskyLabel("Cancel",dangerousMap) && riskyLabel("Confirm",safeMap) && riskyLabel("Allow access",safeMap))
        precondition(matches("Delete draft",riskyPattern) && matches("Send",riskyPattern) && !matches("Export",riskyPattern))
        precondition((try! keys("⌘+⇧+4")).0 == 21 && (try! keys("cmd++")).0 == 24)
        precondition(!(try! riskyKey("return")))
        precondition(try! riskyKey("cmd+q")); precondition(!(try! riskyKey("cmd+t")))
        let (code,flags) = try! keys("cmd+shift+4"); precondition(code == 21 && flags == [.maskCommand,.maskShift])
        precondition(digest(["count 1"],maskDigits:true) == digest(["count 2"],maskDigits:true))
        let node = Node(id:1,role:"AXTextField",label:"Password",value:"private",frame:[0,0,10,10],path:[],secret:true)
        precondition(!node.line.contains("private") && node.line.contains("[1]"))
        precondition(!pixelsChanged([],[]) && pixelsChanged([0,0],[5,5]))
        // A 2:x,y spot on a 1920-wide display at x=1470 is the external monitor in Saarth's Oct 21 case: 602,397 -> global 2373,595.
        precondition(picturePoint(602, 397, in: CGRect(x: 1470, y: 0, width: 1920, height: 1080)) == CGPoint(x: 2373, y: 595.5))
        precondition(picturePoint(0, 0, in: CGRect(x: 0, y: 0, width: 1280, height: 800)) == .zero && picturePoint(640, 400, in: CGRect(x: 0, y: 0, width: 1280, height: 800)) == CGPoint(x: 640, y: 400))
        for args in [["click","Export","--yes"],["press","cmd+q","0"],["type","Name","text","force"],["wait","nan"]] { do { try validate(args); preconditionFailure("Accepted invalid hands args") } catch {} }
    }
}
// MARK: - End Hands

if CommandLine.arguments == [CommandLine.arguments[0], "--raise"] || CommandLine.arguments == [CommandLine.arguments[0], "--raise", "user"] {
    DistributedNotificationCenter.default().postNotificationName(.init("aurel.raise"), object: CommandLine.arguments.count == 3 ? "user" : nil, deliverImmediately: true); usleep(50_000); exit(0)
}
if CommandLine.arguments.dropFirst() == ["--calendar"] {
    let result: [String: Any]
    do {
        guard let data = try JSONSerialization.jsonObject(with: FileHandle.standardInput.readDataToEndOfFile()) as? [String: Any] else { throw Hands.Failure("Expected a calendar JSON object.") }
        result = try CalendarTool.run(data)
    } catch { result = ["error": "Calendar could not finish: \(error.localizedDescription)"] }
    if let json = try? JSONSerialization.data(withJSONObject: result), let text = String(data: json, encoding: .utf8) { print(text) }
    exit(0)
}
if CommandLine.arguments.count >= 2, CommandLine.arguments[1] == "--hands" { exit(Hands.cli(Array(CommandLine.arguments.dropFirst(2)))) }
if CommandLine.arguments.dropFirst() == ["--draw-target"] {
    let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly,kCGNullWindowID) as? [[String:Any]] ?? []
    let named = ProcessInfo.processInfo.environment["AUREL_SCREEN"]
    let screen = named.flatMap { name in NSScreen.screens.first { $0.localizedName == name } }.map {
        CGDisplayBounds($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? CGMainDisplayID())
    }
    let front = NSWorkspace.shared.frontmostApplication
    let pids = [front?.processIdentifier].compactMap { $0 } + windows.compactMap {
        guard ($0[kCGWindowLayer as String] as? Int) == 0, let frame = MiniScreen.bounds($0),
              screen == nil || screen!.contains(CGPoint(x:frame.midX,y:frame.midY)) else { return nil }
        return ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
    }
    let unique = pids.reduce(into: [Int32](), { if !$0.contains($1) { $0.append($1) } })
    if let target = unique.lazy.compactMap({ pid -> [String:Any]? in
        guard let app = NSRunningApplication(processIdentifier:pid) else { return nil }
        return MiniScreen.windowTarget(app,screen:screen,windows:windows)
    }).first,
       let data = try? JSONSerialization.data(withJSONObject:target) { print(String(decoding:data,as:UTF8.self)) }
    exit(0)
}
if CommandLine.arguments.count >= 3, ["--window-target","--target-app"].contains(CommandLine.arguments[1]) {
    let name = CommandLine.arguments[2]
    let url = name.contains(":") ? URL(string:name) : FileManager.default.fileExists(atPath:name) ? URL(fileURLWithPath:name) : nil
    let handler = url.flatMap { NSWorkspace.shared.urlForApplication(toOpen:$0) }, bundle = handler.flatMap { Bundle(url:$0)?.bundleIdentifier }
    let title = CommandLine.arguments.count > 3 && !CommandLine.arguments[3].isEmpty ? CommandLine.arguments[3] : url?.isFileURL == true && FileManager.default.fileExists(atPath:name) ? url!.deletingPathExtension().lastPathComponent : ""
    let frame = CommandLine.arguments.count == 5 ? (try? JSONSerialization.jsonObject(with:Data(CommandLine.arguments[4].utf8))) as? [Double] ?? [] : []
    if !frame.isEmpty && (frame.count != 4 || !frame.allSatisfy(\.isFinite)) { exit(1) }
    let apps = NSWorkspace.shared.runningApplications.filter { $0.localizedName?.localizedCaseInsensitiveCompare(name) == .orderedSame || $0.bundleIdentifier == name || (bundle != nil && $0.bundleIdentifier == bundle) || $0.executableURL?.lastPathComponent.localizedCaseInsensitiveCompare(name) == .orderedSame || $0.bundleURL?.deletingPathExtension().lastPathComponent.localizedCaseInsensitiveCompare(name) == .orderedSame }
    if CommandLine.arguments[1] == "--target-app" { if apps.count == 1 { print(apps[0].localizedName ?? name) } else if let handler { print(handler.deletingPathExtension().lastPathComponent) }; exit(0) }
    if apps.count == 1 { MiniScreen.work(apps[0]) }
    if apps.count == 1, var target = MiniScreen.windowTarget(apps[0],title:title,frame:frame,windows:CGWindowListCopyWindowInfo(.optionAll,kCGNullWindowID) as? [[String:Any]] ?? []),
       let id = UInt32(target["windowID"] as? String ?? ""), let f = target["windowFrame"] as? [CGFloat] {
        var count: UInt32 = 0; CGGetActiveDisplayList(0, nil, &count)
        var displays = [CGDirectDisplayID](repeating:0, count:Int(count)); CGGetActiveDisplayList(count, &displays, &count)
        let above = (CGWindowListCopyWindowInfo(.optionOnScreenAboveWindow, id) as? [[String:Any]] ?? []).filter { ($0[kCGWindowLayer as String] as? Int) == 0 }
        let onScreen = ((CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String:Any]])?.first?[kCGWindowIsOnscreen as String] as? Bool) == true
        target["visible"] = onScreen && target["minimized"] as? Bool != true &&
            MiniScreen.visible(CGRect(x:f[0],y:f[1],width:f[2],height:f[3]), displays:displays.map(CGDisplayBounds), above:above.compactMap(MiniScreen.bounds))
        if let data = try? JSONSerialization.data(withJSONObject:target) { print(String(decoding:data,as:UTF8.self)) }
    }
    exit(0)
}

// One Aurel at a time: a lock the system drops when the process ends (opened by hand + started by launchd = two)
if CommandLine.arguments.dropFirst() == ["--selftest"] {
    precondition(transcriptKey(" Open   Notes. ") == transcriptKey("open notes"))
    precondition(transcriptKey("calculate 1.5") != transcriptKey("calculate 15"))
    precondition(transcriptKey("search a b") != transcriptKey("search ab"))
    precondition(transcriptKey("open a-b.com") != transcriptKey("open ab.com"))
    Hands.selftest()
    // Agent answers: a stream never shows an unclosed mark; math is shielded from Markdown, prices and code keep their $.
    precondition(agentShut("Use **rad") == "Use " && agentShut("x \\(\\dfrac{4}") == "x " && agentShut("a\n$$\nA = ") == "a\n" && agentShut("Try `ls") == "Try ")
    precondition(agentShut("It costs $5 and $x$ is done") == "It costs $5 and $x$ is done" && agentShut("```\necho $HOME") == "```\necho $HOME")
    precondition(answerMarkdown("$5 and $10") == "\u{E000}5 and \u{E000}10" && answerMarkdown(#"$x\,y$"#) == #"$x\\\,y$"# && answerMarkdown(#"\(a_1\) \[b\]"#) == #"$a\_1$ $$b$$"#)
    // The shelf: working agents show, finished ones fold into the pill; ten minutes on screen and they leave. Made things drop pages the answer only cites.
    do {
        let s = ShelfModel(), now = Date().timeIntervalSince1970
        func row(_ id: String, _ status: String, _ more: [String:Any]) -> [String:Any] { ["id":id,"status":status].merging(more) { $1 } }
        func view() -> [String] { let (shown, folded) = s.split(s.list); return [shown.map(\.id).joined(separator: ","), folded.isEmpty ? "" : ShelfModel.pillLabel(folded, s.list.count).full] }
        s.receive("list", [row("w","running",["started":now-9]), row("d1","done",["ended":now-120]), row("d2","done",["ended":now-30]), row("f","failed",["ended":now-60]), row("s","stopped",["ended":now-5]), row("old","done",["ended":now-3600,"seenAt":now-700])])
        precondition(Int(s.onScreen["d1"]!.rounded()) == 120 && s.onScreen["old"] == ShelfModel.linger)   // first sight after a restart: the wall clock since it finished or was last seen
        precondition(view() == ["w", "1 failed · 2 done"])   // failed lingers and is counted apart; stopped and old ones do not
        s.stack = "open"; precondition(view() == ["w,d2,f,d1", ""])   // a peek: working first, then newest finished
        s.stack = "min"; precondition(view() == ["", "1 agent · 1 failed · 2 done"])
        s.stack = ""; s.onScreen["d2"] = ShelfModel.linger; precondition(view() == ["w", "1 failed · 1 done"])
        s.rows += [AgentRow(row("w2","running",["started":now-5])), AgentRow(row("w3","needs-you",["started":now-4,"question":["q":"ok?"]]))]
        precondition(view() == ["w3", "2 more · 1 failed · 1 done"])   // three working: the newest, plus the one asking
        s.rows = [AgentRow(row("d","done",["ended":now-300]))]; s.onScreen["d"] = 0; precondition(view() == ["", "✓ 1 done"] && s.rows[0].state == "Done · 5m ago")
        s.rows = [AgentRow(row("f","failed",["ended":now-60]))]; s.onScreen["f"] = 0; precondition(view() == ["", "1 failed"])
        let cite = "https://example.com/review", issue = "https://tracker.example.com/issues/12"
        precondition(AgentRow(["result":"See [Review](\(cite)). Filed \(issue)","made":[["url":cite,"title":"","type":""],["url":issue,"title":"Login fails","type":""]]]).things.map(\.title) == ["Login fails"])
    }
    precondition(AgentRow.cost(0.0412) == "≈4.12¢ at API prices" && AgentRow.cost(0.1861) == "≈18.6¢ at API prices" && AgentRow.cost(2.5) == "≈$2.50 at API prices")
    precondition(answerMarkdown("`$5` and ```\n$PATH\n```") == "`\u{E000}5` and ```\n\u{E000}PATH\n```")
    // The box's answers (Answer.swift): shutAnswer and parseMarkdown, and the orb (Orb.swift).
    precondition(shutAnswer("Use **rad") == "Use " && shutAnswer("x \\(\\dfrac{4}") == "x " && shutAnswer("a\n$$\nA = ") == "a\n" && shutAnswer("Try `ls") == "Try ")
    precondition(shutAnswer("It costs $5 and $x$ is done") == "It costs $5 and $x$ is done" && shutAnswer("```\necho $HOME") == "```\necho $HOME")
    do {
        let b = parseMarkdown("# Plan\n- one\n- two\n\nCosts $5, area $\\pi r^2$.\n\n| A | B |\n|---|---|\n| 1 | 2 |\n\n```\nls\n```")
        let kinds = b.map { b -> String in switch b { case .heading: return "h"; case .list: return "ul"; case .para: return "p"; case .table: return "table"; case .pre: return "pre"; case .hr: return "hr"; case .math: return "math" } }
        precondition(kinds == ["h", "ul", "p", "table", "pre"], "\(kinds)")
        if case .para(let i) = b[2] { precondition(i.contains { if case .math(let t) = $0 { return t == "\\pi r^2" }; return false }) }
        precondition(answerWords(parseMarkdown("**Two** words")) == ["Two", "words"])
    }
    precondition(capsOf("fn⌃Space") == ["fn", "⌃", "Space"] && capsOf("⌃⌥Space") == ["⌃", "⌥", "Space"] && capsOf("F5") == ["F5"])
    precondition(orbFrame("breathing", 64, 0).dots.count == 484 && orbFrame("connecting", 64, 0).lines.count > 0)
    print("native selftest ok"); exit(0)
}
// The brain's typing helper shares selection validation and clipboard ownership with Replace.
if CommandLine.arguments.dropFirst() == ["--type"] {
    let nsapp = NSApplication.shared; nsapp.setActivationPolicy(.accessory)
    guard let selected = TextSelection.capture(enabled: true, allowEmpty: true), selected.caret, selected.editable || selected.pastable else {
        print("Could not type: a verified empty caret is required. Place it with --hands, and never replace selected text."); exit(1)
    }
    let draft = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
    let target = AXUIElementCreateApplication(selected.app.processIdentifier)
    AXUIElementSetMessagingTimeout(target, 0.15)
    selected.apply(draft, valid: {
        guard NSWorkspace.shared.frontmostApplication == selected.app,
              let focused = axAttribute(target, kAXFocusedUIElementAttribute) else { return false }
        return CFEqual(focused, selected.focus)
    }) { ok in
        print(ok ? "typed into \(selected.app.localizedName ?? "app")" : "Could not type: the field lost focus or the keystroke could not be sent.")
        if ok { DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { exit(0) } }
        else { exit(1) }
    }
    nsapp.run(); exit(1)
}

let lockFD = open((Prefs.path as NSString).deletingLastPathComponent + "/app.lock", O_CREAT | O_RDWR, 0o600)
if lockFD >= 0 && flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
    for _ in 0..<15 where flock(lockFD, LOCK_EX | LOCK_NB) != 0 { usleep(100_000) }   // a restart: the old one is exiting
    if flock(lockFD, LOCK_EX | LOCK_NB) != 0 { exit(0) }
}

let calendar = EKEventStore()   // setup asks for calendar access with it
// Call apps holding the mic: a done card waits until the call ends. Browser helpers share the browser's prefix.
let callApps = ["us.zoom.xos": "Zoom", "com.microsoft.teams": "Teams", "com.apple.FaceTime": "FaceTime", "com.tinyspeck.slackmacgap": "Slack",
                "net.whatsapp.WhatsApp": "WhatsApp", "com.hnc.Discord": "Discord", "com.cisco.webex": "Webex", "com.google.Chrome": "Chrome",
                "com.apple.WebKit.GPU": "Safari", "company.thebrowser": "Arc", "com.brave.Browser": "Brave", "com.microsoft.edgemac": "Edge", "org.mozilla.firefox": "Firefox"]
func callAppsOnMic() -> Set<String> {   // names of call apps whose audio input is running right now (macOS 14.2+ per-process audio objects)
    Set(audioProp(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList, AudioObjectID(0)).compactMap { p in
        guard audioProp(p, kAudioProcessPropertyIsRunningInput, UInt32(0)).first ?? 0 != 0 else { return nil }
        var a = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyBundleID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var id: Unmanaged<CFString>?, size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(p, &a, 0, nil, &size, &id) == noErr, let bundle = id?.takeRetainedValue() as String? else { return nil }
        return callApps.first { bundle.hasPrefix($0.key) }?.value
    })
}
let app = App()
RunLoop.main.add(Timer(timeInterval: 1, repeats: true) { _ in app.wakeTick() }, forMode: .common)   // also while the box tracks a click or its field
let agentsUI = AgentPanels()
let routineWake = RoutineWake()
let onboarding = Onboarding()
if !UserDefaults.standard.bool(forKey: "onboarded") { DispatchQueue.main.async { onboarding.open() } }
else { Onboarding.plan { c in if c["ok"] as? Bool != true { onboarding.open(automatic: true) } } }   // set up once, but Claude signed out since
// An idea only while the user is at the Mac and nothing else wants them: no call, sharing, full-screen app, setup, or Aurel in use.
let launched = Date()
var specs = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
             EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
InstallEventHandler(GetApplicationEventTarget(), { _, ev, _ in
    let pressed = GetEventKind(ev) == UInt32(kEventHotKeyPressed)
    var hk = EventHotKeyID()
    GetEventParameter(ev, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
    DispatchQueue.main.async { if hk.id == 2 { if pressed { app.escape() } } else if hk.id == 3 || hk.id == 4 { if pressed { app.defaultAction() } } else if hk.id == 5 { if pressed { app.moveToAgent() } } else if hk.id == 6 { app.dictateShortcut(pressed) } else if hk.id == 7 { if pressed { app.pasteLastDictation() } } else { app.shortcut(pressed) } }
    return noErr
}, 2, &specs, nil, nil)
var ref: EventHotKeyRef?
var dictateRef: EventHotKeyRef?
var hotkeyRegistered = false
var dictateHotkeyRegistered = false
var specialGlobalHotkeys: Any?, specialLocalHotkeys: Any?, specialMainDown = false, specialDictateDown = false
for name in [NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification, NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
    NSWorkspace.shared.notificationCenter.addObserver(forName:name, object:nil, queue:.main) { _ in
        specialMainDown = false; specialDictateDown = false
        if name == NSWorkspace.willSleepNotification { app.wakeSleeping = true }
        if name == NSWorkspace.didWakeNotification { app.wakeSleeping = false }
        if name == NSWorkspace.sessionDidResignActiveNotification { app.wakeInactive = true }
        if name == NSWorkspace.sessionDidBecomeActiveNotification { app.wakeInactive = false }
        app.prepareForInactiveSession()
    }
}
func specialHotkey(_ h: (code: Int, mods: Int, flags: NSEvent.ModifierFlags)) -> Bool { h.code < 0 || h.mods & aurelFnKey != 0 }
func hotkeysConflict(_ a: (code: Int, mods: Int, flags: NSEvent.ModifierFlags), _ b: (code: Int, mods: Int, flags: NSEvent.ModifierFlags)) -> Bool {
    a.code == b.code && a.mods == b.mods ||
    a.code < 0 && a.mods & b.mods == a.mods ||
    b.code < 0 && b.mods & a.mods == b.mods
}
func stopSpecialHotkeys() {
    if let m = specialGlobalHotkeys { NSEvent.removeMonitor(m); specialGlobalHotkeys = nil }
    if let m = specialLocalHotkeys { NSEvent.removeMonitor(m); specialLocalHotkeys = nil }
    specialMainDown = false; specialDictateDown = false
}
func updateSpecialHotkey(_ e: NSEvent, _ h: (code: Int, mods: Int, flags: NSEvent.ModifierFlags), _ down: inout Bool, chord: () -> Bool = { false }, _ action: (Bool) -> Void) {
    guard specialHotkey(h) else { return }
    let next: Bool
    if h.code < 0 {
        // Arrows and F-keys carry the fn flag on their own key events, so only a modifier change presses or releases.
        // Another key while held (fn+Delete, ⌃⌥+K) is that key's shortcut; chord() drops the press if nothing was said yet.
        if e.type == .keyDown { if down, chord() { down = false }; return }
        guard e.type == .flagsChanged else { return }
        next = shortcutModifiers(e.modifierFlags) == h.mods
    } else {
        if e.type == .flagsChanged, down, shortcutModifiers(e.modifierFlags) != h.mods { next = false }
        else {
            guard Int(e.keyCode) == h.code else { return }
            if e.type == .keyDown { guard shortcutModifiers(e.modifierFlags) == h.mods else { return }; next = true }
            else if e.type == .keyUp { next = false }
            else { return }
        }
    }
    guard next != down else { return }
    down = next; action(next)
}
func handleSpecialHotkeys(_ e: NSEvent) {
    updateSpecialHotkey(e, hotkey(), &specialMainDown) { app.shortcut($0) }
    if !Prefs.str("dictateHotkeyLabel").isEmpty {
        updateSpecialHotkey(e, dictateHotkey(), &specialDictateDown, chord: app.dictateChord) { app.dictateShortcut($0) }
    }
}
func refreshSpecialHotkeys() {
    stopSpecialHotkeys()
    guard specialHotkey(hotkey()) || !Prefs.str("dictateHotkeyLabel").isEmpty && specialHotkey(dictateHotkey()) else { return }
    let events: NSEvent.EventTypeMask = [.flagsChanged, .keyDown, .keyUp]
    specialGlobalHotkeys = NSEvent.addGlobalMonitorForEvents(matching: events) { e in DispatchQueue.main.async { handleSpecialHotkeys(e) } }
    specialLocalHotkeys = NSEvent.addLocalMonitorForEvents(matching: events) { e in handleSpecialHotkeys(e); return e }
}
@discardableResult func registerHotkey() -> Bool {   // false: another app already owns that shortcut
    if let r = ref { UnregisterEventHotKey(r); ref = nil }
    let h = hotkey()
    let conflict = !Prefs.str("dictateHotkeyLabel").isEmpty && hotkeysConflict(h, dictateHotkey())
    hotkeyRegistered = !conflict && (specialHotkey(h) || RegisterEventHotKey(UInt32(h.code), UInt32(h.mods), EventHotKeyID(signature: 0x41545443, id: 1), GetApplicationEventTarget(), 0, &ref) == noErr)
    refreshSpecialHotkeys(); return hotkeyRegistered
}
@discardableResult func registerDictateHotkey() -> Bool {
    if let r = dictateRef { UnregisterEventHotKey(r); dictateRef = nil }
    guard !Prefs.str("dictateHotkeyLabel").isEmpty else { dictateHotkeyRegistered = true; refreshSpecialHotkeys(); return true }
    let h = dictateHotkey()
    dictateHotkeyRegistered = !hotkeysConflict(h, hotkey()) && (specialHotkey(h) || RegisterEventHotKey(UInt32(h.code), UInt32(h.mods), EventHotKeyID(signature: 0x41545443, id: 6), GetApplicationEventTarget(), 0, &dictateRef) == noErr)
    refreshSpecialHotkeys(); return dictateHotkeyRegistered
}
registerHotkey()
registerDictateHotkey()
// ⌃⌘V pastes the last dictation; skipped when Aurel's own shortcuts hold it or another app (Willow Voice) already does.
var pasteRef: EventHotKeyRef?
let pasteHotkey = (code: 9, mods: controlKey | cmdKey, flags: NSEvent.ModifierFlags([.control, .command]))
let pasteHotkeyRegistered = !hotkeysConflict(pasteHotkey, hotkey()) && (Prefs.str("dictateHotkeyLabel").isEmpty || !hotkeysConflict(pasteHotkey, dictateHotkey())) &&
    RegisterEventHotKey(UInt32(pasteHotkey.code), UInt32(pasteHotkey.mods), EventHotKeyID(signature: 0x41545443, id: 7), GetApplicationEventTarget(), 0, &pasteRef) == noErr
let settings = SettingsWindow()
let bar = MenuBar()
let delegate = Delegate()
NSApplication.shared.delegate = delegate
if !hotkeyRegistered || !dictateHotkeyRegistered { DispatchQueue.main.async { settings.open() } }   // another app owns a saved shortcut: show the warning, not a silent dead key
Updater.schedule()

// Test hook: `defaults write com.aurel.app demo -string "<request>"` then restart runs it once without the mic.
if let demo = UserDefaults.standard.string(forKey: "demo") {
    UserDefaults.standard.removeObject(forKey: "demo")
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { app.js("listen"); app.show(); app.js("words", demo); app.run(demo) }
}

// ⌘X/C/V/A/Z in every Aurel text field (typing box, choices, Settings): a menu-bar-less app has no Edit
// menu to route them, and a non-activating panel never gets menu shortcuts anyway, so send them down the responder chain.
NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
    let mods = e.modifierFlags.intersection(.deviceIndependentFlagsMask), k = e.charactersIgnoringModifiers?.lowercased() ?? ""
    let action: Selector? = mods == [.command, .shift] ? (k == "z" ? Selector(("redo:")) : nil) : mods != .command ? nil :
        ["x": #selector(NSText.cut(_:)), "c": #selector(NSText.copy(_:)), "v": #selector(NSText.paste(_:)), "a": #selector(NSText.selectAll(_:)), "z": Selector(("undo:"))][k]
    guard let action, NSApp.sendAction(action, to: nil, from: nil) else { return e }
    return nil
}
NSApplication.shared.setActivationPolicy(.accessory)
NSApplication.shared.run()
