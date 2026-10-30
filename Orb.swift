// thinking-orbs 0.3.2 engine, ported line for line from its JS (dist/index-B8WsUNf5.js) — MIT License, Copyright (c) 2026 Jakub Antalik. https://github.com/Jakubantalik/thinking-orbs
// Same math, same order, same rounding as the canvas version the HTML pages drew, so the dots land on the same pixels.
import AppKit

struct OrbDot { var x, y, z, r, white, a: Double }
struct OrbLine { var x1, y1, x2, y2, white, a, w: Double }
struct OrbFrame { var dots: [OrbDot]; var lines: [OrbLine] }
typealias OrbOpts = [String: Double]

private func jsRound(_ x: Double) -> Double { (x + 0.5).rounded(.down) }   // Math.round: halves go up, even below zero
private func lerp(_ a: Double, _ b: Double, _ f: Double) -> Double { a + (b - a) * f }
private func frac(_ x: Double) -> Double { x - x.rounded(.down) }
private func hashD(_ a: Double, _ b: Double) -> Double { let h = sin(a * 12.9898 + b * 78.233) * 43758.5453; return h - h.rounded(.down) }
private func vnoise(_ x: Double, _ y: Double) -> Double {
    let xi = x.rounded(.down), yi = y.rounded(.down)
    var fx = x - xi, fy = y - yi
    fx = fx * fx * (3 - 2 * fx); fy = fy * fy * (3 - 2 * fy)
    let a = hashD(xi, yi), b = hashD(xi + 1, yi), c = hashD(xi, yi + 1), d = hashD(xi + 1, yi + 1)
    return a + (b - a) * fx + (c - a) * fy + (a - b - c + d) * fx * fy
}
private func fibDir(_ i: Int, _ n: Int) -> (Double, Double, Double) {
    let golden = Double.pi * (3 - sqrt(5.0))
    let y = 1 - 2 * (Double(i) + 0.5) / Double(n), rad = sqrt(1 - y * y), a = Double(i) * golden
    return (rad * cos(a), y, rad * sin(a))
}
private func angleDelta(_ a: Double, _ b: Double) -> Double { atan2(sin(a - b), cos(a - b)) }
private func makeProj(_ yaw: Double, _ tilt: Double, _ cx: Double, _ cy: Double, _ scale: Double) -> (Double, Double, Double) -> (Double, Double, Double) {
    let st = sin(tilt), ct = cos(tilt), sy = sin(yaw), cyw = cos(yaw)
    return { x, y, z in
        let x1 = x * cyw + z * sy, z1 = -x * sy + z * cyw
        let y1 = y * ct - z1 * st, z2 = y * st + z1 * ct
        return (cx + x1 * scale, cy - y1 * scale, z2)
    }
}
private func finalizeFrame(_ dots: [OrbDot], _ lines: [OrbLine], _ rMin: Double?) -> OrbFrame {
    let rMin = rMin ?? 0.3
    var visible: [(Int, OrbDot)] = []
    for (i, var d) in dots.enumerated() where d.a >= 0.02 { d.r = max(rMin, d.r); visible.append((i, d)) }
    visible.sort { $0.1.z != $1.1.z ? $0.1.z < $1.1.z : $0.0 < $1.0 }   // Array.sort in JS is stable
    return OrbFrame(dots: visible.map(\.1), lines: lines.filter { $0.a >= 0.02 })
}
private func radiusScale(_ size: Double, _ pow_: Double) -> Double { pow(size / 300, pow_) }

