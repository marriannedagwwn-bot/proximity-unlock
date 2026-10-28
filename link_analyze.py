#!/usr/bin/env python3
"""
分析原型 v0 的连接日志，回答 docs/protocol.md 里 v0 要回答的 4 个问题

    python link_analyze.py phone_20261019_110000_ios.csv
    python link_analyze.py phone_20261019_110000_ios.csv peer_20261019_105500_win32.csv
    python link_analyze.py phone_20261019_160000_ios.csv peer_20261019_155500_darwin.csv --device Mac

第一个文件是 iPhone App 导出的 CSV（位置标签记在这里），第二个可选，是电脑端的 CSV。
App 同时连着几台电脑时，手机 CSV 里几台电脑的事件混在一起（device 列区分），要用 --device 选一台。
两个文件按 time 列（墙上时钟）对齐，两台设备的时间要准（都开自动对时）。
只用标准库，表格和阈值建议沿用 rssi_probe.py 的做法。
"""

import argparse
import csv
import os
import re
import sys
from datetime import datetime

from rssi_probe import CLASS_CN, fmt_db, median, percentile, print_table, stdev, suggest_thresholds

UNAVAILABLE = 127
STATE_CN = {"0": "未定", "1": "靠近", "2": "离开"}
WINDOW = 5  # 滤波：最近 5 次 RSSI 的中位数，和 App 默认的判断参数一样


# ---------------------------------------------------------------- 读文件

def load(path):
    with open(path, newline="", encoding="utf-8-sig") as f:
        rows = list(csv.DictReader(f))
    for r in rows:
        r["ts"] = datetime.fromisoformat(r["time"]).timestamp()
    rows.sort(key=lambda r: r["ts"])
    if not rows:
        raise SystemExit(f"{path} 里没有记录")
    return rows


def device_name(label):
    """device 列是「电脑名（identifier 前 8 位）」，换了地址 identifier 会变，按电脑名分"""
    return label.split("（")[0]


def pick_device(rows, wanted):
    """只留一台电脑的事件和不分电脑的事件（app_launch、label 这些 device 列是空的）"""
    names = {}
    for r in rows:
        if r["event"] == "report" and r["device"]:
            name = device_name(r["device"])
            names[name] = names.get(name, 0) + 1
    if wanted is None:
        if len(names) > 1:
            raise SystemExit("手机日志里有 %d 台电脑的报告，用 --device 选一台（device 列里含这段文字就算）：\n%s" % (
                len(names), "\n".join(f"  {n}：REPORT {c} 次" for n, c in names.items())))
        return rows
    picked = [n for n in names if wanted in n]
    if not picked:
        raise SystemExit(f"手机日志里没有 device 含「{wanted}」的报告，有：{'、'.join(names) or '无'}")
    return [r for r in rows if not r["device"] or wanted in r["device"]]


def clock(ts):
    return datetime.fromtimestamp(ts).strftime("%H:%M:%S")


def dur(seconds):
    s = max(0, round(seconds))
    return f"{s}秒" if s < 60 else f"{s // 60}分{s % 60:02d}秒"


def overlap(intervals_a, intervals_b):
    """两组时间段相交的总长度"""
    return sum(max(0, min(b1, b2) - max(a1, a2)) for a1, b1 in intervals_a for a2, b2 in intervals_b)


def reports(rows):
    return [r for r in rows if r["event"] == "report"]


def valid_rssi(r):
    return r["rssi"] not in ("", str(UNAVAILABLE))


# ---------------------------------------------------------------- 手机端

