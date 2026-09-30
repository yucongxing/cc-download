#!/bin/bash

set -e
set -o pipefail

# 本地脚本优先接收管道输入；curl | bash 的 stdin 是代码，需要从终端读取答案。
if [[ -n "${BASH_SOURCE[0]:-}" ]] && [ ! -t 0 ]; then
    exec 3<&0
elif { exec 3</dev/tty; } 2>/dev/null; then
    :
elif [[ -n "${BASH_SOURCE[0]:-}" ]]; then
    exec 3<&0
else
    echo "没有可用的交互终端，请先保存脚本，再在终端运行 bash ./cc_download.sh。" >&2
    exit 1
fi

read_choice() {
    local prompt="$1" variable="$2"
    if [ -t 3 ]; then
        read -r -u 3 -p "$prompt" "$variable" || return 1
    else
        printf '%s' "$prompt" >&2
        if ! read -r -u 3 "$variable"; then
            echo "没有读取到输入。请在交互终端运行，或通过 stdin 提供菜单选项。" >&2
            return 1
        fi
    fi
}

# ── 交互式模式选择 ────────────────────────────────────────────────────────────
MODE=""
TARGET=""
echo ""
echo "选择运行模式："
echo "  1) download  下载离线安装包（默认）"
echo "  2) install   安装 Claude Code"
echo "  3) update    更新 Claude Code"
echo ""
read_choice "输入选项 [1/2/3]: " mode_choice

case "$mode_choice" in
    2) MODE="install" ;;
    3) MODE="update" ;;
    *) MODE="" ;;
esac

if [[ "$MODE" == "install" ]]; then
    echo ""
    echo "选择安装目标："
    echo "  1) 默认（不指定 Target，默认通道）"
    echo "  2) latest"
    echo "  3) stable"
    echo "  4) 指定版本号（如 1.0.33）"
    echo ""
    read_choice "输入选项 [1/2/3/4]: " target_choice
    case "$target_choice" in
        2) TARGET="latest" ;;
        3) TARGET="stable" ;;
        4)
            read_choice "输入版本号（如 1.0.33）: " TARGET
            if [[ ! "$TARGET" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[^[:space:]]+)?$ ]]; then
                echo "版本号格式不正确（示例: 1.0.33）" >&2
                exit 1
            fi
            ;;
        *) TARGET="" ;;
    esac
fi

# ── 代理选择 ──────────────────────────────────────────────────────────────────
echo ""
echo "请选择代理类型："
echo "  1) HTTP 代理（默认）"
echo "  2) 不使用代理"
echo ""
read_choice "输入选项 [1/2]: " type_choice

PROXY_URL=""
CURL_PROXY_ARGS=()
WGET_PROXY_ARGS=()

if [[ "$type_choice" != "2" ]]; then
    read_choice "输入代理端口 [默认: 7897]: " port_input
    port_input="${port_input:-7897}"
    PROXY_URL="http://127.0.0.1:$port_input"
    CURL_PROXY_ARGS=(--proxy "$PROXY_URL" --noproxy "")
    WGET_PROXY_ARGS=(-e use_proxy=yes -e "http_proxy=$PROXY_URL" -e "https_proxy=$PROXY_URL" -e no_proxy=)
    unset no_proxy NO_PROXY
    export http_proxy="$PROXY_URL" https_proxy="$PROXY_URL"
    export HTTP_PROXY="$PROXY_URL" HTTPS_PROXY="$PROXY_URL"
    echo "使用代理: $PROXY_URL"
else
    CURL_PROXY_ARGS=(--noproxy "*")
    WGET_PROXY_ARGS=(-e use_proxy=no)
    unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY
    echo "不使用代理，直接连接。"
fi

# ── 检测下载工具 ──────────────────────────────────────────────────────────────
DOWNLOADER=""
if command -v curl >/dev/null 2>&1; then
    DOWNLOADER="curl"
elif command -v wget >/dev/null 2>&1; then
    DOWNLOADER="wget"
else
    echo "需要 curl 或 wget，但均未安装" >&2; exit 1
fi

HAS_JQ=false
command -v jq >/dev/null 2>&1 && HAS_JQ=true

