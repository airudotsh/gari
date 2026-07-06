#!/bin/bash
# 가리 설치 — 처음 세팅하는 사람의 문. 몇 번을 다시 돌려도 안전.
set -e
GARI="$HOME/gari"
echo "── 가리 설치 ──"
# 0. 전제조건
command -v claude >/dev/null || { echo "✗ Claude Code CLI가 필요합니다: https://claude.com/claude-code 설치 후 로그인하고 다시 실행"; exit 1; }
xcode-select -p >/dev/null 2>&1 || { echo "✗ 명령줄 도구가 필요합니다: xcode-select --install 후 다시 실행"; exit 1; }
# 1. 명령 등록
mkdir -p "$HOME/.local/bin"
ln -sf "$GARI/bin/gari" "$HOME/.local/bin/gari"
# 2. 펫 빌드 + 앱 설치
cd "$GARI/pet"
clang -fobjc-arc -framework Cocoa -O2 -o gari-pet GariPet.m
DEST="/Applications/Gari.app"; [ -w /Applications ] || DEST="$HOME/Applications/Gari.app"
mkdir -p "$DEST/Contents/MacOS" "$DEST/Contents/Resources"
[ -f "$DEST/Contents/Info.plist" ] || cp "$GARI/pet/app/Info.plist" "$DEST/Contents/Info.plist" 2>/dev/null || true
cp gari-pet "$DEST/Contents/MacOS/gari"
[ -f "$GARI/pet/app/gari.icns" ] && cp "$GARI/pet/app/gari.icns" "$DEST/Contents/Resources/"
codesign --force --deep -s - "$DEST" 2>/dev/null || true
# 3. 온보딩 (질문 → 훅·예약 등록 → 진단)
"$GARI/bin/gari" init
echo "── 완료. 펫을 깨우려면: Spotlight에서 'Gari' 또는 'gari pet' ──"
