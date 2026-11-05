#!/usr/bin/env bash
#
# 一键把本地仓库推到 GitHub，并打 tag 触发 Actions 出 tipa
#
#   用法:
#     GH_TOKEN=ghp_xxx ./Scripts/push-to-github.sh            # 推到 <你的账号>/Xloc
#     GH_TOKEN=ghp_xxx ./Scripts/push-to-github.sh MyName     # 自定义仓库名
#     GH_TOKEN=ghp_xxx TAG=v0.1.0 ./Scripts/push-to-github.sh # 推完自动打 tag
#
# 需要的 token 权限（fine-grained）:
#   - Administration: Read and write   （创建仓库）
#   - Contents: Read and write         （推送代码 / tag）
#
# ⚠️ 用完请立刻在 GitHub 设置里撤销 token。
#
set -euo pipefail

: "${GH_TOKEN:?请设置 GH_TOKEN 环境变量}"
REPO="${1:-Xloc}"
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
TAG="${TAG:-}"

api() {
  curl -sS -H "Authorization: Bearer $GH_TOKEN" \
       -H "Accept: application/vnd.github+json" \
       -H "X-GitHub-Api-Version: 2022-11-28" "$@"
}

echo "==> 校验 token"
OWNER="$(api https://api.github.com/user | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("login",""))')"
if [ -z "$OWNER" ]; then
  echo "错误: token 无效或没有 user 权限" >&2
  exit 1
fi
echo "    账号: $OWNER"

echo "==> 检查仓库 $OWNER/$REPO"
CODE="$(api -o /dev/null -w '%{http_code}' "https://api.github.com/repos/$OWNER/$REPO")"
if [ "$CODE" = "404" ]; then
  echo "    不存在，创建中…"
  api -X POST https://api.github.com/user/repos \
      -d "{\"name\":\"$REPO\",\"private\":false,\"description\":\"Xloc — 开源 iOS 定位模拟工具\",\"has_issues\":true,\"has_wiki\":false}" \
      > /dev/null
  echo "    已创建（public）"
elif [ "$CODE" = "200" ]; then
  echo "    已存在，直接推送"
else
  echo "错误: 查询仓库返回 $CODE" >&2
  exit 1
fi

echo "==> 配置 remote"
if git remote get-url origin >/dev/null 2>&1; then
  git remote set-url origin "https://x-access-token:$GH_TOKEN@github.com/$OWNER/$REPO.git"
else
  git remote add origin "https://x-access-token:$GH_TOKEN@github.com/$OWNER/$REPO.git"
fi

echo "==> 推送 $BRANCH"
git push -u origin "$BRANCH"

if [ -n "$TAG" ]; then
  echo "==> 打 tag $TAG 并推送（触发 Release workflow）"
  git tag -f "$TAG" -m "Xloc ${TAG#v}"
  git push -f origin "$TAG"
  echo
  echo "构建进度: https://github.com/$OWNER/$REPO/actions"
  echo "发布页面: https://github.com/$OWNER/$REPO/releases/tag/$TAG"
fi

# 把 token 从 remote URL 里摘掉，避免留在 .git/config
git remote set-url origin "https://github.com/$OWNER/$REPO.git"

echo "==> 完成: https://github.com/$OWNER/$REPO"
