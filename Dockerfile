# Build the toolchain once using bench/Dockerfile.tools, then build this image.
ARG TOOLCHAIN_IMAGE=campfire-local-tools:verified
FROM ${TOOLCHAIN_IMAGE} AS build
ARG GIT_REVISION=unknown
ENV GIT_REVISION=${GIT_REVISION}
WORKDIR /build
COPY . .
RUN make -j3
RUN mkdir /mojo-runtime && cp /opt/mojo/lib/python3.13/site-packages/modular/lib/libKGENCompilerRTShared.so /opt/mojo/lib/python3.13/site-packages/modular/lib/libMSupportGlobals.so /opt/mojo/lib/python3.13/site-packages/modular/lib/libAsyncRTRuntimeGlobals.so /mojo-runtime/

FROM debian:trixie-slim
ARG GIT_REVISION=unknown
ARG APP_VERSION=0.1.0-dev
ARG SOURCE_URL=local
LABEL org.opencontainers.image.title="Campfire in Mojo" \
    org.opencontainers.image.description="Campfire chat for Linux and local Disk storage; independent Mojo port" \
    org.opencontainers.image.version=${APP_VERSION} \
    org.opencontainers.image.revision=${GIT_REVISION} \
    org.opencontainers.image.source=${SOURCE_URL} \
    org.opencontainers.image.licenses="MIT"
# Bootstrap HTTPS trust from the pinned build image before installing packages.
COPY --from=build /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
RUN sed -i 's|http://deb.debian.org|https://deb.debian.org|g' /etc/apt/sources.list.d/debian.sources \
    && apt-get -o Acquire::https::CaInfo=/etc/ssl/certs/ca-certificates.crt -o APT::Update::Error-Mode=any update \
    && apt-get -o Acquire::https::CaInfo=/etc/ssl/certs/ca-certificates.crt install -y --no-install-recommends \
    libcurl4t64 libcrypt1 libmagic1t64 libxml2 libvips42t64 ffmpeg poppler-utils \
    ca-certificates openssl python3 tini caddy && rm -rf /var/lib/apt/lists/* \
    && useradd --system --uid 10001 --create-home campfire
WORKDIR /app
COPY --from=build /build/build/campfire /app/campfire
COPY --from=build /mojo-runtime /usr/local/lib/mojo
COPY public /app/public
COPY deploy /app/deploy
COPY tools/manage.py tools/schema_contract.json /app/tools/
COPY MIT-LICENSE THIRD_PARTY_NOTICES.md /app/
COPY licenses /app/licenses
COPY --from=build /build/VERSION /app/VERSION
COPY --from=build /build/build/generated/build_info.mojo /app/build-info.txt
RUN test -s /app/campfire && test -s /app/deploy/start && test -s /app/tools/manage.py && test -s /app/public/service-worker.js \
    && mkdir -p /data && chown campfire:campfire /data
ENV LD_LIBRARY_PATH=/usr/local/lib/mojo BIND_ADDRESS=127.0.0.1 PORT=3000 \
    DATABASE_PATH=/data/production.sqlite3 STORAGE_PATH=/data/files PUBLIC_PATH=/app/public \
    CAMPFIRE_DATA=/data TRUSTED_PROXY_IP=127.0.0.1 XDG_DATA_HOME=/data/caddy XDG_CONFIG_HOME=/data/caddy
USER campfire
VOLUME /data
EXPOSE 8080 8443
ENTRYPOINT ["/usr/bin/tini","--","/app/deploy/start"]
