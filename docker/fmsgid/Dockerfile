FROM golang:1.18 AS builder

WORKDIR /build

RUN git clone https://github.com/markmnl/fmsgid.git . && \
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
