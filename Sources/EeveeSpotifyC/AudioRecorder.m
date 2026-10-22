// AudioRecorder.m - captures Spotify's decoded audio by hooking AudioUnitRender
// (audiounit) or by attaching AudioUnitAddRenderNotify (alternate).
//
// Why this version exists: the inline hook (MSHookFunction) can only patch code when the process
// has JIT / a debugger attached. Without it MSHookFunction returned no trampoline and a SECOND call
// crashed the app. Now: probe first, try at most once per process, leave a crash marker so a crash
// inside the hook is never repeated, and always explain the failure in the log and in LastError.
//
// The alternate method is a JIT-free path: instead of interposing a global symbol, we attach a
// render-notify callback to the AudioUnit Spotify already uses. Same AudioBufferList, same ring
// buffer, same writer thread — only the entry point changes.

#import <AudioToolbox/AudioToolbox.h>
#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <stdatomic.h>
#import <pthread.h>
#import <dlfcn.h>
#import <errno.h>
#import <math.h>
#import <unistd.h>
#import <stdio.h>
#import <string.h>
#import <sys/sysctl.h>
#import <sys/mman.h>
#import <mach/mach.h>
#import <mach-o/dyld.h>
#import <mach-o/getsect.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "EVRecorderInternal.h"

#if __has_include(<ptrauth.h>)
#import <ptrauth.h>
#import "../../modules/fishhook/fishhook.h"
#endif

#ifndef MAP_JIT
#define MAP_JIT 0x800
#endif
#ifndef P_TRACED
#define P_TRACED 0x00000800
#endif
#define EV_CS_DEBUGGED 0x10000000u
extern int csops(pid_t pid, unsigned int ops, void *useraddr, size_t usersize);

NSString *const EeveeRecorderStateDidChangeNotification = @"EeveeRecorderStateDidChangeNotification";
NSString *const EeveeRecorderDidFinishNotification = @"EeveeRecorderDidFinishNotification";

#define CALLER_FILTER "libEmbeddedSystemAUs.dylib"   // comment out to capture every caller
#define RING_SAMPLES (4u * 1024u * 1024u)            // power of two
#define WRITE_CHUNK 8192u
#define BATCH_FRAMES 2048u
#define WAV_MAX_BYTES 0xFFFFF000ull
#define MIN_FREE_BYTES (300ull * 1024 * 1024)
#define MIN_FREE_STOP_BYTES (150ull * 1024 * 1024)   // lower than the start threshold, so a recording cannot start and stop at once

typedef OSStatus (*RenderFunction)(AudioUnit, AudioUnitRenderActionFlags *, const AudioTimeStamp *,
                                   UInt32, UInt32, AudioBufferList *);
typedef void (*MSHookFunctionType)(void *symbol, void *replace, void **result);


#pragma mark - State

static RenderFunction originalRender;
static _Atomic(int) hookState;               // 0 untried, 1 installed, 2 failed (never retried)
static NSString *hookMode = @"none";
static NSString *hookError;
static NSString *lastErrorText;
static pthread_mutex_t ctlLock = PTHREAD_MUTEX_INITIALIZER;

static float ring[RING_SAMPLES];
static _Atomic(uint64_t) writeIndex, readIndex;
static _Atomic(bool) capturing, sessionActive, finalizing, formatReady, abortFlag;
static _Atomic(uint32_t) sampleRate = 44100, fmtChannels, fmtBits, mismatchRate;
static _Atomic(bool) fmtIsFloat;
static _Atomic(uint64_t) framesCaptured, statCalls, statMatched, statCaptured, statDropped, statBadLayout;
static _Atomic(uint32_t) peakBits;
static _Atomic(uintptr_t) callerStart, callerEnd, lastRejectedCaller;
static _Atomic(uint32_t) lastAsbdID, lastAsbdFlags, lastAsbdBits, lastAsbdChannels, lastAsbdRate;
static _Atomic(int32_t) lastAsbdStatus;

static pthread_t writerThread;
static bool threadStarted;
static FILE *outputFile;
static NSString *outputPath;
static NSURL *sessionDir, *sessionWav;
static NSDate *sessionStart;
static uint64_t writtenFramesTotal;
static NSMutableArray<EVMarker *> *markers;
static NSString *lastSessionSummary = @"";

static NSObject *evSync(void) {
    static NSObject *o; static dispatch_once_t t;
    dispatch_once(&t, ^{ o = [NSObject new]; });
    return o;
}
static void setLastError(NSString *s) { @synchronized(evSync()) { lastErrorText = [s copy]; } }
NSString *EeveeAudioRecorderLastError(void) { @synchronized(evSync()) { return lastErrorText; } }

// ---- Capture method selection ----
// "audiounit" installs the MSHookFunction-based AudioUnitRender interposer (needs JIT).
// "alternate" attaches AudioUnitAddRenderNotify to the AudioUnit Spotify already uses
// (JIT-free). If alternate cannot attach, we record a reason and fall back to audiounit.
static _Atomic(bool) captureFallbackUsed;
static NSString *captureFallbackReason;

static NSString *evCaptureSelectedMethod(void) {
    NSString *s = EVSettingString(@"captureMethod", @"bmtaptap");
    if (![s isKindOfClass:[NSString class]] || s.length == 0) return @"audiounit";
    if (![s isEqualToString:@"audiounit"]
        && ![s isEqualToString:@"alternate"]
        && ![s isEqualToString:@"converter"]
        && ![s isEqualToString:@"pump"]
        && ![s isEqualToString:@"bmtaptap"]) return @"audiounit";
    return s;
}

static void evPostState(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:EeveeRecorderStateDidChangeNotification object:nil];
    });
}
static uint64_t evNowMs(void) {
    struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000ull + (uint64_t)ts.tv_nsec / 1000000ull;
}

uint64_t EVCoreFramesCaptured(void) { return atomic_load_explicit(&framesCaptured, memory_order_relaxed); }
uint32_t EVCoreSampleRate(void) { return atomic_load_explicit(&sampleRate, memory_order_relaxed); }
NSString *EVCoreActiveSessionPath(void) { return atomic_load(&sessionActive) ? sessionDir.path : nil; }

#pragma mark - WAV header

static void put16(uint8_t *p, uint16_t v) { p[0] = v & 255; p[1] = (v >> 8) & 255; }
static void put32(uint8_t *p, uint32_t v) {
    p[0] = v & 255; p[1] = (v >> 8) & 255; p[2] = (v >> 16) & 255; p[3] = (v >> 24) & 255;
}

// Always float32 stereo. Rewrites the header, then returns to the end so appending continues.
static void writeWAVHeader(FILE *f, uint32_t rate, uint64_t bytes) {
    uint8_t h[44] = {0};
    if (bytes > WAV_MAX_BYTES) bytes = WAV_MAX_BYTES;
    memcpy(h, "RIFF", 4);
    put32(h + 4, (uint32_t)(36 + bytes));
    memcpy(h + 8, "WAVEfmt ", 8);
    put32(h + 16, 16);
    put16(h + 20, 3);
    put16(h + 22, 2);
    put32(h + 24, rate);
    put32(h + 28, rate * 8);
    put16(h + 32, 8);
    put16(h + 34, 32);
    memcpy(h + 36, "data", 4);
    put32(h + 40, (uint32_t)bytes);
    fseeko(f, 0, SEEK_SET);
    fwrite(h, 1, sizeof(h), f);
    fflush(f);
    fseeko(f, 0, SEEK_END);
}

#pragma mark - Caller filter (no dladdr on the audio thread)

static uintptr_t stripPAC(void *p) {
#if __has_feature(ptrauth_calls)
    return (uintptr_t)ptrauth_strip(p, ptrauth_key_return_address);
#else
    return (uintptr_t)p;
#endif
}

static void refreshCallerRange(void) {
#ifdef CALLER_FILTER
    if (atomic_load(&callerEnd)) return;
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (!name || !strstr(name, CALLER_FILTER)) continue;
        const struct mach_header_64 *hdr = (const struct mach_header_64 *)_dyld_get_image_header(i);
        if (!hdr) continue;
        unsigned long size = 0;
        uint8_t *seg = getsegmentdata(hdr, "__TEXT", &size);
        if (!seg || !size) continue;
        atomic_store(&callerStart, (uintptr_t)seg);
        atomic_store_explicit(&callerEnd, (uintptr_t)seg + size, memory_order_release);
        EVI("Hook", @"caller filter resolved: %s [%p - %p]", name, seg, seg + size);
        return;
    }
