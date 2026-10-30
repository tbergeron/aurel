// Screenshots of one surface (settings, onboarding, box) as the native view draws it, scene by scene, in the app's window chrome.
// tests/shoot_native.py builds this with the native UI files and compares the pictures with the ones the HTML pages drew.
// usage: shoot <surface> <scenes.json> <outdir> <light|dark>
import AppKit
import SwiftUI

let args = CommandLine.arguments
let surface = args[1], scenes = try! JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: args[2]))) as! [[String: Any]]
let out = args[3], look = args[4]
let app = NSApplication.shared
app.setActivationPolicy(.regular)
app.appearance = NSAppearance(named: look == "dark" ? .darkAqua : .aqua)
func after(_ s: Double, _ f: @escaping () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + s, execute: f) }

// A plain backdrop behind every window, so the vibrancy has the same thing to blur in both runs.
let screen = NSScreen.main!.frame
let backdrop = NSWindow(contentRect: screen, styleMask: .borderless, backing: .buffered, defer: false)
backdrop.backgroundColor = NSColor(srgbRed: 0.42, green: 0.49, blue: 0.56, alpha: 1); backdrop.level = .floating; backdrop.orderFrontRegardless()

func snap(_ name: String, _ w: NSWindow) {
    w.sharingType = .readOnly
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    p.arguments = ["-x", "-o", "-l\(w.windowNumber)", out + "/" + name + ".png"]; try! p.run(); p.waitUntilExit()
    print("shot \(name)")
}

final class KeyWindow: NSWindow { override var canBecomeKey: Bool { true } }
// Key, like the real window when you look at it: controls draw their active colors.
func key(_ w: NSWindow) { app.activate(ignoringOtherApps: true); w.makeKeyAndOrderFront(nil); w.makeFirstResponder(nil) }

// The window each surface lives in, as Aurel.swift builds it.
func chrome(_ size: NSSize) -> (NSWindow, NSVisualEffectView) {
    if surface == "box" {   // App.init: a borderless panel, dark HUD glass with an 18 pt radius, the rgb(18,18,20) tint
        let w = KeyWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        w.isOpaque = false; w.backgroundColor = .clear; w.hasShadow = true; w.level = .floating
        let bg = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        bg.material = .hudWindow; bg.state = .active; bg.wantsLayer = true; bg.appearance = NSAppearance(named: .darkAqua)
        bg.layer?.cornerRadius = 18; bg.layer?.masksToBounds = true
        let tint = NSView(frame: bg.bounds); tint.wantsLayer = true; tint.layer?.backgroundColor = NSColor(calibratedRed: 18/255, green: 18/255, blue: 20/255, alpha: 0.85).cgColor
        bg.addSubview(tint); w.contentView = bg
        w.setFrameTopLeftPoint(NSPoint(x: screen.minX + 60, y: screen.maxY - 60))
        return (w, bg)
    }
    let style: NSWindow.StyleMask = surface == "onboarding" ? [.titled, .closable, .fullSizeContentView] : [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
    let w = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: style, backing: .buffered, defer: false)
    w.titlebarAppearsTransparent = true; w.titleVisibility = .hidden; w.isReleasedWhenClosed = false; w.level = .floating
    let bg = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
    bg.material = .underWindowBackground; bg.blendingMode = .behindWindow; bg.state = .active
    w.contentView = bg
    w.setFrameTopLeftPoint(NSPoint(x: screen.minX + 60, y: screen.maxY - 60))
    return (w, bg)
}
let size = surface == "settings" ? NSSize(width: 780, height: 560) : surface == "box" ? NSSize(width: 500, height: 640) : NSSize(width: 640, height: 640)

func runNative() {
    let (w, bg) = chrome(size)
    let top: CGFloat = surface == "onboarding" ? 28 : 0
    let host = nativeSurface(surface, frame: NSRect(x: 0, y: 0, width: size.width, height: size.height - top))
    bg.addSubview(host.view)
    key(w)
    func play(_ i: Int) {
        guard i < scenes.count else { print("done"); exit(0) }
        let s = scenes[i]
        for c in s["calls"] as? [[Any]] ?? [] { host.receive(c[0] as! String, c.count > 1 ? c[1] : NSNull()) }
        after(s["wait"] as? Double ?? 0.9) {
            host.freeze(at: s["at"] as? Double)
            key(w); after(0.25) { snap(s["name"] as! String, w); play(i + 1) }
        }
    }
    after(0.5) { play(0) }
}

runNative()
app.run()
