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
            callbacks.rumble = { SlotRouter.shared.sink(for: .a)?.rumble(controller: $0, low: $1, high: $2) }
            callbacks.rumbleTriggers = { SlotRouter.shared.sink(for: .a)?.rumbleTriggers(controller: $0, left: $1, right: $2) }
            callbacks.setMotionEventState = { SlotRouter.shared.sink(for: .a)?.setMotionEventState(controller: $0, motionType: $1, reportRateHz: $2) }
            callbacks.setControllerLED = { SlotRouter.shared.sink(for: .a)?.setControllerLED(controller: $0, r: $1, g: $2, b: $3) }
            callbacks.setAdaptiveTriggers = { controller, flags, typeLeft, typeRight, left, right in
                let size = Int(DS_EFFECT_PAYLOAD_SIZE)
                let l = left.map { Array(UnsafeBufferPointer(start: $0, count: size)) } ?? []
                let r = right.map { Array(UnsafeBufferPointer(start: $0, count: size)) } ?? []
                SlotRouter.shared.sink(for: .a)?.setAdaptiveTriggers(controller: controller, eventFlags: flags, typeLeft: typeLeft, typeRight: typeRight, left: l, right: r)
            }
        case .b:
            callbacks.stageFailed = { SlotRouter.shared.sink(for: .b)?.stageFailed(stage: $0, error: $1) }
            callbacks.connectionStarted = { SlotRouter.shared.sink(for: .b)?.connectionStarted() }
            callbacks.connectionTerminated = { SlotRouter.shared.sink(for: .b)?.connectionTerminated(error: $0) }
            callbacks.connectionStatusUpdate = { SlotRouter.shared.sink(for: .b)?.connectionStatus($0) }
            callbacks.setHdrMode = { SlotRouter.shared.sink(for: .b)?.setHdrMode($0) }
            callbacks.rumble = { SlotRouter.shared.sink(for: .b)?.rumble(controller: $0, low: $1, high: $2) }
            callbacks.rumbleTriggers = { SlotRouter.shared.sink(for: .b)?.rumbleTriggers(controller: $0, left: $1, right: $2) }
            callbacks.setMotionEventState = { SlotRouter.shared.sink(for: .b)?.setMotionEventState(controller: $0, motionType: $1, reportRateHz: $2) }
            callbacks.setControllerLED = { SlotRouter.shared.sink(for: .b)?.setControllerLED(controller: $0, r: $1, g: $2, b: $3) }
            callbacks.setAdaptiveTriggers = { controller, flags, typeLeft, typeRight, left, right in
                let size = Int(DS_EFFECT_PAYLOAD_SIZE)
                let l = left.map { Array(UnsafeBufferPointer(start: $0, count: size)) } ?? []
                let r = right.map { Array(UnsafeBufferPointer(start: $0, count: size)) } ?? []
                SlotRouter.shared.sink(for: .b)?.setAdaptiveTriggers(controller: controller, eventFlags: flags, typeLeft: typeLeft, typeRight: typeRight, left: l, right: r)
            }
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
                SlotRouter.shared.sink(for: .a)?.audioSample(data, length: length)
            }
            callbacks.cleanup = { SlotRouter.shared.sink(for: .a)?.audioCleanup() }
        case .b:
            callbacks.`init` = { _, opusConfig, _, _ in
                guard let opusConfig else { return -1 }
                return SlotRouter.shared.sink(for: .b)?.audioInit(opusConfig.pointee) ?? -1
            }
            callbacks.decodeAndPlaySample = { data, length in
                SlotRouter.shared.sink(for: .b)?.audioSample(data, length: length)
            }
            callbacks.cleanup = { SlotRouter.shared.sink(for: .b)?.audioCleanup() }
        }
        return callbacks
    }
}
