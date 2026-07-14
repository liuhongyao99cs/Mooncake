#!/usr/bin/env bash
# server_mc.sh - 启动 SGLang server, L3 用 Mooncake 分布式 KV cache (DRAM + SSD 多级)
#
# 多级 KV cache 架构:
#   L1 = GPU 显存      (--mem-fraction-static 控制)
#   L2 = host DRAM     (--hicache-ratio 控制, 本机内存)
#   L3 = Mooncake 池   (分布式 DRAM + SSD offload)
#        ├─ DRAM 层:  MOONCAKE_GLOBAL_SEGMENT_SIZE 贡献的内存
#        └─ SSD 层:   DRAM 不够时 spill 到 MOONCAKE_OFFLOAD_FILE_STORAGE_PATH
#
# 用法:
#   终端 1: ./mooncake_master.sh     # 先启动 master (常驻)
#   终端 2: ./server_mc.sh           # 再启动 SGLang server
#
export LD_LIBRARY_PATH=/usr/local/cuda/lib64:$LD_LIBRARY_PATH
set -euo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------- 自定义 Mooncake 编译版本 (不覆盖系统安装) ----------
# 设 MC_CUSTOM_DIR=/path/to/Mooncake 即可让 SGLang import 自定义编译的 mooncake,
# 不需要 pip install --force-reinstall, 不影响系统已安装的版本.
# 原理: 把 mooncake-wheel/ 目录插到 PYTHONPATH 最前面, Python 会优先从这里 import.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MC_CUSTOM_DIR="${MC_CUSTOM_DIR:-}"
if [[ -n "$MC_CUSTOM_DIR" ]]; then
    MC_WHEEL_DIR="${MC_CUSTOM_DIR}/mooncake-wheel"
    if [[ ! -f "${MC_WHEEL_DIR}/mooncake/store.so" ]]; then
        echo "[mooncake] ERROR: MC_CUSTOM_DIR=$MC_CUSTOM_DIR 但找不到 mooncake Python 包:"
        echo "[mooncake]        ${MC_WHEEL_DIR}/mooncake/store.so"
        echo "[mooncake]        请先编译并执行: cd ${MC_CUSTOM_DIR} && OUTPUT_DIR=dist ./scripts/build_wheel.sh"
        exit 1
    fi
    export PYTHONPATH="${MC_WHEEL_DIR}:${PYTHONPATH:-}"
    # LD_LIBRARY_PATH 确保自编译的 .so 能找到依赖
    export LD_LIBRARY_PATH="${MC_CUSTOM_DIR}/build/mooncake-store/src:${MC_CUSTOM_DIR}/build/mooncake-common:${MC_CUSTOM_DIR}/build/mooncake-common/etcd:${MC_CUSTOM_DIR}/build/mooncake-transfer-engine/src:${MC_WHEEL_DIR}/mooncake:${LD_LIBRARY_PATH:-}"
    echo "[mooncake] 使用自定义编译 Mooncake: ${MC_WHEEL_DIR}"
    python3 -c "import mooncake; print('[mooncake] using:', mooncake.__path__)" || echo "[mooncake] WARNING: 无法从自定义路径加载 mooncake"
else
    echo "[mooncake] 使用系统安装的 Mooncake (设 MC_CUSTOM_DIR=/path/to/Mooncake 切换自定义版本)"
fi

# ---------- 强制使用本地 sglang 代码 (覆盖 pip 安装版本) ----------
# 默认使用 pip 安装的 sglang 版本.
# 如需使用本地补丁, 通过环境变量指定:
#   SGLANG_PATCH_DIR=/path/to/patch ./server_mc.sh
#   或 SGLANG_USE_PATCH=1 ./server_mc.sh  (自动检测脚本同目录下的 sglang_patch/)
# 脚本所在目录 (不依赖 $(pwd), 支持从任意路径执行)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -n "${SGLANG_PATCH_DIR:-}" ]]; then
    export PYTHONPATH="${SGLANG_PATCH_DIR}:${PYTHONPATH:-}"
    echo "[sglang] 使用指定补丁目录: ${SGLANG_PATCH_DIR}"
    python3 -c "import sglang; print('[sglang] using:', sglang.__file__)" || echo "[sglang] WARNING: 无法从指定目录加载 sglang"
