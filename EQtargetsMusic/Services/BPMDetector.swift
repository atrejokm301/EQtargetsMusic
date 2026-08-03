//
//  BPMDetector.swift
//  EQtargetsMusic
//
//  Offline tempo estimate from audio (never on the playback render path).
//  v2 — multi-window spectral-flux onsets + lag reinforcement + confidence gate.
//
//  Pipeline:
//  1. Decode mono PCM (chunked convert, ~11 kHz)
//  2. Skip leading silence / soft intro
//  3. Analyze 2–3 windows of music
//  4. Spectral-flux onset envelope
//  5. Autocorrelation + harmonic lag reinforcement + tempo prior
//  6. Confidence gate + half/double correction
//

import Foundation
import AVFoundation
import Accelerate
import os

private let bpmLog = Logger(subsystem: "com.eqtargets.music", category: "BPM")

enum BPMDetector {
    private static let targetSampleRate: Double = 11_025
    private static let maxReadSeconds: Double = 72
    private static let windowSeconds: Double = 14
    private static let hopSize = 128
    private static let fftSize = 512
    private static let bpmMin = 60.0
    private static let bpmMax = 190.0
    private static let minConfidence: Double = 0.12

    private struct Vote {
        var bpm: Double
        var confidence: Double
    }

    /// Estimated BPM or nil if analysis fails / low confidence / silence.
    /// Safe off the main actor — file I/O + pure compute only.
    nonisolated static func estimateBPM(fileURL: URL) -> Double? {
        let accessed = fileURL.startAccessingSecurityScopedResource()
        defer { if accessed { fileURL.stopAccessingSecurityScopedResource() } }

        guard let file = try? AVAudioFile(forReading: fileURL) else {
            bpmLog.debug("open failed: \(fileURL.lastPathComponent, privacy: .public)")
            return nil
        }
        let srcFormat = file.processingFormat
        guard srcFormat.sampleRate > 0, srcFormat.channelCount > 0, file.length > 0 else { return nil }

        let fileSeconds = Double(file.length) / srcFormat.sampleRate
        guard fileSeconds >= 4 else { return nil }

        guard let monoFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        ) else { return nil }

        let maxSrcFrames = AVAudioFrameCount(min(
            Double(file.length),
            srcFormat.sampleRate * maxReadSeconds
        ))
        guard maxSrcFrames > AVAudioFrameCount(srcFormat.sampleRate * 3) else { return nil }

        guard var samples = readMonoDownsampled(
            file: file,
            srcFormat: srcFormat,
            monoFormat: monoFormat,
            maxSrcFrames: maxSrcFrames
        ), samples.count > hopSize * 80 else {
            return nil
        }

        let musicStart = firstMusicSampleIndex(samples)
        if musicStart > 0, musicStart < samples.count - hopSize * 80 {
            samples = Array(samples.suffix(from: musicStart))
        }

        let windowSamples = Int(windowSeconds * targetSampleRate)
        guard samples.count > windowSamples / 2 else { return nil }

        var windows: [(offset: Int, length: Int)] = []
        windows.append((0, min(windowSamples, samples.count)))
        if samples.count > windowSamples + hopSize * 40 {
            let mid = min(samples.count - windowSamples, windowSamples * 2 / 3)
            if mid > hopSize * 20 {
                windows.append((mid, windowSamples))
            }
        }
        if samples.count > windowSamples * 2 {
            let late = min(samples.count - windowSamples, windowSamples + windowSamples / 2)
            if late > hopSize * 40 {
                windows.append((late, windowSamples))
            }
        }

        var votes: [Vote] = []
        votes.reserveCapacity(windows.count)
        for w in windows {
            let end = min(w.offset + w.length, samples.count)
            guard end - w.offset > hopSize * 60 else { continue }
            let slice = Array(samples[w.offset ..< end])
            if let vote = estimateWindow(samples: slice) {
                votes.append(vote)
            }
        }

        guard let best = combineVotes(votes) else {
            bpmLog.debug("no confident BPM: \(fileURL.lastPathComponent, privacy: .public)")
            return nil
        }

