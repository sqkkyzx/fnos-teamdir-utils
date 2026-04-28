#!/bin/bash

# 环境变量配置
CLEAN_MODE="${CLEAN_MODE:-0}"
DEFAULT_POOL_FOR_PERSONAL_DIR="${DEFAULT_POOL_FOR_PERSONAL_DIR:-2}"
VERSION="${VERSION:-0.1.0}"

# 1. 输出项目 Banner
echo "#==============================#"
echo "#     FNOS-TEAMDIR-UTILS       #"
echo "#     VERSION $VERSION            #"
echo "#==============================#"

# 进入宿主机命名空间执行核心逻辑
nsenter -t 1 -m -u -i -n env CLEAN_MODE="$CLEAN_MODE" POOL_ID="$DEFAULT_POOL_FOR_PERSONAL_DIR" bash << 'EOF'
    shopt -s nullglob

    log() {
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    }

    # ==========================================
    # 模式一：清理模式
    # ==========================================
    if [ "$CLEAN_MODE" = "1" ]; then
        log "🧹 检测到 CLEAN_MODE=1，进入清理模式..."
        for target_mount in /vol1/*/@团队文件-*; do
            if mountpoint -q "$target_mount"; then
                umount "$target_mount"
                log "  🔓 已卸载: $target_mount"
            fi
            if [ -d "$target_mount" ]; then
                rmdir "$target_mount" 2>/dev/null && log "  🗑️ 已删除空挂载点: $target_mount"
            fi
        done
        log "✅ 清理任务完成。"
        exit 0
    fi

    # ==========================================
    # 模式二：挂载与初始化模式
    # ==========================================
    log "🚀 启动任务 (个人存储池: vol${POOL_ID})..."

    # 获取宿主机上所有 UID >= 1000 的普通用户 (过滤掉系统账号)
    # FNOS 的用户 UID 通常从 1000 开始
    uids=$(awk -F: '$3 >= 1000 && $3 < 60000 {print $3}' /etc/passwd)

    for uid in $uids; do
        # 排除掉特殊的系统 UID (如果有需要可以继续添加过滤)
        if [ "$uid" = "65534" ]; then continue; fi

        user_root="/vol1/${uid}"

        # 核心优化：如果 /vol1/uid 目录不存在（如用户 1006 ），则自动创建
        if [ ! -d "$user_root" ]; then
            log "👤 发现新用户 [UID: $uid]，正在创建基础家目录..."
            mkdir -p "$user_root"
            # 修正所属权，确保飞牛系统内该用户有权访问
            chown "$uid:$uid" "$user_root" 2>/dev/null || chown "$uid" "$user_root"
        fi

        log "📂 正在处理用户目录: $user_root"

        # 1. 处理“个人文件”文件夹
        personal_dir="/vol${POOL_ID}/${uid}/个人文件"
        if [ ! -d "$personal_dir" ]; then
            log "  📁 创建个人主目录: $personal_dir"
            mkdir -p "$personal_dir"
            chown "$uid:$uid" "$personal_dir" 2>/dev/null || chown "$uid" "$personal_dir"
        fi

        # 2. 处理“团队文件”挂载
        for team_base in /vol*/@team; do
            if [ ! -d "$team_base" ]; then continue; fi

            for team_dir in "$team_base"/*; do
                if [ ! -d "$team_dir" ]; then continue; fi

                dir_name=$(basename "$team_dir")
                target_mount="${user_root}/@团队文件-${dir_name}"

                mkdir -p "$target_mount"

                if mountpoint -q "$target_mount"; then
                    # 校验挂载源是否正确
                    src_stat=$(stat -c "%d:%i" "$team_dir")
                    tgt_stat=$(stat -c "%d:%i" "$target_mount")

                    if [ "$src_stat" == "$tgt_stat" ]; then
                        log "    ✅ [$dir_name] 已挂载，跳过。"
                    else
                        log "    ⚠️ [$dir_name] 源不匹配，重定向中..."
                        umount "$target_mount"
                        mount --bind "$team_dir" "$target_mount"
                    fi
                else
                    mount --bind "$team_dir" "$target_mount"
                    log "    🔗 [$dir_name] 挂载成功。"
                fi
            done
        done
    done
    log "✅ 所有操作执行完毕。"
EOF

# 保持容器运行状态
if [ "$CLEAN_MODE" = "1" ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] 容器已完成清理任务，请手动结束容器。"
else
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] 进入守护状态..."
fi

tail -f /dev/null