elif [[ "${SGLANG_USE_PATCH:-0}" == "1" ]]; then
    # 自动检测脚本同目录下的 sglang_patch/sglang 目录 (不依赖 $(pwd))
    PATCH_DIR="${SCRIPT_DIR}/sglang_patch"
    if [[ -d "${PATCH_DIR}/sglang" ]]; then
        export PYTHONPATH="${PATCH_DIR}:${PYTHONPATH:-}"
        echo "[sglang] 使用本地补丁目录: ${PATCH_DIR}"
        echo "[sglang] 检测到 ${PATCH_DIR}/sglang 目录存在"
        python3 -c "import sglang; print('[sglang] using:', sglang.__file__)" || echo "[sglang] WARNING: 无法加载本地 sglang"
    else
        echo "[sglang] WARNING: 未找到 ${PATCH_DIR}/sglang 目录, 回退到 pip 版本"
        echo "[sglang] 请确认 ${PATCH_DIR}/ 下包含完整的 sglang/ 文件夹 (含 __init__.py)"
        ls -la "${PATCH_DIR}/" 2>/dev/null | head -10 || echo "[sglang] ${PATCH_DIR}/ 目录也不存在"
    fi
else
    echo "[sglang] 使用 pip 安装的 sglang 版本 (如需本地补丁请设 SGLANG_PATCH_DIR 或 SGLANG_USE_PATCH=1)"
fi
# ---------- 基本配置 ----------
MODEL_PATH="${MODEL_PATH:-Qwen3-14B-FP8}"
PORT="${PORT:-8022}"
# 是否启用 Mooncake 作为 L3 存储后端:
#   USE_MOONCAKE=1 -> 使用 Mooncake (当前默认行为)
#   USE_MOONCAKE=0 -> 关闭 Mooncake, 仅保留 L1 GPU + L2 host HiCache
USE_MOONCAKE="${USE_MOONCAKE:-1}"

# ---------- Mooncake 连接配置 ----------
# master 地址 (必须和 mooncake_master.sh 里的监听地址一致)
MC_MASTER_HOST="${MC_MASTER_HOST:-127.0.0.1}"
MC_MASTER_PORT="${MC_MASTER_PORT:-50051}"
MC_MASTER_ADDR="${MC_MASTER_HOST}:${MC_MASTER_PORT}"

# metadata server: 指向 master 内嵌的 HTTP metadata 服务
# (mooncake_master.sh 用 --enable_http_metadata_server=true 启动, 端口 8080)
# 注意: P2PHANDSHAKE 模式在 tcp 协议下可能 setup 失败 (error -1300), 建议用 HTTP 模式
MC_METADATA_PORT="${MC_METADATA_PORT:-8080}"
MC_METADATA_SERVER="${MC_METADATA_SERVER:-http://${MC_MASTER_HOST}:${MC_METADATA_PORT}/metadata}"

# 当前节点的 IP / hostname (master 通过此地址回连本节点做数据传输)
# 单机: 127.0.0.1; 多节点: 本机内网 IP, 如 10.0.0.2
MC_LOCAL_HOSTNAME="${MC_LOCAL_HOSTNAME:-127.0.0.1}"

# 传输协议: tcp (通用) 或 rdma (需要 IB/eRDMA 网卡, 零拷贝性能更好)
MC_PROTOCOL="${MC_PROTOCOL:-tcp}"

# ---------- L3-DRAM 层 (Mooncake I/O 缓冲区) ----------
# Mooncake 架构: DRAM 是主存储池, SSD 是溢出层(spill).
# 要以 SSD 为主, DRAM 设极小做缓冲(不能为0, 至少需要少量内存做 I/O 中转).
# 数据会快速从 DRAM 溢出到 SSD, 实际 L3 主要在磁盘上.
MC_GLOBAL_SEGMENT_SIZE="${MC_GLOBAL_SEGMENT_SIZE:-68719476736}"   # 64 GB in bytes (mooncake 要求纯数字, 单位 byte)

