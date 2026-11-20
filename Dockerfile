# source image - alpine hardened (dev means it has "apk" package manager)
FROM dhi.io/alpine-base:3.24-dev

# set labels
LABEL maintainer='github.com/blomstertj'
LABEL description='NATPMP port forward loop script for ProtonVPN P2P connections with optional qBittorrent sync'
LABEL build_version='2026.10.28'
LABEL script_version='2026.10.28'

# set environment variables
ENV COMPACT_OUTPUT='false'
ENV SKIP_IPME_CHECK='false'
# set both to enable qBittorrent syncing or keep blank to skip syncing
ENV QBITTORRENT_API_KEY=''
ENV QBITTORRENT_WEBUI_URL=''
ENV TZ='UTC'

# enable https community repository for natpmpc package
RUN echo '**** enable community repository ****' && \
    echo 'https://dl-cdn.alpinelinux.org/alpine/v3.24/community' >> /etc/apk/repositories

# install bash, libnatpmp, curl, jq, and tzdata
RUN echo '**** install base packages ****' && \
    apk update && \
    apk add --no-cache bash libnatpmp curl jq tzdata

# set timezone
RUN echo '**** set timezone ****' && \
    cp /usr/share/zoneinfo/${TZ} /etc/localtime && \
    echo "${TZ}" > /etc/timezone

# copy bash script to container / dir
RUN echo '**** copy bash script to container ****' && \
    mkdir -p /config && \
    chown nonroot:nonroot /config
COPY proton-natpmp-qbsync-keepalive.sh /config/proton-natpmp-qbsync-keepalive.sh

# set ownership and permissions (nonroot user from hardened alpine image)
RUN echo '**** set ownership and permissions ****' && \
    chown nonroot:nonroot /config/proton-natpmp-qbsync-keepalive.sh && \
    chmod +x /config/proton-natpmp-qbsync-keepalive.sh

# clean up container /tmp, /var/log, and /var/cache/apk
RUN echo '**** cleanup ****' && \
    rm -rf /tmp/* && \
    rm -rf /var/log/* && \
    rm -rf /var/cache/apk/*

# set the container user to nonroot
USER nonroot

# create startup command
ENTRYPOINT [ "/bin/bash" ]
CMD [ "/config/proton-natpmp-qbsync-keepalive.sh" ]
