//
//  SilenceAnalyzer.swift
//  EQtargetsMusic
//
//  Skip-silence v2 — playable window detection for live alabanzas / long
//  intros / trailing applause.
//
//  Fast path: intro-only, coarse windows (main-thread safe, tens of ms).
//  Full path: intro + outro with adaptive noise floor (background + cache).
//
//  Improvements vs v1:
//  - Adaptive gate from noise floor + peak (not peak-only %)
//  - Longer sustain required so single claps don't count as “music”
//  - Intro cap instead of “zero the skip if too long” (that killed live intros)
//  - Outro requires real trailing quiet before trimming soft fades
//  - Safer minimum playable body so we never crush short tracks
//

import Foundation
import AVFoundation
import Accelerate
import os

private let silenceLog = Logger(subsystem: "com.eqtargets.music", category: "Silence")

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

enum SilenceAnalyzer {
    /// How far into the file we look for music start (live intros can be long).
    static let maxIntroScan: TimeInterval = 72
    /// How much tail we search for trailing silence / applause.
    static let maxOutroScan: TimeInterval = 120
    /// Keep a little tail after last loud window so endings don't clip.
    static let outroPad: TimeInterval = 0.55
    /// Music must stay loud this long to count as start (filters claps).
    static let minMusicHold: TimeInterval = 0.55
    /// Trailing quiet must last this long before we trim the end.
    static let minTrailingQuiet: TimeInterval = 1.6
    /// Never skip more than this fraction of the file as intro.
    static let maxIntroFraction: Double = 0.42
    /// Absolute intro cap.
    static let maxIntroAbsolute: TimeInterval = 64
    /// Never leave less playable body than this (unless the file is shorter).
    static let minPlayableBody: TimeInterval = 12

    // MARK: - Fast path (main-thread safe)

