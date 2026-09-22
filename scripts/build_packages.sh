#!/usr/bin/env bash
#
# TweakLang 统一打包入口
#
# 依据《越狱插件打包规范（官方原生 rootful / rootless / roothide）》：
#
#   rootful  -> make clean package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=
#   rootless -> make clean package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=rootless
#   roothide -> make clean package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=roothide
#
# THEOS 指向 roothide/theos 即可，同一份同时支持 rootless 与 roothide 两种 scheme
# （roothide scheme 由 vendor/mod/roothide 把 THEOS_PACKAGE_ARCH 固定为 iphoneos-arm64e，
#   rootless scheme 由 vendor/mod/rootless 固定为 iphoneos-arm64）。
#
# 每条产物线独立构建、独立验收，最终 .deb 收敛到 out/，命名
# <DisplayName>_<Version>_<Scheme>_<ShortArch>.deb。
#
# 本脚本不做规范第 9 节废弃的任何事情：不手工 lift rootless 包树成 roothide、
# 不改 DEBIAN/control 架构伪装产物线、不维护静态 Package_roothide 模板。
#
# macOS 注意：自带 /bin/bash 是 3.2，在 UTF-8 locale 下会把「$var 紧跟一个多字节字符」
# 里的首字节吞进变量名，导致 set -u 报 unbound variable。因此本脚本所有 $var 后紧跟
# 非 ASCII 字符的位置一律写成 ${var}，新增文案时也要保持这个写法。

set -euo pipefail

DISPLAY_NAME="TweakLang"

# 发布矩阵。默认 rootless + roothide（见 README「安装包」）。需要 rootful 时：
#   SCHEMES="rootful rootless roothide" ./scripts/build_packages.sh
SCHEMES="${SCHEMES:-rootless roothide}"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out_dir="$repo_root/out"

# 本地构建环境 workaround，不是发布规范的一部分（规范 §8.2）：
# 本机 clang 模块缓存默认目录不可写，显式指到 /tmp。
MODULE_CACHE_FLAG="-fmodules-cache-path=/tmp/clang-module-cache"

die() {
    echo "error: $*" >&2
    exit 1
}

scheme_short_arch() {
    case "$1" in
        rootful)  echo "arm" ;;
        rootless) echo "arm64" ;;
        roothide) echo "arm64e" ;;
        *) die "未知 scheme：$1" ;;
    esac
}

scheme_expected_arch() {
    case "$1" in
        rootful)  echo "iphoneos-arm" ;;
        rootless) echo "iphoneos-arm64" ;;
        roothide) echo "iphoneos-arm64e" ;;
        *) die "未知 scheme：$1" ;;
    esac
}

# 规范 §6.2：rootful 是 Theos 的默认 scheme，必须显式传**空值**。
# 上游/roothide theos 的 vendor/mod/ 下只有 roothide 与 rootless，传字面量 "rootful" 会让
# common.mk:134 直接报 'rootful' package scheme does not exist 并 Stop.
scheme_make_value() {
    if [ "$1" = "rootful" ]; then
        echo ""
    else
        echo "$1"
    fi
}

# 规范 §10.5：宿主系统元数据不得进入最终包。
clean_host_metadata() {
    local target_path
    for target_path in "$@"; do
        [ -e "$target_path" ] || continue
        find "$target_path" -type f \( -name '.DS_Store' -o -name '._*' \) -exec rm -f {} +
        find "$target_path" -name '__MACOSX' -type d -prune -exec rm -rf {} +
    done
}

# 规范 §11.3：保留目录本身，只清空内容，避免 rm -rf 整个目录时的
# "Directory not empty" 竞态；带短重试。
clear_dir_with_retry() {
    local dir="$1" attempt
    [ -e "$dir" ] || return 0
    for attempt in 1 2 3; do
        find "$dir" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
        if [ -z "$(ls -A "$dir" 2>/dev/null || true)" ]; then
            return 0
        fi
        sleep 1
    done
    die "无法清空目录 $dir"
}

# 规范 §11.3：同一项目同一时间只允许一个正式打包流程。
# BUILD_LOCK_DIR 必须是全局变量，否则 trap 里拿不到。
BUILD_LOCK_DIR=""

release_build_lock() {
    if [ -n "$BUILD_LOCK_DIR" ]; then
        rm -rf "$BUILD_LOCK_DIR" 2>/dev/null || true
    fi
    return 0
}

