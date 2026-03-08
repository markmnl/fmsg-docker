FROM golang:1.25 AS builder

WORKDIR /build

RUN git clone https://github.com/markmnl/fmsgd.git . && \
    cd src && \
    go build -o fmsgd .

FROM debian:bookworm-slim

RUN useradd -r -s /bin/false fmsg

WORKDIR /opt/fmsgd

COPY --from=builder /build/src/fmsgd /opt/fmsgd/fmsgd

RUN mkdir -p /opt/fmsg/data && \
    chown -R fmsg:fmsg /opt/fmsgd /opt/fmsg/data

USER fmsg

EXPOSE 4930

ENTRYPOINT ["/opt/fmsgd/fmsgd", "0.0.0.0"]
