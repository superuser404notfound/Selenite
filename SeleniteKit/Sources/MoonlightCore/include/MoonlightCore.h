#pragma once
#include <stdbool.h>
#include <stdint.h>
#include "../../../Vendor/moonlight-common-c/src/Limelight.h"

// One moonlight-common-c copy. MLSlotA and MLSlotB are defined in the MoonlightSlotA/B targets,
// each pointing at its own prefixed copy with its own globals.
typedef struct {
    int slot;
    void (*initializeServerInformation)(PSERVER_INFORMATION serverInfo);
    void (*initializeStreamConfiguration)(PSTREAM_CONFIGURATION streamConfig);
    void (*initializeVideoCallbacks)(PDECODER_RENDERER_CALLBACKS drCallbacks);
    void (*initializeAudioCallbacks)(PAUDIO_RENDERER_CALLBACKS arCallbacks);
    void (*initializeConnectionCallbacks)(PCONNECTION_LISTENER_CALLBACKS clCallbacks);
    int (*startConnection)(PSERVER_INFORMATION serverInfo, PSTREAM_CONFIGURATION streamConfig,
                           PCONNECTION_LISTENER_CALLBACKS clCallbacks, PDECODER_RENDERER_CALLBACKS drCallbacks,
                           PAUDIO_RENDERER_CALLBACKS arCallbacks, void *renderContext, int drFlags,
                           void *audioContext, int arFlags);
    void (*stopConnection)(void);
    void (*interruptConnection)(void);
    const char *(*getStageName)(int stage);
    const char *(*getLaunchUrlQueryParameters)(void);
    bool (*waitForNextVideoFrame)(VIDEO_FRAME_HANDLE *frameHandle, PDECODE_UNIT *decodeUnit);
    void (*wakeWaitForVideoFrame)(void);
    void (*completeVideoFrame)(VIDEO_FRAME_HANDLE handle, int drStatus);
    void (*requestIdrFrame)(void);
    int (*sendMultiControllerEvent)(short controllerNumber, short activeGamepadMask, int buttonFlags,
                                    unsigned char leftTrigger, unsigned char rightTrigger,
                                    short leftStickX, short leftStickY, short rightStickX, short rightStickY);
    bool (*getEstimatedRttInfo)(uint32_t *estimatedRtt, uint32_t *estimatedRttVariance);
    int (*sendControllerArrivalEvent)(uint8_t controllerNumber, uint16_t activeGamepadMask, uint8_t type,
                                      uint32_t supportedButtonFlags, uint16_t capabilities);
    int (*sendControllerTouchEvent)(uint8_t controllerNumber, uint8_t eventType, uint32_t pointerId,
                                    float x, float y, float pressure);
    int (*sendControllerMotionEvent)(uint8_t controllerNumber, uint8_t motionType, float x, float y, float z);
    int (*sendControllerBatteryEvent)(uint8_t controllerNumber, uint8_t batteryState, uint8_t batteryPercentage);
    int (*sendMouseMoveEvent)(short deltaX, short deltaY);
    int (*sendMouseButtonEvent)(char action, int button);
    int (*sendHighResScrollEvent)(short scrollAmount);
    // Variadic logger for CONNECTION_LISTENER_CALLBACKS.logMessage; formats and forwards to the log sink.
    ConnListenerLogMessage logMessage;
} MLSlotAPI;

extern const MLSlotAPI MLSlotA;
extern const MLSlotAPI MLSlotB;

typedef void (*MLLogSink)(int slot, const char *line);
void MLSetLogSink(MLLogSink sink);
MLLogSink MLGetLogSink(void);

// Function-like macros do not import into Swift.
static const int ML_AUDIO_CONFIGURATION_STEREO = AUDIO_CONFIGURATION_STEREO;
static const int ML_SURROUND_AUDIO_INFO_STEREO = SURROUNDAUDIOINFO_FROM_AUDIO_CONFIGURATION(AUDIO_CONFIGURATION_STEREO);
static const int ML_AUDIO_CONFIGURATION_51 = AUDIO_CONFIGURATION_51_SURROUND;
static const int ML_SURROUND_AUDIO_INFO_51 = SURROUNDAUDIOINFO_FROM_AUDIO_CONFIGURATION(AUDIO_CONFIGURATION_51_SURROUND);
