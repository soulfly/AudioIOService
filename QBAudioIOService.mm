//
//  QBAudioManager.m
//  AudioUnit PCM to iLBC converter
//
//  Created by Igor Khomenko on 11/7/13.
//  Copyright (c) 2013 Igor Khomenko. All rights reserved.
//

#import "QBAudioIOService.h"

#import "QBiLBCEncoder.h"
#import "QBiLBCDecoder.h"

#import "QBAudioUtils.h"

#define kOutputBus 0
#define kInputBus 1

#define renderDirectToOutput NO

@implementation QBAudioIOService{
	AudioUnit inputUnit;
    AudioBufferList *inputBuffer;
    
    // iLBC encoder/decoder
    QBiLBCEncoder *g_encoder;
    QBiLBCDecoder *g_decoder;
    //
    AudioBuffer g_outputBuffer;
    //
    dispatch_queue_t encode_queue;
    dispatch_queue_t decode_queue;
}

+ (instancetype)shared
{
	static id instance = nil;
	static dispatch_once_t onceToken;
	
	dispatch_once(&onceToken, ^{
		instance = [[self alloc] init];
	});
	
	return instance;
}

- (id)init
{
    self = [super init];
    if(self){        
        [self initializeAudioSession];
        
        [self checkAudioSource];
        
        if(self.inputAvailable){
            [self setupAudioSession];
            
            [self setupAudioUnits];
            
            [self checkSessionProperties];
            
            // Init iLBC Encoder & Decoder
            //
            [self initiLBCEncoderAndDEcoder];
        }
    }
    return self;
}


#pragma mark
#pragma mark Start/Stop

- (void)start
{
    UInt32 isInputAvailable=0;
	UInt32 size = sizeof(isInputAvailable);
    
	QBCheckError(AudioSessionGetProperty(kAudioSessionProperty_AudioInputAvailable,
                                          &size,
                                          &isInputAvailable), "Couldn't check if input was available");
    
    self->_inputAvailable = isInputAvailable;
    
    NSLog(@"inputAvailable %d", self.inputAvailable);
    
	if (self.inputAvailable > 0) {
		if (!self.running) {
            QBCheckError(AudioOutputUnitStart(inputUnit),
                         "Couldn't start the audio unit");
            self->_running = YES;
		}
	}
}

- (void)stop
{
    if(self.running){
        QBCheckError(AudioOutputUnitStop(inputUnit),
                 "Couldn't stop the audio unit");
        
        self->_running = NO;
    }
}


#pragma mark
#pragma mark Setup Audio Units