acquire_build_lock() {
    local holder
    BUILD_LOCK_DIR="${TMPDIR:-/tmp}/$(basename "$repo_root").build.lock"
    while ! mkdir "$BUILD_LOCK_DIR" 2>/dev/null; do
        holder=""
        if [ -f "$BUILD_LOCK_DIR/pid" ]; then
            holder="$(cat "$BUILD_LOCK_DIR/pid" 2>/dev/null || true)"
        fi
        if [ -n "$holder" ] && ! kill -0 "$holder" 2>/dev/null; then
            echo "==> 清理陈旧构建锁 (pid $holder)"
            rm -rf "$BUILD_LOCK_DIR"
            continue
        fi
        echo "==> 等待其他打包流程释放构建锁..."
        sleep 2
    done
    echo "$$" > "$BUILD_LOCK_DIR/pid"
    trap release_build_lock EXIT
}

# 单个 deb 的验收。规范 §10.1–10.3 + §10.5，外加一条本项目自己的权限断言。
verify_deb() {
    local deb="$1" scheme="$2"
    local expected_arch pkg version arch unpack top
    expected_arch="$(scheme_expected_arch "$scheme")"

    pkg="$(dpkg-deb -f "$deb" Package)"
    version="$(dpkg-deb -f "$deb" Version)"
    arch="$(dpkg-deb -f "$deb" Architecture)"
    [ -n "$pkg" ] && [ -n "$version" ] && [ -n "$arch" ] || die "$deb 包头字段读取失败"

    if [ "$arch" != "$expected_arch" ]; then
        die "$deb 架构为 ${arch}，${scheme} 线要求 ${expected_arch}"
    fi

    unpack="$(mktemp -d)"
    dpkg-deb -R "$deb" "$unpack"

    # 发现宿主元数据就净化并重打包，保持包内 root 权属
    if [ -n "$(find "$unpack" \( -name '.DS_Store' -o -name '._*' -o -name __MACOSX \) \
              -print -quit 2>/dev/null)" ]; then
        echo "==> 发现宿主元数据，净化后重打包"
        clean_host_metadata "$unpack"
        dpkg-deb -b --root-owner-group "$unpack" "$deb"
        rm -rf "$unpack"
        dpkg-deb -R "$deb" "$unpack"
    fi
    if [ -n "$(find "$unpack" \( -name '.DS_Store' -o -name '._*' -o -name __MACOSX \) \
              -print -quit 2>/dev/null)" ]; then
        rm -rf "$unpack"
        die "$deb 仍含宿主元数据"
    fi

    # 权限断言（本项目自加，不属于规范现有条目）。
    #
    # 教训来源：源码树里 layout/ 与 tweaklangprefs/Resources/ 曾是 700/600，theos 原样
    # 拷进包，导致 root/wheel 700 的 bundle 目录——而 Settings.app 以 mobile 用户运行，
    # 连目录都穿越不了。症状是「文件在设备上、dpkg 不报错、注销无效、但设置里没有条目」，
    # 极难定位。所以这里强制要求：目录 o+rx、文件 o+r。
    local perm_bad
    perm_bad="$(dpkg-deb -c "$deb" | awk '
        $1 ~ /^d/ { p = substr($1, 8, 3); if (p !~ /r/ || p !~ /x/) print "DIR  " $1 " " $6 }
        $1 ~ /^-/ { p = substr($1, 8, 3); if (p !~ /r/)            print "FILE " $1 " " $6 }
    ')"
    if [ -n "$perm_bad" ]; then
        echo "$perm_bad" >&2
        rm -rf "$unpack"
        die "$deb 存在 mobile 用户不可读的条目（目录需 o+rx，文件需 o+r）"
    fi

    top="$(ls -1 "$unpack" | grep -v '^DEBIAN$' || true)"

    if [ "$scheme" = "rootless" ]; then
        [ -d "$unpack/var/jb" ] || { rm -rf "$unpack"; die "rootless 包安装根不是 var/jb"; }
    else
        if [ -d "$unpack/var" ]; then
            rm -rf "$unpack"
            die "${scheme} 包中出现了 var/ 安装根，与 ${scheme} 语义冲突"
        fi
        case " $top " in
            *" Library "*|*" Applications "*|*" usr "*)
                ;;
            *)
                rm -rf "$unpack"
                die "${scheme} 包安装根不是 Library/Applications/usr（实际：${top}）"
                ;;
        esac
        if [ "$scheme" = "rootful" ]; then
            if [ -n "$(find "$unpack" \( -name '.jbroot' -o -name 'libroothide*' \) \
                      -print -quit 2>/dev/null)" ]; then
                rm -rf "$unpack"
                die "rootful 包中出现了 .jbroot/libroothide 运行基线"
            fi
        fi
    fi

    echo "==> 验收通过：${pkg} ${version} ${arch}（安装根：${top}；权限与清洁性 OK）"
    rm -rf "$unpack"
}

