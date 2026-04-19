FROM golang:1.25 AS builder

ARG FMSGID_REF=main
ARG CACHEBUST

WORKDIR /build

RUN git clone --branch "$FMSGID_REF" --depth 1 https://github.com/markmnl/fmsgid.git . && \
    cd src && \
    go build -o fmsgid .

FROM debian:bookworm-slim

RUN useradd -r -s /bin/false fmsg

WORKDIR /opt/fmsgid

COPY --from=builder /build/src/fmsgid /opt/fmsgid/fmsgid

RUN chown -R fmsg:fmsg /opt/fmsgid

USER fmsg

EXPOSE 8080

ENTRYPOINT ["/opt/fmsgid/fmsgid"]
