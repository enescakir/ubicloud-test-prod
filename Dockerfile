FROM golang:1.22.5-alpine3.20

RUN set -ex && apk add --update --no-cache git wget tar openssh bash util-linux-dev musl-dev build-base openssl curl && wget -q https://github.com/golang-migrate/migrate/releases/download/v4.14.1/migrate.linux-amd64.tar.gz -O - | tar -zxf - && mv migrate.linux-amd64 /bin/migrate && chmod +x /bin/migrate && git config --global credential.helper store

COPY . /app

WORKDIR /app

RUN GODEBUG=gocache=1,gomodule=1 go mod download -x
# RUN go mod download
