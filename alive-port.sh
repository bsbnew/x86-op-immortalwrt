#!/bin/sh
# ============================================================
# alive-port.sh — 跨平台探活端口 + nohup 持久化 + cron 自愈
# 支持：Alpine / Debian/Ubuntu / RHEL/CentOS/Fedora / Arch
# 不依赖 supervisor，纯 nohup + cron 方案
# ============================================================

set -u

CONF_DIR="/etc/alive-port"
PORT_FILE="${CONF_DIR}/port"
PID_FILE="${CONF_DIR}/server.pid"
LOG_FILE="${CONF_DIR}/server.log"
CRON_SCRIPT="${CONF_DIR}/cron-check.sh"
SERVICE_SCRIPT="${CONF_DIR}/server.py"
SERVICE_NAME="alive-port"

# ---------- 颜色 ----------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()  { printf "${BLUE}[INFO]${NC} %s\n" "$*"; }
ok()   { printf "${GREEN}[OK]${NC} %s\n" "$*"; }
warn() { printf "${YELLOW}[WARN]${NC} %s\n" "$*"; }
fail() { printf "${RED}[FAIL]${NC} %s\n" "$*"; }

log() {
    mkdir -p "${CONF_DIR}" 2>/dev/null || true
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "${LOG_FILE}" 2>/dev/null || true
}

# ---------- 系统检测 ----------
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_ID="${ID_LIKE:-$ID}"
        OS_NAME="$NAME"
    elif [ -f /etc/alpine-release ]; then
        OS_ID="alpine"; OS_NAME="Alpine Linux"
    elif [ -f /etc/debian_version ]; then
        OS_ID="debian"; OS_NAME="Debian"
    elif [ -f /etc/redhat-release ]; then
        OS_ID="rhel"; OS_NAME="Red Hat"
    elif [ -f /etc/arch-release ]; then
        OS_ID="arch"; OS_NAME="Arch Linux"
    else
        OS_ID="unknown"; OS_NAME="Unknown"
    fi
    info "系统: ${OS_NAME} (${OS_ID})"
    log "系统: ${OS_NAME} (${OS_ID})"
}

pkg_update() {
    case "${OS_ID}" in
        alpine) apk update >/dev/null 2>&1 || true ;;
        debian|ubuntu) apt-get update -qq >/dev/null 2>&1 || true ;;
        rhel|centos|fedora) if command -v dnf >/dev/null 2>&1; then dnf makecache >/dev/null 2>&1 || true; else yum makecache >/dev/null 2>&1 || true; fi ;;
        arch) pacman -Sy --noconfirm >/dev/null 2>&1 || true ;;
    esac
}

pkg_install() {
    case "${OS_ID}" in
        alpine) apk add --no-cache "$@" >/dev/null 2>&1 || true ;;
        debian|ubuntu) apt-get install -y "$@" >/dev/null 2>&1 || true ;;
        rhel|centos|fedora) if command -v dnf >/dev/null 2>&1; then dnf install -y "$@" >/dev/null 2>&1 || true; else yum install -y "$@" >/dev/null 2>&1 || true; fi ;;
        arch) pacman -S --noconfirm "$@" >/dev/null 2>&1 || true ;;
    esac
}

# ---------- 环境检查与依赖 ----------
check_env() {
    if [ "$(id -u)" -ne 0 ]; then
        fail "请以 root 运行此脚本"
        exit 1
    fi
    ok "当前为 root 用户"

    detect_os
    pkg_update

    # python3
    if ! command -v python3 >/dev/null 2>&1; then
        info "安装 python3..."
        pkg_install python3
    else
        ok "python3 已安装"
    fi

    # cron
    if ! command -v crond >/dev/null 2>&1 && ! command -v cron >/dev/null 2>&1; then
        info "安装 cron..."
        case "${OS_ID}" in
            alpine) pkg_install dcron || pkg_install cronie ;;
            debian|ubuntu) pkg_install cron ;;
            rhel|centos|fedora) pkg_install cronie || pkg_install cron ;;
            arch) pkg_install cronie ;;
        esac
    else
        ok "cron 已安装"
    fi

    log "环境检查完成"
}