class Phone:
    def __init__(self, rows, trim):
        self.rows = rows
        self.trim = trim
        self.start, self.end = rows[0]["ts"], rows[-1]["ts"]
        self.reports = reports(rows)
        self.periods = self._connected_periods()
        self.filtered = self._filter()
        self.segments = self._segments(trim)

    def _connected_periods(self):
        """已连接的时间段 [(开始, 结束, 结束原因)]，结束原因为 None 表示到文件末尾还连着"""
        periods, start, prev = [], None, self.start
        for r in self.rows:
            ev = r["event"]
            if ev == "app_launch" and start is not None:
                # App 被结束，日志在上一行就断了；系统恢复连接时会再记 restored_connected
                periods.append((start, prev, "App 被结束，之后不知道"))
                start = None
            elif ev in ("connect", "restored_connected", "adopt") and start is None:
                start = r["ts"]
            elif ev == "disconnect" and start is not None:
                periods.append((start, r["ts"], r["note"]))
                start = None
            prev = r["ts"]
        if start is not None:
            periods.append((start, self.end, None))
        return periods

    def _filter(self):
        """每条有效 report 的滤波值（最近 WINDOW 次的中位数），断开或 App 重启后重新攒"""
        out, recent = {}, []
        for r in self.rows:
            if r["event"] in ("disconnect", "app_launch"):
                recent = []
            elif r["event"] == "report" and valid_rssi(r):
                recent = (recent + [int(r["rssi"])])[-WINDOW:]
                out[id(r)] = median(recent)
        return out

    def _segments(self, trim):
        labels = []
        for r in self.rows:
            if r["event"] == "label" and ":" in r["note"]:
                name, cls = r["note"].rsplit(":", 1)
                labels.append((r["ts"], name, cls))
        segs = []
        for i, (ts, name, cls) in enumerate(labels):
            end = labels[i + 1][0] if i + 1 < len(labels) else self.end
            segs.append({"name": name, "cls": cls, "start": ts, "end": end, "a": ts + trim, "b": end - trim})
        return segs

    def label_at(self, ts):
        for s in self.segments:
            if s["start"] <= ts < s["end"]:
                return s
        return None

    def connected_time(self, intervals=None):
        spans = [(a, b) for a, b, _ in self.periods]
        return overlap(spans, intervals) if intervals is not None else sum(b - a for a, b in spans)

    def flag_intervals(self, on_events, off_events, start_on=False):
        """按事件切出某个状态（锁屏、后台）为真的时间段"""
        spans, since = [], (self.start if start_on else None)
        for r in self.rows:
            if r["event"] in on_events and since is None:
                since = r["ts"]
            elif r["event"] in off_events and since is not None:
                spans.append((since, r["ts"]))
                since = None
        if since is not None:
            spans.append((since, self.end))
        return spans

    def report_gaps(self):
        """同一段连接里相邻两次 report 的间隔"""
        gaps = []
        for a, b, _ in self.periods:
            ts = [r["ts"] for r in self.reports if a <= r["ts"] <= b]
            gaps += [(t2 - t1, t1) for t1, t2 in zip(ts, ts[1:])]
        return sorted(gaps, reverse=True)


def section_overview(phone, path):
    launches = [r for r in phone.rows if r["event"] == "app_launch"]
    woken = sum(1 for r in launches if "后台唤醒" in r["note"])
    print("== 概况 ==")
    print(f"{os.path.basename(path)}：{clock(phone.start)} 到 {clock(phone.end)}，共 {dur(phone.end - phone.start)}")
    print(f"App 启动 {len(launches)} 次（其中系统在后台唤醒 {woken} 次），"
          f"已连接 {dur(phone.connected_time())}，断开 {sum(1 for p in phone.periods if p[2] and 'App 被结束' not in p[2])} 次")
    reps = phone.reports
    valid = [r for r in reps if valid_rssi(r)]
    skips = sum(1 for r in phone.rows if r["event"] == "skip")
    missed = sum(int(m.group(1)) for r in reps for m in [re.search(r"漏了 (\d+) 次心跳", r["note"])] if m)
    conn = phone.connected_time()
    lat = [int(r["latency_ms"]) for r in reps if r["latency_ms"]]
    print(f"REPORT {len(reps)} 次（读不到 RSSI {len(reps) - len(valid)} 次），连接期间每秒 "
          f"{len(reps) / conn:.2f} 次" if conn else f"REPORT {len(reps)} 次")
    print(f"跳过的心跳 {skips} 次（RSSI 还没读完），漏收的心跳 {missed} 次")
    if lat:
        print(f"手机从收到心跳到读到 RSSI：中位 {median(lat):.0f}ms，P90 {percentile(lat, 90):.0f}ms，最长 {max(lat)}ms")
    print()


def section_q1(phone):
    print("== 问题 1：锁屏放兜里，连接会不会断？每秒能拿到几次 RSSI？ ==")
    locked = phone.flag_intervals({"phone_locked"}, {"phone_unlocked"})
    background = phone.flag_intervals({"app_background"}, {"app_active"})
    total = [(phone.start, phone.end)]
    rows = []
    for name, spans in (("全部", total), ("锁屏", locked), ("App 在后台", background)):
        conn = phone.connected_time(spans)
        if conn <= 0:
            continue
        reps = [r for r in phone.reports if any(a <= r["ts"] < b for a, b in spans)]
        gaps = [g for g, t in phone.report_gaps() if any(a <= t < b for a, b in spans)]
        cut = [p for p in phone.periods
               if p[2] and "App 被结束" not in p[2] and any(a <= p[1] < b for a, b in spans)]
        rows.append([name, dur(sum(b - a for a, b in spans)), dur(conn), len(cut),
                     f"{len(reps) / conn:.2f}", f"{max(gaps):.1f}s" if gaps else "-"])
    print_table(["时段", "时长", "其中已连接", "断开", "REPORT/秒", "最长间隔"], rows)
    if not locked:
        print("（日志里没有锁屏记录：手机没设密码时 iOS 不发锁屏通知）")
    gaps = phone.report_gaps()[:3]
    if gaps and gaps[0][0] > 3:
        print("最长的几次间隔：" + "，".join(
            f"{clock(t)} 起 {g:.1f}s（{(phone.label_at(t) or {}).get('name', '无标签')}）" for g, t in gaps if g > 3))
    print()


