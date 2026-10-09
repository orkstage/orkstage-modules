# OpenTofu runner with the OrkStage module library baked in at /modules (read-only).
# The worker starts one throwaway container from this image per OpenTofu command.
# The official image must not be used as a base (it fails on purpose); copy the binary from the
# minimal image instead, as documented at https://opentofu.org/docs/intro/install/docker/.
FROM ghcr.io/opentofu/opentofu:1.12.7-minimal AS tofu

# Official Alpine image through mirror.gcr.io (Google's Docker Hub cache): anonymous pulls from
# Docker Hub and ECR Public on shared CI runners hit rate limits.
FROM mirror.gcr.io/library/alpine:3.24
RUN apk add --no-cache ca-certificates git
COPY --from=tofu /usr/local/bin/tofu /usr/local/bin/tofu
COPY modules /modules
ENTRYPOINT ["tofu"]