        let snapped = (best * 2).rounded() / 2
        bpmLog.info(
            "BPM \(snapped, format: .fixed(precision: 1)) ← \(fileURL.lastPathComponent, privacy: .public) votes=\(votes.count)"
        )
        return snapped
    }

    // MARK: - Decode

    nonisolated private static func readMonoDownsampled(
        file: AVAudioFile,
        srcFormat: AVAudioFormat,
        monoFormat: AVAudioFormat,
        maxSrcFrames: AVAudioFrameCount
    ) -> [Float]? {
        guard let converter = AVAudioConverter(from: srcFormat, to: monoFormat) else { return nil }

        let srcChunk = AVAudioFrameCount(min(srcFormat.sampleRate * 1.0, Double(maxSrcFrames)))
        var collected: [Float] = []
        let approxOut = Int(Double(maxSrcFrames) * monoFormat.sampleRate / max(srcFormat.sampleRate, 1)) + 1024
        collected.reserveCapacity(max(approxOut, 1024))

        var readPos: AVAudioFramePosition = 0
        let endPos = AVAudioFramePosition(maxSrcFrames)

        while readPos < endPos {
            let framesThis = min(AVAudioFrameCount(endPos - readPos), srcChunk)
            guard let srcBuffer = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: framesThis) else { break }
            do {
                file.framePosition = readPos
                try file.read(into: srcBuffer, frameCount: framesThis)
            } catch {
                break
            }
            if srcBuffer.frameLength == 0 { break }
            readPos += AVAudioFramePosition(srcBuffer.frameLength)

            let ratio = monoFormat.sampleRate / max(srcFormat.sampleRate, 1)
            let outCap = AVAudioFrameCount(Double(srcBuffer.frameLength) * ratio + 64)
            guard let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: max(outCap, 1)) else { continue }

            var error: NSError?
            var fed = false
            let status = converter.convert(to: mono, error: &error) { _, outStatus in
                if fed {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                fed = true
                outStatus.pointee = .haveData
                return srcBuffer
            }
            if status == .error || mono.frameLength == 0 { continue }
            guard let ch = mono.floatChannelData?[0] else { continue }
            let n = Int(mono.frameLength)
            collected.append(contentsOf: UnsafeBufferPointer(start: ch, count: n))
        }

        return collected.isEmpty ? nil : collected
    }

    nonisolated private static func firstMusicSampleIndex(_ samples: [Float]) -> Int {
        let win = hopSize * 8
        guard samples.count > win * 4 else { return 0 }

        var peak: Float = 1e-6
        var i = 0
        samples.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            while i + win <= samples.count {
                var rms: Float = 0
                vDSP_rmsqv(base.advanced(by: i), 1, &rms, vDSP_Length(win))
                peak = max(peak, rms)
                i += win * 2
            }
        }
        let gate = max(peak * 0.08, 0.002)

        var run = 0
        var foundAt = 0
        var found = false
        i = 0
        let need = 3
        let limit = min(samples.count, Int(targetSampleRate * 48))
        samples.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            while i + win <= limit {
                var rms: Float = 0
                vDSP_rmsqv(base.advanced(by: i), 1, &rms, vDSP_Length(win))
                if rms >= gate {
                    run += 1
                    if run >= need {
                        foundAt = i
                        found = true
                        return
                    }
                } else {
                    run = 0
                }
                i += win
            }
        }
        guard found else { return 0 }
        return max(0, foundAt - win * need)
    }

    // MARK: - One window

    nonisolated private static func estimateWindow(samples: [Float]) -> Vote? {
        let env = spectralFluxEnvelope(samples: samples)
        guard env.count > 80 else { return nil }

        var hp = env
        if hp.count > 2 {
            var prev = hp[0]
            for i in 1 ..< hp.count {
                let x = hp[i]
                hp[i] = max(0, x - prev * 0.97)
                prev = x
            }
        }
        if hp.count > 3 {
            for k in 1 ..< hp.count - 1 {
                hp[k] = (hp[k - 1] + hp[k] * 2 + hp[k + 1]) * 0.25
            }
        }

        var mean: Float = 0
        vDSP_meanv(hp, 1, &mean, vDSP_Length(hp.count))
        var centered = [Float](repeating: 0, count: hp.count)
        var neg = -mean
        vDSP_vsadd(hp, 1, &neg, &centered, 1, vDSP_Length(hp.count))

        var energy: Float = 0
        vDSP_svesq(centered, 1, &energy, vDSP_Length(centered.count))
        guard energy > 1e-8 else { return nil }

        let hopSeconds = Double(hopSize) / targetSampleRate
        let n = centered.count
        let minLag = max(2, Int((60.0 / bpmMax) / hopSeconds))
        let maxLag = min(n / 3, Int((60.0 / bpmMin) / hopSeconds))
        guard maxLag > minLag + 4 else { return nil }

        var scores = [Float](repeating: 0, count: maxLag + 1)
        centered.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            var zeroLag: Float = 0
            vDSP_dotpr(base, 1, base, 1, &zeroLag, vDSP_Length(n))
            zeroLag = max(zeroLag, 1e-9)

            for lag in minLag...maxLag {
                var corr: Float = 0
                let len = n - lag
                vDSP_dotpr(base, 1, base.advanced(by: lag), 1, &corr, vDSP_Length(len))
                corr = (corr / Float(len)) / (zeroLag / Float(n))
                scores[lag] = max(0, corr)
            }
        }

        var reinforced = scores
        for lag in minLag...maxLag {
            var s = scores[lag]
            let l2 = lag * 2
            let l3 = lag * 3
            if l2 <= maxLag { s += scores[l2] * 0.55 }
            if l3 <= maxLag { s += scores[l3] * 0.30 }
            if lag % 2 == 0 {
                let half = lag / 2
                if half >= minLag { s += scores[half] * 0.25 }
            }
            reinforced[lag] = s
        }

        var bestLag = minLag
        var bestScore: Float = -1
        var secondScore: Float = -1
        for lag in minLag...maxLag {
            let bpm = 60.0 / (Double(lag) * hopSeconds)
            let s = reinforced[lag] * Float(tempoPrior(bpm: bpm))
            if s > bestScore {
                secondScore = bestScore
                bestScore = s
                bestLag = lag
            } else if s > secondScore {
                secondScore = s
            }
        }
        guard bestScore > 0.02 else { return nil }

        var bpm = 60.0 / (Double(bestLag) * hopSeconds)
        bpm = clampToRange(bpm)

        let clarity = Double(bestScore / max(bestScore + secondScore, 1e-6))
        let strength = min(1.0, Double(bestScore) / 0.35)
        let confidence = 0.55 * clarity + 0.45 * strength
        guard confidence >= minConfidence else { return nil }
        guard bpm.isFinite, bpm >= bpmMin, bpm <= bpmMax else { return nil }
        return Vote(bpm: bpm, confidence: confidence)
    }

    nonisolated private static func tempoPrior(bpm: Double) -> Double {
        let center = 112.0
        let sigma = 38.0
        let g = exp(-0.5 * pow((bpm - center) / sigma, 2))
        return 0.55 + 0.45 * g
    }

    nonisolated private static func clampToRange(_ bpm: Double) -> Double {
        var b = bpm
        while b < bpmMin { b *= 2 }
        while b > bpmMax { b /= 2 }
        if b < 80, b * 2 <= bpmMax { b *= 2 }
        if b > 165, b / 2 >= bpmMin { b /= 2 }
        return b
    }

    // MARK: - Spectral flux

    nonisolated private static func spectralFluxEnvelope(samples: [Float]) -> [Float] {
        let n = samples.count
        let hop = hopSize
        let fftN = fftSize
        guard n > fftN + hop else {
            return energyFluxEnvelope(samples: samples, hop: hop)
        }

        guard let fftSetup = vDSP_create_fftsetup(
            vDSP_Length(log2(Double(fftN))),
            FFTRadix(kFFTRadix2)
        ) else {
            return energyFluxEnvelope(samples: samples, hop: hop)
        }
        defer { vDSP_destroy_fftsetup(fftSetup) }

        var window = [Float](repeating: 0, count: fftN)
        vDSP_hann_window(&window, vDSP_Length(fftN), Int32(vDSP_HANN_NORM))

        var prevMag = [Float](repeating: 0, count: fftN / 2)
        var env: [Float] = []
        env.reserveCapacity(max(n / hop, 1))

        var realp = [Float](repeating: 0, count: fftN / 2)
        var imagp = [Float](repeating: 0, count: fftN / 2)
        var i = 0

        while i + fftN <= n {
            var frame = Array(samples[i ..< i + fftN])
            vDSP_vmul(frame, 1, window, 1, &frame, 1, vDSP_Length(fftN))

            realp.withUnsafeMutableBufferPointer { rBuf in
                imagp.withUnsafeMutableBufferPointer { iBuf in
                    var split = DSPSplitComplex(realp: rBuf.baseAddress!, imagp: iBuf.baseAddress!)
                    frame.withUnsafeBufferPointer { fBuf in
                        fBuf.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: fftN / 2) { complexPtr in
                            vDSP_ctoz(complexPtr, 2, &split, 1, vDSP_Length(fftN / 2))
                        }
                    }
                    vDSP_fft_zrip(
                        fftSetup,
                        &split,
                        1,
                        vDSP_Length(log2(Double(fftN))),
                        FFTDirection(FFT_FORWARD)
                    )

                    var mag = [Float](repeating: 0, count: fftN / 2)
                    vDSP_zvabs(&split, 1, &mag, 1, vDSP_Length(fftN / 2))

                    var flux: Float = 0
                    for b in 1 ..< mag.count {
                        let d = mag[b] - prevMag[b]
                        if d > 0 { flux += d }
                    }
                    prevMag = mag
                    env.append(flux)
                }
            }
            i += hop
        }
        return env
    }

    nonisolated private static func energyFluxEnvelope(samples: [Float], hop: Int) -> [Float] {
        let count = samples.count
        guard count > hop else { return [] }
        var env: [Float] = []
        env.reserveCapacity(count / hop)
        var prev: Float = 0
        var i = 0
        samples.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            while i + hop <= count {
                var sum: Float = 0
                vDSP_svesq(base.advanced(by: i), 1, &sum, vDSP_Length(hop))
                let e = sqrtf(sum / Float(hop))
                env.append(max(0, e - prev))
                prev = e
                i += hop
            }
        }
        return env
    }

    // MARK: - Votes

    nonisolated private static func combineVotes(_ votes: [Vote]) -> Double? {
        guard !votes.isEmpty else { return nil }
        if votes.count == 1 {
            return votes[0].confidence >= minConfidence * 0.9 ? clampToRange(votes[0].bpm) : nil
        }

        struct Cluster {
            var bpmSum: Double = 0
            var confSum: Double = 0
            var weightSum: Double = 0
            var count: Int = 0
            var mean: Double { weightSum > 0 ? bpmSum / weightSum : 0 }
        }
        var clusters: [Cluster] = []

        for v in votes.sorted(by: { $0.confidence > $1.confidence }) {
            var placed = false
            for i in clusters.indices {
                if tempoDistance(clusters[i].mean, v.bpm) <= 6 {
                    clusters[i].bpmSum += v.bpm * v.confidence
                    clusters[i].confSum += v.confidence
                    clusters[i].weightSum += v.confidence
                    clusters[i].count += 1
                    placed = true
                    break
                }
            }
            if !placed {
                clusters.append(Cluster(
                    bpmSum: v.bpm * v.confidence,
                    confSum: v.confidence,
                    weightSum: v.confidence,
                    count: 1
                ))
            }
        }

        guard let best = clusters.max(by: { $0.confSum < $1.confSum }) else { return nil }
        let ok = best.count >= 2 || best.confSum >= minConfidence * 1.35
        if ok {
            return clampToRange(best.mean)
        }
        if let top = votes.max(by: { $0.confidence < $1.confidence }),
           top.confidence >= minConfidence * 1.2 {
            return clampToRange(top.bpm)
        }
        return nil
    }

    nonisolated private static func tempoDistance(_ a: Double, _ b: Double) -> Double {
        [abs(a - b), abs(a * 2 - b), abs(a - b * 2), abs(a / 2 - b), abs(a - b / 2)].min() ?? abs(a - b)
    }
}