def section_q2(phone):
    print("== 问题 2：各位置的连接信号（每段去掉开头结尾各 %g 秒）==" % phone.trim)
    segs = [s for s in phone.segments if s["cls"] != "skip"]
    if not segs:
        print("没有位置标签。在 App 里先点位置、再带着手机过去待 90 秒左右。")
        print()
        return
    rows, near_vals, far_vals = [], [], []
    for s in segs:
        span = s["b"] - s["a"]
        if span <= 0:
            rows.append([s["name"], CLASS_CN.get(s["cls"], s["cls"]), clock(s["start"]), "太短"] + [""] * 5)
            continue
        reps = [r for r in phone.reports if s["a"] <= r["ts"] < s["b"]]
        raw = [int(r["rssi"]) for r in reps if valid_rssi(r)]
        flt = [phone.filtered[id(r)] for r in reps if id(r) in phone.filtered]
        states = [r["phone_state"] for r in reps]
        judged = "、".join(f"{STATE_CN[k]} {states.count(k) * 100 // len(states)}%"
                          for k in ("1", "2", "0") if states.count(k)) if states else "-"
        rows.append([
            s["name"], CLASS_CN.get(s["cls"], s["cls"]), clock(s["start"]), f"{span:.0f}s",
            f"{len(reps) / span:.2f}",
            f"{fmt_db(median(raw))} ({fmt_db(percentile(raw, 10))}~{fmt_db(percentile(raw, 90))})" if raw else "-",
            f"{stdev(raw):.1f}" if raw else "-",
            f"{fmt_db(percentile(flt, 5))}~{fmt_db(percentile(flt, 95))}" if flt else "-",
            judged,
        ])
        if s["cls"] == "near":
            near_vals += flt
        elif s["cls"] == "far":
            far_vals += flt
    print_table(["标签", "类别", "开始", "有效时长", "REPORT/秒", "RSSI 中位(P10~P90)", "抖动",
                 "滤波后 P5~P95", "手机判断"], rows)
    print(f"（抖动 = 标准差；滤波 = 最近 {WINDOW} 次的中位数，和 App 判断用的一样）")
    if near_vals and far_vals:
        near_th, far_th, _, _, verdict = suggest_thresholds(near_vals, far_vals)
        print(verdict)
        print(f"建议阈值：滤波后 ≥ {near_th} 判为靠近，≤ {far_th} 判为离开")
    else:
        print("要比较远近，至少各测一个「近」（桌上、兜里）和「远」（3米、门口、隔壁）的位置。")
    wrong = []
    for r in phone.rows:
        if r["event"] != "state":
            continue
        s = phone.label_at(r["ts"])
        if s and s["a"] <= r["ts"] < s["b"] and (s["cls"], r["phone_state"]) in (("near", "2"), ("far", "1")):
            wrong.append(f"{clock(r['ts'])} 在「{s['name']}」判成{STATE_CN[r['phone_state']]}（{r['note']}）")
    print(f"手机判断出错 {len(wrong)} 次" + ("：" + "；".join(wrong[:5]) if wrong else ""))
    print()


def section_q3(phone):
    print("== 问题 3：走开以后多久断开？回来以后多久重新连上？ ==")
    rows = []
    for i, (a, b, reason) in enumerate(phone.periods):
        if reason is None or "App 被结束" in reason:
            continue
        nxt = phone.periods[i + 1][0] if i + 1 < len(phone.periods) else None
        seg = phone.label_at(b)
        where = f"{seg['name']}（标签后 {dur(b - seg['start'])}）" if seg else "-"
        rows.append([clock(b), where, dur(nxt - b) if nxt else "到结尾没连上", reason[:30]])
    if rows:
        print_table(["断开时间", "当时的标签", "多久重连", "断开原因"], rows)
        print("「标签后」是从点下标签到断开的时间，包含走过去的时间。")
    else:
        print("这段记录里没有断开过。要测这一项，带着手机走到连接断开为止（比如隔壁、楼下），再走回来。")
    print()


