#!/bin/bash
# 编译并运行 Mac 发 iBeacon 的实验工具，参数见 ./run.sh --help。日志 CSV 写在当前目录。
#
# 和 mac_peer 一样打包成 App（理由见 prototype/mac_peer/README.md「为什么打包成 App」）：
# - 在「终端」里运行：直接跑 App 里的程序，Ctrl+C 停止。
# - 不在终端里（比如从 Claude Code 里跑）：用 open 启动，输出写到 mac_beacon_stdout.txt；
#   停止用 pkill -INT -f MacBeacon.app/Contents/MacOS/mac_beacon
set -euo pipefail
cd "$(dirname "$0")"
SRC="$PWD"
cd - >/dev/null
OUT="${MAC_PEER_BUILD_DIR:-$HOME/Library/Caches/proximity-unlock}"
APP="$OUT/MacBeacon.app"
mkdir -p "$APP/Contents/MacOS" "$OUT/beacon-build"
swiftc -O "$SRC/main.swift" -o "$OUT/beacon-build/mac_beacon" >&2
# 没变就不重新签名：签名一变，系统可能要重新问一次蓝牙权限
STAMP="$(cat "$OUT/beacon-build/mac_beacon" "$SRC/Info.plist" | shasum | cut -d' ' -f1)"
if [ "$STAMP" != "$(cat "$OUT/MacBeacon.stamp" 2>/dev/null)" ] || [ ! -x "$APP/Contents/MacOS/mac_beacon" ]; then
    cp "$OUT/beacon-build/mac_beacon" "$APP/Contents/MacOS/mac_beacon"
    cp "$SRC/Info.plist" "$APP/Contents/Info.plist"
    codesign --force --sign - "$APP" >&2
    echo "$STAMP" > "$OUT/MacBeacon.stamp"
fi
if pgrep -f "MacPeer.app/Contents/MacOS/mac_peer" >/dev/null; then
    echo "注意：MacPeer 在跑，它的服务广播会把 iBeacon 挤掉（系统只发一份第三方广播）" >&2
fi
BIN="$APP/Contents/MacOS/mac_beacon"
if [ -t 1 ]; then
    exec "$BIN" --dir "$PWD" "$@"
fi
OUTPUT="${MAC_BEACON_STDOUT:-$PWD/mac_beacon_stdout.txt}"
echo "用 open 启动 $APP，输出在 $OUTPUT" >&2
exec open -W -n --stdout "$OUTPUT" --stderr "$OUTPUT" "$APP" --args --dir "$PWD" "$@"