# ── 下载文件：curl TLS 握手失败时使用 wget 重试 ──────────────────────────────
download_file() {
    local url="$1" output="$2" quiet="$3" status
    local curl_args=(--fail --location --connect-timeout 15)
    local wget_args=(--tries=1 --timeout=15)
    if [ "$quiet" = true ]; then
        curl_args+=(--silent --show-error --max-time 60)
        wget_args+=(--no-verbose)
    else
        curl_args+=(--show-error --progress-bar)
        wget_args+=(--progress=bar:force)
    fi

    if [ "$DOWNLOADER" = "curl" ]; then
        if curl "${curl_args[@]}" "${CURL_PROXY_ARGS[@]}" -o "$output" "$url"; then
            return 0
        else
            status=$?
        fi
        echo "curl 下载失败（退出码 $status）：$url" >&2
        if [ "$status" -ne 35 ] || ! command -v wget >/dev/null 2>&1; then
            return "$status"
        fi
        echo "TLS 握手失败，使用 wget 重试：$url" >&2
    fi
    # -O 覆盖 curl 可能留下的部分内容，避免拼接两个响应。
    if wget "${wget_args[@]}" "${WGET_PROXY_ARGS[@]}" -O "$output" "$url"; then
        return 0
    else
        status=$?
        echo "wget 下载失败（退出码 $status）：$url；请检查 HTTP/混合代理端口及代理节点。" >&2
        return "$status"
    fi
}

# ── 下载文本：仅成功后输出完整内容，错误写入 stderr ──────────────────────────
download_quiet() {
    local temp_file status
    temp_file=$(mktemp) || return 1
    if download_file "$1" "$temp_file" true; then
        if cat "$temp_file"; then status=0; else status=$?; fi
    else
        status=$?
    fi
    rm -f "$temp_file"
    return "$status"
}

# ── 下载函数（带进度条，写入文件）────────────────────────────────────────────
download_with_progress() {
    download_file "$1" "$2" false
}

# ── SHA256 校验（依宿主 OS 选择工具）─────────────────────────────────────────
sha256_file() {
    case "$(uname -s)" in
        Darwin) shasum -a 256 "$1" | cut -d' ' -f1 ;;
        *)      sha256sum "$1" | cut -d' ' -f1 ;;
    esac
}

