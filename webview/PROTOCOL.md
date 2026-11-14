# Skyward 插件协议 v1（帧插件）

状态：**已定稿，双方按此实现**。这是宿主与插件之间唯一的契约，任何一边单独改它都会让另一边读不懂，
所以改动前先把两边要对齐的东西说清楚。

两个实现方：

- 宿主：recovery 里的通用插件宿主（管镜像、上屏、转发输入、清理）。
- 插件：本仓库发布的程序（源码在 `webview/crate/`，由 `webview/build.sh` 打包成镜像）。

## 0. 为什么是这样

v0.3.4（`Jamvii/skyward-for-aurora@browser-v034`）把浏览器编进 recovery。我们改成外置插件：
recovery 只负责「装插件 / 启动程序 / 共享帧缓冲上屏 / 转发触摸键盘 / 退出清理」，
浏览器的一切（抓页面、排版、画界面、完整模式的 Chromium）都在插件进程里。
插件不碰 DRM、不 chroot、不写 recovery 的状态；宿主不认识「浏览器」这个词。

## 1. 插件包

插件目录（`/data/skyward/plugins/<name>/`）里：

```
plugin.json          # 清单
payload.erofs        # 负载镜像（erofs / squashfs / ext4 / img，只读挂载）
```

`plugin.json`：

```json
{
  "title": "浏览器",
  "version": "2.0",
  "author": "Rinrroy",
  "about": "在恢复里浏览网页、播放视频。默认用必应搜索。",
  "needs": ["data", "network"],
  "protocol": 1,
  "payload": {
    "url": "https://github.com/Rinrroy/skyward-plugins/releases/download/webview-2.0/webview-2.0-arm64.erofs",
    "sha256": "…64 hex…",
    "size": 12345678,
    "format": "erofs",
    "program": "/opt/skyward/bin/skyward-browser"
  }
}
```

- `protocol: 1` = 本文档的帧协议。缺省（无此字段）= 非帧插件，宿主只列出来、不运行。
- `program` 是**镜像内**的绝对路径，可执行文件或脚本。镜像被只读挂载在
  运行目录下的 `img/`（见 §2）；`program` 直接以**recovery 自己的 libc（bionic）**执行，
  **不 chroot**（所以程序必须是 aarch64-linux-android 二进制或一个 `#!/system/bin/sh` 脚本）。
- 镜像挂在 rootfs 上（不是 /data），因为要可执行。
- 本仓库的清单指向二进制（`/opt/skyward/bin/skyward-browser`）。镜像里另外带一个薄 wrapper
  `opt/skyward/run.sh`（设好 `HOME` 再 exec 同一个二进制），给手工调试用；清单不指向它，
  因为少一次 fork 就少一个能被改坏的地方。

## 2. 宿主给插件的环境

宿主为插件建两个位置，**都在 rootfs（ramdisk）上，都可写**：

```
R = /skyward/run/plugin/<name>/        运行目录：帧文件、FIFO、日志、插件自己的 home 都在这
R/img/                                 挂载点：payload 只读挂在这（erofs/squashfs/ext4/img）
```

`img/` 是 `R` 的子目录，所以挂载点不在只读文件系统里，`R` 里其余东西照常可写。
插件要用的镜像内路径 = `R/img` + `payload.program`（例如 `R/img/opt/skyward/bin/skyward-browser`）。
宿主 exec 的就是这个路径；插件若要知道自己的镜像根，用 `argv[0]` 反推或看 `SKYWARD_PLUGIN_ROOT`。

| 名字 | 含义 |
|---|---|
| `SKYWARD_PLUGIN_ROOT` | `R/img`，镜像根（只读） |
| argv[0] | `program` 的路径（镜像内挂载点 + program） |
| argv[1] | 启动 URL（可为空字符串） |
| `SKYWARD_PLUGIN` = `1` | 表示跑在插件协议下 |
| `SKYWARD_PLUGIN_FRAME` | 帧文件路径 `R/frame`（宿主已创建并 ftruncate 好） |
| `SKYWARD_PLUGIN_INPUT` | 输入 FIFO 路径 `R/input`（宿主已 mkfifo） |
| `SKYWARD_PANEL_W` / `SKYWARD_PANEL_H` | 面板像素尺寸 |
| `SKYWARD_URL` | 与 argv[1] 相同（脚本方便取） |
| `SKYWARD_USER_AGENT` | 宿主建议的 UA。**v1 不生效**：`skyward-net` 的 UA 是编译期常量（`web.rs:23`），插件改不了；留作 v2 |
| `SKYWARD_DNS` | 宿主已知的域名服务器，逗号分隔的 IPv4（可空）。插件优先用它，没有再自己从网关/属性猜 |
| `SKYWARD_DATA` | `/data/media/0/Skyward`（data 已解密时存在，否则为空串） |
| `SKYWARD_STORE` | `/data/skyward/plugins`（已安装插件目录，完整模式找 chromium 用） |
| `SKYWARD_HOME` | `/data/skyward/browser`（可写，插件自己的缓存/配置；data 未开时是 `R/home`） |
| `SKYWARD_LOG` | `R/log`（追加写；也是插件的 stdout/stderr） |
| cwd | `R` |
| stdin/stdout/stderr | 指向 `SKYWARD_LOG`（追加），插件写日志不要钱 |

