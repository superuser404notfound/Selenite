<p align="center">
  <img src=".github/selenite-logo.png" alt="Selenite" width="180">
</p>

<h1 align="center">Selenite</h1>

<p align="center">
  <b>Your PC games on the Apple TV, streamed from Sunshine.</b><br>
  Native for tvOS. Low latency, clean frame pacing, up to 4K and 500 Mbps.<br>
  Two PCs on one TV in split screen, each side with its own controllers.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/tvOS-26%2B-black?logo=apple">
  <img src="https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white">
  <img src="https://img.shields.io/badge/license-GPL--3.0-lightgrey">
  <img src="https://img.shields.io/badge/languages-26-blue">
  <img src="https://img.shields.io/badge/status-App%20Store%20coming%20soon-orange">
</p>

---

## What it is

Selenite is a client for [Sunshine](https://github.com/LizardByte/Sunshine), the free, open-source game streaming host for Windows, Linux and macOS. It speaks the same protocol as Moonlight, through [moonlight-common-c](https://github.com/moonlight-stream/moonlight-common-c), but everything around it is built for the Apple TV from scratch: a SwiftUI interface for the Siri Remote, a video path tuned for the Apple TV's display pipeline, and a split screen mode no other client has.

## Features

### Split screen: two PCs, one TV

Stream two hosts at once, side by side or top and bottom.

- A wizard picks host, game and layout for each side. On the join screen every player points their stick at a side and presses A; the stream starts as soon as one controller is seated, and an empty side streams too and can be joined later.
- Each side gets its own controllers. Controllers that play on neither side wait in a lobby.
- Menu on the Siri Remote opens the split overlay while both games keep running: volume per side, disconnect, quit, swap sides, reassign controllers, end the split.
- A tile on Home starts the last split again with one click.

Selenite runs two independent protocol sessions in one process for this. moonlight-common-c keeps its whole connection state in globals, so it is compiled twice under prefixed symbols (see [Architecture](#architecture)).

### Frame pacing in three steps

| Mode | What it does | Typical cost |
|---|---|---|
| **Lowest latency** | Every frame goes out the moment it is decoded. | Lowest latency, judder whenever the network jitters. |
| **Smooth** | Elastic playout on the host's own cadence: a few milliseconds of buffer that stretches by a refresh when a frame comes late and steps back after two calm seconds. | A few milliseconds more than Lowest latency, about half the judder. |
| **Smooth+** | Two standing frames of buffer for a busy network. | About 50 ms, steadiest picture on a poor link. |

Pacing changes are judged by replaying traces recorded on a real Apple TV, not by feel (see [Development](#development)).

### Picture and sound

- Resolutions from 720p to 4K, or match the TV; 30 or 60 fps, or match the display.
- H.264 and HEVC, bitrates up to 500 Mbps.
- Stereo or 5.1 surround.
- Every setting can be overridden per host, from Settings > Hosts or the host card's long-press menu.

### Controllers and the Siri Remote

- Xbox and PlayStation controllers with rumble; touchpad, motion and light bar on DualSense and DualShock 4; Xbox Elite paddles.
- Controller buttons, Start and Select included, always go to the host. Only the Siri Remote controls the stream.
- With the overlay closed, the Siri Remote is the host's mouse: the touch surface moves the pointer, a circle on the outer ring scrolls, click is left, Play/Pause is right.

### Hosts

- Sunshine hosts on the network show up on their own (Bonjour) and pair with a PIN. Hosts can also be added by address.
- A paired host that moves to a new IP is followed automatically.
- A sleeping PC is woken with Wake-on-LAN when you pick it (a per-host switch, off by default for virtual network adapters).
- Recently played games across all hosts sit on Home.

### Stream stats

Off, Compact (a pill in the corner) or Full: resolution, frame rate, display and stream rate, codec, pacing and bitrate; host, network, decode and display latency and round trip; jitter, and dropped frames split into network loss, client queue drops and pacer drops (overflow and catch-up), plus unrecoverable frames, stalls, missed display refreshes and audio underruns. The Menu overlay always shows the full list, in split screen for both sides.

### Languages

26 languages: English, German, French, Spanish, Italian, Dutch, Portuguese (Brazil and Portugal), Danish, Swedish, Norwegian, Finnish, Polish, Czech, Slovak, Hungarian, Croatian, Romanian, Greek, Russian, Ukrainian, Turkish, Japanese, Korean and Chinese (Simplified and Traditional).

### Privacy

No accounts, no analytics, no tracking. Selenite only talks to your own hosts; see the [privacy policy](PRIVACY.md).

## Getting started

1. Install [Sunshine](https://github.com/LizardByte/Sunshine) on your PC and create a user in its web UI (`https://localhost:47990`).
2. Open Selenite on the Apple TV. The PC appears on Home; if it does not, use **Add host** and enter its address.
3. Select it and enter the PIN Selenite shows in Sunshine's web UI under **PIN**.
4. Pick a game. Menu on the Siri Remote opens the stream overlay.

A wired connection for the Apple TV and the host gives the best results; on Wi-Fi, try **Smooth** first.

## Requirements

- Apple TV with tvOS 26 or later. Apple TV 4K recommended (HEVC, 4K).
- A PC running Sunshine on the same network. Split screen needs two, since one Sunshine host serves one stream at a time.

## Building from source

Requirements: Xcode 26 or later, [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```bash
git clone --recursive https://github.com/superuser404notfound/Selenite.git
cd Selenite
Scripts/generate-project.sh
open Selenite.xcodeproj
```

Pick the `Selenite-tvOS` scheme and an Apple TV or the simulator. `project.yml` is the source of truth for the Xcode project; regenerate after adding or moving files.

## Architecture

```
Selenite/                 tvOS app: Home, Settings, Stream, Split (wizard, join screen, overlay)
SeleniteKit/              Swift package with everything testable
  Sources/AppCore         app state without UI: settings, hosts, recents, stream and split controllers
  Sources/HostKit         discovery, nvhttp, pairing, Wake-on-LAN
  Sources/StreamKit       video intake, decoding, frame pacing, audio, stats
  Sources/InputKit        controllers, seats, rumble and feedback, the Siri Remote pointer
  Sources/MoonlightCore   Swift bridge to the protocol core
  Sources/MoonlightSlotA  moonlight-common-c, compiled with SlotA_ prefixes
  Sources/MoonlightSlotB  moonlight-common-c, compiled with SlotB_ prefixes
  Sources/MbedCrypto      mbedTLS 3.6, the protocol's crypto backend
  Sources/OpusCodec       Opus audio decoding
  Vendor/                 git submodules: moonlight-common-c, mbedTLS, Opus
```

Two streams in one process: moonlight-common-c holds all connection state in globals and its callbacks carry no context, so Selenite builds it twice through generated wrapper files with prefixed symbols and reaches each copy through a function table. `Scripts/check-slot-symbols.sh` proves the two copies share no unprefixed symbol; CI runs it. Solo streams use slot A, split screen uses both.

## Development

```bash
swift test --package-path SeleniteKit
```

runs the test suite on the Mac. Frame pacing is tuned against real traces: record them on a device, then replay every mode against the same input:

```bash
PACER_TRACE=<dir> PACER_MODES=lowLatency,smooth,smoothPlus \
  swift test --package-path SeleniteKit --filter pacerTraceReplay
```

The replay reports latency, judder per minute, stalls and drops per mode.

## Credits and license

Selenite is licensed under the [GPL-3.0](LICENSE). It builds on:

- [moonlight-common-c](https://github.com/moonlight-stream/moonlight-common-c) (GPL-3.0), the GameStream protocol core
- [Mbed TLS](https://github.com/Mbed-TLS/mbedtls) (Apache-2.0)
- [Opus](https://github.com/xiph/opus) (BSD-3-Clause)

Selenite is not affiliated with LizardByte, the Sunshine project or the Moonlight project.
