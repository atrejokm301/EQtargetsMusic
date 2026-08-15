#!/usr/bin/env swift
// Standalone pure-core checks for skip-silence v3 (no AVFoundation).
// Run: swift scripts/test_silence_core.swift

import Foundation

// MARK: - Mirror of SilenceDetectionCore (keep in sync with SilenceAnalyzer.swift)

struct FrameSeries {
    var times: [TimeInterval]
    var rmsDB: [Float]
}

struct Gates {
    var floor: Float
    var open: Float
    var hold: Float
    var peak: Float
}

func computeGates(levelsDB: [Float], midPeakDB: Float?) -> Gates {
    guard !levelsDB.isEmpty else {
        return Gates(floor: -60, open: -38, hold: -46, peak: -20)
    }
    let sorted = levelsDB.sorted()
    let n = sorted.count
    let p10 = sorted[min(n - 1, max(0, Int(Double(n) * 0.10)))]
    let p20 = sorted[min(n - 1, max(0, Int(Double(n) * 0.20)))]
    let p50 = sorted[min(n - 1, max(0, Int(Double(n) * 0.50)))]
    let p90 = sorted[min(n - 1, max(0, Int(Double(n) * 0.90)))]
    let localPeak = sorted[n - 1]
    let peak = max(localPeak, midPeakDB ?? localPeak)
    var floor = max(p10, p20 - 2)
    floor = min(floor, p50 - 1)
    floor = min(max(floor, -90), -25)
    let fromFloor = floor + 12
    let fromPeak = peak - 28
    let fromP90 = p90 - 8
    var open = max(fromFloor, min(fromPeak, fromP90))
    open = min(max(open, floor + 6), peak - 6)
    open = min(max(open, -55), -12)
    var hold = open - 8
    hold = max(hold, floor + 3)
    hold = min(hold, open - 3)
    return Gates(floor: floor, open: open, hold: hold, peak: peak)
}

func energyFlux(_ levelsDB: [Float]) -> [Float] {
    guard levelsDB.count > 1 else { return Array(repeating: 0, count: levelsDB.count) }
    var flux = [Float](repeating: 0, count: levelsDB.count)
    for i in 1 ..< levelsDB.count {
        flux[i] = max(0, levelsDB[i] - levelsDB[i - 1])
    }
    if flux.count >= 3 {
        var smooth = flux
        for i in 1 ..< (flux.count - 1) {
            smooth[i] = (flux[i - 1] + flux[i] * 2 + flux[i + 1]) * 0.25
        }
        return smooth
    }
    return flux
}

func voiceActivityMask(levelsDB: [Float], flux: [Float], openGateDB: Float, holdGateDB: Float) -> [Bool] {
    let n = levelsDB.count
    var mask = [Bool](repeating: false, count: n)
    var active = false
    let fluxOpen: Float = 5.5
    for i in 0 ..< n {
        let level = levelsDB[i]
        let f = i < flux.count ? flux[i] : 0
        if active {
            if level >= holdGateDB {
                mask[i] = true
            } else {
                active = false
                mask[i] = false
            }
        } else {
            if level >= openGateDB || (level >= holdGateDB && f >= fluxOpen) {
                active = true
                mask[i] = true
            }
        }
    }
    return mask
}

func findIntroSkip(
    times: [TimeInterval],
    openMask: [Bool],
    windowSec: TimeInterval,
    minMusicHold: TimeInterval
) -> TimeInterval {
    let n = min(times.count, openMask.count)
    var run: TimeInterval = 0
    var runStartIdx = 0
    for i in 0 ..< n {
        if openMask[i] {
            if run <= 0 { runStartIdx = i }
            run += windowSec
            if run >= minMusicHold {
                let t = times[runStartIdx]
                let pad = min(windowSec * 0.6, 0.12)
                return max(0, t - pad)
            }
        } else {
            if run > 0, run < minMusicHold, i + 1 < n, openMask[i + 1] {
                run += windowSec * 0.5
                continue
            }
            run = 0
        }
    }
    return 0
}

