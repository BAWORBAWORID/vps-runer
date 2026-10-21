FROM ubuntu:24.04

LABEL maintainer="VpsFree"
LABEL description="Containerized Ubuntu Server VPS with Tailscale & SSH"

ENV DEBIAN_FRONTEND=noninteractive

# Pasang paket dasar dan repositori Tailscale resmi
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    gnupg \
    iptables \
    iproute2 \
    sudo \
    openssh-server \
    jq \
    procps \
    net-tools \
    bash \
    tzdata \
    && curl -fsSL https://tailscale.com/install.sh | sh \
    && apt-get clean && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /var/run/sshd /var/run/tailscale /var/lib/tailscale /etc/ssh/sshd_config.d

# Konfigurasi SSH Server (root login + password auth)
RUN echo "PermitRootLogin yes" > /etc/ssh/sshd_config.d/99-vpsfree.conf \
    && echo "PasswordAuthentication yes" >> /etc/ssh/sshd_config.d/99-vpsfree.conf \
    && echo "PubkeyAuthentication yes" >> /etc/ssh/sshd_config.d/99-vpsfree.conf

# Salin entrypoint script
COPY scripts/docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

EXPOSE 22

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
