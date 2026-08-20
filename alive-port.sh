#!/bin/sh
# ============================================================
# alive-port.sh — 跨平台探活端口 + Supervisor 持久化
# 支持：Alpine Linux、Debian/Ubuntu、CentOS/RHEL/Fedora、Arch Linux
# ============================================================

set -e

CONF_DIR="/etc/alive-port"
CONF_FILE="${CONF_DIR}/config"
PORT_FILE="${CONF_DIR}/port"
LOG_FILE="${CONF_DIR}/install.log"
SUPERVISOR_CONF_DIR="/etc/supervisor.d"
SUPERVISOR_CONF="${SUPERVISOR_CONF_DIR}/alive-port.conf"
SERVICE_NAME="alive-port"

# ----------------------------------------------------------
# 颜色输出
# ----------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

info()  { printf "${BLUE}[INFO]${NC} %s\n" "$*"; }
ok()   { printf "${GREEN}[OK]${NC} %s\n" "$*"; }
warn() { printf "${YELLOW}[WARN]${NC} %s\n" "$*"; }
fail() { printf "${RED}[FAIL]${NC} %s\n" "$*"; }

# ----------------------------------------------------------
# 日志
# ----------------------------------------------------------
log() {
    mkdir -p "${CONF_DIR}"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "${LOG_FILE}"
}

# ----------------------------------------------------------
# 系统类型检测
# ----------------------------------------------------------
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_ID="${ID_LIKE:-$ID}"
        OS_NAME="$NAME"
    elif [ -f /etc/alpine-release ]; then
        OS_ID="alpine"
        OS_NAME="Alpine Linux"
    elif [ -f /etc/debian_version ]; then
        OS_ID="debian"
        OS_NAME="Debian"
    elif [ -f /etc/redhat-release ]; then
        OS_ID="rhel"
        OS_NAME="Red Hat"
    elif [ -f /etc/arch-release ]; then
        OS_ID="arch"
        OS_NAME="Arch Linux"
    else
        OS_ID="unknown"
        OS_NAME="Unknown"
    fi

    info "检测到系统: ${OS_NAME} (ID: ${OS_ID})"
    log "检测到系统: ${OS_NAME} (ID: ${OS_ID})"
}

# ----------------------------------------------------------
# 获取包管理器命令
# ----------------------------------------------------------
get_pkg_manager() {
    case "${OS_ID}" in
        alpine)
            PKG_UPDATE="apk update"
            PKG_INSTALL="apk add --no-cache"
            PKG_CHECK="command -v"
            ;;
        debian|ubuntu)
            PKG_UPDATE="apt-get update"
            PKG_INSTALL="apt-get install -y"
            PKG_CHECK="dpkg -s"
            ;;
        rhel|centos|fedora)
            if command -v dnf >/dev/null 2>&1; then
                PKG_UPDATE="dnf makecache"
                PKG_INSTALL="dnf install -y"
                PKG_CHECK="rpm -q"
            else
                PKG_UPDATE="yum makecache"
                PKG_INSTALL="yum install -y"
                PKG_CHECK="rpm -q"
            fi
            ;;
        arch)
            PKG_UPDATE="pacman -Sy"
            PKG_INSTALL="pacman -S --noconfirm"
            PKG_CHECK="pacman -Q"
            ;;
        *)
            fail "不支持的操作系统: ${OS_NAME}"
            exit 1
            ;;
    esac

    ok "包管理器: ${PKG_INSTALL}"
    log "包管理器: ${PKG_INSTALL}"
}

# ----------------------------------------------------------
# 环境检查
# ----------------------------------------------------------
check_env() {
    info "开始环境检查..."

    # 检查 root
    if [ "$(id -u)" -ne 0 ]; then
        fail "请以 root 用户运行此脚本 (sudo su - 或 sudo sh $0)"
        exit 1
    fi
    ok "当前为 root 用户"

    # 检测系统类型
    detect_os
    get_pkg_manager

    log "环境检查通过"
}

