import Foundation
import Testing
@testable import AppCore

@Test func eachLaunchTruncatesTheFileAndLinesAreAppended() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("selenite-log-\(UUID().uuidString).txt")
    try Data("previous run\n".utf8).write(to: url)
    let log = DiagnosticLog(url: url)
    log.append("hello")
    log.append("world\n")
    log.flush()
    let text = try String(contentsOf: url, encoding: .utf8)
    #expect(!text.contains("previous run"))
    #expect(text.contains("hello\n"))
    #expect(text.hasSuffix("world\n"))
}
