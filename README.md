# SSH Shield

一键部署 SSH 防暴力破解 + 多渠道实时攻击通知。

## 功能

- fail2ban 自动封禁攻击 IP
- **多渠道通知** — Bark (iOS)、飞书 (Webhook)，可同时启用
- SSH 密钥认证（Ed25519），自动禁用密码登录
- SSH 安全加固（MaxAuthTries、LoginGraceTime、MaxStartups）
- UFW 防火墙（仅开放 SSH）
- **交互式配置** — 运行后逐步引导配置所有参数

## 一键安装

```bash
curl -sSL https://raw.githubusercontent.com/Harukite/ssh-shield/main/install.sh | sudo bash
```

## 手动安装

```bash
git clone https://github.com/Harukite/ssh-shield.git
cd ssh-shield
chmod +x ssh-shield.sh
sudo ./ssh-shield.sh
```

## 交互式配置项

运行后会逐步引导配置：

```
▶ Bark 通知（iOS 推送）
  启用 Bark 通知？ [Y/n]: y
  Bark Key（从 Bark App 获取）: xxxxxx

▶ 飞书通知（Webhook 机器人）
  启用飞书通知？ [y/N]: y
  飞书 Webhook URL: https://open.feishu.cn/open-apis/bot/v2/hook/xxx

▶ 通用配置
  通知标题中的服务器名称 [vmi3104264]: 我的生产服务器
  可信 IP 白名单（留空跳过）: 1.2.3.4

▶ fail2ban 防护参数
  最大失败次数 (maxretry) [3]: 3
  检测时间/秒 (findtime) [600]: 600
  封禁时长/秒 (bantime) [86400]: -1   ← -1 为永久封禁

▶ UFW 防火墙
  启用 UFW 防火墙 [Y/n]: y
```

## 部署流程

```
1. 安装 fail2ban
2. 部署 Bark 通知脚本
3. 配置 fail2ban Bark action
4. 配置 fail2ban 防护规则
5. 生成 Ed25519 SSH 密钥
6. SSH 安全加固（禁用密码登录）
7. 配置 UFW 防火墙
8. 启动 fail2ban
9. 发送部署完成通知
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

### 支持的通知渠道

| 渠道 | 说明 |
|------|------|
| [Bark](https://github.com/Finb/Bark) | iOS 推送通知 |
| 飞书 Webhook | 群机器人卡片消息 |

## 系统要求

- Ubuntu 20.04+ / Debian 11+
- Root 权限
- python3、curl

## License

MIT