# ---------- L3-SSD 层 (实际 L3 存储) ----------
# SSD offload 目录: DRAM 缓冲区满后 spill 到这里, 这是你 profile 的目标层.
# 
# ⚠️  磁盘空间现状 (df 实测):
#   分区总容量:    ~400 GB
#   已用:          ~368 GB  
#   剩余可用:      ~12 GB  (使用率 98%)
#
# ⚠️  Mooncake 没有 SSD 配额参数!
#   它会往这个目录一直写文件直到磁盘满或被 eviction 驱逐.
#   eviction_high_watermark_ratio=0.95 只管 DRAM 池, 不管 SSD.
#   所以必须手动控制可用空间.
#
# 安全策略:
#   MC_SSD_USE_PCT     = SSD offload 使用剩余空间的百分比 (0-100). 默认 90%.
#                        设为 0 则使用固定值 MC_SSD_MAX_GB.
#   MC_SSD_MAX_GB      = 固定上限 (GB). 仅当 MC_SSD_USE_PCT=0 时生效.
#   MC_SSD_OFFLOAD_PATH = 实际存储目录.
MC_SSD_OFFLOAD_PATH="${MC_SSD_OFFLOAD_PATH:-/data/home/royyliu/hicache_ssd}"
MC_SSD_USE_PCT="${MC_SSD_USE_PCT:-0}"     # 不使用百分比, 使用固定值
MC_SSD_MAX_GB="${MC_SSD_MAX_GB:-12}"         # 固定上限 8GB

# 默认在启动前清空 SSD offload 内容, 避免复用残留数据导致异常.
# 只有 CLEAR_MOONCAKE=0 时才保留目录中的已有内容.
# 如果目录不存在, mkdir -p 会自动创建 (包括父目录)
CLEAR_MOONCAKE="${CLEAR_MOONCAKE:-1}"
if [[ "$USE_MOONCAKE" == "1" ]]; then
    if [[ "$CLEAR_MOONCAKE" == "1" && -d "$MC_SSD_OFFLOAD_PATH" ]]; then
        echo "[mooncake] clearing L3-SSD offload dir: $MC_SSD_OFFLOAD_PATH"
        rm -rf "${MC_SSD_OFFLOAD_PATH:?}/"* 2>/dev/null || true
    elif [[ ! -d "$MC_SSD_OFFLOAD_PATH" ]]; then
        echo "[mooncake] L3-SSD offload dir 不存在, 自动创建: $MC_SSD_OFFLOAD_PATH"
    else
        echo "[mooncake] keeping existing L3-SSD offload dir: $MC_SSD_OFFLOAD_PATH"
    fi
    mkdir -p "$MC_SSD_OFFLOAD_PATH"

# ---------- SSD 配额策略 ----------
# 容器环境通常没有 loop mount 权限 (/dev/loop-control 缺失),
# 所以默认用软配额: 后台守护进程监控目录大小, 超过上限就删最旧文件.
# 如需硬配额 (loop mount), 设 MC_QUOTA_ENFORCE=1 (需要 root + privileged).
MC_QUOTA_ENFORCE="${MC_QUOTA_ENFORCE:-0}"   # 默认 0=软配额, 1=硬配额(loop mount)

