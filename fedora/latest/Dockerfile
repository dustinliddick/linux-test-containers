FROM fedora:latest

RUN dnf update -y && \
    dnf install -y \
        systemd \
        curl \
        wget \
        ca-certificates \
        shadow-utils \
        util-linux \
        which && \
    dnf clean all

RUN systemctl set-default multi-user.target

VOLUME ["/sys/fs/cgroup"]

CMD ["/usr/sbin/init"]