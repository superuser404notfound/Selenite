import MoonlightCore

/// C function pointers cannot capture, so every slot gets its own literal closures.
enum SlotCallbacks {
    static func connection(for slot: Slot) -> CONNECTION_LISTENER_CALLBACKS {
        var callbacks = CONNECTION_LISTENER_CALLBACKS()
        slot.api.initializeConnectionCallbacks!(&callbacks)
        switch slot {
        case .a:
            callbacks.stageFailed = { SlotRouter.shared.sink(for: .a)?.stageFailed(stage: $0, error: $1) }
            callbacks.connectionStarted = { SlotRouter.shared.sink(for: .a)?.connectionStarted() }
            callbacks.connectionTerminated = { SlotRouter.shared.sink(for: .a)?.connectionTerminated(error: $0) }
            callbacks.connectionStatusUpdate = { SlotRouter.shared.sink(for: .a)?.connectionStatus($0) }
            callbacks.setHdrMode = { SlotRouter.shared.sink(for: .a)?.setHdrMode($0) }
        case .b:
            callbacks.stageFailed = { SlotRouter.shared.sink(for: .b)?.stageFailed(stage: $0, error: $1) }
            callbacks.connectionStarted = { SlotRouter.shared.sink(for: .b)?.connectionStarted() }
            callbacks.connectionTerminated = { SlotRouter.shared.sink(for: .b)?.connectionTerminated(error: $0) }
            callbacks.connectionStatusUpdate = { SlotRouter.shared.sink(for: .b)?.connectionStatus($0) }
            callbacks.setHdrMode = { SlotRouter.shared.sink(for: .b)?.setHdrMode($0) }
        }
        callbacks.logMessage = slot.api.logMessage
        return callbacks
    }

    static func video(for slot: Slot) -> DECODER_RENDERER_CALLBACKS {
        var callbacks = DECODER_RENDERER_CALLBACKS()
        slot.api.initializeVideoCallbacks!(&callbacks)
        switch slot {
        case .a:
            callbacks.setup = { format, width, height, fps, _, _ in
                SlotRouter.shared.sink(for: .a)?.decoderSetup(videoFormat: format, width: width, height: height, fps: fps) ?? -1
            }
            callbacks.start = { SlotRouter.shared.sink(for: .a)?.decoderStart() }
            callbacks.stop = { SlotRouter.shared.sink(for: .a)?.decoderStop() }
        case .b:
            callbacks.setup = { format, width, height, fps, _, _ in
                SlotRouter.shared.sink(for: .b)?.decoderSetup(videoFormat: format, width: width, height: height, fps: fps) ?? -1
            }
            callbacks.start = { SlotRouter.shared.sink(for: .b)?.decoderStart() }
            callbacks.stop = { SlotRouter.shared.sink(for: .b)?.decoderStop() }
        }
        callbacks.capabilities = Int32(CAPABILITY_PULL_RENDERER)
        return callbacks
    }

    static func audio(for slot: Slot) -> AUDIO_RENDERER_CALLBACKS {
        var callbacks = AUDIO_RENDERER_CALLBACKS()
        slot.api.initializeAudioCallbacks!(&callbacks)
        switch slot {
        case .a:
            callbacks.`init` = { _, opusConfig, _, _ in
                guard let opusConfig else { return -1 }
                return SlotRouter.shared.sink(for: .a)?.audioInit(opusConfig.pointee) ?? -1
            }
            callbacks.decodeAndPlaySample = { data, length in
                guard let data else { return }
                SlotRouter.shared.sink(for: .a)?.audioSample(data, length: length)
            }
            callbacks.cleanup = { SlotRouter.shared.sink(for: .a)?.audioCleanup() }
        case .b:
            callbacks.`init` = { _, opusConfig, _, _ in
                guard let opusConfig else { return -1 }
                return SlotRouter.shared.sink(for: .b)?.audioInit(opusConfig.pointee) ?? -1
            }
            callbacks.decodeAndPlaySample = { data, length in
                guard let data else { return }
                SlotRouter.shared.sink(for: .b)?.audioSample(data, length: length)
            }
            callbacks.cleanup = { SlotRouter.shared.sink(for: .b)?.audioCleanup() }
        }
        return callbacks
    }
}
