#!/bin/sh
set -eu

APP_DIR=/opt/flexiv/RobotControlApp-Sim
APP_BIN="$APP_DIR/RobotControlApp"

export LD_LIBRARY_PATH="$APP_DIR/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export QT_QPA_PLATFORM_PLUGIN_PATH="$APP_DIR/plugins"
export QTWEBENGINE_DISABLE_SANDBOX="${QTWEBENGINE_DISABLE_SANDBOX:-1}"


SN="AX01L-06-D1-${RCA_ID:-"Docker"}"


if [ -z "${DISPLAY:-}" ]; then
    echo "DISPLAY is not set. Start the container with the host X11 socket mounted and pass DISPLAY through." >&2
    exit 1
fi

if [ ! -x "$APP_BIN" ]; then
    echo "Expected executable not found: $APP_BIN" >&2
    exit 1
fi

cp -r ${APP_DIR}/user_data /tmp/user_data

# setup requires serial number, so do it here
cd ${APP_DIR}
bash ./setup_RCA.sh -s "${SN}"

# start IPPublish service

cd "${APP_DIR}"
exec "$APP_BIN" -c ${APP_DIR}/specs/robots/FlexivAX01L/flexivCfg.xml -u /tmp/user_data/ -m MotionBarDummy -x CX03-02-P1-00034 -p factory -s "${SN}"
