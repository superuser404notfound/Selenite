import Foundation
import Testing
@testable import StreamKit

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("pacer-trace-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private let metadata = PacerTrace.Metadata(mode: "lowLatency", directPresent: true, frameRate: 60, slot: 1,
                                           width: 1920, height: 2160, startedAt: "2026-10-05T12:00:00+02:00")

@Test func aRecordedTraceReadsBackEventForEvent() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    // Every time value round-trips bit for bit, so a replay decides exactly as the device did.
    let events: [PacerTrace.Event] = [
        .presenter(attached: true),
        .vsync(timestamp: 100.0, duration: 1.0 / 60, tickTime: 100.000_812_345),
        .tick,
        .put(arrival: 100.0071234567, frameNumber: 41),
        .put(arrival: 100.0123, frameNumber: nil),
        .vsync(timestamp: 100.0 + 1.0 / 60, duration: 1.0 / 59.94, tickTime: 100.0 + 1.0 / 60 + 0.000_7),
        .tick,
        .presenter(attached: false),
    ]
    let recorder = PacerTraceRecorder(metadata: metadata, directory: directory)
    events.forEach(recorder.record)
    recorder.close()
    let trace = try PacerTrace.decode(Data(contentsOf: recorder.fileURL))
    #expect(trace.metadata == metadata)
    #expect(trace.events == events)
}

@Test func thePacerRecordsItsInputsInOrder() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let recorder = PacerTraceRecorder(metadata: metadata, directory: directory)
    let pacer = FramePacer<Int>(mode: .lowLatency, frameRate: 60, directPresent: true, trace: recorder)
    pacer.setPresenter { _ in }
    pacer.vsync(timestamp: 2.0, duration: 0.015625, tickTime: 2.0009765625)
    _ = pacer.tick()
    pacer.put(0, arrival: 2.005, frameNumber: 7)
    pacer.finishTrace()
    // After finishing, nothing more reaches the file.
    pacer.put(1, arrival: 2.02, frameNumber: 8)
    let trace = try PacerTrace.decode(Data(contentsOf: recorder.fileURL))
    #expect(trace.events == [
        .presenter(attached: true),
        .vsync(timestamp: 2.0, duration: 0.015625, tickTime: 2.0009765625),
        .tick,
        .put(arrival: 2.005, frameNumber: 7),
    ])
}

@Test func traceFilesAreNamedByStartTimeAndSlot() {
    var components = DateComponents()
    components.year = 2026; components.month = 10; components.day = 5
    components.hour = 21; components.minute = 4; components.second = 9
    let date = Calendar.current.date(from: components)!
    #expect(PacerTraceRecorder.fileName(startedAt: date, slot: 0) == "pacer-trace-20261005-210409-slot0.bin")
}

@Test func pruningKeepsTheNewestTracesWithinTheCaps() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    for index in 0..<6 {
        let name = String(format: "pacer-trace-20261005-1200%02d-slot0.bin", index)
        FileManager.default.createFile(atPath: directory.appendingPathComponent(name).path, contents: Data(count: 100))
    }
    FileManager.default.createFile(atPath: directory.appendingPathComponent("selenite-log.txt").path,
                                   contents: Data(count: 1000))
    PacerTraceRecorder.prune(directory: directory, reserving: 50, keepFiles: 5, keepBytes: 350)
    let left = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    // Room for the new one: at most 4 old ones and 350 bytes with its 50, so 3 remain. Other
    // files are not touched.
    #expect(left == ["pacer-trace-20261005-120003-slot0.bin", "pacer-trace-20261005-120004-slot0.bin",
                     "pacer-trace-20261005-120005-slot0.bin", "selenite-log.txt"])
}

@Test func somethingElseIsNotATrace() {
    #expect(throws: PacerTrace.DecodeError.notATrace) { try PacerTrace.decode(Data("hello world".utf8)) }
    let header = PacerTrace.header(metadata)
    #expect(throws: PacerTrace.DecodeError.truncated) { try PacerTrace.decode(header.dropLast(2)) }
}

@Test func onlyThisFormatVersionIsRead() {
    var older = PacerTrace.header(metadata)
    older[3] = UInt8(ascii: "1")
    #expect(throws: PacerTrace.DecodeError.unsupportedVersion("SPT1")) { try PacerTrace.decode(older) }
}

@Test func aTruncatedTailReadsUpToTheLastWholeRecord() throws {
    // The app killed mid-write: the last record is cut off, everything before it still counts.
    var data = PacerTrace.header(metadata)
    PacerTrace.append(.put(arrival: 1, frameNumber: 1), to: &data)
    PacerTrace.append(.tick, to: &data)
    PacerTrace.append(.vsync(timestamp: 2, duration: 1.0 / 60, tickTime: 2.001), to: &data)
    let trace = try PacerTrace.decode(data.dropLast(5))
    #expect(trace.events == [.put(arrival: 1, frameNumber: 1), .tick])
    #expect(trace.endsTruncated)
    #expect(try !PacerTrace.decode(data).endsTruncated)
}

@Test func pruningNeverDeletesATraceThatIsStillOpen() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    var components = DateComponents()
    components.year = 2026; components.month = 10; components.day = 5; components.hour = 11
    let recorder = PacerTraceRecorder(metadata: metadata, directory: directory,
                                      startedAt: Calendar.current.date(from: components)!)
    recorder.record(.tick)
    for index in 0..<3 {
        let name = String(format: "pacer-trace-20261005-1200%02d-slot0.bin", index)
        FileManager.default.createFile(atPath: directory.appendingPathComponent(name).path, contents: Data(count: 100))
    }
    // The open trace sorts first (11:00), so it is the oldest; a cap of one file keeps it anyway.
    PacerTraceRecorder.prune(directory: directory, reserving: 0, keepFiles: 1, keepBytes: 1)
    let left: [String] = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    #expect(left == [recorder.fileURL.lastPathComponent])
    recorder.close()
    #expect(!PacerTraceRecorder.isOpen(recorder.fileURL))
    PacerTraceRecorder.prune(directory: directory, reserving: 0, keepFiles: 1, keepBytes: 1)
    let after: [String] = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    #expect(after.isEmpty)
}
