#!/bin/bash
#
# SSH Shield - 交互式部署 SSH 防暴力破解 + 多渠道攻击通知
# 用法: sudo ./ssh-shield.sh
#
set -euo pipefail

BARK_API="https://api.day.app"
SSH_KEY_PATH="/root/.ssh/id_ed25519"
CONFIG_DIR="/etc/ssh-shield"
CONFIG_FILE="${CONFIG_DIR}/config"

# ─── 配置变量（交互填写） ───
CFG_BARK_KEY=""
CFG_FEISHU_WEBHOOK=""
CFG_SERVER_NAME="$HOSTNAME"
CFG_TRUSTED_IP=""
CFG_MAX_RETRY=3
CFG_FIND_TIME=600
CFG_BAN_TIME=86400
CFG_ENABLE_UFW="y"
CFG_AUTH_MODE="key"

# ─── 颜色输出 ───
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

info()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
fail()  { echo -e "${RED}[✗]${NC} $1"; exit 1; }
step()  { echo -e "\n${CYAN}━━━ $1 ━━━${NC}"; }

format_seconds() {
    local s=$1
    if (( s < 0 )); then
        echo "永久"
    elif (( s >= 86400 )); then
        echo "$((s / 86400))天"
    elif (( s >= 3600 )); then
        echo "$((s / 3600))小时"
    elif (( s >= 60 )); then
        echo "$((s / 60))分钟"
    else
        echo "${s}秒"
    fi
}

ask() {
    local prompt="$1" default="$2" var="$3" display_default=""
    [[ -n "$default" ]] && display_default=" ${DIM}[${default}]${NC}"
    echo -ne "  ${BOLD}${prompt}${NC}${display_default}: "
    local answer
    read -r answer < /dev/tty
    [[ -z "$answer" ]] && answer="$default"
    eval "$var=\"\$answer\""
}

ask_yn() {
    local prompt="$1" default="$2" var="$3" display_default=""
    [[ "$default" == "y" ]] && display_default=" ${DIM}[Y/n]${NC}" || display_default=" ${DIM}[y/N]${NC}"
    echo -ne "  ${BOLD}${prompt}${NC}${display_default}: "
    local answer
    read -r answer < /dev/tty
    [[ -z "$answer" ]] && answer="$default"
    case "$answer" in y|Y|yes|YES) eval "$var=\"y\"" ;; *) eval "$var=\"n\"" ;; esac
}

# ═══════════════════════════════════════════════════════════
#  配置持久化
# ═══════════════════════════════════════════════════════════

save_config() {
    mkdir -p "$CONFIG_DIR"
    cat > "$CONFIG_FILE" << CONF
BARK_KEY="${CFG_BARK_KEY}"
FEISHU_WEBHOOK="${CFG_FEISHU_WEBHOOK}"
USE_BARK="${USE_BARK:-n}"
USE_FEISHU="${USE_FEISHU:-n}"
SERVER_NAME="${CFG_SERVER_NAME}"
TRUSTED_IP="${CFG_TRUSTED_IP}"
MAX_RETRY="${CFG_MAX_RETRY}"
FIND_TIME="${CFG_FIND_TIME}"
BAN_TIME="${CFG_BAN_TIME}"
ENABLE_UFW="${CFG_ENABLE_UFW}"
AUTH_MODE="${CFG_AUTH_MODE}"
CONF
    chmod 600 "$CONFIG_FILE"
}

load_config() {
    local key value
    while IFS='=' read -r key value; do
        key="${key%"${key##*[![:space:]]}"}"
        [[ "$key" =~ ^#.*$ || -z "$key" ]] && continue
        value="${value#\"}"
        value="${value%\"}"
        case "$key" in
            BARK_KEY)       CFG_BARK_KEY="$value" ;;
            FEISHU_WEBHOOK) CFG_FEISHU_WEBHOOK="$value" ;;
            USE_BARK)       USE_BARK="$value" ;;
            USE_FEISHU)     USE_FEISHU="$value" ;;
            SERVER_NAME)    CFG_SERVER_NAME="$value" ;;
            TRUSTED_IP)     CFG_TRUSTED_IP="$value" ;;
            MAX_RETRY)      CFG_MAX_RETRY="$value" ;;
            FIND_TIME)      CFG_FIND_TIME="$value" ;;
            BAN_TIME)       CFG_BAN_TIME="$value" ;;
            ENABLE_UFW)     CFG_ENABLE_UFW="$value" ;;
            AUTH_MODE)      CFG_AUTH_MODE="$value" ;;
        esac
    done < "$CONFIG_FILE"
}

# ═══════════════════════════════════════════════════════════
#  配置生成（首次安装 & 重新配置共用）
# ═══════════════════════════════════════════════════════════

