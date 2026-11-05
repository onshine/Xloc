#!/usr/bin/env bash
#
# 把 .app 打包成 TrollStore 可安装的 .tipa
#
#   用法: ./Scripts/package.sh <Xloc.app> [输出.tipa] [--no-sign]
#
# 说明：
#   - 优先用 ldid 写入 entitlements（TrollStore 生态的标准做法）
#   - 没有 ldid 时回退到 codesign 的 ad-hoc 签名，效果等价
#   - --no-sign 只打包不签名，用于 CI 的"能否编译"检查
#
set -euo pipefail

SIGN=1
POSITIONAL=()
for arg in "$@"; do
  case "$arg" in
    --no-sign) SIGN=0 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) POSITIONAL+=("$arg") ;;
  esac
done

APP="${POSITIONAL[0]:-}"
OUT="${POSITIONAL[1]:-Xloc.tipa}"
ENT="${ENTITLEMENTS:-Xloc/Xloc.entitlements}"

if [ -z "$APP" ] || [ ! -d "$APP" ]; then
  echo "错误: 找不到 .app: '$APP'" >&2
  exit 1
fi
if [ ! -f "$APP/Info.plist" ]; then
  echo "错误: $APP 不是有效的 app bundle" >&2
  exit 1
fi

# 输出路径转成绝对路径（后面要在临时目录里 zip）
OUT_DIR="$(cd "$(dirname "$OUT")" 2>/dev/null && pwd || echo ".")"
OUT="$OUT_DIR/$(basename "$OUT")"

# 读取 Info.plist 的键（macOS 用 PlistBuddy，其他平台回退 python3）
plist_get() {
  local plist="$1" key="$2"
  if [ -x /usr/libexec/PlistBuddy ]; then
    /usr/libexec/PlistBuddy -c "Print :$key" "$plist" 2>/dev/null
  else
    python3 - "$plist" "$key" <<'PYEOF'
import plistlib, sys
try:
    d = plistlib.load(open(sys.argv[1], 'rb'))
    print(d.get(sys.argv[2], ''))
except Exception:
    print('')
PYEOF
  fi
}

BIN_NAME="$(plist_get "$APP/Info.plist" CFBundleExecutable)"
BIN="$APP/$BIN_NAME"

if [ -z "$BIN_NAME" ] || printf '%s' "$BIN_NAME" | grep -q '\$('; then
  echo "错误: Info.plist 里的 CFBundleExecutable 未解析（'$BIN_NAME'）" >&2
  echo "      请使用 Xcode 构建产物中的 .app，而不是源码目录里的 Info.plist" >&2
  exit 1
fi

echo "==> App:        $APP"
echo "==> Executable: $BIN_NAME"
echo "==> Output:     $OUT"
echo "==> Sign:       $([ "$SIGN" = 1 ] && echo yes || echo no)"

# ── 签名 ────────────────────────────────────────────────
sign_file() {
  local f="$1"
  if command -v ldid >/dev/null 2>&1; then
    ldid -S"$ENT" "$f"
  else
    codesign --force --sign - --timestamp=none --entitlements "$ENT" "$f" >/dev/null 2>&1 \
      || codesign --force --sign - --entitlements "$ENT" "$f"
  fi
}

if [ "$SIGN" = "1" ]; then
  if [ ! -f "$ENT" ]; then
    echo "错误: 找不到 entitlements: $ENT" >&2
    exit 1
  fi

  # 先签嵌套的可执行文件（framework / dylib / appex）
  if [ -d "$APP/Frameworks" ]; then
    while IFS= read -r f; do
      echo "    sign $(basename "$f")"
      sign_file "$f"
    done < <(find "$APP/Frameworks" -type f -perm -111 2>/dev/null)
  fi
  if [ -d "$APP/PlugIns" ]; then
    while IFS= read -r f; do
      echo "    sign $(basename "$f")"
      sign_file "$f"
    done < <(find "$APP/PlugIns" -type f -perm -111 2>/dev/null)
  fi

  echo "==> 签名主程序"
  sign_file "$BIN"

  # 校验 entitlements 真的进去了（这是最容易静默失败的一步）
  ENT_OUT="$(mktemp)"
  if command -v ldid >/dev/null 2>&1; then
    ldid -e "$BIN" > "$ENT_OUT" 2>/dev/null || true
  else
    codesign -d --entitlements :- "$BIN" > "$ENT_OUT" 2>/dev/null || true
  fi

  if grep -q "com.apple.locationd.simulation" "$ENT_OUT"; then
    echo "==> ✓ entitlements 已写入（含 locationd.simulation）"
  else
    echo "==> ✗ 警告: entitlements 里没有 locationd.simulation，安装后无法模拟定位" >&2
    echo "    请确认 $ENT 正确，且签名工具可用" >&2
    SIGN_FAIL=1
  fi
  rm -f "$ENT_OUT"
fi

# ── 打包 ────────────────────────────────────────────────
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/Payload"
cp -R "$APP" "$STAGE/Payload/"

rm -f "$OUT"
( cd "$STAGE" && zip -qry "$OUT" Payload )

# ── 校验和 ──────────────────────────────────────────────
(
  cd "$OUT_DIR"
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$(basename "$OUT")" > "$(basename "$OUT").sha256"
  else
    sha256sum "$(basename "$OUT")" > "$(basename "$OUT").sha256"
  fi
  cat "$(basename "$OUT").sha256"
)

SIZE="$(du -h "$OUT" | cut -f1)"
echo "==> 完成: $OUT ($SIZE)"

if [ "${SIGN_FAIL:-0}" = "1" ]; then
  exit 2
fi
