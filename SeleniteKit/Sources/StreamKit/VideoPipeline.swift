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
    private var lastFrameNumber: Int32 = 0
    private var decodeTimeTotal: Double = 0
    // Mutated only on the pull thread inside process(), but read from other threads by stats
    // (see VideoPipeline.decodedFrames / .networkDroppedFrames below), so every access goes
    // through `lock` rather than the `private(set) public var` the brief specified.
    private var decodedFramesCount = 0
    private var networkDroppedFramesCount = 0

    public init(slot: Slot, codec: VideoCodec, color: ColorSignal, pacer: FramePacer<CMSampleBuffer>) {
        self.slot = slot; self.codec = codec; self.color = color; self.pacer = pacer
    }

    public var decodedFrames: Int {
        lock.lock(); defer { lock.unlock() }
        return decodedFramesCount
    }

    public var networkDroppedFrames: Int {
        lock.lock(); defer { lock.unlock() }
        return networkDroppedFramesCount
    }

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
        if lastFrameNumber != 0, unit.frameNumber > lastFrameNumber + 1 {
            let dropped = Int(unit.frameNumber - lastFrameNumber - 1)
            lock.lock(); networkDroppedFramesCount += dropped; lock.unlock()
        }
        lastFrameNumber = unit.frameNumber
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
                    decoder = try VideoDecoder(format: newFormat, color: color) { [pacer] pixelBuffer in
                        if let sample = try? DisplaySample.make(pixelBuffer) { pacer.put(sample, arrival: CACurrentMediaTime()) }
                    }
                }
                format = newFormat
            }
            guard let format, let decoder else { return DR_NEED_IDR }
            let sample = try NALPackager.sampleBuffer(annexB: picture, format: format,
                                                      pts: CMTime(value: Int64(unit.rtpTimestamp), timescale: 90000))
            let started = CACurrentMediaTime()
            try decoder.decode(sample)
            lock.lock()
            decodeTimeTotal += CACurrentMediaTime() - started
            decodedFramesCount += 1
            lock.unlock()
            return DR_OK
        } catch {
            return DR_NEED_IDR
        }
    }
}
