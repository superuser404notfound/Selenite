# Selenite

A native tvOS client for [Sunshine](https://github.com/LizardByte/Sunshine) hosts.

- Low latency with clean frame pacing: one frame per vsync, always the newest.
- Bitrate up to 500 Mbps.
- Split screen (planned for M2, a developer harness until then): stream two hosts at once, side by side or top and bottom, with controllers assigned per side.

Status: early development. Solo streaming works from the app; split screen is still a developer harness (Settings > Developer).

Selenite builds on [moonlight-common-c](https://github.com/moonlight-stream/moonlight-common-c) and is licensed under the GPL-3.0.
