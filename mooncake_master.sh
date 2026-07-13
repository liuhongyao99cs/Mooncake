#!/usr/bin/env bash
# mooncake_master.sh - 启动 Mooncake master 服务 (常驻前台)
#
# Mooncake master 是分布式 KV cache 系统的协调者:
#   - 管理全局空间池的分配 / eviction
#   - 不存储实际 KV 数据, 只管元信息和空间调度
#   - 所有 SGLang server / store service 启动时都向它注册
#
# 架构:
#   mooncake_master (本脚本)  ← 协调者, 不存数据
#        ↑ 注册               ↑ 注册
#   SGLang server            mooncake_store_service (可选)
#   (兼任 store, 贡献 DRAM)   (独立存储节点, 贡献 DRAM + SSD)
#
# 用法:
#   终端 1: ./mooncake_master.sh          # 先启动 master
#   终端 2: ./server_mc.sh                # 再启动 SGLang server
#
# 多节点扩展: 只需在整个集群启动一个 master, 其他节点跑 server_mc.sh 即可
set -euo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------- master 配置 ----------
# 监听地址 (单机用 127.0.0.1 即可; 多节点部署时改为 0.0.0.0 或本机内网 IP)
MASTER_HOST="${MASTER_HOST:-127.0.0.1}"
MASTER_PORT="${MASTER_PORT:-50051}"

# eviction 高水位线: 池子用量超过此比例时触发 eviction
# 0.95 = 用到 95% 时开始驱逐旧 KV; 内存碎片多时可调低
EVICTION_HIGH_WATERMARK="${EVICTION_HIGH_WATERMARK:-0.95}"

# 是否嵌入 metadata server (true = 不用单独部署 metadata 服务)
ENABLE_HTTP_METADATA="${ENABLE_HTTP_METADATA:-true}"
HTTP_METADATA_PORT="${HTTP_METADATA_PORT:-8080}"

# 是否开启 SSD offload 能力 (master 侧开关)
# 参考: https://kvcache-ai.github.io/Mooncake/deployment/ssd-offload.html
# 官方文档要求 master 与 client 都需要传 --enable_offload=true 才能让 master
# 正确追踪/淘汰被 offload 到 SSD 的对象; 若 master 端没开, SSD offload 即使在
# client(SGLang) 侧配置正确也可能不生效或元数据不同步。
MC_ENABLE_OFFLOAD="${MC_ENABLE_OFFLOAD:-true}"

# Mooncake master 自带的 Prometheus metrics 端口 (put/get/evict 延迟、segment 用量等).
# 参考官方 benchmark 命令: -metrics_port=9004
# 这是排查 "SSD offload 每一步耗时" 最直接的数据源之一, 与 SGLang 侧 /metrics 是两套独立指标.
MC_METRICS_PORT="${MC_METRICS_PORT:-9003}"

# ---------- 前置检查 ----------
if ! command -v mooncake_master >/dev/null 2>&1; then
    echo "[mooncake] ERROR: mooncake_master not found in PATH."
    echo "[mooncake]        pip install mooncake-transfer-engine"
    echo "[mooncake]        或从源码编译: https://github.com/kvcache-ai/Mooncake"
    exit 1
fi

# 注意: 这里不用 `--helpshort` 也不用 `--helpmatch`。
# --helpshort 只列出"定义在 main() 所在源文件"里的 flag, 依赖编译时记录的
# __FILE__ 路径与程序名匹配, 在很多打包/CI 构建场景下会失配, 导致明明支持的
# flag 却检测不到。
# --helpmatch=<regex> 匹配的其实是"源文件(module)名", 不是 flag 名字, 而
# enable_offload/metrics_port 都定义在 master.cpp 里, 文件名里根本没有这几个
# 字, 永远会返回 "No modules matched", 跟 flag 是否存在无关。
# 真正可靠的方式是 `--help`(列出所有 module 的所有 flag) 再用 grep 过滤 flag 名。
MOONCAKE_MASTER_HELP="$(mooncake_master --help 2>&1 || true)"

# 检测当前 mooncake_master 二进制是否支持 --enable_offload flag
# (不同版本的 Mooncake 该 gflag 可能不存在, 传入不支持的 flag 会直接启动失败)
EXTRA_MASTER_ARGS=()
if [[ "$MC_ENABLE_OFFLOAD" == "true" ]]; then
    if echo "$MOONCAKE_MASTER_HELP" | grep -q -- "-enable_offload"; then
        EXTRA_MASTER_ARGS+=(--enable_offload=true)
        echo "[mooncake] master SSD offload flag: enabled (--enable_offload=true)"
    else
        echo "[mooncake] WARNING: 当前 mooncake_master 二进制不支持 --enable_offload flag,"
        echo "[mooncake]          已自动跳过。若 SSD offload 不生效, 请升级 mooncake-transfer-engine。"
    fi
fi

# 检测是否支持 --metrics_port (老版本可能没有)
if echo "$MOONCAKE_MASTER_HELP" | grep -q -- "-metrics_port"; then
    EXTRA_MASTER_ARGS+=(--metrics_port="${MC_METRICS_PORT}")
    echo "[mooncake] master metrics endpoint: http://${MASTER_HOST}:${MC_METRICS_PORT}/metrics"
else
    echo "[mooncake] WARNING: 当前 mooncake_master 不支持 --metrics_port, 跳过 (无法拿到 master 侧延迟指标)."
fi

# ---------- 启动 ----------
echo "============================================================"
echo " Mooncake Master"
echo "------------------------------------------------------------"
echo "  listen:           ${MASTER_HOST}:${MASTER_PORT}"
echo "  metadata server:  ${ENABLE_HTTP_METADATA} (port ${HTTP_METADATA_PORT})"
echo "  eviction ratio:   ${EVICTION_HIGH_WATERMARK}"
echo "  ssd offload:      ${MC_ENABLE_OFFLOAD}"
echo "============================================================"
echo ""
echo "[mooncake] master is running. Keep this terminal open."
echo "[mooncake] open another terminal and run: ./server_mc.sh"
echo "[mooncake] press Ctrl-C to stop."
echo ""

exec mooncake_master \
    --enable_http_metadata_server="${ENABLE_HTTP_METADATA}" \
    --http_metadata_server_port="${HTTP_METADATA_PORT}" \
    --eviction_high_watermark_ratio="${EVICTION_HIGH_WATERMARK}" \
    "${EXTRA_MASTER_ARGS[@]}"
