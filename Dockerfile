FROM golang:1.22

WORKDIR /usr/src/app

COPY . .

RUN go get github.com/ericlagergren/decimal

RUN go build -v -o /usr/local/bin/mockserver .

ENTRYPOINT ["mockserver"]