generate_notify_script() {
    local bark_key_inject="" feishu_webhook_inject=""
    [[ "$USE_BARK" == "y" ]] && bark_key_inject="${CFG_BARK_KEY}"
    [[ "$USE_FEISHU" == "y" ]] && feishu_webhook_inject="${CFG_FEISHU_WEBHOOK}"

    cat > /usr/local/bin/ssh-shield-notify.sh << NOTIFICATION_SCRIPT
#!/bin/bash
BARK_KEY="${bark_key_inject}"
BARK_URL="${BARK_API}/\${BARK_KEY}"
FEISHU_WEBHOOK="${feishu_webhook_inject}"

ACTION="\$1"
IP="\$2"
PORT="\$3"
ATTEMPTS="\$4"
JAIL="\$5"
SERVER_NAME="${CFG_SERVER_NAME}"
DATETIME=\$(date '+%Y-%m-%d %H:%M:%S %Z')

case "\$ACTION" in
  ban)
    TITLE="🚨 SSH攻击封禁 [\${SERVER_NAME}]"
    BODY="攻击IP: \${IP}
攻击端口: \${PORT}
尝试次数: \${ATTEMPTS}
触发规则: \${JAIL}
封禁时间: \${DATETIME}
封禁时长: $(format_seconds "$CFG_BAN_TIME")"
    ;;
  unban)
    TITLE="🔓 IP解封通知 [\${SERVER_NAME}]"
    BODY="解封IP: \${IP}
触发规则: \${JAIL}
解封时间: \${DATETIME}"
    ;;
  *)
    TITLE="⚠️ 安全告警 [\${SERVER_NAME}]"
    BODY="时间: \${DATETIME}
详情: \${ACTION}"
    ;;
esac

# ─── Bark 通知 ───
if [[ -n "\$BARK_KEY" ]]; then
  python3 -c "
import json, urllib.request
data = json.dumps({
    'title': '''\$TITLE''',
    'body': '''\$BODY''',
    'group': 'server-security',
    'sound': 'alarm'
}).encode()
req = urllib.request.Request('\${BARK_URL}', data=data, headers={'Content-Type': 'application/json'})
urllib.request.urlopen(req)
" > /dev/null 2>&1
fi

# ─── 飞书通知 ───
if [[ -n "\$FEISHU_WEBHOOK" ]]; then
  python3 -c "
import json, urllib.request
card = {
    'msg_type': 'interactive',
    'card': {
        'header': {
            'title': {'tag': 'plain_text', 'content': '''\$TITLE'''},
            'template': 'red'
        },
        'elements': [
            {'tag': 'markdown', 'content': '''\$BODY'''}
        ]
    }
}
req = urllib.request.Request('\${FEISHU_WEBHOOK}', data=json.dumps(card).encode(), headers={'Content-Type': 'application/json'})
urllib.request.urlopen(req)
" > /dev/null 2>&1
fi
NOTIFICATION_SCRIPT
    chmod +x /usr/local/bin/ssh-shield-notify.sh
    ln -sf /usr/local/bin/ssh-shield-notify.sh /usr/local/bin/bark-notify.sh 2>/dev/null || true
}

generate_jail_config() {
    local ignore_ip="127.0.0.1/8"
    [[ -n "$CFG_TRUSTED_IP" ]] && ignore_ip="127.0.0.1/8 ${CFG_TRUSTED_IP}"

    cat > /etc/fail2ban/jail.local << JAIL_CONF
[DEFAULT]
bantime = ${CFG_BAN_TIME}
findtime = ${CFG_FIND_TIME}
maxretry = ${CFG_MAX_RETRY}
ignoreip = ${ignore_ip}

[sshd]
enabled = true
port = ssh
logpath = %(sshd_log)s
backend = %(sshd_backend)s
maxretry = ${CFG_MAX_RETRY}
bantime = ${CFG_BAN_TIME}
action = %(action_)s
         bark
JAIL_CONF
}

# ═══════════════════════════════════════════════════════════
#  状态查看
# ═══════════════════════════════════════════════════════════

show_status() {
    echo ""
    echo -e "  ${CYAN}════════════════════════════════════${NC}"
    echo -e "  ${CYAN}       SSH Shield 运行状态${NC}"
    echo -e "  ${CYAN}════════════════════════════════════${NC}"

    # fail2ban 服务
    echo ""
    echo -e "  ${BOLD}fail2ban 服务:${NC}"
    if systemctl is-active --quiet fail2ban; then
        echo -e "    状态: ${GREEN}运行中${NC}"
    else
        echo -e "    状态: ${RED}未运行${NC}"
    fi

    # sshd jail 详细状态
    echo ""
    echo -e "  ${BOLD}SSH 防护状态:${NC}"
    if fail2ban-client status sshd &>/dev/null; then
        fail2ban-client status sshd 2>/dev/null | sed 's/^/    /'
    else
        echo -e "    ${DIM}无法获取 jail 状态${NC}"
    fi

    # 最近封禁记录
    echo ""
    echo -e "  ${BOLD}最近封禁/解封记录:${NC}"
    if journalctl -u fail2ban --no-pager -n 20 2>/dev/null | grep -q "Ban\|Unban"; then
        journalctl -u fail2ban --no-pager -n 20 2>/dev/null | grep "Ban\|Unban" | tail -10 | sed 's/^/    /'
    else
        echo -e "    ${DIM}暂无记录${NC}"
    fi

    # 最近登录失败
    echo ""
    echo -e "  ${BOLD}最近 SSH 登录失败:${NC}"
    local recent_failed
    recent_failed=$(journalctl -u ssh -u sshd --no-pager -n 50 2>/dev/null | grep -i "Failed password" | tail -5)
    if [[ -n "$recent_failed" ]]; then
        echo "$recent_failed" | sed 's/^/    /'
    else
        echo -e "    ${DIM}暂无失败记录${NC}"
    fi

    # SSH 配置
    echo ""
    echo -e "  ${BOLD}SSH 安全配置:${NC}"
    if [[ -f /etc/ssh/sshd_config.d/49-hardening.conf ]]; then
        grep -v "^#\|^$" /etc/ssh/sshd_config.d/49-hardening.conf | sed 's/^/    /'
    else
        echo -e "    ${DIM}未配置加固${NC}"
    fi

    # UFW 状态
    if command -v ufw &>/dev/null; then
        echo ""
        echo -e "  ${BOLD}UFW 防火墙:${NC}"
        ufw status 2>/dev/null | head -5 | sed 's/^/    /'
    fi

    echo ""
}