# ── 简单 JSON 解析（jq 不存在时）─────────────────────────────────────────────
get_checksum_from_manifest() {
    local json platform
    json=$(echo "$1" | tr -d '\n\r\t' | sed 's/ \+/ /g')
    platform="$2"
    if [[ $json =~ \"$platform\"[^}]*\"checksum\"[[:space:]]*:[[:space:]]*\"([a-f0-9]{64})\" ]]; then
        echo "${BASH_REMATCH[1]}"; return 0
    fi
    return 1
}

# ── 检测 manifest checksum（通用）────────────────────────────────────────────
fetch_checksum() {
    local manifest_json="$1" plat="$2" cs
    if [ "$HAS_JQ" = true ]; then
        if ! cs=$(echo "$manifest_json" | jq -r ".platforms[\"$plat\"].checksum // empty"); then
            echo "无法解析 manifest.json" >&2; return 1
        fi
    else
        cs=$(get_checksum_from_manifest "$manifest_json" "$plat") || cs=""
    fi
    if [ -z "$cs" ] || [[ ! "$cs" =~ ^[a-f0-9]{64}$ ]]; then
        echo "平台 $plat 未在 manifest 中找到" >&2; exit 1
    fi
    echo "$cs"
}

# ── 下载或复用已缓存的 claude 二进制 ──────────────────────────────────────────
ensure_binary() {
    local binary_path="$1" download_url="$2" checksum="$3" label="$4"
    if [ -f "$binary_path" ]; then
        echo "发现已缓存文件，校验中..."
        local cached
        cached=$(sha256_file "$binary_path")
        if [ "$cached" = "$checksum" ]; then
            echo "校验通过，跳过下载。"
            return 0
        fi
        echo "缓存文件校验不匹配，重新下载..."
        rm -f "$binary_path"
    fi
    echo "下载 $label..."
    echo "下载地址: $download_url"
    if ! download_with_progress "$download_url" "$binary_path"; then
        rm -f "$binary_path"; echo "下载失败" >&2; return 1
    fi
    echo ""
    echo "校验文件完整性..."
    local actual
    actual=$(sha256_file "$binary_path")
    if [ "$actual" != "$checksum" ]; then
        rm -f "$binary_path"
        echo "校验失败（期望: $checksum  实际: $actual）" >&2; return 1
    fi
    echo "校验通过"
}

# ── 检测当前平台（官方逻辑）──────────────────────────────────────────────────
detect_platform() {
    local os arch platform
    case "$(uname -s)" in
        Darwin) os="darwin" ;;
        Linux)  os="linux"  ;;
        *) echo "不支持的操作系统: $(uname -s)" >&2; exit 1 ;;
    esac
    case "$(uname -m)" in
        x86_64|amd64)  arch="x64"   ;;
        arm64|aarch64) arch="arm64" ;;
        *) echo "不支持的架构: $(uname -m)" >&2; exit 1 ;;
    esac
    # macOS Rosetta 2
    if [ "$os" = "darwin" ] && [ "$arch" = "x64" ]; then
        [ "$(sysctl -n sysctl.proc_translated 2>/dev/null)" = "1" ] && arch="arm64"
    fi
    # Linux musl
    if [ "$os" = "linux" ]; then
        if [ -f /lib/libc.musl-x86_64.so.1 ] || [ -f /lib/libc.musl-aarch64.so.1 ] || \
           ldd /bin/ls 2>&1 | grep -q musl; then
            platform="linux-${arch}-musl"
        else
            platform="linux-${arch}"
        fi
    else
        platform="${os}-${arch}"
    fi
    echo "$platform"
}