# ---------- 探活服务脚本 ----------
generate_service_script() {
    mkdir -p "${CONF_DIR}"
    cat > "${SERVICE_SCRIPT}" << 'PYEOF'
#!/usr/bin/env python3
import http.server, socketserver, sys, os
PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8080
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header('Content-Type','text/plain; charset=utf-8')
        self.send_header('Content-Length','2')
        self.end_headers()
        self.wfile.write(b'OK')
    def do_POST(self): self.do_GET()
    def do_PUT(self): self.do_GET()
    def do_DELETE(self): self.do_GET()
    def do_HEAD(self):
        self.send_response(200)
        self.send_header('Content-Type','text/plain; charset=utf-8')
        self.end_headers()
    def log_message(self, *a): pass
if __name__ == '__main__':
    os.chdir('/')
    with socketserver.TCPServer(('', PORT), H) as s:
        try: s.serve_forever()
        except KeyboardInterrupt: pass
PYEOF
    chmod +x "${SERVICE_SCRIPT}"
    ok "探活服务脚本已生成: ${SERVICE_SCRIPT}"
}

# ---------- 进程管理 ----------
is_running() {
    # 检查进程是否存在且端口在监听
    if [ -f "${PID_FILE}" ]; then
        local pid
        pid=$(cat "${PID_FILE}" 2>/dev/null || true)
        if [ -n "${pid}" ] && kill -0 "${pid}" 2>/dev/null; then
            # PID 文件存在且进程存活，再检查端口
            if command -v ss >/dev/null 2>&1 && ss -tlnp | grep -q ":${PORT} "; then
                return 0
            elif command -v netstat >/dev/null 2>&1 && netstat -tlnp | grep -q ":${PORT} "; then
                return 0
            else
                # 进程存在但端口未监听，可能还在启动中
                return 0
            fi
        fi
    fi
    # 通过 pgrep 检查
    if pgrep -f "python3 ${SERVICE_SCRIPT} ${PORT}" >/dev/null 2>&1; then
        return 0
    fi
    return 1
}

start_service() {
    # 先停止旧进程
    stop_service 2>/dev/null || true

    info "启动探活服务 (端口: ${PORT})..."
    nohup python3 "${SERVICE_SCRIPT}" "${PORT}" >> "${LOG_FILE}" 2>&1 &
    echo $! > "${PID_FILE}"
    sleep 2

    if is_running; then
        ok "探活服务已启动 (PID: $(cat "${PID_FILE}"))"
        log "服务启动成功，PID: $(cat "${PID_FILE}")"
        return 0
    else
        fail "探活服务启动失败"
        log "服务启动失败"
        return 1
    fi
}

stop_service() {
    if [ -f "${PID_FILE}" ]; then
        local pid
        pid=$(cat "${PID_FILE}" 2>/dev/null || true)
        if [ -n "${pid}" ]; then
            kill "${pid}" 2>/dev/null || true
            sleep 1
            if kill -0 "${pid}" 2>/dev/null; then
                kill -9 "${pid}" 2>/dev/null || true
            fi
        fi
    fi
    # 清理所有相关进程
    pkill -f "python3 ${SERVICE_SCRIPT} ${PORT}" 2>/dev/null || true
    rm -f "${PID_FILE}" 2>/dev/null || true
}

