#!/bin/bash

# 环境变量配置
CLEAN_MODE="${CLEAN_MODE:-0}"
DEFAULT_POOL_FOR_PERSONAL_DIR="${DEFAULT_POOL_FOR_PERSONAL_DIR:-2}"
CHECK_INTERVAL="${CHECK_INTERVAL:-60}" # 轮询间隔，默认60秒
VERSION="${VERSION:-0.1.3}"

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

            # ==========================================================
            # 0. 初始化 /vol1 的用户挂载根目录
            # ==========================================================
            user_root="/vol1/${uid}"
            if [ ! -d "$user_root" ]; then
                log "👤 检测到新用户或缺失挂载根目录 [UID: $uid]，正在初始化..."
                mkdir -p "$user_root"
                # 适配 FNOS 权限规范：父目录归属 UID:root，权限 771
                chown "$uid:root" "$user_root" 2>/dev/null || chown "$uid" "$user_root"
                chmod 771 "$user_root"
            fi

            # ==========================================================
            # 1. 初始化用户个人存储池父目录 (如 /vol2/1000)
            # ==========================================================
            personal_base="/vol${POOL_ID}/${uid}"
            if [ ! -d "$personal_base" ]; then
                mkdir -p "$personal_base"
                # 适配 FNOS 权限规范：父目录归属 UID:root，权限 771
                chown "$uid:root" "$personal_base" 2>/dev/null || chown "$uid" "$personal_base"
                chmod 771 "$personal_base"
            fi

            # ==========================================================
            # 2. 处理“个人文件”子目录，并注入 FNOS 标准 ACL (+)
            # ==========================================================
            personal_dir="${personal_base}/个人文件"
            if [ ! -d "$personal_dir" ]; then
                log "  📁 创建个人主目录并注入底层权限: $personal_dir"
                mkdir -p "$personal_dir"
                # 适配 FNOS 权限规范：子目录归属 UID:Users，权限 771
                chown "$uid:Users" "$personal_dir" 2>/dev/null || chown "$uid" "$personal_dir"
                chmod 771 "$personal_dir"

                # 显式注入 ACL 权限，生成 '+' 号，确保被 FNOS 数据库和 SMB 识别
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