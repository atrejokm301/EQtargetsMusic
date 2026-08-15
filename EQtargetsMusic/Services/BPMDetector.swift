//
//  BPMDetector.swift
//  EQtargetsMusic
//
//  Offline tempo estimate from audio (never on the playback render path).
//  v3 — band-split onsets + fine lag grid. Two measured failures drove this
//  (see the harness in scratchpad/bpm, run against real library files):
//    • Dense praise mixes: full-band RMS flux cannot see the kick through a
//      wall of guitars/vocals/crowd — corr at the true period measured 0.000
//      on a real 152 BPM song, so it was filed at 79. Band-split flux (kick
//      band + percussive high band, plain biquads — still no per-hop FFT, so
//      the thermal reason v2.1 dropped spectral flux does not apply).
//    • 20 ms hops: a ~146 BPM song has a true lag of 20.5 hops — correlation
//      collapses at both integer neighbours while the doubled lag 41 is exact,
//      so quantisation *causes* halving rather than merely losing precision.
//      10 ms hops put fast tempi on the grid; parabolic interpolation refines.
//
//  Pipeline:
//  1. Decode mono PCM (chunked convert, ~8 kHz)
//  2. Skip leading silence / soft intro
//  3. Analyze 1–2 windows of music
//  4. Band-split energy-flux onset envelope (low + high + full band)
//  5. Autocorrelation + harmonic lag reinforcement + tempo prior
//  6. Confidence gate + octave correction + sub-lag interpolation
//

import Foundation
@preconcurrency import AVFoundation
import Accelerate
import os

private let bpmLog = Logger(subsystem: "com.eqtargets.music", category: "BPM")

enum BPMDetector {
    /// Lower SR = less RAM/CPU on bulk library analysis.
    private static let targetSampleRate: Double = 8_000
    private static let maxReadSeconds: Double = 36
    private static let windowSeconds: Double = 10
    /// 10 ms — at 20 ms a ~146 BPM lag of 20.5 hops fell between integers and
    /// its double won by default. Autocorr stage is still microseconds.
    private static let hopSize = 80
    private static let bpmMin = 60.0
    private static let bpmMax = 190.0
    private static let minConfidence: Double = 0.12
    /// Low-band offbeat/beat energy ratio above which a sub-95 reading is the
    /// accent cycle of a double-felt groove. Set from the labelled harness run
    /// — see the ground-truth table in the session notes before retuning.
    private static let feltDoubleThreshold = 0.40

    private struct Vote {
        var bpm: Double
        var confidence: Double
    }

    #if BPM_HARNESS
    /// Ground-truth harness only — the Xcode project never defines BPM_HARNESS,
    /// so none of this exists in the app. One line per analyzed window with the
    /// internals the octave decision saw.
    nonisolated(unsafe) static var trace: (@Sendable (String) -> Void)?
    #endif