private let countPairs = [("latRings", "lonDensity"), ("rings", "lonDensity"), ("lanes", "segs")]
private let countKeys = ["orbitN", "ghostN", "nodeN", "strandN", "signals"]
private let radiusKeys = ["rBase", "rDepth", "rActive", "rDot", "ghostR", "partR", "partRDepth", "nodeR", "nodeRDepth"]
private func scaleCounts(_ opts: OrbOpts, _ scale: Double) -> OrbOpts {
    var out = opts, done = Set<String>()
    let rt = sqrt(scale)
    for (a, b) in countPairs {
        if let va = out[a], let vb = out[b], !done.contains(a), !done.contains(b) {
            out[a] = max(2, jsRound(va * rt)); out[b] = max(2, jsRound(vb * rt)); done.insert(a); done.insert(b)
        }
    }
    for k in countKeys { if let v = out[k], v != 0, !done.contains(k) { out[k] = max(1, jsRound(v * scale)) } }
    if let v = out["iconD"] { out["iconD"] = max(0.02, v * scale) }
    return out
}
private func scaleRadii(_ opts: OrbOpts, _ scale: Double) -> OrbOpts {
    var out = opts
    for k in radiusKeys { if let v = out[k] { out[k] = v * scale } }
    out["rSizeMul"] = (out["rSizeMul"] ?? 1) * scale
    return out
}
private let baseProfiles: [String: OrbOpts] = [
    "globe": ["latRings": 17, "lonDensity": 44, "rBase": 0.6, "rDepth": 1.7, "rBoost": 1, "inkFar": 0.62, "inkSpan": 0.54, "rsPow": 0.6, "rMin": 0.3],
    "orbits": ["orbitN": 12, "ghostN": 40, "ghostR": 0.9, "ghostA": 0.5, "particles": 3, "partR": 1.2, "partRDepth": 1.6, "rsPow": 0.6, "rMin": 0.3],
    "rubik": ["latRings": 15, "lonDensity": 40, "moveCount": 14, "rBase": 0.6, "rDepth": 1.7, "rActive": 0.3, "inkFar": 0.62, "inkSpan": 0.54, "rsPow": 0.6, "rMin": 0.3],
    "wave": ["rings": 15, "lonDensity": 40, "rBase": 0.6, "rDepth": 1.7, "rsPow": 0.6, "rMin": 0.3],
    "web": ["nodeN": 30, "thr": 0.72, "signals": 5, "nodeR": 1.4, "nodeRDepth": 1.8, "lineW": 0.8, "rsPow": 0.6, "rMin": 0.3],
    "braid": ["strandN": 52, "turns": 3, "ghostN": 150, "rBase": 1.2, "rDepth": 1.8, "rsPow": 0.6, "rMin": 0.3],
    "ribbon": ["lanes": 5, "segs": 88, "ghostN": 150, "rBase": 1.1, "rDepth": 1.7, "rsPow": 0.6, "rMin": 0.3],
    "ring": ["lanes": 5, "segs": 88, "ghostN": 0, "faceOn": 1, "rBase": 1.1, "rDepth": 1.7, "rsPow": 0.6, "rMin": 0.3],   // ribbon's painter seen face on, with no ghost sphere
    "morph": ["rDot": 0.021, "iconD": 1, "rMin": 0.25],
]

private func frameBraid(_ size: Double, _ t: Double, _ o: OrbOpts) -> OrbFrame {
    let cx = size / 2, cy = size / 2, R = size / 2 * 0.76
    let pt = makeProj(t * 0.4, 0.3, cx, cy, 1), rs = radiusScale(size, o["rsPow"] ?? 0.6)
    var dots: [OrbDot] = []
    let ghostN = Int(o["ghostN"] ?? 150)
    for i in 0..<max(0, ghostN) {
        let d = fibDir(i, ghostN), (px, py, z) = pt(d.0 * R, d.1 * R, d.2 * R), depth = (z / R + 1) / 2
        dots.append(OrbDot(x: px, y: py, z: z, r: 0.8 * rs, white: 0.78, a: 0.1 + 0.22 * depth))
    }
    let strandN = Int(o["strandN"] ?? 52), turns = o["turns"] ?? 3
    for s in 0..<3 {
        let phase = Double(s) / 3 * 2 * .pi
        for i in 0..<strandN {
            let u = (frac(Double(i) / Double(strandN) + t * 0.045) * 2 - 1) * 0.96
            let surf = sqrt(max(0, 1 - u * u)), endFade = min(1, (1 - abs(u)) / 0.1)
            let a = u * .pi * turns + phase
            let weave = 1 + 0.075 * sin(u * .pi * turns * 2 + phase * 2 + t * 0.8)
            let rr = surf * R * weave
            let (px, py, zr) = pt(cos(a) * rr, u * R * weave, sin(a) * rr), depth = (zr / R + 1) / 2
            dots.append(OrbDot(x: px, y: py, z: zr, r: ((o["rBase"] ?? 1.2) + (o["rDepth"] ?? 1.8) * depth) * rs, white: 0.55 - 0.45 * depth, a: endFade * (0.45 + 0.55 * depth)))
        }
    }
    return finalizeFrame(dots, [], o["rMin"])
}

