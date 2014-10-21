
#include "QBiLBCDecoder.h"

#import "QBAudioUtils.h"

/* Internal representation of an AAC-ELD decoder abstracting from the AudioConverter API */
typedef struct QBiLBCDecoder_ {
    AudioStreamBasicDescription  sourceFormat;
    AudioStreamBasicDescription  destinationFormat;
    AudioConverterRef            audioConverter;
  
    UInt32                       bytesToDecode;
    void                        *decodeBuffer;
    AudioStreamPacketDescription packetDesc[1];
  
    Float64                      samplingRate;
    UInt32                       frameSize;
    UInt32                       maxOutputPacketSize;
} QBiLBCDecoder;

QBiLBCDecoder* CreateiLBCDecoder()
{
    /* Create and initialize a new decoder */
    QBiLBCDecoder *decoder = (QBiLBCDecoder *) malloc(sizeof(QBiLBCDecoder));
    memset(&(decoder->sourceFormat), 0, sizeof(AudioStreamBasicDescription));
    memset(&(decoder->destinationFormat), 0, sizeof(AudioStreamBasicDescription));

    decoder->bytesToDecode       = 0;
    decoder->decodeBuffer        = NULL;
    decoder->samplingRate        = 0;
    decoder->frameSize           = 0;
    decoder->maxOutputPacketSize = 0;
  
    return decoder;
}

void DestroyiLBCDecoder(QBiLBCDecoder* decoder)
{
    AudioConverterDispose(decoder->audioConverter);
    free(decoder); /* free the allocated decoder memory */
}

int InitiLBCDecoder(QBiLBCDecoder* decoder, QBDecoderProperties props)
{
    /* Copy the provided decoder properties */
    decoder->samplingRate = props.samplingRate;
    decoder->frameSize    = props.frameSize;
  
    /* We will decode to LPCM */
    FillOutASBDForLPCM(decoder->destinationFormat,
                       decoder->samplingRate,
                       1,
                       8*sizeof(AudioSampleType),
                       8*sizeof(AudioSampleType),
                       false,
                       false);
  
    /* from AAC-ELD, having the same sampling rate, but possibly a different channel configuration */
    decoder->sourceFormat.mFormatID         = kAudioFormatiLBC;
    decoder->sourceFormat.mFramesPerPacket = 240;
    decoder->sourceFormat.mBytesPerPacket = 50;
    decoder->sourceFormat.mChannelsPerFrame = 1;
    decoder->sourceFormat.mSampleRate       = decoder->samplingRate;

    /* Get the rest of the format info */
    UInt32 dataSize = sizeof(decoder->sourceFormat);
    QBCheckError(AudioFormatGetProperty(kAudioFormatProperty_FormatInfo,
                           0,
                           NULL,
                           &dataSize,
                           &(decoder->sourceFormat)), "QBiLBCDecoder AudioFormatGetProperty error");
  
    /* Create a new AudioConverter instance for the conversion AAC-ELD -> LPCM */
    QBCheckError(AudioConverterNew(&(decoder->sourceFormat),
                      &(decoder->destinationFormat),
                      &(decoder->audioConverter)), "QBiLBCDecoder AudioConverterNew error");
  
    if (!decoder->audioConverter){
        return -1;
    }
  
    /* Check for variable output packet size */
    if (decoder->destinationFormat.mBytesPerPacket == 0){
        UInt32 maxOutputSizePerPacket = 0;
        dataSize = sizeof(maxOutputSizePerPacket);
        AudioConverterGetProperty(decoder->audioConverter,
                                  kAudioConverterPropertyMaximumOutputPacketSize,
                                  &dataSize,
                                  &maxOutputSizePerPacket);
        decoder->maxOutputPacketSize = maxOutputSizePerPacket;
    }else{
        decoder->maxOutputPacketSize = decoder->destinationFormat.mBytesPerPacket;
    }

    return 0;
}

static OSStatus decodeProc(AudioConverterRef inAudioConverter, 
                           UInt32 *ioNumberDataPackets, 
                           AudioBufferList *ioData, 
                           AudioStreamPacketDescription **outDataPacketDescription, 
                           void *inUserData)
{
    /* Get the current decoder state from the inUserData parameter */
    QBiLBCDecoder *decoder = (QBiLBCDecoder *)inUserData;
  
    /* Compute the maximum number of output packets */
    UInt32 maxPackets = decoder->bytesToDecode / decoder->maxOutputPacketSize;
  
    if (*ioNumberDataPackets > maxPackets){
        /* If requested number of packets is bigger, adjust */
        *ioNumberDataPackets = maxPackets;
    }
  
    /* If there is data to be decoded, set it accordingly */
    if (decoder->bytesToDecode){
        ioData->mBuffers[0].mData           = decoder->decodeBuffer;
        ioData->mBuffers[0].mDataByteSize   = decoder->bytesToDecode;
        ioData->mBuffers[0].mNumberChannels = 1;
    }
  
    /* And set the packet description */
    if (outDataPacketDescription){
        decoder->packetDesc[0].mStartOffset            = 0;
        decoder->packetDesc[0].mVariableFramesInPacket = 0;
        decoder->packetDesc[0].mDataByteSize           = decoder->bytesToDecode;
    
        (*outDataPacketDescription) = decoder->packetDesc;
    }
  
    if (decoder->bytesToDecode == 0){
        // We are currently out of data but want to keep on processing
        // See Apple Technical Q&A QA1317
        return 1;
    }
  
    decoder->bytesToDecode = 0;

    return noErr;
}

int DecodeiLBC(QBiLBCDecoder* decoder, AudioBuffer *inData, AudioBuffer *outSamples)
{
    OSStatus status = noErr;
  
    /* Keep a reference to the samples that should be decoded */
    decoder->decodeBuffer  = inData->mData;
    decoder->bytesToDecode = inData->mDataByteSize;
  
    UInt32 outBufferMaxSizeBytes = decoder->frameSize * sizeof(AudioSampleType);
  
    assert(outSamples->mDataByteSize <= outBufferMaxSizeBytes);
  
    UInt32 numOutputDataPackets = outBufferMaxSizeBytes / decoder->maxOutputPacketSize;
  
    /* Output packet stream are 512 LPCM samples */
    AudioStreamPacketDescription outputPacketDesc[512];

    /* Create the output buffer list */
    AudioBufferList outBufferList;
    outBufferList.mNumberBuffers = 1;
    outBufferList.mBuffers[0].mNumberChannels = 1;
    outBufferList.mBuffers[0].mDataByteSize   = outSamples->mDataByteSize;
    outBufferList.mBuffers[0].mData           = outSamples->mData;
  
    /* Start the decoding process */
    status = AudioConverterFillComplexBuffer(decoder->audioConverter,
                                             decodeProc,
                                             decoder,
                                             &numOutputDataPackets,
                                             &outBufferList,
                                             outputPacketDesc);
  
    if (noErr != status){
        return -1;
    }

    return 0;
}

