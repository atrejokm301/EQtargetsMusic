//
//  SilenceAnalyzer.swift
//  EQtargetsMusic
//
//  Skip-silence v3 — playable-window detection for live alabanzas / long
//  intros / trailing dead air.
//
//  Goals (same product job as v1/v2, better mechanics):
//  - Skip leading silence / room tone without chopping soft musical attacks
//  - Ignore isolated claps / coughs at the start of live recordings
//  - Trim trailing silence so natural crossfade arms before dead air
//  - Stay cheap: head + tail only, never full-file decode; fast path main-safe
//
//  v3 algorithm (on-device, no ML):
//  1. Short-time RMS in dB via vDSP (mono energy)
//  2. Energy flux (positive first difference) as onset / activity cue
//  3. Robust noise floor from low percentiles of the scan region
//  4. Dual-threshold hysteresis VAD (open high, hold low) like telephony VAD
//  5. Require sustained “music open” before committing intro skip
//  6. Outro: last sustained music run + trailing-quiet confirmation + pad
//  7. Optional mid-file peak sample (full path) so soft songs still open
//

import Foundation
import AVFoundation
import Accelerate
import os

private let silenceLog = Logger(subsystem: "com.eqtargets.music", category: "Silence")

// MARK: - Public model

/// Playable window inside a file after silence trim.
struct SilenceTrim: Equatable {
    var introSkip: TimeInterval
    var effectiveEnd: TimeInterval
    var fileDuration: TimeInterval
    /// False when only a quick intro pass ran (outro not refined yet).
    var isFullyRefined: Bool

    static func full(duration: TimeInterval) -> SilenceTrim {
        SilenceTrim(
            introSkip: 0,
            effectiveEnd: max(duration, 0),
            fileDuration: max(duration, 0),
            isFullyRefined: true
        )
    }

    var playableDuration: TimeInterval {
        max(0, effectiveEnd - introSkip)
    }
}

// MARK: - Analyzer

enum SilenceAnalyzer {
    /// How far into the file we look for music start (live intros can be long).
    static let maxIntroScan: TimeInterval = 56
    /// How much tail we search for trailing silence.
    static let maxOutroScan: TimeInterval = 90
    /// Keep a little tail after last music so endings / reverb don't clip.
    static let outroPad: TimeInterval = 0.65
    /// Continuous open-gate time required before we treat a region as music.
    static let minMusicHold: TimeInterval = 0.70
    /// Trailing quiet must last this long before we trim the end.
    static let minTrailingQuiet: TimeInterval = 1.35
    /// Never skip more than this fraction of the file as intro.
    static let maxIntroFraction: Double = 0.45
    /// Absolute intro cap.
    static let maxIntroAbsolute: TimeInterval = 72
    /// Never leave less playable body than this (unless the file is shorter).
    static let minPlayableBody: TimeInterval = 12
    /// Fast path only needs the head; keep it short for main-thread safety.
    static let fastIntroScan: TimeInterval = 18

    // MARK: - Fast path (main-thread safe)

    /// Intro-only, slightly coarser windows. Outro left as full file end until refined.
    static func analyzeFast(_ file: AVAudioFile) -> SilenceTrim {
        let meta = fileMeta(file)
        guard meta.duration > 3.0 else { return .full(duration: meta.duration) }

        let windowSec: TimeInterval = 0.08
        let windowFrames = max(AVAudioFrameCount(meta.sr * windowSec), 512)
        let introLimit = min(
            AVAudioFramePosition(min(fastIntroScan, maxIntroScan) * meta.sr),
            meta.totalFrames
        )

        let series = sampleFrameSeries(
            file: file,
            from: 0,
            to: introLimit,
            windowFrames: windowFrames,
            channels: meta.channels
        )
        guard !series.isEmpty else { return .full(duration: meta.duration) }

        let decision = SilenceDetectionCore.detect(
            series: series,
            fileDuration: meta.duration,
            windowSec: windowSec,
            minMusicHold: minMusicHold * 0.9,
            minTrailingQuiet: minTrailingQuiet,
            outroPad: outroPad,
            mode: .introOnly,
            midPeakDB: nil
        )

        var intro = clampIntro(decision.introSkip, duration: meta.duration)
        silenceLog.debug(
            "fast v3 intro=\(intro, format: .fixed(precision: 2))s open=\(decision.openGateDB, format: .fixed(precision: 1))dB floor=\(decision.noiseFloorDB, format: .fixed(precision: 1))dB dur=\(meta.duration, format: .fixed(precision: 1))s"
        )

        return SilenceTrim(
            introSkip: intro,
            effectiveEnd: meta.duration,
            fileDuration: meta.duration,
            isFullyRefined: false
        )
    }