private struct Solve { var amount: [Double]; var active: Int }
private func solveCycle(_ time: Double, _ count: Int, _ slotDur: Double, _ rest: Double) -> Solve {
    let cyc = 2 * Double(count) * slotDur + rest, tc = time.truncatingRemainder(dividingBy: cyc)
    var amount = [Double](repeating: 0, count: count), active = -1
    if tc < 2 * Double(count) * slotDur {
        let slot = Int((tc / slotDur).rounded(.down)), p = (tc - Double(slot) * slotDur) / slotDur
        let cl = min(1, p / 0.7), ep = 1 - pow(1 - cl, 3)
        if slot < count {
            for i in 0..<slot { amount[i] = 1 }
            amount[slot] = ep; active = slot
        } else {
            let u = 2 * count - 1 - slot
            for i in 0..<u { amount[i] = 1 }
            amount[u] = 1 - ep; active = u
        }
    }
    return Solve(amount: amount, active: active)
}
private struct Move { var axis: Int; var lo, hi, ang: Double }
private func applyMoves(_ p: (Double, Double, Double), _ moves: [Move], _ sc: Solve) -> (Double, Double, Double, Bool) {
    var (x, y, z) = p, inActive = false
    for (i, mv) in moves.enumerated() {
        if sc.amount[i] <= 0 { continue }
        let coord = mv.axis == 0 ? x : mv.axis == 1 ? y : z
        if coord < mv.lo || coord >= mv.hi { continue }
        if i == sc.active { inActive = true }
        let a = mv.ang * sc.amount[i], ca = cos(a), sa = sin(a)
        if mv.axis == 0 { let y2 = y * ca - z * sa; z = y * sa + z * ca; y = y2 }
        else if mv.axis == 1 { let x2 = x * ca + z * sa; z = -x * sa + z * ca; x = x2 }
        else { let x2 = x * ca - y * sa; y = x * sa + y * ca; x = x2 }
    }
    return (x, y, z, inActive)
}
private func makeMoves(_ count: Int) -> [Move] {
    (0..<count).map { i in
        let i = Double(i)
        let axis = min(2, Int((hashD(i, 2.3) * 3).rounded(.down)))
        let lo = -1 + 0.5 * min(3, (hashD(i, 5.9) * 4).rounded(.down))
        let dir: Double = hashD(i, 7.7) < 0.5 ? 1 : -1
        return Move(axis: axis, lo: lo, hi: lo + 0.5, ang: dir * .pi / 2)
    }
}

private func frameGlobe(_ size: Double, _ t: Double, _ o: OrbOpts) -> OrbFrame {
    let spin = 0.5, cx = size / 2, cy = size / 2, radius = size / 2 * 0.82
    let tilt = 0.4 + 0.06 * sin(t * 0.35)
    let pt = makeProj(t * spin, tilt, cx, cy, radius)
    let scan = t * (spin + (1.7 - spin) * (o["scanMul"] ?? 1))
    let rs = radiusScale(size, o["rsPow"] ?? 0.6), dimBase = o["dimBase"] ?? 1
    var dots: [OrbDot] = []
    let latRings = Int(o["latRings"] ?? 17), lonDensity = o["lonDensity"] ?? 44
    for li in 0...latRings {
        let lat = -Double.pi / 2 + Double(li) / Double(latRings) * .pi, cosLat = cos(lat), sinLat = sin(lat)
        let lonCount = Int(max(1, jsRound(abs(cosLat) * lonDensity)))
        for lj in 0..<lonCount {
            let lon = Double(lj) / Double(lonCount) * 2 * .pi
            let (px, py, z) = pt(cosLat * cos(lon), sinLat, cosLat * sin(lon)), depth = (z + 1) / 2
            let d = angleDelta(lon + t * spin, scan), boost = exp(-(d * d) / 0.18) * max(0, z)
            dots.append(OrbDot(x: px, y: py, z: z, r: ((o["rBase"] ?? 0.6) + (o["rDepth"] ?? 1.7) * depth + (o["rBoost"] ?? 1) * boost) * rs,
                               white: (o["inkFar"] ?? 0.62) - (o["inkSpan"] ?? 0.54) * depth, a: dimBase + (1 - dimBase) * min(1, boost)))
        }
    }
    return finalizeFrame(dots, [], o["rMin"])
}

private func frameRubik(_ size: Double, _ t: Double, _ o: OrbOpts) -> OrbFrame {
    let cx = size / 2, cy = size / 2, R = size / 2 * 0.82
    let pt = makeProj(t * 0.55, 0.35 + 0.1 * sin(t * 0.9), cx, cy, R), rs = radiusScale(size, o["rsPow"] ?? 0.6)
    let moveCount = Int(o["moveCount"] ?? 14), moves = makeMoves(moveCount), sc = solveCycle(t, moveCount, 0.42, 1.2)
    var dots: [OrbDot] = []
    let latRings = Int(o["latRings"] ?? 15), lonDensity = o["lonDensity"] ?? 40
    for li in 0...latRings {
        let lat = -Double.pi / 2 + Double(li) / Double(latRings) * .pi, cosLat = cos(lat), sinLat = sin(lat)
        let lonCount = Int(max(1, jsRound(abs(cosLat) * lonDensity)))
        for lj in 0..<lonCount {
            let lon = Double(lj) / Double(lonCount) * 2 * .pi
            let (x, y, z, inActive) = applyMoves((cosLat * cos(lon), sinLat, cosLat * sin(lon)), moves, sc)
            let (px, py, zr) = pt(x, y, z), depth = (zr + 1) / 2
            dots.append(OrbDot(x: px, y: py, z: zr, r: ((o["rBase"] ?? 0.6) + (o["rDepth"] ?? 1.7) * depth + (inActive ? o["rActive"] ?? 0.3 : 0)) * rs,
                               white: (o["inkFar"] ?? 0.62) - (o["inkSpan"] ?? 0.54) * depth - (inActive ? 0.14 : 0), a: 1))
        }
    }
    return finalizeFrame(dots, [], o["rMin"])
}

