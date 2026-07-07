#!/bin/sh
# 가리 내부 호출 산출은 수집하지 않는다 (자기 인용 오염 방지 — 파견은 do가 직접 기록)
[ -n "$GARI_INTERNAL" ] && exit 0
exec "$HOME/gari/bin/gari" enqueue >/dev/null 2>>"$HOME/gari/store/hook.err.log"
