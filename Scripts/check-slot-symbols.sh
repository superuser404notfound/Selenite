#!/usr/bin/env bash
# Fails if the two moonlight-common-c copies share any defined external symbol, or if a slot
# defines a symbol without its prefix (other than its API table). Run after `swift build`.
set -euo pipefail
PKG="$(cd "$(dirname "$0")/../SeleniteKit" && pwd)"
syms() {
  # SwiftPM's legacy native build system emits .build/<triple>/debug/MoonlightSlotX.build/*.o;
  # its newer swiftbuild backend (current default on recent toolchains) emits
  # .build/out/Intermediates.noindex/.../Debug/MoonlightSlotX-t.build/Objects-normal/<arch>/*.o.
  # Match both so this works regardless of which backend produced the build.
  find "$PKG/.build" -type f -name '*.o' \
    \( -path "*MoonlightSlot$1.build/*" -o -path "*MoonlightSlot$1-t.build/*" \) -print0 \
    | xargs -0 nm -g -U -j | grep -v ':$' | grep -v '^$' | sed 's/^_//' | sort -u
}
A="$(syms A)"; B="$(syms B)"
[ -n "$A" ] && [ -n "$B" ] || { echo "no slot objects found, run swift build first"; exit 1; }
shared="$(comm -12 <(echo "$A") <(echo "$B"))"
strayA="$(echo "$A" | grep -v '^SlotA_' | grep -vx 'MLSlotA' || true)"
strayB="$(echo "$B" | grep -v '^SlotB_' | grep -vx 'MLSlotB' || true)"
if [ -n "$shared$strayA$strayB" ]; then
  echo "shared: $shared"; echo "unprefixed in A: $strayA"; echo "unprefixed in B: $strayB"
  exit 1
fi
echo "slot symbols OK: $(echo "$A" | wc -l | tr -d ' ') per slot, none shared"
