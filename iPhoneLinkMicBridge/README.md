# iPhone Link Mic Bridge

## What this component does

- Receives the Windows PC microphone over UDP 9878.
- PC audio format: 48 kHz, mono, PCM16, 20 ms packets.
- Plays the received PC microphone as app audio on the iPhone.
- On iOS 18.2+, uses Apple's supported **Microphone Injection** API so app audio can be mixed into supported Phone/FaceTime/VoIP microphone streams.
- Does **not** use a `.playAndRecord`/`.voiceChat` session, so starting the bridge does not intentionally take over the iPhone's physical microphone route.
- Does not modify the existing iPhone → PC audio implementation.

## iPhone requirements

- Physical iPhone.
- iOS 18.2 or newer for microphone injection.
- Mac + Xcode are required to build/sign/install the iOS app normally.

## iOS settings

For microphone injection:

1. Settings → Accessibility → Audio & Visual → Add Audio in Calls.
2. Enable **Allow Apps to Add Audio in Calls**.
3. Open this app and start the PC Mic Receiver.
4. Start a supported Phone/FaceTime/VoIP call.
5. Turn on **Add PC mic to supported calls** in this app.
6. Grant the app microphone-injection permission when iOS asks.

Apple documents this feature as available on iOS 18.2+ for calling apps that use Apple's voice processing, including Phone, FaceTime and most VoIP apps. It is not a universal microphone replacement API for every game/app.

## Network

The iPhone listens on UDP port **9878**. The Windows PC must send to the iPhone's LAN IPv4 address. Keep both devices on the same LAN.