private func frameWave(_ size: Double, _ t: Double, _ o: OrbOpts) -> OrbFrame {
    let cx = size / 2, cy = size / 2, R = size / 2 * 0.874
    let pt = makeProj(t * 0.18, 0.38, cx, cy, 1), rs = radiusScale(size, o["rsPow"] ?? 0.6)
    var dots: [OrbDot] = []
    let rings = Int(o["rings"] ?? 15), lonDensity = o["lonDensity"] ?? 40
    for ri in 0...rings {
        let r = Double(ri)
        let lat = -Double.pi / 2 + r / Double(rings) * .pi, cosLat = cos(lat), sinLat = sin(lat)
        let w = 0.62 * sin(t * 2.1 - r * 0.52) + 0.38 * sin(t * 1.27 + r * 0.83)
        let rr = R * (0.88 + 0.105 * w)
        let lonCount = Int(max(1, jsRound(abs(cosLat) * lonDensity)))
        for lj in 0..<lonCount {
            let lon = Double(lj) / Double(lonCount) * 2 * .pi
            let (px, py, z) = pt(cosLat * cos(lon) * rr, sinLat * rr, cosLat * sin(lon) * rr)
            let depth = (z / R + 1) / 2, crest = max(0, w)
            dots.append(OrbDot(x: px, y: py, z: z, r: ((o["rBase"] ?? 0.6) + (o["rDepth"] ?? 1.7) * depth) * (1 + 0.4 * crest) * rs,
                               white: 0.66 - 0.56 * depth - 0.1 * crest, a: 1))
        }
    }
    return finalizeFrame(dots, [], o["rMin"])
}

private func smoothE(_ x: Double) -> Double { x * x * (3 - 2 * x) }
private func polyPath(_ verts: [(Double, Double)]) -> (Double) -> (Double, Double) {
    let V = verts.count
    var L: [Double] = [], total = 0.0
    for i in 0..<V { let a = verts[i], b = verts[(i + 1) % V], l = hypot(b.0 - a.0, b.1 - a.1); L.append(l); total += l }
    return { f in
        var target = f * total, i = 0
        while target > L[i] && i < V - 1 { target -= L[i]; i += 1 }
        let a = verts[i], b = verts[(i + 1) % V], ff = L[i] != 0 ? min(1, target / L[i]) : 0
        return (a.0 + (b.0 - a.0) * ff, a.1 + (b.1 - a.1) * ff)
    }
}
private let morphCycle: [(Double) -> (Double, Double)] = [
    { f in let a = -Double.pi / 2 + f * 2 * .pi; return (cos(a) * 0.24, sin(a) * 0.24) },
    polyPath([(0, -0.26), (0.24, 0.16), (-0.24, 0.16)]),
    polyPath([(0, -0.2), (0.2, -0.2), (0.2, 0.2), (-0.2, 0.2), (-0.2, -0.2)]),
]
private func frameMorph(_ size: Double, _ t: Double, _ o: OrbOpts) -> OrbFrame {
    let HOLD = 1.4, MORPH = 0.9, SEG = HOLD + MORPH, K = morphCycle.count
    let tc = t.truncatingRemainder(dividingBy: SEG * Double(K))
    let held = o["shape"].map { $0 >= 0 && $0 < Double(K) ? Int($0.rounded(.down)) : -1 } ?? -1
    let k = held >= 0 ? held : Int((tc / SEG).rounded(.down))
    let local = held >= 0 ? t.truncatingRemainder(dividingBy: SEG) : tc - Double(k) * SEG
    let m = held >= 0 ? 0 : local > HOLD ? smoothE((local - HOLD) / MORPH) : 0
    let sprd = o["spread"] ?? 1
    let pA = morphCycle[k], pB = held >= 0 ? pA : morphCycle[(k + 1) % K]
    let M = 160
    var pts: [(Double, Double)] = []
    for i in 0..<M { let f = Double(i) / Double(M), a = pA(f), b = pB(f); pts.append(((a.0 + (b.0 - a.0) * m) * sprd, (a.1 + (b.1 - a.1) * m) * sprd)) }
    var L: [Double] = [], total = 0.0
    for i in 0..<M { let a = pts[i], b = pts[(i + 1) % M], l = hypot(b.0 - a.0, b.1 - a.1); L.append(l); total += l }
    let n = Int(max(6, jsRound(34 * (o["iconD"] ?? 1))))
    let re = (o["rDot"] ?? 0.021) * 1.35 * sprd, pulse = 1 + 0.02 * sin(local * 3.1)
    var dots: [OrbDot] = []
    let c2 = size / 2
    var seg = 0, acc = 0.0
    for k2 in 0..<n {
        let target = Double(k2) / Double(n) * total
        while acc + L[seg] < target && seg < M - 1 { acc += L[seg]; seg += 1 }
        let a = pts[seg], b = pts[(seg + 1) % M], f = L[seg] != 0 ? min(1, (target - acc) / L[seg]) : 0
        let x = (a.0 + (b.0 - a.0) * f) * pulse, y = (a.1 + (b.1 - a.1) * f) * pulse
        dots.append(OrbDot(x: c2 + x * size, y: c2 + y * size, z: 0, r: max(0.35, re * size), white: 0.1, a: 1))
    }
    return finalizeFrame(dots, [], o["rMin"])
}