- (void)setupAudioUnits
{
    // Create new unit
    //
    AudioComponentDescription inputDescription = {0};
    inputDescription.componentType = kAudioUnitType_Output;
    inputDescription.componentSubType = kAudioUnitSubType_VoiceProcessingIO;
    inputDescription.componentManufacturer = kAudioUnitManufacturer_Apple;
    //
    AudioComponent inputComponent = AudioComponentFindNext(NULL, &inputDescription);
    //
    QBCheckError(AudioComponentInstanceNew(inputComponent, &inputUnit), "Couldn't create the output audio unit");
    
    
    // Enable input 1
    //
    UInt32 one = 1;
    QBCheckError(AudioUnitSetProperty(inputUnit,
                                       kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input,
                                       kInputBus, &one, sizeof(one)),
                 "Couldn't enable IO on the input scope of output unit");
    
    
    // Set Render & Input callback
    //
    AURenderCallbackStruct callbackStruct;
    callbackStruct.inputProc = qbRenderCallback;
    callbackStruct.inputProcRefCon = (__bridge void *)(self);
    QBCheckError(AudioUnitSetProperty(inputUnit,
                                      kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input,
                                      kOutputBus,
                                      &callbackStruct, sizeof(callbackStruct)),
                 "Couldn't set the render callback on the input unit");
    
    callbackStruct.inputProc = qbInputCallback;
    callbackStruct.inputProcRefCon = (__bridge void *)(self);
    QBCheckError(AudioUnitSetProperty(inputUnit,
                                      kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global,
                                      kOutputBus,
                                      &callbackStruct,
                                      sizeof(callbackStruct)), "Couldn't set the callback on the input unit");
    

    /* Set the input audio stream formats */
    AudioStreamBasicDescription audioFormat;
    audioFormat.mSampleRate       = qbSampleRateT;
    audioFormat.mFormatID         = kAudioFormatLinearPCM;
    audioFormat.mFormatFlags      = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
    audioFormat.mFramesPerPacket  = 1;
    audioFormat.mChannelsPerFrame = 1;
    audioFormat.mBitsPerChannel   = 8 * sizeof(AudioSampleType);
    audioFormat.mBytesPerFrame    = audioFormat.mChannelsPerFrame * sizeof(AudioSampleType);
    audioFormat.mBytesPerPacket   = audioFormat.mBytesPerFrame;
    //
    QBCheckError(AudioUnitSetProperty(inputUnit,
                         kAudioUnitProperty_StreamFormat,
                         kAudioUnitScope_Output,
                         kInputBus,
                         &audioFormat,
                         sizeof(audioFormat)), "Couldn't set Stream formay for  Scope_Output");
    //
    QBCheckError(AudioUnitSetProperty(inputUnit,
                         kAudioUnitProperty_StreamFormat,
                         kAudioUnitScope_Input,
                         kOutputBus,
                         &audioFormat,
                         sizeof(audioFormat)), "Couldn't set Stream formay for  Scope_Input");
    
    
    
    // Create input buffer for data from microphone
    //
    self->inputBuffer = (AudioBufferList *)malloc(sizeof(AudioBufferList));
    self->inputBuffer->mNumberBuffers = 1;
    int dataSize = qbBufferFrameSize * sizeof(AudioSampleType);
    self->inputBuffer->mBuffers[0].mNumberChannels = 1;
    self->inputBuffer->mBuffers[0].mDataByteSize = dataSize;
    self->inputBuffer->mBuffers[0].mData = malloc(dataSize);
    memset(self->inputBuffer->mBuffers[0].mData, 0, dataSize);
    
    // Init unit
    //
    QBCheckError(AudioUnitInitialize(inputUnit), "Couldn't initialize the output unit");
}

- (void)releaseAudioUnits
{
    if(inputUnit != NULL){
        [self stop];
        
        AudioUnitUninitialize(inputUnit);
        AudioComponentInstanceDispose(inputUnit);
        
        inputUnit = NULL;
    }
}


#pragma mark
#pragma mark Setup Audio Session

- (void)initializeAudioSession
{
    QBCheckError(AudioSessionInitialize(NULL, NULL, qbSessionInterruptionListener, (__bridge void *)(self)),
                  "Couldn't initialize audio session");
}

- (void)setupAudioSession
{
    UInt32 sessionCategory = kAudioSessionCategory_PlayAndRecord;
    QBCheckError( AudioSessionSetProperty (kAudioSessionProperty_AudioCategory,
                                         sizeof (sessionCategory),
                                         &sessionCategory), "Couldn't set audio category");
    
    UInt32 allowMixing = 1;
    QBCheckError( AudioSessionSetProperty(kAudioSessionProperty_OverrideCategoryMixWithOthers,
                                          sizeof(allowMixing),
                                          &allowMixing), "Couldn't set allow mixing");
    
    
    // Add a property listener, to listen to changes to the session
    QBCheckError( AudioSessionAddPropertyListener(kAudioSessionProperty_AudioRouteChange, qbSessionPropertyListener, (__bridge void *)(self)),
                 "Couldn't add audio session property listener");
    
    // Set the buffer size, this will affect the number of samples that get rendered every time the audio callback is fired
    // A small number will get you lower latency audio, but will make your processor work harder
#if !TARGET_IPHONE_SIMULATOR
    Float32 preferredBufferSize = qbIOBufferDuration; // 0.032000
    QBCheckError( AudioSessionSetProperty(kAudioSessionProperty_PreferredHardwareIOBufferDuration, sizeof(preferredBufferSize), &preferredBufferSize), "Couldn't set the preferred buffer duration");
#endif
    
    Float64 F64sampleRate = qbSampleRateT;
    QBCheckError( AudioSessionSetProperty(kAudioSessionProperty_PreferredHardwareSampleRate, sizeof(F64sampleRate), &F64sampleRate), "Couldn't set the preferred sample rate");
    
    
    // Set the audio session active
    QBCheckError( AudioSessionSetActive(YES), "Couldn't activate the audio session");
}


