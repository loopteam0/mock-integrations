FROM wiremock/wiremock:3.9.2

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY scripts/download-extension.sh /usr/local/bin/download-extension.sh
RUN chmod +x /usr/local/bin/download-extension.sh && \
    /usr/local/bin/download-extension.sh /var/wiremock/extensions

COPY wiremock/mappings /home/wiremock/mappings
COPY wiremock/__files /home/wiremock/__files

RUN chmod -R a+rX /home/wiremock /var/wiremock/extensions

EXPOSE 8080

ENTRYPOINT ["/docker-entrypoint.sh"]
CMD ["--global-response-templating", "--verbose", "--max-template-cache-entries", "0"]