#endif
}

static bool targetCaller(uintptr_t address) {
#ifdef CALLER_FILTER
    uintptr_t end = atomic_load_explicit(&callerEnd, memory_order_acquire);
    if (!end) return false;
    return address >= atomic_load_explicit(&callerStart, memory_order_relaxed) && address < end;
#else
    (void)address; return true;
#endif
}

#pragma mark - Format

static bool readASBD(AudioUnit unit, AudioStreamBasicDescription *asbd, OSStatus *st) {
    UInt32 size = sizeof(*asbd);
    *st = AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, asbd, &size);
    return *st == noErr;
}

static void inspectFormat(AudioUnit unit) {
    if (atomic_load_explicit(&formatReady, memory_order_relaxed)) return;
    AudioStreamBasicDescription asbd = {0};
    OSStatus st;
    bool ok = readASBD(unit, &asbd, &st);
    atomic_store(&lastAsbdStatus, (int32_t)st);
    if (!ok) return;
    atomic_store(&lastAsbdID, asbd.mFormatID);
    atomic_store(&lastAsbdFlags, asbd.mFormatFlags);
    atomic_store(&lastAsbdBits, asbd.mBitsPerChannel);
    atomic_store(&lastAsbdChannels, asbd.mChannelsPerFrame);
    atomic_store(&lastAsbdRate, (uint32_t)asbd.mSampleRate);
    bool isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0;
    bool bitsOK = isFloat ? asbd.mBitsPerChannel == 32 : asbd.mBitsPerChannel == 16;
    if (asbd.mFormatID == kAudioFormatLinearPCM && bitsOK && asbd.mChannelsPerFrame >= 1 &&
        asbd.mChannelsPerFrame <= 2 && asbd.mSampleRate >= 8000 && asbd.mSampleRate <= 192000) {
        atomic_store(&fmtChannels, asbd.mChannelsPerFrame);
        atomic_store(&fmtBits, asbd.mBitsPerChannel);
        atomic_store(&fmtIsFloat, isFloat);
        atomic_store(&sampleRate, (uint32_t)asbd.mSampleRate);
        atomic_store_explicit(&formatReady, true, memory_order_release);
    }
}

// A changed sample rate (e.g. Bluetooth connected) would corrupt timing, so it aborts the session.
static void recheckRate(AudioUnit unit) {
    AudioStreamBasicDescription asbd = {0};
    OSStatus st;
    if (!readASBD(unit, &asbd, &st)) return;
    uint32_t r = (uint32_t)asbd.mSampleRate;
    if (r && r != atomic_load_explicit(&sampleRate, memory_order_relaxed)) {
        atomic_store(&mismatchRate, r);
        atomic_store(&abortFlag, true);
    }
}

// Converter variant: format comes from the AudioConverter, not from an AU.




#pragma mark - Ring buffer (realtime side)

static bool pushSamples(const float *samples, uint32_t count) {
    if (!samples || !count || count > RING_SAMPLES) return false;
    uint64_t w = atomic_load_explicit(&writeIndex, memory_order_relaxed);
    uint64_t r = atomic_load_explicit(&readIndex, memory_order_acquire);
    if (w - r + count > RING_SAMPLES) {          // never overwrite what the writer is reading
        atomic_fetch_add_explicit(&statDropped, 1, memory_order_relaxed);
        return false;
    }
    float peak = 0;
    for (uint32_t i = 0; i < count; i++) { float a = fabsf(samples[i]); if (a > peak) peak = a; }
    uint32_t pos = (uint32_t)(w & (RING_SAMPLES - 1));
    uint32_t first = RING_SAMPLES - pos;
    if (first > count) first = count;
    memcpy(ring + pos, samples, first * sizeof(float));
    if (count > first) memcpy(ring, samples + first, (count - first) * sizeof(float));
    atomic_store_explicit(&writeIndex, w + count, memory_order_release);
    uint32_t cur = atomic_load_explicit(&peakBits, memory_order_relaxed), nb;
    float curf; memcpy(&curf, &cur, 4);
    if (peak > curf) { memcpy(&nb, &peak, 4); atomic_store_explicit(&peakBits, nb, memory_order_relaxed); }
    return true;
}

static inline float readSample(const void *base, uint32_t index, bool isFloat) {
    if (isFloat) return ((const float *)base)[index];
    return ((const int16_t *)base)[index] * (1.0f / 32768.0f);
}

static void captureBuffers(AudioBufferList *list, UInt32 frames) {
    if (!list || !frames || list->mNumberBuffers < 1) return;
    uint32_t bits = atomic_load_explicit(&fmtBits, memory_order_relaxed);
    bool isFloat = atomic_load_explicit(&fmtIsFloat, memory_order_relaxed);
    uint32_t bytesPer = bits / 8;
    if (!bytesPer) return;

    const void *left = NULL, *right = NULL;
    uint32_t stride = 1, available = 0;
    const AudioBuffer *b0 = &list->mBuffers[0];
    if (list->mNumberBuffers == 1 && b0->mNumberChannels == 2 && b0->mData) {
        left = b0->mData; right = (const uint8_t *)b0->mData + bytesPer; stride = 2;
        available = b0->mDataByteSize / (bytesPer * 2);
    } else if (list->mNumberBuffers == 1 && b0->mNumberChannels == 1 && b0->mData) {
        left = right = b0->mData; available = b0->mDataByteSize / bytesPer;
    } else if (list->mNumberBuffers >= 2 && b0->mNumberChannels == 1 &&
               list->mBuffers[1].mNumberChannels == 1 && b0->mData && list->mBuffers[1].mData) {
        left = b0->mData; right = list->mBuffers[1].mData;
        uint32_t aL = b0->mDataByteSize / bytesPer, aR = list->mBuffers[1].mDataByteSize / bytesPer;
        available = aL < aR ? aL : aR;
    } else {
        atomic_fetch_add_explicit(&statBadLayout, 1, memory_order_relaxed);
        return;
    }
    if (frames > available) frames = available;

    float temp[BATCH_FRAMES * 2];
    uint32_t i0 = 0;
    while (frames) {
        uint32_t batch = frames > BATCH_FRAMES ? BATCH_FRAMES : frames;
        for (uint32_t i = 0; i < batch; i++) {
            uint32_t idx = (i0 + i) * stride;
            temp[i * 2] = readSample(left, idx, isFloat);
            temp[i * 2 + 1] = readSample(right, idx, isFloat);
        }
        if (pushSamples(temp, batch * 2))
            atomic_fetch_add_explicit(&framesCaptured, batch, memory_order_relaxed);
        i0 += batch; frames -= batch;
    }
    atomic_fetch_add_explicit(&statCaptured, 1, memory_order_relaxed);
}


// ============================================================
// LIVE BASS VISUALIZER (FFT)
// ============================================================
#include <Accelerate/Accelerate.h>

static _Atomic(float) currentBassLevel = 0.0f;
float EVGetCurrentBassLevel(void) { return atomic_load_explicit(&currentBassLevel, memory_order_relaxed); }

static FFTSetup fftSetup = NULL;
static DSPSplitComplex splitComplex;
static float *fftWindow = NULL;
static vDSP_Length fftLog2n = 10; // 1024 samples
static vDSP_Length fftN = 1024;

static void initFFT() {
    if (fftSetup) return;
    fftSetup = vDSP_create_fftsetup(fftLog2n, kFFTRadix2);
    splitComplex.realp = malloc(fftN / 2 * sizeof(float));
    splitComplex.imagp = malloc(fftN / 2 * sizeof(float));
    fftWindow = malloc(fftN * sizeof(float));
    vDSP_hann_window(fftWindow, fftN, vDSP_HANN_NORM);
}

