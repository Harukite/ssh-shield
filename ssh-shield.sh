#!/bin/bash
#
# SSH Shield - 交互式部署 SSH 防暴力破解 + 多渠道攻击通知
# 用法: sudo ./ssh-shield.sh
#
set -euo pipefail

BARK_API="https://api.day.app"
SSH_KEY_PATH="/root/.ssh/id_ed25519"

# ─── 配置变量（交互填写） ───
CFG_BARK_KEY=""
CFG_FEISHU_WEBHOOK=""
CFG_SERVER_NAME="$HOSTNAME"
CFG_TRUSTED_IP=""
CFG_MAX_RETRY=3
CFG_FIND_TIME=600
CFG_BAN_TIME=86400
CFG_ENABLE_UFW="y"

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
#  Banner
# ═══════════════════════════════════════════════════════════
echo ""
echo -e "${CYAN}  ╔══════════════════════════════════════════╗${NC}"
echo -e "${CYAN}  ║            SSH Shield v1.1               ║${NC}"
echo -e "${CYAN}  ║  SSH 防暴力破解 + 多渠道攻击通知         ║${NC}"
echo -e "${CYAN}  ╚══════════════════════════════════════════╝${NC}"
echo ""

# ─── 前置检查 ───
[[ $EUID -ne 0 ]] && fail "请以 root 用户运行此脚本"
command -v python3 &>/dev/null || fail "需要 python3"
command -v curl &>/dev/null || fail "需要 curl"

# ═══════════════════════════════════════════════════════════
#  交互式配置
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

# ─── 2. 部署通知脚本（支持多渠道） ───
step "2/9 部署通知脚本"

BARK_KEY_INJECT=""
[[ "$USE_BARK" == "y" ]] && BARK_KEY_INJECT="${CFG_BARK_KEY}"
FEISHU_WEBHOOK_INJECT=""
[[ "$USE_FEISHU" == "y" ]] && FEISHU_WEBHOOK_INJECT="${CFG_FEISHU_WEBHOOK}"

cat > /usr/local/bin/ssh-shield-notify.sh << NOTIFICATION_SCRIPT
#!/bin/bash
BARK_KEY="${BARK_KEY_INJECT}"
BARK_URL="${BARK_API}/\${BARK_KEY}"
FEISHU_WEBHOOK="${FEISHU_WEBHOOK_INJECT}"

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
封禁时长: $(format_seconds $CFG_BAN_TIME)"
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
req = urllib.request.Request('\$FEISHU_WEBHOOK', data=json.dumps(card).encode(), headers={'Content-Type': 'application/json'})
urllib.request.urlopen(req)
" > /dev/null 2>&1
fi
NOTIFICATION_SCRIPT
chmod +x /usr/local/bin/ssh-shield-notify.sh
info "ssh-shield-notify.sh 已部署（Bark=$USE_BARK, 飞书=$USE_FEISHU）"

# ─── 兼容旧路径 ───
ln -sf /usr/local/bin/ssh-shield-notify.sh /usr/local/bin/bark-notify.sh 2>/dev/null || true

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
IGNORE_IP_LINE="127.0.0.1/8"
[[ -n "$CFG_TRUSTED_IP" ]] && IGNORE_IP_LINE="127.0.0.1/8 ${CFG_TRUSTED_IP}"

cat > /etc/fail2ban/jail.local << JAIL_CONF
[DEFAULT]
bantime = ${CFG_BAN_TIME}
findtime = ${CFG_FIND_TIME}
maxretry = ${CFG_MAX_RETRY}
ignoreip = ${IGNORE_IP_LINE}

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
info "防护规则已配置（${CFG_MAX_RETRY}次失败/$(format_seconds $CFG_FIND_TIME) → 封禁$(format_seconds $CFG_BAN_TIME)）"

# ─── 5. 生成 SSH 密钥 ───
step "5/9 生成 SSH 密钥"
if [[ -f "$SSH_KEY_PATH" ]]; then
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
    cat > /etc/ssh/sshd_config.d/49-hardening.conf << SSH_HARDENING
# SSH Shield - Security hardening
# Must load before 50-cloud-init.conf (sshd first-match-wins)
PasswordAuthentication no
PermitRootLogin prohibit-password
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

# ═══════════════════════════════════════════════════════════
#  部署结果
# ═══════════════════════════════════════════════════════════
echo ""
echo -e "${CYAN}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║              ${BOLD}SSH Shield 部署完成${NC}${CYAN}                         ║${NC}"
echo -e "${CYAN}╠══════════════════════════════════════════════════════╣${NC}"
echo -e "${CYAN}║${NC} SSH 密钥: ${GREEN}${SSH_KEY_PATH}${NC}"
CHANNELS=""
[[ "$USE_BARK" == "y" ]] && CHANNELS="Bark"
[[ "$USE_FEISHU" == "y" ]] && CHANNELS="${CHANNELS:+$CHANNELS + }飞书"
echo -e "${CYAN}║${NC} 通知渠道: ${GREEN}${CHANNELS}${NC}"
echo -e "${CYAN}║${NC} 服务器名: ${GREEN}${CFG_SERVER_NAME}${NC}"
echo -e "${CYAN}║${NC} 防护规则: ${GREEN}${CFG_MAX_RETRY}次失败/$(format_seconds $CFG_FIND_TIME) → 封禁$(format_seconds $CFG_BAN_TIME)${NC}"
echo -e "${CYAN}║${NC} 密码登录: ${RED}已禁用（仅密钥登录）${NC}"
echo -e "${CYAN}║${NC} UFW 防火墙: $([ "$CFG_ENABLE_UFW" == "y" ] && echo -e "${GREEN}已启用${NC}" || echo -e "${YELLOW}跳过${NC}")"
echo -e "${CYAN}║${NC} 重启生效: ${GREEN}所有配置持久化，重启后自动生效${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${YELLOW}⚠️  请立即保存以下私钥到本地，否则将无法登录！${NC}"
echo ""
cat "$SSH_KEY_PATH"
echo ""
echo -e "${YELLOW}使用方法:${NC}"
echo "  chmod 600 ~/ssh-shield-key"
echo "  ssh -i ~/ssh-shield-key root@<服务器IP>"