# ----------------------------------------------------------
# 安装依赖
# ----------------------------------------------------------
install_deps() {
    info "更新包索引并安装依赖..."

    # 更新包索引
    eval "${PKG_UPDATE}" >> "${LOG_FILE}" 2>&1 || true

    # supervisor
    if ! command -v supervisord >/dev/null 2>&1; then
        info "安装 supervisor..."
        case "${OS_ID}" in
            alpine)
                eval "${PKG_INSTALL} supervisor" >> "${LOG_FILE}" 2>&1
                ;;
            debian|ubuntu)
                eval "${PKG_INSTALL} supervisor" >> "${LOG_FILE}" 2>&1
                ;;
            rhel|centos|fedora)
                eval "${PKG_INSTALL} supervisor" >> "${LOG_FILE}" 2>&1
                ;;
            arch)
                eval "${PKG_INSTALL} supervisor" >> "${LOG_FILE}" 2>&1
                ;;
        esac
    else
        ok "supervisor 已安装"
    fi

    # python3 用于提供探活服务（轻量 HTTP 200）
    if ! command -v python3 >/dev/null 2>&1; then
        info "安装 python3..."
        case "${OS_ID}" in
            alpine)
                eval "${PKG_INSTALL} python3" >> "${LOG_FILE}" 2>&1
                ;;
            debian|ubuntu)
                eval "${PKG_INSTALL} python3" >> "${LOG_FILE}" 2>&1
                ;;
            rhel|centos|fedora)
                eval "${PKG_INSTALL} python3" >> "${LOG_FILE}" 2>&1
                ;;
            arch)
                eval "${PKG_INSTALL} python" >> "${LOG_FILE}" 2>&1
                ;;
        esac
    else
        ok "python3 已安装"
    fi

    # 可选：socat 作为纯 C 的备选探活服务
    if ! command -v socat >/dev/null 2>&1; then
        info "安装 socat（用于纯 TCP 探活，备用）..."
        case "${OS_ID}" in
            alpine|debian|ubuntu|rhel|centos|fedora|arch)
                eval "${PKG_INSTALL} socat" >> "${LOG_FILE}" 2>&1 || true
                ;;
        esac
    else
        ok "socat 已安装"
    fi

    log "依赖安装完成"
}

# ----------------------------------------------------------
# 读取已保存配置
# ----------------------------------------------------------
load_config() {
    if [ -f "${PORT_FILE}" ]; then
        SAVED_PORT=$(cat "${PORT_FILE}")
    else
        SAVED_PORT=""
    fi
}

# ----------------------------------------------------------
# 生成随机端口（10000-20000）
# ----------------------------------------------------------
generate_random_port() {
    # 使用 /dev/urandom 生成随机端口
    PORT=$(od -An -N2 -i /dev/urandom | tr -d ' ' | awk '{print int($1 % 10001) + 10000}')
    ok "自动生成随机端口: ${PORT}"
    log "自动生成随机端口: ${PORT}"
}

# ----------------------------------------------------------
# 提示输入端口
# ----------------------------------------------------------
prompt_port() {
    # 检测是否在交互式终端中运行
    # 如果不是交互式终端（如通过 curl | sh 管道执行），自动生成随机端口
    if [ ! -t 0 ]; then
        info "检测到非交互模式（管道执行），自动生成随机端口..."
        generate_random_port
        return
    fi

    load_config
    DEFAULT_PORT=""
    if [ -n "${SAVED_PORT}" ]; then
        DEFAULT_PORT=" [默认: ${SAVED_PORT}]"
    fi

    while true; do
        printf "${YELLOW}请输入探活端口 (1-65535)${DEFAULT_PORT}: ${NC}"
        # read 在非交互式管道中可能失败，捕获错误避免 set -e 退出
        if ! read -r INPUT_PORT; then
            warn "读取输入失败，自动生成随机端口..."
            generate_random_port
            break
        fi

        # 空输入
        if [ -z "${INPUT_PORT}" ]; then
            # 如果存在默认端口，使用默认
            if [ -n "${SAVED_PORT}" ]; then
                PORT="${SAVED_PORT}"
                ok "使用默认端口: ${PORT}"
                break
            else
                # 没有默认端口，生成随机端口
                generate_random_port
                break
            fi
        fi

        # 验证
        if echo "${INPUT_PORT}" | grep -qE '^[0-9]+$'; then
            if [ "${INPUT_PORT}" -ge 1 ] && [ "${INPUT_PORT}" -le 65535 ]; then
                PORT="${INPUT_PORT}"
                ok "使用输入端口: ${PORT}"
                break
            fi
        fi

        fail "无效端口，请输入 1-65535 之间的数字，或直接回车使用随机端口"
    done
}

