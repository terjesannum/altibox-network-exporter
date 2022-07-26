FROM perl:5.36.0-slim

LABEL org.opencontainers.image.authors="Terje Sannum <terje@offpiste.org>" \
      org.opencontainers.image.source="https://github.com/terjesannum/altibox-network-exporter"

RUN apt-get update \
        && apt-get install -y --no-install-recommends openssl gcc libc6-dev libssl-dev libz-dev \
        && cpanm JSON \
        && cpanm LWP::Protocol::https \
        && cpanm LWP::UserAgent \
        && cpanm HTTP::Server::Simple \
        && cpanm Prometheus::Tiny \
        && apt-get purge -y --auto-remove gcc libc6-dev libssl-dev libz-dev \
        && apt-get clean \
        && rm -rf /var/lib/apt/lists/*

ENV ALTIBOX_USER ""
ENV ALTIBOX_PASSWORD ""
ENV ALTIBOX_VERBOSE 0

COPY altibox-network-exporter.pl /

ENTRYPOINT [ "/altibox-network-exporter.pl" ]