#pragma mark
#pragma mark Checks source & properties

- (void)checkAudioSource
{
    
    // Check what the incoming audio route is.
    //
    UInt32 propertySize = sizeof(CFStringRef);
    CFStringRef route;
    QBCheckError( AudioSessionGetProperty(kAudioSessionProperty_AudioRoute,
                                          &propertySize,
                                          &route), "Couldn't check the audio route");
    NSLog(@"checkAudioSource: AudioRoute: %@", (NSString *)route);
    CFRelease(route);
    
    
    // Check if there's input available.
    //
    UInt32 isInputAvailable = 0;
    UInt32 size = sizeof(isInputAvailable);
    QBCheckError(AudioSessionGetProperty(kAudioSessionProperty_AudioInputAvailable,
                                         &size,
                                         &isInputAvailable), "Couldn't check if input is available");
    self->_inputAvailable = (BOOL)isInputAvailable;
    NSLog(@"checkAudioSource: Input available: %d", self.inputAvailable);
}

// To be run ONCE per session property change and once on initialization.
- (void)checkSessionProperties
{

    // Check the number of Input channels.
    //
    UInt32 size = sizeof(self.numInputChannels);
    UInt32 newNumChannels;
    QBCheckError(AudioSessionGetProperty(kAudioSessionProperty_CurrentHardwareInputNumberChannels,
                                         &size,
                                         &newNumChannels), "Checking number of input channels");
    self->_numInputChannels = newNumChannels;
    NSLog(@"Audio input channels: %u", (unsigned int)self.numInputChannels);
    
    // We do not handle more than one input channel (iPhone 5, 5C, 5S)
    if(self.numInputChannels > 1){
        self->_numInputChannels = 1;
    }
    
    
    // Check the number of Output channels.
    //
    QBCheckError(AudioSessionGetProperty(kAudioSessionProperty_CurrentHardwareOutputNumberChannels,
                                         &size,
                                         &newNumChannels), "Checking number of output channels");
    self->_numOutputChannels = newNumChannels;
    NSLog(@"Audio output channels: %u", (unsigned int)self.numOutputChannels);
    
    
    // Get the hardware sampling rate.
    //
    Float64 currentSamplingRate;
    size = sizeof(currentSamplingRate);
    QBCheckError(AudioSessionGetProperty(kAudioSessionProperty_CurrentHardwareSampleRate,
                                         &size,
                                         &currentSamplingRate), "Checking hardware sampling rate");
    NSLog(@"Audio hardware sampling rate: %f", currentSamplingRate);
}


#pragma mark
#pragma mark AudioUnit callbacks