    // MARK: - Full path (background / cache)

    /// Full head + tail analysis. Prefer off the main actor with a fresh file.
    static func analyze(_ file: AVAudioFile) -> SilenceTrim {
        let meta = fileMeta(file)
        guard meta.duration > 3.0 else { return .full(duration: meta.duration) }

        let windowSec: TimeInterval = 0.05
        let windowFrames = max(AVAudioFrameCount(meta.sr * windowSec), 384)

        let introLimit = min(AVAudioFramePosition(maxIntroScan * meta.sr), meta.totalFrames)
        let outroSpan = min(AVAudioFramePosition(maxOutroScan * meta.sr), meta.totalFrames)
        let outroStart = max(meta.totalFrames - outroSpan, 0)

        let introSeries = sampleFrameSeries(
            file: file,
            from: 0,
            to: introLimit,
            windowFrames: windowFrames,
            channels: meta.channels
        )
        let outroSeries = sampleFrameSeries(
            file: file,
            from: outroStart,
            to: meta.totalFrames,
            windowFrames: windowFrames,
            channels: meta.channels
        )

        // Mid-file peak sample: soft recordings with quiet intros need a true peak
        // reference so the open gate doesn't sit on noise alone.
        let midPeakDB = sampleMidPeakDB(
            file: file,
            meta: meta,
            windowFrames: windowFrames,
            channels: meta.channels
        )

        guard !introSeries.isEmpty || !outroSeries.isEmpty else {
            return .full(duration: meta.duration)
        }

        let introDecision = SilenceDetectionCore.detect(
            series: introSeries,
            fileDuration: meta.duration,
            windowSec: windowSec,
            minMusicHold: minMusicHold,
            minTrailingQuiet: minTrailingQuiet,
            outroPad: outroPad,
            mode: .introOnly,
            midPeakDB: midPeakDB,
            extraLevelsDB: outroSeries.rmsDB
        )

        let outroDecision = SilenceDetectionCore.detect(
            series: outroSeries,
            fileDuration: meta.duration,
            windowSec: windowSec,
            minMusicHold: minMusicHold,
            minTrailingQuiet: minTrailingQuiet,
            outroPad: outroPad,
            mode: .outroOnly,
            midPeakDB: midPeakDB,
            extraLevelsDB: introSeries.rmsDB,
            regionStartTime: Double(outroStart) / meta.sr
        )

        var intro = clampIntro(introDecision.introSkip, duration: meta.duration)
        var end = outroDecision.effectiveEnd

        // Safety: never crush the playable body.
        let minBody = min(minPlayableBody, meta.duration * 0.45)
        if end - intro < minBody {
            if meta.duration - intro < minBody {
                intro = 0
                end = meta.duration
            } else {
                end = min(meta.duration, intro + max(minBody, meta.duration * 0.5))
            }
            silenceLog.debug(
                "full v3: body guard → intro=\(intro, format: .fixed(precision: 2)) end=\(end, format: .fixed(precision: 2))"
            )
        }

        end = max(intro + 1.0, min(end, meta.duration))

        silenceLog.info(
            "full v3 intro=\(intro, format: .fixed(precision: 2))s end=\(end, format: .fixed(precision: 2))s open=\(introDecision.openGateDB, format: .fixed(precision: 1))dB floor=\(introDecision.noiseFloorDB, format: .fixed(precision: 1))dB trimmedTail=\(meta.duration - end, format: .fixed(precision: 2))s"
        )

        return SilenceTrim(
            introSkip: intro,
            effectiveEnd: end,
            fileDuration: meta.duration,
            isFullyRefined: true
        )
    }

    /// Open file and run full analysis (background-safe).
    static func analyzeURL(_ url: URL) -> SilenceTrim? {
        let access = SecurityScopedAccess.startIfNeeded(url)
        defer { SecurityScopedAccess.stopIfNeeded(url, didStart: access) }
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        return analyze(file)
    }

    // MARK: - File helpers

    private struct FileMeta {
        var sr: Double
        var totalFrames: AVAudioFramePosition
        var duration: TimeInterval
        var channels: Int
    }