static void updateBassLevel(const float *samples, uint32_t frames) {
    if (frames < 1024) return; // Need enough samples for 1024-point FFT
    initFFT();

    // Copy, window, and interleave to mono for FFT
    float mono[1024];
    vDSP_vadd(samples, 2, samples + 1, 2, mono, 1, fftN); // L + R
    vDSP_vmul(mono, 1, fftWindow, 1, mono, 1, fftN);

    // Pack real signal into split complex
    vDSP_ctoz((DSPComplex *)mono, 2, &splitComplex, 1, fftN / 2);

    // Perform FFT
    vDSP_fft_zrip(fftSetup, &splitComplex, 1, fftLog2n, FFT_FORWARD);

    // Calculate magnitudes
    float magnitudes[512];
    vDSP_zvabs(&splitComplex, 1, magnitudes, 1, fftN / 2);

    // Sum the first few bins (bass frequencies)
    float bassSum = 0;
    for (int i = 1; i < 5; i++) {
        bassSum += magnitudes[i];
    }

    // Normalize and smooth
    float newLevel = bassSum / 50.0f;
    if (newLevel > 1.0f) newLevel = 1.0f;

    float oldLevel = atomic_load_explicit(&currentBassLevel, memory_order_relaxed);
    float smoothed = (oldLevel * 0.8f) + (newLevel * 0.2f);
    atomic_store_explicit(&currentBassLevel, smoothed, memory_order_relaxed);
}
// ============================================================

static OSStatus hookedRender(AudioUnit unit, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *time,
                             UInt32 bus, UInt32 frames, AudioBufferList *data) {
    uintptr_t caller = stripPAC(__builtin_return_address(0));
    RenderFunction orig = originalRender;
    OSStatus status = orig ? orig(unit, flags, time, bus, frames, data) : kAudioUnitErr_Uninitialized;
    uint64_t n = atomic_fetch_add_explicit(&statCalls, 1, memory_order_relaxed);
    if (status == noErr && atomic_load_explicit(&capturing, memory_order_relaxed)) {
        if (targetCaller(caller)) {
            atomic_fetch_add_explicit(&statMatched, 1, memory_order_relaxed);
            inspectFormat(unit);
            if (atomic_load_explicit(&formatReady, memory_order_acquire)) {
                if ((n & 511) == 511) recheckRate(unit);
                captureBuffers(data, frames);
            }
        } else {
            atomic_store_explicit(&lastRejectedCaller, caller, memory_order_relaxed);
        }
    }
    return status;
}


#pragma mark - Environment / hook installation

static void evEnvProbe(uint32_t *cs, BOOL *debugged, BOOL *traced, BOOL *mapJit, int *jitErrno) {
    *cs = 0; *debugged = NO; *traced = NO; *mapJit = NO; *jitErrno = 0;
    if (csops(getpid(), 0, cs, sizeof(*cs)) == 0) *debugged = (*cs & EV_CS_DEBUGGED) != 0;
    struct kinfo_proc info; memset(&info, 0, sizeof info);
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()};
    size_t sz = sizeof info;
    if (sysctl(mib, 4, &info, &sz, NULL, 0) == 0) *traced = (info.kp_proc.p_flag & P_TRACED) != 0;
    void *p = mmap(NULL, 16384, PROT_READ | PROT_WRITE | PROT_EXEC, MAP_PRIVATE | MAP_ANON | MAP_JIT, -1, 0);
    if (p == MAP_FAILED) { *jitErrno = errno; }
    else { *mapJit = YES; munmap(p, 16384); }
}

static NSString *evHookMarkerPath(void) {
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    return [docs stringByAppendingPathComponent:@".evhook_attempt"];
}

static BOOL failHook(NSString *msg) {
    hookError = [msg copy];
    atomic_store(&hookState, 2);
    setLastError(msg);
    EVE("Hook", @"FAILED: %@", msg);
    return NO;
}


// ============================================================================
// Pump hook + fishhook converter fallback (patched)
// ============================================================================
#define EV_PUMP_FILE_OFFSET 0x10326a6a8u
#define EV_PUMP_PROLOGUE    0xD10203FFu

struct EVPumpResult { uint64_t lo, hi; };
typedef struct EVPumpResult (*EVPumpFn)(void *, void *, size_t *, void *, void *, int);
static EVPumpFn origPump;

static struct EVPumpResult hookPump(void *provider, void *outBuf, size_t *outBytes,
                                     void *ioData, void *param5, int flags) {
    struct EVPumpResult r = origPump(provider, outBuf, outBytes, ioData, param5, flags);
    if (!EeveeAudioRecorderIsRecording() || !outBuf || !outBytes || *outBytes == 0) return r;
    size_t bytes = *outBytes;
    if ((bytes & 3u) != 0) return r;
    uint32_t floats = (uint32_t)(bytes >> 2);
    if ((floats & 1u) != 0) floats &= ~1u;
    if (floats > RING_SAMPLES / 2) floats = RING_SAMPLES / 2;
    if (floats) pushSamples((const float *)outBuf, floats);
    return r;
}

static uintptr_t evSpotifySlide(void) {
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (!name) continue;
        size_t nlen = strlen(name);
        if ((nlen >= 8 && strcmp(name + nlen - 8, "/Spotify") == 0) ||
            (nlen >= 15 && strcmp(name + nlen - 15, "/Spotify.dylib") == 0)) {
            return _dyld_get_image_vmaddr_slide(i);
        }
    }
    return 0;
}

static BOOL installPumpHook(void) {
    uintptr_t slide = evSpotifySlide();
    if (!slide) {
        EVW("Pump", @"could not locate Spotify image");
        return NO;
    }
    void *target = (void *)(slide + EV_PUMP_FILE_OFFSET);
    uint32_t prologue = *(volatile uint32_t *)target;
    if (prologue != EV_PUMP_PROLOGUE) {
        EVW("Pump", @"unexpected prologue @ %p: 0x%08x (want 0x%08x) - skip",
            target, prologue, EV_PUMP_PROLOGUE);
        return NO;
    }
    typedef int (*inline_hook_t)(void *, void *, void **);
    inline_hook_t ink = (inline_hook_t)dlsym(RTLD_DEFAULT, "inline_hook");
    if (ink) {
        void *orig = NULL;
        if (ink(target, (void *)hookPump, &orig) == 0 && orig) {
            origPump = (EVPumpFn)orig;
            hookMode = @"pump(inline_hook)";
            EVI("Pump", @"installed inline_hook @ %p -> orig %p", target, orig);
            return YES;
        }
        EVW("Pump", @"inline_hook failed for %p", target);
    }
    MSHookFunctionType ms = (MSHookFunctionType)dlsym(RTLD_DEFAULT, "MSHookFunction");
    if (ms) {
        void *orig = NULL;
        ms(target, (void *)hookPump, &orig);
        if (orig) {
            origPump = (EVPumpFn)orig;
            hookMode = @"pump(MSHookFunction)";
            EVI("Pump", @"installed MSHookFunction @ %p -> orig %p", target, orig);
            return YES;
        }
        EVW("Pump", @"MSHookFunction returned no trampoline for %p", target);
    }
    return NO;
}

static OSStatus (*origFillComplex)(
    AudioConverterRef, UInt32 *, AudioConverterComplexInputDataProc,
    void *, AudioBufferList *, AudioStreamPacketDescription *);

static OSStatus hookFillComplex(
    AudioConverterRef conv, UInt32 *ioPackets,
    AudioConverterComplexInputDataProc proc, void *ud,
    AudioBufferList *ioData, AudioStreamPacketDescription *outPackDesc)
{
    OSStatus st = origFillComplex(conv, ioPackets, proc, ud, ioData, outPackDesc);
    if (st != noErr || !EeveeAudioRecorderIsRecording() || !ioData || !ioPackets) return st;
    if (*ioPackets == 0) return st;

    if (ioData->mNumberBuffers == 1
        && ioData->mBuffers[0].mNumberChannels == 2
        && ioData->mBuffers[0].mData) {
        AudioBuffer *b = &ioData->mBuffers[0];
        uint32_t frames = *ioPackets;
        uint64_t floats = (uint64_t)frames * 2u;
        uint64_t maxFloats = (uint64_t)(b->mDataByteSize / sizeof(float));
        if (floats > maxFloats) floats = maxFloats;
        floats &= ~1ull;
        if (floats > RING_SAMPLES / 2) floats = RING_SAMPLES / 2;
        if (floats) pushSamples((const float *)b->mData, (uint32_t)floats);
    } else if (ioData->mNumberBuffers >= 2
               && ioData->mBuffers[0].mNumberChannels == 1
               && ioData->mBuffers[1].mNumberChannels == 1
               && ioData->mBuffers[0].mData
               && ioData->mBuffers[1].mData) {
        AudioBuffer *L = &ioData->mBuffers[0];
        AudioBuffer *R = &ioData->mBuffers[1];
        uint32_t nFrames = *ioPackets;
        uint32_t availL  = L->mDataByteSize / sizeof(float);
        uint32_t availR  = R->mDataByteSize / sizeof(float);
        if (nFrames > availL) nFrames = availL;
        if (nFrames > availR) nFrames = availR;
        if (nFrames > RING_SAMPLES / 4) nFrames = RING_SAMPLES / 4;
        float temp[2048 * 2];
        const float *l = L->mData, *r = R->mData;
        while (nFrames) {
            uint32_t batch = nFrames > 2048 ? 2048 : nFrames;
            for (uint32_t i = 0; i < batch; i++) {
                temp[i * 2]     = l[i];
                temp[i * 2 + 1] = r[i];
            }
            pushSamples(temp, batch * 2);
            l += batch; r += batch; nFrames -= batch;
        }
    }
    return st;
}

