import Foundation

enum CallAudioMixer {
    static func appendTX(_ chunk: [Int16], onto existing: inout [Int16], timeline: Int) {
        if existing.count < timeline {
            existing.append(contentsOf: repeatElement(0, count: timeline - existing.count))
        }
        existing.append(contentsOf: chunk)
    }

    static func consumeTX(_ pending: inout [Int16], count: Int) -> [Int16] {
        guard count > 0 else { return [] }
        let take = min(pending.count, count)
        var out = Array(pending.prefix(take))
        if take > 0 {
            pending.removeFirst(take)
        }
        if out.count < count {
            out.append(contentsOf: repeatElement(0, count: count - out.count))
        }
        return out
    }

    static func mix(rx: [Int16], tx: [Int16]) -> [Int16] {
        let count = max(rx.count, tx.count)
        guard count > 0 else { return [] }
        var mixed = [Int16](repeating: 0, count: count)
        for index in 0..<count {
            let a = index < rx.count ? Int(rx[index]) : 0
            let b = index < tx.count ? Int(tx[index]) : 0
            mixed[index] = Int16(clamping: a + b)
        }
        return mixed
    }

    static func conversation(rx: [Int16], tx: [Int16], window: Int = 240, speechRMS: Float = 400) -> [Int16] {
        let count = max(rx.count, tx.count)
        guard count > 0, window > 0 else { return [] }
        var output: [Int16] = []
        var heldTX: [Int16] = []
        var offset = 0
        while offset < count {
            let end = min(offset + window, count)
            var rxSum: Float = 0
            var txSum: Float = 0
            var rxWindow: [Int16] = []
            var txWindow: [Int16] = []
            rxWindow.reserveCapacity(end - offset)
            txWindow.reserveCapacity(end - offset)
            for index in offset..<end {
                let rxSample = index < rx.count ? rx[index] : 0
                let txSample = index < tx.count ? tx[index] : 0
                rxWindow.append(rxSample)
                txWindow.append(txSample)
                rxSum += Float(rxSample) * Float(rxSample)
                txSum += Float(txSample) * Float(txSample)
            }
            let frames = Float(end - offset)
            let rxSpeech = sqrt(rxSum / frames) >= speechRMS
            let txSpeech = sqrt(txSum / frames) >= speechRMS
            if rxSpeech && txSpeech {
                output.append(contentsOf: rxWindow)
                heldTX.append(contentsOf: txWindow)
            } else if rxSpeech {
                output.append(contentsOf: rxWindow)
            } else {
                if !heldTX.isEmpty {
                    output.append(contentsOf: heldTX)
                    heldTX.removeAll(keepingCapacity: true)
                }
                if txSpeech {
                    output.append(contentsOf: txWindow)
                } else {
                    output.append(contentsOf: rxWindow)
                }
            }
            offset = end
        }
        if !heldTX.isEmpty {
            output.append(contentsOf: heldTX)
        }
        return output
    }

    static func interleave(rx: [Int16], tx: [Int16]) -> [Int16] {
        let count = max(rx.count, tx.count)
        guard count > 0 else { return [] }
        var stereo = [Int16](repeating: 0, count: count * 2)
        for index in 0..<count {
            stereo[index * 2] = index < rx.count ? rx[index] : 0
            stereo[index * 2 + 1] = index < tx.count ? tx[index] : 0
        }
        return stereo
    }
}

protocol CallAudioEncoding {
    func encodeM4A(pcm16: [Int16], channels: Int) throws -> Data
}

extension CallAudioEncoding {
    func encodeM4A(pcm16Mono24k: [Int16]) throws -> Data {
        try encodeM4A(pcm16: pcm16Mono24k, channels: 1)
    }
}

struct IdentityCallAudioEncoder: CallAudioEncoding {
    func encodeM4A(pcm16: [Int16], channels: Int) throws -> Data {
        let little = pcm16.map(\.littleEndian)
        return little.withUnsafeBytes { Data($0) }
    }
}
