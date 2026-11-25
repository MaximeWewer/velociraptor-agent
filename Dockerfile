# syntax=docker/dockerfile:1
#
# Velociraptor agent (client) image - multi-arch (amd64 + arm64).
#
# Unlike the server image (velociraptor-docker: distroless/static, uid 65532), the agent
# runs as root: a forensic agent only sees what its privileges let it see (host processes
# via hostPID, host filesystem via a read-only hostPath). Hardening is done by the chart
# (read-only rootfs, targeted capabilities, read-only host mount), not by dropping root.
#
# Base: distroless/base-debian13 (glibc 2.41). The upstream linux-amd64 / linux-arm64
# binaries are dynamically linked against glibc and require GLIBC_2.38: debian12
# (glibc 2.36) does NOT work. There is no static musl build for arm64, so both arches use
# the glibc build for a single, uniform image.
#
# Targets:
#   runtime (default) - binary only, no shell
#   debug             - same + busybox shell (distroless :debug), for troubleshooting

# ---- fetch + verify stage ----
FROM --platform=$BUILDPLATFORM alpine:3.24 AS fetch

ARG VELO_VERSION=v0.77.4
# sha256 of the release assets velociraptor-${VELO_VERSION}-linux-<arch>.gz (pinned,
# verified at build). Updated by .github/workflows/update-versions.yml.
ARG VELO_SHA256_AMD64=890c1b8458276909cfbbfb2edad2e0b9c31672b95532e41516c39d2537925157
ARG VELO_SHA256_ARM64=908eda7aaaf46f4a988b282cabbe7844c273ad185d5c9846aa33518ff5e2708c
ARG TARGETARCH

RUN apk add --no-cache curl
WORKDIR /out
RUN set -eux; \
    case "${TARGETARCH}" in \
      amd64) SHA="${VELO_SHA256_AMD64}" ;; \
      arm64) SHA="${VELO_SHA256_ARM64}" ;; \
      *) echo "ERROR: unsupported arch ${TARGETARCH} (amd64, arm64 only)" >&2; exit 1 ;; \
    esac; \
    curl -fsSL -o velociraptor.gz \
      "https://github.com/Velocidex/velociraptor/releases/download/${VELO_VERSION}/velociraptor-${VELO_VERSION}-linux-${TARGETARCH}.gz"; \
    echo "${SHA}  velociraptor.gz" | sha256sum -c -; \
    gunzip velociraptor.gz; \
    chmod 0755 velociraptor; \
    # Default paths of an unmodified client config (writeback in /etc, local buffer in
    # /var/tmp) must exist when the config is used as-is (ephemeral container mode).
    mkdir -p /dirs/var/tmp /dirs/var/lib/velociraptor && chmod 1777 /dirs/var/tmp

# ---- runtime ----
FROM gcr.io/distroless/base-debian13 AS runtime

LABEL org.opencontainers.image.title="velociraptor-agent"
LABEL org.opencontainers.image.description="Velociraptor DFIR agent (client) - multi-arch, distroless"
LABEL org.opencontainers.image.licenses="AGPL-3.0-or-later"

COPY --from=fetch /out/velociraptor /velociraptor
COPY --from=fetch /dirs/ /

# Root on purpose (see header). distroless/base default user is root.
USER 0:0
ENTRYPOINT ["/velociraptor"]
CMD ["--config", "/etc/velociraptor/client.config.yaml", "client", "-v"]

# ---- debug ----
FROM gcr.io/distroless/base-debian13:debug AS debug

LABEL org.opencontainers.image.title="velociraptor-agent"
LABEL org.opencontainers.image.description="Velociraptor DFIR agent (client) - debug variant with busybox"
LABEL org.opencontainers.image.licenses="AGPL-3.0-or-later"

COPY --from=fetch /out/velociraptor /velociraptor
COPY --from=fetch /dirs/ /

USER 0:0
ENTRYPOINT ["/velociraptor"]
CMD ["--config", "/etc/velociraptor/client.config.yaml", "client", "-v"]

# Default target = runtime (last stage wins otherwise).
FROM runtime
