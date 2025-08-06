# Rptr

A simple iOS video and location streaming server for home and casual use where certificate-level security is not required.

## Overview

Rptr is a lightweight iOS application that turns your iPhone or iPad into a basic HLS (HTTP Live Streaming) server. It allows you to stream video from your device's camera to other devices on the same local network using a standard web browser.

## Features

- Stream video from your iOS device camera
- View streams in any modern web browser
- Location sharing (when enabled)
- Simple web interface for viewing streams
- No external dependencies or complex setup required

## Requirements

- iOS 17.6 or later
- iPhone or iPad with camera
- Local network connection (WiFi recommended)

## Usage

1. Launch the app on your iOS device
2. Grant necessary permissions (camera, microphone, location if desired)
3. The app will display URLs for accessing the stream
4. Open the provided URL in a web browser on another device connected to the same network
5. The stream should begin playing automatically

## Technical Details

- Uses HLS (HTTP Live Streaming) protocol
- Streams at 600 kbps video / 64 kbps audio (optimized for reliability)
- 15 fps frame rate (smooth playback with lower bandwidth)
- H.264 video encoding (Baseline profile for compatibility)
- AAC audio encoding (Mono for bandwidth efficiency)
- 960x540 resolution (qHD)
- 4-second segments for balanced reliability and responsiveness

## Limitations

- Designed for local network use only
- No authentication or encryption (not suitable for sensitive content)
- Basic functionality focused on simplicity over features
- May experience delays or buffering depending on network conditions

## Building

Open `Rptr.xcodeproj` in Xcode and build for your target device. The app uses only standard iOS frameworks with no external dependencies.

## Privacy & Security

This app is intended for casual, home use only. It does not implement certificate-based security or authentication. Do not use for streaming sensitive or private content over untrusted networks.

## License

MIT License