    private static func fileMeta(_ file: AVAudioFile) -> FileMeta {
        let sr = max(file.processingFormat.sampleRate, 1)
        let total = max(file.length, 0)
        return FileMeta(
            sr: sr,
            totalFrames: total,
            duration: Double(total) / sr,
            channels: max(Int(file.processingFormat.channelCount), 1)
        )
    }

    private static func clampIntro(_ intro: TimeInterval, duration: TimeInterval) -> TimeInterval {
        var s = intro
        // Tiny skips aren't worth the discontinuity.
        if s < 0.35 { return 0 }
        let fracCap = duration * maxIntroFraction
        let absCap = min(maxIntroAbsolute, max(0, duration - minPlayableBody))
        s = min(s, fracCap, absCap)
        if s < 0.35 { return 0 }
        return s
    }

    /// 2–3 short windows around 25% / 50% / 70% for a true-peak hint (not full scan).
    private static func sampleMidPeakDB(
        file: AVAudioFile,
        meta: FileMeta,
        windowFrames: AVAudioFrameCount,
        channels: Int
    ) -> Float? {
        guard meta.duration > 20 else { return nil }
        let fractions: [Double] = [0.25, 0.50, 0.70]
        var peak: Float = -120
        for f in fractions {
            let frame = AVAudioFramePosition(Double(meta.totalFrames) * f)
            let end = min(frame + AVAudioFramePosition(windowFrames) * 4, meta.totalFrames)
            let series = sampleFrameSeries(
                file: file,
                from: frame,
                to: end,
                windowFrames: windowFrames,
                channels: channels
            )
            if let m = series.rmsDB.max() {
                peak = max(peak, m)
            }
        }
        return peak > -100 ? peak : nil
    }

    private static func sampleFrameSeries(
        file: AVAudioFile,
        from start: AVAudioFramePosition,
        to end: AVAudioFramePosition,
        windowFrames: AVAudioFrameCount,
        channels: Int
    ) -> SilenceDetectionCore.FrameSeries {
        let sr = max(file.processingFormat.sampleRate, 1)
        let step = AVAudioFramePosition(windowFrames)
        var times: [TimeInterval] = []
        var levels: [Float] = []
        let capacity = max(1, Int((end - start) / max(step, 1)) + 2)
        times.reserveCapacity(capacity)
        levels.reserveCapacity(capacity)

        var pos = max(start, 0)
        let limit = min(end, file.length)
        while pos < limit {
            if let db = readRMSDB(file: file, at: pos, frames: windowFrames, channels: channels) {
                times.append(Double(pos) / sr)
                levels.append(db)
            }
            pos += step
        }
        return SilenceDetectionCore.FrameSeries(times: times, rmsDB: levels)
    }

    private static func readRMSDB(
        file: AVAudioFile,
        at frame: AVAudioFramePosition,
        frames: AVAudioFrameCount,
        channels: Int
    ) -> Float? {
        let remaining = file.length - frame
        guard remaining > 0 else { return nil }
        let n = min(frames, AVAudioFrameCount(remaining))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: n) else {
            return nil
        }
        let saved = file.framePosition
        defer { file.framePosition = saved }
        do {
            file.framePosition = max(0, frame)
            try file.read(into: buffer, frameCount: n)
        } catch {
            return nil
        }
        guard buffer.frameLength > 0, let ch = buffer.floatChannelData else { return nil }

        let count = Int(buffer.frameLength)
        guard count > 0 else { return nil }
        let chCount = min(channels, Int(file.processingFormat.channelCount))

        // Mono energy: mean of per-channel mean-square, then sqrt → RMS → dB.
        var meanSquare: Float = 0
        for c in 0 ..< chCount {
            var ms: Float = 0
            vDSP_measqv(ch[c], 1, &ms, vDSP_Length(count))
            meanSquare += ms
        }
        meanSquare /= Float(max(chCount, 1))
        let rms = sqrt(max(meanSquare, 0))
        // Floor so log10 stays finite; ~-100 dBFS.
        let safe = max(rms, 1e-5)
        return 20 * log10(safe)
    }
}

// MARK: - Pure detection core (unit-testable without AVAudioFile)

/// Dual-threshold hysteresis VAD + energy flux on short-time RMS (dB).
enum SilenceDetectionCore {
    struct FrameSeries {
        var times: [TimeInterval]
        var rmsDB: [Float]
        var isEmpty: Bool { rmsDB.isEmpty }
    }

    enum Mode {
        case introOnly
        case outroOnly
        case full
    }

