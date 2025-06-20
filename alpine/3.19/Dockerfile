FROM alpine:3.19

RUN apk update && \
    apk add --no-cache \
        openrc \
        bash \
        curl \
        wget \
        ca-certificates \
        shadow \
        util-linux && \
    rm -rf /var/cache/apk/*

RUN rc-update add syslog boot && \
    rc-update add networking boot

CMD ["/sbin/init"]