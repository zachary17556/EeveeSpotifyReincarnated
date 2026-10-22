// EVRecorder.h - public API of the Eevee audio recorder.
// Import this from include/Tweak.h so Swift can call it.
#pragma once
#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

NS_ASSUME_NONNULL_BEGIN

// Posted on the main thread when recording starts, stops or fails.
extern NSString *const EeveeRecorderStateDidChangeNotification;
// Posted on the main thread when the per-track files are written.
// userInfo: files (NSArray<NSURL*>), folder (NSURL), tracks (NSArray<NSDictionary*>), error (NSString, optional)
extern NSString *const EeveeRecorderDidFinishNotification;

// Existing API (unchanged signatures)
BOOL EeveeAudioRecorderStart(void);
void EeveeAudioRecorderStop(void);
BOOL EeveeAudioRecorderIsRecording(void);
NSString * _Nullable EeveeAudioRecorderCurrentPath(void);

// New API
// Persistent recorder preferences. Keys are unprefixed; implementation adds EVRec.
BOOL EVSettingBool(NSString *key, BOOL fallback);
void EVSetSettingBool(NSString *key, BOOL value);
NSInteger EVSettingInt(NSString *key, NSInteger fallback);
void EVSetSettingInt(NSString *key, NSInteger value);
NSString * _Nullable EVSettingString(NSString *key, NSString * _Nullable fallback);
void EVSetSettingString(NSString *key, NSString *value);


// Capture method diagnostics.
//   selected = Settings value ("audiounit" today, "alternate" reserved for a future hook)
//   active   = what is actually installed in this process
//   fallback = non-nil reason when the selected method was refused and AudioUnitRender used instead.
NSString * _Nullable EVCaptureMethodSelected(void);
NSString * _Nullable EVCaptureMethodActive(void);
NSString * _Nullable EVCaptureFallbackReason(void);

NSString * _Nullable EeveeAudioRecorderLastError(void);          // why the last Start failed, nil if none
NSString *EeveeRecorderStatusLine(void);              // short text for a settings row
void EeveeRecorderSetExtraMetadata(NSDictionary * _Nullable md); // title, artist, album, albumArtist, genre, trackNumber, discNumber, year, uri, isrc
NSString * _Nullable EeveeRecorderDebugReport(void);             // main thread only
void EeveeRecorderPresentDebugPanel(void);            // main thread only

NS_ASSUME_NONNULL_END

#ifdef __cplusplus
}
#endif
