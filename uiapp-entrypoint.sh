#!/bin/sh
set -eu

APP_DIR=/opt/flexiv/FlexivElementsStudio

if [ -z "${DISPLAY:-}" ]; then
    echo "DISPLAY is not set. Start the container with the host X11 socket mounted and pass DISPLAY through." >&2
    exit 1
fi

cd "$APP_DIR"
bash ./run_FlexivElements.sh "$@"
