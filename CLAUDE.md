# CLAUDE.md

Selenite is a native tvOS 26+ client for Sunshine hosts (GameStream protocol), built to replace Moonlight on the Apple TV. Highlights: low latency with clean frame pacing, bitrate up to 500 Mbps, and split-screen streaming of two hosts at once with per-side controller assignment. GPL-3.0, public repo.

## Layout

- `SeleniteKit/` local Swift package with all testable code. `swift test --package-path SeleniteKit` runs the tests on the Mac.
- `SeleniteKit/Vendor/` git submodules: moonlight-common-c (protocol core) and mbedTLS 3.6 (its crypto backend). Never edit them; update by submodule bump plus `Scripts/gen-vendor-wrappers.sh`.
- `SeleniteKit/Sources/AppCore` the app's state without UI (SettingsStore, StreamController, AddHostModel, StreamFailure, DiagnosticLog, HostWaker, RecentsStore), tested on the Mac like the other modules.
- `Selenite/` the tvOS app target: `App/` (AppModel and the live wiring), `UI/` (building blocks adapted from Sodalite), `Home/`, `Settings/`, `Stream/`, and `Developer/` (the M0/M1-A harness, reachable from Settings > Developer, runs split until M2). `project.yml` is the source of truth; regenerate with `Scripts/generate-project.sh` after adding, moving or deleting files.
- `Selenite/Localizable.xcstrings` holds every user-facing string (English only for now). Interpolate `Int` or `String` into localized strings, never `Int32`.

## Two sessions in one process

moonlight-common-c keeps all connection state in globals and its callbacks carry no context. Selenite compiles it twice, as `MoonlightSlotA` and `MoonlightSlotB`, through generated wrapper files that include a generated prefix header (`SlotA_*`, `SlotB_*`). Swift reaches each copy through the `MLSlotAPI` function table (`MLSlotA`, `MLSlotB`) declared in `MoonlightCore`. `Scripts/check-slot-symbols.sh` proves the two copies share no unprefixed symbol; CI runs it. Solo is one session on slot A, split is slots A and B.

## Conventions

- Swift 6, SwiftUI, Swift Testing.
- Conventional Commits, no em-dashes anywhere.
- `docs/superpowers/` holds local-only specs and plans and is gitignored.
- Code lifted from AetherEngine (LGPLv3 with App Store exception, relicensable to GPLv3) carries a header comment naming its source file.
- Only the Siri Remote controls a stream: Menu opens the overlay (and cancels while loading), Menu with the overlay open leaves the stream. Controller buttons, Start and Select included, always go to the host. While the overlay is closed the Siri Remote is also the host's mouse (`RemotePointer`): touch surface moves, a circle on the outer ring scrolls, click is the left button, Play/Pause the right one. The stream surface is a `GCEventViewController` with controller user interaction off while the overlay is closed.
- tvOS UI: settings rows are single focusable views that open a list of buttons (a Form `Picker` opens nothing); panel buttons stack vertically; panels present through `.menuPresentation`.
- Hosts: Bonjour (`_nvstream._tcp`) finds unpaired PCs (New cards) and moves a paired host to its new IP unless it was saved by name; a host with a known MAC (from the paired serverinfo) is woken on demand; recents are written at the first frame. Wake-on-LAN is a per-host switch (long press), automatic default off for virtual MACs (00:16:3E, locally administered).