# ----------------------------------------------------------
# 保存端口配置
# ----------------------------------------------------------
save_config() {
    mkdir -p "${CONF_DIR}"
    echo "${PORT}" > "${PORT_FILE}"
    log "端口配置已保存: ${PORT}"
}

# ----------------------------------------------------------
# 生成探活服务脚本
# ----------------------------------------------------------
generate_service_script() {
    SCRIPT_PATH="${CONF_DIR}/alive-port-server.py"

    cat > "${SCRIPT_PATH}" << 'PYEOF'
#!/usr/bin/env python3
"""
轻量探活服务：监听指定端口，任何访问返回 HTTP 200 OK
"""
import http.server
import socketserver
import sys
import os

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8080

class AliveHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header('Content-Type', 'text/plain; charset=utf-8')
        self.send_header('Content-Length', '2')
        self.end_headers()
        self.wfile.write(b'OK')

    def do_POST(self):
        self.do_GET()

    def do_PUT(self):
        self.do_GET()

    def do_DELETE(self):
        self.do_GET()

    def do_HEAD(self):
        self.send_response(200)
        self.send_header('Content-Type', 'text/plain; charset=utf-8')
        self.end_headers()

    def log_message(self, format, *args):
        # 抑制日志输出，保持安静
        pass

if __name__ == '__main__':
    os.chdir('/')
    with socketserver.TCPServer(('', PORT), AliveHandler) as httpd:
        try:
            httpd.serve_forever()
        except KeyboardInterrupt:
            pass
PYEOF

    chmod +x "${SCRIPT_PATH}"
    ok "探活服务脚本已生成: ${SCRIPT_PATH}"
    log "探活服务脚本已生成"
}

# ----------------------------------------------------------
# 生成 Supervisor 配置
# ----------------------------------------------------------
generate_supervisor_conf() {
    # 根据系统类型选择配置文件目录
    case "${OS_ID}" in
        alpine)
            SUPERVISOR_CONF_DIR="/etc/supervisor.d"
            ;;
        debian|ubuntu)
            SUPERVISOR_CONF_DIR="/etc/supervisor/conf.d"
            ;;
        rhel|centos|fedora)
            SUPERVISOR_CONF_DIR="/etc/supervisord.d"
            ;;
        arch)
            SUPERVISOR_CONF_DIR="/etc/supervisord.d"
            ;;
        *)
            # 默认尝试常见目录
            if [ -d "/etc/supervisor.d" ]; then
                SUPERVISOR_CONF_DIR="/etc/supervisor.d"
            elif [ -d "/etc/supervisor/conf.d" ]; then
                SUPERVISOR_CONF_DIR="/etc/supervisor/conf.d"
            elif [ -d "/etc/supervisord.d" ]; then
                SUPERVISOR_CONF_DIR="/etc/supervisord.d"
            else
                SUPERVISOR_CONF_DIR="/etc/supervisor.d"
            fi
            ;;
    esac

    SUPERVISOR_CONF="${SUPERVISOR_CONF_DIR}/${SERVICE_NAME}.conf"

    # 确保目录存在，如果失败则尝试备用目录
    if ! mkdir -p "${SUPERVISOR_CONF_DIR}" 2>/dev/null; then
        warn "无法创建目录 ${SUPERVISOR_CONF_DIR}，尝试备用目录..."
        case "${OS_ID}" in
            alpine)
                SUPERVISOR_CONF_DIR="/etc/supervisord.d"
                ;;
            debian|ubuntu)
                SUPERVISOR_CONF_DIR="/etc/supervisor/conf.d"
                ;;
            rhel|centos|fedora|arch)
                SUPERVISOR_CONF_DIR="/etc/supervisord.d"
                ;;
            *)
                if [ -d "/etc/supervisord.d" ]; then
                    SUPERVISOR_CONF_DIR="/etc/supervisord.d"
                elif [ -d "/etc/supervisor/conf.d" ]; then
                    SUPERVISOR_CONF_DIR="/etc/supervisor/conf.d"
                else
                    SUPERVISOR_CONF_DIR="/etc/supervisor.d"
                fi
                ;;
        esac
        SUPERVISOR_CONF="${SUPERVISOR_CONF_DIR}/${SERVICE_NAME}.conf"
        mkdir -p "${SUPERVISOR_CONF_DIR}" || {
            fail "无法创建 supervisor 配置目录: ${SUPERVISOR_CONF_DIR}"
            return 1
        }
    fi

    cat > "${SUPERVISOR_CONF}" << EOF
