# source image - alpine hardened (dev means it has "apk" package manager)
FROM dhi.io/alpine-base:3.24-dev

# set labels
LABEL build_version='2026.10.18'
LABEL maintainer='blomstertj'

# set environment variables
ENV COMPACT_OUTPUT='false'
ENV SKIP_IPME_CHECK='false'
ENV QBITTORRENT_API_KEY=''
ENV QBITTORRENT_WEBUI_URL=''
ENV TZ='UTC'

# enable community repository for natpmpc package
RUN echo '**** enable community repository ****' && \
    echo 'https://dl-cdn.alpinelinux.org/alpine/v3.24/community' >> /etc/apk/repositories

# install bash, curl, and libnatpmp
RUN echo '**** install packages ****' && \
    apk update && \
    apk add --no-cache tzdata bash curl jq libnatpmp

RUN echo '**** set timezone ****' && \
    cp /usr/share/zoneinfo/${TZ} /etc/localtime && \
    echo "${TZ}" > /etc/timezone

# clean up container /tmp, /var/log, and /var/cache/apk
RUN echo '**** cleanup ****' && \
    rm -rf /tmp/* && \
    rm -rf /var/log/* && \
    rm -rf /var/cache/apk/*

# copy bash script to container / dir
COPY proton-natpmp-keepalive-sync-qb.sh /

# copy entrypoint script to container / dir
RUN echo '**** set ownership and permissions ****' && \
    chown nonroot:nonroot /proton-natpmp-keepalive-sync-qb.sh && \
    chmod +x /proton-natpmp-keepalive-sync-qb.sh

# set the container user to nonroot
# this user is special to the hardened alpine image
# and has a UID of 65532, which is the same as the "nobody" user in many Linux distributions
USER nonroot

# create startup command
ENTRYPOINT [ "/bin/bash" ]
CMD [ "/proton-natpmp-keepalive-sync-qb.sh" ]