func findEffectiveEnd(
    times: [TimeInterval],
    openMask: [Bool],
    levelsDB: [Float],
    windowSec: TimeInterval,
    fileDuration: TimeInterval,
    minMusicHold: TimeInterval,
    minTrailingQuiet: TimeInterval,
    outroPad: TimeInterval,
    holdGateDB: Float
) -> TimeInterval {
    let n = min(times.count, openMask.count)
    var lastMusicEnd: TimeInterval?
    var run: TimeInterval = 0
    var runEnd: TimeInterval = 0
    for i in 0 ..< n {
        let tEnd = times[i] + windowSec * 0.5
        if openMask[i] || levelsDB[i] >= holdGateDB {
            run += windowSec
            runEnd = tEnd
            if run >= minMusicHold { lastMusicEnd = runEnd }
        } else {
            run = 0
        }
    }
    guard let musicEnd = lastMusicEnd else { return fileDuration }
    var effectiveEnd = min(fileDuration, musicEnd + outroPad)
    let trailing = fileDuration - effectiveEnd
    if trailing < minTrailingQuiet { return fileDuration }
    var quietRun: TimeInterval = 0
    var sawQuiet = false
    for i in 0 ..< n {
        guard times[i] >= musicEnd else { continue }
        if levelsDB[i] < holdGateDB - 1 {
            quietRun += windowSec
            if quietRun >= minTrailingQuiet * 0.75 {
                sawQuiet = true
                break
            }
        } else {
            quietRun = 0
        }
    }
    if !sawQuiet, trailing < minTrailingQuiet * 1.5 { return fileDuration }
    return effectiveEnd
}

// MARK: - Helpers

func makeSeries(levels: [Float], windowSec: TimeInterval) -> (times: [TimeInterval], levels: [Float]) {
    let times = levels.indices.map { TimeInterval($0) * windowSec }
    return (times, levels)
}

func assertTrue(_ cond: Bool, _ msg: String) {
    if !cond {
        fputs("FAIL: \(msg)\n", stderr)
        exit(1)
    }
    print("PASS: \(msg)")
}

// MARK: - Cases

let window: TimeInterval = 0.05
let hold: TimeInterval = 0.70

// 1) Leading silence then music → intro ~4s
do {
    var levels = [Float](repeating: -55, count: 80) // 4s noise
    levels += [Float](repeating: -18, count: 200) // music
    let (times, lv) = makeSeries(levels: levels, windowSec: window)
    let g = computeGates(levelsDB: lv, midPeakDB: -12)
    let flux = energyFlux(lv)
    let mask = voiceActivityMask(levelsDB: lv, flux: flux, openGateDB: g.open, holdGateDB: g.hold)
    let intro = findIntroSkip(times: times, openMask: mask, windowSec: window, minMusicHold: hold)
    assertTrue(intro > 3.5 && intro < 4.5, "intro skip near 4s (got \(intro))")
}

// 2) Isolated clap then silence then music → still land near music, not clap
do {
    var levels = [Float](repeating: -58, count: 40)
    levels += [-12, -14, -55] // clap blip
    levels += [Float](repeating: -58, count: 40)
    levels += [Float](repeating: -16, count: 160)
    let (times, lv) = makeSeries(levels: levels, windowSec: window)
    let g = computeGates(levelsDB: lv, midPeakDB: -12)
    let flux = energyFlux(lv)
    let mask = voiceActivityMask(levelsDB: lv, flux: flux, openGateDB: g.open, holdGateDB: g.hold)
    let intro = findIntroSkip(times: times, openMask: mask, windowSec: window, minMusicHold: hold)
    // clap is early; music around (40+3+40)*0.05 = 4.15s
    assertTrue(intro > 3.5, "clap does not count as music start (got \(intro))")
}

// 3) Music then trailing silence → trim end
do {
    var levels = [Float](repeating: -16, count: 200) // 10s music
    levels += [Float](repeating: -60, count: 80) // 4s silence
    let fileDur: TimeInterval = TimeInterval(levels.count) * window
    let (times, lv) = makeSeries(levels: levels, windowSec: window)
    let g = computeGates(levelsDB: lv, midPeakDB: -12)
    let flux = energyFlux(lv)
    let mask = voiceActivityMask(levelsDB: lv, flux: flux, openGateDB: g.open, holdGateDB: g.hold)
    let end = findEffectiveEnd(
        times: times,
        openMask: mask,
        levelsDB: lv,
        windowSec: window,
        fileDuration: fileDur,
        minMusicHold: hold,
        minTrailingQuiet: 1.35,
        outroPad: 0.65,
        holdGateDB: g.hold
    )
    assertTrue(end < fileDur - 2.0, "trims trailing silence (end=\(end) file=\(fileDur))")
    assertTrue(end > 9.0, "does not clip music body (end=\(end))")
}

// 4) Soft song: noise -50, music -30, mid peak -28 → should still open
do {
    var levels = [Float](repeating: -52, count: 60)
    levels += [Float](repeating: -30, count: 120)
    let g = computeGates(levelsDB: levels, midPeakDB: -28)
    assertTrue(g.open < -20, "soft song open gate not too high (open=\(g.open))")
    let flux = energyFlux(levels)
    let mask = voiceActivityMask(levelsDB: levels, flux: flux, openGateDB: g.open, holdGateDB: g.hold)
    let openCount = mask.filter { $0 }.count
    assertTrue(openCount > 50, "soft music still detected as active (open frames=\(openCount))")
}

print("\nAll silence-core checks passed.")
