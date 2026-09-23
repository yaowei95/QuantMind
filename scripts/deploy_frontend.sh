#!/usr/bin/env bash
# QuantMind Web 前端部署：本地构建 → rsync 到服务器 web/dist（宿主机原生 Nginx 托管）
#
# 用法:
#   bash scripts/deploy_frontend.sh [--skip-build]          # 读取 deploy/web.local.env
#   SSH_TARGET=... WEB_DIR=... WEB_URL=... bash scripts/deploy_frontend.sh
#
# 变量来源：命令行环境变量 > deploy/web.local.env（gitignore，从 deploy/web.env.example 复制）
#   SSH_TARGET  服务器 ssh 目标（必填）
#   WEB_DIR     服务器上存放前端文件的目录（必填，只放构建产物，勿放项目源码/.env）
#   WEB_URL     服务器本机访问前端的地址，用于部署后校验（默认 http://127.0.0.1/）
#
# 前提：服务器 Nginx 已按 deploy/nginx/quantmind.locations.conf 配好。静态文件更新无需 reload。
#
# 两段式同步，避免浏览器拿到新 index.html 却找不到新 chunk：
#   1) 先传除 index.html 以外的全部文件（新 chunk 就位，旧 chunk 保留）
#   2) 再传 index.html 并 --delete 清掉旧 chunk
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ELECTRON_DIR="${PROJECT_ROOT}/electron"
DIST_DIR="${ELECTRON_DIR}/dist-react"
SKIP_BUILD=false

log()  { echo -e "\033[36m[deploy]\033[0m $*"; }
ok()   { echo -e "\033[32m[ok]\033[0m $*"; }
fail() { echo -e "\033[31m[fail]\033[0m $*" >&2; exit 1; }

for arg in "$@"; do
    case "$arg" in
        --skip-build) SKIP_BUILD=true ;;
        -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
        *) fail "未知参数: $arg" ;;
    esac
done

LOCAL_ENV="${PROJECT_ROOT}/deploy/web.local.env"
if [[ -f "$LOCAL_ENV" ]]; then
    # 命令行显式传入的变量优先于本地配置
    cli_ssh="${SSH_TARGET:-}" cli_dir="${WEB_DIR:-}" cli_url="${WEB_URL:-}"
    # shellcheck source=/dev/null
    source "$LOCAL_ENV"
    SSH_TARGET="${cli_ssh:-${SSH_TARGET:-}}"
    WEB_DIR="${cli_dir:-${WEB_DIR:-}}"
    WEB_URL="${cli_url:-${WEB_URL:-}}"
    log "已读取 ${LOCAL_ENV#"$PROJECT_ROOT"/}"
fi

[[ -n "${SSH_TARGET:-}" ]] || fail "缺少 SSH_TARGET（如 root@1.2.3.4 或 ssh 别名）"
[[ -n "${WEB_DIR:-}" ]] || fail "缺少 WEB_DIR（服务器上存放前端文件的目录）"
REMOTE_DIST="${WEB_DIR%/}"
WEB_URL="${WEB_URL:-http://127.0.0.1/}"
WEB_URL="${WEB_URL%/}/"

# ── 1. 本地构建 ──────────────────────────────────────────────
if $SKIP_BUILD; then
    log "跳过构建（--skip-build），直接部署现有 dist-react/"
else
    [[ -x "${PROJECT_ROOT}/node_modules/.bin/vite" || -x "${ELECTRON_DIR}/node_modules/.bin/vite" ]] \
        || fail "未安装前端依赖，先在项目根目录执行 npm install"
    log "构建前端（npm run build:react）..."
    (cd "$ELECTRON_DIR" && npm run build:react)
fi

[[ -f "${DIST_DIR}/index.html" ]] || fail "${DIST_DIR}/index.html 不存在，构建失败？"
MAIN_REF=$(grep -oE 'assets/main-[A-Za-z0-9_-]+\.js' "${DIST_DIR}/index.html" | head -1)
[[ -n "$MAIN_REF" ]] || fail "index.html 找不到 main-*.js 引用"
[[ -f "${DIST_DIR}/${MAIN_REF}" ]] || fail "${MAIN_REF} 不在 dist-react/ 中"
ok "本地构建产物: index.html → ${MAIN_REF}"

# ── 2. 准备服务器目录（不存在或属 root 时交给 ssh 用户，rsync 才能写入）──
log "准备 ${SSH_TARGET}:${REMOTE_DIST} ..."
ssh "$SSH_TARGET" "mkdir -p '$REMOTE_DIST' 2>/dev/null && [ -w '$REMOTE_DIST' ] \
    || { sudo mkdir -p '$REMOTE_DIST' && sudo chown -R \$(id -un) '$REMOTE_DIST'; }"

# ── 3. 两段式同步 ────────────────────────────────────────────
log "上传静态资源（不含 index.html）..."
rsync -rtz --exclude=index.html "${DIST_DIR}/" "${SSH_TARGET}:${REMOTE_DIST}/"
log "切换 index.html 并清理旧文件..."
rsync -rtz --delete "${DIST_DIR}/" "${SSH_TARGET}:${REMOTE_DIST}/"

# ── 4. 验证 Nginx 能返回新的 main chunk ──────────────────────
HTTP_CODE=$(ssh "$SSH_TARGET" \
    "curl -s -o /dev/null -w '%{http_code}' '${WEB_URL}${MAIN_REF}'" || true)
[[ "$HTTP_CODE" == "200" ]] \
    || fail "Nginx 未返回 ${MAIN_REF}（HTTP ${HTTP_CODE:-ERR}），检查 Nginx 的 quantmind.locations.conf 是否已 include、root/@WEB_PATH@ 与 WEB_DIR 是否一致"
ok "Nginx 健康：GET ${WEB_URL}${MAIN_REF} → 200"

echo ""
ok "Web 前端部署完成：${WEB_URL}（127.0.0.1 换成服务器 IP 即浏览器访问地址）"
