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

    public init(width: Int, height: Int, fps: Int, bitrateKbps: Int, hdr: Bool) {
        self.width = width; self.height = height; self.fps = fps; self.bitrateKbps = bitrateKbps; self.hdr = hdr
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
    public var mailbox: MailboxStats
    public var averageDecodeMilliseconds: Double
    public var rttMilliseconds: UInt32?
}

public enum StreamSessionError: Error {
    case noFreeSlot
    case launchFailed(String)
    case connectionFailed(Int32)
}

public final class StreamSession: SlotEventSink, @unchecked Sendable {
    public let slot: Slot
    public let mailbox = FrameMailbox<CMSampleBuffer>()
    public let events: AsyncStream<StreamEvent>
    private let eventSink: AsyncStream<StreamEvent>.Continuation
    private let host: PairedHost
    private let appID: Int
    private let settings: StreamSettings
    private let endpoints: NvEndpoints
    private let client: NvHTTPClient
    private let lock = NSLock()
    private var pipeline: VideoPipeline?
    private var stopped = false
    private var cStrings: [UnsafeMutablePointer<CChar>] = []

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
        let info = try ServerInfo(NvResponse.parse(try await client.get(endpoints.serverInfo(secure: true), timeout: 10)).requireOK())
        let riKey = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        let riKeyID = Int32.random(in: 0...Int32.max)
        let request = LaunchRequest(
            appID: appID, width: settings.width, height: settings.height, fps: settings.fps,
            riKey: riKey, riKeyID: riKeyID, hdr: settings.hdr,
            surroundAudioInfo: Int(ML_SURROUND_AUDIO_INFO_STEREO), gamepadMask: 1,
            launchQueryTail: String(cString: slot.api.getLaunchUrlQueryParameters!()!))
        let launch = try NvResponse.parse(try await client.get(endpoints.launch(request, resume: info.isBusy), timeout: 60))
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
        config.audioConfiguration = ML_AUDIO_CONFIGURATION_STEREO
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

        SlotRouter.shared.attach(self, to: slot)
        args.connection = SlotCallbacks.connection(for: slot)
        args.video = SlotCallbacks.video(for: slot)
        args.audio = SlotCallbacks.audio(for: slot)
        let slot = self.slot
        // LiStartConnection blocks through the whole RTSP handshake.
        let result: Int32 = await withCheckedContinuation { continuation in
            Thread {
                let status = slot.api.startConnection!(&args.serverInfo, &args.config, &args.connection,
                                                       &args.video, &args.audio, nil, 0, nil, 0)
                continuation.resume(returning: status)
            }.start()
        }
        guard result == 0 else {
            SlotRouter.shared.detach(slot, ifAttached: self)
            throw StreamSessionError.connectionFailed(result)
        }
    }

    /// Only the first call does anything: after it the slot may already belong to another session.
    public func stop() async {
        let alreadyStopped = lock.withLock {
            defer { stopped = true }
            return stopped
        }
        guard !alreadyStopped else { return }
        let slot = self.slot
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            Thread {
                slot.api.stopConnection!()
                continuation.resume()
            }.start()
        }
        SlotRouter.shared.detach(slot, ifAttached: self)
        SlotAllocator.shared.release(slot)
        lock.withLock {
            cStrings.forEach { free($0) }
            cStrings.removeAll()
        }
        eventSink.finish()
    }

    public func stats() -> StreamStats {
        lock.lock(); let pipeline = self.pipeline; lock.unlock()
        var rtt: UInt32 = 0
        var variance: UInt32 = 0
        let hasRTT = slot.api.getEstimatedRttInfo!(&rtt, &variance)
        return StreamStats(decodedFrames: pipeline?.decodedFrames ?? 0,
                           networkDroppedFrames: pipeline?.networkDroppedFrames ?? 0,
                           mailbox: mailbox.stats,
                           averageDecodeMilliseconds: pipeline?.averageDecodeMilliseconds ?? 0,
                           rttMilliseconds: hasRTT ? rtt : nil)
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
        pipeline = VideoPipeline(slot: slot, codec: codec, color: color, mailbox: mailbox)
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
}
