# Verification client image; uses the host daemon for disposable application images.
ARG TOOLCHAIN_IMAGE=campfire-local-tools:verified
FROM node:24-bookworm-slim AS node
FROM ${TOOLCHAIN_IMAGE}
COPY --from=node /usr/local/bin/node /usr/local/bin/node
RUN sed -i 's|http://deb.debian.org|https://deb.debian.org|g' /etc/apt/sources.list.d/debian.sources \
    && apt-get -o APT::Update::Error-Mode=any update \
    && apt-get install -y --no-install-recommends docker-cli \
    && rm -rf /var/lib/apt/lists/* \
    && docker --version && node --version
# Ruby's gzip reader uses the process locale when validating UTF-8 HTML.
ENV LANG=C.UTF-8 LC_ALL=C.UTF-8