// ---------------------------------------------------------------------------
// BM tap hook: swizzle BMSampleBufferAudioTap::processAudioBufferList:sampleRate:
// Spotify's own audio sink. Fires with the exact AudioBufferList that is
// about to be fed to the visualizer / watch-feed pipeline. No JIT needed:
// class_replaceMethod works in any process.
// ---------------------------------------------------------------------------
typedef void (*BMTapProcessFn)(id, SEL, AudioBufferList *, double);
static BMTapProcessFn origBMTapProcess;
static BOOL bmTapInstalled;

static void hookBMTapProcess(id self, SEL _cmd, AudioBufferList *abl, double sr) {
    if (origBMTapProcess) origBMTapProcess(self, _cmd, abl, sr);
    if (!atomic_load_explicit(&capturing, memory_order_relaxed)) return;
    if (!abl || abl->mNumberBuffers == 0) return;

    if (!atomic_load_explicit(&formatReady, memory_order_acquire)) {
        bool ok = false;
        if (abl->mNumberBuffers == 1 && abl->mBuffers[0].mNumberChannels == 2 && abl->mBuffers[0].mData)
            ok = true;
        else if (abl->mNumberBuffers >= 2
                 && abl->mBuffers[0].mNumberChannels == 1
                 && abl->mBuffers[1].mNumberChannels == 1
                 && abl->mBuffers[0].mData && abl->mBuffers[1].mData)
            ok = true;
        if (ok) {
            atomic_store(&fmtChannels, 2);
            atomic_store(&fmtBits, 32);
            atomic_store(&fmtIsFloat, true);
            atomic_store(&sampleRate, (uint32_t)sr);
            atomic_store_explicit(&formatReady, true, memory_order_release);
            EVI("BMtap", @"format locked: rate=%.0f bufs=%u ch=%u", sr,
                abl->mNumberBuffers, abl->mBuffers[0].mNumberChannels);
        }
    }
    if (!atomic_load_explicit(&formatReady, memory_order_acquire)) return;

    uint32_t bytesPer = 4, frames = 0;
    if (abl->mNumberBuffers == 1 && abl->mBuffers[0].mNumberChannels == 2) {
        frames = (uint32_t)(abl->mBuffers[0].mDataByteSize / (bytesPer * 2));
    } else if (abl->mNumberBuffers >= 2) {
        uint32_t aL = (uint32_t)(abl->mBuffers[0].mDataByteSize / bytesPer);
        uint32_t aR = (uint32_t)(abl->mBuffers[1].mDataByteSize / bytesPer);
        frames = aL < aR ? aL : aR;
    }
    if (frames == 0) return;

    uint64_t n = atomic_fetch_add_explicit(&statCalls, 1, memory_order_relaxed);
    atomic_fetch_add_explicit(&statMatched, 1, memory_order_relaxed);
    if ((n & 511) == 511) {
        uint32_t r = (uint32_t)sr;
        if (r && r != atomic_load_explicit(&sampleRate, memory_order_relaxed)) {
            atomic_store(&mismatchRate, r);
            atomic_store(&abortFlag, true);
        }
    }
    captureBuffers(abl, frames);
}

static BOOL installBMTapHook(void) {
    if (bmTapInstalled) return YES;
    Class cls = NSClassFromString(@"BMSampleBufferAudioTap");
    if (!cls) return failHook(@"BMSampleBufferAudioTap class not found.");
    SEL sel = NSSelectorFromString(@"processAudioBufferList:sampleRate:");
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return failHook(@"BMSampleBufferAudioTap has no processAudioBufferList:sampleRate:.");
    origBMTapProcess = (BMTapProcessFn)method_getImplementation(m);
    class_replaceMethod(cls, sel, (IMP)hookBMTapProcess, method_getTypeEncoding(m));
    bmTapInstalled = YES;
    hookMode = @"bmtaptap";
    EVI("Hook", @"swizzled BMSampleBufferAudioTap::processAudioBufferList:sampleRate: (orig=%p)",
        (void *)origBMTapProcess);
    return YES;
}

static BOOL installConverterHookOnce(void) {
    if (origFillComplex) return YES;
    struct rebinding b = {
        "AudioConverterFillComplexBuffer",
        (void *)hookFillComplex,
        (void **)&origFillComplex
    };
    int r = rebind_symbols(&b, 1);
    if (r != 0 || !origFillComplex) {
        return failHook(@"fishhook on AudioConverterFillComplexBuffer failed");
    }
    hookMode = @"converter(fishhook)";
    EVI("Hook", @"installed via fishhook (converter/pre-EQ)");
    return YES;
}

static BOOL installHookOnce(void) {
    int st = atomic_load(&hookState);
    if (st == 1) return YES;
    if (st == 2) {
        setLastError(hookError);
        EVW("Hook", @"hook already failed in this process (%@); not retrying (a retry used to crash the app)", hookError);
        return NO;
    }

    uint32_t cs; BOOL debugged, traced, mapJit; int jitErrno;
    evEnvProbe(&cs, &debugged, &traced, &mapJit, &jitErrno);
    BOOL jitOK = debugged || traced || mapJit;
    BOOL force = EVSettingBool(@"forceInline", NO);
    EVI("Hook", @"code-signing flags=0x%08x CS_DEBUGGED=%d P_TRACED=%d MAP_JIT=%d(errno %d) => JIT-capable=%d force=%d",
        cs, debugged, traced, mapJit, jitErrno, jitOK, force);

    NSString *marker = evHookMarkerPath();
    if ([[NSFileManager defaultManager] fileExistsAtPath:marker] && !force)
        return failHook(@"A previous inline-hook attempt never finished (the app died inside the hook). Not trying again. "
                        @"Enable JIT, then turn on 'Force inline hook' in Recorder debug to retry.");

    void *target = dlsym(RTLD_DEFAULT, "AudioUnitRender");
    if (!target) return failHook(@"AudioUnitRender symbol not found.");
    MSHookFunctionType ms = (MSHookFunctionType)dlsym(RTLD_DEFAULT, "MSHookFunction");
    if (!ms) return failHook(@"MSHookFunction is not available in this process (no Substrate shim).");
    if (!jitOK && !force)
        return failHook(@"No JIT: this process cannot patch code, so the audio hook cannot be installed. "
                        @"Launch LiveContainer with JIT enabled (e.g. via StikDebug) and try again.");

    Dl_info di = {0}; dladdr(target, &di);
    EVI("Hook", @"AudioUnitRender=%p in %s; calling MSHookFunction (crash marker armed)", target, di.dli_fname ?: "?");
    [@"attempt\n" writeToFile:marker atomically:YES encoding:NSUTF8StringEncoding error:nil];
    EVLogFlush();                                    // make sure this line survives a crash
    originalRender = NULL;
    ms(target, (void *)hookedRender, (void **)&originalRender);
    [[NSFileManager defaultManager] removeItemAtPath:marker error:nil];

    if (!originalRender)
        return failHook(@"MSHookFunction returned no trampoline (the patch was refused).");
    hookMode = @"inline(MSHookFunction)";
    atomic_store(&hookState, 1);
    EVI("Hook", @"installed via %@, original/trampoline=%p", hookMode, (void *)originalRender);
    return YES;
}