enforce_ssd_quota() {
    local mount_dir="$1"
    local max_gb="$2"
    local img_file="${mount_dir}.img"

    if [[ "$(id -u)" != "0" ]]; then
        echo "[quota] FATAL: 当前非 root 用户 (uid=$(id -u)), 无法执行 loop mount 配额."
        echo "[quota]        请用 root 启动: sudo ./server_mc.sh, 或者设 MC_QUOTA_ENFORCE=0 关闭配额."
        return 1
    fi

    # 如果目录已经是独立挂载点, 信任外部配置
    if command -v mountpoint >/dev/null 2>&1 && mountpoint -q "$mount_dir" 2>/dev/null; then
        echo "[quota] ${mount_dir} 已是独立挂载点, 跳过 loop mount."
        return 0
    fi

    # 清理可能残留的旧镜像和挂载
    umount "$mount_dir" 2>/dev/null || true
    rm -f "$img_file"

    # 创建固定大小的镜像文件 (sparse file)
    echo "[quota] 创建 ${max_gb}GB loop 镜像: ${img_file}"
    if ! fallocate -l "${max_gb}G" "$img_file" 2>/dev/null; then
        echo "[quota] fallocate 失败, 尝试用 dd 创建 (较慢) ..."
        dd if=/dev/zero of="$img_file" bs=1G count="$max_gb" status=progress || {
            echo "[quota] ERROR: 创建镜像文件失败."
            rm -f "$img_file"
            return 1
        }
    fi

    # 格式化为 ext4
    mkfs.ext4 -F -q "$img_file" >/dev/null 2>&1 || {
        echo "[quota] ERROR: mkfs.ext4 失败."
        rm -f "$img_file"
        return 1
    }

    # loop mount 到目标目录 (容器里常见失败原因: 没有 /dev/loop-control 设备,
    # 需要 --privileged 或 --device /dev/loop-control 才能用, 这里失败就返回 1
    # 由上层决定是否降级为软配额)
    mount -o loop "$img_file" "$mount_dir" || {
        echo "[quota] ERROR: loop mount 失败 (容器常见: 缺少 /dev/loop-control, 需 --privileged)."
        rm -f "$img_file"
        return 1
    }

    # 验证 mount 是否生效
    if ! mountpoint -q "$mount_dir" 2>/dev/null; then
        echo "[quota] ERROR: mountpoint 检查失败, ${mount_dir} 不是独立挂载点."
        umount "$mount_dir" 2>/dev/null || true
        rm -f "$img_file"
        return 1
    fi

    local actual_gb
    actual_gb=$(df -BG "$mount_dir" | tail -1 | awk '{print $2}' | tr -d 'G')
    echo "[quota] 成功: ${img_file} (${max_gb}GB) -> ${mount_dir} (df 显示 total=${actual_gb}GB)"
    return 0
}

# ---------- SSD 软配额 (无需 root/特权, 容器内兜底方案) ----------
# 原理: 后台常驻一个循环, 定期统计 $mount_dir 实际占用大小,
#       超过 max_gb 就计算出超出量, 然后按 mtime 从旧到新删除文件,
#       直到累计删除量 >= 超出量 (一次清理到位).
# 不是内核级硬限制 (写入瞬间仍可能短暂超过), 但能保证磁盘不会被写爆.
SOFT_QUOTA_PID=""
start_soft_quota_watcher() {
    local mount_dir="$1"
    local max_gb="$2"
    local interval="${MC_SOFT_QUOTA_INTERVAL:-10}"   # 检查间隔(秒)
    local parent_pid=$$                               # 记录父脚本 PID
    # 清理目标: 降到 max_gb 的 90% (留缓冲避免频繁触发清理)
    local target_pct="${MC_SOFT_QUOTA_TARGET_PCT:-90}"
    local target_kb=$(( max_gb * 1024 * 1024 * target_pct / 100 ))

    (
        while true; do
            sleep "$interval"
            # 父脚本已退出 → 自动终止 (避免成为孤儿进程)
            if ! kill -0 "$parent_pid" 2>/dev/null; then
                exit 0
            fi
            [[ -d "$mount_dir" ]] || continue
            local used_kb used_gb over_kb
            used_kb=$(du -sk "$mount_dir" 2>/dev/null | awk '{print $1}')
            [[ -z "$used_kb" ]] && continue
            used_gb=$(( used_kb / 1024 / 1024 ))
            if (( used_gb > max_gb )); then
                over_kb=$(( used_kb - target_kb ))
                echo "[soft-quota] ${mount_dir} 占用 ${used_gb}GB > 上限 ${max_gb}GB, 超出约 $(( over_kb / 1024 ))MB, 开始清理最旧文件..."
                # 按 mtime 从旧到新排序, 累加文件大小直到 >= 超出量, 然后一次性删除
                local to_delete="" deleted_kb=0 file_size
                while IFS= read -r line; do
                    [[ -z "$line" ]] && continue
                    local f="${line#* }"          # 去掉前缀的 timestamp
                    [[ -f "$f" ]] || continue
                    file_size=$(stat -c%s "$f" 2>/dev/null || stat -f%z "$f" 2>/dev/null || echo 0)
                    to_delete="${to_delete}${f}"$'\n'
                    deleted_kb=$(( deleted_kb + file_size / 1024 ))
                    (( deleted_kb >= over_kb )) && break
                done < <(find "$mount_dir" -type f -printf '%T@ %p\n' 2>/dev/null | sort -n)

                if [[ -n "$to_delete" ]]; then
                    echo "$to_delete" | xargs rm -f 2>/dev/null
                    echo "[soft-quota] 已清理约 $(( deleted_kb / 1024 ))MB ($((deleted_kb / 1024 / 1024))GB), 当前占用 $(du -sh "$mount_dir" 2>/dev/null | awk '{print $1}')"
                fi
            fi
        done
    ) &
    SOFT_QUOTA_PID=$!
    disown "$SOFT_QUOTA_PID" 2>/dev/null || true
    echo "[soft-quota] 已启动后台软配额守护进程 (pid=${SOFT_QUOTA_PID}, 上限=${max_gb}GB, 目标清理到${target_pct}%, 检查间隔=${interval}s, 随主进程退出)"
}