[program:${SERVICE_NAME}]
command=python3 ${CONF_DIR}/alive-port-server.py ${PORT}
directory=${CONF_DIR}
autostart=true
autorestart=true
startsecs=2
startretries=3
stopwaitsecs=5
stdout_logfile=${CONF_DIR}/supervisor-stdout.log
stderr_logfile=${CONF_DIR}/supervisor-stderr.log
stdout_logfile_maxbytes=1MB
stderr_logfile_maxbytes=1MB
stdout_logfile_backups=5
stderr_logfile_backups=5
environment=HOME="/root",USER="root"
EOF

    ok "Supervisor 配置已生成: ${SUPERVISOR_CONF}"
    log "Supervisor 配置已生成"
    return 0
}

# ----------------------------------------------------------
# 部署服务
# ----------------------------------------------------------
deploy_service() {
    info "正在部署探活服务..."

    # 生成脚本
    generate_service_script

    # 生成 supervisor 配置
    generate_supervisor_conf

    # 确保 supervisor 目录存在
    mkdir -p /var/log/supervisor

    # 确保 supervisord 正在运行
    info "检查 supervisord 进程..."
    if ! pgrep -x "supervisord" >/dev/null 2>&1; then
        info "启动 supervisord..."
        # 尝试不同的启动方式
        if [ -f /etc/supervisord.conf ]; then
            supervisord -c /etc/supervisord.conf >> "${LOG_FILE}" 2>&1 || true
        else
            supervisord >> "${LOG_FILE}" 2>&1 || true
        fi
        sleep 2
    else
        ok "supervisord 已在运行"
    fi

    # 再次确认 supervisord 运行
    if ! pgrep -x "supervisord" >/dev/null 2>&1; then
        warn "supervisord 启动失败，尝试再次启动..."
        supervisord >> "${LOG_FILE}" 2>&1 || true
        sleep 2
    fi

    # 重载 supervisor
    info "重载 Supervisor 配置..."
    supervisorctl reread >> "${LOG_FILE}" 2>&1 || true
    supervisorctl update >> "${LOG_FILE}" 2>&1 || true

    sleep 1

    # 启动服务
    info "启动探活服务..."
    if supervisorctl start "${SERVICE_NAME}" >> "${LOG_FILE}" 2>&1; then
        ok "探活服务已启动"
    else
        warn "首次启动失败，等待后重试..."
        sleep 2
        supervisorctl start "${SERVICE_NAME}" >> "${LOG_FILE}" 2>&1 || true
    fi

    # 等待启动
    sleep 2

    log "部署完成"
}

