#import <Foundation/Foundation.h>

BOOL DictateTryObjC(void (NS_NOESCAPE ^block)(void), NSError **error)
    __attribute__((swift_error(none)));

#import <AVFoundation/AVFoundation.h>
NS_ASSUME_NONNULL_BEGIN
AVAudioFormat * _Nullable dictate_pcm_format(AVAudioCommonFormat commonFormat, double rate,
    AVAudioChannelCount channels, BOOL interleaved, NSError * _Nullable * _Nullable error);
AVAudioPCMBuffer * _Nullable dictate_pcm_buffer(AVAudioFormat *format, AVAudioFrameCount capacity,
    NSError * _Nullable * _Nullable error);
AVAudioConverter * _Nullable dictate_audio_converter(AVAudioFormat *from, AVAudioFormat *to,
    NSError * _Nullable * _Nullable error);
AVAudioConverterOutputStatus dictate_convert_audio(AVAudioConverter *converter, AVAudioPCMBuffer *output,
    AVAudioConverterInputBlock input, NSError * _Nullable * _Nullable error);

BOOL dictate_rig_start(AVAudioEngine *engine, AVAudioPlayerNode *player, AVAudioFormat *format, UInt32 device, NSError * _Nullable * _Nullable error);
BOOL dictate_rig_schedule_play(AVAudioPlayerNode *player, AVAudioPCMBuffer *buffer, AVAudioPlayerNodeCompletionHandler completion, NSError * _Nullable * _Nullable error);
BOOL dictate_rig_stop(AVAudioEngine *engine, AVAudioPlayerNode *player, NSError * _Nullable * _Nullable error);
AVAudioConverter *dictate_throwing_converter(AVAudioFormat *from, AVAudioFormat *to);
NS_ASSUME_NONNULL_END
// Offline fault seam: caller deliberately chooses whether it is inside a native guard.
void dictate_force_headset_exception(void);
