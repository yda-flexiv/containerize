FROM ubuntu:22.04
    LABEL org.opencontainers.image.authors="da.yang <dayang@IT002193>"


ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update -qq && apt-get install -y --no-install-recommends \
    bash ca-certificates \
    libglib2.0-0 libasound2 libdbus-1-3 libfontconfig1 libfreetype6 \
    libegl1 libgl1 libglu1-mesa libglfw3 libglew2.2 \
    libice6 libnss3 libopengl0 libpng16-16 libssl3 libsm6 libusb-1.0-0 \
    libx11-6 libx11-xcb1 libxcb1 libxcb-render0 libxcb-shape0 libxcb-xfixes0 \
    libxcursor1 libxext6 libxfixes3 libxi6 libxinerama1 libxkbcommon0 libxkbcommon-x11-0 \
    libxrandr2 libxrender1 libxcomposite1 libxdamage1 libxtst6 \
    net-tools gocryptfs libnss3 libxdamage1 qtbase5-dev libxcb-xinerama0 net-tools network-manager iputils-ping \
    freeglut3-dev libatomic1 libgomp1 fuse3 unzip zip sudo \
 && rm -rf /var/lib/apt/lists/*


RUN mkdir -p /opt/flexiv/

# copy packages
COPY packages/FlexivElementsStudio.zip /opt/flexiv/
COPY packages/RobotControlApp-Sim.zip /opt/flexiv/
# install
RUN cd /opt/flexiv && unzip FlexivElementsStudio.zip && unzip RobotControlApp-Sim.zip

# TODO decrypt rca
# setup
RUN cd /opt/flexiv/FlexivElementsStudio && bash ./setup_FlexivElements.sh

COPY uiapp-entrypoint.sh /opt/flexiv/start-flexiv-element
COPY rca-entrypoint.sh /opt/flexiv/start-rca
ENTRYPOINT ["/opt/flexiv/start-flexiv-element"]
