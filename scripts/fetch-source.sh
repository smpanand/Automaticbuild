#!/usr/bin/env bash
# ============================================================
#  fetch-source.sh —— 获取待构建的源码
#  用法: bash scripts/fetch-source.sh <type> <url> <ref> <dest>
#
#    type = repo   : url 为 git 仓库地址(公开仓库无需 token)
#    type = asset  : url 为压缩包直链(Release asset / 对象存储签名 URL)
#
#  可选环境变量:
#    GH_TOKEN      : 私有仓库 clone / 私有 asset 下载用
# ============================================================
set -euo pipefail

TYPE="${1:?缺少 type(repo|asset)}"
URL="${2:?缺少 url}"
REF="${3:-}"
DEST="${4:?缺少 dest}"

rm -rf "$DEST"
mkdir -p "$DEST"

# 用 token 时给 https 地址注入凭据(不落盘到 git config)
auth_url() {
  local u="$1"
  if [ -n "${GH_TOKEN:-}" ]; then
    if [[ "$u" == https://github.com/* ]]; then
      printf '%s' "https://x-access-token:${GH_TOKEN}@${u#https://}"
      return
    fi
  fi
  printf '%s' "$u"
}

case "$TYPE" in
  repo)
    echo "==> git clone ($URL ${REF:+@ $REF})"
    ok=0

    # 1) 优先按指定 ref 克隆
    if [ -n "$REF" ]; then
      n=0
      while [ "$n" -lt 2 ]; do
        if git clone --depth 1 --branch "$REF" "$(auth_url "$URL")" "$DEST/.clone" >/dev/null 2>&1; then
          ok=1; break
        fi
        n=$((n+1)); rm -rf "$DEST/.clone"; sleep 3
      done
      if [ "$ok" -eq 0 ]; then
        echo "   ⚠ 分支/标签 '$REF' 克隆失败，改用仓库默认分支"
      fi
    fi

    # 2) 回退：克隆默认分支（ref 写错 / 默认分支不是 main 的情况）
    if [ "$ok" -eq 0 ]; then
      n=0
      while [ "$n" -lt 3 ]; do
        if git clone --depth 1 "$(auth_url "$URL")" "$DEST/.clone" >/dev/null 2>&1; then
          ok=1; break
        fi
        n=$((n+1))
        echo "   clone 第 $n 次失败，5s 后重试…"
        rm -rf "$DEST/.clone"; sleep 5
      done
    fi

    if [ "$ok" -eq 0 ]; then
      echo "!! clone 失败（已重试）: $URL"
      exit 1
    fi
    echo "   已获取分支: $(git -C "$DEST/.clone" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"

    # 3) ref 是 commit SHA 时，补一次精确 checkout
    if [ -n "$REF" ]; then
      ( cd "$DEST/.clone" \
        && git fetch --depth 1 origin "$REF" >/dev/null 2>&1 \
        && git checkout -q FETCH_HEAD >/dev/null 2>&1 ) || true
    fi
    # 去掉 .git 减小体积
    rm -rf "$DEST/.clone/.git"
    mv "$DEST/.clone/"* "$DEST/.clone/".[!.]* "$DEST/" 2>/dev/null || true
    rmdir "$DEST/.clone" 2>/dev/null || true
    ;;

  asset)
    echo "==> 下载压缩包 ($URL)"
    ARCHIVE="$DEST/.archive"
    n=0
    until curl -fL --connect-timeout 20 --retry 3 --retry-delay 5 \
            ${GH_TOKEN:+-H "Authorization: Bearer $GH_TOKEN"} \
            -o "$ARCHIVE" "$URL"; do
      n=$((n+1))
      [ "$n" -ge 3 ] && { echo "!! 下载失败(已重试 $n 次)"; exit 1; }
      echo "   下载第 $n 次失败，5s 后重试…"; sleep 5
    done
    echo "    压缩包大小: $(du -h "$ARCHIVE" | cut -f1)"
    rm -rf "$DEST/.unpack"; mkdir -p "$DEST/.unpack"
    case "$URL" in
      *.tar.gz|*.tgz) tar -xzf "$ARCHIVE" -C "$DEST/.unpack" ;;
      *.tar)          tar -xf  "$ARCHIVE" -C "$DEST/.unpack" ;;
      *)              unzip -q "$ARCHIVE" -d "$DEST/.unpack" ;;
    esac
    rm -f "$ARCHIVE"
    # 若解压后只有一个顶层目录，则提升一层（适配 GitHub 的 repo-main 风格打包）
    entries=$(find "$DEST/.unpack" -mindepth 1 -maxdepth 1 | wc -l)
    if [ "$entries" -eq 1 ] && [ -d "$(find "$DEST/.unpack" -mindepth 1 -maxdepth 1)" ]; then
      inner="$(find "$DEST/.unpack" -mindepth 1 -maxdepth 1)"
      mv "$inner"/* "$inner/".[!.]* "$DEST/" 2>/dev/null || true
      rm -rf "$DEST/.unpack"
    else
      mv "$DEST/.unpack/"* "$DEST/.unpack/".[!.]* "$DEST/" 2>/dev/null || true
      rmdir "$DEST/.unpack" 2>/dev/null || true
    fi
    ;;

  *)
    echo "!! 未知 type: $TYPE(应为 repo 或 asset)"; exit 1 ;;
esac

echo "==> 源码就绪，顶层内容:"
ls -A "$DEST" | head -30