    struct Decision: Equatable {
        var introSkip: TimeInterval
        var effectiveEnd: TimeInterval
        var noiseFloorDB: Float
        var openGateDB: Float
        var holdGateDB: Float
    }

    /// Public pure entry — feed window times + RMS dB series.
    static func detect(
        series: FrameSeries,
        fileDuration: TimeInterval,
        windowSec: TimeInterval,
        minMusicHold: TimeInterval,
        minTrailingQuiet: TimeInterval,
        outroPad: TimeInterval,
        mode: Mode,
        midPeakDB: Float?,
        extraLevelsDB: [Float] = [],
        regionStartTime: TimeInterval = 0
    ) -> Decision {
        guard !series.rmsDB.isEmpty, series.times.count == series.rmsDB.count else {
            return Decision(
                introSkip: 0,
                effectiveEnd: fileDuration,
                noiseFloorDB: -60,
                openGateDB: -40,
                holdGateDB: -48
            )
        }

        let gates = computeGates(levelsDB: series.rmsDB + extraLevelsDB, midPeakDB: midPeakDB)
        let flux = energyFlux(series.rmsDB)
        let openMask = voiceActivityMask(
            levelsDB: series.rmsDB,
            flux: flux,
            openGateDB: gates.open,
            holdGateDB: gates.hold
        )

        var intro: TimeInterval = 0
        var end: TimeInterval = fileDuration

        if mode == .introOnly || mode == .full {
            intro = findIntroSkip(
                times: series.times,
                openMask: openMask,
                levelsDB: series.rmsDB,
                windowSec: windowSec,
                minMusicHold: minMusicHold
            )
        }

        if mode == .outroOnly || mode == .full {
            end = findEffectiveEnd(
                times: series.times,
                openMask: openMask,
                levelsDB: series.rmsDB,
                windowSec: windowSec,
                fileDuration: fileDuration,
                regionStartTime: regionStartTime,
                minMusicHold: minMusicHold,
                minTrailingQuiet: minTrailingQuiet,
                outroPad: outroPad,
                holdGateDB: gates.hold
            )
        }

        return Decision(
            introSkip: intro,
            effectiveEnd: end,
            noiseFloorDB: gates.floor,
            openGateDB: gates.open,
            holdGateDB: gates.hold
        )
    }

    // MARK: Gates

    struct Gates {
        var floor: Float
        var open: Float
        var hold: Float
        var peak: Float
    }

    /// Robust noise floor + dual thresholds in dB.
    static func computeGates(levelsDB: [Float], midPeakDB: Float?) -> Gates {
        guard !levelsDB.isEmpty else {
            return Gates(floor: -60, open: -38, hold: -46, peak: -20)
        }
        let sorted = levelsDB.sorted()
        let n = sorted.count
        // Low percentiles ≈ ambient / room tone; ignore absolute digital silence.
        let p10 = sorted[min(n - 1, max(0, Int(Double(n) * 0.10)))]
        let p20 = sorted[min(n - 1, max(0, Int(Double(n) * 0.20)))]
        let p50 = sorted[min(n - 1, max(0, Int(Double(n) * 0.50)))]
        let p90 = sorted[min(n - 1, max(0, Int(Double(n) * 0.90)))]
        let localPeak = sorted[n - 1]
        let peak = max(localPeak, midPeakDB ?? localPeak)

        // Floor: blend quiet percentiles; never above median.
        var floor = max(p10, p20 - 2)
        floor = min(floor, p50 - 1)
        // Absolute floors: -90 dBFS min useful, -25 dBFS max "noise" (avoid crushing soft material).
        floor = min(max(floor, -90), -25)

        // Open gate: clear step above noise, but also relative to peak so soft songs work.
        // Typical: noise + 10–14 dB, or peak − 28 dB (whichever is higher / more open).
        let fromFloor = floor + 12
        let fromPeak = peak - 28
        let fromP90 = p90 - 8
        var open = max(fromFloor, min(fromPeak, fromP90))
        // Keep open between sensible bounds.
        open = min(max(open, floor + 6), peak - 6)
        open = min(max(open, -55), -12)

        // Hold gate (hysteresis): once open, stay in music a bit lower so soft passages count.
        var hold = open - 8
        hold = max(hold, floor + 3)
        hold = min(hold, open - 3)

        return Gates(floor: floor, open: open, hold: hold, peak: peak)
    }

    // MARK: Flux + VAD mask

