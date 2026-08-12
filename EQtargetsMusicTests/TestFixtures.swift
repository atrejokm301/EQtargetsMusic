//
//  TestFixtures.swift
//  EQtargetsMusicTests
//
//  Shared builders + reference measurement helpers.
//
//  The measurement helpers here are deliberately re-derived from first
//  principles rather than shared with the app: a suite that validates code
//  against that code's own helper cannot catch a bug in the helper.
//

import Foundation
import XCTest
@testable import EQtargetsMusic

enum Fixtures {

    // MARK: - Library builders

    /// Deterministic library with three tempo clusters (adoración / mid / júbilo).
    static func library(
        _ n: Int,
        missingAlbumFraction: Double = 0,
        artists: Int? = nil,
        seed: UInt64 = 42
    ) -> [Track] {
        var rng = SplitMix64(seed: seed)
        func rnd(_ lo: Double, _ hi: Double) -> Double { Double.random(in: lo ... hi, using: &rng) }
        let artistCount = artists ?? max(4, n / 12)
        return (0 ..< n).map { i in
            let hasAlbum = Double.random(in: 0 ... 1, using: &rng) >= missingAlbumFraction
            let bucket = i % 3
            let bpm = bucket == 0 ? rnd(60, 88) : bucket == 1 ? rnd(95, 115) : rnd(125, 160)
            return Track(
                title: "Track \(i)",
                artist: "Artist \(i % artistCount)",
                album: hasAlbum ? "Album \(i % max(2, n / 30))" : "",
                duration: rnd(120, 420),
                bpm: bpm
            )
        }
    }

    // MARK: - Reference DSP (independent of the app's implementation)

    /// RBJ biquad magnitude, written from the cookbook rather than reusing EQBiquad.
    struct RefBiquad {
        var b0 = 1.0, b1 = 0.0, b2 = 0.0, a0 = 1.0, a1 = 0.0, a2 = 0.0
        enum Kind { case peak, lowShelf, highShelf, highPass }

        init(_ kind: Kind, frequency: Double, gainDB: Double, q: Double, sampleRate: Double = 48_000) {
            let A = pow(10, gainDB / 40)
            let w0 = 2 * .pi * frequency / sampleRate
            let c = cos(w0), s = sin(w0)
            let alpha = s / (2 * max(q, 0.05))
            switch kind {
            case .peak:
                b0 = 1 + alpha * A; b1 = -2 * c; b2 = 1 - alpha * A
                a0 = 1 + alpha / A; a1 = -2 * c; a2 = 1 - alpha / A
            case .lowShelf:
                let t = 2 * sqrt(A) * alpha
                b0 = A * ((A + 1) - (A - 1) * c + t)
                b1 = 2 * A * ((A - 1) - (A + 1) * c)
                b2 = A * ((A + 1) - (A - 1) * c - t)
                a0 = (A + 1) + (A - 1) * c + t
                a1 = -2 * ((A - 1) + (A + 1) * c)
                a2 = (A + 1) + (A - 1) * c - t
            case .highShelf:
                let t = 2 * sqrt(A) * alpha
                b0 = A * ((A + 1) + (A - 1) * c + t)
                b1 = -2 * A * ((A - 1) + (A + 1) * c)
                b2 = A * ((A + 1) + (A - 1) * c - t)
                a0 = (A + 1) - (A - 1) * c + t
                a1 = 2 * ((A - 1) - (A + 1) * c)
                a2 = (A + 1) - (A - 1) * c - t
            case .highPass:
                b0 = (1 + c) / 2; b1 = -(1 + c); b2 = (1 + c) / 2
                a0 = 1 + alpha;   a1 = -2 * c;   a2 = 1 - alpha
            }
        }

        func magnitudeDB(at f: Double, sampleRate: Double = 48_000) -> Double {
            let w = 2 * Double.pi * f / sampleRate
            let cw = cos(w), c2w = cos(2 * w), sw = sin(w), s2w = sin(2 * w)
            let nRe = b0 + b1 * cw + b2 * c2w, nIm = -(b1 * sw + b2 * s2w)
            let dRe = a0 + a1 * cw + a2 * c2w, dIm = -(a1 * sw + a2 * s2w)
            let n2 = nRe * nRe + nIm * nIm, d2 = dRe * dRe + dIm * dIm
            guard d2 > 1e-30, n2 > 0 else { return 0 }
            return 10 * log10(n2 / d2)
        }
    }

    /// ITU-R BS.1770 K-weighting, re-derived from the spec.
    static func kWeightDB(_ f: Double, sampleRate: Double = 48_000) -> Double {
        let shelf = RefBiquad(.highShelf, frequency: 1_681.97, gainDB: 3.999, q: 0.7071, sampleRate: sampleRate)
        let hp = RefBiquad(.highPass, frequency: 38.13, gainDB: 0, q: 0.5003, sampleRate: sampleRate)
        return shelf.magnitudeDB(at: f, sampleRate: sampleRate) + hp.magnitudeDB(at: f, sampleRate: sampleRate)
    }

    /// AVAudioUnitEQ bandwidth (octaves) → RBJ Q. Inverse of EQBand.bandwidthOctaves.
    static func qFromBandwidth(_ bw: Float) -> Double {
        1.0 / (2.0 * sinh(Double(max(bw, 0.01)) * log(2.0) / 2.0))
    }

    // MARK: - Timing

    /// Best of N — a microbenchmark on a shared machine measures contention,
    /// not regressions. The minimum is the least-disturbed sample.
    static func bestOf(_ n: Int, _ body: () -> Void) -> TimeInterval {
        var best = TimeInterval.infinity
        for _ in 0 ..< n {
            let t0 = Date()
            body()
            best = min(best, Date().timeIntervalSince(t0))
        }
        return best
    }
}
