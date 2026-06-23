FROM alpine:latest

RUN apk add --no-cache bash util-linux

COPY entrypoint.sh /entrypoint.sh

RUN chmod +x /entrypoint.sh

ENV VERSION=0.1.7

# 设置容器启动时执行的脚本
ENTRYPOINT ["/entrypoint.sh"]
