#!/bin/zsh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"
mkdir -p "$ROOT/.work/phase1/build" "$ROOT/.work/phase1/backups" "$ROOT/outputs/phase1"
xcodegen generate --spec "$ROOT/project.yml"
xcodebuild -project "$ROOT/TuanTuan.xcodeproj" -scheme TuanTuan -configuration Release \
  -derivedDataPath "$ROOT/.work/phase1/build" \
  CLANG_MODULE_CACHE_PATH="$ROOT/.work/phase1/build/ModuleCache.noindex" \
  build
SOURCE="$ROOT/.work/phase1/build/Build/Products/Release/TuanTuan.app"
DESTINATION="$ROOT/outputs/phase1/TuanTuan.app"
if [[ -d "$DESTINATION" ]]; then
  rm -rf "$ROOT/.work/phase1/backups/TuanTuan.previous.app"
  mv "$DESTINATION" "$ROOT/.work/phase1/backups/TuanTuan.previous.app"
fi
ditto "$SOURCE" "$DESTINATION"
codesign --force --deep --sign - "$DESTINATION"
codesign --verify --deep --strict "$DESTINATION"
ditto -c -k --sequesterRsrc --keepParent "$DESTINATION" "$ROOT/outputs/phase1/TuanTuan-Phase1.zip"
echo "应用已构建：$DESTINATION"
echo "启动：open \"$DESTINATION\""
