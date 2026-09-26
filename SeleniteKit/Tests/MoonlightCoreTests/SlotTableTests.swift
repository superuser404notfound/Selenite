import Testing
import MoonlightCore
import MoonlightSlotA
import MoonlightSlotB

@Test func tablesIdentifyTheirSlot() {
    #expect(MLSlotA.slot == 0)
    #expect(MLSlotB.slot == 1)
}

@Test func tablesPointAtDistinctCopies() {
    let a = unsafeBitCast(MLSlotA.startConnection, to: UnsafeRawPointer.self)
    let b = unsafeBitCast(MLSlotB.startConnection, to: UnsafeRawPointer.self)
    #expect(a != b)
}

@Test func bothCopiesAnswer() {
    // getStageName/getLaunchUrlQueryParameters return `const char *`, imported as an Optional
    // pointer; the extra `!` unwraps the call's result, not just the optional function pointer.
    let a = String(cString: MLSlotA.getStageName!(Int32(STAGE_RTSP_HANDSHAKE))!)
    let b = String(cString: MLSlotB.getStageName!(Int32(STAGE_RTSP_HANDSHAKE))!)
    #expect(a == b)
    #expect(!a.isEmpty)
    #expect(String(cString: MLSlotA.getLaunchUrlQueryParameters!()!).hasPrefix("&"))
}

@Test func stereoConstantsMatchMoonlight() {
    #expect(ML_AUDIO_CONFIGURATION_STEREO == 0x302CA)
    #expect(ML_SURROUND_AUDIO_INFO_STEREO == 0x30002)
}