# 脚本退出时兜底清理软配额守护进程 (双保险: trap + 父进程检测)
cleanup_soft_quota() {
    if [[ -n "$SOFT_QUOTA_PID" ]] && kill -0 "$SOFT_QUOTA_PID" 2>/dev/null; then
        kill "$SOFT_QUOTA_PID" 2>/dev/null || true
        echo "[soft-quota] 主进程退出, 已终止软配额守护进程 (pid=${SOFT_QUOTA_PID})"
    fi
}
trap cleanup_soft_quota EXIT INT TERM

# SSD offload 开关 (quota 只在开启 SSD offload 时才有意义)
MC_ENABLE_SSD_OFFLOAD="${MC_ENABLE_SSD_OFFLOAD:-0}"

if [[ "$MC_ENABLE_SSD_OFFLOAD" == "1" ]]; then
    if [[ "$MC_QUOTA_ENFORCE" == "1" ]]; then
        if enforce_ssd_quota "$MC_SSD_OFFLOAD_PATH" "$MC_SSD_MAX_GB"; then
            MC_QUOTA_ACTIVE=1
        else
            # loop mount 失败 (常见于容器无 privileged): 自动降级为软配额,
            # 不再直接退出, 保证容器环境下也能限制住 SSD 用量.
            echo "[quota] loop mount 硬配额不可用 (可能缺少 privileged 权限), 自动降级为软配额 (用户态监控删旧文件)."
            start_soft_quota_watcher "$MC_SSD_OFFLOAD_PATH" "$MC_SSD_MAX_GB"
            MC_QUOTA_ACTIVE=2   # 2 = 软配额生效 (非内核级硬限制)
        fi
    else
        # 默认路径: 软配额 (无需 root/privileged, 容器内可用)
        echo "[quota] SSD offload 已开启, 使用软配额 (后台监控, 超过 ${MC_SSD_MAX_GB}GB 删最旧文件)."
        start_soft_quota_watcher "$MC_SSD_OFFLOAD_PATH" "$MC_SSD_MAX_GB"
        MC_QUOTA_ACTIVE=2
    fi
else
    MC_QUOTA_ACTIVE=0
    echo "[quota] SSD offload 未开启, 无需 SSD 配额."
fi

