AudioIOService
==============

The service to access low level audio IO data.

Features:

* Access low level audio IO data

```objc
[[QBAudioIOService shared] setOutputBlock:^(AudioBuffer buffer) {

}];

...

[[QBAudioIOService shared] setInputBlock:^(AudioBuffer buffer){

}];
```

```objc
[[QBAudioIOService shared] start];

...

[[QBAudioIOService shared] stop];
```

* Route output to speaker/headphone

```objc
[[QBAudioIOService shared] routeToHeadphone];

...

[[QBAudioIOService shared] routeToSpeaker];
```
