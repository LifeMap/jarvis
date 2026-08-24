enum RealtimeAudioConverter {
    static func toProviderRX(interleavedStereo48k: [Float]) -> [Int16] {
        guard interleavedStereo48k.count >= 2, interleavedStereo48k.count % 2 == 0 else { return [] }
        let mono48k: [Float] = stride(from: 0, to: interleavedStereo48k.count, by: 2).map { i in
            (interleavedStereo48k[i] + interleavedStereo48k[i + 1]) * 0.5
        }
        let mono24k = resampleLinear(mono48k, inRate: RealtimeAudioFormat.halSampleRate, outRate: RealtimeAudioFormat.sampleRate)
        return mono24k.map { sample in
            let clamped = max(-1, min(1, sample))
            return Int16((clamped * 32767.0).rounded())
        }
    }

    static func toHALTX(mono24kPCM16: [Int16]) -> [Float] {
        var converter = RealtimeHALTXConverter()
        var stereo = converter.convert(mono24kPCM16)
        stereo.append(contentsOf: converter.flush())
        return stereo
    }

    private static func resampleLinear(_ input: [Float], inRate: Double, outRate: Double) -> [Float] {
        guard !input.isEmpty else { return [] }
        if inRate == outRate { return input }
        let outCount = max(1, Int((Double(input.count) * outRate / inRate).rounded(.down)))
        var output = [Float](repeating: 0, count: outCount)
        let last = input.count - 1
        let ratio = inRate / outRate
        for i in 0..<outCount {
            let src = Double(i) * ratio
            let i0 = Int(src)
            let frac = Float(src - Double(i0))
            let s0 = input[min(i0, last)]
            let s1 = input[min(i0 + 1, last)]
            output[i] = s0 + (s1 - s0) * frac
        }
        return output
    }
}

struct RealtimeHALTXConverter {
    private var pending: Float?

    mutating func reset() {
        pending = nil
    }

    mutating func convert(_ mono24kPCM16: [Int16]) -> [Float] {
        var mono48k: [Float] = []
        mono48k.reserveCapacity(mono24kPCM16.count * 2)
        for sample in mono24kPCM16 {
            let current = Float(sample) / 32768.0
            if let previous = pending {
                mono48k.append(previous)
                mono48k.append((previous + current) * 0.5)
            }
            pending = current
        }
        return Self.stereo(mono48k)
    }

    mutating func flush() -> [Float] {
        guard let previous = pending else { return [] }
        pending = nil
        return Self.stereo([previous, previous])
    }

    private static func stereo(_ mono48k: [Float]) -> [Float] {
        var stereo = [Float](repeating: 0, count: mono48k.count * 2)
        for i in mono48k.indices {
            stereo[i * 2] = mono48k[i]
            stereo[i * 2 + 1] = mono48k[i]
        }
        return stereo
    }
}