# ---------- 磁盘空间安全检查 ----------
# Mooncake 没有 SSD 层配额, 必须在启动前确认剩余空间够用
SSD_DIR_REALPATH="$(realpath "$MC_SSD_OFFLOAD_PATH")"
SSD_FS_INFO="$(df -BG "$SSD_DIR_REALPATH" 2>/dev/null | tail -1)"
SSD_AVAIL_GB="$(echo "$SSD_FS_INFO" | awk '{print $4}' | tr -d 'G')"
SSD_TOTAL_GB="$(echo "$SSD_FS_INFO" | awk '{print $2}' | tr -d 'G')"

# 动态计算 SSD 上限: 按剩余空间的百分比, 或使用固定值
if [[ "$MC_SSD_USE_PCT" -gt 0 ]]; then
    MC_SSD_ACTUAL_MAX=$(( SSD_AVAIL_GB * MC_SSD_USE_PCT / 100 ))
    echo "[mooncake] SSD 上限 = 剩余空间(${SSD_AVAIL_GB}GB) × ${MC_SSD_USE_PCT}% = ${MC_SSD_ACTUAL_MAX}GB"
else
    MC_SSD_ACTUAL_MAX="$MC_SSD_MAX_GB"
    echo "[mooncake] SSD 上限 = 固定值 ${MC_SSD_ACTUAL_MAX}GB (忽略磁盘剩余空间)"
fi

echo "[mooncake] SSD offload dir:  $MC_SSD_OFFLOAD_PATH"
echo "[mooncake] Filesystem:       total=${SSD_TOTAL_GB}GB  available=${SSD_AVAIL_GB}GB (${MC_SSD_ACTUAL_MAX}GB/${SSD_AVAIL_GB}GB)"

# quota 状态提示
if [[ "$MC_QUOTA_ACTIVE" == "1" ]]; then
    echo "[mooncake] SSD 硬配额: 已启用 (loop mount ${MC_SSD_ACTUAL_MAX}GB, Mooncake 最多写到 ${MC_SSD_ACTUAL_MAX}GB)"
elif [[ "$MC_QUOTA_ACTIVE" == "2" ]]; then
    echo "[mooncake] SSD 软配额: 已启用 (无 loop mount 权限, 后台监控删旧文件, 上限约 ${MC_SSD_ACTUAL_MAX}GB, 非内核级硬限制)"
elif [[ "$MC_ENABLE_SSD_OFFLOAD" == "1" ]]; then
    echo "[mooncake] SSD 硬配额: 未启用 (SSD offload 已开启, 不限制上限, 可能写爆磁盘)"
else
    echo "[mooncake] SSD 硬配额: 未启用 (SSD offload 未开启, 不写 SSD)"
fi
echo "[mooncake]    压测时建议另开终端监控: watch -n 5 'df -h ${MC_SSD_OFFLOAD_PATH}'"

# ---------- Mooncake SSD offload 开关 ----------
# 这些被 sglang/srt/mem_cache/storage/mooncake_store/mooncake_store.py 读取
export MOONCAKE_MASTER="$MC_MASTER_ADDR"
export MOONCAKE_TE_META_DATA_SERVER="$MC_METADATA_SERVER"
export MOONCAKE_PROTOCOL="$MC_PROTOCOL"
export MOONCAKE_GLOBAL_SEGMENT_SIZE="$MC_GLOBAL_SEGMENT_SIZE"
export MOONCAKE_LOCAL_HOSTNAME="$MC_LOCAL_HOSTNAME"

