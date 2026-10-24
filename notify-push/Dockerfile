# syntax=docker/dockerfile:1.6
# The push server of the app notify_push («Client Push»): the static binary of
# the latest release of the app, nothing else. The weekly rebuild takes a new
# release along, as the App Store updates the app.
FROM mwaeckerlin/build AS build
ARG TARGETARCH
ADD --chmod=755 https://github.com/nextcloud/notify_push/releases/latest/download/notify_push-x86_64-unknown-linux-musl /tmp/notify_push-amd64
ADD --chmod=755 https://github.com/nextcloud/notify_push/releases/latest/download/notify_push-aarch64-unknown-linux-musl /tmp/notify_push-arm64
RUN mkdir -p /tmp/out/usr/bin && cp /tmp/notify_push-${TARGETARCH:-amd64} /tmp/out/usr/bin/notify_push

FROM mwaeckerlin/scratch
# The database comes from config.php of the config volume, mounted read-only;
# Redis and the address of Nextcloud from these variables.
ENV CONTAINERNAME="notify-push" \
    PORT="7867" \
    NEXTCLOUD_URL="http://nextcloud-nginx:8080" \
    REDIS_URL="redis://redis"
EXPOSE 7867
ENTRYPOINT ["/usr/bin/notify_push", "/app/config/config.php"]
COPY --from=build /tmp/out/ /