# ----------------------------------------------------------
# 验证服务
# ----------------------------------------------------------
verify_service() {
    info "验证探活服务..."

    # 检查 supervisor 状态
    if supervisorctl status "${SERVICE_NAME}" >/dev/null 2>&1; then
        ok "Supervisor 识别到服务"
    else
        fail "Supervisor 未识别到服务"
        return 1
    fi

    # 检查进程
    if pgrep -f "alive-port-server.py" >/dev/null 2>&1; then
        ok "探活服务进程运行中"
    else
        fail "探活服务进程未运行"
        return 1
    fi

    # 检查端口监听
    if command -v ss >/dev/null 2>&1; then
        if ss -tlnp | grep -q ":${PORT} "; then
            ok "端口 ${PORT} 正在监听"
        else
            warn "端口 ${PORT} 未检测到监听，但进程存在"
        fi
    elif command -v netstat >/dev/null 2>&1; then
        if netstat -tlnp | grep -q ":${PORT} "; then
            ok "端口 ${PORT} 正在监听"
        else
            warn "端口 ${PORT} 未检测到监听，但进程存在"
        fi
    else
        warn "ss/netstat 不可用，跳过端口监听检查"
    fi

    # HTTP 探活
    if command -v curl >/dev/null 2>&1; then
        if curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:${PORT}/" | grep -q "200"; then
            ok "HTTP 探活返回 200"
        else
            warn "HTTP 探活未返回 200（可能服务尚未完全启动）"
        fi
    else
        warn "curl 不可用，跳过 HTTP 探活验证"
    fi

    log "验证完成"
}

# ----------------------------------------------------------
# 纠错 / 修复
# ----------------------------------------------------------
fix_service() {
    info "尝试修复探活服务..."

    # 检查配置文件
    if [ ! -f "${SUPERVISOR_CONF}" ]; then
        warn "Supervisor 配置文件丢失，将重新生成"
        generate_supervisor_conf
    fi

    # 检查服务脚本
    if [ ! -f "${CONF_DIR}/alive-port-server.py" ]; then
        warn "服务脚本丢失，将重新生成"
        generate_service_script
    fi

    # 重载并重启
    supervisorctl reread >> "${LOG_FILE}" 2>&1 || true
    supervisorctl update >> "${LOG_FILE}" 2>&1 || true

    # 停止旧进程
    supervisorctl stop "${SERVICE_NAME}" >> "${LOG_FILE}" 2>&1 || true
    sleep 1

    # 启动
    supervisorctl start "${SERVICE_NAME}" >> "${LOG_FILE}" 2>&1 || true
    sleep 2

    # 再次验证
    verify_service
}

# ----------------------------------------------------------
# 显示状态
# ----------------------------------------------------------
show_status() {
    echo ""
    echo "========================================"
    echo " 探活端口服务状态"
    echo "========================================"

    # 读取端口
    if [ -f "${PORT_FILE}" ]; then
        PORT=$(cat "${PORT_FILE}")
        echo " 当前探活端口: ${PORT}"
    else
        echo " 探活端口: 未配置"
    fi

    # Supervisor 状态
    if supervisorctl status "${SERVICE_NAME}" >/dev/null 2>&1; then
        STATUS=$(supervisorctl status "${SERVICE_NAME}" 2>/dev/null | awk '{print $2}' || echo "unknown")
        echo " 服务状态    : ${STATUS}"

        # 显示详细信息
        DETAIL=$(supervisorctl status "${SERVICE_NAME}" 2>/dev/null || echo "无法获取状态")
        echo " 详细信息    : ${DETAIL}"
    else
        echo " 服务状态    : 未配置"
    fi

    # 进程检查
    if pgrep -f "alive-port-server.py" >/dev/null 2>&1; then
        echo " 进程 PID    : $(pgrep -f 'alive-port-server.py' | tr '\n' ' ')"
    else
        echo " 进程 PID    : 无"
    fi

    # 端口监听
    if [ -n "${PORT}" ] && [ "${PORT}" -gt 0 ] 2>/dev/null; then
        if command -v ss >/dev/null 2>&1; then
            if ss -tlnp | grep -q ":${PORT} "; then
                echo " 端口监听    : ${PORT} (listening)"
            else
                echo " 端口监听    : ${PORT} (未监听)"
            fi
        fi
    fi

    # 日志位置
    echo " 配置文件    : ${SUPERVISOR_CONF}"
    echo " 运行日志    : ${LOG_FILE}"
    echo "========================================"
    echo ""
}

