// adi2_midi_helper.c
// Memory-safe, zero-MIKMIDI CoreMIDI helper for RME ADI-2 DAC hardware volume control.
// Replaces Hammerspoon's hs.midi (which has a sleep/wake MIDIPacketListAdd crash in MIKMIDI).
//
// Protocol (stdin -> helper):
//   SET <addr> <idx> <val>\n   -- Send 3-byte parameter container (Command 0x02)
//   SYNC\n                     -- Reset state cache and request full dump (Command 0x03 0x09)
//
// Protocol (helper -> stdout):
//   CONNECTED <model>\n        -- Emitted when ADI-2 DAC CoreMIDI endpoints are bound
//   DISCONNECTED\n             -- Emitted when ADI-2 DAC CoreMIDI endpoints disappear
//   ACTIVE <addr>\n            -- Emitted when active output changes (3=Line, 6=Phones, 9=IEM)
//   PARAM <addr> <idx> <val>\n -- Emitted when volume (idx=12) or mute (idx=15) changes

#include <CoreMIDI/CoreMIDI.h>
#include <CoreFoundation/CoreFoundation.h>
#include <dispatch/dispatch.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static MIDIClientRef gClient = 0;
static MIDIPortRef gInPort = 0;
static MIDIPortRef gOutPort = 0;
static MIDIEndpointRef gSrcEndpoint = 0;
static MIDIEndpointRef gDestEndpoint = 0;

static pthread_mutex_t gStateLock = PTHREAD_MUTEX_INITIALIZER;

// Cached state to suppress redundant 1 Hz heartbeat wakeups in Hammerspoon
static int gActiveAddr = -1;
static int gCachedVol[16];
static int gCachedMute[16];

// Fixed-size SysEx reassembly state (accessed only on CoreMIDI read thread, guarded on reset)
static uint8_t gSysexBuf[1024];
static size_t gSysexLen = 0;
static bool gInSysex = false;

static void resetCacheLocked(void) {
    gActiveAddr = -1;
    for (int i = 0; i < 16; i++) {
        gCachedVol[i] = -99999;
        gCachedMute[i] = -1;
    }
}

static bool endpointMatchesADI2(MIDIEndpointRef ep, char *outName, size_t outSize) {
    if (!ep) return false;
    CFStringRef props[2] = { NULL, NULL };
    MIDIObjectGetStringProperty(ep, kMIDIPropertyModel, &props[0]);
    MIDIObjectGetStringProperty(ep, kMIDIPropertyDisplayName, &props[1]);

    bool matched = false;
    for (int i = 0; i < 2; i++) {
        if (props[i]) {
            char buf[256] = {0};
            if (CFStringGetCString(props[i], buf, sizeof(buf), kCFStringEncodingUTF8)) {
                if (strncmp(buf, "ADI-2 DAC", 9) == 0 || strstr(buf, "ADI-2 DAC") != NULL) {
                    matched = true;
                    if (outName && outSize > 0 && outName[0] == '\0') {
                        snprintf(outName, outSize, "%s", buf);
                    }
                }
            }
            CFRelease(props[i]);
        }
    }
    return matched;
}

static void sendSysexBytes(const uint8_t *data, size_t len) {
    MIDIEndpointRef dest = gDestEndpoint;
    if (!gOutPort || !dest || len == 0 || len > 64) return;

    Byte pktBuf[256];
    MIDIPacketList *pktList = (MIDIPacketList *)pktBuf;
    MIDIPacket *pkt = MIDIPacketListInit(pktList);
    pkt = MIDIPacketListAdd(pktList, sizeof(pktBuf), pkt, 0, len, data);
    if (pkt) {
        MIDISend(gOutPort, dest, pktList);
    }
}

static void requestAllSettings(void) {
    static const uint8_t req[] = { 0xF0, 0x00, 0x20, 0x0D, 0x71, 0x03, 0x09, 0xF7 };
    sendSysexBytes(req, sizeof(req));
}

static void sendChannelParam(int addr, int index, int val) {
    int raw12 = (val < 0) ? (4096 + val) : val;
    if (raw12 < 0) raw12 = 0;
    if (raw12 > 4095) raw12 = 4095;

    uint8_t b1 = (uint8_t)(((addr & 0x0F) << 3) | ((index >> 2) & 0x07));
    uint8_t b2 = (uint8_t)(((index & 0x03) << 5) | ((raw12 >> 7) & 0x1F));
    uint8_t b3 = (uint8_t)(raw12 & 0x7F);

    uint8_t msg[10] = { 0xF0, 0x00, 0x20, 0x0D, 0x71, 0x02, b1, b2, b3, 0xF7 };

    pthread_mutex_lock(&gStateLock);
    if (addr >= 0 && addr < 16) {
        if (index == 12) gCachedVol[addr] = val;
        else if (index == 15) gCachedMute[addr] = (val != 0) ? 1 : 0;
    }
    pthread_mutex_unlock(&gStateLock);

    sendSysexBytes(msg, sizeof(msg));
}

