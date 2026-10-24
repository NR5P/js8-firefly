import Foundation

/// Drives the C++ reference harness (tools/refharness) built from the original
/// JS8Call sources. Tests are skipped when the harness has not been built.
final class RefHarness {
    static let path: String = {
        let here = URL(fileURLWithPath: #filePath)
        return here.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("tools/refharness/build/js8ref").path
    }()

    static var isAvailable: Bool { FileManager.default.isExecutableFile(atPath: path) }

    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private var buffer = Data()

    init() throws {
        process.executableURL = URL(fileURLWithPath: Self.path)
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    deinit {
        try? input.fileHandleForWriting.close()
        process.terminate()
    }

    func readLine() -> String {
        while true {
            if let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<nl]
                buffer = Data(buffer[(nl + 1)...])
                return String(decoding: line, as: UTF8.self)
            }
            let chunk = output.fileHandleForReading.availableData
            if chunk.isEmpty { return "" }
            buffer.append(chunk)
        }
    }

    func send(_ fields: [String]) {
        let line = fields.joined(separator: "\t") + "\n"
        input.fileHandleForWriting.write(line.data(using: .utf8)!)
    }

    func call(_ fields: [String]) -> String {
        send(fields)
        return readLine()
    }

    func callUntilEnd(_ fields: [String]) -> [String] {
        send(fields)
        var lines: [String] = []
        while true {
            let l = readLine()
            if l == "END" || l.isEmpty { break }
            lines.append(l)
        }
        return lines
    }
}
