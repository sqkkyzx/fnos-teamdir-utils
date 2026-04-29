#!/bin/bash

# 环境变量配置
CLEAN_MODE="${CLEAN_MODE:-0}"
DEFAULT_POOL_FOR_PERSONAL_DIR="${DEFAULT_POOL_FOR_PERSONAL_DIR:-2}"
CHECK_INTERVAL="${CHECK_INTERVAL:-60}" # 新增：轮询间隔，默认60秒
VERSION="${VERSION:-0.1.2}"

# 1. 输出项目 Banner
echo "#==============================#"
echo "#     FNOS-TEAMDIR-UTILS       #"
echo "#     VERSION $VERSION            #"
echo "#==============================#"

# 进入宿主机命名空间执行核心逻辑
nsenter -t 1 -m -u -i -n env CLEAN_MODE="$CLEAN_MODE" POOL_ID="$DEFAULT_POOL_FOR_PERSONAL_DIR" CHECK_INTERVAL="$CHECK_INTERVAL" bash << 'EOF'
    shopt -s nullglob

    log() {
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    }

    # 定义核心处理函数
    process_mounts() {
        # 获取宿主机上所有有效普通用户
        uids=$(awk -F: '$3 >= 1000 && $3 < 60000 {print $3}' /etc/passwd)

        for uid in $uids; do
            if [ "$uid" = "65534" ]; then continue; fi

            user_root="/vol1/${uid}"

            # 自动创建不存在的用户家目录
            if [ ! -d "$user_root" ]; then
                log "👤 检测到新用户或缺失目录 [UID: $uid]，正在初始化..."
                mkdir -p "$user_root"
                chown "$uid:$uid" "$user_root" 2>/dev/null || chown "$uid" "$user_root"
            fi

            # 1. 处理“个人文件”文件夹
            personal_dir="/vol${POOL_ID}/${uid}/个人文件"
            if [ ! -d "$personal_dir" ]; then
                mkdir -p "$personal_dir"
                chown "$uid:$uid" "$personal_dir" 2>/dev/null || chown "$uid" "$personal_dir"
            fi

            # 2. 遍历团队文件挂载
            for team_base in /vol*/@team; do
                [ ! -d "$team_base" ] && continue

                for team_dir in "$team_base"/*; do
                    [ ! -d "$team_dir" ] && continue

                    dir_name=$(basename "$team_dir")
                    target_mount="${user_root}/@团队文件-${dir_name}"

                    [ ! -d "$target_mount" ] && mkdir -p "$target_mount"

                    if mountpoint -q "$target_mount"; then
                        src_stat=$(stat -c "%d:%i" "$team_dir")
                        tgt_stat=$(stat -c "%d:%i" "$target_mount")
                        # 如果 inode 不匹配，说明挂载源变了或挂载错误，执行重挂
                        if [ "$src_stat" != "$tgt_stat" ]; then
                            log "⚠️ 用户 $uid 的 [$dir_name] 挂载不一致，正在修正..."
                            umount -l "$target_mount"
                            mount --bind "$team_dir" "$target_mount"
                        fi
                    else
                        mount --bind "$team_dir" "$target_mount"
                        log "🔗 用户 $uid 的 [$dir_name] 挂载成功。"
                    fi
                done
            done
        done
    }

    # ==========================================
    # 模式一：清理模式 (单次执行)
    # ==========================================
    if [ "$CLEAN_MODE" = "1" ]; then
        log "🧹 进入清理模式..."
        for target_mount in /vol1/*/@团队文件-*; do
            if mountpoint -q "$target_mount"; then
                umount -l "$target_mount"
                log "  🔓 已卸载: $target_mount"
            fi
            [ -d "$target_mount" ] && rmdir "$target_mount" 2>/dev/null
        done
        log "✅ 清理完成。"
        exit 0
    fi

    # ==========================================
    # 模式二：守护轮询模式 (持续运行)
    # ==========================================
    log "🚀 守护进程启动 (轮询间隔: ${CHECK_INTERVAL}s)..."
    while true; do
        process_mounts
        sleep "$CHECK_INTERVAL"
    done
EOF

# 清理模式执行完会 exit 0，从而走到这里
if [ "$CLEAN_MODE" = "1" ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] 任务结束，请手动停止容器。"
    tail -f /dev/null
fi