FROM golang:1.25 AS builder

WORKDIR /build

RUN git clone https://github.com/markmnl/fmsg-webapi.git . && \
    cd src && \
    go build -o fmsg-webapi .

FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN useradd -r -s /bin/false fmsg

WORKDIR /opt/fmsg-webapi

COPY --from=builder /build/src/fmsg-webapi /opt/fmsg-webapi/fmsg-webapi

RUN chown -R fmsg:fmsg /opt/fmsg-webapi

USER fmsg

EXPOSE 8081

ENTRYPOINT ["/opt/fmsg-webapi/fmsg-webapi"]
