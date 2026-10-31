#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""HDD Sleep Guard 核心引擎。

职责：
  1. 自动发现外置机械硬盘（rotational、非内置；可选纳入内置）。
  2. 用 macOS 原生 iostat 读每块盘的 I/O 传输次数，判断是否空闲。
  3. 连续空闲达到阈值后，用 smartctl 发 ATA「立即待机」，让盘片真正停转。
  4. 提供状态、手动停转/唤醒、温度、配置、日志等命令行子命令。

空闲检测刻意不查询硬盘电源状态（查询会唤醒盘片），改用自身对 I/O 的跟踪：
  · 采样窗口内传输次数 > 阈值  -> 视为在用，刷新 last_active，标记 spinning。
  · 采样窗口内传输次数 <= 阈值 -> 视为空闲；若仍在转且空闲时长够，则停转。
"""

import os
import sys
import json
import time
import plistlib
import subprocess
import datetime

BASE = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
SMARTCTL = os.path.join(BASE, "bin", "smartctl")
DRIVEDB = os.path.join(BASE, "share", "drivedb.h")
# 可写数据目录：随 .app 打包运行时改放 Application Support（app 包内不宜写）；
# 按前缀安装的守护进程则仍用安装根，行为不变。
if (".app" + os.sep + "Contents" + os.sep + "Resources") in BASE:
    DATA_DIR = os.path.expanduser("~/Library/Application Support/HDD Sleep Guard")
else:
    DATA_DIR = BASE
CONFIG_PATH = os.path.join(DATA_DIR, "config.json")
STATE_PATH = os.path.join(DATA_DIR, "state.json")
LOG_PATH = os.path.join(DATA_DIR, "hddguard.log")

DEFAULT_CONFIG = {
    "idle_minutes": 15,        # 连续空闲多少分钟后停转
    "poll_seconds": 60,        # 采样窗口/轮询间隔（秒）
    "idle_io_transfers": 3,    # 一个窗口内传输次数 <= 此值视为空闲
    "temp_alert_c": 55,        # 温度警戒线（仅提示，不自动动作）
    "device_type": "auto",     # smartctl -d；auto/sat/usbjmicron/usbasm1352r/usbsunplus/...
    "use_rdisk": True,         # 用 /dev/rdiskN（原始设备）发指令，兼容性更好
    "manage_internal": False,  # 是否也管理内置机械盘（一般不用）
    "enabled": True,           # 自动停转总开关
}


# ---------- 基础：日志 / 配置 / 状态 ----------
def log(msg):
    try:
        os.makedirs(os.path.dirname(LOG_PATH), exist_ok=True)
        ts = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        with open(LOG_PATH, "a", encoding="utf-8") as f:
            f.write("[%s] %s\n" % (ts, msg))
    except Exception:
        pass


def load_config():
    cfg = dict(DEFAULT_CONFIG)
    try:
        with open(CONFIG_PATH, encoding="utf-8") as f:
            data = json.load(f)
            if isinstance(data, dict):
                cfg.update(data)
    except Exception:
        pass
    return cfg


def save_config(cfg):
    try:
        os.makedirs(os.path.dirname(CONFIG_PATH), exist_ok=True)
        with open(CONFIG_PATH, "w", encoding="utf-8") as f:
            json.dump(cfg, f, ensure_ascii=False, indent=2)
    except Exception as e:
        log("保存配置失败: %s" % e)


def load_state():
    try:
        with open(STATE_PATH, encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return {}


def save_state(st):
    try:
        os.makedirs(os.path.dirname(STATE_PATH), exist_ok=True)
        with open(STATE_PATH, "w", encoding="utf-8") as f:
            json.dump(st, f, indent=2)
    except Exception:
        pass


# ---------- 子进程封装 ----------
def _run(cmd, timeout=30):
    try:
        p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                           text=True, timeout=timeout)
        return p.returncode, p.stdout
    except Exception as e:
        return -1, str(e)


def _plist(cmd, timeout=30):
    rc, out = _run(cmd, timeout=timeout)
    if rc != 0:
        return None
    try:
        return plistlib.loads(out.encode("utf-8"))
    except Exception:
        return None


# ---------- 发现机械盘 ----------
def disk_info(bsd):
    return _plist(["diskutil", "info", "-plist", bsd]) or {}


def _rotation_rate(bsd, cfg):
    rc, out = _run(_smartctl_info_cmd(bsd, cfg))
    for line in out.splitlines():
        if "Rotation Rate" in line:
            v = line.split(":", 1)[1].strip()
            try:
                return int(v.split()[0])
            except Exception:
                return None
    return None


def discover_hdds(cfg=None):
    cfg = cfg or load_config()
    manage_internal = cfg.get("manage_internal", False)
    top = _plist(["diskutil", "list", "-plist"])
    whole = []
    for e in (top or {}).get("AllDisksAndPartitions", []):
        ident = e.get("DeviceIdentifier")
        if ident:
            whole.append(ident)

    hdds = []
    for bsd in whole:
        info = disk_info(bsd)
        if not info:
            continue
        internal = bool(info.get("Internal", False))
        solid = info.get("SolidState", None)  # True=固态 False=机械 None=未知
        if solid is True:
            continue
        if solid is None:
            rot = _rotation_rate(bsd, cfg)
            # 明确固态（转速 0 或无转速但报 Solid State Device）则跳过
            if rot == 0:
                continue
        if internal and not manage_internal:
            continue
        hdds.append({
            "bsd": bsd,
            "name": info.get("MediaName") or info.get("DeviceIdentifier") or bsd,
            "size": info.get("TotalSize", 0) or 0,
            "internal": internal,
            "solid": bool(solid) if solid is not None else False,
            "protocol": info.get("DeviceProtocol", "") or "",
            "mount": info.get("MountPoint") or "",
        })
    return hdds


# ---------- smartctl 指令 ----------
def _smartctl_base(cfg):
    cmd = [SMARTCTL, "-B", DRIVEDB]
    dt = cfg.get("device_type", "auto")
    if dt and dt != "auto":
        cmd += ["-d", dt]
    return cmd


def _dev(bsd, cfg):
    return ("/dev/r" + bsd) if cfg.get("use_rdisk", True) else ("/dev/" + bsd)


def _smartctl_info_cmd(bsd, cfg):
    return _smartctl_base(cfg) + ["-i", _dev(bsd, cfg)]


def do_standby(bsd, cfg):
    cmd = _smartctl_base(cfg) + ["-s", "standby,now", _dev(bsd, cfg)]
    rc, out = _run(cmd, timeout=30)
    last = out.strip().splitlines()[-1] if out.strip() else ""
    log("standby %s rc=%d %s" % (bsd, rc, last))
    return rc == 0


def read_temp(bsd, cfg):
    rc, out = _run(_smartctl_base(cfg) + ["-A", _dev(bsd, cfg)], timeout=30)
    if rc != 0:
        return None
    for line in out.splitlines():
        parts = line.split()
        if len(parts) >= 10 and parts[0].isdigit() and \
                parts[1] in ("Temperature_Celsius", "Airflow_Temperature_Cel"):
            try:
                return int(parts[9])
            except Exception:
                pass
    return None


def wake(bsd, cfg):
    rc, _ = _run(_smartctl_info_cmd(bsd, cfg), timeout=30)
    return rc == 0


# ---------- I/O 空闲检测 ----------
def sample_transfers(disks, window):
    """并发对每块盘跑 iostat，返回 {bsd: 窗口内传输次数}。

    iostat -d <disk> <window> 2 会先打印开机均值，再打印一个 <window> 秒的实时
    间隔；取最后一行的 tps（第 2 列）乘 window 即窗口内传输次数。
    """
    res = {}
    if not disks:
        return res
    window = max(1, int(window))
    procs = {}
    for d in disks:
        procs[d] = subprocess.Popen(
            ["iostat", "-d", d, str(window), "2"],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
    for d, p in procs.items():
        try:
            out, _ = p.communicate(timeout=window + 20)
        except Exception:
            try:
                p.kill()
            except Exception:
                pass
            out = ""
        data = []
        for line in out.splitlines():
            parts = line.split()
            if len(parts) == 3:
                try:
                    [float(x) for x in parts]
                    data.append(parts)
                except ValueError:
                    pass
        tps = float(data[-1][1]) if data else 0.0
        res[d] = tps * window
    return res


# ---------- 守护进程 ----------
def run_daemon():
    log("守护进程启动 (pid=%d)" % os.getpid())
    while True:
        loop_start = time.time()
        poll = 60
        try:
            cfg = load_config()
            poll = max(5, int(cfg.get("poll_seconds", 60)))
            if not cfg.get("enabled", True):
                time.sleep(poll)
                continue
            hdds = discover_hdds(cfg)
            disks = [h["bsd"] for h in hdds]
            # 有盘时 iostat 会阻塞约 poll 秒；无盘时立即返回，靠末尾节奏控制补齐
            transfers = sample_transfers(disks, poll)

            now = time.time()
            state = load_state()
            idle_secs = int(cfg.get("idle_minutes", 15)) * 60
            thr = float(cfg.get("idle_io_transfers", 3))

            for h in hdds:
                d = h["bsd"]
                st = state.get(d) or {"last_active": now, "spinning": True, "standby_at": 0}
                tr = transfers.get(d, 0.0)
                if tr > thr:
                    if not st.get("spinning", True):
                        log("%s(%s) 有活动 %.0f 次，恢复旋转" % (d, h["name"], tr))
                    st["last_active"] = now
                    st["spinning"] = True
                else:
                    idle_for = now - st.get("last_active", now)
                    if st.get("spinning", True) and idle_for >= idle_secs:
                        if do_standby(d, cfg):
                            st["spinning"] = False
                            st["standby_at"] = now
                            log("%s(%s) 已空闲 %.1f 分钟，执行停转" %
                                (d, h["name"], idle_for / 60.0))
                state[d] = st
            save_state(state)
        except Exception as e:
            log("守护循环异常: %s" % e)
        # 节奏控制：每轮总耗时至少 poll 秒，避免无盘时 busy-loop
        remaining = poll - (time.time() - loop_start)
        if remaining > 0:
            time.sleep(remaining)


# ---------- 命令行 ----------
def human_size(n):
    try:
        n = float(n)
    except Exception:
        return str(n)
    for u in ("B", "KB", "MB", "GB", "TB"):
        if n < 1024:
            return "%.1f%s" % (n, u)
        n /= 1024
    return "%.1fPB" % n


def cmd_status_json(cfg):
    hdds = discover_hdds(cfg)
    state = load_state()
    now = time.time()
    idle_secs = int(cfg.get("idle_minutes", 15)) * 60
    items = []
    for h in hdds:
        d = h["bsd"]
        st = state.get(d, {})
        spinning = st.get("spinning", True)
        idle_for = now - st.get("last_active", now)
        items.append({
            "bsd": d,
            "name": h["name"],
            "size": h["size"],
            "protocol": h["protocol"],
            "spinning": spinning,
            "idle_minutes": round(idle_for / 60.0, 1),
            "remain_minutes": round(max(0, idle_secs - idle_for) / 60.0, 1),
            # 只在盘正在旋转时读温度，避免为读温度而唤醒已停转的盘
            "temp_c": read_temp(d, cfg) if spinning else None,
        })
    out = {
        "enabled": cfg.get("enabled", True),
        "idle_minutes": cfg.get("idle_minutes"),
        "poll_seconds": cfg.get("poll_seconds"),
        "disks": items,
    }
    print(json.dumps(out, ensure_ascii=False))


def cmd_status(cfg):
    hdds = discover_hdds(cfg)
    state = load_state()
    now = time.time()
    if not hdds:
        print("未发现外置机械硬盘。")
        print("提示：仅管理 rotational 且非内置的盘；插入 USB 机械盘后再试。")
        print("想看全部候选（含内置/固态）用: hddguard list")
        return
    print("发现 %d 块外置机械盘：" % len(hdds))
    for h in hdds:
        d = h["bsd"]
        st = state.get(d, {})
        spinning = st.get("spinning", True)
        last_active = st.get("last_active", now)
        idle_for = now - last_active
        remain = max(0, int(cfg.get("idle_minutes", 15)) * 60 - idle_for)
        print("· %s  %s  %s  协议 %s" % (d, h["name"], human_size(h["size"]), h["protocol"]))
        print("    状态 %s；已空闲 %.1f 分钟；距自动停转 %.1f 分钟" %
              ("旋转中" if spinning else "已停转", idle_for / 60.0, remain / 60.0))
        t = read_temp(d, cfg)
        if t is not None:
            flag = "（超警戒）" if t >= int(cfg.get("temp_alert_c", 55)) else ""
            print("    温度 %d°C %s" % (t, flag))
    print("阈值：空闲 %s 分钟停转；采样每 %s 秒；自动停转 %s" %
          (cfg.get("idle_minutes"), cfg.get("poll_seconds"),
           "开" if cfg.get("enabled", True) else "关"))


def cmd_list(cfg):
    top = _plist(["diskutil", "list", "-plist"])
    print("全部整盘候选（diskutil）：")
    for e in (top or {}).get("AllDisksAndPartitions", []):
        ident = e.get("DeviceIdentifier")
        if not ident:
            continue
        info = disk_info(ident)
        print("· %s  %s  %s  internal=%s solid=%s proto=%s" % (
            ident,
            info.get("MediaName", "?"),
            human_size(info.get("TotalSize", 0) or 0),
            info.get("Internal", "?"),
            info.get("SolidState", "?"),
            info.get("DeviceProtocol", "?"),
        ))


def cmd_sleep(cfg, disks):
    hdds = discover_hdds(cfg)
    allb = [h["bsd"] for h in hdds]
    targets = disks or allb
    if not targets:
        print("没有可停转的机械盘。")
        return
    state = load_state()
    for d in targets:
        if d not in allb:
            print("跳过 %s：不是已识别的机械盘" % d)
            continue
        print("对 %s 发立即停转…" % d)
        if do_standby(d, cfg):
            st = state.setdefault(d, {})
            st["spinning"] = False
            st["standby_at"] = time.time()
            print("  %s 已停转" % d)
        else:
            print("  %s 停转失败：USB 桥接可能不支持 ATA 待机，"
                  "可在 config.json 调 device_type（如 sat / usbjmicron / usbasm1352r）" % d)
    save_state(state)


def cmd_wake(cfg, disks):
    hdds = discover_hdds(cfg)
    allb = [h["bsd"] for h in hdds]
    state = load_state()
    for d in (disks or allb):
        if wake(d, cfg):
            print("%s 已唤醒" % d)
        else:
            print("%s 唤醒指令返回异常" % d)
        st = state.setdefault(d, {})
        st["spinning"] = True
        st["last_active"] = time.time()
    save_state(state)


def cmd_temp(cfg, disks):
    hdds = discover_hdds(cfg)
    allb = [h["bsd"] for h in hdds]
    for d in (disks or allb):
        if d not in allb:
            print("跳过 %s" % d)
            continue
        t = read_temp(d, cfg)
        print("%s 温度 %s" % (d, ("%d°C" % t) if t is not None else "不可读（USB 可能不透传 SMART）"))


def cmd_info(cfg, bsd):
    if not bsd:
        print("用法: hddguard info <diskN>")
        return
    rc, out = _run(_smartctl_base(cfg) + ["-a", _dev(bsd, cfg)], timeout=40)
    print(out)


def cmd_logs(args):
    n = 40
    if args and args[0].isdigit():
        n = int(args[0])
    try:
        with open(LOG_PATH, encoding="utf-8") as f:
            lines = f.readlines()
        for line in lines[-n:]:
            print(line.rstrip())
    except FileNotFoundError:
        print("暂无日志")


def print_help():
    print("HDD Sleep Guard 命令：")
    print("  status              查看各机械盘状态、温度、空闲倒计时")
    print("  list                列出全部整盘候选")
    print("  sleep [diskN...]    立即停转（指定盘或全部机械盘）")
    print("  wake  [diskN...]    唤醒（指定盘或全部）")
    print("  temp  [diskN...]    读温度")
    print("  info  <diskN>       查看 smartctl 完整信息")
    print("  enable / disable    开/关自动停转")
    print("  set <key> <val>     改配置，如 set idle_minutes 20")
    print("  logs [n]            看最近 n 行日志")
    print("  --daemon            以前台守护进程运行（一般由 launchd 拉起）")


def main(argv):
    cfg = load_config()
    if not argv or argv[0] in ("status", "-s", "--status"):
        if "--json" in argv:
            cmd_status_json(cfg)
        else:
            cmd_status(cfg)
        return
    cmd = argv[0]
    if cmd in ("--daemon", "daemon"):
        run_daemon()
    elif cmd == "sleep":
        cmd_sleep(cfg, argv[1:])
    elif cmd == "wake":
        cmd_wake(cfg, argv[1:])
    elif cmd == "temp":
        cmd_temp(cfg, argv[1:])
    elif cmd == "list":
        cmd_list(cfg)
    elif cmd == "info":
        cmd_info(cfg, argv[1] if len(argv) > 1 else "")
    elif cmd == "enable":
        cfg["enabled"] = True
        save_config(cfg)
        print("已启用自动停转")
    elif cmd == "disable":
        cfg["enabled"] = False
        save_config(cfg)
        print("已停用自动停转")
    elif cmd == "set":
        if len(argv) < 3:
            print("用法: hddguard set <key> <value>")
            return
        key, val = argv[1], argv[2]
        low = val.lower()
        if low in ("true", "false"):
            v = (low == "true")
        else:
            try:
                v = int(val)
            except ValueError:
                try:
                    v = float(val)
                except ValueError:
                    v = val
        cfg[key] = v
        save_config(cfg)
        print("已设置 %s = %s" % (key, v))
    elif cmd == "logs":
        cmd_logs(argv[1:])
    elif cmd in ("-h", "--help", "help"):
        print_help()
    else:
        print("未知命令: %s" % cmd)
        print_help()


if __name__ == "__main__":
    main(sys.argv[1:])