main() {
    [ -d "${THEOS:-/opt/theos}" ] || die "找不到 theos：${THEOS:-/opt/theos}"
    THEOS="${THEOS:-/opt/theos}"

    command -v dpkg-deb >/dev/null 2>&1 || die "缺少 dpkg-deb"

    # rootful 的 scheme 传值已经按规范 §6.2 做成空值，但本项目当前仍不能产出合规 rootful 包：
    # vendor/mod/ 下没有 rootful 模块，THEOS_PACKAGE_ARCH 不会被改成 iphoneos-arm，
    # 而 control 声明的是 iphoneos-arm64、Makefile 是 ARCHS = arm64 arm64e，
    # 空 scheme 构建出的 deb 架构仍是 iphoneos-arm64，不符合规范 §10.1。
    # 启用 rootful 需要先改 control 与 Makefile，不在本 change 范围内，因此在这里明确拦下。
    local scheme
    for scheme in $SCHEMES; do
        if [ "$scheme" = "rootful" ]; then
            die "rootful 线当前不可用：需先把 control 的 Architecture 改为 iphoneos-arm 并调整 Makefile 的 ARCHS；这超出本 change 范围，故默认不启用"
        fi
    done

    acquire_build_lock

    local short_arch expected_arch package_dir built candidate deb_count
    local version target final_version final_arch

    for scheme in $SCHEMES; do
        short_arch="$(scheme_short_arch "$scheme")"
        expected_arch="$(scheme_expected_arch "$scheme")"
        package_dir="$repo_root/packages/$scheme"

        echo "==> [$scheme] 清理产物目录 $package_dir"
        mkdir -p "$package_dir"
        clear_dir_with_retry "$package_dir"

        echo "==> [$scheme] 构建"
        # scheme 在每条命令上显式指定，不继承 shell 环境（规范 §6.1）；
        # rootful 走 scheme_make_value 转成空值（规范 §6.2）
        make -C "$repo_root" clean package FINALPACKAGE=1 \
            THEOS="$THEOS" \
            THEOS_PACKAGE_DIR="$package_dir" \
            THEOS_PACKAGE_SCHEME="$(scheme_make_value "$scheme")" \
            ADDITIONAL_CFLAGS="$MODULE_CACHE_FLAG"

        # 产物目录已清空，本次构建必须恰好产出一个 .deb；
        # 不用 find | head -n 1 之类的方式挑包（规范 §11.2）
        deb_count=0
        built=""
        for candidate in "$package_dir"/*.deb; do
            [ -e "$candidate" ] || continue
            built="$candidate"
            deb_count=$((deb_count + 1))
        done
        [ "$deb_count" -eq 1 ] || die "$package_dir 中找到 $deb_count 个 .deb，预期 1 个"

        verify_deb "$built" "$scheme"

        version="$(dpkg-deb -f "$built" Version)"
        target="$out_dir/${DISPLAY_NAME}_${version}_${scheme}_${short_arch}.deb"

        mkdir -p "$out_dir"
        cp -f "$built" "$target"

        # 复核 out/ 里的最终产物，文件名与包头必须一致（规范 §11.1 第 7 条）
        final_version="$(dpkg-deb -f "$target" Version)"
        final_arch="$(dpkg-deb -f "$target" Architecture)"
        [ "$final_version" = "$version" ] || die "out/ 版本号 ${final_version} 与构建产物 ${version} 不一致"
        [ "$final_arch" = "$expected_arch" ] || die "out/ 架构 ${final_arch} 与 ${scheme} 线要求的 ${expected_arch} 不一致"

        echo "==> [$scheme] 已输出 out/$(basename "$target")"
    done

    echo
    echo "==> Done"
    echo "out/ 产物："
    ls -1 "$out_dir"/*.deb 2>/dev/null || true
}

main "$@"
