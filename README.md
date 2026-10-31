# HDD Sleep Guard（硬盘休眠卫士）

让外置机械硬盘（HDD）在空闲时真正「停转」的 macOS 小工具。对机械硬盘而言，不转才是最好的散热——本工具在系统自带的 disksleep 对外置 USB 盘常常失效时，直接对盘下发 ATA「立即待机」指令，从根源消除空闲发热。

## 功能

· 自动发现外置机械硬盘（只管理 rotational、非内置盘；内置 SSD 自动排除）
· 用 macOS 原生 iostat 读每块盘的 I/O 活跃度判断空闲，达到阈值就令其停转
· 菜单栏常驻图标：实时显示各盘状态、温度、空闲倒计时，可立即停转/唤醒、改阈值、看日志
· 命令行 hddguard：与菜单栏等价的全部控制
· 登录自启、崩溃自重启的后台守护进程

## 工作原理

1. 空闲检测刻意不去查询硬盘的电源状态（一查就会把盘唤醒），改为跟踪磁盘 I/O：一个采样窗口内传输次数低于阈值即视为空闲。
2. 连续空闲达到 idle_minutes 后，用 smartctl 向该盘下发 ATA STANDBY IMMEDIATE，盘片停转、磁头归位。
3. 温度只在盘正在旋转时读取，避免为读温度而反复唤醒已停转的盘。

底层指令由 smartmontools 的 smartctl 承担（跨平台标准件）；本仓库不内置其二进制，安装时由脚本从官方 release 单独提取（见下）。

## 安装

需要 macOS 11+，在 Apple Silicon 与 Intel Mac 上均可。无需 Homebrew。

```bash
git clone https://github.com/mark-cell-520/hdd-sleep-guard.git
cd hdd-sleep-guard
bash scripts/install.sh            # 默认安装到 ~/hdd-sleep-guard
# 或指定目录： bash scripts/install.sh /your/prefix
```

install.sh 会：拷贝源码 → 从 smartmontools 官方 dmg 提取 smartctl 与 drivedb.h → 安装并加载 launchd 守护 → 编译菜单栏 app → 把 hddguard 链到 ~/.local/bin。

## 预编译 .app（免编译）

不想自己编译，可到 Releases 页面下载最新的 HDD-Sleep-Guard.app.zip：

https://github.com/mark-cell-520/hdd-sleep-guard/releases

解压后把「HDD Sleep Guard.app」拖到「应用程序」或 ~/Applications。首次打开请右键 → 打开（未公证，Gatekeeper 首次会拦）。该 .app 自包含核心引擎与 smartctl，双击即用，可写数据存放在 ~/Library/Application Support/HDD Sleep Guard。

注意：预编译 .app 提供菜单栏界面与手动停转/唤醒/温度；「空闲自动停转 + 登录自启」的后台守护仍需跑一次 scripts/install.sh。运行需要系统里有 python3（macOS 装过 Xcode 命令行工具，或 PATH 上任意 python3 均可）。

## 使用

菜单栏：点右上角外置硬盘图标即可操作，最常用「立即全部停转」和空闲阈值。

命令行：

```bash
hddguard status              # 各盘状态、温度、空闲倒计时
hddguard sleep [diskN...]    # 立即停转（指定盘或全部机械盘）
hddguard wake  [diskN...]    # 唤醒
hddguard temp  [diskN...]    # 读温度
hddguard info  <diskN>       # smartctl 完整信息
hddguard enable / disable    # 开/关自动停转
hddguard set <key> <val>     # 改配置，如 set idle_minutes 20
hddguard logs [n]            # 最近 n 行日志
```

## 配置（config.json）

| 键 | 默认 | 说明 |
|----|------|------|
| idle_minutes | 15 | 连续空闲多少分钟后停转 |
| poll_seconds | 60 | 采样窗口/轮询间隔（秒） |
| idle_io_transfers | 3 | 一个窗口内传输次数 ≤ 此值视为空闲 |
| temp_alert_c | 55 | 温度警戒线（仅提示） |
| device_type | auto | smartctl -d；USB 桥接不认标准待机时试 sat / usbjmicron / usbasm1352r / usbsunplus |
| use_rdisk | true | 用 /dev/rdiskN 发指令，兼容性更好 |
| manage_internal | false | 是否也管理内置机械盘 |

## 关于外置 USB 硬盘盒 / 扩展坞

部分 USB 桥接芯片不转发 ATA 待机指令，会导致停转失败。遇到时：
1. 先直连机身 USB 口，绕开扩展坞验证；
2. 若仍失败，在 config.json 里把 device_type 从 auto 改成你的桥接芯片对应值（可用 hddguard info <diskN> 观察）。

## 目录结构

```
daemon/hddguard_core.py        核心引擎（发现/空闲检测/停转/CLI）
cli/hddguard                   命令行入口
app/main.swift                 菜单栏 app（Swift/AppKit；核心定位：包内自带→install_prefix.txt→环境变量→默认前缀）
app/Info.plist
launchd/….plist.template       launchd 守护模板（安装时填入前缀）
scripts/fetch_smartctl.sh      从官方 dmg 提取 smartctl（无需 brew/sudo）
scripts/install.sh             一键安装
config.json                    默认配置
```

## 许可

本项目自身代码为 MIT（见 LICENSE）。底层 smartctl / drivedb.h 来自 smartmontools（GNU GPL v2），安装时从官方 release 单独获取，不随本仓库分发。
