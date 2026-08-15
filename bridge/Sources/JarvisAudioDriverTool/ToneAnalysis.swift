import Foundation

/// Deterministic-signal analysis for CHECKPOINT 4/5/6 loopback tests (PRD §14 — "RMS moved" alone
/// is not an acceptable PASS criterion). All metrics are computed on captured samples for a
/// single channel extracted from the interleaved stream.
enum ToneAnalysis {
    struct Result: CustomStringConvertible {
        let expectedFrequencyHz: Double
        let measuredFrequencyHz: Double
        let goertzelMagnitude: Double
        let correlation: Double
        let rms: Double
        let peak: Double
        let frameCount: Int

        var description: String {
            String(
                format: "expectedHz=%.1f measuredHz=%.1f goertzelMag=%.4f correlation=%.3f rms=%.4f peak=%.4f frames=%d",
                expectedFrequencyHz, measuredFrequencyHz, goertzelMagnitude, correlation, rms, peak, frameCount
            )
        }
    }

    /// Extracts a single channel from interleaved samples.
    static func extractChannel(_ interleaved: [Float], channel: Int, channelCount: Int) -> [Float] {
        guard channelCount > 0 else { return [] }
        var out = [Float]()
        out.reserveCapacity(interleaved.count / channelCount)
        var i = channel
        while i < interleaved.count {
            out.append(interleaved[i])
            i += channelCount
        }
        return out
    }

    static func rms(_ samples: [Float]) -> Double {
        guard !samples.isEmpty else { return 0 }
        let sumSquares = samples.reduce(0.0) { $0 + Double($1) * Double($1) }
        return sqrt(sumSquares / Double(samples.count))
    }

    static func peak(_ samples: [Float]) -> Double {
        samples.map { Double(abs($0)) }.max() ?? 0
    }

    /// Goertzel algorithm — measures the magnitude of a single target frequency bin without a
    /// full FFT. Good fit here since the expected frequency is known in advance (we generated the
    /// tone ourselves).
    static func goertzelMagnitude(_ samples: [Float], targetHz: Double, sampleRate: Double) -> Double {
        guard samples.count > 1 else { return 0 }
        let n = samples.count
        let k = Double(n) * targetHz / sampleRate
        let omega = 2 * Double.pi * k / Double(n)
        let coeff = 2 * cos(omega)
        var s0 = 0.0, s1 = 0.0, s2 = 0.0
        for sample in samples {
            s0 = Double(sample) + coeff * s1 - s2
            s2 = s1
            s1 = s0
        }
        let real = s1 - s2 * cos(omega)
        let imag = s2 * sin(omega)
        return sqrt(real * real + imag * imag) / Double(n)
    }

    /// Coarse dominant-frequency estimate via zero-crossing rate. Good enough to distinguish
    /// e.g. 440Hz from 880Hz for a channel/device isolation sanity check, not a precision tool.
    static func zeroCrossingFrequency(_ samples: [Float], sampleRate: Double) -> Double {
        guard samples.count > 1 else { return 0 }
        var crossings = 0
        for i in 1..<samples.count {
            if (samples[i - 1] < 0 && samples[i] >= 0) || (samples[i - 1] > 0 && samples[i] <= 0) {
                crossings += 1
            }
        }
        let durationSeconds = Double(samples.count) / sampleRate
        guard durationSeconds > 0 else { return 0 }
        return Double(crossings) / 2.0 / durationSeconds
    }

    /// Normalized cross-correlation between a captured signal and a freshly generated reference
    /// tone of the same frequency, searching a small lag window (±`maxLagSamples`) to absorb the
    /// loopback's small internal latency. Returns the best (highest-magnitude) correlation found,
    /// in [-1, 1] — close to 1 means "this really is that tone", not just "something non-silent".
    static func correlationWithReferenceTone(_ captured: [Float], frequencyHz: Double, sampleRate: Double, maxLagSamples: Int = 200) -> Double {
        guard captured.count > maxLagSamples * 2 else { return 0 }
        let reference = (0..<captured.count).map { Float(sin(2 * Double.pi * frequencyHz * Double($0) / sampleRate)) }

        var best = 0.0
        for lag in stride(from: -maxLagSamples, through: maxLagSamples, by: 5) {
            var sumProduct = 0.0, sumCapturedSq = 0.0, sumRefSq = 0.0
            let start = max(0, -lag)
            let end = min(captured.count, captured.count - lag)
            guard end > start else { continue }
            for i in start..<end {
                let c = Double(captured[i])
                let r = Double(reference[i + lag >= 0 && i + lag < reference.count ? i + lag : i])
                sumProduct += c * r
                sumCapturedSq += c * c
                sumRefSq += r * r
            }
            guard sumCapturedSq > 0, sumRefSq > 0 else { continue }
            let correlation = sumProduct / sqrt(sumCapturedSq * sumRefSq)
            if abs(correlation) > abs(best) { best = correlation }
        }
        return best
    }

    static func analyze(captured: [Float], channel: Int, channelCount: Int, expectedFrequencyHz: Double, sampleRate: Double) -> Result {
        let channelSamples = extractChannel(captured, channel: channel, channelCount: channelCount)
        return Result(
            expectedFrequencyHz: expectedFrequencyHz,
            measuredFrequencyHz: zeroCrossingFrequency(channelSamples, sampleRate: sampleRate),
            goertzelMagnitude: goertzelMagnitude(channelSamples, targetHz: expectedFrequencyHz, sampleRate: sampleRate),
            correlation: correlationWithReferenceTone(channelSamples, frequencyHz: expectedFrequencyHz, sampleRate: sampleRate),
            rms: rms(channelSamples),
            peak: peak(channelSamples),
            frameCount: channelSamples.count
        )
    }
}