    /// Estimated BPM or nil if analysis fails / low confidence / silence.
    /// Safe off the main actor — file I/O + pure compute only.
    nonisolated static func estimateBPM(fileURL: URL) -> Double? {
        // Don't startAccess on Documents/Music copies (sandbox_extension 22 spam).
        let accessed = SecurityScopedAccess.startIfNeeded(fileURL)
        defer { SecurityScopedAccess.stopIfNeeded(fileURL, didStart: accessed) }

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

        // One envelope pass over the whole read, then up to four windows tiled
        // across it as envelope slices. The old "first window, second only if
        // weak" rule let a percussion-free live intro decide the whole song —
        // and a flat surface scored deceptively *confident* (clarity ≈ 0.5
        // when everything is equally bad).
        let (flux, lowFlux) = onsetEnvelope(samples: samples, hop: hopSize)
        guard flux.count > 100 else { return nil }

        let hopSeconds = Double(hopSize) / targetSampleRate
        let windowHops = Int(windowSeconds / hopSeconds)
        let strideHops = max(windowHops / 2, (flux.count - windowHops) / 3)
        var windowRanges: [Range<Int>] = []
        var start = 0
        for _ in 0 ..< 4 {
            let end = min(start + windowHops, flux.count)
            if end - start > 50 { windowRanges.append(start ..< end) }
            if end == flux.count { break }
            start += strideHops
        }

        var votes: [Vote] = []
        for r in windowRanges {
            if let v = estimateWindow(flux: Array(flux[r])) {
                votes.append(v)
            }
        }

        guard var merged = combineVotes(votes) else {
            bpmLog.debug("no confident BPM: \(fileURL.lastPathComponent, privacy: .public)")
            return nil
        }

        // Felt-octave decision — once per song, over every window.
        //
        // A merengue/cumbia júbilo's energy envelope is honestly periodic at
        // the *two-beat tambora cycle* — half the danced tempo — so the
        // autocorrelation correctly reads ~76 for a song the congregation
        // claps at 152 (tap-verified on real library files). What separates it
        // from a genuinely slow song is **low-band** onset energy between the
        // accent beats: tambora/bass hit every danced beat, an anthem's
        // eighth-note hats live in the high bands, and a 6/8 adoración
        // subdivides in thirds, not halves. Deciding per window let one quiet
        // breakdown flip the octave vote; averaging the measured support
        // across windows decides it once.
        if merged < 95, merged * 2 <= bpmMax {
            let canonLag = Int((60.0 / (merged * hopSeconds)).rounded())
            var supports: [Double] = []
            for r in windowRanges {
                if let s = lowOffbeatSupport(lowFlux: Array(lowFlux[r]), lag: canonLag) {
                    supports.append(s)
                }
            }
            if !supports.isEmpty {
                let meanSupport = supports.reduce(0, +) / Double(supports.count)
                #if BPM_HARNESS
                Self.trace?(String(
                    format: "feltOctave merged=%.1f lag=%d lowOff=[%@] mean=%.2f%@",
                    merged, canonLag,
                    supports.map { String(format: "%.2f", $0) }.joined(separator: " "),
                    meanSupport, meanSupport >= feltDoubleThreshold ? " ⇒×2" : ""
                ))
                #endif
                if meanSupport >= feltDoubleThreshold {
                    merged *= 2
                }
            }
        }

        let snapped = (merged * 2).rounded() / 2
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

    /// One window over a pre-computed onset-flux slice.
    nonisolated private static func estimateWindow(flux: [Float]) -> Vote? {
        guard flux.count > 80 else { return nil }

        var hp = flux
        if hp.count > 2 {
            // 0.985 per 10 ms hop ≈ the 0.97-per-20 ms decay this was tuned at.
            var prev = hp[0]
            for i in 1 ..< hp.count {
                let x = hp[i]
                hp[i] = max(0, x - prev * 0.985)
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
        // ceil — truncation put the shortest lag slightly above bpmMax, and
        // clampToRange would then fold that reading down an octave.
        let minLag = max(2, Int(((60.0 / bpmMax) / hopSeconds).rounded(.up)))
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

        // ── Octave decided from the envelope, not from the prior ──────────────
        //
        // Autocorrelation peaks at every multiple of the true beat period, so
        // the peak alone cannot tell 68 from 136 from 34. The evidence that can
        // is whether the beats at a given period are *equally strong*:
        //
        //   • alternating strong/weak → this period is too fast, the real beat
        //     is twice as long (a half-time ballad read at double speed);
        //   • all equal, and the half period is also all equal with real
        //     correlation support → this period is a multiple of the true one.
        //
        // Walking both directions matters. An earlier version only slowed down,
        // which fixed doubled ballads but let a straight 168 BPM praise song be
        // chosen at 84 and filed as Adoración.
        var correctedLag = bestLag
        while correctedLag * 2 <= maxLag, beatsAlternate(envelope: centered, lag: correctedLag) {
            correctedLag *= 2
        }
        // Half of an odd lag is fractional: a 146 BPM song peaking at lag 81
        // has its true fast lag at 41, but 81/2 truncates to 40 — misaligned,
        // so the old check measured garbage and never sped up. Test both
        // integer neighbours and walk to the better-supported one.
        while true {
            let hFloor = correctedLag / 2
            let hCeil = (correctedLag + 1) / 2
            var half = hFloor
            if hCeil != hFloor, hCeil <= maxLag, scores[hCeil] > scores[hFloor] {
                half = hCeil
            }
            guard half >= minLag,
                  !beatsAlternate(envelope: centered, lag: half),
                  scores[half] >= scores[correctedLag] * 0.8 else { break }
            correctedLag = half
        }

        // Sub-lag precision: even at 10 ms hops the grid near 150 BPM is ~4 BPM
        // wide, so a parabola through the three autocorrelation points around
        // the chosen lag recovers the fractional period.
        var lagF = Double(correctedLag)
        if correctedLag > minLag, correctedLag < maxLag {
            let y0 = Double(scores[correctedLag - 1])
            let y1 = Double(scores[correctedLag])
            let y2 = Double(scores[correctedLag + 1])
            let denom = y0 - 2 * y1 + y2
            if denom < -1e-12 {                       // genuine local maximum
                let delta = 0.5 * (y0 - y2) / denom
                if abs(delta) <= 0.6 { lagF += delta }
            }
        }

        #if BPM_HARNESS
        if let trace = Self.trace {
            func cell(_ lag: Int) -> String {
                guard lag >= minLag, lag <= maxLag else { return "\(lag):-" }
                let fill = beatFillRatio(envelope: centered, lag: lag)
                    .map { String(format: "%.2f", $0) } ?? "-"
                return String(format: "%d:%.2f/%@", lag, scores[lag], fill)
            }
            var rawBest = minLag
            for lag in minLag...maxLag where scores[lag] > scores[rawBest] { rawBest = lag }
            let bpmAt = { (lag: Int) in 60.0 / (Double(lag) * hopSeconds) }
            trace(String(
                format: "peak %d (%.1f bpm)  lag:corr/fill  half[%@ %@]  peak[%@]  dbl[%@]  rawBest[%@ %.1f bpm]  → %d (%.1f bpm)",
                bestLag, bpmAt(bestLag),
                cell(bestLag / 2), cell((bestLag + 1) / 2),
                cell(bestLag), cell(bestLag * 2),
                cell(rawBest), bpmAt(rawBest),
                correctedLag, bpmAt(correctedLag)
            ))
        }
        #endif

        var bpm = 60.0 / (lagF * hopSeconds)
        bpm = clampToRange(bpm)

        // Confidence must go to zero on a flat surface. The old additive blend
        // (0.55·clarity + 0.45·strength) scored garbage at ~0.35, because a
        // surface where everything is equally bad has clarity ≈ 0.5 — a real
        // 152 BPM song with corr 0.06 everywhere sailed through the gate at 79.
        // Multiplying instead means no raw correlation support ⇒ no vote, and
        // the raw autocorrelation at the chosen lag is the evidence, not the
        // reinforced+prior score that manufactured the peak.
        let rawCorr = Double(max(
            scores[max(minLag, correctedLag - 1)],
            max(scores[correctedLag], scores[min(maxLag, correctedLag + 1)])
        ))
        // Absolute evidence floor: across the labelled library runs, real music
        // measured 0.16–0.57 here while flat/noise surfaces measured 0.04–0.11.
        guard rawCorr >= 0.13 else { return nil }
        let clarity = Double(bestScore / max(bestScore + secondScore, 1e-6))
        let strength = min(1.0, rawCorr / 0.30)
        let confidence = clarity * strength
        guard confidence >= minConfidence else { return nil }
        guard bpm.isFinite, bpm >= bpmMin, bpm <= bpmMax else { return nil }
        return Vote(bpm: bpm, confidence: confidence)
    }

    /// Tempo prior — **bimodal**, because a worship library is.
    ///
    /// This used to be a single Gaussian centred on 112 BPM, which sits in the
    /// valley *between* the two things this library actually contains: adoración
    /// around 60–85 and júbilo around 120–145. A centre in the gap gives the
    /// doubled reading of a slow song more prior weight than the truth — for a
    /// 68 BPM ballad the old curve scored 136 at 0.92 against 68 at 0.78, so the
    /// prior actively argued for the wrong answer. Combined with the clamp below
    /// it converted the whole 60–80 band into 120–160, i.e. into Júbilo.
    ///
    /// Two lobes, one per real mode, so neither interpretation is favoured
    /// merely for being nearer the middle.
    /// The fast lobe is deliberately wide: a narrow one measured *worse* than the
    /// old prior at the top of the band, scoring genuine 168 BPM praise below its
    /// own half at 84 and folding it into Adoración — the reported bug mirrored.
    /// The octave walk decides the octave now; the prior only breaks ties.
    nonisolated private static func tempoPrior(bpm: Double) -> Double {
        let slow = exp(-0.5 * pow((bpm - 72.0) / 22.0, 2))
        let fast = exp(-0.5 * pow((bpm - 136.0) / 34.0, 2))
        return 0.70 + 0.30 * max(slow, fast)
    }

    /// Fold only what is genuinely outside the detectable band.
    ///
    /// The old version additionally did `if b < 80 { b *= 2 }`, which doubled
    /// every tempo in 60–80 into 120–160 — the Júbilo lane — regardless of the
    /// evidence. `bpmMin` already guards the truly-too-slow case, so that rule
    /// only ever moved correct answers. The high-side rule is kept but pushed
    /// out to 180 so fast praise at 165–180 is not halved into Adoración, which
    /// is the same bug mirrored.
    nonisolated private static func clampToRange(_ bpm: Double) -> Double {
        var b = bpm
        while b < bpmMin { b *= 2 }
        while b > bpmMax { b /= 2 }
        if b > 180, b / 2 >= bpmMin { b /= 2 }
        return b
    }

    /// Decide the tempo octave from the signal instead of from a prior.
    ///
    /// At double time every second beat lands where there is no real onset, so a
    /// ballad read at 136 shows a strong / weak / strong / weak pattern while a
    /// genuine 136 song fills every beat. Measuring that ratio answers "is this
    /// really twice the tempo?" from evidence — which is exactly the question a
    /// prior can only guess at.
    ///
    /// - Returns: true when the beats alternate, meaning the real period is
    ///   twice `lag` and the BPM should be halved.
    nonisolated private static func beatsAlternate(envelope: [Float], lag: Int) -> Bool {
        guard let ratio = beatFillRatio(envelope: envelope, lag: lag) else { return false }
        // 0.62 sits below the spread a straight-eights groove produces and well
        // above the near-silence of an off-beat in a half-time ballad.
        return ratio < 0.62
    }

    /// How uniformly the beat slots at `lag` carry onset energy: the mean of the
    /// weaker alternating group over the stronger one. 1 = every beat equally
    /// real; near 0 = every second slot is empty, i.e. this lag reads the music
    /// an octave too fast. Nil when the window is too short to measure.
    nonisolated static func beatFillRatio(envelope: [Float], lag: Int) -> Double? {
        // Need a few bars of both interpretations to compare.
        guard lag >= 2, envelope.count >= lag * 8 else { return nil }

        // Phase-align: pick the offset whose beat positions carry most energy.
        var bestPhase = 0
        var bestSum: Double = -1
        for phase in 0 ..< lag {
            var sum: Double = 0
            var i = phase
            while i < envelope.count {
                sum += Double(envelope[i])
                i += lag
            }
            if sum > bestSum {
                bestSum = sum
                bestPhase = phase
            }
        }

        // Split the aligned beats into alternating groups.
        var evenSum: Double = 0, oddSum: Double = 0
        var evenCount = 0, oddCount = 0
        var k = 0
        var i = bestPhase
        while i < envelope.count {
            let v = Double(max(0, envelope[i]))
            if k % 2 == 0 { evenSum += v; evenCount += 1 } else { oddSum += v; oddCount += 1 }
            k += 1
            i += lag
        }
        guard evenCount > 2, oddCount > 2 else { return nil }

        let strong = max(evenSum / Double(evenCount), oddSum / Double(oddCount))
        let weak = min(evenSum / Double(evenCount), oddSum / Double(oddCount))
        guard strong > 0 else { return nil }

        return weak / strong
    }

    // MARK: - Onset envelope (banded log-flux)

    /// 2nd-order RBJ bandpass (constant 0 dB peak gain), plain scalar loop —
    /// a few hundred µs on an 80k-sample window, nothing near the decode cost.
    nonisolated private static func bandpassFiltered(
        _ x: [Float], centerHz: Double, q: Double, sampleRate: Double
    ) -> [Float] {
        let w0 = 2.0 * Double.pi * centerHz / sampleRate
        let cw = cos(w0), sw = sin(w0)
        let alpha = sw / (2.0 * q)
        let a0 = 1 + alpha
        let b0 = alpha / a0
        let b2 = -alpha / a0
        let a1 = (-2 * cw) / a0
        let a2 = (1 - alpha) / a0

        var y = [Float](repeating: 0, count: x.count)
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
        for i in 0 ..< x.count {
            let xn = Double(x[i])
            let yn = b0 * xn + b2 * x2 - a1 * y1 - a2 * y2
            y[i] = Float(yn)
            x2 = x1; x1 = xn
            y2 = y1; y1 = yn
        }
        return y
    }

    /// Per-hop RMS level (not flux) of a signal.
    nonisolated private static func hopRMS(samples: [Float], hop: Int) -> [Float] {
        let count = samples.count
        guard count > hop else { return [] }
        var env: [Float] = []
        env.reserveCapacity(count / hop)
        var i = 0
        samples.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            while i + hop <= count {
                var sum: Float = 0
                vDSP_svesq(base.advanced(by: i), 1, &sum, vDSP_Length(hop))
                env.append(sqrtf(sum / Float(hop)))
                i += hop
            }
        }
        return env
    }

    /// Onset envelope that can see the beat through a dense mix.
    ///
    /// Full-band RMS flux fails on wall-of-sound praise recordings: sustained
    /// guitars/vocals/crowd/güira hold the broadband level nearly constant, so
    /// kick and tambora hits barely move it — measured corr 0.000 at the true
    /// period of a real 152 BPM song, i.e. the pulse never reached the
    /// envelope. Standard robust cure, minus the per-hop FFT that v2.1 dropped
    /// for thermals: six octave bands (biquads), per-hop RMS, **log**
    /// compression so a small hit against a loud wall still registers as
    /// relative change, then half-wave-rectified flux summed across bands.
    /// The reference level is the window's own broadband RMS, so the measure
    /// is level-invariant and a near-silent band's noise floor stays tiny
    /// instead of being normalised up into fake onsets.
    /// `combined` drives the tempo autocorrelation. `low` (60–240 Hz only —
    /// kick/tambora/bass) feeds the felt-octave decision: a merengue's offbeat
    /// tambora hits live down here, an anthem's eighth-note hats do not.
    nonisolated private static func onsetEnvelope(
        samples: [Float], hop: Int
    ) -> (combined: [Float], low: [Float]) {
        let full = hopRMS(samples: samples, hop: hop)
        guard full.count > 4 else { return ([], []) }
        var ref: Float = 0
        vDSP_meanv(full, 1, &ref, vDSP_Length(full.count))
        guard ref > 1e-7 else { return ([], []) } // digital silence

        // Octave bands 60–3840 Hz: kick/tambora at the bottom, snare mid,
        // palmas/hats/güira transients at the top. Q = fc / bandwidth ≈ √2.
        let edges: [(Double, Double)] = [
            (60, 120), (120, 240), (240, 480), (480, 960), (960, 1_920), (1_920, 3_840),
        ]
        let inv = 1.0 / (0.05 * ref)
        var flux = [Float](repeating: 0, count: full.count)
        var lowFlux = [Float](repeating: 0, count: full.count)
        for (bandIndex, edge) in edges.enumerated() {
            let (lo, hi) = edge
            let fc = (lo * hi).squareRoot()
            let band = bandpassFiltered(samples, centerHz: fc, q: fc / (hi - lo), sampleRate: targetSampleRate)
            let rms = hopRMS(samples: band, hop: hop)
            guard rms.count > 1 else { continue }
            var prev = log1pf(rms[0] * inv)
            for i in 1 ..< min(rms.count, flux.count) {
                let le = log1pf(rms[i] * inv)
                let d = max(0, le - prev)
                flux[i] += d
                if bandIndex < 2 { lowFlux[i] += d }
                prev = le
            }
        }
        return (flux, lowFlux)
    }

    /// How much low-band onset energy sits **between** the beats of `lag`,
    /// relative to the beats themselves. Beats are phase-aligned first;
    /// offbeat positions are rounded per beat so odd lags don't drift.
    nonisolated private static func lowOffbeatSupport(lowFlux: [Float], lag: Int) -> Double? {
        guard lag >= 4, lowFlux.count >= lag * 8 else { return nil }

        var bestPhase = 0
        var bestSum: Double = -1
        for phase in 0 ..< lag {
            var sum: Double = 0
            var i = phase
            while i < lowFlux.count {
                sum += Double(max(0, lowFlux[i]))
                i += lag
            }
            if sum > bestSum {
                bestSum = sum
                bestPhase = phase
            }
        }

        var beatSum = 0.0, offSum = 0.0
        var beats = 0, offs = 0
        var i = bestPhase
        while i < lowFlux.count {
            beatSum += Double(max(0, lowFlux[i]))
            beats += 1
            let off = i + lag / 2
            if off < lowFlux.count {
                offSum += Double(max(0, lowFlux[off]))
                offs += 1
            }
            i += lag
        }
        guard beats > 4, offs > 4, beatSum > 0 else { return nil }
        return (offSum / Double(offs)) / (beatSum / Double(beats))
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
                    // Fold the vote into the cluster's octave before averaging:
                    // a 76 and a 152 vote agree on the pulse, but their raw
                    // mean (~110) is a tempo neither window heard. The first
                    // (highest-confidence) vote sets the octave.
                    let m = clusters[i].mean
                    let folded = [v.bpm, v.bpm * 2, v.bpm / 2]
                        .min { abs($0 - m) < abs($1 - m) } ?? v.bpm
                    clusters[i].bpmSum += folded * v.confidence
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
