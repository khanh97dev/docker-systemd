FROM debian:13-slim

ARG TARGETARCH
ARG CLOUDFLARED_VERSION=2026.10.2
ARG DEBIAN_FRONTEND=noninteractive

# systemd cần biết nó đang trong container
ENV container=docker \
    TZ=Australia/Sydney

RUN apt-get update && apt-get install -y --no-install-recommends \
      systemd systemd-sysv dbus dbus-user-session \
      openssh-server \
      cron \
      ca-certificates \
      curl \
      tzdata \
      procps \
 && rm -rf /var/lib/apt/lists/*

# ---- cloudflared: .deb chính thức, pin version + verify sha256 ----
RUN set -eux; \
    case "${TARGETARCH:-arm64}" in \
      arm64) SHA=2e5335ea0ef2fa98e5354357e77aaf453f3756d1f9023cf5b063409e1fb3baca ;; \
      amd64) SHA=30a9a127c24ea8365fa8e11b13684128f34dd8a1137599aa00b4bebda1a0a083 ;; \
      *) echo "arch không hỗ trợ: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    curl -fsSL -o /tmp/cloudflared.deb \
      "https://github.com/cloudflare/cloudflared/releases/download/${CLOUDFLARED_VERSION}/cloudflared-linux-${TARGETARCH:-arm64}.deb"; \
    echo "${SHA}  /tmp/cloudflared.deb" | sha256sum -c -; \
    dpkg -i /tmp/cloudflared.deb; \
    rm -f /tmp/cloudflared.deb; \
    cloudflared --version

# ---- Mask unit không chạy được / không cần trong container ----
# Không mask -> systemd báo "degraded" vì các unit này fail.
RUN systemctl mask \
      systemd-udevd.service \
      systemd-udevd-kernel.socket \
      systemd-udevd-control.socket \
      systemd-modules-load.service \
      systemd-journald-audit.socket \
      sys-kernel-debug.mount \
      sys-kernel-tracing.mount \
      sys-kernel-config.mount \
      systemd-oomd.service \
 && rm -f /lib/systemd/system/multi-user.target.wants/getty.target

COPY units/ /etc/systemd/system/
COPY bin/ /usr/local/sbin/
RUN chmod +x /usr/local/sbin/*.sh

# sshd host keys (bỏ dòng này nếu không cần ssh)
RUN ssh-keygen -A

# Bật service. cloudflared KHÔNG enable sẵn - cần token trước (xem README).
RUN systemctl enable ssh.service cron.service app.service

EXPOSE 22

HEALTHCHECK --interval=30s --timeout=10s --start-period=40s --retries=3 \
  CMD /usr/local/sbin/healthcheck.sh

# systemd shutdown bằng SIGRTMIN+3, không phải SIGTERM
STOPSIGNAL SIGRTMIN+3

CMD ["/sbin/init"]