    /// Intro-only, coarse windows. Outro left as full file end until refined.
    static func analyzeFast(_ file: AVAudioFile) -> SilenceTrim {
        let meta = fileMeta(file)
        guard meta.duration > 3.0 else { return .full(duration: meta.duration) }

        let windowSec: TimeInterval = 0.12
        let windowFrames = max(AVAudioFrameCount(meta.sr * windowSec), 1024)
        let introLimit = min(
            AVAudioFramePosition(min(14, maxIntroScan) * meta.sr),
            meta.totalFrames
        )

        let series = sampleRMSSeries(
            file: file,
            from: 0,
            to: introLimit,
            windowFrames: windowFrames,
            channels: meta.channels,
            strideWindows: 1
        )
        guard !series.isEmpty else { return .full(duration: meta.duration) }

        let gate = adaptiveGate(levels: series.map(\.rms))
        var intro = findIntroSkip(
            series: series,
            gate: gate,
            windowSec: windowSec,
            hold: minMusicHold * 0.85,
            fileDuration: meta.duration
        )
        intro = clampIntro(intro, duration: meta.duration)

        silenceLog.debug(
            "fast intro=\(intro, format: .fixed(precision: 2))s gate=\(gate, format: .fixed(precision: 5)) dur=\(meta.duration, format: .fixed(precision: 1))s"
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

        let windowSec: TimeInterval = 0.06
        let windowFrames = max(AVAudioFrameCount(meta.sr * windowSec), 512)

        let introLimit = min(AVAudioFramePosition(maxIntroScan * meta.sr), meta.totalFrames)
        let outroSpan = min(AVAudioFramePosition(maxOutroScan * meta.sr), meta.totalFrames)
        let outroStart = max(meta.totalFrames - outroSpan, 0)

        // Combined series for adaptive gate (intro + tail only — not whole file).
        var introSeries = sampleRMSSeries(
            file: file,
            from: 0,
            to: introLimit,
            windowFrames: windowFrames,
            channels: meta.channels,
            strideWindows: 1
        )
        let outroSeries = sampleRMSSeries(
            file: file,
            from: outroStart,
            to: meta.totalFrames,
            windowFrames: windowFrames,
            channels: meta.channels,
            strideWindows: 1
        )

        let allLevels = introSeries.map(\.rms) + outroSeries.map(\.rms)
        guard !allLevels.isEmpty else { return .full(duration: meta.duration) }
        let gate = adaptiveGate(levels: allLevels)

        var intro = findIntroSkip(
            series: introSeries,
            gate: gate,
            windowSec: windowSec,
            hold: minMusicHold,
            fileDuration: meta.duration
        )
        intro = clampIntro(intro, duration: meta.duration)

        var end = findEffectiveEnd(
            series: outroSeries,
            gate: gate,
            windowSec: windowSec,
            fileDuration: meta.duration,
            regionStartTime: Double(outroStart) / meta.sr
        )

        // Safety: never crush the playable body.
        let minBody = min(minPlayableBody, meta.duration * 0.45)
        if end - intro < minBody {
            // Prefer keeping the end; pull intro back if needed.
            if meta.duration - intro < minBody {
                intro = 0
                end = meta.duration
            } else {
                end = min(meta.duration, intro + max(minBody, meta.duration * 0.5))
            }
            silenceLog.debug("full: body guard → intro=\(intro, format: .fixed(precision: 2)) end=\(end, format: .fixed(precision: 2))")
        }

        end = max(intro + 1.0, min(end, meta.duration))

        silenceLog.info(
            "full intro=\(intro, format: .fixed(precision: 2))s end=\(end, format: .fixed(precision: 2))s gate=\(gate, format: .fixed(precision: 5)) trimmedTail=\(meta.duration - end, format: .fixed(precision: 2))s"
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
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        return analyze(file)
    }

    // MARK: - Core detection

    private struct RMSPoint {
        var time: TimeInterval
        var rms: Float
    }

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

    /// Adaptive gate: blend noise floor (low percentile) with peak.
    private static func adaptiveGate(levels: [Float]) -> Float {
        guard !levels.isEmpty else { return 0.002 }
        let sorted = levels.sorted()
        let n = sorted.count
        let p15 = sorted[min(n - 1, max(0, Int(Double(n) * 0.15)))]
        let p50 = sorted[min(n - 1, max(0, Int(Double(n) * 0.50)))]
        let peak = sorted[n - 1]
        // Noise floor estimate; ignore pure zeros.
        let floor = max(p15, peak * 0.01, 1e-5)
        // Gate sits between floor and mid energy so soft music still counts,
        // but room tone / distant chatter usually does not.
        let gate = max(
            floor * 3.2,
            p50 * 0.55,
            peak * 0.035,
            0.0006
        )
        // Never set gate above 25% of peak or we miss quiet songs.
        return min(gate, max(peak * 0.25, 0.001))
    }

    private static func findIntroSkip(
        series: [RMSPoint],
        gate: Float,
        windowSec: TimeInterval,
        hold: TimeInterval,
        fileDuration: TimeInterval
    ) -> TimeInterval {
        guard !series.isEmpty else { return 0 }
        var loudRun: TimeInterval = 0
        var runStart: TimeInterval = 0

        for p in series {
            if p.rms >= gate {
                if loudRun <= 0 { runStart = p.time }
                loudRun += windowSec
                if loudRun >= hold {
                    // Nudge slightly before the sustain so attacks aren't clipped.
                    let skip = max(0, runStart - windowSec * 0.35)
                    return skip
                }
            } else {
                loudRun = 0
            }
        }
        return 0
    }

    private static func clampIntro(_ intro: TimeInterval, duration: TimeInterval) -> TimeInterval {
        var s = intro
        // Tiny skips aren't worth the discontinuity.
        if s < 0.40 { return 0 }
        let fracCap = duration * maxIntroFraction
        let absCap = min(maxIntroAbsolute, max(0, duration - minPlayableBody))
        s = min(s, fracCap, absCap)
        if s < 0.40 { return 0 }
        return s
    }

    /// Walk the tail: last sustained loud time, only trim if real trailing quiet exists.
    private static func findEffectiveEnd(
        series: [RMSPoint],
        gate: Float,
        windowSec: TimeInterval,
        fileDuration: TimeInterval,
        regionStartTime: TimeInterval
    ) -> TimeInterval {
        guard !series.isEmpty else { return fileDuration }

        // Last time energy was clearly "music".
        var lastLoud = regionStartTime
        var sawLoud = false
        for p in series {
            if p.rms >= gate {
                lastLoud = p.time + windowSec * 0.5
                sawLoud = true
            }
        }
        guard sawLoud else { return fileDuration }

        var effectiveEnd = min(fileDuration, lastLoud + outroPad)

        // How much trailing quiet is there after last loud?
        let trailing = fileDuration - effectiveEnd
        // Don't trim tiny tails (natural reverb / soft endings).
        if trailing < minTrailingQuiet {
            return fileDuration
        }
        // Don't trim almost nothing meaningful.
        if trailing < 1.0 {
            return fileDuration
        }
        // Sanity: never remove more than maxOutroScan.
        if fileDuration - effectiveEnd > maxOutroScan {
            effectiveEnd = fileDuration - maxOutroScan
        }
        return max(effectiveEnd, regionStartTime + 1)
    }

    // MARK: - RMS sampling

    private static func sampleRMSSeries(
        file: AVAudioFile,
        from start: AVAudioFramePosition,
        to end: AVAudioFramePosition,
        windowFrames: AVAudioFrameCount,
        channels: Int,
        strideWindows: Int
    ) -> [RMSPoint] {
        let sr = max(file.processingFormat.sampleRate, 1)
        let step = AVAudioFramePosition(windowFrames) * AVAudioFramePosition(max(strideWindows, 1))
        var points: [RMSPoint] = []
        points.reserveCapacity(max(1, Int((end - start) / max(step, 1)) + 2))

        var pos = max(start, 0)
        let limit = min(end, file.length)
        while pos < limit {
            if let rms = readRMS(file: file, at: pos, frames: windowFrames, channels: channels) {
                points.append(RMSPoint(time: Double(pos) / sr, rms: rms))
            }
            pos += step
        }
        return points
    }

    private static func readRMS(
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
        let chCount = min(channels, Int(file.processingFormat.channelCount))
        var sum: Float = 0
        var samples: Float = 0
        // Stride-2 for speed; plenty for silence detection.
        for c in 0 ..< chCount {
            let ptr = ch[c]
            var i = 0
            while i < count {
                let s = ptr[i]
                sum += s * s
                samples += 1
                i += 2
            }
        }
        guard samples > 0 else { return nil }
        return sqrt(sum / samples)
    }
}
