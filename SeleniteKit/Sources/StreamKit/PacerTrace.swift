import Foundation
import MoonlightCore

/// What one pacer saw, recorded on device and replayed offline through every candidate rule
/// (`PacerTraceRecorder` writes it, `PacerTrace.decode` reads it back).
///
/// File layout, little-endian: the magic `SPT2` (the format version is its last character; the
/// reader takes only this one), a UInt32 byte count and that many bytes of JSON metadata, then one
/// record per event, each a tag byte and its payload, every time value the exact Float64 the pacer
/// got so a replay decides bit for bit as the device did:
/// - 1 put: arrival Float64 (seconds, the pacer's clock), frame number Int32 (-1 when unknown)
/// - 2 vsync: timestamp, duration and tick time, Float64 each
/// - 3 tick
/// - 4 presenter attached, 5 presenter detached
/// About 2.4 KB per second at 60 fps, so ten minutes stay near 1.5 MB. A file whose last record
/// was cut off (the app was killed mid-write) reads up to that record.
public struct PacerTrace: Equatable, Sendable {
    public struct Metadata: Codable, Equatable, Sendable {
        public var mode: String
        public var directPresent: Bool
        public var frameRate: Int
        public var slot: Int
        public var width: Int
        public var height: Int
        /// Local wall clock when recording began, ISO 8601.
        public var startedAt: String

        public init(mode: String, directPresent: Bool, frameRate: Int, slot: Int, width: Int, height: Int,
                    startedAt: String) {
            self.mode = mode; self.directPresent = directPresent; self.frameRate = frameRate; self.slot = slot
            self.width = width; self.height = height; self.startedAt = startedAt
        }
    }

    public enum Event: Equatable, Sendable {
        case put(arrival: Double, frameNumber: Int?)
        case vsync(timestamp: Double, duration: Double, tickTime: Double)
        case tick
        case presenter(attached: Bool)
    }

    public enum DecodeError: Error, Equatable {
        case notATrace
        /// A trace in another format version than this build reads.
        case unsupportedVersion(String)
        case truncated
        case unknownTag(UInt8)
    }

    public var metadata: Metadata
    public var events: [Event]
    /// The file ended inside a record; `events` holds everything before it.
    public var endsTruncated: Bool

    public init(metadata: Metadata, events: [Event], endsTruncated: Bool = false) {
        self.metadata = metadata
        self.events = events
        self.endsTruncated = endsTruncated
    }

    static let magic: [UInt8] = Array("SPT2".utf8)

    static func header(_ metadata: Metadata) -> Data {
        var data = Data(magic)
        let json = (try? JSONEncoder().encode(metadata)) ?? Data("{}".utf8)
        append(UInt32(json.count), to: &data)
        data.append(json)
        return data
    }

    static func append(_ event: Event, to data: inout Data) {
        switch event {
        case let .put(arrival, frameNumber):
            data.append(1)
            append(arrival.bitPattern, to: &data)
            append(UInt32(bitPattern: Int32(clamping: frameNumber ?? -1)), to: &data)
        case let .vsync(timestamp, duration, tickTime):
            data.append(2)
            append(timestamp.bitPattern, to: &data)
            append(duration.bitPattern, to: &data)
            append(tickTime.bitPattern, to: &data)
        case .tick:
            data.append(3)
        case let .presenter(attached):
            data.append(attached ? 4 : 5)
        }
    }

    private static func append<Value: FixedWidthInteger>(_ value: Value, to data: inout Data) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    public static func decode(_ data: Data) throws -> PacerTrace {
        var reader = Reader(bytes: [UInt8](data))
        let found = try reader.bytes(4)
        guard found.prefix(3) == magic.prefix(3) else { throw DecodeError.notATrace }
        guard found == magic else { throw DecodeError.unsupportedVersion(String(decoding: found, as: UTF8.self)) }
        let length = Int(try reader.integer(UInt32.self))
        let json = Data(try reader.bytes(length))
        guard let metadata = try? JSONDecoder().decode(Metadata.self, from: json) else { throw DecodeError.notATrace }
        var events: [Event] = []
        events.reserveCapacity(data.count / 12)
        do {
            while !reader.atEnd {
                let tag = try reader.integer(UInt8.self)
                switch tag {
                case 1:
                    let arrival = Double(bitPattern: try reader.integer(UInt64.self))
                    let number = Int32(bitPattern: try reader.integer(UInt32.self))
                    events.append(.put(arrival: arrival, frameNumber: number < 0 ? nil : Int(number)))
                case 2:
                    let timestamp = Double(bitPattern: try reader.integer(UInt64.self))
                    let duration = Double(bitPattern: try reader.integer(UInt64.self))
                    let tickTime = Double(bitPattern: try reader.integer(UInt64.self))
                    events.append(.vsync(timestamp: timestamp, duration: duration, tickTime: tickTime))
                case 3: events.append(.tick)
                case 4: events.append(.presenter(attached: true))
                case 5: events.append(.presenter(attached: false))
                default: throw DecodeError.unknownTag(tag)
                }
            }
        } catch DecodeError.truncated {
            return PacerTrace(metadata: metadata, events: events, endsTruncated: true)
        }
        return PacerTrace(metadata: metadata, events: events)
    }

    private struct Reader {
        let bytes: [UInt8]
        var offset = 0

        var atEnd: Bool { offset >= bytes.count }

        mutating func bytes(_ count: Int) throws -> [UInt8] {
            guard count >= 0, offset + count <= bytes.count else { throw DecodeError.truncated }
            defer { offset += count }
            return Array(bytes[offset..<offset + count])
        }