static void evLogEnvironment(void) {
    char machine[64] = {0}; size_t sz = sizeof machine;
    sysctlbyname("hw.machine", machine, &sz, NULL, 0);
    NSDictionary *fs = [[NSFileManager defaultManager] attributesOfFileSystemForPath:NSHomeDirectory() error:nil];
    task_vm_info_data_t vi; mach_msg_type_number_t cnt = TASK_VM_INFO_COUNT;
    double footprintMB = task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&vi, &cnt) == KERN_SUCCESS
        ? vi.phys_footprint / 1048576.0 : -1;
    EVI("Env", @"device=%s iOS=%@ pid=%d process=%@ bundle=%@ build=%s %s", machine,
        UIDevice.currentDevice.systemVersion, getpid(), NSProcessInfo.processInfo.processName,
        NSBundle.mainBundle.bundleIdentifier, __DATE__, __TIME__);
    EVI("Env", @"free disk=%.1f GB, app memory=%.0f MB, low-power=%d, thermal=%ld",
        [fs[NSFileSystemFreeSize] doubleValue] / 1e9, footprintMB,
        NSProcessInfo.processInfo.isLowPowerModeEnabled, (long)NSProcessInfo.processInfo.thermalState);
    AVAudioSession *s = [AVAudioSession sharedInstance];
    NSMutableArray *outs = [NSMutableArray array];
    for (AVAudioSessionPortDescription *p in s.currentRoute.outputs)
        [outs addObject:[NSString stringWithFormat:@"%@(%@)", p.portName, p.portType]];
    EVI("Env", @"audio session: category=%@ mode=%@ sampleRate=%.0f outputs=%@", s.category, s.mode, s.sampleRate, outs);
}

#pragma mark - Alternate capture (render-notify)

// The alternate is a JIT-free entry point into the same audio pipeline:
// AudioUnitAddRenderNotify fires *after* the AU renders, handing us the exact
// AudioBufferList that hookedRender used to see, without patching any code.

static AudioUnit altUnit;
static _Atomic(bool) altInstalled;
static NSString *altFailReason;

// Called on Spotify's audio thread. Do NOT allocate / lock here.
static OSStatus evAltRenderNotify(void *refCon,
                                  AudioUnitRenderActionFlags *flags,
                                  const AudioTimeStamp *ts,
                                  UInt32 bus,
                                  UInt32 frames,
                                  AudioBufferList *data)
{
    if (!flags || !(*flags & kAudioUnitRenderAction_PostRender)) return noErr;
    if (!data || !frames) return noErr;
    if (!atomic_load_explicit(&capturing, memory_order_relaxed)) return noErr;

    AudioUnit unit = (AudioUnit)refCon;
    if (!atomic_load_explicit(&formatReady, memory_order_acquire))
        inspectFormat(unit);                    // safe: reads AU property
    if (atomic_load_explicit(&formatReady, memory_order_acquire)) {
        if (frames >= 1024 && data->mNumberBuffers > 0
            && data->mBuffers[0].mNumberChannels == 1
            && data->mBuffers[0].mData) {
            updateBassLevel((const float *)data->mBuffers[0].mData, frames);
        }

        uint64_t n = atomic_fetch_add_explicit(&statCalls, 1, memory_order_relaxed);
        atomic_fetch_add_explicit(&statMatched, 1, memory_order_relaxed);
        if ((n & 511) == 511) recheckRate(unit);
        captureBuffers(data, frames);
    }
    return noErr;
}

static BOOL evInstallAlternate(AudioUnit unit) {
    if (!unit) return NO;
    if (atomic_load(&altInstalled)) {
        if (altUnit == unit) return YES;
        // If it's a different unit, the old one is already stopped/dead.
        // Do NOT call RemoveRenderNotify here; hookAudioOutputUnitStop handles it.
        atomic_store(&altInstalled, false);
        altUnit = NULL;
    }
    OSStatus st = AudioUnitAddRenderNotify(unit, evAltRenderNotify, (void *)unit);
    if (st != noErr) {
        @synchronized(evSync()) {
            altFailReason = [NSString stringWithFormat:
                @"AudioUnitAddRenderNotify failed (OSStatus %d).", (int)st];
        }
        EVW("Alt", @"%@", altFailReason);
        return NO;
    }
    altUnit = unit;
    atomic_store(&altInstalled, true);
    EVI("Alt", @"render-notify installed on AU %p", (void *)unit);
    return YES;
}

static void evRemoveAlternate(void) {
    if (atomic_load(&altInstalled) && altUnit) {
        AudioUnitRemoveRenderNotify(altUnit, evAltRenderNotify, (void *)altUnit);
        atomic_store(&altInstalled, false);
        altUnit = NULL;
    }
}

// Verify `val` is a heap-allocated, readable, non-executable pointer.
// AudioUnit handles always satisfy this; ObjC object pointers, code
// pointers, and zeroed __TEXT bytes do not.
static bool evIsPlausibleAudioUnit(uintptr_t val) {
    if (!val || (val & 0x7) != 0) return false;
    // Reject any pointer that resolves inside a loaded image (__TEXT or __DATA).
    // AudioUnit handles are heap allocations, so an image-internal pointer here
    // is always a spurious ivar (code pointer, zeroed __DATA slot, etc).
    Dl_info di = {0};
    if (dladdr((void *)val, &di) && di.dli_fname) return false;
    // Reject if the first word is null. AudioUnitGetProperty reads it as a
    // dispatch-table pointer and branches through it; a null first word
    // produces EXC_BAD_ACCESS at pc=0 inside AudioToolboxCore.
    if (!*(volatile uintptr_t *)val) return false;
    return true;
}

// Walk an object's ivars looking for an AudioUnit (probe with a real property read).
static AudioUnit evFindAudioUnit(id obj) {
    if (!obj) return NULL;
    Class cls = object_getClass(obj);
    while (cls && cls != [NSObject class]) {
        unsigned n = 0;
        Ivar *iv = class_copyIvarList(cls, &n);
        for (unsigned i = 0; i < n; i++) {
            const char *enc = ivar_getTypeEncoding(iv[i]);
            if (!enc || (enc[0] != '@' && enc[0] != '^')) continue;
            uintptr_t val = *(uintptr_t *)((uint8_t *)(__bridge void *)obj + ivar_getOffset(iv[i]));
            if (!val) continue;
            // Second guard: verify val is actually in a readable heap region
            // before we hand it to a CoreAudio function that will dereference it.
            if (!evIsPlausibleAudioUnit(val)) continue;
            AudioStreamBasicDescription asbd = {0};
            UInt32 sz = sizeof(asbd);
            OSStatus st = AudioUnitGetProperty((AudioUnit)val,
                                               kAudioUnitProperty_StreamFormat,
                                               kAudioUnitScope_Output, 0, &asbd, &sz);
            if (st == noErr) {
                EVI("Alt", @"found AU %p on %s.%s (rate=%.0f ch=%u)",
                    (void *)val, class_getName(cls), ivar_getName(iv[i]),
                    asbd.mSampleRate, asbd.mChannelsPerFrame);
                free(iv);
                return (AudioUnit)val;
            }
        }
        free(iv);
        cls = class_getSuperclass(cls);
    }
    return NULL;
}

#pragma mark - Writer thread

static void evPersistMarkers(void) {
    if (!sessionDir) return;
    NSMutableArray *list = [NSMutableArray array];
    @synchronized(evSync()) {
        for (EVMarker *m in markers)
            [list addObject:@{@"frame": @(m.frame), @"partialStart": @(m.partialStart), @"info": m.info ? [m.info dictionary] : @{}}];
    }
    NSDictionary *root = @{@"rate": @(EVCoreSampleRate()), @"startedAt": @([sessionStart timeIntervalSince1970]), @"markers": list};
    NSData *d = [NSJSONSerialization dataWithJSONObject:root options:NSJSONWritingPrettyPrinted error:nil];
    [d writeToURL:[sessionDir URLByAppendingPathComponent:@"markers.json"] atomically:YES];
}

static void evOnTrack(EVTrackInfo *info, uint64_t frame, BOOL partial) {
    EVMarker *m = [EVMarker new];
    m.frame = frame; m.info = info; m.partialStart = partial;
    @synchronized(evSync()) { [markers addObject:m]; }
    uint32_t r = EVCoreSampleRate();
    EVI("Meta", @"track marker at frame %llu (%@): '%@' - '%@' [album '%@', #%ld, expected %.3fs, partialStart=%d]",
        (unsigned long long)frame, EVFormatTime((double)frame / r), info.artist, info.title, info.album,
        (long)info.trackNumber, info.duration, partial);
    evPersistMarkers();
}