private func frameOrbits(_ size: Double, _ t: Double, _ o: OrbOpts) -> OrbFrame {
    let cx = size / 2, cy = size / 2, R = size / 2 * 0.82
    let pt = makeProj(t * 0.12, 0.3, cx, cy, 1), rs = radiusScale(size, o["rsPow"] ?? 0.6)
    var dots: [OrbDot] = []
    let orbitN = Int(o["orbitN"] ?? 12), ghostN = Int(o["ghostN"] ?? 40), particles = Int(o["particles"] ?? 3)
    for orb in 0..<orbitN {
        let ob = Double(orb)
        let h1 = hashD(ob, 1.7), h2 = hashD(ob, 5.2), h3 = hashD(ob, 8.9)
        let ro = R * (0.45 + 0.52 * h1), th = h1 * 2 * .pi, phi = acos(2 * h2 - 1)
        let nx = sin(phi) * cos(th), ny = cos(phi), nz = sin(phi) * sin(th)
        var ux = -ny, uy = nx
        let uz = 0.0, ul = max(1e-6, sqrt(ux * ux + uy * uy))
        ux /= ul; uy /= ul
        let vx = ny * uz - nz * uy, vy = nz * ux - nx * uz, vz = nx * uy - ny * ux
        let speed = (0.25 + 0.55 * h3) * (h3 > 0.5 ? 1 : -1)
        for k in 0..<ghostN {
            let a = Double(k) / Double(ghostN) * 2 * .pi
            let (px, py, z) = pt((ux * cos(a) + vx * sin(a)) * ro, (uy * cos(a) + vy * sin(a)) * ro, (uz * cos(a) + vz * sin(a)) * ro)
            let depth = (z / ro + 1) / 2
            dots.append(OrbDot(x: px, y: py, z: z, r: (o["ghostR"] ?? 0.9) * rs, white: 0.72, a: (o["ghostA"] ?? 0.5) * (0.4 + 0.6 * depth)))
        }
        for m in 0..<particles {
            let a = t * speed + Double(m) / Double(particles) * 2 * .pi + h2 * 6
            let (px, py, z) = pt((ux * cos(a) + vx * sin(a)) * ro, (uy * cos(a) + vy * sin(a)) * ro, (uz * cos(a) + vz * sin(a)) * ro)
            let depth = (z / ro + 1) / 2
            dots.append(OrbDot(x: px, y: py, z: z, r: ((o["partR"] ?? 1.2) + (o["partRDepth"] ?? 1.6) * depth) * rs, white: 0.3 - 0.22 * depth, a: 1))
        }
    }
    return finalizeFrame(dots, [], o["rMin"])
}

