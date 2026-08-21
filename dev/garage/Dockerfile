# The garage image is a single static binary with no shell, so the layout and
# bucket setup cannot run inside it. This is that image plus a shell and the
# script, talking to the running node over RPC with the same config file.
FROM dxflrs/garage:v2.1.0 AS garage

FROM alpine:3.21
RUN apk add --no-cache jq
COPY --from=garage /garage /usr/local/bin/garage
COPY init.sh /usr/local/bin/init.sh
ENTRYPOINT ["/usr/local/bin/init.sh"]
