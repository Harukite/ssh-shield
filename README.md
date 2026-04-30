# SSH Shield

一键部署 SSH 防暴力破解 + Bark 实时攻击通知。

## 功能

- fail2ban 自动封禁（3次失败 → 封禁24小时）
- Bark 推送通知（攻击IP、端口、次数、时间）
- SSH 密钥认证（Ed25519），自动禁用密码登录
- SSH 安全加固（MaxAuthTries、LoginGraceTime、MaxStartups）
- UFW 防火墙（仅开放 SSH）

## 一键安装

```bash
curl -sSL https://raw.githubusercontent.com/Harukite/ssh-shield/main/install.sh | bash -s <你的Bark Key>
```

## 手动安装

```bash
git clone https://github.com/Harukite/ssh-shield.git
cd ssh-shield
chmod +x ssh-shield.sh
sudo ./ssh-shield.sh <你的Bark Key>
```

## 部署流程

```
1. 测试 Bark 通知连通性
2. 安装 fail2ban
3. 部署 Bark 通知脚本
4. 配置 fail2ban + Bark action
5. 配置 fail2ban SSH 防护规则
6. 生成 Ed25519 SSH 密钥
7. SSH 安全加固（禁用密码登录）
8. 配置 UFW 防火墙
9. 启动 fail2ban
10. 发送部署完成通知
```

## 部署完成后

脚本会输出 SSH 私钥内容，请立即保存到本地：

```bash
chmod 600 ~/ssh-shield-key
ssh -i ~/ssh-shield-key root@<服务器IP>
```

## 通知消息分类

| 类型 | 触发场景 |
|------|---------|
| 🚨 攻击封禁 | IP 被 fail2ban 封禁 |
| 🔓 IP 解封 | 封禁到期解封 |
| ⚠️ 安全告警 | 其他安全事件 |

## 系统要求

- Ubuntu 20.04+ / Debian 11+
- Root 权限
- python3、curl

## License

MIT
