FROM ubuntu:20.04

RUN apt-get update && \
    apt-get install -y \
        systemd \
        curl \
        wget \
        ca-certificates \
        sudo \
        locales && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

RUN systemctl set-default multi-user.target

VOLUME ["/sys/fs/cgroup"]

CMD ["/sbin/init"]