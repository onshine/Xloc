#!/usr/bin/env bash
# 把 .app 打包成 TrollStore 可安装的 .tipa
# 用法: ./Scripts/package.sh <Xloc.app> <输出.tipa>
set -euo pipefail

APP="${1:?usage: package.sh <Xloc.app> <out.tipa>}"
OUT="${2:-Xloc.tipa}"
ENT="${ENTITLEMENTS:-Xloc/Xloc.entitlements}"

if ! command -v ldid >/dev/null 2>&1; then
  echo "缺少 ldid，请先: brew install ldid-procursus (或下载 ldid 二进制)" >&2
  exit 1
fi

echo "==> 签名 $APP"
# 递归签名：先签内部的 framework/dylib/appex，再签主程序
find "$APP" -type f \( -name "*.dylib" -o -name "*.framework" -o -perm -111 \) 2>/dev/null | while read -r f; do
  case "$f" in
    *.framework) continue ;;
    *) ldid -S"$ENT" "$f" 2>/dev/null || true ;;
  esac
done
ldid -S"$ENT" "$APP/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Info.plist")"

WORK="$(mktemp -d)"
mkdir -p "$WORK/Payload"
cp -R "$APP" "$WORK/Payload/"
( cd "$WORK" && zip -qry "$OUT" Payload )
mv "$WORK/$OUT" "$OUT" 2>/dev/null || true
rm -rf "$WORK"

echo "==> 完成: $OUT ($(du -h "$OUT" | cut -f1))"
echo "    用 TrollStore 打开安装即可"
