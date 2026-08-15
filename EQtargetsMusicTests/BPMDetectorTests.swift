//
//  BPMDetectorTests.swift
//  EQtargetsMusicTests
//
//  Synthetic ground truth for the tempo detector. Each test writes a WAV whose
//  BPM is known by construction, so these catch octave regressions in both
//  directions — the two failure modes this library has actually shipped:
//    • v5 doubled slow ballads into the Júbilo lane;
//    • v6 halved dense júbilo (measured: a real 152 BPM song filed at 79).
//  Real-recording behaviour is covered separately by the labelled harness runs
//  (12 library songs, tap-verified octave) — synthetic beats can't stand in
//  for a live merengue mix, but they pin the contract.
//

import XCTest
import AVFoundation
@testable import EQtargetsMusic

final class BPMDetectorTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bpm-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
        try super.tearDownWithError()
    }

    // MARK: - Synthesis

    private let sampleRate = 8_000.0

    /// A decaying low sine — kick / tambora.
    private func lowHit(into samples: inout [Float], at index: Int, amp: Float, hz: Double = 70) {
        let len = Int(0.08 * sampleRate)
        for i in 0 ..< len where index + i < samples.count {
            let t = Double(i) / sampleRate
            let envAmp = amp * Float(exp(-t * 40))
            samples[index + i] += envAmp * Float(sin(2 * .pi * hz * t))
        }
    }

    /// A short noise burst — hat / palmas (broadband, lands in the high bands).
    private func noiseHit(into samples: inout [Float], at index: Int, amp: Float, seed: inout UInt64) {
        let len = Int(0.015 * sampleRate)
        for i in 0 ..< len where index + i < samples.count {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let r = Float(Int64(bitPattern: seed >> 11)) / Float(Int64.max)
            samples[index + i] += amp * r * Float(exp(-Double(i) / (0.004 * sampleRate)))
        }
    }

    /// A quiet sustained tone so the file isn't gated as silence.
    private func pad(into samples: inout [Float], hz: Double, amp: Float) {
        for i in 0 ..< samples.count {
            let t = Double(i) / sampleRate
            samples[i] += amp * Float(sin(2 * .pi * hz * t))
        }
    }

    private func writeWAV(_ samples: [Float], name: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false
        )!
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buf.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            buf.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }
        try file.write(from: buf)
        return url
    }

    private func assertBPM(_ got: Double?, near truth: Double, tolerance: Double = 0.04,
                           _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let got else {
            XCTFail("no estimate — \(message)", file: file, line: line)
            return
        }
        XCTAssertLessThanOrEqual(
            abs(got - truth) / truth, tolerance,
            "\(message): got \(got), expected ~\(truth)", file: file, line: line
        )
    }

    // MARK: - Tests

    /// Straight four-on-the-floor: every beat a kick, offbeat hats. The
    /// bread-and-butter case — no octave decision needed.
    func test_fourOnFloor140() throws {
        let bpm = 140.0
        let seconds = 20.0
        var samples = [Float](repeating: 0, count: Int(seconds * sampleRate))
        pad(into: &samples, hz: 300, amp: 0.03)
        var seed: UInt64 = 7
        let beat = 60.0 / bpm * sampleRate
        var b = 0.0
        while Int(b) < samples.count {
            lowHit(into: &samples, at: Int(b), amp: 0.8)
            noiseHit(into: &samples, at: Int(b + beat / 2), amp: 0.25, seed: &seed)
            b += beat
        }
        let url = try writeWAV(samples, name: "four140.wav")
        assertBPM(BPMDetector.estimateBPM(fileURL: url), near: 140, "four-on-floor")
    }

    /// Sparse ballad: a low thump per beat and nothing between. The v5 bug
    /// doubled exactly this into the Júbilo lane — it must stay slow.
    func test_sparseBalladStaysAt76() throws {
        let bpm = 76.0
        let seconds = 20.0
        var samples = [Float](repeating: 0, count: Int(seconds * sampleRate))
        pad(into: &samples, hz: 250, amp: 0.04)
        let beat = 60.0 / bpm * sampleRate
        var b = 0.0
        while Int(b) < samples.count {
            lowHit(into: &samples, at: Int(b), amp: 0.7)
            b += beat
        }
        let url = try writeWAV(samples, name: "ballad76.wav")
        assertBPM(BPMDetector.estimateBPM(fileURL: url), near: 76, "sparse ballad must not double")
    }

    /// Merengue-style accent cycle: a low hit on *every* beat of the fast grid,
    /// alternating strong/weak, so the envelope's dominant period is the
    /// two-beat cycle at 76 — but the felt tempo is 152. The v6 bug filed
    /// exactly this at 79.
    func test_accentCycleFeltAt152() throws {
        let bpm = 152.0
        let seconds = 20.0
        var samples = [Float](repeating: 0, count: Int(seconds * sampleRate))
        pad(into: &samples, hz: 300, amp: 0.03)
        var seed: UInt64 = 11
        let beat = 60.0 / bpm * sampleRate
        var b = 0.0
        var strong = true
        while Int(b) < samples.count {
            lowHit(into: &samples, at: Int(b), amp: strong ? 0.8 : 0.45)
            noiseHit(into: &samples, at: Int(b), amp: 0.2, seed: &seed)
            strong.toggle()
            b += beat
        }
        let url = try writeWAV(samples, name: "accent152.wav")
        assertBPM(BPMDetector.estimateBPM(fileURL: url), near: 152, "accent cycle must resolve to felt tempo")
    }

    /// Near-silence must return nil, not a confident hallucination.
    /// (A raw LCG is NOT usable as the noise source here — its lattice
    /// structure is genuinely periodic and the detector rightly finds it.)
    func test_noiseFloorReturnsNil() throws {
        var rng = SplitMix64(seed: 3)
        var samples = [Float](repeating: 0, count: Int(16 * sampleRate))
        for i in 0 ..< samples.count {
            samples[i] = Float.random(in: -1 ... 1, using: &rng) * 0.0005
        }
        let url = try writeWAV(samples, name: "noise.wav")
        XCTAssertNil(BPMDetector.estimateBPM(fileURL: url), "noise floor must not produce a BPM")
    }
}
