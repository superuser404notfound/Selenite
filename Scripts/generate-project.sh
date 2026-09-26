#!/usr/bin/env bash
# Regenerate Selenite.xcodeproj from project.yml. project.yml is the source of truth.
set -euo pipefail
cd "$(dirname "$0")/.."

RESOLVED="Selenite.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
BACKUP="$(mktemp)"
if [ -f "$RESOLVED" ]; then cp "$RESOLVED" "$BACKUP"; fi

xcodegen generate --spec project.yml

if [ -s "$BACKUP" ]; then
  mkdir -p "$(dirname "$RESOLVED")"
  cp "$BACKUP" "$RESOLVED"
fi
rm -f "$BACKUP"
echo "Regenerated Selenite.xcodeproj from project.yml (Package.resolved preserved)"
