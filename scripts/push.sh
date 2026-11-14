#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 一条命令把 iOS 工程推到 GitHub，触发 Actions 编译。
#
#   用法：
#     ./scripts/push.sh https://github.com/<账号>/smartdash-ios.git
#     ./scripts/push.sh git@github.com:<账号>/smartdash-ios.git      # 配过 SSH key 时
#
# 前提：已在 GitHub 网页上建好空仓库（不要勾 README / .gitignore / license）。
# 作用：设置提交身份 → 绑定 origin → 提交改动 → 推 main → 打印 Actions 地址。
# ---------------------------------------------------------------------------
set -euo pipefail

REMOTE="${1:-}"
if [ -z "$REMOTE" ]; then
  echo "用法: $0 https://github.com/<账号>/smartdash-ios.git" >&2
  exit 1
fi

cd "$(dirname "$0")/.."

# 1) 提交身份：没有就用占位，避免 commit 失败（以后可改）
if [ -z "$(git config user.name || true)" ]; then
  git config user.name "SmartDash"
  echo "[git] 设置本地 user.name = SmartDash"
fi
if [ -z "$(git config user.email || true)" ]; then
  git config user.email "dev@smartdash.local"
  echo "[git] 设置本地 user.email = dev@smartdash.local"
fi

# 2) 分支固定为 main（工作流监听 main/master，两者都行，但统一更好）
CUR="$(git branch --show-current)"
if [ "$CUR" != "main" ]; then
  git branch -M main
  echo "[git] 当前分支 $CUR → main"
fi

# 3) 绑定远程：已存在则改成新地址
if git remote get-url origin >/dev/null 2>&1; then
  git remote set-url origin "$REMOTE"
  echo "[git] origin 已更新为 $REMOTE"
else
  git remote add origin "$REMOTE"
  echo "[git] origin = $REMOTE"
fi

# 4) 提交未落库的改动
if [ -n "$(git status --porcelain)" ]; then
  git add -A
  git commit -q -m "sync: $(date '+%Y-%m-%d %H:%M')"
  echo "[git] 已提交本地改动"
else
  echo "[git] 工作区干净，无需提交"
fi

# 5) 推送
echo "[git] 正在推送 main（首次会要求登录 GitHub）…"
git push -u origin main

# 6) 打印后续地址
SLUG="$(echo "$REMOTE" | sed -e 's#^git@github.com:#https://github.com/#' -e 's#\.git$##' -e 's#/$##')"
cat <<EOF

────────────────────────────────────────────────────────────
推送完成。接下来：

1. 打开 Actions：  $SLUG/actions
2. 等 iOS Build 跑完（2~3 分钟，绿勾）
3. 进这次运行页面 → 底部 Artifacts → 下载 SmartDash-unsigned-ipa.zip
4. 解压出 SmartDash-unsigned.ipa → 丢进 Sideloadly 签名装机

同步仓库改名（可选）：Settings → Rename，地址会自动重定向。
────────────────────────────────────────────────────────────
EOF
