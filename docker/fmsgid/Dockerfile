FROM golang:1.25 AS builder

ARG FMSGID_REF=main
ARG GIT_SSL_NO_VERIFY=
ARG CACHEBUST

WORKDIR /build

RUN if [ "$GIT_SSL_NO_VERIFY" = "true" ]; then \
      git config --global http.sslVerify false; \
      export GOINSECURE='*' GONOSUMDB='*' GONOSUMCHECK='*' GOPROXY=direct; \
    fi && \
    git clone --branch "$FMSGID_REF" --depth 1 https://github.com/markmnl/fmsgid.git . && \
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
