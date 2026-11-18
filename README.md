# iPhone Link Mic Bridge

This companion iOS app receives low-latency PCM16 mono audio from the Windows iPhone Link PC app and plays it through an `AVAudioEngine` output node. The app is intentionally a separate companion so the existing Windows/iPhone Link mirroring and iPhone→PC audio path remain untouched.

On iOS 18.2+ Apple provides microphone injection for supported calling/VoIP apps. The user must enable **Settings → Accessibility → Audio & Visual → Add Audio in Calls → Allow Apps to Add Audio in Calls**, then grant this app microphone-injection permission. Apple documents that the injected app audio is mixed into the microphone input stream of supported calls/VoIP apps.

This bridge does **not** replace the existing iPhone Link audio-output path.

## Transport

- UDP source: Windows PC
- Port listened to by iPhone: `9878`
- Codec: PCM signed 16-bit little-endian
- Sample rate: 48 kHz
- Channels: 1
- Packet duration: 20 ms
- Header: 20 bytes, network byte order

The Windows app exposes the target host/port in its Mic Uplink API. Enter the iPhone LAN IPv4 address in the Windows iPhone Link Mic Uplink panel and tap Start. The iPhone app listens on UDP `9878`.

## Build

Open the Xcode project/workspace you create around this source on macOS with an iOS 18.2+ deployment target. A physical iPhone is required for microphone injection testing.

## iPhone setup

1. Install the companion app on a physical iPhone running iOS 18.2 or later.
2. Open it once and allow local-network/audio permissions.
3. Start **Mic Bridge**. It listens on UDP `9878`.
4. In Windows iPhone Link, enter the iPhone's LAN IPv4 address and press **Start** under **PC Microphone → iPhone**.
5. For supported calls/VoIP apps, enable **Settings → Accessibility → Audio & Visual → Add Audio in Calls → Allow Apps to Add Audio in Calls**.
6. Allow microphone injection for iPhone Link Mic Bridge when prompted.

## What this does not promise

iOS does not expose a general-purpose virtual microphone API that lets an arbitrary third-party app replace the microphone device for every app. Apple's microphone injection API is specifically for adding an app's spoken audio to supported calls/VoIP input streams. Apple documents Phone, FaceTime, and most VoIP apps; a particular game's voice-chat implementation may not accept the injected stream.
# iphone-link-mic-bridge
