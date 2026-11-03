#!/bin/bash
# azooKey をビルドし、自分のアカウントの ~/Library/Input Methods に入れる（sudo 不要、ad-hoc 署名）。
# 入れ替える前に azooKey を使っていれば、入れ替えた後に同じ入力ソースを選び直す。
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$HOME/Library/Input Methods"
BUILD_DIR="$REPO_ROOT/build"
LOG="$BUILD_DIR/install_user.log"
TOOL="$BUILD_DIR/input_source"
mkdir -p "$BUILD_DIR"

cd "$REPO_ROOT"
if ! xcodebuild -project azooKeyMac.xcodeproj -scheme azooKeyMac -configuration Release -derivedDataPath "$BUILD_DIR/dd" build \
    CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="" CODE_SIGN_IDENTITY="-" PROVISIONING_PROFILE_SPECIFIER="" > "$LOG" 2>&1; then
    grep -E "error:" "$LOG" | head -20
    echo "ビルドに失敗しました（詳細: $LOG）" >&2
    exit 1
fi

if [ ! -x "$TOOL" ] || [ "$REPO_ROOT/Tools/input_source.swift" -nt "$TOOL" ]; then
    swiftc -O "$REPO_ROOT/Tools/input_source.swift" -o "$TOOL"
fi

previous="$("$TOOL" current)"

mkdir -p "$DEST"
rm -rf "$DEST/azooKeyMac.app"
cp -R "$BUILD_DIR/dd/Build/Products/Release/azooKeyMac.app" "$DEST/"

pkill -x azooKeyMac || true
sleep 0.5
open -g "$DEST/azooKeyMac.app"
sleep 2
"$TOOL" install "$DEST/azooKeyMac.app"

case "$previous" in
    dev.ensan.inputmethod.azooKeyMac*)
        "$TOOL" select "$previous" || echo "入力ソース（$previous）を選び直せませんでした。メニューバーから選んでください" >&2
        ;;
esac
echo "インストールしました: $DEST/azooKeyMac.app（入力ソース: $("$TOOL" current)）"
