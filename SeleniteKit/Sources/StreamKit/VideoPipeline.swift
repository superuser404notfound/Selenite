import CoreMedia
import Foundation
import MoonlightCore
import QuartzCore

/// Pulls decode units from one slot on a dedicated thread, decodes them and hands the newest
/// frames to the pacer the display tick reads.
public final class VideoPipeline: @unchecked Sendable {
    private let slot: Slot
    private let codec: VideoCodec
    private let color: ColorSignal
    private let pacer: FramePacer<CMSampleBuffer>
    private let lock = NSLock()
    private var running = false
    // Signalled when the pull thread has left run(), decoder teardown included; nil while no
    // thread is running.
    private var finished: DispatchSemaphore?
    private var format: CMVideoFormatDescription?
    private var decoder: VideoDecoder?
    private var decodeTimeTotal: Double = 0
    // Mutated only on the pull thread inside process(), but read from other threads by stats
    // (see VideoPipeline.decodedFrames / .networkDroppedFrames below), so every access goes
    // through `lock` rather than the `private(set) public var` the brief specified.
    private var decodedFramesCount = 0
    private var intake = FrameIntake()
    private var overflowBase = 0
    private var unrecoverableBase = 0
    /// The unit being decoded: the session decodes synchronously, so its output callback runs
    /// inside `decode` on the pull thread and reads this to tell the pacer which frame it got.
    private var decodingFrameNumber = 0

    public init(slot: Slot, codec: VideoCodec, color: ColorSignal, pacer: FramePacer<CMSampleBuffer>) {
        self.slot = slot; self.codec = codec; self.color = color; self.pacer = pacer
    }

    public var decodedFrames: Int {
        lock.lock(); defer { lock.unlock() }
        return decodedFramesCount
    }

    public var networkDroppedFrames: Int { lock.withLock { intake.networkDrops } }

    public var averageDecodeMilliseconds: Double {
        lock.lock(); defer { lock.unlock() }
        return decodedFramesCount == 0 ? 0 : decodeTimeTotal / Double(decodedFramesCount) * 1000
    }

    public func start() {
        lock.lock()
        guard finished == nil else { lock.unlock(); return }
        running = true
        let done = DispatchSemaphore(value: 0)
        finished = done
        overflowBase = SlotLogCounters.shared.overflows(slot)
        unrecoverableBase = SlotLogCounters.shared.unrecoverable(slot)
        lock.unlock()
        let thread = Thread { [self] in run(signalling: done) }
        thread.name = "Selenite video slot \(slot)"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// Returns only after the pull thread has finished, so the slot can be released right after.
    public func stop() {
        lock.lock()
        running = false
        let done = finished
        finished = nil
        lock.unlock()
        guard let done else { return }
        slot.api.wakeWaitForVideoFrame!()
        done.wait()
    }

    private var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }

    private func run(signalling done: DispatchSemaphore) {
        defer { done.signal() }
        while isRunning {
            var handle: VIDEO_FRAME_HANDLE?
            var unit: PDECODE_UNIT?
            guard slot.api.waitForNextVideoFrame!(&handle, &unit), let unit else { break }
            let status = process(unit.pointee)
            slot.api.completeVideoFrame!(handle, status)
        }
        decoder?.invalidate()
        decoder = nil
    }

    private func process(_ unit: DECODE_UNIT) -> Int32 {
        let overflows = SlotLogCounters.shared.overflows(slot) - overflowBase
        lock.withLock {
            intake.receive(frameNumber: unit.frameNumber, bytes: Int(unit.fullLength),
                           hostLatencyTenths: unit.frameHostProcessingLatency,
                           receiveMicroseconds: unit.receiveTimeUs, enqueueMicroseconds: unit.enqueueTimeUs,
                           overflowsSoFar: overflows)
        }
        var parameterSets: [Data] = []
        var picture = Data(capacity: Int(unit.fullLength))
        var entry = unit.bufferList
        while let current = entry {
            let bytes = UnsafeRawBufferPointer(start: current.pointee.data, count: Int(current.pointee.length))
            if current.pointee.bufferType == BUFFER_TYPE_PICDATA {
                picture.append(contentsOf: bytes)
            } else {
                parameterSets.append(NALPackager.stripStartCode(bytes))
            }
            entry = current.pointee.next
        }
        do {
            if !parameterSets.isEmpty {
                let newFormat = try NALPackager.formatDescription(codec: codec, parameterSets: parameterSets)
                if decoder.map({ !$0.canAccept(newFormat, color: color) }) ?? true {
                    decoder?.invalidate()
                    decoder = nil
                    decoder = try VideoDecoder(format: newFormat, color: color) { [weak self, pacer] pixelBuffer in
                        if let sample = try? DisplaySample.make(pixelBuffer) {
                            pacer.put(sample, arrival: CACurrentMediaTime(), frameNumber: self?.decodingFrameNumber)
                        }
                    }
                }
                format = newFormat
            }
            guard let format, let decoder else {
                diagnostic("frame \(unit.frameNumber): no decoder yet (format \(format != nil)), requesting IDR")
                return DR_NEED_IDR
            }
            let sample = try NALPackager.sampleBuffer(annexB: picture, format: format,
                                                      pts: CMTime(value: Int64(unit.rtpTimestamp), timescale: 90000))
            let started = CACurrentMediaTime()
            decodingFrameNumber = Int(unit.frameNumber)
            try decoder.decode(sample)
            lock.lock()
            decodeTimeTotal += CACurrentMediaTime() - started
            decodedFramesCount += 1
            lock.unlock()
            return DR_OK
        } catch {
            diagnostic("frame \(unit.frameNumber) type \(unit.frameType) length \(unit.fullLength): \(error), requesting IDR")
            return DR_NEED_IDR
        }
    }

    struct IntakeSnapshot {
        var bytes: Int
        var queueDrops: Int
        var unrecoverable: Int
        var hostLatencyTotalTenths: Int
        var hostLatencySamples: Int
        var hostLatencyRange: ClosedRange<Double>?
        var receiveTotalMicroseconds: UInt64
        var receiveSamples: Int
    }

    /// Read-only: no draining, safe to call as often as a caller likes (e.g. a poll loop).
    func intakeSnapshot() -> IntakeSnapshot {
        let unrecoverable = SlotLogCounters.shared.unrecoverable(slot) - lock.withLock { unrecoverableBase }
        return lock.withLock {
            IntakeSnapshot(bytes: intake.bytes, queueDrops: intake.queueDrops, unrecoverable: unrecoverable,
                           hostLatencyTotalTenths: intake.hostLatencyTotalTenths,
                           hostLatencySamples: intake.hostLatencySamples,
                           hostLatencyRange: intake.hostLatencyRange,
                           receiveTotalMicroseconds: intake.receiveTotalMicroseconds,
                           receiveSamples: intake.receiveSamples)
        }
    }
}

/// Routes a diagnostic line through the moonlight log sink, so it lands wherever the app logs.
private func diagnostic(_ text: String) {
    guard let sink = MLGetLogSink() else { return }
    text.withCString { sink(-1, $0) }
}