OSStatus qbRenderCallback (void						*inRefCon,
                           AudioUnitRenderActionFlags	*ioActionFlags,
                           const AudioTimeStamp 		*inTimeStamp,
                           UInt32						inOutputBusNumber,
                           UInt32						inNumberFrames,
                           AudioBufferList				*ioData)
{
    for (int iBuffer=0; iBuffer < ioData->mNumberBuffers; ++iBuffer) {
        memset(ioData->mBuffers[iBuffer].mData, 0, ioData->mBuffers[iBuffer].mDataByteSize);
    }
    
    
    QBAudioIOService *audioService = (__bridge QBAudioIOService *)inRefCon;
    
    
    // Render
    //
    if(renderDirectToOutput){
        QBCheckError(AudioUnitRender(audioService->inputUnit,
                                     ioActionFlags, inTimeStamp, kInputBus, inNumberFrames,
                                     ioData),
                     "Couldn't render the output unit");
    }else{
        
        // Collect data to render from the callbacks
        //
        if (audioService.outputBlock != nil){
            audioService.outputBlock(ioData->mBuffers[0]);
        }
    }
    
    return noErr;
}

#pragma mark - Render Methods
OSStatus qbInputCallback   (void                         *inRefCon,
                            AudioUnitRenderActionFlags   *ioActionFlags,
                            const AudioTimeStamp         *inTimeStamp,
                            UInt32                       inOutputBusNumber,
                            UInt32                       inNumberFrames,
                            AudioBufferList              *ioData)
{
    QBAudioIOService *audioService = (__bridge QBAudioIOService *)inRefCon;
    // this is a workaround for an issue with core audio on the simulator
#if TARGET_IPHONE_SIMULATOR
    const UInt32 normalFrameNumbers = 93;
#else
    const UInt32 normalFrameNumbers = qbBufferFrameSize;
#endif
    
//    QBDLog(@"audioService.inputBlock: %@", audioService.inputBlock);
//    QBDLog(@"inNumberFrames: %d, normalFrameNumbers: %d", (unsigned int)inNumberFrames, (unsigned int)normalFrameNumbers);
    
    // grab the data. A inputBuffer will be with data after this call
    //
    if (audioService.inputBlock != nil) {
        if (inNumberFrames != normalFrameNumbers) {
            return noErr;
        }
        
        QBCheckError(AudioUnitRender(audioService->inputUnit,
                                     ioActionFlags, inTimeStamp, kInputBus, inNumberFrames,
                                     audioService->inputBuffer),
                     "Couldn't render the output unit");
        //
        if(audioService.inputBlock != nil){
            audioService.inputBlock(audioService->inputBuffer->mBuffers[0]);
        }
    }
    
    return noErr;
}



#pragma mark
#pragma mark AudioSession callbacks

void qbSessionInterruptionListener(void *inClientData, UInt32 inInterruption)
{
    QBAudioIOService *audioIOService = (QBAudioIOService *)inClientData;
    
    // begin
	if (inInterruption == kAudioSessionBeginInterruption) {
		NSLog(@"Audio Begin interuption");
		audioIOService->_inputAvailable = NO;
        [audioIOService stop];
        
    // end
    }else if (inInterruption == kAudioSessionEndInterruption) {
		NSLog(@"Audio End interuption");
		audioIOService->_inputAvailable = YES;
		[audioIOService start];
	}
}

void qbSessionPropertyListener(void *inClientData, AudioSessionPropertyID  inID, UInt32 inDataSize, const void *inData)
{
    // Determines the reason for the route change, to ensure that it is not because of a category change.
    //
    CFNumberRef routeChangeReasonRef = (CFNumberRef)CFDictionaryGetValue ((CFDictionaryRef)inData, CFSTR (kAudioSession_AudioRouteChangeKey_Reason));
    SInt32 routeChangeReason;
    CFNumberGetValue (routeChangeReasonRef, kCFNumberSInt32Type, &routeChangeReason);
	
    if (inID == kAudioSessionProperty_AudioRouteChange && routeChangeReason != kAudioSessionRouteChangeReason_CategoryChange){
        
        QBAudioIOService *audioIOService = (QBAudioIOService *)inClientData;
        [audioIOService checkSessionProperties];
    }
}


#pragma mark -
#pragma mark Routes

