# Container Images

A collection of Docker container images for various Linux distributions, designed for testing and development purposes. These containers are similar to robertdebock's approach and include init system support.

## Available Images

### Alpine Linux
- `alpine/latest` - Latest Alpine with OpenRC
- `alpine/3.19` - Alpine 3.19 with OpenRC
- `alpine/3.18` - Alpine 3.18 with OpenRC

### Amazon Linux
- `amazon/latest` - Latest Amazon Linux with systemd
- `amazon/candidate` - Amazon Linux candidate with systemd
- `amazon/2023` - Amazon Linux 2023 with systemd

### Enterprise Linux
- `el/9` - CentOS Stream 9 with systemd

### Debian
- `debian/latest` - Latest Debian with systemd
- `debian/bookworm` - Debian 12 (Bookworm) with systemd
- `debian/bullseye` - Debian 11 (Bullseye) with systemd

### Fedora
- `fedora/latest` - Latest Fedora with systemd
- `fedora/40` - Fedora 40 with systemd
- `fedora/39` - Fedora 39 with systemd
- `fedora/38` - Fedora 38 with systemd

### Ubuntu
- `ubuntu/latest` - Latest Ubuntu with systemd
- `ubuntu/24.04` - Ubuntu 24.04 LTS with systemd
- `ubuntu/22.04` - Ubuntu 22.04 LTS with systemd
- `ubuntu/20.04` - Ubuntu 20.04 LTS with systemd

## Building Images

To build a specific image, navigate to the desired directory and run:

```bash
# Example: Build Alpine latest
cd alpine/latest
docker build -t myname/alpine:latest .

# Example: Build Ubuntu 22.04
cd ubuntu/22.04
docker build -t myname/ubuntu:22.04 .
```

## Running Containers

### For systemd-enabled containers (Debian, Ubuntu, Fedora, Amazon, EL):

```bash
docker run \
  --tty \
  --privileged \
  --volume /sys/fs/cgroup:/sys/fs/cgroup:ro \
  myname/ubuntu:22.04
```

### For OpenRC containers (Alpine):

```bash
docker run \
  --tty \
  --privileged \
  myname/alpine:latest
```

## Features

- **Init System Support**: All containers include their appropriate init system (systemd or OpenRC)
- **Common Tools**: Each container includes curl, wget, ca-certificates, and other essential utilities
- **Version Specific**: Multiple versions available for each distribution
- **Testing Ready**: Designed for testing Ansible roles, scripts, and applications

## Container Contents

All containers include:
- Appropriate init system (systemd/OpenRC)
- curl and wget
- CA certificates
- Shadow utilities for user management
- Distribution-specific package managers

## Use Cases

These containers are ideal for:
- Testing Ansible playbooks and roles
- CI/CD pipelines requiring specific OS versions
- Development environments
- Application testing across different distributions

## Directory Structure

```
.
├── alpine/
│   ├── 3.18/Dockerfile
│   ├── 3.19/Dockerfile
│   └── latest/Dockerfile
├── amazon/
│   ├── 2023/Dockerfile
│   ├── candidate/Dockerfile
│   └── latest/Dockerfile
├── debian/
│   ├── bookworm/Dockerfile
│   ├── bullseye/Dockerfile
│   └── latest/Dockerfile
├── el/
│   └── 9/Dockerfile
├── fedora/
│   ├── 38/Dockerfile
│   ├── 39/Dockerfile
│   ├── 40/Dockerfile
│   └── latest/Dockerfile
└── ubuntu/
    ├── 20.04/Dockerfile
    ├── 22.04/Dockerfile
    ├── 24.04/Dockerfile
    └── latest/Dockerfile
```