# SSD offload (DRAM 溢出时 spill 到 SSD, 形成多级)
# 默认关闭: 先用纯 DRAM 模式验证链路跑通.
#         UNABLE_OFFLOAD 常见原因: 磁盘太满(当前 98%)/文件系统不支持 mmap/权限问题.
#         验证通过后设 MC_ENABLE_SSD_OFFLOAD=1 重新开启.
if [[ "$MC_ENABLE_SSD_OFFLOAD" == "1" ]]; then
    export MOONCAKE_ENABLE_SSD_OFFLOAD=1
    export MOONCAKE_OFFLOAD_FILE_STORAGE_PATH="$MC_SSD_OFFLOAD_PATH"

    # ★ 关键: 设置 Mooncake 内部 SSD 淘汰阈值 (bytes)
    #   不设的话 Mooncake 默认用磁盘总容量的 90% (~385GB), 远超实际可用空间.
    #   storage_backend.cpp 读取此环境变量控制 bucket eviction.
    export MOONCAKE_OFFLOAD_BUCKET_MAX_TOTAL_SIZE=$(( MC_SSD_MAX_GB * 1024 * 1024 * 1024 ))
    export MOONCAKE_OFFLOAD_TOTAL_SIZE_LIMIT_BYTES=$(( MC_SSD_MAX_GB * 1024 * 1024 * 1024 ))
    echo "[mooncake] SSD offload bucket max_total_size: ${MC_SSD_MAX_GB}GB (${MOONCAKE_OFFLOAD_BUCKET_MAX_TOTAL_SIZE} bytes)"

    # 官方 benchmark (ssd-offload-benchmark-results.html) 额外给了这两个环境变量:
    #   MOONCAKE_OFFLOAD_LOCAL_BUFFER_SIZE_BYTES: 本地缓冲区, 吸收突发写入后再落盘 SSD
    #   MOONCAKE_OFFLOAD_USE_URING:              用 io_uring 加速磁盘 I/O
    # 这两个不是 sglang python 层的参数, sglang 只显式传了 enable_ssd_offload/ssd_offload_path,
    # 但底层 mooncake 引擎在开启 offload 时会自行读取这两个环境变量, 所以在这里 export 即可生效
    # (若你的 mooncake 版本不识别, 只是被忽略, 不会报错).
    MC_OFFLOAD_LOCAL_BUFFER_BYTES="${MC_OFFLOAD_LOCAL_BUFFER_BYTES:-2147483648}"  # 默认 2GB 缓冲
    # io_uring 默认关闭: 容器环境通常不支持 io_uring (Operation not permitted),
    # 初始化失败后 UringFile 不会 fallback 到 PosixFile, 导致 SSD 写入全部失败.
    # 设为 0 使用 PosixFile (pwrite), 兼容所有环境.
    MC_OFFLOAD_USE_URING="${MC_OFFLOAD_USE_URING:-0}"
    export MOONCAKE_OFFLOAD_LOCAL_BUFFER_SIZE_BYTES="$MC_OFFLOAD_LOCAL_BUFFER_BYTES"
    export MOONCAKE_OFFLOAD_USE_URING="$MC_OFFLOAD_USE_URING"

    echo "[mooncake] SSD offload: enabled (path=$MC_SSD_OFFLOAD_PATH, local_buffer=${MC_OFFLOAD_LOCAL_BUFFER_BYTES}B, use_uring=${MC_OFFLOAD_USE_URING})"

    # 前置检查: 已安装的 mooncake python 包 store.setup() 是否支持 enable_ssd_offload 参数.
    # 如果不支持, sglang 会静默 fallback 到不带 SSD offload 的 setup(), 只打 warning 日志,
    # 表现上就是"开了开关但 SSD 完全没有被使用"。这里提前暴露出来, 避免误以为是配置问题。
    if ! python3 -c "
import inspect, sys
try:
    from mooncake.store import MooncakeDistributedStore
except ImportError as e:
    print('[mooncake] ERROR: cannot import mooncake.store:', e)
    sys.exit(1)
params = inspect.signature(MooncakeDistributedStore.setup).parameters
if 'enable_ssd_offload' not in params:
    print('[mooncake] WARNING: 当前安装的 mooncake 版本 setup() 不支持 enable_ssd_offload 参数,')
    print('[mooncake]          SGLang 会自动 fallback 为不开启 SSD offload (只打 warning, 不会报错)。')
    print('[mooncake]          请执行: pip install -U mooncake-transfer-engine 升级后重试。')
    sys.exit(1)
" 2>&1; then
        echo "[mooncake] ⚠️  上面的检查未通过, SSD offload 可能实际不会生效, 请先升级 mooncake 后再压测。"
    fi