static void *writerMain(void *unused) {
    (void)unused;
    float temp[WRITE_CHUNK];
    uint64_t written = 0;
    uint64_t lastStat = evNowMs(), lastHdr = lastStat, lastCaller = lastStat;
    uint64_t lastDiskCheck = lastStat;
    uint64_t prevCalls = 0, prevCaptured = 0, prevFramesRef = 0;
    int silentStreak = 0; bool silenceWarned = false, abortHandled = false;

    for (;;) {
        uint64_t r = atomic_load_explicit(&readIndex, memory_order_relaxed);
        uint64_t w = atomic_load_explicit(&writeIndex, memory_order_acquire);
        if (r < w) {
            uint32_t count = (uint32_t)(w - r);
            if (count > WRITE_CHUNK) count = WRITE_CHUNK;

            // Never write beyond the classic WAV payload limit.
            if (written >= WAV_MAX_BYTES) {
                if (!abortHandled) {
                    abortHandled = true;
                    setLastError(@"Recording reached the 4 GB WAV limit and was stopped; the captured audio is being saved.");
                    EVW("Writer", @"4 GB WAV payload limit reached - stopping");
                    atomic_store(&capturing, false);
                    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                        EeveeAudioRecorderStop();
                    });
                }
                break;
            }

            uint64_t remainingSamples =
                (WAV_MAX_BYTES - written) / sizeof(float);
            if (count > remainingSamples)
                count = (uint32_t)remainingSamples;
            if (!count) {
                atomic_store(&capturing, false);
                dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                    EeveeAudioRecorderStop();
                });
                break;
            }

            uint32_t pos = (uint32_t)(r & (RING_SAMPLES - 1));
            uint32_t first = RING_SAMPLES - pos;
            if (first > count) first = count;
            memcpy(temp, ring + pos, first * sizeof(float));
            if (count > first) memcpy(temp + first, ring, (count - first) * sizeof(float));
            size_t done = fwrite(temp, sizeof(float), count, outputFile);
            if (done < count) {
                if (!abortHandled) {
                    abortHandled = true;
                    setLastError([NSString stringWithFormat:@"Disk write failed (errno %d). Is storage full?", errno]);
                    EVE("Writer", @"fwrite short (%zu/%u), errno=%d - stopping", done, count, errno);
                    atomic_store(&capturing, false);
                    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ EeveeAudioRecorderStop(); });
                }
            }
            written += done * sizeof(float);
            atomic_store_explicit(&readIndex, r + (done ? done : count), memory_order_release);
            if (written >= WAV_MAX_BYTES && !abortHandled) {
                abortHandled = true;
                setLastError(@"Recording reached the 4 GB WAV limit and was stopped; the captured audio is being saved.");
                EVW("Writer", @"4 GB WAV payload limit reached - stopping");
                atomic_store(&capturing, false);
                dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                    EeveeAudioRecorderStop();
                });
                break;
            }
        } else if (!atomic_load(&capturing)) {
            break;
        } else {
            usleep(5000);
        }

        uint64_t now = evNowMs();

        // Leave a storage reserve so recording cannot fill the device.
        if (now - lastDiskCheck >= 2000) {
            lastDiskCheck = now;
            @autoreleasepool {
                NSDictionary *fs = [[NSFileManager defaultManager]
                    attributesOfFileSystemForPath:NSHomeDirectory()
                    error:nil];
                uint64_t freeBytes =
                    [fs[NSFileSystemFreeSize] unsignedLongLongValue];

                if (freeBytes < MIN_FREE_STOP_BYTES && !abortHandled) {
                    abortHandled = true;
                    setLastError([NSString stringWithFormat:
                        @"Recording stopped to protect storage: only %.0f MB remain. Captured audio is being saved.",
                        (double)freeBytes / (1024.0 * 1024.0)]);
                    EVW("Writer",
                        @"free storage dropped below %.0f MB - stopping safely",
                        (double)MIN_FREE_STOP_BYTES / (1024.0 * 1024.0));
                    atomic_store(&capturing, false);
                    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                        EeveeAudioRecorderStop();
                    });
                }
            }
        }

        if (atomic_load(&abortFlag) && !abortHandled) {
            abortHandled = true;
            uint32_t nr = atomic_load(&mismatchRate);
            setLastError([NSString stringWithFormat:@"Sample rate changed %u -> %u Hz mid-recording (output route changed?). Recording stopped; the audio so far is saved.",
                          EVCoreSampleRate(), nr]);
            EVE("Writer", @"sample rate changed %u -> %u - stopping", EVCoreSampleRate(), nr);
            atomic_store(&capturing, false);
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ EeveeAudioRecorderStop(); });
        }
        if (now - lastCaller >= 500) { lastCaller = now; refreshCallerRange(); }
        if (now - lastHdr >= 2000) { lastHdr = now; writeWAVHeader(outputFile, EVCoreSampleRate(), written); }  // file stays playable after a crash
        if (now - lastStat >= 2000) {
            lastStat = now;
            uint64_t calls = atomic_load(&statCalls), cap = atomic_load(&statCaptured), frames = EVCoreFramesCaptured();
            uint32_t pk = atomic_exchange(&peakBits, 0); float peak; memcpy(&peak, &pk, 4);
            double fill = (double)(atomic_load(&writeIndex) - atomic_load(&readIndex)) * 100.0 / RING_SAMPLES;
            double rate = EVCoreSampleRate() ? EVCoreSampleRate() : 44100;
            EVI("Stats", @"calls=%llu(+%llu) matched=%llu captured=%llu(+%llu) dropped=%llu badLayout=%llu | rec=%@ file=%.1fMB ring=%.1f%% peak=%.3f",
                (unsigned long long)calls, (unsigned long long)(calls - prevCalls), (unsigned long long)atomic_load(&statMatched),
                (unsigned long long)cap, (unsigned long long)(cap - prevCaptured), (unsigned long long)atomic_load(&statDropped),
                (unsigned long long)atomic_load(&statBadLayout), EVFormatTime(frames / rate), written / 1048576.0, fill, peak);
            if (calls > prevCalls && frames > prevFramesRef) {
                if (peak <= 0.0f) { if (++silentStreak >= 3 && !silenceWarned) { silenceWarned = true; EVW("Stats", @"audio is arriving but it is digital silence for 6 s+ (muted? DRM? wrong unit?)"); } }
                else silentStreak = 0;
            }
            if (calls > 0 && atomic_load(&statMatched) == 0) {
                uintptr_t a = atomic_load(&lastRejectedCaller); Dl_info di = {0};
                if (a && dladdr((void *)a, &di) && di.dli_fname)
                    EVW("Stats", @"render calls arrive but none match the caller filter; last caller image: %s", di.dli_fname);
            }
            if (atomic_load(&statMatched) > 0 && !atomic_load(&formatReady))
                EVW("Stats", @"format rejected: status=%d id=0x%x flags=0x%x bits=%u ch=%u rate=%u",
                    atomic_load(&lastAsbdStatus), atomic_load(&lastAsbdID), atomic_load(&lastAsbdFlags),
                    atomic_load(&lastAsbdBits), atomic_load(&lastAsbdChannels), atomic_load(&lastAsbdRate));
            prevCalls = calls; prevCaptured = cap; prevFramesRef = frames;
        }
    }

    writeWAVHeader(outputFile, EVCoreSampleRate(), written);
    fclose(outputFile);
    outputFile = NULL;
    writtenFramesTotal = written / 8;
    EVI("Writer", @"closed %@: %llu frames = %@ (%llu bytes)", sessionWav.lastPathComponent,
        (unsigned long long)writtenFramesTotal, EVFormatTime((double)writtenFramesTotal / EVCoreSampleRate()),
        (unsigned long long)written);
    return NULL;
}

#pragma mark - Public API

static BOOL evFail(NSString *msg) {
    setLastError(msg);
    EVE("Core", @"Start failed: %@", msg);
    return NO;
}

// Steal the AudioUnit handle when Spotify starts playback
static OSStatus (*origAudioOutputUnitStart)(AudioUnit unit);
static OSStatus (*origAudioOutputUnitStop)(AudioUnit unit);

static OSStatus hookAudioOutputUnitStart(AudioUnit unit) {
    if (EeveeAudioRecorderIsRecording()) {
        if (!atomic_load(&altInstalled) || altUnit != unit) {
            evInstallAlternate(unit);
        }
    }
    return origAudioOutputUnitStart(unit);
}

