AudioIOService
==============

The service to access low level audio IO data.

Features:

* Access low level audio IO data

```objc
TPCircularBuffer circularBuffer;

TPCircularBufferInit(&circularBuffer, 32768); 
 
[[QBAudioIOService shared] setOutputBlock:^(AudioBuffer buffer) {
    int32_t availableBytesInBuffer;
    void *cbuffer = TPCircularBufferTail(&circularBuffer, &availableBytesInBuffer);
                    
    // Read audio data if exist
    if(availableBytesInBuffer > 0){
      int min = MIN(buffer.mDataByteSize, availableBytesInBuffer);
      memcpy(buffer.mData, cbuffer, min);
      TPCircularBufferConsume(&circularBuffer, min);
    } 
}];

...

[[QBAudioIOService shared] setInputBlock:^(AudioBuffer buffer){
    // Put audio into circular buffer
    TPCircularBufferProduceBytes(&circularBuffer, buffer.mData, buffer.mDataByteSize);
}];
```

```objc
[[QBAudioIOService shared] start];

...

[[QBAudioIOService shared] stop];
TPCircularBufferCleanup(&circularBuffer);
```

* Route output to speaker/headphone

```objc
[[QBAudioIOService shared] routeToHeadphone];

...

[[QBAudioIOService shared] routeToSpeaker];
```

* Compress/decompress raw data using iLBC codec
```objc

// Convert to iLBC
AudioBuffer encodedBuffer = [[QBAudioIOService shared] encodePCMtoiLBC:originBuffer];

// Convert back to PCM
AudioBuffer decodedData = [[QBAudioIOService shared] decodeiLBCtoPCM:buffer];
```
