import Foundation

final class RealtimeDebugWAVWriter {
    private let url: URL
    private var handle: FileHandle?
    private var dataBytes: UInt32 = 0

    init(url: URL) {
        self.url = url
    }

    func open() throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        try handle.write(contentsOf: placeholderHeader())
        self.handle = handle
        dataBytes = 0
    }

    func append(pcm16: [Int16]) {
        guard let handle, !pcm16.isEmpty else { return }
        var little = pcm16.map { $0.littleEndian }
        little.withUnsafeBytes { raw in
            handle.write(Data(raw))
        }
        dataBytes += UInt32(pcm16.count * 2)
    }

    func close() throws {
        guard let handle else { return }
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: header(dataBytes: dataBytes))
        try handle.close()
        self.handle = nil
    }

    private func placeholderHeader() -> Data {
        header(dataBytes: 0)
    }

    private func header(dataBytes: UInt32) -> Data {
        var data = Data(capacity: 44)
        func appendASCII(_ text: String) { data.append(contentsOf: text.utf8) }
        func append16(_ value: UInt16) {
            var v = value.littleEndian
            withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
        }
        func append32(_ value: UInt32) {
            var v = value.littleEndian
            withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
        }
        appendASCII("RIFF")
        append32(36 + dataBytes)
        appendASCII("WAVE")
        appendASCII("fmt ")
        append32(16)
        append16(1)
        append16(1)
        append32(24_000)
        append32(24_000 * 2)
        append16(2)
        append16(16)
        appendASCII("data")
        append32(dataBytes)
        return data
    }
}
