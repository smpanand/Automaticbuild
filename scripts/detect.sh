#!/usr/bin/env bash
# ============================================================
#  detect.sh —— 工程指纹探测
#  用法: bash scripts/detect.sh <源码根目录>
#  输出(写入 $GITHUB_OUTPUT,本地执行则打印):
#    ptype          android | flutter | rn | unknown
#    has_wrapper    true | false        (是否存在 gradlew)
#    gradle_ver     Gradle 版本,如 8.5
#    agp_ver        AGP 版本,如 8.2.0
#    java           JDK 主版本,如 17
#    sdk_platform   compileSdk,如 34
#    module         Gradle 模块,如 :app
#    gradle_dir     执行 gradlew 的目录(. 或 android)
# ============================================================
set -euo pipefail

SRC="${1:-.}"
cd "$SRC"

OUT="${GITHUB_OUTPUT:-}"
out() {
  if [ -n "$OUT" ]; then printf '%s=%s\n' "$1" "$2" >> "$OUT"
  else printf '%-14s = %s\n' "$1" "$2" >&2; fi
}

# ------------------------------------------------------------
# 1. 工程类型
# ------------------------------------------------------------
ptype="unknown"
if [ -f pubspec.yaml ] && grep -q 'flutter:' pubspec.yaml 2>/dev/null; then
  ptype="flutter"
elif [ -f package.json ] && grep -q '"react-native"' package.json 2>/dev/null; then
  ptype="rn"
elif [ -f settings.gradle ] || [ -f settings.gradle.kts ] \
  || [ -f build.gradle ] || [ -f build.gradle.kts ]; then
  ptype="android"
fi

# ------------------------------------------------------------
# 2. gradle 执行目录 / wrapper
# ------------------------------------------------------------
gradle_dir="."
case "$ptype" in
  flutter|rn) [ -f android/gradlew ] && gradle_dir="android" ;;
  android)    [ ! -f gradlew ] && [ -f android/gradlew ] && gradle_dir="android" ;;
esac

has_wrapper="false"
[ -f "$gradle_dir/gradlew" ] && has_wrapper="true"

# ------------------------------------------------------------
# 3. Gradle 版本(从 wrapper properties)
# ------------------------------------------------------------
gradle_ver=""
for p in \
  "$gradle_dir/gradle/wrapper/gradle-wrapper.properties" \
  gradle/wrapper/gradle-wrapper.properties \
  android/gradle/wrapper/gradle-wrapper.properties ; do
  if [ -f "$p" ]; then
    gradle_ver="$(grep -oE 'gradle-[0-9]+\.[0-9]+(\.[0-9]+)?' "$p" 2>/dev/null \
      | head -1 | sed 's/gradle-//' || true)"
    [ -n "$gradle_ver" ] && break
  fi
done

# ------------------------------------------------------------
# 4. AGP 版本(两种写法都兼容)
#    - build.gradle:      classpath 'com.android.tools.build:gradle:8.2.0'
#    - settings.gradle:   id 'com.android.application' version '8.2.0'
# ------------------------------------------------------------
agp_ver=""
# 形式一：classpath 'com.android.tools.build:gradle:8.2.0'
agp_ver="$(grep -rhoE 'com\.android\.tools\.build:gradle:[0-9]+(\.[0-9]+)+' \
  --include='*.gradle' --include='*.gradle.kts' . 2>/dev/null \
  | grep -oE '[0-9]+(\.[0-9]+)+' | head -1 || true)"
# 形式二：id("com.android.application") version "9.2.0"（Kotlin DSL 常见写法）
if [ -z "$agp_ver" ]; then
  agp_ver="$(grep -rhE 'com\.android\.(application|library)' \
    --include='*.gradle' --include='*.gradle.kts' . 2>/dev/null \
    | grep -oE '[0-9]+(\.[0-9]+)+' | head -1 || true)"
fi

# ------------------------------------------------------------
# 5. JDK 决策
# ------------------------------------------------------------
java=17                                  # 缺省：当代 Android 工程的普遍选择
if [ -n "$gradle_ver" ]; then
  case "${gradle_ver%%.*}" in
    4|5|6|7)     java=11 ;;
    8)           java=17 ;;
    *)           java=21 ;;            # Gradle 9+ 通常需要 JDK 21
  esac
fi
if [ -n "$agp_ver" ]; then
  case "${agp_ver%%.*}" in
    2|3|4)       java=11 ;;            # 老 AGP 强制降级
    5|6|7)       [ "$java" -gt 11 ] && java=11 || true ;;
    8)           java=17 ;;
    *)           java=21 ;;            # AGP 9+
  esac
fi

# ------------------------------------------------------------
# 6. compileSdk / targetSdk
# ------------------------------------------------------------
sdk_platform="$(grep -rhoE 'compileSdk(Version)?[[:space:]]*[=:]?[[:space:]]*[0-9]+' \
  --include='build.gradle' --include='build.gradle.kts' . 2>/dev/null \
  | grep -oE '[0-9]+$' | sort -rn | head -1 || true)"
[ -z "$sdk_platform" ] && sdk_platform=34

# ------------------------------------------------------------
# 6.5 是否需要 NDK / 原生构建
# ------------------------------------------------------------
needs_ndk="false"
if grep -rqE 'ndkVersion|externalNativeBuild|CMakeLists|jniLibs|ndk[[:space:]]*\{' \
     --include='*.gradle' --include='*.gradle.kts' . 2>/dev/null; then
  needs_ndk="true"
fi
[ -d app/src/main/cpp ] && needs_ndk="true"
[ -d src/main/cpp ] && needs_ndk="true"

ndk_ver="$(grep -rhoE 'ndkVersion[^0-9]*[0-9]+(\.[0-9]+)+' \
  --include='*.gradle' --include='*.gradle.kts' . 2>/dev/null \
  | grep -oE '[0-9]+(\.[0-9]+)+' | head -1 || true)"

out needs_ndk   "$needs_ndk"
out ndk_ver     "$ndk_ver"

# ------------------------------------------------------------
# 7. 模块名
# ------------------------------------------------------------
module=":app"
if [ -f settings.gradle ] || [ -f settings.gradle.kts ]; then
  sf="settings.gradle"; [ -f settings.gradle.kts ] && sf="settings.gradle.kts"
  found="$(grep -oE "include[[:space:]]*\(?[[:space:]]*['\"]:[A-Za-z0-9_.-]+" "$sf" 2>/dev/null \
    | grep -oE "['\"]:?[A-Za-z0-9_.-]+" | tr -d "'\"" | head -1 || true)"
  [ -n "$found" ] && module=":${found#:}"
fi

# ------------------------------------------------------------
out ptype        "$ptype"
out has_wrapper  "$has_wrapper"
out gradle_ver   "$gradle_ver"
out agp_ver      "$agp_ver"
out java         "$java"
out sdk_platform "$sdk_platform"
out module       "$module"
out gradle_dir   "$gradle_dir"