        mutating func integer<Value: FixedWidthInteger>(_: Value.Type) throws -> Value {
            let size = MemoryLayout<Value>.size
            guard offset + size <= bytes.count else { throw DecodeError.truncated }
            var value: Value = 0
            for index in 0..<size { value |= Value(bytes[offset + index]) << (8 * index) }
            offset += size
            return value
        }
    }
}

/// Writes one pacer's trace to `Library/Caches/pacer-trace-<yyyyMMdd-HHmmss>-slot<N>.bin`. The
/// pacer appends events to a memory buffer under its own lock; a timer on this recorder's serial
/// queue moves the buffer to the file once a second, so no file I/O runs on the decode thread, the
/// display link or under the pacer's lock. Older traces are pruned at start to the newest
/// `keepFiles` within `keepBytes` (never one a recorder still has open), and one file stops
/// growing at `maxFileBytes`. After a failed write nothing more is appended, so the file ends
/// at most one torn record late.
public final class PacerTraceRecorder: @unchecked Sendable {
    public static let filePrefix = "pacer-trace-"
    public static let keepFiles = 20
    public static let keepBytes = 50 * 1024 * 1024
    public static let maxFileBytes = 25 * 1024 * 1024

    public let fileURL: URL
    private let queue = DispatchQueue(label: "Selenite pacer trace", qos: .utility)
    private let lock = NSLock()
    private var buffer = Data()
    private var bufferedBytes = 0
    private var closed = false
    private var handle: FileHandle?
    private var timer: DispatchSourceTimer?

    /// Paths every recorder in this process still has open: pruning leaves them alone.
    private static let openLock = NSLock()
    nonisolated(unsafe) private static var openPaths: Set<String> = []

    static func isOpen(_ url: URL) -> Bool {
        openLock.withLock { openPaths.contains(url.standardizedFileURL.path) }
    }

    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    }

    public static func fileName(startedAt date: Date, slot: Int) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "\(filePrefix)\(formatter.string(from: date))-slot\(slot).bin"
    }

    public init(metadata: PacerTrace.Metadata, directory: URL = PacerTraceRecorder.defaultDirectory,
                startedAt date: Date = Date()) {
        fileURL = directory.appendingPathComponent(Self.fileName(startedAt: date, slot: metadata.slot))
        buffer.reserveCapacity(64 * 1024)
        let header = PacerTrace.header(metadata)
        let fileURL = self.fileURL
        Self.openLock.withLock { _ = Self.openPaths.insert(fileURL.standardizedFileURL.path) }
        queue.async { [self] in
            Self.prune(directory: directory, reserving: header.count)
            guard FileManager.default.createFile(atPath: fileURL.path, contents: header),
                  let opened = try? FileHandle(forWritingTo: fileURL) else {
                traceDiagnostic("pacer trace: cannot create \(fileURL.lastPathComponent), not recording")
                return
            }
            handle = opened
            _ = try? opened.seekToEnd()
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.flush() }
        timer.resume()
        self.timer = timer
    }

    deinit {
        timer?.cancel()
        let path = fileURL.standardizedFileURL.path
        Self.openLock.withLock { _ = Self.openPaths.remove(path) }
    }

    /// Appends one event to the buffer; cheap enough to call under the pacer's lock.
    func record(_ event: PacerTrace.Event) {
        lock.withLock {
            guard !closed, bufferedBytes < Self.maxFileBytes else { return }
            let before = buffer.count
            PacerTrace.append(event, to: &buffer)
            bufferedBytes += buffer.count - before
        }
    }

    /// Writes what is buffered and closes the file; later events are ignored. Blocks until the
    /// file is complete, so a reader right after sees every event.
    public func close() {
        lock.withLock { closed = true }
        queue.sync {
            timer?.cancel()
            timer = nil
            flush()
            try? handle?.close()
            handle = nil
        }
        let path = fileURL.standardizedFileURL.path
        Self.openLock.withLock { _ = Self.openPaths.remove(path) }
    }

    /// On `queue`: moves the buffer to the file.
    private func flush() {
        var fresh = Data()
        fresh.reserveCapacity(64 * 1024)
        let pending: Data = lock.withLock {
            swap(&buffer, &fresh)
            return fresh
        }
        guard !pending.isEmpty, let handle else { return }
        do {
            try handle.write(contentsOf: pending)
        } catch {
            // A partial write may have left a torn record: appending after it would misalign every
            // record that follows, so the file ends here.
            try? handle.close()
            self.handle = nil
            traceDiagnostic("pacer trace: write to \(fileURL.lastPathComponent) failed (\(error)), stopped")
        }
    }

    /// Deletes the oldest traces until at most `keepFiles - 1` remain within `keepBytes` minus
    /// what the new one needs to start. Names sort by start time.
    static func prune(directory: URL, reserving: Int, keepFiles: Int = keepFiles, keepBytes: Int = keepBytes) {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: directory.path) else { return }
        let traces = names.filter { $0.hasPrefix(filePrefix) && $0.hasSuffix(".bin") }.sorted()
        var sizes = traces.map { name -> Int in
            let attributes = try? manager.attributesOfItem(atPath: directory.appendingPathComponent(name).path)
            return (attributes?[.size] as? Int) ?? 0
        }
        var remaining = traces
        var index = 0
        while index < remaining.count,
              remaining.count >= keepFiles || sizes.reduce(0, +) + reserving > keepBytes {
            let url = directory.appendingPathComponent(remaining[index])
            if isOpen(url) {
                index += 1
                continue
            }
            try? manager.removeItem(at: url)
            remaining.remove(at: index)
            sizes.remove(at: index)
        }
    }
}

/// Routes a diagnostic line through the moonlight log sink, so it lands wherever the app logs.
private func traceDiagnostic(_ text: String) {
    guard let sink = MLGetLogSink() else { return }
    text.withCString { sink(-1, $0) }
}