static OSStatus hookAudioOutputUnitStop(AudioUnit unit) {
    // Safely detach BEFORE the OS destroys the unit
    if (atomic_load(&altInstalled) && altUnit == unit) {
        AudioUnitRemoveRenderNotify(altUnit, evAltRenderNotify, (void *)altUnit);
        atomic_store(&altInstalled, false);
        altUnit = NULL;
    }
    return origAudioOutputUnitStop(unit);
}

static BOOL evTryAlternate(void) {
    if (atomic_load(&altInstalled)) return YES;

    Class cls = NSClassFromString(@"SPTAudioDriverImplementation");
    if (cls) {
        for (NSString *sel in @[@"sharedInstance", @"sharedDriver", @"defaultDriver"]) {
            SEL s = NSSelectorFromString(sel);
            if (![cls respondsToSelector:s]) continue;
            id inst = ((id (*)(id, SEL))objc_msgSend)(cls, s);
            AudioUnit u = evFindAudioUnit(inst);
            if (u && evInstallAlternate(u)) return YES;
        }
    }

    // If that fails, hook AudioOutputUnitStart to grab the AU handle dynamically
    if (!origAudioOutputUnitStart) {
        struct rebinding b_start = {
            "AudioOutputUnitStart",
            (void *)hookAudioOutputUnitStart,
            (void **)&origAudioOutputUnitStart
        };
        struct rebinding b_stop = {
            "AudioOutputUnitStop",
            (void *)hookAudioOutputUnitStop,
            (void **)&origAudioOutputUnitStop
        };
        if (rebind_symbols(&b_start, 1) == 0 && origAudioOutputUnitStart &&
            rebind_symbols(&b_stop, 1) == 0 && origAudioOutputUnitStop) {
            EVI("Alt", @"Hooked AudioOutputUnitStart and Stop.");
        } else {
            EVW("Alt", @"Failed to hook AudioOutputUnit lifecycle.");
            return NO;
        }
    }

    // Return YES so the recorder doesn't fall back to the crashing inline hook.
    return YES;
}

// Route the start request to the selected capture method. If alternate was chosen
// but could not attach, record why and fall back to the inline hook.
static BOOL evEnsureCaptureReady(void) {
    NSString *sel = evCaptureSelectedMethod();

    if ([sel isEqualToString:@"auto"]) {
        if (installPumpHook())          return YES;
        if (installConverterHookOnce()) return YES;
        return installHookOnce();
    }
    if ([sel isEqualToString:@"bmtaptap"])  return installBMTapHook();
    if ([sel isEqualToString:@"pump"])      return installPumpHook();
    if ([sel isEqualToString:@"converter"]) return installConverterHookOnce();
    if ([sel isEqualToString:@"audiounit"]) return installHookOnce();

    // alternate selected
    if (evTryAlternate()) return YES;

    @synchronized(evSync()) {
        if (!captureFallbackReason) {
            captureFallbackReason = altFailReason ?: @"Alternate capture could not attach to Spotify's AudioUnit.";
        }
    }
    atomic_store(&captureFallbackUsed, true);
    EVW("Core", @"alternate refused: %@; falling back to AudioUnitRender.", captureFallbackReason);
    return installHookOnce();
}

static BOOL evStartLocked(void) {
    if (atomic_load(&sessionActive)) return YES;
    if (atomic_load(&finalizing))
        return evFail(@"The previous recording is still being finalized. Wait for track saving to finish.");
    setLastError(nil);
    EVI("Core", @"Start requested");
    evLogEnvironment();
    if (!evEnsureCaptureReady()) return NO;

    NSDictionary *fs = [[NSFileManager defaultManager] attributesOfFileSystemForPath:NSHomeDirectory() error:nil];
    if ([fs[NSFileSystemFreeSize] unsignedLongLongValue] < MIN_FREE_BYTES)
        return evFail(@"Less than 300 MB of free storage.");

    NSDateFormatter *df = [NSDateFormatter new];
    df.dateFormat = @"yyyy-MM-dd_HH-mm-ss";
    df.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    NSURL *dir = [EVRecordingsRoot() URLByAppendingPathComponent:[df stringFromDate:[NSDate date]] isDirectory:YES];
    NSError *err = nil;
    if (![[NSFileManager defaultManager] createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:&err])
        return evFail([NSString stringWithFormat:@"Cannot create folder: %@", err.localizedDescription]);
    NSURL *wav = [dir URLByAppendingPathComponent:@"session.wav"];
    FILE *f = fopen(wav.path.fileSystemRepresentation, "wb");
    if (!f) return evFail([NSString stringWithFormat:@"Cannot open %@ (errno %d)", wav.path, errno]);
    writeWAVHeader(f, 44100, 0);

    sessionDir = dir; sessionWav = wav; sessionStart = [NSDate date];
    outputPath = wav.path; outputFile = f; writtenFramesTotal = 0;
    @synchronized(evSync()) { markers = [NSMutableArray array]; }
    atomic_store(&writeIndex, 0); atomic_store(&readIndex, 0);
    atomic_store(&formatReady, false); atomic_store(&abortFlag, false);
    atomic_store(&sampleRate, 44100); atomic_store(&framesCaptured, 0);
    atomic_store(&statCalls, 0); atomic_store(&statMatched, 0); atomic_store(&statCaptured, 0);
    atomic_store(&statDropped, 0); atomic_store(&statBadLayout, 0); atomic_store(&peakBits, 0);
    refreshCallerRange();
    atomic_store(&capturing, true);
    atomic_store(&sessionActive, true);

    int rc = pthread_create(&writerThread, NULL, writerMain, NULL);
    if (rc != 0) {
        atomic_store(&capturing, false); atomic_store(&sessionActive, false);
        fclose(outputFile); outputFile = NULL;
        return evFail([NSString stringWithFormat:@"Writer thread failed (%d)", rc]);
    }
    threadStarted = true;
    EVMetaStart(^(EVTrackInfo *info, uint64_t frame, BOOL partial) { evOnTrack(info, frame, partial); });
    EVI("Core", @"recording to %@", wav.path);
    return YES;
}

BOOL EeveeAudioRecorderStart(void) {
    pthread_mutex_lock(&ctlLock);
    BOOL ok = evStartLocked();
    pthread_mutex_unlock(&ctlLock);
    evPostState();
    return ok;
}

void EeveeAudioRecorderStop(void) {
    pthread_mutex_lock(&ctlLock);
    if (!atomic_load(&sessionActive)) { pthread_mutex_unlock(&ctlLock); return; }
    EVI("Core", @"Stop requested");
    atomic_store(&capturing, false);
    evRemoveAlternate();
    EVMetaStop();
    if (threadStarted) { pthread_join(writerThread, NULL); threadStarted = false; }
    NSURL *wav = sessionWav;
    uint64_t total = writtenFramesTotal;
    uint32_t rate = EVCoreSampleRate();
    NSArray<EVMarker *> *snapshot; @synchronized(evSync()) { snapshot = [markers copy]; }
    evPersistMarkers();
    atomic_store(&finalizing, true);
    atomic_store(&sessionActive, false);
    pthread_mutex_unlock(&ctlLock);
    evPostState();

    EVI("Core", @"splitting %lu marker(s) over %@", (unsigned long)snapshot.count, EVFormatTime((double)total / rate));
    EVFinalizeSession(wav, rate, snapshot, total, ^(NSArray<NSURL *> *files, NSURL *folder, NSArray<NSDictionary *> *tracks, NSString *error) {
        NSURL *first = files.firstObject;
        if (first) outputPath = first.path;
        lastSessionSummary = [NSString stringWithFormat:@"%lu track(s) in %@", (unsigned long)tracks.count, folder.lastPathComponent];
        atomic_store(&finalizing, false);
        evPostState();
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:EeveeRecorderDidFinishNotification object:nil
                userInfo:@{@"files": files ?: @[], @"folder": folder ?: [NSNull null], @"tracks": tracks ?: @[], @"error": error ?: @""}];
        });
    });
}

BOOL EeveeAudioRecorderIsRecording(void) { return atomic_load(&sessionActive); }
NSString *EeveeAudioRecorderCurrentPath(void) { return outputPath; }

