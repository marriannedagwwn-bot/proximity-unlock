#!/bin/bash
# 编译 Mac 电脑端并打包成 MacPeer.app，最后一行输出 App 的路径。
#
# 为什么要打包成 App：macOS 的蓝牙权限按"负责的进程"查 Info.plist 里的用途说明，
# 从没有这项说明的程序（比如 Claude Code）里直接跑命令行程序会被系统结束。
# 产物放在仓库以外：仓库在开着 iCloud 同步的文件夹（比如桌面）里时，签名会报 "resource fork, Finder information,
# or similar detritus not allowed"，编译产物也会被同步上去。
#
# 签名：系统按签名要求认辅助功能、发送系统事件、蓝牙和钥匙串的授权。用固定的签名身份时签名要求是
# 「这个标识 + 这张证书」，重新打包也不变，并且开 hardened runtime 挡住动态库注入；临时签名的签名要求是
# 程序的哈希，每次重签都要重新授权。签名身份写在 signing.local 里（不进仓库），见 README.md「签名」。
set -euo pipefail
cd "$(dirname "$0")"
OUT="${MAC_PEER_BUILD_DIR:-$HOME/Library/Caches/proximity-unlock}"
APP="$OUT/MacPeer.app"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" Info.plist)"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

# 签名身份：环境变量 MAC_PEER_SIGN_IDENTITY（证书的 SHA-1 或全名，"-" 表示临时签名），
# 没有就读 signing.local：先找这份代码旁边的，再找主仓库的（在 worktree 里编译也用同一个身份）
if [ -z "${MAC_PEER_SIGN_IDENTITY:-}" ]; then
    MAIN_GIT="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
    for f in ./signing.local "${MAIN_GIT:+$(dirname "$MAIN_GIT")/prototype/mac_peer/signing.local}"; do
        if [ -n "$f" ] && [ -f "$f" ]; then . "$f"; break; fi
    done
fi
IDENTITY="${MAC_PEER_SIGN_IDENTITY:-}"
[ "$IDENTITY" != "-" ] || IDENTITY=""
SHA1=""
if [ -n "$IDENTITY" ]; then
    if [[ "$IDENTITY" =~ ^[0-9A-Fa-f]{40}$ ]]; then
        SHA1="$(echo "$IDENTITY" | tr '[:lower:]' '[:upper:]')"
    else
        # 按全名找，要正好一张（证书续过以后可能有两张同名的，那就写 SHA-1）
        SHA1="$(security find-identity -p codesigning | awk -v name="\"$IDENTITY\"" '
            $1 ~ /^[0-9]+\)$/ && index($0, name) { seen[$2] = 1 }
            END { for (h in seen) n++; if (n == 1) for (h in seen) print h }')"
        if [ -z "$SHA1" ]; then
            echo "钥匙串里没有叫「$IDENTITY」的签名身份，或者不止一张：改写成 SHA-1（security find-identity -v -p codesigning 里看）" >&2
            exit 1
        fi
    fi
    # hardened runtime（--options runtime）：系统不再理会 DYLD_INSERT_LIBRARIES 这类环境变量，只加载苹果或同一团队签的库，
    # 别的程序就没法把代码注入进来、借 MacPeer 的身份读钥匙串里的登录密码、用它的辅助功能。签名要求不变，授权都还认
    SIGN=(--sign "$SHA1" --timestamp=none --options runtime -r="designated => identifier \"$BUNDLE_ID\" and certificate leaf = H\"$SHA1\"")
else
    SIGN=(--sign -)
fi

# App 的签名要求（designated requirement），临时签名的是 cdhash H"…"；没有 App 时为空
designated() { codesign -d -r- "$1" 2>/dev/null | sed -n 's/^# //; s/^designated => //p' || true; }

swift build -c release --scratch-path "$OUT/build" >&2
BIN="$(swift build -c release --scratch-path "$OUT/build" --show-bin-path)/mac_peer"
# 没变就不重新签名。签名会改写 App 里的程序，所以比较的是编译产物、Info.plist 和签名参数（身份、选项）
STAMP="$( (cat "$BIN" Info.plist; echo "${SIGN[*]}") | shasum | cut -d' ' -f1)"
if [ "$STAMP" != "$(cat "$OUT/MacPeer.stamp" 2>/dev/null)" ] || [ ! -x "$APP/Contents/MacOS/mac_peer" ]; then
    OLD="$(designated "$APP")"
    if [ -z "$SHA1" ] && [ -n "$OLD" ] && [[ "$OLD" != cdhash* ]] && [ "${MAC_PEER_SIGN_IDENTITY:-}" != "-" ]; then
        echo "装着的 MacPeer 是用固定证书签的，这次没找到签名身份（signing.local）。改用临时签名的话辅助功能、钥匙串要重新授权；真要这样就加 MAC_PEER_SIGN_IDENTITY=-" >&2
        exit 1
    fi
    # 在旁边打包、签好再换上去：签名失败时装着的 App 不受影响，也不会改写正在运行的程序
    NEW="$OUT/MacPeer.app.new"
    rm -rf "$NEW" "$APP.old"
    mkdir -p "$NEW/Contents/MacOS"
    cp "$BIN" "$NEW/Contents/MacOS/mac_peer"
    cp Info.plist "$NEW/Contents/Info.plist"
    if ! codesign --force "${SIGN[@]}" --identifier "$BUNDLE_ID" "$NEW" >&2; then
        rm -rf "$NEW"
        echo "用「$IDENTITY」签名失败（证书过期、删了，或者钥匙串锁着）：在 signing.local 里换一个签名身份" >&2
        exit 1
    fi
    if [ -e "$APP" ]; then mv "$APP" "$APP.old"; fi
    mv "$NEW" "$APP"
    rm -rf "$APP.old"
    echo "$STAMP" > "$OUT/MacPeer.stamp"
    if [ "$(designated "$APP")" != "$OLD" ]; then
        # 签名要求变了，系统当成另一个程序：辅助功能、发送系统事件要重新授权，钥匙串里的解锁登记电脑端启动时会问一次。
        # 系统的应用缓存里还记着旧签名，不刷新的话在系统设置里「+」加回来的也是旧的，照样不认
        "$LSREGISTER" -f "$APP" >&2 || true
        HINT=""
        [ -n "$SHA1" ] || HINT="（现在是临时签名，每次重新打包都要这样，固定签名见 README「签名」）"
        echo "MacPeer 的签名变了：自动解锁要在「系统设置 → 隐私与安全性 → 辅助功能」里把 MacPeer 删掉再加回来；电脑端启动时钥匙串会问一次，输登录密码点「始终允许」$HINT" >&2
    fi
fi
echo "$APP"
