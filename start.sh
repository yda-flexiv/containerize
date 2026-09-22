#!/bin/bash

APP=${1:-rca}
RCA_ID="Podman"

usage() {
	echo "Usage: $0 -a APP [-i RCA_ID] [-h]"
	echo "  -a APP              App to start, valid options: rca, ui, bash"
	echo "  -i RCA_ID           Last part of RCA serial number, max length is 6"
	echo "  -h                  Show this message and exit"
	exit 1
}

while getopts "a:i:h" opt; do
	case $opt in
	i) RCA_ID=$OPTARG ;;
	a) APP=$OPTARG ;;
	h) usage
	   exit 0
	   ;;
	\?)
		usage
		exit 1
		;;
	:)
		usage
		exit 1
		;;
	esac
done

shift $((OPTIND - 1))

ENTRY_POINT=""
case $APP in
rca) ENTRY_POINT="/opt/flexiv/start-rca" ;;
ui) ENTRY_POINT="/opt/flexiv/start-flexiv-element" ;;
bash) ENTRY_POINT="/bin/bash" ;;
esac

podman run --name "${APP}-${RCA_ID}" -it --rm \
	-e DISPLAY="$DISPLAY" \
	-e XAUTHORITY=/tmp/host.xauth \
	-e RCA_ID="$RCA_ID" \
	-v /tmp/.X11-unix:/tmp/.X11-unix:ro \
	-v "$XAUTHORITY":/tmp/host.xauth:ro \
	--cap-add=SYS_ADMIN \
	--device /dev/fuse \
	--entrypoint $ENTRY_POINT \
	--network podman \
	flexivapps:v1.0