# ----------------------------------------------------------
# 修改端口
# ----------------------------------------------------------
change_port() {
    info "进入修改端口流程..."

    if [ -f "${PORT_FILE}" ]; then
        CURRENT_PORT=$(cat "${PORT_FILE}")
        info "当前端口: ${CURRENT_PORT}"
    else
        warn "当前未配置端口"
    fi

    # 提示新端口
    prompt_port

    # 停止旧服务
    if supervisorctl status "${SERVICE_NAME}" >/dev/null 2>&1; then
        info "停止旧服务..."
        supervisorctl stop "${SERVICE_NAME}" >> "${LOG_FILE}" 2>&1 || true
    fi

    # 保存新端口
    save_config

    # 重新生成配置
    generate_supervisor_conf

    # 重载并启动
    info "启动新端口服务..."
    supervisorctl reread >> "${LOG_FILE}" 2>&1 || true
    supervisorctl update >> "${LOG_FILE}" 2>&1 || true
    supervisorctl start "${SERVICE_NAME}" >> "${LOG_FILE}" 2>&1 || true

    sleep 2

    # 验证
    verify_service

    ok "端口已修改为: ${PORT}"
}

# ----------------------------------------------------------
# 首次部署
# ----------------------------------------------------------
first_deploy() {
    info "首次部署探活端口服务..."

    check_env
    install_deps
    prompt_port
    save_config
    deploy_service
    verify_service

    echo ""
    ok "========================================"
    ok " 探活端口服务部署完成"
    ok " 端口: ${PORT}"
    ok " 外部访问: http://<服务器IP>:${PORT}/"
    ok " 返回: HTTP 200 OK"
    ok "========================================"
    echo ""
}

# ----------------------------------------------------------
# 主菜单
# ----------------------------------------------------------
main_menu() {
    # 检查是否已配置
    if [ ! -f "${PORT_FILE}" ] || [ ! -f "${SUPERVISOR_CONF}" ]; then
        info "检测到首次运行，进入部署流程..."
        first_deploy
        return
    fi

    # 非交互模式下（如 curl | sh），不显示菜单，直接显示状态并退出
    if [ ! -t 0 ]; then
        show_status
        exit 0
    fi

    # 交互模式下显示菜单
    show_status

    printf "${YELLOW}请选择操作:${NC}\n"
    echo "  1) 查看详细状态"
    echo "  2) 验证服务并纠错"
    echo "  3) 修改探活端口"
    echo "  4) 重启服务"
    echo "  5) 停止服务"
    echo "  6) 退出"
    echo ""
    printf "${YELLOW}输入选项 [1-6]: ${NC}"
    read -r CHOICE || true

    case "${CHOICE}" in
        1)
            info "显示详细状态..."
            supervisorctl status "${SERVICE_NAME}" 2>/dev/null || echo "服务未配置"
            echo ""
            if [ -f "${PORT_FILE}" ]; then
                PORT=$(cat "${PORT_FILE}")
                if command -v curl >/dev/null 2>&1; then
                    printf "HTTP 探活测试: "
                    curl -s -o /dev/null -w "HTTP %{http_code}\n" "http://127.0.0.1:${PORT}/"
                fi
            fi
            ;;
        2)
            fix_service
            show_status
            ;;
        3)
            change_port
            ;;
        4)
            info "重启服务..."
            supervisorctl restart "${SERVICE_NAME}" >> "${LOG_FILE}" 2>&1 || true
            sleep 2
            verify_service
            show_status
            ;;
        5)
            info "停止服务..."
            supervisorctl stop "${SERVICE_NAME}" >> "${LOG_FILE}" 2>&1 || true
            show_status
            ;;
        6)
            info "退出"
            exit 0
            ;;
        *)
            warn "无效选项"
            ;;
    esac
}

# ----------------------------------------------------------
# 入口
# ----------------------------------------------------------
if [ $# -gt 0 ]; then
    case "$1" in
        --status)
            show_status
            ;;
        --fix)
            fix_service
            ;;
        --change-port)
            change_port
            ;;
        --restart)
            supervisorctl restart "${SERVICE_NAME}" >> "${LOG_FILE}" 2>&1 || true
            show_status
            ;;
        --stop)
            supervisorctl stop "${SERVICE_NAME}" >> "${LOG_FILE}" 2>&1 || true
            show_status
            ;;
        --verify)
            verify_service
            ;;
        *)
            echo "用法: $0 [--status|--fix|--change-port|--restart|--stop|--verify]"
            exit 1
            ;;
    esac
else
    main_menu
fi
