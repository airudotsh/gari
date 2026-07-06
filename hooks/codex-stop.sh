#!/bin/sh
exec "$HOME/gari/bin/gari" enqueue >/dev/null 2>>"$HOME/gari/store/hook.err.log"