# ═══════════════════════════════════════════════════════════
#  卸载
# ═══════════════════════════════════════════════════════════

do_uninstall() {
    echo ""
    echo -e "  ${RED}╔══════════════════════════════════════════╗${NC}"
    echo -e "  ${RED}║          卸载 SSH Shield                 ║${NC}"
    echo -e "  ${RED}╚══════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${YELLOW}将移除以下内容:${NC}"
    echo "    - fail2ban SSH Shield 规则 (jail.local)"
    echo "    - fail2ban 通知 action (bark.conf)"
    echo "    - 通知脚本 (ssh-shield-notify.sh)"
    echo "    - SSH 安全加固 (49-hardening.conf)"
    echo "    - SSH Shield 配置文件"
    echo ""
    echo -e "  ${GREEN}保留:${NC} fail2ban 服务、SSH 密钥"
    echo ""

    ask_yn "确认卸载？" "n" CONFIRM_UNINSTALL
    [[ "$CONFIRM_UNINSTALL" != "y" ]] && { echo -e "  ${DIM}已取消${NC}"; exit 0; }

    step "移除 fail2ban 配置"
    fail2ban-client stop sshd 2>/dev/null || true
    rm -f /etc/fail2ban/jail.local
    rm -f /etc/fail2ban/action.d/bark.conf
    systemctl restart fail2ban 2>/dev/null || true
    info "fail2ban SSH Shield 规则已移除"

    step "移除通知脚本"
    rm -f /usr/local/bin/ssh-shield-notify.sh
    rm -f /usr/local/bin/bark-notify.sh
    info "通知脚本已删除"

    step "移除 SSH 加固"
    rm -f /etc/ssh/sshd_config.d/49-hardening.conf
    if sshd -t 2>/dev/null; then
        systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
        info "SSH 配置已恢复"
    else
        warn "SSH 配置恢复后语法检查失败，请手动检查"
    fi

    step "清理配置文件"
    rm -rf "$CONFIG_DIR"
    info "配置文件已删除"

    echo ""
    echo -e "  ${GREEN}[✓] SSH Shield 已完全卸载${NC}"
    echo ""
    exit 0
}

# ═══════════════════════════════════════════════════════════
#  重新配置菜单
# ═══════════════════════════════════════════════════════════

show_current_config() {
    echo ""
    echo -e "  ${CYAN}当前配置:${NC}"
    echo -e "  ${DIM}─────────────────────────────────────────${NC}"
    local channels=""
    [[ "$USE_BARK" == "y" ]] && channels="Bark ✓"
    [[ "$USE_FEISHU" == "y" ]] && channels="${channels:+$channels | }飞书 ✓"
    [[ -z "$channels" ]] && channels="未配置"
    echo -e "  通知渠道:     ${GREEN}${channels}${NC}"
    [[ "$USE_BARK" == "y" ]] && echo -e "  Bark Key:     ${DIM}${CFG_BARK_KEY}${NC}"
    [[ "$USE_FEISHU" == "y" ]] && echo -e "  飞书 Webhook: ${DIM}${CFG_FEISHU_WEBHOOK}${NC}"
    echo -e "  服务器名称:   ${GREEN}${CFG_SERVER_NAME}${NC}"
    if [[ -n "$CFG_TRUSTED_IP" ]]; then
        echo -e "  可信 IP:      ${GREEN}${CFG_TRUSTED_IP}${NC}"
    else
        echo -e "  可信 IP:      ${DIM}未设置${NC}"
    fi
    echo -e "  最大失败次数: ${GREEN}${CFG_MAX_RETRY} 次${NC}"
    echo -e "  检测时间:     ${GREEN}$(format_seconds "$CFG_FIND_TIME")${NC}"
    echo -e "  封禁时长:     ${GREEN}$(format_seconds "$CFG_BAN_TIME")$([ "$CFG_BAN_TIME" -ge 0 ] && echo " (${CFG_BAN_TIME}s)")${NC}"
    echo -e "  UFW 防火墙:   $([ "$CFG_ENABLE_UFW" == "y" ] && echo -e "${GREEN}已启用${NC}" || echo -e "${YELLOW}未启用${NC}")"
    if [[ "$CFG_AUTH_MODE" == "key" ]]; then
        echo -e "  SSH 登录方式: ${GREEN}密钥认证${NC}"
    else
        echo -e "  SSH 登录方式: ${GREEN}密码认证${NC}"
    fi
    echo -e "  ${DIM}─────────────────────────────────────────${NC}"
}

