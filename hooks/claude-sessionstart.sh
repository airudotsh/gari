#!/bin/sh
# Gari hook — resolves GARI_HOME from its own location.
[ -n "$GARI_INTERNAL" ] && exit 0
GARI_HOME="${GARI_HOME:-$(cd "$(dirname "$0")/.." && pwd)}"
exec "$GARI_HOME/bin/gari" brief 2>>"$GARI_HOME/store/hook.err.log"