NSString *EeveeRecorderStatusLine(void) {
    if (atomic_load(&sessionActive))
        return [NSString stringWithFormat:@"Recording %@", EVFormatTime((double)EVCoreFramesCaptured() / EVCoreSampleRate())];
    if (atomic_load(&finalizing)) return @"Saving tracks…";
    NSString *e = EeveeAudioRecorderLastError();
    if (e.length) return [@"Not recording - " stringByAppendingString:e];
    return lastSessionSummary.length ? [@"Idle - last: " stringByAppendingString:lastSessionSummary] : @"Idle";
}

NSArray<NSString *> *EVCoreDebugLines(void) {
    uint32_t cs; BOOL dbg, trc, jit; int je;
    evEnvProbe(&cs, &dbg, &trc, &jit, &je);
    uint32_t rate = EVCoreSampleRate();
    NSMutableArray *l = [NSMutableArray array];
    [l addObject:[NSString stringWithFormat:@"== Core ==\nbuild %s %s | pid %d", __DATE__, __TIME__, getpid()]];
    [l addObject:[NSString stringWithFormat:@"hook: %@ (state %d) %@", hookMode, atomic_load(&hookState), hookError ? [@"| error: " stringByAppendingString:hookError] : @""]];
    [l addObject:[NSString stringWithFormat:@"alt: installed=%d unit=%p fail=%@",
        atomic_load(&altInstalled), (void *)altUnit, altFailReason ?: @"none"]];
    {
        NSString *__fb = EVCaptureFallbackReason();
        [l addObject:[NSString stringWithFormat:@"capture: selected=%@ active=%@ fallback=%@%@",
            EVCaptureMethodSelected(), EVCaptureMethodActive(),
            atomic_load(&captureFallbackUsed) ? @"yes" : @"no",
            __fb ? [NSString stringWithFormat:@" (%@)", __fb] : @""]];
    }
    [l addObject:[NSString stringWithFormat:@"JIT: CS_DEBUGGED=%d P_TRACED=%d MAP_JIT=%d (cs=0x%08x) force=%d", dbg, trc, jit, cs, EVSettingBool(@"forceInline", NO)]];
    [l addObject:[NSString stringWithFormat:@"last error: %@", EeveeAudioRecorderLastError() ?: @"none"]];
    [l addObject:[NSString stringWithFormat:@"recording: %d | session: %@", atomic_load(&sessionActive), sessionDir.lastPathComponent ?: @"-"]];
    [l addObject:[NSString stringWithFormat:@"format: ready=%d rate=%u bits=%u float=%d ch=%u", atomic_load(&formatReady), rate, atomic_load(&fmtBits), atomic_load(&fmtIsFloat), atomic_load(&fmtChannels)]];
    [l addObject:[NSString stringWithFormat:@"calls=%llu matched=%llu captured=%llu dropped=%llu badLayout=%llu frames=%llu (%@)",
        (unsigned long long)atomic_load(&statCalls), (unsigned long long)atomic_load(&statMatched), (unsigned long long)atomic_load(&statCaptured),
        (unsigned long long)atomic_load(&statDropped), (unsigned long long)atomic_load(&statBadLayout),
        (unsigned long long)EVCoreFramesCaptured(), EVFormatTime((double)EVCoreFramesCaptured() / rate)]];
    [l addObject:[NSString stringWithFormat:@"caller filter: %s resolved=%d",
#ifdef CALLER_FILTER
        CALLER_FILTER,
#else
        "none",
#endif
        atomic_load(&callerEnd) != 0]];
    @synchronized(evSync()) { [l addObject:[NSString stringWithFormat:@"markers: %lu", (unsigned long)markers.count]]; }
    return l;
}

#pragma mark - Audio-driver probe (log only, JIT-free; for finding a hook-free capture point)

static const char *evProbeSels[4] = {"audioDriverWillStartRunning:", "audioDriverDidStartRunning:",
                                     "audioDriverDidStopRunning:", "audioDriverDidClose:"};
static IMP evProbeOrig[4];

static void evProbeDump(id obj, const char *label) {
    if (!obj) { EVI("Probe", @"%s: nil", label); return; }
    Class cls = object_getClass(obj);
    while (cls && cls != [NSObject class]) {
        unsigned n = 0;
        Ivar *iv = class_copyIvarList(cls, &n);
        for (unsigned i = 0; i < n; i++) {
            const char *name = ivar_getName(iv[i]), *enc = ivar_getTypeEncoding(iv[i]);
            NSString *desc = @"?";
            if (enc && enc[0] == '@') { id v = object_getIvar(obj, iv[i]); desc = v ? NSStringFromClass(object_getClass(v)) : @"nil"; }
            else if (enc && enc[0] == '^') { void *p = *(void **)((uint8_t *)(__bridge void *)obj + ivar_getOffset(iv[i])); desc = [NSString stringWithFormat:@"%p", p]; }
            EVI("Probe", @"%s %s.%s type=%s value=%@", label, class_getName(cls), name ?: "?", enc ?: "?", desc);
        }
        free(iv);
        cls = class_getSuperclass(cls);
    }
}

static void evProbeCommon(int idx, id self_, SEL cmd, id arg) {
    // NEVER call NSStringFromClass or evProbeDump on `arg`. Spotify passes
    // raw pointers / AudioUnit handles / Swift values here — not ObjC objects.
    // Doing so triggers libobjc's class_rw_t corruption trap (#brk 0xc473).
	EVI("Probe", @"%s (self=%p arg=%p)", evProbeSels[idx], (__bridge void *)self_, (__bridge void *)arg);
    if (idx == 1) {                                 // audioDriverDidStartRunning:
        evProbeDump(self_, "self");                 // self_ IS SPTAudioDriverImplementation
        if ([evCaptureSelectedMethod() isEqualToString:@"alternate"]) {
            AudioUnit u = evFindAudioUnit(self_);
            if (u) evInstallAlternate(u);
        }
    }
    if (evProbeOrig[idx]) ((void (*)(id, SEL, id))evProbeOrig[idx])(self_, cmd, arg);
}

static void evProbe0(id s, SEL c, id a) { evProbeCommon(0, s, c, a); }
static void evProbe1(id s, SEL c, id a) { evProbeCommon(1, s, c, a); }
static void evProbe2(id s, SEL c, id a) { evProbeCommon(2, s, c, a); }
static void evProbe3(id s, SEL c, id a) { evProbeCommon(3, s, c, a); }

static void evProbeInstall(void) {
    Class cls = NSClassFromString(@"SPTAudioDriverImplementation");
    if (!cls) { EVW("Probe", @"SPTAudioDriverImplementation not found"); return; }
    IMP imps[4] = {(IMP)evProbe0, (IMP)evProbe1, (IMP)evProbe2, (IMP)evProbe3};
    for (int i = 0; i < 4; i++) {
        SEL sel = sel_registerName(evProbeSels[i]);
        Method m = class_getInstanceMethod(cls, sel);
        if (!m) { EVW("Probe", @"%s not found", evProbeSels[i]); continue; }
        IMP inherited = method_getImplementation(m);
        IMP prev = class_replaceMethod(cls, sel, imps[i], method_getTypeEncoding(m));
        evProbeOrig[i] = prev ?: inherited;
        EVI("Probe", @"swizzled %s", evProbeSels[i]);
    }
}

__attribute__((constructor)) static void evCoreInit(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        EVI("Core", @"recorder loaded: build %s %s pid %d", __DATE__, __TIME__, getpid());
        // Probe when explicitly enabled OR when the alternate method is selected
        // (the alternate needs the probe to discover Spotify's AudioUnit).
        BOOL needProbe = EVSettingBool(@"probeDriver", NO)
                      || [evCaptureSelectedMethod() isEqualToString:@"alternate"];
        if (needProbe) evProbeInstall();
        EVResumePendingSessions();
    });
}

#pragma mark - Capture method diagnostics

NSString *EVCaptureMethodSelected(void) { return evCaptureSelectedMethod(); }

NSString *EVCaptureMethodActive(void) {
    if (bmTapInstalled) return @"bmtaptap";
    if (atomic_load(&altInstalled)) return @"alternate";
    if (atomic_load(&hookState) == 1) {
        if ([hookMode isEqualToString:@"inline(converter)"]) return @"converter";
        if ([hookMode hasPrefix:@"pump"]) return @"pump";
        return @"audiounit";
    }
    return @"none";
}

NSString *EVCaptureFallbackReason(void) {
    @synchronized(evSync()) { return captureFallbackReason; }
}
