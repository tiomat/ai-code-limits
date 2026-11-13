#!/bin/zsh
set -euo pipefail

root="${0:A:h:h}"
output="$root/dist/AI Code Limits.app"
installed="/Applications/AI Code Limits.app"

install=false
case "${1:-}" in
  "") ;;
  --install) install=true ;;
  *) echo "usage: $0 [--install]" >&2; exit 64 ;;
esac

swift build --package-path "$root" -c release
mkdir -p "$output/Contents/MacOS" "$output/Contents/Resources"
cp "$root/.build/release/AICodeLimitsMenuBar" "$output/Contents/MacOS/AICodeLimitsMenuBar"
cp "$root/Resources/Info.plist" "$output/Contents/Info.plist"
cp "$root/Resources/AppIcon.icns" "$output/Contents/Resources/AppIcon.icns"

if ! $install; then
  echo "$output"
  exit 0
fi

pkill -x AICodeLimitsMenuBar && while pgrep -x AICodeLimitsMenuBar >/dev/null; do sleep 0.1; done || true
# Миграция со старого имени проекта (kimi-limits / Coding Limits).
pkill -x CodingLimitsMenuBar && while pgrep -x CodingLimitsMenuBar >/dev/null; do sleep 0.1; done || true
rm -rf "/Applications/Coding Limits.app"
rm -rf "$installed"
ditto "$output" "$installed"
open "$installed"
echo "$installed"