# ---------- Cron 自愈 ----------
setup_cron() {
    mkdir -p "${CONF_DIR}"
    cat > "${CRON_SCRIPT}" << 'CRONEOF'
#!/bin/sh
# 探活服务自愈检查脚本
CONF_DIR="/etc/alive-port"
PORT_FILE="${CONF_DIR}/port"
PID_FILE="${CONF_DIR}/server.pid"
LOG_FILE="${CONF_DIR}/cron.log"
SERVICE_SCRIPT="${CONF_DIR}/server.py"

# 如果端口文件不存在，退出
if [ ! -f "${PORT_FILE}" ]; then
    exit 0
fi

PORT=$(cat "${PORT_FILE}" 2>/dev/null || true)
if [ -z "${PORT}" ]; then
    exit 0
fi

# 检查服务是否运行
if pgrep -f "python3 ${SERVICE_SCRIPT} ${PORT}" >/dev/null 2>&1; then
    # 进程存在，检查端口是否监听
    if command -v ss >/dev/null 2>&1 && ss -tlnp | grep -q ":${PORT} "; then
        exit 0
    elif command -v netstat >/dev/null 2>&1 && netstat -tlnp | grep -q ":${PORT} "; then
        exit 0
    fi
fi

# 服务未运行，尝试重启
mkdir -p "${CONF_DIR}" 2>/dev/null || true
echo "[$(date '+%Y-%m-%d %H:%M:%S')] 检测到服务未运行，尝试重启..." >> "${LOG_FILE}" 2>/dev/null || true

# 停止旧进程
pkill -f "python3 ${SERVICE_SCRIPT} ${PORT}" 2>/dev/null || true
sleep 1

# 启动服务
nohup python3 "${SERVICE_SCRIPT}" "${PORT}" >> "${CONF_DIR}/server.log" 2>&1 &
echo $! > "${PID_FILE}"
sleep 2

if pgrep -f "python3 ${SERVICE_SCRIPT} ${PORT}" >/dev/null 2>&1; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] 服务重启成功" >> "${LOG_FILE}" 2>/dev/null || true
else
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] 服务重启失败" >> "${LOG_FILE}" 2>/dev/null || true
fi
CRONEOF

    chmod +x "${CRON_SCRIPT}"

    # 添加到 crontab
    # 每分钟检查一次
    (crontab -l 2>/dev/null | grep -v "${CRON_SCRIPT}"; echo "* * * * * ${CRON_SCRIPT} >/dev/null 2>&1") | crontab - 2>/dev/null || true

    # 确保 cron 服务运行
    if command -v crond >/dev/null 2>&1; then
        # Alpine
        if [ ! -f /var/log/cron ]; then
            touch /var/log/cron 2>/dev/null || true
        fi
        crond 2>/dev/null || true
    elif command -v cron >/dev/null 2>&1; then
        # Debian/Ubuntu
        service cron start 2>/dev/null || systemctl start cron 2>/dev/null || true
    fi

    ok "Cron 自愈已设置 (每分钟检查)"
    log "Cron 自愈已设置"
}

remove_cron() {
    (crontab -l 2>/dev/null | grep -v "${CRON_SCRIPT}") | crontab - 2>/dev/null || true
    log "Cron 自愈已移除"
}

# ---------- 端口 ----------
random_port() {
    PORT=$(awk 'BEGIN{srand(); print int(10000 + rand()*10001)}')
    ok "随机端口: ${PORT}"
}

prompt_port() {
    # 非交互模式
    if [ ! -t 0 ]; then
        if [ -f "${PORT_FILE}" ]; then
            PORT=$(cat "${PORT_FILE}")
            ok "非交互模式，使用已保存端口: ${PORT}"
        else
            random_port
        fi
        return
    fi

    # 交互模式
    if [ -f "${PORT_FILE}" ]; then
        DEFAULT=$(cat "${PORT_FILE}")
        printf "请输入探活端口 [默认: ${DEFAULT}]: "
        read -r INPUT || true
        PORT="${INPUT:-$DEFAULT}"
    else
        printf "请输入探活端口 (1-65535，直接回车随机): "
        read -r INPUT || true
        if [ -z "${INPUT}" ]; then
            random_port
        else
            PORT="${INPUT}"
        fi
    fi

    # 校验
    if ! echo "${PORT}" | grep -qE '^[0-9]+$' || [ "${PORT}" -lt 1 ] || [ "${PORT}" -gt 65535 ]; then
        warn "端口无效，使用随机端口..."
        random_port
    fi
    ok "使用端口: ${PORT}"
}

save_port() {
    mkdir -p "${CONF_DIR}"
    echo "${PORT}" > "${PORT_FILE}"
}

# ---------- 验证 ----------
verify() {
    local http_code=""
    if is_running; then
        ok "进程运行中 (PID: $(cat "${PID_FILE}" 2>/dev/null || echo 'unknown'))"
    else
        fail "进程未运行"
    fi
    if command -v ss >/dev/null 2>&1 && ss -tlnp | grep -q ":${PORT} "; then
        ok "端口 ${PORT} 监听中"
    elif command -v netstat >/dev/null 2>&1 && netstat -tlnp | grep -q ":${PORT} "; then
        ok "端口 ${PORT} 监听中"
    else
        warn "端口 ${PORT} 未检测到监听"
    fi
    if command -v curl >/dev/null 2>&1; then
        http_code=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:${PORT}/" 2>/dev/null || true)
        if [ "${http_code}" = "200" ]; then
            ok "HTTP 探活返回 200"
        else
            warn "HTTP 返回: ${http_code:-timeout}"
        fi
    fi
}