宿主在 exec 前把进程放进自己的进程组（`setpgid(0,0)`），结束时 `kill(-pgid, SIGKILL)`。

## 3. 帧文件（`SKYWARD_PLUGIN_FRAME`）

mmap 共享的普通文件，宿主先 `ftruncate` 到 `4096 + H*W*4` 再启动插件，双方 `mmap(MAP_SHARED)`。
全部小端。

```
偏移  大小  字段
0     4     magic "SWFR"          宿主写入，插件只读
4     4     u32 version = 1       宿主写入
8     4     u32 width             宿主写入（面板宽）
12    4     u32 height            宿主写入
16    4     u32 stride            宿主写入 = width*4
20    4     u32 seq               插件写：每完成一帧 +1（宿主按它判断新帧）
24    4     u32 flags             位 0 ready：插件已画出第一帧；位 1 quit：插件要退出；位 2 keyboard：插件请求恢复的软键盘
28    4     u32 dirty_count       脏矩形个数，0..=16；0 且 seq 变化 = 整帧
32    256   dirty[16] {u32 x,y,w,h}  插件写
288   3808  保留（0）
4096  H*stride  像素：RGBA8888（straight alpha），行主序，行内 x 递增；通道序就是宿主 Canvas::data 的序（R,G,B,A）
```

写出顺序（插件侧必须遵守，宿主据此避免撕裂）：
1. 写像素到 4096 起；
2. 写 dirty 表；
3. 写 `dirty_count`；
4. 最后写 `seq`（递增，奇数表示正在写：`seq |= 1` 起笔，写完 `seq += 1` 变偶）。

宿主只在 `seq` 是偶数且比上次大时上屏；按 dirty 矩形只拷那些行，`dirty_count==0` 拷整帧。
`ready` 位置 1 之后宿主才开始上屏。

## 4. 输入 FIFO（`SKYWARD_PLUGIN_INPUT`）

宿主写、插件读。**一行一条命令，UTF-8，`\n` 结尾**。插件以 `O_RDONLY|O_NONBLOCK` 打开、
自己 select/poll；宿主永远不阻塞写（写失败就丢这一条并记日志）。

v1 里宿主真正会发的命令（插件必须实现）：

```
down <x> <y>              面板像素，触摸按下
move <x> <y>              按住移动
up   <x> <y>              抬起（一次点击 = down/up，可能带 move）
key <Name>                Back / Power（recovery 的输入只有四个硬件键：Back、Power、VolumeUp、VolumeDown）
stop                      宿主请求退出：插件写完收尾后 exit(0)
```

保留、v1 宿主**不**发（插件必须忽略，不许崩）：`swipe <x0> <y0> <x1> <y1> <ms>`、`pinch <cx> <cy> <scale>`、`text <escaped>`（`\\` 反斜杠、`\n` 换行）、`rotate <0|90|180|270>`、`reload`、`start`。
`text` 之所以没人发，是因为 recovery 没有软键盘：**打字是插件自己的事**——插件画自己的键盘，把它收到的 `down/move/up` 变成按键。`swipe/pinch` 同理：滑动的惯性由插件自己从 `move` 序列算，宿主的触摸只是原始事件。

宿主只有在用户确实操作时才发命令；插件必须容忍未知命令（忽略）。

## 5. 生命周期

1. 宿主挂载 payload，选程序，建帧文件/FIFO，`fork+exec`。
2. 插件 mmap 帧文件、打开 FIFO，画第一帧，置 `ready`。
3. 宿主 10 秒内没等到 `ready` → 杀进程组、卸载镜像、报告「插件没有启动」+ 日志尾巴。
   宿主 90 秒无新帧且无触摸 → 不算失败（页面可能静止），但日志记一次。
4. 用户离开（按返回且插件 `quit`，或宿主自己退出）→ 宿主写 `stop`，等 2 秒，再 `kill(-pgid, SIGKILL)`。
5. 插件 exit 码：0 = 正常；其它 = 失败，宿主报告「插件退出码 N」+ 日志尾巴。

## 6. 职责边界

- 宿主：镜像我管、帧我上屏、触摸我转发、日志我保留、2 小时上限、退出清理（umount/loop）。
- 插件：URL 栏、标签页、下载、表单、cookie、完整模式的 Chromium 全部自己搞。插件要下载文件就
  自己写 `$SKYWARD_DATA`。
- 插件不得：改 recovery 的状态、改别的插件、写 `/metadata`。

## 7. 完整模式（Chromium）怎么归属

完整模式属于**插件内部实现**：插件在 `$SKYWARD_STORE/webview-chromium/`（或
`/data/media/0/Skyward/plugins/chromium/`）找到 Chromium rootfs，自己 `mount --bind /dev`、
`chroot ... /bin/sh /run.sh <url> serve`（照 v0.3.4 的做法），再走 CDP 截图/触摸。
宿主完全不知道有 Chromium。

## 8. 验收

- 宿主：`cargo ndk -t arm64-v8a --platform 30 check --locked -p skyward` 通过；`clippy -D warnings` 干净。
- 插件：`cargo ndk -t arm64-v8a --platform 30 build --release -p skyward-browser` 通过。
- 协议：两边各有一份帧文件/命令的最小自测（宿主侧 `#[test]` 用普通文件模拟，插件侧单测解析）。
