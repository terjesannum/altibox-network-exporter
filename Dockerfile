FROM perl:5.36.0-slim

LABEL org.opencontainers.image.title="altibox-network-exporter" \
      org.opencontainers.image.description="Prometheus exporter for Altibox networks" \
      org.opencontainers.image.authors="Terje Sannum <terje@offpiste.org>" \
      org.opencontainers.image.source="https://github.com/terjesannum/altibox-network-exporter" \
      org.opencontainers.image.url="https://github.com/terjesannum/altibox-network-exporter"

ENV PERL_CPANM_OPT "--configure-timeout=600 --build-timeout=7200 --test-timeout=7200"

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

USER 65532:65532

ENTRYPOINT [ "/altibox-network-exporter.pl" ]