private func frameRibbon(_ size: Double, _ t: Double, _ o: OrbOpts) -> OrbFrame {
    let cx = size / 2, cy = size / 2, R = size / 2 * 0.78, spin = o["spin"] ?? 1, camTilt = 0.3
    let pt = makeProj(t * 0.1 * spin, camTilt, cx, cy, 1), rs = radiusScale(size, o["rsPow"] ?? 0.6)
    var dots: [OrbDot] = []
    let ghostN = Int(o["ghostN"] ?? 150)
    for i in 0..<max(0, ghostN) {
        let d = fibDir(i, ghostN), (px, py, z) = pt(d.0 * R, d.1 * R, d.2 * R), depth = (z / R + 1) / 2
        dots.append(OrbDot(x: px, y: py, z: z, r: 0.8 * rs, white: 0.78, a: 0.1 + 0.22 * depth))
    }
    let faceOn = (o["faceOn"] ?? 0) != 0
    let ya = t * 0.24 * spin, ta = faceOn ? -camTilt : 0.55 + 0.3 * sin(t * 0.18) * spin
    let ux = cos(ya), uy = 0.0, uz = sin(ya)
    let vx = -uz * sin(ta), vy = cos(ta), vz = ux * sin(ta)
    let nx = uy * vz - uz * vy, ny = uz * vx - ux * vz, nz = ux * vy - uy * vx
    let wobAmp = 0.23 * (o["wobMul"] ?? 1), baseR = faceOn ? R / (1 + 0.85 * wobAmp) : R
    let baseLanes = o["lanes"] ?? 5, segs = Int(o["segs"] ?? 88)
    let lanes = Int(max(1, jsRound(baseLanes * (o["bandMul"] ?? 1))))
    for w in 0..<lanes {
        let wd = Double(w), half = Double(lanes - 1) / 2
        let laneOff = (wd - half) * 0.075, edge = abs(wd - half) / max(1, half)
        for k in 0..<segs {
            let a = Double(k) / Double(segs) * 2 * .pi
            let wob = (0.16 * sin(a * 3 - t * 1.7 + wd * 0.22) + 0.07 * sin(a * 5 + t * 1.1)) * (o["wobMul"] ?? 1)
            let radial = faceOn ? 1 + wob : 1, off = faceOn ? laneOff : laneOff + wob
            let x = ux * cos(a) + vx * sin(a) + nx * off
            let y = uy * cos(a) + vy * sin(a) + ny * off
            let z = uz * cos(a) + vz * sin(a) + nz * off
            let l = sqrt(x * x + y * y + z * z), rr = baseR * radial
            let (px, py, zr) = pt(x / l * rr, y / l * rr, z / l * rr), depth = (zr / R + 1) / 2
            dots.append(OrbDot(x: px, y: py, z: zr, r: ((o["rBase"] ?? 1.1) + (o["rDepth"] ?? 1.7) * depth) * (1 - 0.25 * edge) * rs,
                               white: 0.52 - 0.44 * depth + 0.18 * edge, a: 0.4 + 0.6 * depth))
        }
    }
    return finalizeFrame(dots, [], o["rMin"])
}

private func frameWeb(_ size: Double, _ t: Double, _ o: OrbOpts) -> OrbFrame {
    let cx = size / 2, cy = size / 2, R = size / 2 * 0.8 * (o["spread"] ?? 1)
    let pt = makeProj(t * 0.12, 0.32, cx, cy, R), rs = radiusScale(size, o["rsPow"] ?? 0.6)
    let nodeN = Int(o["nodeN"] ?? 30), thr = o["thr"] ?? 0.72, nodeR = o["nodeR"] ?? 1.4, nodeRDepth = o["nodeRDepth"] ?? 1.8
    var nodes: [(Double, Double, Double)] = []
    for i in 0..<nodeN {
        let d = fibDir(i, nodeN), fi = Double(i)
        let x = d.0 + 0.3 * (vnoise(fi * 0.31 + 9, t * 0.24) - 0.5) * 2
        let y = d.1 + 0.3 * (vnoise(fi * 0.53 + 27, t * 0.21) - 0.5) * 2
        let z = d.2 + 0.3 * (vnoise(fi * 0.77 + 55, t * 0.27) - 0.5) * 2
        let l = sqrt(x * x + y * y + z * z)
        nodes.append((x / l, y / l, z / l))
    }
    var lines: [OrbLine] = [], dots: [OrbDot] = []
    for i in 0..<nodeN {
        for j in (i + 1)..<max(i + 1, nodeN) {
            let dx = nodes[i].0 - nodes[j].0, dy = nodes[i].1 - nodes[j].1, dz = nodes[i].2 - nodes[j].2
            let dist = sqrt(dx * dx + dy * dy + dz * dz)
            if dist >= thr { continue }
            let (x1, y1, z1) = pt(nodes[i].0, nodes[i].1, nodes[i].2), (x2, y2, z2) = pt(nodes[j].0, nodes[j].1, nodes[j].2)
            let depth = ((z1 + z2) / 2 + 1) / 2
            lines.append(OrbLine(x1: x1, y1: y1, x2: x2, y2: y2, white: 0.42, a: (1 - dist / thr) * (0.3 + 0.55 * depth), w: max(0.6, (o["lineW"] ?? 0.8) * rs)))
        }
    }
    for i in 0..<nodeN {
        let (px, py, z) = pt(nodes[i].0, nodes[i].1, nodes[i].2), depth = (z + 1) / 2
        let pulse = 1 + 0.25 * sin(t * 1.4 + Double(i) * 2.7)
        dots.append(OrbDot(x: px, y: py, z: z, r: (nodeR + nodeRDepth * depth) * pulse * rs, white: 0.55 - 0.45 * depth, a: 1))
    }
    let signals = Int(o["signals"] ?? 5)
    for s in 0..<signals {
        let sd = Double(s)
        let seg = (t * 0.55 + sd * 7.31).rounded(.down)
        let a = Int((hashD(seg, sd * 3.1 + 1.7) * Double(nodeN)).rounded(.down)), b = Int((hashD(seg, sd * 5.7 + 4.2) * Double(nodeN)).rounded(.down))
        if a == b { continue }
        let f = frac(t * 0.55 + sd * 7.31)
        let x = lerp(nodes[a].0, nodes[b].0, f), y = lerp(nodes[a].1, nodes[b].1, f), z = lerp(nodes[a].2, nodes[b].2, f)
        let l = max(1e-6, sqrt(x * x + y * y + z * z))
        let (px, py, zr) = pt(x / l, y / l, z / l), depth = (zr + 1) / 2
        dots.append(OrbDot(x: px, y: py, z: zr, r: (nodeR * 1.5 + nodeRDepth * depth) * rs, white: 0.05, a: 0.5 + 0.5 * depth))
    }
    return finalizeFrame(dots, lines, o["rMin"])
}

