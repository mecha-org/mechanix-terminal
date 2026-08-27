#!/bin/sh
APPDIR="/usr/share/mechanix/mechanix-terminal"
export LD_LIBRARY_PATH="$APPDIR/lib:$LD_LIBRARY_PATH"
exec "$APPDIR/mechanix_terminal" --bundle="$APPDIR" "$@"
