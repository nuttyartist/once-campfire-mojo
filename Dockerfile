# Build the toolchain once using bench/Dockerfile.tools, then build this image.
ARG TOOLCHAIN_IMAGE=campfire-local-tools:latest
FROM ${TOOLCHAIN_IMAGE} AS build
WORKDIR /build
COPY . .
RUN make -j3
RUN mkdir /mojo-runtime && cp /opt/mojo/lib/python3.13/site-packages/modular/lib/libKGENCompilerRTShared.so /opt/mojo/lib/python3.13/site-packages/modular/lib/libMSupportGlobals.so /opt/mojo/lib/python3.13/site-packages/modular/lib/libAsyncRTRuntimeGlobals.so /mojo-runtime/

FROM debian:trixie-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
    libcurl4t64 libcrypt1 libmagic1t64 libxml2 libvips42t64 ffmpeg poppler-utils \
    ca-certificates openssl python3 tini caddy && rm -rf /var/lib/apt/lists/* \
    && useradd --system --uid 10001 --create-home campfire
WORKDIR /app
COPY --from=build /build/build/campfire /app/campfire
COPY --from=build /mojo-runtime /usr/local/lib/mojo
COPY public /app/public
COPY deploy /app/deploy
COPY tools/manage.py /app/tools/manage.py
RUN test -s /app/campfire && test -s /app/deploy/start && test -s /app/tools/manage.py && test -s /app/public/service-worker.js \
    && mkdir -p /data && chown campfire:campfire /data
ENV LD_LIBRARY_PATH=/usr/local/lib/mojo BIND_ADDRESS=127.0.0.1 PORT=3000 \
    DATABASE_PATH=/data/production.sqlite3 STORAGE_PATH=/data/files PUBLIC_PATH=/app/public \
    CAMPFIRE_DATA=/data TRUSTED_PROXY_IP=127.0.0.1 XDG_DATA_HOME=/data/caddy XDG_CONFIG_HOME=/data/caddy
USER campfire
VOLUME /data
EXPOSE 8080 8443
ENTRYPOINT ["/usr/bin/tini","--","/app/deploy/start"]
