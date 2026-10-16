// Standalone offline regression. No engines, IO units, speech services or TCC.
#import "DictateObjC.h"
#import <math.h>
@interface ForcedRig : NSObject
@property(nonatomic) BOOL engineStopped;
@end
@implementation ForcedRig
- (void)attachNode:(AVAudioNode *)node { [NSException raise:@"DictateForcedAttach" format:@"offline control"]; }
- (void)scheduleBuffer:(AVAudioPCMBuffer *)buffer atTime:(AVAudioTime *)time options:(AVAudioPlayerNodeBufferOptions)options completionCallbackType:(AVAudioPlayerNodeCompletionCallbackType)type completionHandler:(AVAudioPlayerNodeCompletionHandler)completion {
    [NSException raise:@"DictateForcedSchedule" format:@"offline control"];
}
- (void)stop { self.engineStopped = YES; }
@end
@interface ForcedRigPlayer : ForcedRig
@end
@implementation ForcedRigPlayer
- (void)stop { [NSException raise:@"DictateForcedStop" format:@"offline control"]; }
@end
int main(void) { @autoreleasepool {
    int failures = 0;
    NSError *error = nil;
    for (NSNumber *number in @[@24000, @0, @(-1), @(NAN)]) {
        double rate = number.doubleValue;
        error = nil;
        AVAudioFormat *format = dictate_pcm_format(AVAudioPCMFormatInt16, rate, 1, YES, &error);
        BOOL valid = isfinite(rate) && rate > 0;
        printf("R0 DICTATE_NATIVE rate=%g format=%d error=%d\n", rate, format != nil, error != nil);
        failures += ((format != nil) != valid || (!valid && error == nil));
    }
    for (NSNumber *count in @[@0, @33, @(UINT32_MAX)]) {
        error = nil;
        failures += dictate_pcm_format(AVAudioPCMFormatInt16, 24000, count.unsignedIntValue, YES, &error) != nil || error == nil;
    }
    AVAudioFormat *input = dictate_pcm_format(AVAudioPCMFormatInt16, 24000, 1, YES, &error);
    AVAudioFormat *output = dictate_pcm_format(AVAudioPCMFormatFloat32, 16000, 1, NO, &error);
    for (NSNumber *count in @[@0, @2000001]) {
        error = nil;
        failures += dictate_pcm_buffer(input, count.unsignedIntValue, &error) != nil || error == nil;
    }
    AVAudioPCMBuffer *source = dictate_pcm_buffer(input, 2400, &error);
    source.frameLength = 2400;
    for (int i=0; i<2400; i++) source.int16ChannelData[0][i] = 4000;
    AVAudioPCMBuffer *target = dictate_pcm_buffer(output, 2048, &error);
    AVAudioConverter *converter = dictate_audio_converter(input, output, &error);
    __block BOOL supplied = NO;
    error = nil;
    AVAudioConverterOutputStatus status = dictate_convert_audio(converter, target, ^AVAudioBuffer *(AVAudioPacketCount n, AVAudioConverterInputStatus *outStatus) {
        if (!supplied) { supplied = YES; *outStatus = AVAudioConverterInputStatus_HaveData; return source; }
        *outStatus = AVAudioConverterInputStatus_EndOfStream; return nil;
    }, &error);
    float peak = 0;
    for (int i=0; i<target.frameLength; i++) peak = fmaxf(peak, fabsf(target.floatChannelData[0][i]));
    printf("R0 DICTATE_NATIVE conversion frames=%u peak=%f status=%ld error=%d\n", target.frameLength, peak, (long)status, error != nil);
    failures += status == AVAudioConverterOutputStatus_Error || error != nil || target.frameLength == 0 || peak == 0;
    // Ordinary native error must survive with its domain/code, not become success.
    converter = dictate_audio_converter(input, output, &error);
    AVAudioPCMBuffer *wrong = dictate_pcm_buffer(input, 2400, &error);
    error = nil;
    status = dictate_convert_audio(converter, wrong, ^AVAudioBuffer *(AVAudioPacketCount n, AVAudioConverterInputStatus *s) {
        *s = AVAudioConverterInputStatus_EndOfStream; return nil;
    }, &error);
    printf("R0 DICTATE_NATIVE wrong_format status=%ld error=%ld exception=%d\n", (long)status, (long)error.code, error.userInfo[@"exceptionName"] != nil);
    failures += status != AVAudioConverterOutputStatus_Error || error == nil;
    error = nil;
    status = dictate_convert_audio(dictate_throwing_converter(input, output), target,
        ^AVAudioBuffer *(AVAudioPacketCount n, AVAudioConverterInputStatus *s) { *s = AVAudioConverterInputStatus_EndOfStream; return nil; }, &error);
    printf("R0 DICTATE_NATIVE forced_convert status=%ld exception=%s alive=1\n", (long)status, [error.userInfo[@"exceptionName"] UTF8String]);
    failures += status != AVAudioConverterOutputStatus_Error || ![error.userInfo[@"exceptionName"] isEqual:@"DictateForcedConvert"];
    ForcedRig *fakeEngine = [ForcedRig new];
    ForcedRigPlayer *fakePlayer = [ForcedRigPlayer new];
    error = nil;
    failures += dictate_rig_start((id)fakeEngine, (id)fakePlayer, input, 0, &error) || ![error.userInfo[@"exceptionName"] isEqual:@"DictateForcedAttach"];
    error = nil;
    failures += dictate_rig_schedule_play((id)fakePlayer, source, ^(AVAudioPlayerNodeCompletionCallbackType type) {}, &error) || ![error.userInfo[@"exceptionName"] isEqual:@"DictateForcedSchedule"];
    error = nil;
    failures += dictate_rig_stop((id)fakeEngine, (id)fakePlayer, &error) || ![error.userInfo[@"exceptionName"] isEqual:@"DictateForcedStop"] || !fakeEngine.engineStopped;
    printf("R0 DICTATE_NATIVE rig_exceptions=3 engine_cleanup=%d hardware=0\n", fakeEngine.engineStopped);
    printf("R0 DICTATE_NATIVE failures=%d\n", failures);
    return failures != 0;
} }
