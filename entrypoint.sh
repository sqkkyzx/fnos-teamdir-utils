#!/bin/bash

# 环境变量配置
CLEAN_MODE="${CLEAN_MODE:-0}"
DEFAULT_POOL_FOR_PERSONAL_DIR="${DEFAULT_POOL_FOR_PERSONAL_DIR:-2}"
CHECK_INTERVAL="${CHECK_INTERVAL:-60}" # 轮询间隔，默认60秒
VERSION="${VERSION:-0.1.5}"

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

    # 定义核心处理函数，接收一个参数：是否为首次运行 (1为是，0为否)
    process_mounts() {
        local is_first_run="$1"
        # 获取宿主机上所有有效普通用户，同时提取 UID 和 用户名 (格式: UID:用户名)
        user_list=$(awk -F: '$3 >= 1000 && $3 < 60000 {print $3 ":" $1}' /etc/passwd)

        for user_item in $user_list; do
            # 解析出 UID 和 Username
            uid="${user_item%%:*}"
            username="${user_item#*:}"

            if [ "$uid" = "65534" ]; then continue; fi

            [ "$is_first_run" = "1" ] && log "👤 正在检查用户 $username [UID: $uid]..."

            # ==========================================================
            # 0. 初始化 /vol1 的用户挂载根目录
            # ==========================================================
            user_root="/vol1/${uid}"
            if [ ! -d "$user_root" ]; then
                log "  👤 检测到新用户 $username 挂载根目录缺失，正在初始化..."
                mkdir -p "$user_root"
                chown "$uid:root" "$user_root" 2>/dev/null || chown "$uid" "$user_root"
                chmod 771 "$user_root"
            fi

            # ==========================================================
            # 1. 初始化用户个人存储池父目录 (如 /vol2/1000)
            # ==========================================================
            personal_base="/vol${POOL_ID}/${uid}"
            if [ ! -d "$personal_base" ]; then
                mkdir -p "$personal_base"
                chown "$uid:root" "$personal_base" 2>/dev/null || chown "$uid" "$personal_base"
                chmod 771 "$personal_base"
            fi

            # ==========================================================
            # 2. 处理“个人文件”子目录，并注入 FNOS 标准 ACL (+)
            # ==========================================================
            personal_dir="${personal_base}/个人文件"
            if [ ! -d "$personal_dir" ]; then
                log "  📁 为 $username 创建个人主目录并注入底层权限: $personal_dir"
                mkdir -p "$personal_dir"
                chown "$uid:Users" "$personal_dir" 2>/dev/null || chown "$uid" "$personal_dir"
                chmod 771 "$personal_dir"

                setfacl -m u::rwx,g::--x,o::--x "$personal_dir" 2>/dev/null
                setfacl -d -m u::rwx,g::--x,o::--x "$personal_dir" 2>/dev/null
            fi

            # ==========================================================
            # 3. 遍历团队文件挂载
            # ==========================================================
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

                        if [ "$src_stat" != "$tgt_stat" ]; then
                            log "  ⚠️ 用户 $username [$uid] 的 [$dir_name] 挂载不一致，正在修正..."
                            umount -l "$target_mount"
                            mount --bind "$team_dir" "$target_mount"
                        else
                            # 仅在首次运行时，输出“状态正常，跳过”的日志
                            [ "$is_first_run" = "1" ] && log "    ✅ [$dir_name] 挂载状态正常，已跳过。"
                        fi
                    else
                        mount --bind "$team_dir" "$target_mount"
                        log "  🔗 用户 $username [$uid] 的 [$dir_name] 挂载成功。"
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

    first_run_flag=1

    while true; do
        if [ "$first_run_flag" = "1" ]; then
            log "=================================================="
            log "🚀 开始首次全量扫描与初始化 (个人存储池: vol${POOL_ID})"
            log "=================================================="
        fi

        # 执行核心逻辑，并传入当前是否为首次运行的标记
        process_mounts "$first_run_flag"

        if [ "$first_run_flag" = "1" ]; then
            log "=================================================="
            log "✅ 首次初始化扫描完毕。进入静默轮询模式..."
            log "💡 提示：后续仅在发现新用户或挂载变动时输出日志"
            log "=================================================="
            first_run_flag=0
        fi

        sleep "$CHECK_INTERVAL"
    done
EOF

# 清理模式执行完会 exit 0，从而走到这里
if [ "$CLEAN_MODE" = "1" ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] 任务结束，请手动停止容器。"
    tail -f /dev/null
fi