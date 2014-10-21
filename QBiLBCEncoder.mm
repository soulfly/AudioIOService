
#include "QBiLBCEncoder.h"
#import "QBAudioUtils.h"

/* Internal representation of an AAC-ELD encoder abstracting from the AudioConverter API */
typedef struct QBiLBCEncoder_ {
    AudioStreamBasicDescription  sourceFormat;
    AudioStreamBasicDescription  destinationFormat;
    AudioConverterRef            audioConverter;
    AudioBuffer                 *currentSampleBuffer;
  
    UInt32                       bytesToEncode;
    void                        *encoderBuffer;
    AudioStreamPacketDescription packetDesc[1];
  
    Float64                      samplingRate;
    UInt32                       frameSize;
    UInt32                       bitrate;
    UInt32                       maxOutputPacketSize;
} QBiLBCEncoder;


QBiLBCEncoder* CreateiLBCEncoder()
{
    /* Create an initialize a new instance of the encoder object */
    QBiLBCEncoder *encoder = (QBiLBCEncoder *)malloc(sizeof(QBiLBCEncoder));
  
    memset(&(encoder->sourceFormat), 0, sizeof(AudioStreamBasicDescription));
    memset(&(encoder->destinationFormat), 0, sizeof(AudioStreamBasicDescription));
  
    encoder->currentSampleBuffer = NULL;
    encoder->bytesToEncode       = 0;
    encoder->encoderBuffer       = NULL;
    encoder->samplingRate        = 0;
    encoder->frameSize           = 0;
    encoder->maxOutputPacketSize = 0;
  
    return encoder;
}

void DestroyiLBCEncoder(QBiLBCEncoder *encoder)
{
    /* Clean up */
    AudioConverterDispose(encoder->audioConverter);
    free(encoder->encoderBuffer);
    free(encoder);
}

int InitiLBCEncoder(QBiLBCEncoder *encoder, QBEncoderProperties props)
{
    //
    encoder->samplingRate = props.samplingRate;
    encoder->frameSize    = props.frameSize;
  
    /* Convenience macro to fill out the ASBD structure.
        Available only when __cplusplus is defined! */
    FillOutASBDForLPCM(encoder->sourceFormat,
                       encoder->samplingRate,
                       1,
                       8*sizeof(AudioSampleType),
                       8*sizeof(AudioSampleType),
                       false,
                       false);
 
    /* Set the format parameters for AAC-ELD encoding. */
    encoder->destinationFormat.mFormatID         = kAudioFormatiLBC;
    encoder->destinationFormat.mFramesPerPacket = 240;
    encoder->destinationFormat.mBytesPerPacket = 50;
    encoder->destinationFormat.mChannelsPerFrame = 1;
    encoder->destinationFormat.mSampleRate       = encoder->samplingRate;
    //
    // TODO: add additional setup for iLBC
  
    /* Get the size of the formatinfo structure */
    UInt32 dataSize = sizeof(encoder->destinationFormat);
  
    /* Request the propertie from CoreAudio */
    QBCheckError(AudioFormatGetProperty(kAudioFormatProperty_FormatInfo,
                           0,
                           NULL,
                           &dataSize,
                           &(encoder->destinationFormat)), "QBiLBCEncoder AudioFormatGetProperty error ");
  
    /* Create a new audio converter */
    QBCheckError(AudioConverterNew(&(encoder->sourceFormat),
                      &(encoder->destinationFormat),
                      &(encoder->audioConverter)), "QBiLBCEncoder AudioConverterNew error");
  
    if (!encoder->audioConverter){
        return -1;
    }
 
    /* Query the maximum possible output packet size */
    if (encoder->destinationFormat.mBytesPerPacket == 0){
        UInt32 maxOutputSizePerPacket = 0;
        dataSize = sizeof(maxOutputSizePerPacket);
        AudioConverterGetProperty(encoder->audioConverter,
                                  kAudioConverterPropertyMaximumOutputPacketSize,
                                  &dataSize,
                                  &maxOutputSizePerPacket);
        encoder->maxOutputPacketSize = maxOutputSizePerPacket;
    }else{
        encoder->maxOutputPacketSize = encoder->destinationFormat.mBytesPerPacket;
    }
  
    /* Prepare the temporary AU buffer for encoding */
    encoder->encoderBuffer = malloc(encoder->maxOutputPacketSize);
  
    return 0;
}


static OSStatus encodeProc(AudioConverterRef inAudioConverter, 
                           UInt32 *ioNumberDataPackets, 
                           AudioBufferList *ioData, 
                           AudioStreamPacketDescription **outDataPacketDescription, 
                           void *inUserData)
{
    /* Get the current encoder state from the inUserData parameter */
    QBiLBCEncoder *encoder = (QBiLBCEncoder*) inUserData;
  
    /* Compute the maximum number of output packets */
    UInt32 maxPackets = encoder->bytesToEncode / encoder->sourceFormat.mBytesPerPacket;
  
    if (*ioNumberDataPackets > maxPackets){
        /* If requested number of packets is bigger, adjust */
        *ioNumberDataPackets = maxPackets;
    }
  
    /* Check to make sure we have only one audio buffer */
    if (ioData->mNumberBuffers != 1){
        return 1;
    }
  
    /* Set the data to be encoded */
    ioData->mBuffers[0].mDataByteSize   = encoder->currentSampleBuffer->mDataByteSize;
    ioData->mBuffers[0].mData           = encoder->currentSampleBuffer->mData;
    ioData->mBuffers[0].mNumberChannels = encoder->currentSampleBuffer->mNumberChannels;
  
    if (outDataPacketDescription){
        *outDataPacketDescription = NULL;
    }

    if (encoder->bytesToEncode == 0){
        // We are currently out of data but want to keep on processing
        // See Apple Technical Q&A QA1317
        return 1;
    }
  
    encoder->bytesToEncode = 0;
  
    return noErr;
}


int EncodeiLBC(QBiLBCEncoder *encoder, AudioBuffer *inSamples, AudioBuffer *outData)
{
    /* Clear the encoder buffer */
    memset(encoder->encoderBuffer, 0, sizeof(encoder->maxOutputPacketSize));
  
    /* Keep a reference to the samples that should be encoded */
    encoder->currentSampleBuffer = inSamples;
    encoder->bytesToEncode       = inSamples->mDataByteSize;
  
    UInt32 numOutputDataPackets = 1;
  
    AudioStreamPacketDescription outPacketDesc[1];
  
    /* Create the output buffer list */
    AudioBufferList outBufferList;
    outBufferList.mNumberBuffers = 1;
    outBufferList.mBuffers[0].mNumberChannels = 1;
    outBufferList.mBuffers[0].mDataByteSize   = encoder->maxOutputPacketSize;
    outBufferList.mBuffers[0].mData           = encoder->encoderBuffer;

    /* Start the encoding process */
    OSStatus status = AudioConverterFillComplexBuffer(encoder->audioConverter,
                                                    encodeProc, 
                                                    encoder, 
                                                    &numOutputDataPackets, 
                                                    &outBufferList, 
                                                    outPacketDesc);
  
    if (status != noErr){
        return -1;
    }
  
    /* Set the ouput data */
    outData->mNumberChannels      = 1;
    outData->mData           = encoder->encoderBuffer;
    outData->mDataByteSize = outPacketDesc[0].mDataByteSize;
  
    return 0;
}
