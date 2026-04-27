#!/bin/bash
# 注意：此脚本的外部环境处于 Docker 容器内

echo "🚀 容器启动：开始初始化目录映射..."

# 通过 heredoc 将核心逻辑打包，传给宿主机的 bash 执行
nsenter -t 1 -m -u -i -n env DEFAULT_POOL_FOR_PERSONAL_DIR="${DEFAULT_POOL_FOR_PERSONAL_DIR}" bash << 'EOF'
    shopt -s nullglob
    POOL_ID="${DEFAULT_POOL_FOR_PERSONAL_DIR:-2}"

    echo "🔍 开始扫描 /vol1 下的用户目录..."
    for user_dir in /vol1/*; do
        uid=$(basename "$user_dir")
        if [[ ! "$uid" =~ ^[0-9]+$ ]]; then continue; fi

        # --- 处理个人文件夹 ---
        personal_dir="/vol${POOL_ID}/${uid}/个人文件"
        if [ ! -d "$personal_dir" ]; then
            mkdir -p "$personal_dir"
            chown "$uid:$uid" "$personal_dir" 2>/dev/null || chown "$uid" "$personal_dir"
            echo "📁 创建个人主目录并转移所有权: $personal_dir"
        fi

        # --- 处理团队文件夹映射 ---
        for team_base in /vol*/@team; do
            for team_dir in "$team_base"/*; do
                if [ ! -d "$team_dir" ]; then continue; fi

                dir_name=$(basename "$team_dir")
                target_mount="/vol1/${uid}/@团队文件-${dir_name}"

                mkdir -p "$target_mount"

                if ! mountpoint -q "$target_mount"; then
                    mount --bind "$team_dir" "$target_mount"
                    echo "🔗 建立映射: $team_dir -> $target_mount"
                fi
            done
        done
    done
EOF
echo "✅ 挂载初始化完毕。进入守护进程状态..."

# 定义清理函数
cleanup() {
    echo "🛑 收到停止信号：开始清理团队文件映射..."
    nsenter -t 1 -m -u -i -n bash << 'EOF'
        shopt -s nullglob
        for target_mount in /vol1/*/@团队文件-*; do
            if mountpoint -q "$target_mount"; then
                umount "$target_mount"
                echo "🔓 已卸载: $target_mount"
            fi
            if [ -d "$target_mount" ]; then
                rmdir "$target_mount" 2>/dev/null && echo "🗑️ 已删除空挂载点: $target_mount"
            fi
        done
EOF
    echo "✅ 清理完毕，容器退出。"
    exit 0
}

# 捕获终止信号并执行 cleanup 函数 (SIGINT 对应 Ctrl+C, SIGTERM 对应 docker stop)
trap cleanup SIGINT SIGTERM

# 保持容器运行以维持生命周期
tail -f /dev/null