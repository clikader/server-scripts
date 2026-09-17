FROM debian:13
ENV DEBIAN_FRONTEND=noninteractive container=docker
RUN apt-get update && apt-get install -y --no-install-recommends \
    systemd systemd-sysv systemd-resolved dns-root-data dbus openssh-server openssh-client nftables iproute2 \
    procps jq curl ca-certificates fail2ban python3-systemd unbound dnsutils \
    netplan.io ifupdown unattended-upgrades util-linux shellcheck \
    && rm -rf /var/lib/apt/lists/*
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
