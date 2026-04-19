FROM golang:1.25 AS builder

ARG FMSG_WEBAPI_REF=main
ARG CACHEBUST

WORKDIR /build

RUN git clone --branch "$FMSG_WEBAPI_REF" --depth 1 https://github.com/markmnl/fmsg-webapi.git . && \
    cd src && \
    go build -o fmsg-webapi .

FROM debian:bookworm-slim

RUN useradd -r -s /bin/false fmsg

WORKDIR /opt/fmsg-webapi

COPY --from=builder /build/src/fmsg-webapi /opt/fmsg-webapi/fmsg-webapi

RUN chown -R fmsg:fmsg /opt/fmsg-webapi

USER fmsg

EXPOSE 8081

ENTRYPOINT ["/opt/fmsg-webapi/fmsg-webapi"]
