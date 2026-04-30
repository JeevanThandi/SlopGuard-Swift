import Foundation

/// Line-delimited JSON-RPC over stdin/stdout — the MCP stdio transport.
/// Each message is a single JSON object terminated by `\n`.
public final class StdioTransport: Sendable {

    private let input: FileHandle
    private let output: FileHandle
    private let writeLock: WriteLock

    public init(
        input: FileHandle = .standardInput,
        output: FileHandle = .standardOutput
    ) {
        self.input = input
        self.output = output
        self.writeLock = WriteLock(handle: output)
    }

    /// Write one JSON-RPC message followed by a newline. Serialized through an
    /// actor so concurrent responses don't interleave.
    public func send(_ message: Data) async {
        await writeLock.write(message)
    }

    /// Yield decoded request lines until EOF on stdin. Each line is delivered
    /// in receive order; dispatch concurrency is the caller's choice.
    public func receive() -> AsyncThrowingStream<Data, Error> {
        let handle = self.input
        return AsyncThrowingStream { continuation in
            let task = Task.detached {
                var buffer = Data()
                while !Task.isCancelled {
                    let chunk: Data
                    do {
                        chunk = try handle.read(upToCount: 65_536) ?? Data()
                    } catch {
                        continuation.finish(throwing: error)
                        return
                    }
                    if chunk.isEmpty {
                        let leftover = Self.takeRemainder(&buffer)
                        if let leftover { continuation.yield(leftover) }
                        continuation.finish()
                        return
                    }
                    buffer.append(chunk)
                    while let line = Self.takeLine(&buffer) {
                        continuation.yield(line)
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func takeLine(_ buffer: inout Data) -> Data? {
        guard let nl = buffer.firstIndex(of: 0x0A) else { return nil }
        let lineData = buffer.subdata(in: buffer.startIndex..<nl)
        buffer.removeSubrange(buffer.startIndex...nl)
        // Strip trailing \r if the client used CRLF framing.
        if lineData.last == 0x0D {
            return lineData.dropLast()
        }
        return lineData.isEmpty ? nil : lineData
    }

    private static func takeRemainder(_ buffer: inout Data) -> Data? {
        guard !buffer.isEmpty else { return nil }
        let line = buffer
        buffer.removeAll(keepingCapacity: false)
        return line
    }
}

/// Serializes writes from concurrent tasks. Stdout is shared mutable state;
/// concurrent `write(contentsOf:)` calls on a `FileHandle` would interleave.
private actor WriteLock {
    private let handle: FileHandle

    init(handle: FileHandle) {
        self.handle = handle
    }

    func write(_ data: Data) {
        var payload = data
        if payload.last != 0x0A { payload.append(0x0A) }
        do {
            try handle.write(contentsOf: payload)
        } catch {
            // stdio gone — nothing useful to log to since stderr could be too
        }
    }
}
