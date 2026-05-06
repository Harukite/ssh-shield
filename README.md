# SSH Shield

一键部署 SSH 防暴力破解 + 多渠道实时攻击通知。

## 功能

- fail2ban 自动封禁攻击 IP
- **多渠道通知** — Bark (iOS)、飞书 (Webhook)，可同时启用
- **SSH 登录方式** — 可选密钥认证（Ed25519）或密码认证
- SSH 安全加固（MaxAuthTries、LoginGraceTime、MaxStartups）
- UFW 防火墙（仅开放 SSH）
- **交互式配置** — 运行后逐步引导配置所有参数
- **重新配置** — 再次运行自动检测已有安装，进入修改菜单
- **运行状态** — 一键查看封禁记录、攻击日志、服务状态
- **干净卸载** — 一键移除所有组件，保留 fail2ban 和 SSH 密钥

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

## 命令行用法

```bash
sudo ./ssh-shield.sh              # 首次安装 或 重新配置
sudo ./ssh-shield.sh status       # 查看运行状态
sudo ./ssh-shield.sh uninstall    # 卸载 SSH Shield
sudo ./ssh-shield.sh help         # 显示帮助
```

## 交互式配置项

### 首次安装

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

▶ SSH 登录方式
  登录方式 (key/password) [key]: key
  key      = 密钥认证（生成 Ed25519 密钥，禁用密码登录，更安全）
  password = 密码认证（保留密码登录，不生成密钥）
```

### 重新配置

再次运行脚本时自动检测已有安装，进入修改菜单：

```
  ╔══════════════════════════════════════════╗
  ║     检测到 SSH Shield 已安装！           ║
  ╚══════════════════════════════════════════╝

  当前配置:
  ─────────────────────────────────────────
  通知渠道:     Bark ✓ | 飞书 ✓
  服务器名称:   我的生产服务器
  可信 IP:      1.2.3.4
  最大失败次数: 3 次
  封禁时长:     永久
  SSH 登录方式: 密钥认证
  ─────────────────────────────────────────

  请选择要修改的配置:
    1) Bark 通知设置
    2) 飞书通知设置
    3) 服务器名称
    4) 可信 IP 白名单
    5) fail2ban 防护参数
    6) UFW 防火墙
    7) SSH 登录方式
    ─────────────────────
    8) 查看运行状态
    9) 全部重新配置
   10) 卸载 SSH Shield
    0) 退出
```

## 部署流程

```
1. 安装 fail2ban
2. 部署多渠道通知脚本
3. 配置 fail2ban action
4. 配置 fail2ban 防护规则
5. 生成 Ed25519 SSH 密钥（密钥模式）
6. SSH 安全加固
7. 配置 UFW 防火墙
8. 启动 fail2ban
9. 发送部署完成通知
```

## 部署完成后

### 密钥模式

脚本会输出 SSH 私钥内容，请立即保存到本地：

```bash
chmod 600 ~/ssh-shield-key
ssh -i ~/ssh-shield-key root@<服务器IP>
```

### 密码模式

直接使用密码登录：

```bash
ssh root@<服务器IP>
```

## 查看运行状态

```bash
sudo ./ssh-shield.sh status
```

显示内容：
- fail2ban 服务状态
- SSH 防护规则（封禁 IP 列表）
- 最近封禁/解封记录
- 最近 SSH 登录失败记录
- SSH 安全配置
- UFW 防火墙状态

## 卸载

```bash
sudo ./ssh-shield.sh uninstall
```

移除内容：
- fail2ban SSH Shield 规则
- fail2ban 通知 action
- 通知脚本
- SSH 安全加固配置
- SSH Shield 配置文件

保留内容：
- fail2ban 服务（继续运行）
- SSH 密钥

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