apply_reconfigure() {
    step "应用配置变更"

    generate_notify_script
    info "通知脚本已更新"

    generate_jail_config
    info "fail2ban 规则已更新"

    if [[ -f /etc/ssh/sshd_config.d/49-hardening.conf ]]; then
        if [[ "$CFG_AUTH_MODE" == "key" ]]; then
            sed -i "s/^PasswordAuthentication.*/PasswordAuthentication no/" /etc/ssh/sshd_config.d/49-hardening.conf
            sed -i "s/^PermitRootLogin.*/PermitRootLogin prohibit-password/" /etc/ssh/sshd_config.d/49-hardening.conf
            if [[ ! -f "$SSH_KEY_PATH" ]]; then
                ssh-keygen -t ed25519 -f "$SSH_KEY_PATH" -N "" -C "root@${CFG_SERVER_NAME}" -q
                cat "${SSH_KEY_PATH}.pub" >> /root/.ssh/authorized_keys
                chmod 600 /root/.ssh/authorized_keys
                info "Ed25519 密钥对已生成（切换到密钥模式）"
                echo ""
                echo -e "  ${YELLOW}⚠️  请立即保存以下私钥到本地，否则将无法登录！${NC}"
                echo ""
                cat "$SSH_KEY_PATH"
                echo ""
            fi
        else
            sed -i "s/^PasswordAuthentication.*/PasswordAuthentication yes/" /etc/ssh/sshd_config.d/49-hardening.conf
            sed -i "s/^PermitRootLogin.*/PermitRootLogin yes/" /etc/ssh/sshd_config.d/49-hardening.conf
        fi
        sed -i "s/^MaxAuthTries.*/MaxAuthTries ${CFG_MAX_RETRY}/" /etc/ssh/sshd_config.d/49-hardening.conf
        sshd -t || warn "SSH 配置语法检查失败"
        systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
        info "SSH 服务已重载"
    fi

    systemctl restart fail2ban
    sleep 2
    info "fail2ban 已重启"

    save_config
    /usr/local/bin/ssh-shield-notify.sh "✅配置已更新" "SSH-Shield配置已修改并生效" "" "" "" || true
}

