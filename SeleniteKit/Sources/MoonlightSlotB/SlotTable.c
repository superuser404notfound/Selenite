#include "SlotPrefix.h"
#include <stdarg.h>
#include <stdio.h>
// Textual include so SlotPrefix.h's renaming applies to the Li* declarations before MoonlightCore.h
// is pulled in as a precompiled Clang module (which would otherwise freeze them unprefixed).
#include "../../Vendor/moonlight-common-c/src/Limelight.h"
#include <MoonlightCore.h>

#define SLOT_INDEX 1
#define SLOT_TABLE MLSlotB

static void slotLog(const char *format, ...) {
    MLLogSink sink = MLGetLogSink();
    if (sink == NULL) {
        return;
    }
    char line[1024];
    va_list args;
    va_start(args, format);
    vsnprintf(line, sizeof(line), format, args);
    va_end(args);
    sink(SLOT_INDEX, line);
}

// Every Li* name below is rewritten by SlotPrefix.h to this copy's SlotX_Li* symbol.
const MLSlotAPI SLOT_TABLE = {
    .slot = SLOT_INDEX,
    .initializeServerInformation = LiInitializeServerInformation,
    .initializeStreamConfiguration = LiInitializeStreamConfiguration,
    .initializeVideoCallbacks = LiInitializeVideoCallbacks,
    .initializeAudioCallbacks = LiInitializeAudioCallbacks,
    .initializeConnectionCallbacks = LiInitializeConnectionCallbacks,
    .startConnection = LiStartConnection,
    .stopConnection = LiStopConnection,
    .interruptConnection = LiInterruptConnection,
    .getStageName = LiGetStageName,
    .getLaunchUrlQueryParameters = LiGetLaunchUrlQueryParameters,
    .waitForNextVideoFrame = LiWaitForNextVideoFrame,
    .wakeWaitForVideoFrame = LiWakeWaitForVideoFrame,
    .completeVideoFrame = LiCompleteVideoFrame,
    .requestIdrFrame = LiRequestIdrFrame,
    .sendMultiControllerEvent = LiSendMultiControllerEvent,
    .getEstimatedRttInfo = LiGetEstimatedRttInfo,
    .sendControllerArrivalEvent = LiSendControllerArrivalEvent,
    .sendControllerTouchEvent = LiSendControllerTouchEvent,
    .sendControllerMotionEvent = LiSendControllerMotionEvent,
    .sendControllerBatteryEvent = LiSendControllerBatteryEvent,
    .logMessage = slotLog,
};