let orbModeFrames: [String: (Double, Double, OrbOpts) -> OrbFrame] = [
    "orbits": frameOrbits, "globe": frameGlobe, "rubik": frameRubik, "wave": frameWave, "web": frameWeb,
    "braid": frameBraid, "ribbon": frameRibbon, "ring": frameRibbon, "morph": frameMorph,
]
private let stateToMode = ["working": "orbits", "searching": "globe", "solving": "rubik", "listening": "wave", "connecting": "web",
                           "weaving": "braid", "composing": "ribbon", "breathing": "ring", "shaping": "morph"]
private struct OrbPresetRow { var speed, count, size: Double; var extra: OrbOpts = [:] }
private let orbPresets: [String: [Int: OrbPresetRow]] = [
    "orbits": [64: .init(speed: 1.885, count: 1, size: 1), 32: .init(speed: 2.9072, count: 0.4251, size: 1.6849), 20: .init(speed: 3.9, count: 0.238, size: 2.4)],
    "globe": [64: .init(speed: 2.015, count: 0.42, size: 1.15, extra: ["scanMul": 4.08, "dimBase": 0.45]),
              32: .init(speed: 2.3803, count: 0.1839, size: 1.4769, extra: ["scanMul": 4.2301, "dimBase": 0.45]),
              20: .init(speed: 2.665, count: 0.105, size: 1.75, extra: ["scanMul": 4.335, "dimBase": 0.45])],
    "rubik": [64: .init(speed: 1.82, count: 0.35, size: 1.05), 32: .init(speed: 1.8964, count: 0.1537, size: 1.4951), 20: .init(speed: 1.95, count: 0.088, size: 1.9)],
    "wave": [64: .init(speed: 4.388, count: 0.341, size: 1), 32: .init(speed: 4.1512, count: 0.169, size: 1.3232), 20: .init(speed: 3.998, count: 0.105, size: 1.6)],
    "web": [64: .init(speed: 3.315, count: 1.35, size: 0.95), 32: .init(speed: 5.0104, count: 0.4942, size: 1.2571), 20: .init(speed: 6.63, count: 0.25, size: 1.52)],
    "braid": [64: .init(speed: 1.625, count: 0.5, size: 1), 32: .init(speed: 2.2234, count: 0.2056, size: 1.2011), 20: .init(speed: 2.75, count: 0.1125, size: 1.36)],
    "ribbon": [64: .init(speed: 2.34, count: 0.25, size: 0.85, extra: ["spin": 0, "bandMul": 3.9, "wobMul": 1]),
               32: .init(speed: 2.7776, count: 0.0969, size: 0.9766, extra: ["spin": 0, "bandMul": 4.49, "wobMul": 1]),
               20: .init(speed: 3.12, count: 0.051, size: 1.073, extra: ["spin": 0, "bandMul": 4.94, "wobMul": 1])],
    "ring": [64: .init(speed: 3.24, count: 0.25, size: 0.956, extra: ["spin": 0, "bandMul": 3.627, "wobMul": 0.368]),
             32: .init(speed: 3.5517, count: 0.0678, size: 1.31, extra: ["spin": 0, "bandMul": 3.8265, "wobMul": 0.4751]),
             20: .init(speed: 3.78, count: 0.028, size: 1.622, extra: ["spin": 0, "bandMul": 3.968, "wobMul": 0.565])],
    "morph": [64: .init(speed: 2.405, count: 0.702, size: 0.395, extra: ["spread": 1.45]),
              32: .init(speed: 2.2057, count: 0.5937, size: 0.6916, extra: ["spread": 1.45]),
              20: .init(speed: 2.08, count: 0.53, size: 1.011, extra: ["spread": 1.45])],
]
struct OrbPreset { var mode: String; var speed: Double; var opts: OrbOpts }
func orbPreset(_ state: String, _ size: Int) -> OrbPreset {
    let mode = stateToMode[state] ?? "ring", preset = orbPresets[mode]![size]!
    var opts = baseProfiles[mode]!
    if preset.count != 1 { opts = scaleCounts(opts, preset.count) }
    if preset.size != 1 { opts = scaleRadii(opts, preset.size) }
    opts.merge(preset.extra) { $1 }
    return OrbPreset(mode: mode, speed: preset.speed, opts: opts)
}
func orbFrame(_ state: String, _ size: Int, _ t: Double) -> OrbFrame {
    let p = orbPreset(state, size)
    return orbModeFrames[p.mode]!(Double(size), t, p.opts)
}

