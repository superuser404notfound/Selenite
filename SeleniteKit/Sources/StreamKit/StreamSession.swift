import CoreMedia
import Foundation
import HostKit
import MoonlightCore

public struct StreamSettings: Sendable {
    public var width: Int
    public var height: Int
    public var fps: Int
    public var bitrateKbps: Int
    public var hdr: Bool
    public var audio: AudioChannels

    public init(width: Int, height: Int, fps: Int, bitrateKbps: Int, hdr: Bool, audio: AudioChannels = .stereo) {
        self.width = width; self.height = height; self.fps = fps; self.bitrateKbps = bitrateKbps; self.hdr = hdr
        self.audio = audio
    }
}

public enum StreamEvent: Sendable {
    case started
    case stageFailed(String, Int32)
    case terminated(Int32)
    case poorConnection(Bool)
    case hostHDR(Bool)
}

public struct StreamStats: Sendable {
    public var decodedFrames: Int
    public var networkDroppedFrames: Int
    public var pacer: PacerStats
    public var averageDecodeMilliseconds: Double
    public var rttMilliseconds: UInt32?
    public var audio: AudioRingStats?
}

public enum StreamSessionError: Error {
    case noFreeSlot
    case launchFailed(String)
    case connectionFailed(Int32)
    /// stop() ran before or while start() was connecting.
    case cancelled
    case alreadyStarted
}

public final class StreamSession: SlotEventSink, @unchecked Sendable {
    public let slot: Slot
    public let pacer = FramePacer<CMSampleBuffer>()
    public let events: AsyncStream<StreamEvent>
    private let eventSink: AsyncStream<StreamEvent>.Continuation
    private let host: PairedHost
    private let appID: Int
    private let settings: StreamSettings
    private let endpoints: NvEndpoints
    private let client: NvHTTPClient
    private let lock = NSLock()
    private var pipeline: VideoPipeline?
    private var audio: AudioStream?
    // Not private: StreamSession+Controllers.swift reads `isConnected` before touching the slot.
    let lifecycle = SessionLifecycle()
    private var cStrings: [UnsafeMutablePointer<CChar>] = []
    private weak var _feedbackHandler: (any ControllerFeedbackHandler)?

    /// Host-side receiver for controller feedback (rumble, LED, motion, adaptive triggers) the
    /// server sends back for this session. Weak: the caller owns the handler's lifetime.
    public var feedbackHandler: (any ControllerFeedbackHandler)? {
        get { lock.withLock { _feedbackHandler } }
        set { lock.withLock { _feedbackHandler = newValue } }
    }

    public init(host: PairedHost, appID: Int, settings: StreamSettings,
                identity: ClientIdentity, clientIdentity: SecIdentity) throws {
        guard let slot = SlotAllocator.shared.acquire() else { throw StreamSessionError.noFreeSlot }
        self.slot = slot
        self.host = host
        self.appID = appID
        self.settings = settings
        self.endpoints = NvEndpoints(address: host.address, httpsPort: host.httpsPort, uniqueID: identity.uniqueID)
        self.client = NvHTTPClient(pinnedCertificate: host.serverCertificateDER, clientIdentity: clientIdentity)
        (events, eventSink) = AsyncStream.makeStream()
    }

