FROM alpine:latest

RUN apk add --no-cache bash util-linux

COPY entrypoint.sh /entrypoint.sh

RUN chmod +x /entrypoint.sh

# 声明默认环境变量
ENV DEFAULT_POOL_FOR_PERSONAL_DIR=1
ENV VERSION=0.1.4

# 设置容器启动时执行的脚本
ENTRYPOINT ["/entrypoint.sh"]