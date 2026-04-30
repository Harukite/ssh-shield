#!/bin/bash
#
# SSH Shield - 一键部署 SSH 防暴力破解 + Bark 攻击通知
# 用法: ./ssh-shield.sh <bark_key>
#
set -euo pipefail

BARK_KEY="${1:?用法: $0 <bark_key>}"
BARK_API="https://api.day.app"
SSH_KEY_PATH="/root/.ssh/id_ed25519"
HOSTNAME=$(hostname)
TRUSTED_IP=""

# ─── 颜色输出 ───
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
fail()  { echo -e "${RED}[✗]${NC} $1"; exit 1; }
step()  { echo -e "\n${CYAN}━━━ $1 ━━━${NC}"; }

# ─── 前置检查 ───
step "前置检查"
[[ $EUID -ne 0 ]] && fail "请以 root 用户运行此脚本"
command -v python3 &>/dev/null || fail "需要 python3"
info "root 权限 ✓"

# ─── 询问信任 IP ───
echo ""
read -rp "输入你的可信 IP（留空则不设置白名单）: " TRUSTED_IP

# ─── 1. 测试 Bark 通知 ───
step "测试 Bark 通知"
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "${BARK_API}/${BARK_KEY}/部署开始/SSH-Shield正在部署")
[[ "$HTTP_CODE" == "200" ]] || fail "Bark 通知测试失败 (HTTP ${HTTP_CODE})，请检查 Key 是否正确"
info "Bark 通知可达 ✓"

# ─── 2. 安装 fail2ban ───
step "安装 fail2ban"
if command -v fail2ban-client &>/dev/null; then
    info "fail2ban 已安装，跳过"
else
    apt-get update -qq
    apt-get install -y -qq fail2ban
    info "fail2ban 安装完成 ✓"
fi
systemctl enable fail2ban

# ─── 3. 部署 Bark 通知脚本 ───
step "部署 Bark 通知脚本"
cat > /usr/local/bin/bark-notify.sh << NOTIFICATION_SCRIPT
#!/bin/bash
BARK_KEY="${BARK_KEY}"
BARK_URL="${BARK_API}/\${BARK_KEY}"

ACTION="\$1"
IP="\$2"
PORT="\$3"
ATTEMPTS="\$4"
JAIL="\$5"
HOSTNAME=$(hostname)
DATETIME=\$(date '+%Y-%m-%d %H:%M:%S %Z')

case "\$ACTION" in
  ban)
    TITLE="🚨 SSH攻击封禁 [\${HOSTNAME}]"
    BODY="攻击IP: \${IP}
攻击端口: \${PORT}
尝试次数: \${ATTEMPTS}
触发规则: \${JAIL}
封禁时间: \${DATETIME}
封禁时长: 24小时"
    ;;
  unban)
    TITLE="🔓 IP解封通知 [\${HOSTNAME}]"
    BODY="解封IP: \${IP}
触发规则: \${JAIL}
解封时间: \${DATETIME}"
    ;;
  *)
    TITLE="⚠️ 安全告警 [\${HOSTNAME}]"
    BODY="时间: \${DATETIME}
详情: \${ACTION}"
    ;;
esac

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
NOTIFICATION_SCRIPT
chmod +x /usr/local/bin/bark-notify.sh
info "bark-notify.sh 已部署 ✓"

# ─── 4. 配置 fail2ban Bark action ───
step "配置 fail2ban Bark action"
cat > /etc/fail2ban/action.d/bark.conf << 'FAIL2BAN_ACTION'
[Definition]
actionstart = /usr/local/bin/bark-notify.sh "fail2ban已启动，监控规则: <name>" "" "" "" "<name>"
actionstop = /usr/local/bin/bark-notify.sh "fail2ban已停止，规则: <name>" "" "" "" "<name>"
actioncheck =
actionban = /usr/local/bin/bark-notify.sh "ban" "<ip>" "<port>" "<failures>" "<name>"
actionunban = /usr/local/bin/bark-notify.sh "unban" "<ip>" "<port>" "" "<name>"

[Init]
port = ssh
FAIL2BAN_ACTION
info "fail2ban bark action 已配置 ✓"