else
    echo "[mooncake] SSD offload: disabled (set MC_ENABLE_SSD_OFFLOAD=1 to enable)"
fi
else
    echo "[mooncake] USE_MOONCAKE=0, skip Mooncake SSD/offload initialization."
fi

# ---------- 检查 master 是否在线 ----------
if [[ "$USE_MOONCAKE" == "1" ]]; then
    echo "[mooncake] checking master at $MC_MASTER_ADDR ..."
    for i in $(seq 1 20); do
        if (echo > "/dev/tcp/$MC_MASTER_HOST/$MC_MASTER_PORT") 2>/dev/null; then
            echo "[mooncake] master is online."
            break
        fi
        sleep 0.5
        if [[ $i -eq 20 ]]; then
            echo "[mooncake] ERROR: master at $MC_MASTER_ADDR is not reachable."
            echo "[mooncake]        please start it first: ./mooncake_master.sh"
            exit 1
        fi
    done
else
    echo "[mooncake] USE_MOONCAKE=0, skip master check and disable Mooncake L3 backend."
fi

# ---------- 启动 SGLang server ----------
MC_DRAM_GB=$((MC_GLOBAL_SEGMENT_SIZE / 1024 / 1024 / 1024))
LAUNCH_ARGS=(
    --model-path "$MODEL_PATH"
    --port "$PORT"
    --tp 1
    --context-length 8192
    --mem-fraction-static 0.55
    --max-running-requests 64
    --page-size 16
    --kv-cache-dtype fp8_e4m3
    --enable-hierarchical-cache
    --hicache-ratio 1.2
    --hicache-mem-layout page_first_direct
    --hicache-storage-prefetch-policy wait_complete
)

if [[ "$USE_MOONCAKE" == "1" ]]; then
    echo "============================================================"
    echo " SGLang Server (Mooncake L3: DRAM ${MC_DRAM_GB}GB buffer → SSD ${MC_SSD_OFFLOAD_PATH})"
    echo "  SSD max: ${MC_SSD_MAX_GB}GB (MOONCAKE_OFFLOAD_BUCKET_MAX_TOTAL_SIZE=${MOONCAKE_OFFLOAD_BUCKET_MAX_TOTAL_SIZE})"
    echo "============================================================"

    # 注意: mooncake 后端要求 --hicache-mem-layout 为 page_first / page_first_direct
    #       (默认 layer_first 不兼容, mooncake_store.py:553 会 assert 失败)
    #       page_first_direct 性能更好 (省一次 host->device 中转拷贝)
    #
    # --hicache-storage-prefetch-policy wait_complete:
    #   官方 SSD offload benchmark 明确使用 wait_complete (等待 L3 读完整完成才继续).
    #   默认值是 "timeout": SSD 读比 DRAM 慢很多, 如果等待超时会直接放弃 prefetch 转去重新计算,
    #   表现上就是"看起来 SSD offload 没生效"(backuped/prefetched 计数很低, 数据其实已经落盘了,
    #   只是读的时候没等到就被放弃了)。这很可能是你之前感觉"开不了 SSD offload"的真正原因之一.
    LAUNCH_ARGS+=(
        --hicache-storage-backend mooncake
        --hicache-storage-backend-extra-config '{"prefetch_threshold": 16}'
    )
else
    echo "============================================================"
    echo " SGLang Server (Mooncake disabled: L1 GPU + L2 host HiCache only)"
    echo "============================================================"
fi

# --enable-metrics:
#   打开后 /metrics 会多出 sglang:prefetch_bandwidth / sglang:backup_bandwidth 等 L3 读写
#   带宽 histogram (逐次 batch_get/batch_put 的真实耗时换算), 是 profile "每一步延迟"的关键数据源.
LAUNCH_ARGS+=(
    --enable-metrics
    --enforce-piecewise-cuda-graph)

CUDA_VISIBLE_DEVICES=0 python3 -m sglang.launch_server "${LAUNCH_ARGS[@]}"