reconfigure_menu() {
    echo ""
    echo -e "  ${CYAN}╔══════════════════════════════════════════╗${NC}"
    echo -e "  ${CYAN}║     检测到 SSH Shield 已安装！           ║${NC}"
    echo -e "  ${CYAN}╚══════════════════════════════════════════╝${NC}"

    local changed=false

    while true; do
        show_current_config
        echo ""
        echo -e "  ${BOLD}请选择要修改的配置:${NC}"
        echo -e "    1) Bark 通知设置"
        echo -e "    2) 飞书通知设置"
        echo -e "    3) 服务器名称"
        echo -e "    4) 可信 IP 白名单"
        echo -e "    5) fail2ban 防护参数"
        echo -e "    6) UFW 防火墙"
        echo -e "    7) SSH 登录方式"
        echo -e "    ${DIM}─────────────────────${NC}"
        echo -e "    8) 查看运行状态"
        echo -e "    9) 全部重新配置"
        echo -e "   10) 卸载 SSH Shield"
        echo -e "    ${DIM}0) 退出${NC}"
        echo ""

        local choice
        echo -ne "  ${BOLD}输入选项 [0-10]:${NC} "
        read -r choice < /dev/tty

        case "$choice" in
            1)
                echo ""
                echo -e "  ${CYAN}▶ Bark 通知设置${NC}"
                echo ""
                ask_yn "启用 Bark 通知？" "${USE_BARK}" USE_BARK
                if [[ "$USE_BARK" == "y" ]]; then
                    while true; do
                        ask "Bark Key" "${CFG_BARK_KEY}" CFG_BARK_KEY
                        [[ -n "$CFG_BARK_KEY" ]] && break
                        echo -e "  ${RED}Bark Key 不能为空${NC}"
                    done
                    echo -ne "  测试 Bark 通知... "
                    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "${BARK_API}/${CFG_BARK_KEY}/连通测试/SSH-Shield配置更新" 2>/dev/null || echo "000")
                    if [[ "$HTTP_CODE" == "200" ]]; then
                        echo -e "${GREEN}成功 ✓${NC}"
                    else
                        warn "Bark 不可达 (HTTP ${HTTP_CODE})"
                    fi
                fi
                changed=true
                ;;
            2)
                echo ""
                echo -e "  ${CYAN}▶ 飞书通知设置${NC}"
                echo ""
                ask_yn "启用飞书通知？" "${USE_FEISHU}" USE_FEISHU
                if [[ "$USE_FEISHU" == "y" ]]; then
                    echo -e "  ${DIM}获取方式：飞书群 → 设置 → 群机器人 → 添加自定义机器人 → 复制 Webhook 地址${NC}"
                    while true; do
                        ask "飞书 Webhook URL" "${CFG_FEISHU_WEBHOOK}" CFG_FEISHU_WEBHOOK
                        [[ -n "$CFG_FEISHU_WEBHOOK" ]] && break
                        echo -e "  ${RED}Webhook URL 不能为空${NC}"
                    done
                    echo -ne "  测试飞书通知... "
                    FEISHU_RESULT=$(curl -s -X POST "$CFG_FEISHU_WEBHOOK" \
                        -H "Content-Type: application/json" \
                        -d '{"msg_type":"interactive","card":{"header":{"title":{"tag":"plain_text","content":"SSH Shield 配置更新测试"}},"elements":[{"tag":"markdown","content":"**测试通知** — 飞书通知配置已更新 ✓"}]}}' \
                        2>/dev/null || echo '{"code":-1}')
                    FEISHU_CODE=$(echo "$FEISHU_RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('code','-1'))" 2>/dev/null || echo "-1")
                    if [[ "$FEISHU_CODE" == "0" ]]; then
                        echo -e "${GREEN}成功 ✓${NC}"
                    else
                        warn "飞书不可达"
                    fi
                fi
                changed=true
                ;;
            3)
                echo ""
                ask "服务器名称" "${CFG_SERVER_NAME}" CFG_SERVER_NAME
                changed=true
                ;;
            4)
                echo ""
                ask "可信 IP 白名单（留空清除）" "${CFG_TRUSTED_IP}" CFG_TRUSTED_IP
                changed=true
                ;;
            5)
                echo ""
                echo -e "  ${CYAN}▶ fail2ban 防护参数${NC}"
                echo ""
                echo -e "  ${DIM}最大失败次数：触发封禁前允许的登录失败次数${NC}"
                ask "最大失败次数 (maxretry)" "${CFG_MAX_RETRY}" CFG_MAX_RETRY
                CFG_MAX_RETRY=$((CFG_MAX_RETRY + 0)) 2>/dev/null || CFG_MAX_RETRY=3
                echo ""
                echo -e "  ${DIM}检测时间窗口：在此时间内的失败次数会被累计${NC}"
                ask "检测时间/秒 (findtime)" "${CFG_FIND_TIME}" CFG_FIND_TIME
                CFG_FIND_TIME=$((CFG_FIND_TIME + 0)) 2>/dev/null || CFG_FIND_TIME=600
                echo ""
                echo -e "  ${DIM}封禁时长：触发封禁后 IP 被禁止访问的时间${NC}"
                echo -e "  ${DIM}常用值：3600(1小时) 86400(1天) 604800(7天) -1(永久封禁)${NC}"
                ask "封禁时长/秒 (bantime)" "${CFG_BAN_TIME}" CFG_BAN_TIME
                CFG_BAN_TIME=$((CFG_BAN_TIME + 0)) 2>/dev/null || CFG_BAN_TIME=86400
                changed=true
                ;;
            6)
                echo ""
                if command -v ufw &>/dev/null; then
                    ask_yn "启用 UFW 防火墙" "${CFG_ENABLE_UFW}" CFG_ENABLE_UFW
                else
                    echo -e "  ${DIM}UFW 未安装${NC}"
                fi
                changed=true
                ;;
            7)
                echo ""
                echo -e "  ${CYAN}▶ SSH 登录方式${NC}"
                echo ""
                echo -e "  ${DIM}key = 密钥认证（更安全，推荐）${NC}"
                echo -e "  ${DIM}password = 密码认证（保留密码登录）${NC}"
                echo ""
                local auth_choice=""
                ask "登录方式 (key/password)" "${CFG_AUTH_MODE}" auth_choice
                case "$auth_choice" in
                    key|k) CFG_AUTH_MODE="key" ;;
                    password|p|pwd) CFG_AUTH_MODE="password" ;;
                    *) CFG_AUTH_MODE="${CFG_AUTH_MODE}" ;;
                esac
                changed=true
                ;;
            8)
                show_status
                ;;
            9)
                echo ""
                echo -e "  ${YELLOW}将清除现有配置并重新开始...${NC}"
                rm -f "$CONFIG_FILE"
                exec "$0"
                ;;
            10)
                do_uninstall
                ;;
            0|"")
                if [[ "$changed" == true ]]; then
                    apply_reconfigure
                    echo ""
                    echo -e "  ${GREEN}[✓] 配置已更新并生效${NC}"
                else
                    echo -e "  ${DIM}未做修改，退出${NC}"
                fi
                exit 0
                ;;
            *)
                echo -e "  ${RED}无效选项，请输入 0-10${NC}"
                ;;
        esac
    done
}

# ═══════════════════════════════════════════════════════════
#  Banner
# ═══════════════════════════════════════════════════════════
echo ""
echo -e "${CYAN}  ╔══════════════════════════════════════════╗${NC}"
echo -e "${CYAN}  ║            SSH Shield v1.2               ║${NC}"
echo -e "${CYAN}  ║  SSH 防暴力破解 + 多渠道攻击通知         ║${NC}"
echo -e "${CYAN}  ╚══════════════════════════════════════════╝${NC}"
echo ""

# ─── 前置检查 ───
[[ $EUID -ne 0 ]] && fail "请以 root 用户运行此脚本"
command -v python3 &>/dev/null || fail "需要 python3"
command -v curl &>/dev/null || fail "需要 curl"