-(void)routeToSpeaker
{
	UInt32 audioRouteOverride = kAudioSessionOverrideAudioRoute_Speaker;
	
	QBCheckError(AudioSessionSetProperty (kAudioSessionProperty_OverrideAudioRoute,
                                          sizeof(kAudioSessionCategory_PlayAndRecord),
                                          &audioRouteOverride
                                          ), "err1 - speaker");
}

-(void)routeToHeadphone
{
	UInt32 audioRouteOverride = kAudioSessionOverrideAudioRoute_None;
	
	QBCheckError(AudioSessionSetProperty (kAudioSessionProperty_OverrideAudioRoute,
                                          sizeof(kAudioSessionCategory_PlayAndRecord),
                                          &audioRouteOverride
                                          ), "err2 - headphone");
}


#pragma mark -
#pragma mark iLBC Encoder & Decoder

- (void)initiLBCEncoderAndDEcoder
{
    encode_queue = dispatch_queue_create("com.quickblox.audio.ilbc.encode.queue", NULL);
    decode_queue = dispatch_queue_create("com.quickblox.audio.ilbc.decode.queue", NULL);
    
    // Create encoder
    QBEncoderProperties p;
    p.samplingRate = qbSampleRateT;
    p.frameSize    = qbiLBCOutputBufferSize;
    //
    g_encoder = CreateiLBCEncoder();
    InitiLBCEncoder(g_encoder, p);
    
    // Create decoder
    QBDecoderProperties dp;
    dp.samplingRate = qbSampleRateT;
    dp.frameSize    = qbiLBCOutputBufferSize;
    //
    g_decoder = CreateiLBCDecoder();
    InitiLBCDecoder(g_decoder, dp);
    
    
    // Init output buffer for decoder
    //
    g_outputBuffer.mNumberChannels = 1;
    g_outputBuffer.mDataByteSize   = qbiLBCBufferFrameSize;
    g_outputBuffer.mData = malloc(sizeof(unsigned char)*qbiLBCBufferFrameSize);
    memset(g_outputBuffer.mData, 0, qbiLBCBufferFrameSize);
}

- (void)destroyEncoderAndDecoder
{
    DestroyiLBCEncoder(g_encoder);
    DestroyiLBCDecoder(g_decoder);
    //
    dispatch_release(encode_queue);
    dispatch_release(decode_queue);
}

- (AudioBuffer)encodePCMtoiLBC:(AudioBuffer)pcmData
{
//    NSLog(@"len origin: %d", (unsigned int)pcmData.mDataByteSize);
    
    // Encode
    //
    AudioBuffer encodedAU;
    EncodeiLBC(g_encoder, &pcmData, &encodedAU);
    
//    NSLog(@"len encoded: %d", (unsigned int)encodedAU.mDataByteSize);
    
    return encodedAU;
}

- (AudioBuffer)decodeiLBCtoPCM:(AudioBuffer)iLBCData
{
    // Decode
    //
    DecodeiLBC(g_decoder, &iLBCData, &g_outputBuffer);

//    NSLog(@"len decoded: %d", (unsigned int)g_outputBuffer.mDataByteSize);
    
    return g_outputBuffer;
}

- (void)encodeAsyncPCMtoiLBC:(AudioBuffer)pcmData outputBlock:(QBOutputBlock)outputBlock
{
    dispatch_async(encode_queue, ^{
        AudioBuffer encodedBuffer = [self encodePCMtoiLBC:pcmData];
         
        dispatch_sync(dispatch_get_main_queue(), ^{
            if(outputBlock != nil){
                outputBlock(encodedBuffer);
            }
        });
    });
}

- (void)decodeAsynciLBCtoPCM:(AudioBuffer)iLBCData outputBlock:(QBOutputBlock)outputBlock
{
    dispatch_async(decode_queue, ^{
        AudioBuffer decodedBuffer = [self decodeiLBCtoPCM:iLBCData];
        
        dispatch_sync(dispatch_get_main_queue(), ^{
            if(outputBlock != nil){
                outputBlock(decodedBuffer);
            }
        });
    });
}


@end