# ── 从官方 install.sh 动态解析下载基础 URL ───────────────────────────────────
echo ""
echo "获取最新安装脚本..."
GCS_BUCKET=""
if install_script=$(download_quiet "https://claude.ai/install.sh"); then
    # 新版 bootstrap.sh 使用 DOWNLOAD_BASE_URL，旧版使用 GCS_BUCKET
    if [[ "$install_script" =~ DOWNLOAD_BASE_URL=\"([^\"]+)\" ]]; then
        GCS_BUCKET="${BASH_REMATCH[1]}"
    elif [[ "$install_script" =~ GCS_BUCKET=\"([^\"]+)\" ]]; then
        GCS_BUCKET="${BASH_REMATCH[1]}"
    fi
    if [[ -z "$GCS_BUCKET" ]]; then
        echo "---- install.sh 内容预览 ----"
        echo "${install_script:0:300}"
        echo "-----------------------------"
        echo "无法解析下载基础 URL（DOWNLOAD_BASE_URL / GCS_BUCKET），脚本格式可能已变更" >&2; exit 1
    fi
else
    # 官方文档公布的发布仓库；安装入口可能返回 Cloudflare 403 验证页面。
    # https://code.claude.com/docs/en/setup#verify-the-manifest-signature
    GCS_BUCKET="https://downloads.claude.ai/claude-code-releases"
    echo "获取 install.sh 失败，改用官方发布仓库：$GCS_BUCKET" >&2
fi

# ════════════════════════════════════════════════════════════════════════════════
if [[ -z "$MODE" ]]; then
# ════ 下载模式 ════════════════════════════════════════════════════════════════

    # ── 选择目标平台 ──────────────────────────────────────────────────────────
    echo ""
    echo "选择目标平台："
    echo "  1) linux-x64          Linux x64 (glibc)"
    echo "  2) linux-arm64        Linux ARM64 (glibc)"
    echo "  3) linux-x64-musl     Linux x64 (musl/Alpine)"
    echo "  4) linux-arm64-musl   Linux ARM64 (musl/Alpine)"
    echo "  5) darwin-x64         macOS x64 (Intel)"
    echo "  6) darwin-arm64       macOS ARM64 (Apple Silicon)"
    echo "  7) win32-x64          Windows x64"
    echo "  8) win32-arm64        Windows ARM64"
    echo ""
    read_choice "输入选项 [1-8]: " platform_choice

    IS_WIN=false
    case "$platform_choice" in
        1) PLATFORM="linux-x64"        ;;
        2) PLATFORM="linux-arm64"      ;;
        3) PLATFORM="linux-x64-musl"   ;;
        4) PLATFORM="linux-arm64-musl" ;;
        5) PLATFORM="darwin-x64"       ;;
        6) PLATFORM="darwin-arm64"     ;;
        7) PLATFORM="win32-x64";   IS_WIN=true ;;
        8) PLATFORM="win32-arm64"; IS_WIN=true ;;
        *) echo "无效的选项" >&2; exit 1 ;;
    esac

    # ── 选择版本通道 ───────────────────────────────────────────────────────────
    echo ""
    echo "选择版本通道："
    echo "  1) latest（最新版，默认）"
    echo "  2) stable（稳定版）"
    echo "  3) 输入指定版本号"
    echo ""
    read_choice "输入选项 [1/2/3]: " channel_choice
    channel=""
    case "$channel_choice" in
        2) channel="stable" ;;
        3)
            read_choice "输入版本号（如 1.0.33）: " channel
            [[ ! "$channel" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]] && \
                { echo "版本号格式不正确" >&2; exit 1; }
            ;;
        *) channel="latest" ;;
    esac

    # ── 解析版本号 ─────────────────────────────────────────────────────────────
    if [[ "$channel" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]]; then
        VERSION="$channel"
    else
        VERSION=$(download_quiet "$GCS_BUCKET/$channel" | tr -d '[:space:]')
        [[ -z "$VERSION" ]] && { echo "获取 $channel 版本号失败" >&2; exit 1; }
    fi
    echo "版本: $VERSION"

    # ── 获取 manifest & checksum ──────────────────────────────────────────────
    echo ""
    echo "获取版本清单..."
    manifest_json=$(download_quiet "$GCS_BUCKET/$VERSION/manifest.json")
    [[ -z "$manifest_json" ]] && { echo "获取 manifest.json 失败" >&2; exit 1; }
    checksum=$(fetch_checksum "$manifest_json" "$PLATFORM")

    # ── 下载或复用缓存（当前目录）─────────────────────────────────────────────
    EXT=""; REMOTE_BIN="claude"
    [ "$IS_WIN" = "true" ] && { EXT=".exe"; REMOTE_BIN="claude.exe"; }

    binary_name="claude-$VERSION-$PLATFORM$EXT"
    output_path="$(pwd)/$binary_name"
    download_url="$GCS_BUCKET/$VERSION/$PLATFORM/$REMOTE_BIN"
    echo "保存目录: $(pwd)"
    ensure_binary "$output_path" "$download_url" "$checksum" "$binary_name" || exit 1
    [ "$IS_WIN" = "false" ] && chmod +x "$output_path"

    file_size_kb=$(( $(wc -c < "$output_path") / 1024 ))

    # ── 离线安装提示 ───────────────────────────────────────────────────────────
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo " 文件已下载: $binary_name  (${file_size_kb} KB)"
    echo " 保存位置:   $output_path"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo " 离线安装方法："
    echo ""
    if [ "$IS_WIN" = "true" ]; then
        echo "   1. 将 $binary_name 复制到目标 Windows 机器"
        echo "   2. 在 PowerShell 或 CMD 中运行："
        echo "        .\\$binary_name install"
        echo ""
        echo "   可选：指定通道"
        echo "        .\\$binary_name install stable"
        echo "        .\\$binary_name install latest"
    else
        echo "   1. 将 $binary_name 上传到目标服务器（如 /tmp/）"
        echo "   2. 授予执行权限并安装："
        echo "        chmod +x /tmp/$binary_name && /tmp/$binary_name install"
        echo ""
        echo "   可选：指定通道"
        echo "        /tmp/$binary_name install stable"
        echo "        /tmp/$binary_name install latest"
    fi
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

