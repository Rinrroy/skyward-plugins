# 完整模式的 Chromium

浏览器有两种模式。基本模式就在 recovery 里，不跑脚本、不放视频；完整模式用一个
外置的 Linux Chromium 画页面，脚本、视频和复杂的站点都能用。

这里的脚本生成完整模式要装的那份东西：一个 Debian arm64 的根文件系统，里面有
Chromium 和 `run.sh`，打成 `chromium-<版本>-arm64.tar.gz`。

## 它怎么被用

1. 把 `chromium-<版本>-arm64.tar.gz` 放到手机的 `/sdcard/Skyward/plugins/`，或者
   `/sdcard/Download/Skyward/`（浏览器下载的文件本来就在后者）。
2. 在 recovery 里打开 浏览器 → 完整模式 → 安装或更新。
3. 安装会把包解开到 `/data/media/0/Skyward/plugins/chromium`，之后浏览器在这个
   目录 chroot 里跑 `run.sh`，所以 data 分区必须已经解密。

安装不检验签名，只认你放到手机上的那个文件，所以只用自己构建或可信来源的包。

## run.sh 的约定

- `run.sh <网址> serve`：起一个常驻的 Chromium，在 127.0.0.1:9222 上开调试口，
  浏览器通过 CDP 截图、点按、缩放、输入。
- `run.sh <网址>`：画一次页面，写到 `/tmp/skyward-chromium.png` 后退出。

recovery 事先把 `/dev`、`/proc`、`/sys` 绑进这个根文件系统，并把手机的域名服务器
写进 `/etc/resolv.conf`，`run.sh` 里的挂载和写文件只是给裸 chroot 用的兜底。

## 构建

需要一台 arm64 Linux（或 `.github/workflows/chromium.yml` 里的 arm64 runner）、
`debootstrap`、`sudo`，大约 3 GB 磁盘：

```sh
./chromium/build.sh 1.0      # 得到 chromium-1.0-arm64.tar.gz 和它的 sha256
```

换版本号就会在 Releases 里另发一个 `chromium-<版本>`；同名已存在则不重复发布，
所以想再发一次要改版本号。

## 已知的限制

- 声音没有：recovery 里没有音频通路。
- 视频是软件解码，能放但不流畅。
- 页面大小固定在 412×915（设备像素比 2），截图上限压到 recovery 内存吃得下的
  范围，所以很长的一页会分几次看。
- Chromium 在 recovery 里跑得比在系统里慢，第一次打开页面要等几秒。
