#!/usr/bin/env bash
# ============================================================
#  build.sh —— 通用构建 + 签名
#  用法: bash scripts/build.sh <ptype> <build_type> <module> <gradle_dir> <flavor>
#
#    ptype      : android | flutter | rn
#    build_type : debug | release
#    module     : Gradle 模块(如 :app);flutter 忽略
#    gradle_dir : 执行 gradlew 的目录(如 . 或 android)
#    flavor     : 可选,product flavor(如 prod);留空则不带
#
#  签名(release 生效,可选):
#    KEYSTORE_B64  签名库的 base64
#    KS_PASS       签名库口令
#    KEY_ALIAS     别名
#    KEY_PASS      别名口令
#
#  产物统一收集到 _out/
# ============================================================
set -euo pipefail

PTYPE="${1:?缺少 ptype}"
BUILD_TYPE="${2:-debug}"
MODULE="${3:-:app}"
GRADLE_DIR="${4:-.}"
FLAVOR="${5:-}"

OUT_DIR="$PWD/_out"
rm -rf "$OUT_DIR"; mkdir -p "$OUT_DIR"

# 首字母大写(用于 assemble<Flavor><Type> 任务名)
capitalize() { printf '%s' "$1" | sed 's/^\(.\)/\U\1/'; }

BT_CAP="$(capitalize "$BUILD_TYPE")"      # Debug / Release
FLAVOR_CAP=""
if [ -n "$FLAVOR" ]; then
  FLAVOR_CAP="$(capitalize "$FLAVOR")"
fi

# ------------------------------------------------------------
# 1. 准备签名
# ------------------------------------------------------------
KS_FILE=""
if [ "$BUILD_TYPE" = "release" ] && [ -n "${KEYSTORE_B64:-}" ]; then
  KS_FILE="$PWD/.ci-signing.jks"
  printf '%s' "$KEYSTORE_B64" | base64 -d > "$KS_FILE"
  echo "==> 已还原签名库($(du -h "$KS_FILE" | cut -f1))"
fi

GRADLE_SIGN_ARGS=()
if [ -n "$KS_FILE" ]; then
  # AGP 内置的"无侵入签名"属性：不改动项目里的 signingConfigs 即生效
  GRADLE_SIGN_ARGS=(
    "-Pandroid.injected.signing.store.file=$KS_FILE"
    "-Pandroid.injected.signing.store.password=${KS_PASS:-}"
    "-Pandroid.injected.signing.key.alias=${KEY_ALIAS:-}"
    "-Pandroid.injected.signing.key.password=${KEY_PASS:-}"
  )
fi

# gradlew 优先，缺失时回退到系统 gradle
run_gradle() {
  local dir="$1"; shift
  (
    cd "$dir"
    if [ -f ./gradlew ]; then
      chmod +x ./gradlew 2>/dev/null || true
      ./gradlew "$@"
    else
      gradle "$@"
    fi
  )
}

# ------------------------------------------------------------
# 2. 构建
# ------------------------------------------------------------
case "$PTYPE" in
  flutter)
    echo "==> Flutter 工程"
    if [ -n "$KS_FILE" ] && [ "$BUILD_TYPE" = "release" ] && [ -d android ]; then
      # Flutter 官方模板从 android/key.properties 读取签名
      cat > android/key.properties <<EOF
storeFile=$KS_FILE
storePassword=${KS_PASS:-}
keyAlias=${KEY_ALIAS:-}
keyPassword=${KEY_PASS:-}
EOF
      echo "    已写入 android/key.properties"
    fi
    FLUTTER_ARGS=(build apk "--$BUILD_TYPE")
    if [ -n "$FLAVOR" ]; then
      FLUTTER_ARGS+=(--flavor "$FLAVOR")
    fi
    flutter "${FLUTTER_ARGS[@]}"
    ;;

  android|rn)
    echo "==> $PTYPE 工程(模块 $MODULE,类型 $BUILD_TYPE${FLAVOR:+, flavor $FLAVOR})"
    TASK="${MODULE}:assemble${FLAVOR_CAP}${BT_CAP}"
    run_gradle "$GRADLE_DIR" "$TASK" \
      --no-daemon --stacktrace \
      -Dorg.gradle.jvmargs=-Xmx4g \
      -Dorg.gradle.vfs.watch=false \
      "${GRADLE_SIGN_ARGS[@]}"
    ;;

  *)
    echo "!! 无法识别的工程类型: $PTYPE"; exit 1 ;;
esac

# ------------------------------------------------------------
# 3. 收集产物
# ------------------------------------------------------------
echo "==> 收集 APK"
case "$PTYPE" in
  flutter) SEARCH_DIRS=("build/app/outputs/flutter-apk") ;;
  rn)      SEARCH_DIRS=("$GRADLE_DIR" "android") ;;
  *)       SEARCH_DIRS=("$GRADLE_DIR") ;;
esac

found=0
for d in "${SEARCH_DIRS[@]}"; do
  if [ -d "$d" ]; then
    while IFS= read -r f; do
      cp "$f" "$OUT_DIR/" && found=$((found + 1))
    done < <(find "$d" -type f -name '*.apk' ! -name '*-unsigned.apk' 2>/dev/null)
  fi
done

echo "---------------- 产物清单 ----------------"
ls -lh "$OUT_DIR" || true
if [ "$found" -eq 0 ]; then
  echo "!! 未找到任何 APK 产物"
  exit 1
fi
echo "共 $found 个 APK"
