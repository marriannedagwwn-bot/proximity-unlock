#!/bin/bash
# 编译 Mac 电脑端并打包成 MacPeer.app，最后一行输出 App 的路径。
#
# 为什么要打包成 App：macOS 的蓝牙权限按"负责的进程"查 Info.plist 里的用途说明，
# 从没有这项说明的程序（比如 Claude Code）里直接跑命令行程序会被系统结束。
# 产物放在仓库以外：仓库在开着 iCloud 同步的文件夹（比如桌面）里时，签名会报 "resource fork, Finder information,
# or similar detritus not allowed"，编译产物也会被同步上去。
set -euo pipefail
cd "$(dirname "$0")"
OUT="${MAC_PEER_BUILD_DIR:-$HOME/Library/Caches/proximity-unlock}"
swift build -c release --scratch-path "$OUT/build" >&2
APP="$OUT/MacPeer.app"
BIN="$(swift build -c release --scratch-path "$OUT/build" --show-bin-path)/mac_peer"
mkdir -p "$APP/Contents/MacOS"
# 没变就不重新签名：签名一变，系统可能要重新问一次蓝牙权限。
# 签名会改写 App 里的程序，所以比较的是编译产物的哈希
STAMP="$(cat "$BIN" Info.plist | shasum | cut -d' ' -f1)"
if [ "$STAMP" != "$(cat "$OUT/MacPeer.stamp" 2>/dev/null)" ] || [ ! -x "$APP/Contents/MacOS/mac_peer" ]; then
    cp "$BIN" "$APP/Contents/MacOS/mac_peer"
    cp Info.plist "$APP/Contents/Info.plist"
    codesign --force --sign - "$APP" >&2
    echo "$STAMP" > "$OUT/MacPeer.stamp"
    # 临时签名的 App 系统按程序的哈希认，重签以后是「另一个程序」：辅助功能、发送系统事件要重新授权。
    # 系统的应用缓存里还记着旧签名，不刷新的话在系统设置里「+」加回来的也是旧的，照样不认（实测）
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP" >&2 || true
    echo "MacPeer 重新签名了：自动解锁要在「系统设置 → 隐私与安全性 → 辅助功能」里把 MacPeer 删掉再加回来" >&2
fi
echo "$APP"
