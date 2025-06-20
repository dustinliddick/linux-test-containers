FROM alpine:3.18

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

CMD ["/bin/bash"]