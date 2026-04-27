#!/bin/bash
# 注意：此脚本的外部环境处于 Docker 容器内

# 接收环境变量，若未设置则赋予默认值
CLEAN_MODE="${CLEAN_MODE:-0}"
DEFAULT_POOL_FOR_PERSONAL_DIR="${DEFAULT_POOL_FOR_PERSONAL_DIR:-2}"

# 通过 heredoc 将核心逻辑和环境变量传递给宿主机的 bash 执行
nsenter -t 1 -m -u -i -n env CLEAN_MODE="$CLEAN_MODE" POOL_ID="$DEFAULT_POOL_FOR_PERSONAL_DIR" bash << 'EOF'
    shopt -s nullglob

    # 统一定义日志函数，包含时间戳输出
    log() {
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    }

    # ==========================================
    # 模式一：清理模式 (CLEAN_MODE=1)
    # ==========================================
    if [ "$CLEAN_MODE" = "1" ]; then
        log "🧹 检测到 CLEAN_MODE=1，进入清理挂载模式..."
        for target_mount in /vol1/*/@团队文件-*; do
            log "  -> 发现挂载点目标: $target_mount"

            if mountpoint -q "$target_mount"; then
                umount "$target_mount"
                log "  🔓 已卸载: $target_mount"
            fi

            if [ -d "$target_mount" ]; then
                rmdir "$target_mount" 2>/dev/null && log "  🗑️ 已删除空挂载目录: $target_mount"
            fi
        done
        log "✅ 清理任务完成。"
        exit 0
    fi

    # ==========================================
    # 模式二：常规挂载模式 (CLEAN_MODE=0 或空)
    # ==========================================
    log "🚀 启动目录映射任务 (个人主目录存储池: vol${POOL_ID})..."

    # 1. 遍历 /vol1 下的用户 UID 目录
    for user_dir in /vol1/*; do
        uid=$(basename "$user_dir")
        if [[ ! "$uid" =~ ^[0-9]+$ ]]; then continue; fi

        log "👤 正在处理用户目录 [UID: $uid]"

        # 2. 处理个人文件夹
        personal_dir="/vol${POOL_ID}/${uid}/个人文件"
        if [ ! -d "$personal_dir" ]; then
            log "  📁 个人目录不存在，开始创建并修正权限: $personal_dir"
            mkdir -p "$personal_dir"
            chown "$uid:$uid" "$personal_dir" 2>/dev/null || chown "$uid" "$personal_dir"
        fi

        # 3. 遍历 /vol*/@team 寻找团队目录
        for team_base in /vol*/@team; do
            if [ ! -d "$team_base" ]; then continue; fi
            log "  📂 扫描团队基础存储池: $team_base"

            # 4. 遍历具体的项目目录
            for team_dir in "$team_base"/*; do
                if [ ! -d "$team_dir" ]; then continue; fi

                dir_name=$(basename "$team_dir")
                target_mount="/vol1/${uid}/@团队文件-${dir_name}"

                mkdir -p "$target_mount"

                # 5. 核心逻辑：挂载状态检测与自愈修复
                if mountpoint -q "$target_mount"; then
                    # 获取源目录和目标目录的底层 inode 标识信息 (格式为 DeviceID:InodeID)
                    src_stat=$(stat -c "%d:%i" "$team_dir")
                    tgt_stat=$(stat -c "%d:%i" "$target_mount")

                    if [ "$src_stat" == "$tgt_stat" ]; then
                        log "    ✅ [$dir_name] 挂载状态正确，跳过。"
                    else
                        log "    ⚠️ [$dir_name] 挂载源不匹配 (可能发生过变更)，正在修复..."
                        umount "$target_mount"
                        mount --bind "$team_dir" "$target_mount"
                        log "    🔄 [$dir_name] 重新绑定成功: $team_dir -> $target_mount"
                    fi
                else
                    # 完全未挂载的情况
                    mount --bind "$team_dir" "$target_mount"
                    log "    🔗 [$dir_name] 新建映射成功: $team_dir -> $target_mount"
                fi
            done
        done
    done
    log "✅ 所有目录映射处理完毕。"
EOF

# 判断刚才宿主机的脚本执行完后的状态，决定容器的去留
if [ "$CLEAN_MODE" = "1" ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] 容器已完成清理任务，请手动结束容器"
    tail -f /dev/null
else
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] 挂载进程结束，进入守护状态保持容器运行..."
    # 挂起容器，保持其 Running 状态
    tail -f /dev/null
fi