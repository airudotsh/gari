#!/bin/sh
# 가리 내부 뇌 호출에는 브리핑을 재귀 주입하지 않는다 (정체성 오염 방지)
[ -n "$GARI_INTERNAL" ] && exit 0
exec "$HOME/gari/bin/gari" brief 2>>"$HOME/gari/store/hook.err.log"