    /// Positive first difference of dB levels (onset / activity energy).
    static func energyFlux(_ levelsDB: [Float]) -> [Float] {
        guard levelsDB.count > 1 else { return Array(repeating: 0, count: levelsDB.count) }
        var flux = [Float](repeating: 0, count: levelsDB.count)
        for i in 1 ..< levelsDB.count {
            let d = levelsDB[i] - levelsDB[i - 1]
            flux[i] = max(0, d)
        }
        // 3-tap smooth
        if flux.count >= 3 {
            var smooth = flux
            for i in 1 ..< (flux.count - 1) {
                smooth[i] = (flux[i - 1] + flux[i] * 2 + flux[i + 1]) * 0.25
            }
            return smooth
        }
        return flux
    }

    /// Hysteresis VAD: open above high gate (or strong flux into mid gate), hold above low gate.
    static func voiceActivityMask(
        levelsDB: [Float],
        flux: [Float],
        openGateDB: Float,
        holdGateDB: Float
    ) -> [Bool] {
        let n = levelsDB.count
        guard n > 0 else { return [] }
        var mask = [Bool](repeating: false, count: n)
        var active = false
        // Flux open assist: sudden +6 dB jump into the hold band often starts music.
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
                let strong = level >= openGateDB
                let attack = level >= holdGateDB && f >= fluxOpen
                if strong || attack {
                    active = true
                    mask[i] = true
                }
            }
        }
        return mask
    }

    // MARK: Intro / outro

    static func findIntroSkip(
        times: [TimeInterval],
        openMask: [Bool],
        levelsDB: [Float],
        windowSec: TimeInterval,
        minMusicHold: TimeInterval
    ) -> TimeInterval {
        let n = min(times.count, openMask.count)
        guard n > 0 else { return 0 }

        var run: TimeInterval = 0
        var runStartIdx = 0

        for i in 0 ..< n {
            if openMask[i] {
                if run <= 0 { runStartIdx = i }
                run += windowSec
                if run >= minMusicHold {
                    // Nudge slightly before the sustained open so attacks aren't clipped.
                    let t = times[runStartIdx]
                    let pad = min(windowSec * 0.6, 0.12)
                    return max(0, t - pad)
                }
            } else {
                // Allow one-window dropouts inside a forming run (live mic blips).
                if run > 0, run < minMusicHold, i + 1 < n, openMask[i + 1] {
                    run += windowSec * 0.5
                    continue
                }
                run = 0
            }
        }
        return 0
    }

    static func findEffectiveEnd(
        times: [TimeInterval],
        openMask: [Bool],
        levelsDB: [Float],
        windowSec: TimeInterval,
        fileDuration: TimeInterval,
        regionStartTime: TimeInterval,
        minMusicHold: TimeInterval,
        minTrailingQuiet: TimeInterval,
        outroPad: TimeInterval,
        holdGateDB: Float
    ) -> TimeInterval {
        let n = min(times.count, openMask.count)
        guard n > 0 else { return fileDuration }

        // Find last sustained music run (length >= minMusicHold), not single spikes.
        var lastMusicEnd: TimeInterval?
        var run: TimeInterval = 0
        var runEnd: TimeInterval = regionStartTime

        for i in 0 ..< n {
            let tEnd = times[i] + windowSec * 0.5
            if openMask[i] || levelsDB[i] >= holdGateDB {
                run += windowSec
                runEnd = tEnd
                if run >= minMusicHold {
                    lastMusicEnd = runEnd
                }
            } else {
                run = 0
            }
        }

        guard let musicEnd = lastMusicEnd else { return fileDuration }

        var effectiveEnd = min(fileDuration, musicEnd + outroPad)

        // Trailing quiet confirmation: energy must stay below hold for long enough,
        // or we keep the true file end (soft fade / live reverb still going).
        let trailing = fileDuration - effectiveEnd
        if trailing < minTrailingQuiet {
            return fileDuration
        }

        // Verify the last portion is actually quiet (not continuous soft music we missed).
        var quietRun: TimeInterval = 0
        var sawQuiet = false
        for i in 0 ..< n {
            let t = times[i]
            guard t >= musicEnd else { continue }
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
        if !sawQuiet {
            // Still trim if there's a large trailing span after last music (dead air).
            if trailing < minTrailingQuiet * 1.5 {
                return fileDuration
            }
        }

        // Sanity: never remove more than the scanned tail window implies.
        if fileDuration - effectiveEnd > 90 {
            effectiveEnd = fileDuration - 90
        }
        return max(effectiveEnd, regionStartTime + 1)
    }
}