# ─── 命令行参数 ───
case "${1:-}" in
    status)   show_status; exit 0 ;;
    uninstall) do_uninstall ;;
    help|--help|-h)
        echo "用法: sudo $0 [status|uninstall]"
        echo "  (无参数)    首次安装 或 重新配置"
        echo "  status     查看运行状态"
        echo "  uninstall  卸载 SSH Shield"
        exit 0
        ;;
esac

# ─── 检测已有安装 ───
if [[ -f "$CONFIG_FILE" ]]; then
    load_config
    reconfigure_menu
fi

# ═══════════════════════════════════════════════════════════
#  首次安装 - 交互式配置
# ═══════════════════════════════════════════════════════════
echo -e "${BOLD}请根据提示配置参数（直接回车使用默认值）${NC}"
echo -e "${DIM}─────────────────────────────────────────${NC}"

# ─── Bark 配置 ───
echo ""
echo -e "  ${CYAN}▶ Bark 通知（iOS 推送）${NC}"
echo ""
ask_yn "启用 Bark 通知？" "y" USE_BARK
if [[ "$USE_BARK" == "y" ]]; then
    while true; do
        ask "Bark Key（从 Bark App 获取）" "" CFG_BARK_KEY
        [[ -n "$CFG_BARK_KEY" ]] && break
        echo -e "  ${RED}Bark Key 不能为空${NC}"
    done

    echo -ne "  测试 Bark 通知... "
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "${BARK_API}/${CFG_BARK_KEY}/连通测试/SSH-Shield配置向导" 2>/dev/null || echo "000")
    if [[ "$HTTP_CODE" == "200" ]]; then
        echo -e "${GREEN}成功 ✓${NC}（请检查手机是否收到测试通知）"
    else
        fail "Bark 通知不可达 (HTTP ${HTTP_CODE})，请检查 Key"
    fi
fi

# ─── 飞书配置 ───
echo ""
echo -e "  ${CYAN}▶ 飞书通知（Webhook 机器人）${NC}"
echo ""
ask_yn "启用飞书通知？" "n" USE_FEISHU
if [[ "$USE_FEISHU" == "y" ]]; then
    echo -e "  ${DIM}获取方式：飞书群 → 设置 → 群机器人 → 添加自定义机器人 → 复制 Webhook 地址${NC}"
    while true; do
        ask "飞书 Webhook URL" "" CFG_FEISHU_WEBHOOK
        [[ -n "$CFG_FEISHU_WEBHOOK" ]] && break
        echo -e "  ${RED}Webhook URL 不能为空${NC}"
    done

    echo -ne "  测试飞书通知... "
    FEISHU_RESULT=$(curl -s -X POST "$CFG_FEISHU_WEBHOOK" \
        -H "Content-Type: application/json" \
        -d '{"msg_type":"interactive","card":{"header":{"title":{"tag":"plain_text","content":"SSH Shield 连通测试"}},"elements":[{"tag":"markdown","content":"**测试通知** — 如果你看到这条消息，说明飞书通知配置正确 ✓"}]}}' \
        2>/dev/null || echo '{"code":-1}')
    FEISHU_CODE=$(echo "$FEISHU_RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('code','-1'))" 2>/dev/null || echo "-1")
    if [[ "$FEISHU_CODE" == "0" ]]; then
        echo -e "${GREEN}成功 ✓${NC}（请检查飞书群是否收到测试通知）"
    else
        fail "飞书通知不可达，请检查 Webhook URL"
    fi
fi

[[ "$USE_BARK" != "y" && "$USE_FEISHU" != "y" ]] && fail "至少需要启用一个通知渠道"

# ─── 通用配置 ───
echo ""
echo -e "  ${CYAN}▶ 通用配置${NC}"
echo ""
ask "通知标题中的服务器名称" "$HOSTNAME" CFG_SERVER_NAME
ask "可信 IP 白名单（留空跳过）" "" CFG_TRUSTED_IP

# ─── fail2ban 配置 ───
echo ""
echo -e "  ${CYAN}▶ fail2ban 防护参数${NC}"
echo ""

echo -e "  ${DIM}最大失败次数：触发封禁前允许的登录失败次数${NC}"
ask "最大失败次数 (maxretry)" "3" CFG_MAX_RETRY
CFG_MAX_RETRY=$((CFG_MAX_RETRY + 0)) 2>/dev/null || CFG_MAX_RETRY=3

echo ""
echo -e "  ${DIM}检测时间窗口：在此时间内的失败次数会被累计${NC}"
ask "检测时间/秒 (findtime)" "600" CFG_FIND_TIME
CFG_FIND_TIME=$((CFG_FIND_TIME + 0)) 2>/dev/null || CFG_FIND_TIME=600

echo ""
echo -e "  ${DIM}封禁时长：触发封禁后 IP 被禁止访问的时间${NC}"
echo -e "  ${DIM}常用值：3600(1小时) 86400(1天) 604800(7天) -1(永久封禁)${NC}"
ask "封禁时长/秒 (bantime)" "86400" CFG_BAN_TIME
CFG_BAN_TIME=$((CFG_BAN_TIME + 0)) 2>/dev/null || CFG_BAN_TIME=86400