# ─── 5. 配置 fail2ban jail ───
step "配置 fail2ban SSH 防护规则"
IGNORE_IP_LINE="127.0.0.1/8"
[[ -n "$TRUSTED_IP" ]] && IGNORE_IP_LINE="127.0.0.1/8 ${TRUSTED_IP}"

cat > /etc/fail2ban/jail.local << JAIL_CONF
[DEFAULT]
bantime = 86400
findtime = 600
maxretry = 3
ignoreip = ${IGNORE_IP_LINE}

[sshd]
enabled = true
port = ssh
logpath = %(sshd_log)s
backend = %(sshd_backend)s
maxretry = 3
bantime = 86400
action = %(action_)s
         bark
JAIL_CONF
info "fail2ban jail 已配置（3次失败封禁24h）✓"

# ─── 6. 生成 SSH 密钥 ───
step "生成 SSH 密钥"
if [[ -f "$SSH_KEY_PATH" ]]; then
    warn "SSH 密钥已存在，跳过生成"
else
    ssh-keygen -t ed25519 -f "$SSH_KEY_PATH" -N "" -C "root@${HOSTNAME}" -q
    cat "${SSH_KEY_PATH}.pub" >> /root/.ssh/authorized_keys
    chmod 600 /root/.ssh/authorized_keys
    info "Ed25519 密钥对已生成 ✓"
fi

# ─── 7. SSH 加固 ───
step "SSH 安全加固"
if [[ -f /etc/ssh/sshd_config.d/49-hardening.conf ]]; then
    warn "SSH 加固配置已存在，跳过"
else
    cat > /etc/ssh/sshd_config.d/49-hardening.conf << SSH_HARDENING
# SSH Shield - Security hardening
# Must load before 50-cloud-init.conf (sshd first-match-wins)
PasswordAuthentication no
PermitRootLogin prohibit-password
MaxAuthTries 3
LoginGraceTime 30s
MaxStartups 5:30:10
X11Forwarding no
SSH_HARDENING
    info "SSH 加固配置已写入 ✓"
fi

sshd -t || fail "SSH 配置语法错误"
systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
info "SSH 服务已重载 ✓"

# ─── 8. 配置 UFW 防火墙 ───
step "配置 UFW 防火墙"
if command -v ufw &>/dev/null; then
    ufw status | grep -q "active" && warn "UFW 已启用，跳过" || {
        ufw allow 22/tcp
        ufw --force enable
        info "UFW 防火墙已启用（仅开放 SSH 22）✓"
    }
else
    warn "UFW 未安装，跳过防火墙配置"
fi

# ─── 9. 重启 fail2ban ───
step "启动 fail2ban"
systemctl restart fail2ban
sleep 2
fail2ban-client status sshd 2>/dev/null | head -5
info "fail2ban 运行中 ✓"

# ─── 10. 发送部署完成通知 ───
curl -s -o /dev/null "${BARK_API}/${BARK_KEY}/✅部署完成/SSH-Shield已成功部署到${HOSTNAME}" || true

# ─── 输出结果 ───
echo ""
echo -e "${CYAN}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║              SSH Shield 部署完成                    ║${NC}"
echo -e "${CYAN}╠══════════════════════════════════════════════════════╣${NC}"
echo -e "${CYAN}║${NC} SSH 密钥: ${GREEN}${SSH_KEY_PATH}${NC}"
echo -e "${CYAN}║${NC} 公   钥: ${GREEN}${SSH_KEY_PATH}.pub${NC}"
echo -e "${CYAN}║${NC} 通知 Key: ${GREEN}${BARK_KEY}${NC}"
echo -e "${CYAN}║${NC} fail2ban: ${GREEN}3次失败封禁24h${NC}"
echo -e "${CYAN}║${NC} 密码登录: ${RED}已禁用${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${YELLOW}⚠️  请立即保存私钥到本地:${NC}"
echo ""
cat "$SSH_KEY_PATH"
echo ""
echo -e "${YELLOW}使用方法:${NC}"
echo "  chmod 600 ~/your-key-file"
echo "  ssh -i ~/your-key-file root@<服务器IP>"
