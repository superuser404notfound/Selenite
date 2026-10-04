import Foundation
import MoonlightCore
import StreamKit

/// Device diagnostics: tvOS drops stdout without a debugger, so app lines and moonlight-common-c
/// lines also go to Library/Caches/selenite-log.txt, which `devicectl device copy from` can pull.
/// Truncated at every launch. Moved here from the harness so the real app writes it too.
public final class DiagnosticLog: @unchecked Sendable {
    public static let shared = DiagnosticLog(
        url: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("selenite-log.txt"))

    private let queue = DispatchQueue(label: "selenite.diagnostic-log")
    private let handle: FileHandle?
    private let start = Date()

    init(url: URL) {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try? FileHandle(forWritingTo: url)
    }

    public func append(_ line: String) {
        let stamp = String(format: "%9.3f ", Date().timeIntervalSince(start))
        let text = stamp + (line.hasSuffix("\n") ? line : line + "\n")
        queue.async { [handle] in try? handle?.write(contentsOf: Data(text.utf8)) }
    }

    /// Waits until every appended line is written. Tests only.
    func flush() {
        queue.sync {}
    }

    /// An app-level line: to the console and to the file.
    public static func note(_ line: String) {
        NSLog("[Selenite] %@", line)
        shared.append("[app] " + line)
    }

    /// Routes moonlight-common-c's log lines into the file. Call once at launch.
    public static func installMoonlightSink() {
        MLSetLogSink(moonlightLogSink)
    }
}

/// moonlight-common-c logs from its own connection threads. A closure written in a @MainActor
/// context would inherit that isolation and trap on its first off-main call, hence a free function.
private nonisolated func moonlightLogSink(_ slot: Int32, _ line: UnsafePointer<CChar>?) {
    guard let line else { return }
    let rawLine = String(cString: line)
    let text = "[slot \(slot)] \(rawLine)"
    print(text, terminator: "")
    DiagnosticLog.shared.append(text)
    SlotLogCounters.shared.observe(slot: slot, line: rawLine)
}
