#import "DictateObjC.h"
BOOL DictateTryObjC(void (NS_NOESCAPE ^block)(void), NSError **error) {
    @try {
        block();
        return YES;
    } @catch (NSException *exception) {
        if (error) {
            *error = [NSError errorWithDomain:@"DictateObjC" code:1 userInfo:@{
                @"name": exception.name,
                @"reason": exception.reason ?: @"",
                NSLocalizedDescriptionKey: [NSString stringWithFormat:@"%@: %@", exception.name, exception.reason ?: @""]
            }];
        }
        return NO;
    }
}

#import <math.h>
static void dictate_exception(NSError **error, NSException *exception) {
    if (error) *error = [NSError errorWithDomain:@"DictateNativeAudio" code:1 userInfo:@{
        @"exceptionName": exception.name, NSLocalizedDescriptionKey: exception.reason ?: @"native audio exception"}];
}
static void dictate_audio_error(NSError **error, NSString *reason) {
    if (error) *error = [NSError errorWithDomain:@"DictateNativeAudio" code:3
        userInfo:@{NSLocalizedDescriptionKey: reason}];
}
static BOOL dictate_valid_format(AVAudioFormat *format) {
    return format && isfinite(format.sampleRate) && format.sampleRate > 0 && format.sampleRate <= 384000
        && format.channelCount > 0 && format.channelCount <= 32;
}
AVAudioFormat *dictate_pcm_format(AVAudioCommonFormat commonFormat, double rate,
    AVAudioChannelCount channels, BOOL interleaved, NSError **error) {
    @try {
        if (!isfinite(rate) || rate <= 0 || rate > 384000 || channels == 0 || channels > 32) {
            dictate_audio_error(error, @"invalid PCM format"); return nil;
        }
        AVAudioFormat *format = [[AVAudioFormat alloc] initWithCommonFormat:commonFormat sampleRate:rate
            channels:channels interleaved:interleaved];
        if (!format) dictate_audio_error(error, @"PCM format unavailable");
        return format;
    } @catch (NSException *exception) { dictate_exception(error, exception); return nil; }
}
AVAudioPCMBuffer *dictate_pcm_buffer(AVAudioFormat *format, AVAudioFrameCount capacity, NSError **error) {
    @try {
        if (!dictate_valid_format(format) || capacity == 0 || capacity > 2000000) {
            dictate_audio_error(error, @"invalid PCM buffer capacity or format"); return nil;
        }
        AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:format frameCapacity:capacity];
        if (!buffer) dictate_audio_error(error, @"PCM buffer unavailable");
        return buffer;
    } @catch (NSException *exception) { dictate_exception(error, exception); return nil; }
}
AVAudioConverter *dictate_audio_converter(AVAudioFormat *from, AVAudioFormat *to, NSError **error) {
    @try {
        if (!dictate_valid_format(from) || !dictate_valid_format(to)) {
            dictate_audio_error(error, @"invalid converter format"); return nil;
        }
        AVAudioConverter *converter = [[AVAudioConverter alloc] initFromFormat:from toFormat:to];
        if (!converter) dictate_audio_error(error, @"audio converter unavailable");
        return converter;
    } @catch (NSException *exception) { dictate_exception(error, exception); return nil; }
}
AVAudioConverterOutputStatus dictate_convert_audio(AVAudioConverter *converter, AVAudioPCMBuffer *output,
    AVAudioConverterInputBlock input, NSError **error) {
    @try {
        NSError *conversionError = nil;
        AVAudioConverterOutputStatus status = [converter convertToBuffer:output error:&conversionError withInputFromBlock:input];
        if (conversionError || status == AVAudioConverterOutputStatus_Error) {
            if (conversionError) { if (error) *error = conversionError; }
            else dictate_audio_error(error, @"audio conversion failed");
            return AVAudioConverterOutputStatus_Error;
        }
        return status;
    } @catch (NSException *exception) {
        dictate_exception(error, exception); return AVAudioConverterOutputStatus_Error;
    }
}

BOOL dictate_rig_start(AVAudioEngine *engine, AVAudioPlayerNode *player, AVAudioFormat *format, UInt32 device, NSError **error) {
    @try {
        [engine attachNode:player];
        if (![engine.outputNode.AUAudioUnit setDeviceID:device error:error]) return NO;
        [engine connect:player to:engine.mainMixerNode format:format];
        [engine prepare];
        return [engine startAndReturnError:error];
    } @catch (NSException *exception) { dictate_exception(error, exception); return NO; }
}
BOOL dictate_rig_schedule_play(AVAudioPlayerNode *player, AVAudioPCMBuffer *buffer, AVAudioPlayerNodeCompletionHandler completion, NSError **error) {
    @try {
        [player scheduleBuffer:buffer atTime:nil options:0 completionCallbackType:AVAudioPlayerNodeCompletionDataPlayedBack completionHandler:completion];
        [player play]; return YES;
    } @catch (NSException *exception) { dictate_exception(error, exception); return NO; }
}
BOOL dictate_rig_stop(AVAudioEngine *engine, AVAudioPlayerNode *player, NSError **error) {
    BOOL ok = YES;
    @try { [player stop]; } @catch (NSException *exception) { dictate_exception(error, exception); ok = NO; }
    @try { [engine stop]; } @catch (NSException *exception) { if (ok) dictate_exception(error, exception); ok = NO; }
    return ok;
}
@interface DictateThrowingConverter : AVAudioConverter
@end
@implementation DictateThrowingConverter
- (AVAudioConverterOutputStatus)convertToBuffer:(AVAudioPCMBuffer *)output error:(NSError **)error withInputFromBlock:(AVAudioConverterInputBlock)input {
    [NSException raise:@"DictateForcedConvert" format:@"offline exception control"];
    return AVAudioConverterOutputStatus_Error;
}
@end
AVAudioConverter *dictate_throwing_converter(AVAudioFormat *from, AVAudioFormat *to) { return [[DictateThrowingConverter alloc] initFromFormat:from toFormat:to]; }
