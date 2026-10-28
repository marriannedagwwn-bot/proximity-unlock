#!/bin/bash
# 登录时自动启动 Mac 电脑端（LaunchAgent），和 Windows 的 prototype/install_autostart.ps1 对应。
#
#   prototype/mac_peer/autostart.sh install [mac_peer 参数…]  编译、装上并马上启动；参数原样传给 mac_peer（比如 --no-lock）
#   prototype/mac_peer/autostart.sh stop       停止（不删，下次登录还会启动）
#   prototype/mac_peer/autostart.sh start      停止后再启动
#   prototype/mac_peer/autostart.sh status     在不在跑、最近的日志
#   prototype/mac_peer/autostart.sh uninstall  停止并删掉，以后登录不再启动
#
# - launchd 直接运行 MacPeer.app 里的程序，蓝牙权限算 MacPeer 自己的（第一次或重新编译后系统可能再问一次，点「允许」）。
# - 意外退出（崩溃、被强制结束）launchd 隔 30 秒重启；正常退出（stop、Ctrl+C、同时开了第二份）不重启。
# - 只允许运行一份：手动 run.sh 再开一份会直接退出。
# - 日志在 ~/Library/Logs/proximity-unlock/：peer_*.csv 是事件，mac_peer_stdout.txt 是原来打印到终端的内容。
#   不放在仓库里：仓库在桌面，后台进程写桌面要另外的「文件与文件夹」权限。
set -euo pipefail
cd "$(dirname "$0")"
LABEL="io.github.marriannedagwwn.MacPeer"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOGDIR="$HOME/Library/Logs/proximity-unlock"
DOMAIN="gui/$(id -u)"

loaded() { launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; }

stop_agent() {
    if loaded; then
        launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
        echo "已停止开机自启的 Mac 电脑端。"
    fi
}

stop_manual() {
    # 手动用 run.sh 开的：正常结束，让它记一行 stop
    if pgrep -f "MacPeer.app/Contents/MacOS/mac_peer" >/dev/null; then
        pkill -INT -f "MacPeer.app/Contents/MacOS/mac_peer" || true
        for _ in 1 2 3 4 5; do
            pgrep -f "MacPeer.app/Contents/MacOS/mac_peer" >/dev/null || break
            sleep 1
        done
        echo "已结束手动运行的 Mac 电脑端。"
    fi
}

status() {
    if loaded; then
        launchctl print "$DOMAIN/$LABEL" | grep -E "^\s+(state|pid|last exit code|runs) =" || true
    else
        echo "没有在 launchd 里（没装，或者 stop 了）"
    fi
    pgrep -fl "MacPeer.app/Contents/MacOS/mac_peer" || echo "没有 mac_peer 进程"
    LAST="$(ls -t "$LOGDIR"/peer_*_darwin.csv 2>/dev/null | head -1 || true)"
    if [ -n "$LAST" ]; then
        echo "最新日志：$LAST"
        tail -3 "$LAST"
    fi
}

case "${1:-install}" in
install)
    shift || true
    APP="$(./build.sh | tail -1)"
    BIN="$APP/Contents/MacOS/mac_peer"
    mkdir -p "$LOGDIR" "$(dirname "$PLIST")"
    stop_agent
    stop_manual
    ARGS=""
    for a in "$BIN" --dir "$LOGDIR" "$@"; do
        ARGS+="        <string>$a</string>"$'\n'
    done
    cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
$ARGS    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>
    <key>ThrottleInterval</key>
    <integer>30</integer>
    <key>ProcessType</key>
    <string>Interactive</string>
    <key>LimitLoadToSessionType</key>
    <string>Aqua</string>
    <key>StandardOutPath</key>
    <string>$LOGDIR/mac_peer_stdout.txt</string>
    <key>StandardErrorPath</key>
    <string>$LOGDIR/mac_peer_stdout.txt</string>
</dict>
</plist>
EOF
    launchctl bootstrap "$DOMAIN" "$PLIST"
    echo "已装上：每次登录后在后台启动 Mac 电脑端，现在已经启动。日志在 $LOGDIR"
    sleep 3
    status
    # 自动解锁要辅助功能、发送系统事件权限；重签以后会失效（见 build.sh）。用 open 启动才算 MacPeer 自己的权限
    CHECK="$(mktemp)"
    open -W -n --stdout "$CHECK" --stderr "$CHECK" "$APP" --args --screen-status 2>/dev/null || true
    grep -v "Unable to block" "$CHECK" || true
    if grep -q "未授权" "$CHECK"; then
        echo "自动解锁暂时用不了：在「系统设置 → 隐私与安全性 → 辅助功能」里把 MacPeer 删掉，点「+」按 Command+Shift+G 输入 $APP 加回来、打开开关（自动锁屏不受影响）"
    fi
    rm -f "$CHECK"
    ;;
stop)
    stop_agent
    ;;
start)
    [ -f "$PLIST" ] || { echo "还没装，先 $0 install"; exit 1; }
    loaded && launchctl kickstart "$DOMAIN/$LABEL" || launchctl bootstrap "$DOMAIN" "$PLIST"
    sleep 3
    status
    ;;
status)
    status
    ;;
uninstall)
    stop_agent
    rm -f "$PLIST"
    echo "已删掉，以后登录不再启动。日志留在 $LOGDIR"
    ;;
*)
    sed -n 2,14p "$0"
    exit 2
    ;;
esac