    public func start() async throws {
        try lifecycle.beginStart()
        let info = try ServerInfo(NvResponse.parse(try await client.get(endpoints.serverInfo(secure: true), timeout: 10)).requireOK())
        try lifecycle.checkpoint()
        let riKey = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        let riKeyID = Int32.random(in: 0...Int32.max)
        let request = LaunchRequest(
            appID: appID, width: settings.width, height: settings.height, fps: settings.fps,
            riKey: riKey, riKeyID: riKeyID, hdr: settings.hdr,
            surroundAudioInfo: Int(settings.audio == .surround51 ? ML_SURROUND_AUDIO_INFO_51 : ML_SURROUND_AUDIO_INFO_STEREO),
            gamepadMask: 1,
            launchQueryTail: String(cString: slot.api.getLaunchUrlQueryParameters!()!))
        let launch = try NvResponse.parse(try await client.get(endpoints.launch(request, resume: info.isBusy), timeout: 60))
        try lifecycle.checkpoint()
        guard launch.statusCode == 200, let sessionURL = launch["sessionUrl0"] else {
            throw StreamSessionError.launchFailed(launch.statusMessage)
        }

        let args = ConnectionArguments()
        var serverInfo = SERVER_INFORMATION()
        slot.api.initializeServerInformation!(&serverInfo)
        serverInfo.address = UnsafePointer(keep(host.address))
        serverInfo.serverInfoAppVersion = UnsafePointer(keep(info.appVersion))
        serverInfo.serverInfoGfeVersion = UnsafePointer(keep(info.gfeVersion))
        serverInfo.rtspSessionUrl = UnsafePointer(keep(sessionURL))
        serverInfo.serverCodecModeSupport = info.codecModeSupport

        var config = STREAM_CONFIGURATION()
        slot.api.initializeStreamConfiguration!(&config)
        config.width = Int32(settings.width)
        config.height = Int32(settings.height)
        config.fps = Int32(settings.fps)
        config.bitrate = Int32(settings.bitrateKbps)
        config.packetSize = 1392
        config.streamingRemotely = STREAM_CFG_AUTO
        config.audioConfiguration = settings.audio == .surround51 ? ML_AUDIO_CONFIGURATION_51 : ML_AUDIO_CONFIGURATION_STEREO
        config.supportedVideoFormats = VIDEO_FORMAT_H264 | VIDEO_FORMAT_H265 | (settings.hdr ? VIDEO_FORMAT_H265_MAIN10 : 0)
        config.clientRefreshRateX100 = 6000
        config.colorSpace = settings.hdr ? COLORSPACE_REC_2020 : COLORSPACE_REC_709
        config.colorRange = COLOR_RANGE_LIMITED
        config.encryptionFlags = Int32(bitPattern: UInt32(ENCFLG_ALL))
        withUnsafeMutableBytes(of: &config.remoteInputAesKey) { $0.copyBytes(from: riKey) }
        withUnsafeMutableBytes(of: &config.remoteInputAesIv) { iv in
            iv.initializeMemory(as: UInt8.self, repeating: 0)
            var keyID = riKeyID.bigEndian
            withUnsafeBytes(of: &keyID) { iv.copyMemory(from: $0) }
        }

        args.serverInfo = serverInfo
        args.config = config

        do {
            try lifecycle.beginConnect()
        } catch {
            // A stop that ran before this point may already have freed the earlier strings.
            freeCStrings()
            throw error
        }
        SlotRouter.shared.attach(self, to: slot)
        args.connection = SlotCallbacks.connection(for: slot)
        args.video = SlotCallbacks.video(for: slot)
        args.audio = SlotCallbacks.audio(for: slot)
        let slot = self.slot
        let lifecycle = self.lifecycle
        // LiStartConnection blocks through the whole RTSP handshake.
        let (result, owned): (Int32, Bool) = await withCheckedContinuation { continuation in
            Thread {
                let status = slot.api.startConnection!(&args.serverInfo, &args.config, &args.connection,
                                                       &args.video, &args.audio, nil, 0, nil, 0)
                let owned = lifecycle.endConnect(succeeded: status == 0)
                continuation.resume(returning: (status, owned))
            }.start()
        }
        // A stop arrived while connecting; it waited for this return and tears the slot down.
        guard owned else { throw StreamSessionError.cancelled }
        guard result == 0 else {
            SlotRouter.shared.detach(slot, ifAttached: self)
            throw StreamSessionError.connectionFailed(result)
        }
    }