def section_q4(phone):
    print("== 问题 4：电脑端程序重启后，还能用原来的 identifier 自动重连吗？ ==")
    ids = []
    for r in phone.rows:
        m = (re.search(r"id=([0-9A-F-]{36})", r["note"])
             if r["event"] in ("connect", "restored_connected", "adopt") else None)
        if m and m.group(1) not in ids:
            ids.append(m.group(1))
    print(f"连过的电脑 identifier：{len(ids)} 个" + ("（" + "、".join(i[:8] for i in ids) + "）" if ids else ""))
    events = ("service_changed", "no_service", "service_back", "no_service_drop",
              "adopt", "candidate_reject", "pairing_problem")
    restarts = [r for r in phone.rows if r["event"] in events
                or (r["event"] == "report" and "电脑端可能重启了" in r["note"])]
    if not restarts:
        print("这段记录里没看到电脑端重启（心跳 seq 没有变小，也没有服务变化）。"
              "要测这一项：手机连着时在电脑上结束 win_peer.py 再启动。")
    else:
        print("adopt = 电脑换了地址，App 按名字认出来改连；no_service_drop = 服务 30 秒没回来，主动断开重连。")
    for r in restarts:
        before = [x["ts"] for x in phone.reports if x["ts"] < r["ts"]]
        gap = f"，距上一次 REPORT {dur(r['ts'] - before[-1])}" if before else ""
        print(f"   {clock(r['ts'])} {r['event']}：{r['note']}{gap}")
    print()


# ---------------------------------------------------------------- 电脑端

def section_peer(phone, peer, path):
    print("== 电脑端 ==")
    a, b = max(phone.start, peer[0]["ts"]), min(phone.end, peer[-1]["ts"])
    if a >= b:
        print(f"{os.path.basename(path)} 和手机日志的时间没有重叠（电脑 {clock(peer[0]['ts'])}~{clock(peer[-1]['ts'])}），"
              "检查两台设备的时间对不对。")
        print()
        return
    print(f"{os.path.basename(path)}：和手机日志重叠 {clock(a)} 到 {clock(b)}，共 {dur(b - a)}")
    p_reps = [r for r in reports(peer) if a <= r["ts"] <= b]
    m_reps = [r for r in phone.reports if a <= r["ts"] <= b]
    # 电脑重启后 seq 会从头来，所以按 seq 配对时还要求时间接近
    by_seq = {}
    for r in p_reps:
        by_seq.setdefault(r["seq"], []).append(r["ts"])
    arrived = sum(1 for r in m_reps if any(abs(t - r["ts"]) < 10 for t in by_seq.get(r["seq"], [])))
    print(f"手机发出 REPORT {len(m_reps)} 次，电脑收到 {len(p_reps)} 次，按 seq 对上 {arrived} 次")
    lat = [float(r["latency_ms"]) for r in p_reps if r["latency_ms"]]
    if lat:
        print(f"往返延迟（电脑发心跳 → 收到 REPORT）：中位 {median(lat):.0f}ms，P90 {percentile(lat, 90):.0f}ms，"
              f"最长 {max(lat):.0f}ms")
    hb = [r for r in peer if r["event"] == "hb" and a <= r["ts"] <= b]
    failed = sum(1 for r in hb if re.search(r"ok=0/", r["note"]))
    print(f"电脑发心跳 {len(hb)} 次，其中没送达 {failed} 次")
    subs = [r for r in peer if r["event"] in ("subscribe", "unsubscribe") and a <= r["ts"] <= b]
    if subs:
        print("电脑看到的连接变化：" + "，".join(
            f"{clock(r['ts'])} {'订阅' if r['event'] == 'subscribe' else '取消订阅'}" for r in subs[:10]))
    print()


def main():
    p = argparse.ArgumentParser(description="分析原型 v0 的连接日志")
    p.add_argument("phone", help="iPhone App 导出的 phone_*_ios.csv")
    p.add_argument("peer", nargs="?", help="电脑端的 peer_*.csv（可选）")
    p.add_argument("--trim", type=float, default=10, help="每个位置标签开头结尾各去掉多少秒，默认 10")
    p.add_argument("--device", help="App 连着几台电脑时只看这台：device 列里含这段文字的（比如 DESKTOP、Mac）")
    args = p.parse_args()

    phone = Phone(pick_device(load(args.phone), args.device), args.trim)
    if not phone.reports:
        print("手机日志里没有 REPORT：手机还没连上电脑，或者连上了但没收到心跳。")
    section_overview(phone, args.phone)
    section_q1(phone)
    section_q2(phone)
    section_q3(phone)
    section_q4(phone)
    if args.peer:
        section_peer(phone, load(args.peer), args.peer)


if __name__ == "__main__":
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")  # Windows 控制台默认不是 UTF-8
    main()