// paintFrame on a canvas: the context is already scaled to orb units with y down. Colors go through CSS rgba(), so alpha lands on a byte like WebKit's.
private func inkColor(_ w: Double, _ alpha: Double, dark: Bool) -> CGColor {
    let g = jsRound((dark ? 1 - w : w) * 255) / 255
    let a = jsRound(min(1, max(0, alpha)) * 255) / 255
    return CGColor(srgbRed: g, green: g, blue: g, alpha: a)
}
func orbPaint(_ ctx: CGContext, _ frame: OrbFrame, dark: Bool = true) {
    for l in frame.lines {
        ctx.setStrokeColor(inkColor(min(1, max(0, l.white)), l.a, dark: dark)); ctx.setLineWidth(l.w)
        ctx.beginPath(); ctx.move(to: CGPoint(x: l.x1, y: l.y1)); ctx.addLine(to: CGPoint(x: l.x2, y: l.y2)); ctx.strokePath()
    }
    for d in frame.dots {
        ctx.setFillColor(inkColor(min(1, max(0, d.white)), d.a, dark: dark))
        ctx.beginPath(); ctx.addArc(center: CGPoint(x: d.x, y: d.y), radius: d.r, startAngle: 0, endAngle: .pi * 2, clockwise: false); ctx.fillPath()
    }
}
// One frame as the pages' <canvas> held it: S×dpr pixels square.
func orbImage(_ frame: OrbFrame, size S: Int, dpr: Int) -> CGImage? {
    let px = S * dpr
    guard let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.translateBy(x: 0, y: CGFloat(px)); ctx.scaleBy(x: CGFloat(dpr), y: -CGFloat(dpr))   // canvas space: y down
    orbPaint(ctx, frame)
    return ctx.makeImage()
}

// The orb on screen. Time runs like the pages' loop: t += dt·speed·boost each display frame (dt capped at 0.05 s where the box capped it),
// still under Reduce Motion. UIClock.frozen pins t for screenshots.
final class OrbView: NSView {
    let S: Int, dpr: Int, capped: Bool
    var state: String { didSet { if state != oldValue { preset = orbPreset(state, S); if running { link?.isPaused = false } } } }
    var boost = 1.0
    var running = true { didSet { if running && !oldValue { prev = CACurrentMediaTime(); link?.isPaused = false } } }
    private(set) var t = 0.0
    private var preset: OrbPreset, prev = CACurrentMediaTime(), link: CADisplayLink?
    private var shown: (t: Double, state: String)?   // the frame on screen: an identical one is never drawn again
    init(state: String = "breathing", size: Int = 64, dpr: Int = 2, capped: Bool = true) {
        self.S = size; self.dpr = dpr; self.capped = capped; self.state = state; preset = orbPreset(state, size)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.contentsGravity = .resize; layer?.minificationFilter = .trilinear; layer?.magnificationFilter = .linear
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(motionChanged), name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }
    @objc private func motionChanged() { if running { prev = CACurrentMediaTime(); link?.isPaused = false } }
    required init?(coder: NSCoder) { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        link?.invalidate(); link = nil
        guard window != nil else { return }
        link = displayLink(target: self, selector: #selector(tick)); link?.add(to: .main, forMode: .common)
        prev = CACurrentMediaTime(); paint()
    }
    @objc private func tick(_ l: CADisplayLink) {
        let now = CACurrentMediaTime(), dt = now - prev; prev = now
        guard running else { l.isPaused = true; return }
        let still = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if let f = UIClock.frozen { t = f.orbT }
        else if !still { t += (capped ? min(0.05, dt) : dt) * preset.speed * boost }
        if shown?.t != t || shown?.state != state { paint() }
        else if still && UIClock.frozen == nil { l.isPaused = true }   // Reduce Motion: a still orb needs no frames until its state or the setting changes
    }
    func set(t: Double) { self.t = t; paint() }
    func paint() { shown = (t, state); layer?.contents = orbImage(orbModeFrames[preset.mode]!(Double(S), t, preset.opts), size: S, dpr: dpr) }
}

// Every view that moves reads time here, so a screenshot can stop the world at one instant.
enum UIClock {
    struct Frozen { var orbT: Double; var at: Double }
    static var frozen: Frozen?
}
