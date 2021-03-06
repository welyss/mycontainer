FROM debian:stretch-slim

COPY hbec-db-monitor /usr/local/bin/
COPY healthcheck.sh /usr/local/bin/healthcheck.sh
RUN chmod +x /usr/local/bin/healthcheck.sh
RUN chmod +x /usr/local/bin/hbec-db-monitor

ENTRYPOINT ["hbec-db-monitor"]

EXPOSE 8080