static void handleCompleteSysex(const uint8_t *msg, size_t len) {
    // Minimum valid frame: F0 00 20 0D 71 <cmd> ... F7 (at least 7 bytes)
    if (len < 7) return;
    if (msg[0] != 0xF0 || msg[len - 1] != 0xF7) return;
    if (msg[1] != 0x00 || msg[2] != 0x20 || msg[3] != 0x0D || msg[4] != 0x71) return;

    uint8_t cmd = msg[5];
    if (cmd == 0x01 || cmd == 0x02) {
        // 3-byte parameter containers from index 6 up to len - 1
        for (size_t i = 6; i + 2 < len - 1; i += 3) {
            uint8_t b1 = msg[i];
            uint8_t b2 = msg[i + 1];
            uint8_t b3 = msg[i + 2];
            int addr = (b1 >> 3) & 0x0F;
            if (addr == 3 || addr == 6 || addr == 9) {
                int idx = ((b1 & 0x07) << 2) | ((b2 >> 5) & 0x03);
                int raw12 = ((b2 & 0x1F) << 7) | (b3 & 0x7F);
                int val = (raw12 >= 2048) ? (raw12 - 4096) : raw12;

                if (idx == 12) {
                    bool changed = false;
                    pthread_mutex_lock(&gStateLock);
                    if (gCachedVol[addr] != val) {
                        gCachedVol[addr] = val;
                        changed = true;
                    }
                    pthread_mutex_unlock(&gStateLock);
                    if (changed) {
                        printf("PARAM %d 12 %d\n", addr, val);
                        fflush(stdout);
                    }
                } else if (idx == 15) {
                    int m = (val != 0) ? 1 : 0;
                    bool changed = false;
                    pthread_mutex_lock(&gStateLock);
                    if (gCachedMute[addr] != m) {
                        gCachedMute[addr] = m;
                        changed = true;
                    }
                    pthread_mutex_unlock(&gStateLock);
                    if (changed) {
                        printf("PARAM %d 15 %d\n", addr, m);
                        fflush(stdout);
                    }
                }
            }
        }
    } else if (cmd == 0x07 && len >= 8) {
        int activeOut = msg[6] & 0x03;
        int mappedAddr = (activeOut == 1) ? 6 : ((activeOut == 2) ? 9 : 3);
        bool changed = false;
        pthread_mutex_lock(&gStateLock);
        if (gActiveAddr != mappedAddr) {
            gActiveAddr = mappedAddr;
            changed = true;
        }
        pthread_mutex_unlock(&gStateLock);
        if (changed) {
            printf("ACTIVE %d\n", mappedAddr);
            fflush(stdout);
        }
    }
}

static void midiReadProc(const MIDIPacketList *pktList, void *readProcRefCon, void *srcConnRefCon) {
    (void)readProcRefCon;
    (void)srcConnRefCon;
    if (!pktList) return;

    const MIDIPacket *pkt = &pktList->packet[0];
    for (UInt32 i = 0; i < pktList->numPackets; i++) {
        UInt16 nBytes = pkt->length;
        // Guard against corrupted packet lengths while supporting variable-length SysEx packets
        if (nBytes > 0 && nBytes <= 4096) {
            for (UInt16 j = 0; j < nBytes; j++) {
                uint8_t b = pkt->data[j];
                if (b >= 0xF8) {
                    // Ignore MIDI real-time clock/sense bytes inside SysEx
                    continue;
                }
                if (b == 0xF0) {
                    gSysexBuf[0] = 0xF0;
                    gSysexLen = 1;
                    gInSysex = true;
                } else if (b == 0xF7) {
                    if (gInSysex && gSysexLen < sizeof(gSysexBuf)) {
                        gSysexBuf[gSysexLen++] = 0xF7;
                        handleCompleteSysex(gSysexBuf, gSysexLen);
                    }
                    gInSysex = false;
                    gSysexLen = 0;
                } else if (b & 0x80) {
                    // Unexpected non-SysEx status byte aborts current SysEx cleanly
                    gInSysex = false;
                    gSysexLen = 0;
                } else if (gInSysex) {
                    if (gSysexLen < sizeof(gSysexBuf)) {
                        gSysexBuf[gSysexLen++] = b;
                    } else {
                        // Oversized SysEx; drop safely without overflowing
                        gInSysex = false;
                        gSysexLen = 0;
                    }
                }
            }
        }
        pkt = MIDIPacketNext(pkt);
    }
}