elif [[ "$MODE" == "update" ]]; then
# ════ 更新模式 ════════════════════════════════════════════════════════════════

    # ── 检查已安装的 claude ────────────────────────────────────────────────────
    if ! command -v claude >/dev/null 2>&1; then
        echo "未找到已安装的 claude，请重新运行脚本并选择 install 模式。" >&2; exit 1
    fi

    found_path=$(command -v claude)
    current_version=""
    version_output=$(claude --version 2>&1 || true)
    [[ "$version_output" =~ ([0-9]+\.[0-9]+\.[0-9]+[^[:space:]]*) ]] && \
        current_version="${BASH_REMATCH[1]}"

    echo "已安装位置: $found_path"
    echo "当前版本: ${current_version:-未知}"

    # ── 获取最新版本号 ─────────────────────────────────────────────────────────
    latest_version=$(download_quiet "$GCS_BUCKET/latest" | tr -d '[:space:]')
    [[ -z "$latest_version" ]] && { echo "获取最新版本号失败" >&2; exit 1; }
    echo "最新版本: $latest_version"

    if [[ "$current_version" == "$latest_version" ]]; then
        echo ""
        echo "已是最新版本（$latest_version），无需更新。"
        exit 0
    fi
    [[ -n "$current_version" ]] && echo "需要更新: $current_version -> $latest_version"

    # ── 检测平台 & 下载目录 ────────────────────────────────────────────────────
    platform=$(detect_platform)
    DOWNLOAD_DIR="$HOME/.claude/downloads"
    mkdir -p "$DOWNLOAD_DIR"
    echo "下载目录: $DOWNLOAD_DIR"

    # ── 获取 manifest & checksum ──────────────────────────────────────────────
    echo ""
    echo "获取版本清单..."
    manifest_json=$(download_quiet "$GCS_BUCKET/$latest_version/manifest.json")
    [[ -z "$manifest_json" ]] && { echo "获取 manifest.json 失败" >&2; exit 1; }
    checksum=$(fetch_checksum "$manifest_json" "$platform")

    # ── 下载或复用缓存 ─────────────────────────────────────────────────────────
    binary_path="$DOWNLOAD_DIR/claude-$latest_version-$platform"
    download_url="$GCS_BUCKET/$latest_version/$platform/claude"
    ensure_binary "$binary_path" "$download_url" "$checksum" \
                  "claude ($latest_version / $platform)" || exit 1
    chmod +x "$binary_path"

    # ── 替换二进制 ─────────────────────────────────────────────────────────────
    # 直接 cp -f 覆写正在运行的文件会触发 ETXTBSY（Text file busy）。
    # Unix 允许对运行中的文件重命名（mv 只改目录项，不动 inode），
    # 策略：先 mv 旧文件腾出路径，再 cp 写入新文件。
    echo ""
    echo "替换: $found_path"
    bak_path="${found_path}.old"
    rm -f "$bak_path" 2>/dev/null || true
    if ! mv "$found_path" "$bak_path"; then
        echo "重命名旧文件失败" >&2; exit 1
    fi
    if cp -f "$binary_path" "$found_path"; then
        # 尝试清理备份（进程仍在运行则删除失败，下次更新时再清理，不影响结果）
        rm -f "$bak_path" 2>/dev/null || true
    else
        # 复制失败，回滚
        mv "$bak_path" "$found_path"
        echo "替换失败，已回滚到旧版本。" >&2; exit 1
    fi
    echo ""
    echo "更新完成：${current_version:+$current_version -> }$latest_version"
    rm -f "$binary_path" 2>/dev/null || true

