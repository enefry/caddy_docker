FROM golang:1.13-alpine as builder
RUN apk add --no-cache git gcc musl-dev
RUN mkdir /www /caddy
COPY builder.sh /usr/bin/builder.sh
ARG version="1.0.5"
RUN VERSION=${version} /bin/sh /usr/bin/builder.sh


FROM alpine:latest

ENV CADDY_VERSION=1.0.5

ENV CADDYPATH=/caddy/certs

RUN apk add --no-cache \
    ca-certificates \
    git \
    mailcap \
    openssh-client \
    tzdata


COPY --from=builder /install/caddy /usr/bin/caddy

RUN /usr/bin/caddy -version
RUN /usr/bin/caddy -plugins

EXPOSE 80 443

COPY Caddyfile /etc/caddy/Caddyfile

CMD ["caddy","--conf", "/etc/caddy/caddy.conf", "--log", "stdout", "--agree"]
