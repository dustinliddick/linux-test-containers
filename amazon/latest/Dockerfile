FROM amazonlinux:latest

RUN yum update -y && \
    yum install -y \
        systemd \
        curl \
        wget \
        ca-certificates \
        shadow-utils \
        util-linux \
        which && \
    yum clean all

RUN systemctl set-default multi-user.target

VOLUME ["/sys/fs/cgroup"]

CMD ["/usr/sbin/init"]