elif [[ "$MODE" == "install" ]]; then
# ════ 安装模式 ════════════════════════════════════════════════════════════════

    # ── 检测平台 & 下载目录 ────────────────────────────────────────────────────
    platform=$(detect_platform)
    DOWNLOAD_DIR="$HOME/.claude/downloads"
    mkdir -p "$DOWNLOAD_DIR"
    echo "下载目录: $DOWNLOAD_DIR"

    # ── 获取最新版本号 ─────────────────────────────────────────────────────────
    latest_version=$(download_quiet "$GCS_BUCKET/latest" | tr -d '[:space:]')
    [[ -z "$latest_version" ]] && { echo "获取最新版本号失败" >&2; exit 1; }
    echo "最新版本: $latest_version"

    # ── 检查是否已安装 ─────────────────────────────────────────────────────────
    existing_path=""
    current_version=""
    if command -v claude >/dev/null 2>&1; then
        found_path=$(command -v claude)
        version_output=$(claude --version 2>&1 || true)
        [[ "$version_output" =~ ([0-9]+\.[0-9]+\.[0-9]+[^[:space:]]*) ]] && \
            current_version="${BASH_REMATCH[1]}"
        echo "已安装位置: $found_path"
        echo "当前版本: ${current_version:-未知}"
        if [[ "$current_version" == "$latest_version" ]]; then
            echo ""
            echo "已是最新版本（$latest_version），无需操作。"
            exit 0
        fi
        existing_path="$found_path"
        [[ -n "$current_version" ]] && echo "需要更新: $current_version -> $latest_version"
    else
        echo "未检测到已安装的 claude，将执行全新安装。"
    fi

    # ── 获取 manifest & checksum ──────────────────────────────────────────────
    echo ""
    echo "获取版本清单..."
    manifest_json=$(download_quiet "$GCS_BUCKET/$latest_version/manifest.json")
    [[ -z "$manifest_json" ]] && { echo "获取 manifest.json 失败" >&2; exit 1; }
    checksum=$(fetch_checksum "$manifest_json" "$platform")

    # ── 下载或复用缓存 ─────────────────────────────────────────────────────────
    binary_path="$DOWNLOAD_DIR/claude-$latest_version-$platform"
    download_url="$GCS_BUCKET/$latest_version/$platform/claude"
    ensure_binary "$binary_path" "$download_url" "$checksum" \
                  "claude ($latest_version / $platform)" || exit 1
    chmod +x "$binary_path"

    # ── 已安装：直接替换；未安装：运行 install 命令 ────────────────────────────
    if [[ -n "$existing_path" ]]; then
        echo ""
        echo "替换: $existing_path"
        bak_path="${existing_path}.old"
        rm -f "$bak_path" 2>/dev/null || true
        if ! mv "$existing_path" "$bak_path"; then
            echo "重命名旧文件失败" >&2; exit 1
        fi
        if cp -f "$binary_path" "$existing_path"; then
            rm -f "$bak_path" 2>/dev/null || true
        else
            mv "$bak_path" "$existing_path"
            echo "替换失败，已回滚到旧版本。" >&2; exit 1
        fi
        echo ""
        update_prefix="${current_version:+$current_version -> }"
        echo "更新完成：${update_prefix}$latest_version"
        if [[ -n "$TARGET" ]]; then
            echo "应用安装目标: $TARGET"
            if "$existing_path" install "$TARGET"; then
                echo "安装目标应用完成：$TARGET"
            else
                echo "应用安装目标失败：$TARGET" >&2
                exit 1
            fi
        fi
    else
        # ── 先尝试用二进制自带的 install 命令 ─────────────────────────────────
        echo ""
        echo "正在安装 Claude Code..."
        install_ok=false
        if [[ -n "$TARGET" ]]; then
            "$binary_path" install "$TARGET" && install_ok=true || \
                echo "install $TARGET 命令异常"
        else
            "$binary_path" install && install_ok=true || \
                echo "install 命令异常"
        fi

        if [[ "$install_ok" != "true" ]]; then
            # ── 原生 install 失败，回退到手动复制 ────────────────────────────
            install_dir="$HOME/.local/bin"
            install_path="$install_dir/claude"
            echo ""
            echo "原生 install 命令失败，通过 copy 方式安装到 $install_path"
            mkdir -p "$install_dir"
            if cp -f "$binary_path" "$install_path"; then
                echo "复制完成。"
                echo "请确认 $install_dir 已加入 PATH，否则请手动添加："
                echo "  export PATH=\"\$PATH:$install_dir\""
            else
                echo "回退复制也失败" >&2
                exit 1
            fi
        else
            echo ""
            echo "安装完成：$latest_version"
        fi
    fi

    rm -f "$binary_path" 2>/dev/null || true
fi

echo ""
echo "✅ 完成！"
echo ""