# ─── 防火墙配置 ───
echo ""
echo -e "  ${CYAN}▶ UFW 防火墙${NC}"
echo ""
if command -v ufw &>/dev/null; then
    ask_yn "启用 UFW 防火墙（默认拒绝入站，仅开放 SSH）" "y" CFG_ENABLE_UFW
else
    CFG_ENABLE_UFW="n"
    echo -e "  ${DIM}UFW 未安装，跳过${NC}"
fi

# ─── SSH 登录方式 ───
echo ""
echo -e "  ${CYAN}▶ SSH 登录方式${NC}"
echo ""
echo -e "  ${DIM}key      = 密钥认证（生成 Ed25519 密钥，禁用密码登录，更安全）${NC}"
echo -e "  ${DIM}password = 密码认证（保留密码登录，不生成密钥）${NC}"
echo ""
while true; do
    ask "登录方式 (key/password)" "key" CFG_AUTH_MODE
    case "$CFG_AUTH_MODE" in
        key|k) CFG_AUTH_MODE="key"; break ;;
        password|p|pwd) CFG_AUTH_MODE="password"; break ;;
        *) echo -e "  ${RED}请输入 key 或 password${NC}" ;;
    esac
done

# ═══════════════════════════════════════════════════════════
#  配置确认
# ═══════════════════════════════════════════════════════════
echo ""
echo -e "${BOLD}─────────── 配置确认 ───────────${NC}"
echo ""
echo -e "  通知渠道:"
[[ "$USE_BARK" == "y" ]] && echo -e "    Bark:      ${GREEN}启用${NC} (${CFG_BARK_KEY})"
[[ "$USE_FEISHU" == "y" ]] && echo -e "    飞书:      ${GREEN}启用${NC}"
[[ "$USE_BARK" != "y" && "$USE_FEISHU" != "y" ]] && echo -e "    ${RED}未配置${NC}"
echo -e "  服务器名称:     ${GREEN}${CFG_SERVER_NAME}${NC}"
if [[ -n "$CFG_TRUSTED_IP" ]]; then
    echo -e "  可信 IP:        ${GREEN}${CFG_TRUSTED_IP}${NC}"
else
    echo -e "  可信 IP:        ${DIM}未设置${NC}"
fi
echo -e "  最大失败次数:   ${GREEN}${CFG_MAX_RETRY} 次${NC}"
echo -e "  检测时间窗口:   ${GREEN}$(format_seconds $CFG_FIND_TIME) (${CFG_FIND_TIME}s)${NC}"
echo -e "  封禁时长:       ${GREEN}$(format_seconds $CFG_BAN_TIME)$([ $CFG_BAN_TIME -ge 0 ] && echo " (${CFG_BAN_TIME}s)")${NC}"
echo -e "  UFW 防火墙:    $([ "$CFG_ENABLE_UFW" == "y" ] && echo -e "${GREEN}启用${NC}" || echo -e "${YELLOW}跳过${NC}")"
if [[ "$CFG_AUTH_MODE" == "key" ]]; then
    echo -e "  SSH 登录方式:  ${GREEN}密钥认证（Ed25519）${NC}"
else
    echo -e "  SSH 登录方式:  ${GREEN}密码认证${NC}"
fi
echo ""

confirm=""
ask_yn "确认以上配置，开始部署？" "y" confirm
[[ "$confirm" != "y" ]] && { echo "已取消"; exit 0; }

# ═══════════════════════════════════════════════════════════
#  开始部署
# ═══════════════════════════════════════════════════════════

# ─── 1. 安装 fail2ban ───
step "1/9 安装 fail2ban"
if command -v fail2ban-client &>/dev/null; then
    info "fail2ban 已安装，跳过"
else
    apt-get update -qq
    apt-get install -y -qq fail2ban
    info "fail2ban 安装完成"
fi
systemctl enable fail2ban

# ─── 2. 部署通知脚本 ───
step "2/9 部署通知脚本"
generate_notify_script
info "ssh-shield-notify.sh 已部署（Bark=$USE_BARK, 飞书=$USE_FEISHU）"

# ─── 3. 配置 fail2ban action ───
step "3/9 配置 fail2ban action"
cat > /etc/fail2ban/action.d/bark.conf << 'FAIL2BAN_ACTION'
[Definition]
actionstart = /usr/local/bin/ssh-shield-notify.sh "fail2ban已启动，监控规则: <name>" "" "" "" "<name>"
actionstop = /usr/local/bin/ssh-shield-notify.sh "fail2ban已停止，规则: <name>" "" "" "" "<name>"
actioncheck =
actionban = /usr/local/bin/ssh-shield-notify.sh "ban" "<ip>" "<port>" "<failures>" "<name>"
actionunban = /usr/local/bin/ssh-shield-notify.sh "unban" "<ip>" "<port>" "" "<name>"

[Init]
port = ssh
FAIL2BAN_ACTION
info "action 已配置"

# ─── 4. 配置 fail2ban jail ───
step "4/9 配置 fail2ban 防护规则"
generate_jail_config
info "防护规则已配置（${CFG_MAX_RETRY}次失败/$(format_seconds $CFG_FIND_TIME) → 封禁$(format_seconds $CFG_BAN_TIME)）"

