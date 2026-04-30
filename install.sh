#!/bin/bash
#
# SSH Shield - 远程安装入口
# 用法: curl -sSL https://raw.githubusercontent.com/Harukite/ssh-shield/main/install.sh | sudo bash
#
set -euo pipefail

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

SCRIPT_URL="https://raw.githubusercontent.com/${GITHUB_REPO:-Harukite/ssh-shield}/main/ssh-shield.sh"

echo "下载 SSH Shield..."
curl -sSL "$SCRIPT_URL" -o "${TMPDIR}/ssh-shield.sh"
chmod +x "${TMPDIR}/ssh-shield.sh"

bash "${TMPDIR}/ssh-shield.sh"