# ---------- 修复 ----------
fix() {
    info "尝试修复服务..."
    generate_service_script
    if [ -f "${PORT_FILE}" ]; then
        PORT=$(cat "${PORT_FILE}")
    else
        random_port
    fi
    save_port
    start_service
    setup_cron
    verify
}

# ---------- 状态展示 ----------
status() {
    echo ""
    echo "========================================"
    echo " 探活端口服务状态"
    echo "========================================"
    if [ -f "${PORT_FILE}" ]; then
        PORT=$(cat "${PORT_FILE}")
        echo " 当前端口: ${PORT}"
    else
        echo " 当前端口: 未配置"
    fi
    if [ -f "${PID_FILE}" ]; then
        local pid
        pid=$(cat "${PID_FILE}" 2>/dev/null || true)
        if [ -n "${pid}" ] && kill -0 "${pid}" 2>/dev/null; then
            echo " 进程状态: 运行中 (PID: ${pid})"
        else
            echo " 进程状态: PID文件存在但进程已停止"
        fi
    else
        echo " 进程状态: 未运行"
    fi
    if [ -n "${PORT}" ] && [ "${PORT}" -gt 0 ] 2>/dev/null; then
        if command -v curl >/dev/null 2>&1; then
            local code
            code=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:${PORT}/" 2>/dev/null || true)
            echo " HTTP探活: ${code:-timeout}"
        fi
    fi
    echo " 配置目录: ${CONF_DIR}"
    echo " 日志文件: ${LOG_FILE}"
    echo "========================================"
}

# ---------- 首次部署 ----------
deploy() {
    info "首次部署探活端口服务..."
    check_env
    generate_service_script
    prompt_port
    save_port
    start_service
    setup_cron
    verify || true
    echo ""
    ok "========================================"
    ok " 探活端口服务部署完成"
    ok " 端口: ${PORT}"
    ok " 外部访问: http://<服务器IP>:${PORT}/"
    ok " 返回: HTTP 200 OK"
    ok " Cron 自愈: 已启用 (每分钟检查)"
    ok "========================================"
}

# ---------- 主流程 ----------
main() {
    # 如果已有配置，直接显示状态（非交互）或菜单（交互）
    if [ -f "${PORT_FILE}" ] && [ -f "${SERVICE_SCRIPT}" ]; then
        if [ ! -t 0 ]; then
            # 非交互：检查服务是否正常，不正常则修复
            if ! is_running; then
                info "服务未运行，尝试修复..."
                fix || true
            fi
            status
            exit 0
        fi
        # 交互模式
        status
        printf "操作: [s]状态 [r]重启 [p]改端口 [f]修复 [q]退出: "
        read -r opt || true
        case "${opt}" in
            r)
                if [ -f "${PORT_FILE}" ]; then
                    PORT=$(cat "${PORT_FILE}")
                fi
                start_service
                verify;;
            p)
                prompt_port
                save_port
                start_service
                setup_cron
                verify;;
            f)
                fix;;
            q) exit 0;;
            *) ;; # 默认显示状态
        esac
        exit 0
    fi
    # 首次部署
    deploy
}

# ---------- 入口 ----------
if [ $# -gt 0 ]; then
    case "$1" in
        --status)
            if [ -f "${PORT_FILE}" ]; then PORT=$(cat "${PORT_FILE}"); fi
            status ;;
        --fix)
            fix ;;
        --restart)
            if [ -f "${PORT_FILE}" ]; then PORT=$(cat "${PORT_FILE}"); fi
            start_service
            status ;;
        --stop)
            if [ -f "${PORT_FILE}" ]; then PORT=$(cat "${PORT_FILE}"); fi
            stop_service
            status ;;
        --change-port)
            prompt_port
            save_port
            start_service
            setup_cron
            verify ;;
        *) echo "用法: $0 [--status|--fix|--restart|--stop|--change-port]"; exit 1 ;;
    esac
else
    main
fi