# ─── 5. 生成 SSH 密钥 ───
step "5/9 生成 SSH 密钥"
if [[ "$CFG_AUTH_MODE" == "password" ]]; then
    warn "密码认证模式，跳过密钥生成"
elif [[ -f "$SSH_KEY_PATH" ]]; then
    warn "SSH 密钥已存在，跳过生成"
else
    ssh-keygen -t ed25519 -f "$SSH_KEY_PATH" -N "" -C "root@${CFG_SERVER_NAME}" -q
    cat "${SSH_KEY_PATH}.pub" >> /root/.ssh/authorized_keys
    chmod 600 /root/.ssh/authorized_keys
    info "Ed25519 密钥对已生成"
fi

# ─── 6. SSH 加固 ───
step "6/9 SSH 安全加固"
if [[ -f /etc/ssh/sshd_config.d/49-hardening.conf ]]; then
    warn "SSH 加固配置已存在，跳过"
else
    password_auth="no" root_login="prohibit-password"
    if [[ "$CFG_AUTH_MODE" == "password" ]]; then
        password_auth="yes"
        root_login="yes"
    fi
    cat > /etc/ssh/sshd_config.d/49-hardening.conf << SSH_HARDENING
# SSH Shield - Security hardening
# Must load before 50-cloud-init.conf (sshd first-match-wins)
PasswordAuthentication ${password_auth}
PermitRootLogin ${root_login}
MaxAuthTries ${CFG_MAX_RETRY}
LoginGraceTime 30s
MaxStartups 5:30:10
X11Forwarding no
SSH_HARDENING
    info "SSH 加固配置已写入"
fi

sshd -t || fail "SSH 配置语法错误"
systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
info "SSH 服务已重载"

# ─── 7. 配置 UFW 防火墙 ───
step "7/9 UFW 防火墙"
if [[ "$CFG_ENABLE_UFW" == "y" ]] && command -v ufw &>/dev/null; then
    if ufw status | grep -q "active"; then
        warn "UFW 已启用，跳过"
    else
        ufw allow 22/tcp
        ufw --force enable
        info "UFW 防火墙已启用（仅开放 SSH 22）"
    fi
else
    warn "跳过 UFW 配置"
fi

# ─── 8. 重启 fail2ban ───
step "8/9 启动 fail2ban"
systemctl restart fail2ban
sleep 2
info "fail2ban 运行中"

# ─── 9. 发送部署完成通知 ───
step "9/9 发送部署完成通知"
/usr/local/bin/ssh-shield-notify.sh "✅部署完成" "SSH-Shield已成功部署到${CFG_SERVER_NAME}" "" "" "" || true
info "完成通知已发送"

# ─── 保存配置 ───
save_config

# ═══════════════════════════════════════════════════════════
#  部署结果
# ═══════════════════════════════════════════════════════════
echo ""
echo -e "${CYAN}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║              ${BOLD}SSH Shield 部署完成${NC}${CYAN}                         ║${NC}"
echo -e "${CYAN}╠══════════════════════════════════════════════════════╣${NC}"
CHANNELS=""
[[ "$USE_BARK" == "y" ]] && CHANNELS="Bark"
[[ "$USE_FEISHU" == "y" ]] && CHANNELS="${CHANNELS:+$CHANNELS + }飞书"
echo -e "${CYAN}║${NC} 通知渠道: ${GREEN}${CHANNELS}${NC}"
echo -e "${CYAN}║${NC} 服务器名: ${GREEN}${CFG_SERVER_NAME}${NC}"
echo -e "${CYAN}║${NC} 防护规则: ${GREEN}${CFG_MAX_RETRY}次失败/$(format_seconds $CFG_FIND_TIME) → 封禁$(format_seconds $CFG_BAN_TIME)${NC}"
if [[ "$CFG_AUTH_MODE" == "key" ]]; then
    echo -e "${CYAN}║${NC} SSH 密钥: ${GREEN}${SSH_KEY_PATH}${NC}"
    echo -e "${CYAN}║${NC} 登录方式: ${GREEN}密钥认证（密码已禁用）${NC}"
else
    echo -e "${CYAN}║${NC} 登录方式: ${GREEN}密码认证${NC}"
fi
echo -e "${CYAN}║${NC} UFW 防火墙: $([ "$CFG_ENABLE_UFW" == "y" ] && echo -e "${GREEN}已启用${NC}" || echo -e "${YELLOW}跳过${NC}")"
echo -e "${CYAN}║${NC} 重启生效: ${GREEN}所有配置持久化，重启后自动生效${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════════╝${NC}"
if [[ "$CFG_AUTH_MODE" == "key" ]]; then
    echo ""
    echo -e "${YELLOW}⚠️  请立即保存以下私钥到本地，否则将无法登录！${NC}"
    echo ""
    cat "$SSH_KEY_PATH"
    echo ""
    echo -e "${YELLOW}使用方法:${NC}"
    echo "  chmod 600 ~/ssh-shield-key"
    echo "  ssh -i ~/ssh-shield-key root@<服务器IP>"
fi
