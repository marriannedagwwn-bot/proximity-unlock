#!/bin/bash
# 运行 Mac 电脑端，参数和 win_peer.py 一样（./run.sh --help）。日志 CSV 写在当前目录。
#
# - 在「终端」里运行：直接跑 App 里的程序，蓝牙权限算终端的，Ctrl+C 停止。
# - 不在终端里（比如从 Claude Code 里跑）：用 open 启动 App，蓝牙权限算 MacPeer 自己的，
#   输出写到 mac_peer_stdout.txt；停止用 pkill -INT -f MacPeer.app/Contents/MacOS/mac_peer
set -euo pipefail
APP="$("$(dirname "$0")/build.sh" | tail -1)"
BIN="$APP/Contents/MacOS/mac_peer"
if [ -t 1 ]; then
    exec "$BIN" --dir "$PWD" "$@"
fi
OUTPUT="${MAC_PEER_STDOUT:-$PWD/mac_peer_stdout.txt}"
echo "用 open 启动 $APP，输出在 $OUTPUT" >&2
exec open -W -n --stdout "$OUTPUT" --stderr "$OUTPUT" "$APP" --args --dir "$PWD" "$@"