    /// Only the first call does anything: after it the slot may already belong to another session.
    /// A stop during LiStartConnection interrupts it and waits for it to return before stopping,
    /// the two are not thread-safe against each other.
    public func stop() async {
        guard let found = lifecycle.requestStop() else { return }
        let slot = self.slot
        let lifecycle = self.lifecycle
        if found == .connecting || found == .connected || found == .failed {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                Thread {
                    if found == .connecting {
                        lifecycle.waitForConnectReturn { slot.api.interruptConnection!() }
                    }
                    slot.api.stopConnection!()
                    continuation.resume()
                }.start()
            }
        }
        let stillOpen: AudioStream? = lock.withLock {
            let stream = audio
            audio = nil
            return stream
        }
        stillOpen?.close()
        SlotRouter.shared.detach(slot, ifAttached: self)
        SlotAllocator.shared.release(slot)
        freeCStrings()
        eventSink.finish()
    }

    private func freeCStrings() {
        lock.withLock {
            cStrings.forEach { free($0) }
            cStrings.removeAll()
        }
    }

    public func stats() -> StreamStats {
        lock.lock(); let pipeline = self.pipeline; let audio = self.audio; lock.unlock()
        var rtt: UInt32 = 0
        var variance: UInt32 = 0
        let hasRTT = slot.api.getEstimatedRttInfo!(&rtt, &variance)
        return StreamStats(decodedFrames: pipeline?.decodedFrames ?? 0,
                           networkDroppedFrames: pipeline?.networkDroppedFrames ?? 0,
                           pacer: pacer.stats,
                           averageDecodeMilliseconds: pipeline?.averageDecodeMilliseconds ?? 0,
                           rttMilliseconds: hasRTT ? rtt : nil,
                           audio: audio?.stats)
    }

    private func keep(_ string: String) -> UnsafeMutablePointer<CChar> {
        let pointer = strdup(string)!
        lock.lock(); cStrings.append(pointer); lock.unlock()
        return pointer
    }

    /// The C structs LiStartConnection reads, boxed so the connect thread can take them by address.
    private final class ConnectionArguments: @unchecked Sendable {
        var serverInfo = SERVER_INFORMATION()
        var config = STREAM_CONFIGURATION()
        var connection = CONNECTION_LISTENER_CALLBACKS()
        var video = DECODER_RENDERER_CALLBACKS()
        var audio = AUDIO_RENDERER_CALLBACKS()
    }

    // MARK: SlotEventSink

    public func decoderSetup(videoFormat: Int32, width: Int32, height: Int32, fps: Int32) -> Int32 {
        let codec: VideoCodec = (videoFormat & VIDEO_FORMAT_MASK_H264) != 0 ? .h264 : .hevc
        let color: ColorSignal = (videoFormat & VIDEO_FORMAT_MASK_10BIT) != 0 ? .hdr10 : .sdr709
        lock.lock()
        pipeline = VideoPipeline(slot: slot, codec: codec, color: color, pacer: pacer)
        lock.unlock()
        return 0
    }

    public func decoderStart() { lock.lock(); let p = pipeline; lock.unlock(); p?.start() }
    public func decoderStop() { lock.lock(); let p = pipeline; lock.unlock(); p?.stop() }
    public func stageFailed(stage: Int32, error: Int32) {
        eventSink.yield(.stageFailed(String(cString: slot.api.getStageName!(stage)!), error))
    }
    public func connectionStarted() { eventSink.yield(.started) }
    public func connectionTerminated(error: Int32) { eventSink.yield(.terminated(error)) }
    public func connectionStatus(_ status: Int32) { eventSink.yield(.poorConnection(status == CONN_STATUS_POOR)) }
    public func setHdrMode(_ enabled: Bool) { eventSink.yield(.hostHDR(enabled)) }

    public func audioInit(_ config: OPUS_MULTISTREAM_CONFIGURATION) -> Int32 {
        do {
            let stream = try AudioStream(config: config)
            lock.lock(); audio = stream; lock.unlock()
            return 0
        } catch {
            NSLog("StreamSession: audio init failed on slot %@: %@", String(describing: slot), String(describing: error))
            return -1
        }
    }

    /// `data` is nil for a lost packet; passed through unfiltered so `OpusDecoder` can hand libopus
    /// its packet-loss-concealment call (nil data, zero length).
    public func audioSample(_ data: UnsafePointer<CChar>?, length: Int32) {
        lock.lock(); let stream = audio; lock.unlock()
        stream?.submit(UnsafeRawBufferPointer(start: data, count: Int(length)))
    }

    public func audioCleanup() {
        lock.lock(); let stream = audio; audio = nil; lock.unlock()
        stream?.close()
    }

    public func rumble(controller: UInt16, low: UInt16, high: UInt16) {
        lock.lock(); let handler = _feedbackHandler; lock.unlock()
        handler?.rumble(controller: controller, low: low, high: high)
    }

    public func rumbleTriggers(controller: UInt16, left: UInt16, right: UInt16) {
        lock.lock(); let handler = _feedbackHandler; lock.unlock()
        handler?.rumbleTriggers(controller: controller, left: left, right: right)
    }

    public func setMotionEventState(controller: UInt16, motionType: UInt8, reportRateHz: UInt16) {
        lock.lock(); let handler = _feedbackHandler; lock.unlock()
        handler?.setMotionEventState(controller: controller, motionType: motionType, reportRateHz: reportRateHz)
    }

    public func setControllerLED(controller: UInt16, r: UInt8, g: UInt8, b: UInt8) {
        lock.lock(); let handler = _feedbackHandler; lock.unlock()
        handler?.setControllerLED(controller: controller, r: r, g: g, b: b)
    }

    public func setAdaptiveTriggers(controller: UInt16, eventFlags: UInt8, typeLeft: UInt8, typeRight: UInt8, left: [UInt8], right: [UInt8]) {
        lock.lock(); let handler = _feedbackHandler; lock.unlock()
        handler?.setAdaptiveTriggers(controller: controller, eventFlags: eventFlags, typeLeft: typeLeft, typeRight: typeRight, left: left, right: right)
    }
}
