#!/bin/sh
set -eu

APP_DIR=/opt/flexiv/RobotControlApp-Sim
APP_BIN="$APP_DIR/RobotControlApp"

export LD_LIBRARY_PATH="$APP_DIR/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export QT_QPA_PLATFORM_PLUGIN_PATH="$APP_DIR/plugins"
export QTWEBENGINE_DISABLE_SANDBOX="${QTWEBENGINE_DISABLE_SANDBOX:-1}"


SN="AX01L-06-D1-${RCA_ID:-"Docker"}"

# Set RCA_GUI_DISABLE=1 to run without the Qt window (no X11 / DISPLAY needed).
GUI_ARGS=""
if [ "${RCA_GUI_DISABLE:-0}" = "1" ]; then
    GUI_ARGS="-g"
fi


if [ -z "${DISPLAY:-}" ] && [ -z "${GUI_ARGS}" ]; then
    echo "DISPLAY is not set. Start the container with the host X11 socket mounted and pass DISPLAY through." >&2
    exit 1
fi

if [ ! -x "$APP_BIN" ]; then
    echo "Expected executable not found: $APP_BIN" >&2
    exit 1
fi

# Seed the writable user_data. Remove leftovers first, otherwise cp -r nests
# the source as /tmp/user_data/user_data when the container is restarted in place.
rm -rf /tmp/user_data
cp -r "${APP_DIR}/user_data" /tmp/user_data

# setup_RCA.sh only generates run_RCA.sh (not used by this entrypoint) and runs
# an apt install. Skip it with RCA_SKIP_SETUP=1 when the image already has the deps.
cd "${APP_DIR}"
if [ "${RCA_SKIP_SETUP:-0}" != "1" ]; then
    bash ./setup_RCA.sh -s "${SN}"
fi

# start IPPublish service

cd "${APP_DIR}"
exec "$APP_BIN" -c "${APP_DIR}/specs/robots/FlexivAX01L/flexivCfg.xml" -u /tmp/user_data/ -m MotionBarDummy -x CX03-02-P1-00034 -p factory -s "${SN}" ${GUI_ARGS}
