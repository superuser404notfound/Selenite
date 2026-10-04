# Selenite

A native tvOS client for [Sunshine](https://github.com/LizardByte/Sunshine) hosts.

- Low latency with clean frame pacing: one frame per vsync, always the newest.
- Bitrate up to 500 Mbps.
- Resolution, frame rate, bitrate, codec and audio are set globally in Settings; each host can override any of them from its card's long-press menu. Split screen only uses the host's codec override, the bitrate there always stays half the global one.
- Split screen: stream two hosts at once, side by side or top and bottom, with controllers assigned per side. A wizard walks through host, game and layout for each side, then the join screen lets each player point their stick at a side and press A; Start begins as soon as one controller is seated; an empty side streams too and can be joined later with A. A quick-start tile on Home replays the last split at a tap. Menu on the Siri Remote opens the split overlay for per-side volume, disconnect, quit, swap sides, reassign controllers and ending the split, all while the games keep running behind it; Menu again closes the overlay, as in a solo stream, and only Disconnect or End split ends a stream.
- Hosts running Sunshine are found automatically on the network and pair with a PIN; a sleeping PC wakes on selection.
- Stream stats: Off, Compact (a top-right pill) or Full (resolution, frame rate, display and stream rate, codec, frame pacing and bitrate; host, network, decode and display latency, round trip; jitter, dropped frames split into network loss versus client queue drops, unrecoverable frames, stalls and audio underruns). The Menu overlay always shows the full list, solo and in both split columns.
- Recently played: the last games across all hosts, one tap away from Home.

Status: early development. Solo streaming and split screen both work from the app.

Selenite builds on [moonlight-common-c](https://github.com/moonlight-stream/moonlight-common-c) and is licensed under the GPL-3.0.