static void refreshEndpoints(void) {
    MIDIEndpointRef foundDest = 0;
    MIDIEndpointRef foundSrc = 0;
    char modelName[256] = {0};

    ItemCount nDest = MIDIGetNumberOfDestinations();
    for (ItemCount i = 0; i < nDest; i++) {
        MIDIEndpointRef ep = MIDIGetDestination(i);
        if (endpointMatchesADI2(ep, modelName, sizeof(modelName))) {
            foundDest = ep;
            break;
        }
    }

    ItemCount nSrc = MIDIGetNumberOfSources();
    for (ItemCount i = 0; i < nSrc; i++) {
        MIDIEndpointRef ep = MIDIGetSource(i);
        if (endpointMatchesADI2(ep, modelName, sizeof(modelName))) {
            foundSrc = ep;
            break;
        }
    }

    if (foundSrc == gSrcEndpoint && foundDest == gDestEndpoint) {
        return;
    }

    if (gSrcEndpoint && gInPort) {
        MIDIPortDisconnectSource(gInPort, gSrcEndpoint);
    }

    gSrcEndpoint = foundSrc;
    gDestEndpoint = foundDest;

    pthread_mutex_lock(&gStateLock);
    resetCacheLocked();
    pthread_mutex_unlock(&gStateLock);

    if (gSrcEndpoint && gDestEndpoint) {
        MIDIPortConnectSource(gInPort, gSrcEndpoint, NULL);
        printf("CONNECTED %s\n", modelName[0] ? modelName : "ADI-2 DAC");
        fflush(stdout);
        requestAllSettings();
    } else {
        printf("DISCONNECTED\n");
        fflush(stdout);
    }
}

static void midiNotifyProc(const MIDINotification *message, void *refCon) {
    (void)refCon;
    if (!message) return;
    switch (message->messageID) {
        case kMIDIMsgSetupChanged:
        case kMIDIMsgObjectAdded:
        case kMIDIMsgObjectRemoved:
            dispatch_async(dispatch_get_main_queue(), ^{
                refreshEndpoints();
            });
            break;
        default:
            break;
    }
}

static void setupStdinReader(void) {
    dispatch_source_t src = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_READ, STDIN_FILENO, 0, dispatch_get_main_queue()
    );
    static char lineBuf[512];
    static size_t lineLen = 0;

    dispatch_source_set_event_handler(src, ^{
        char buf[256];
        ssize_t n = read(STDIN_FILENO, buf, sizeof(buf));
        if (n <= 0) {
            // Parent (Hammerspoon) closed pipe or exited; terminate cleanly
            exit(0);
        }
        for (ssize_t i = 0; i < n; i++) {
            char c = buf[i];
            if (c == '\n') {
                lineBuf[lineLen] = '\0';
                int addr = 0, idx = 0, val = 0;
                if (sscanf(lineBuf, "SET %d %d %d", &addr, &idx, &val) == 3) {
                    if (!gDestEndpoint) refreshEndpoints();
                    sendChannelParam(addr, idx, val);
                } else if (strncmp(lineBuf, "SYNC", 4) == 0) {
                    pthread_mutex_lock(&gStateLock);
                    resetCacheLocked();
                    pthread_mutex_unlock(&gStateLock);
                    if (!gDestEndpoint) refreshEndpoints();
                    else requestAllSettings();
                }
                lineLen = 0;
            } else if (c != '\r' && lineLen + 1 < sizeof(lineBuf)) {
                lineBuf[lineLen++] = c;
            }
        }
    });
    dispatch_resume(src);
}

int main(void) {
    setvbuf(stdout, NULL, _IOLBF, 0);
    resetCacheLocked();

    OSStatus st = MIDIClientCreate(CFSTR("ADI2VolumeHelper"), midiNotifyProc, NULL, &gClient);
    if (st != noErr) {
        fprintf(stderr, "MIDIClientCreate failed: %d\n", (int)st);
        return 1;
    }
    st = MIDIInputPortCreate(gClient, CFSTR("ADI2In"), midiReadProc, NULL, &gInPort);
    if (st != noErr) {
        fprintf(stderr, "MIDIInputPortCreate failed: %d\n", (int)st);
        return 1;
    }
    st = MIDIOutputPortCreate(gClient, CFSTR("ADI2Out"), &gOutPort);
    if (st != noErr) {
        fprintf(stderr, "MIDIOutputPortCreate failed: %d\n", (int)st);
        return 1;
    }

    refreshEndpoints();
    setupStdinReader();

    CFRunLoopRun();
    return 0;
}
