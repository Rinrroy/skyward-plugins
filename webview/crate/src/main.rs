//! skyward-browser：把 v0.3.4 的浏览器界面 + worker 做成一个独立程序。
//!
//! 宿主按 `.tmp/plugin-protocol.md`（协议 v1）跑它：共享内存里给一块帧文件、
//! 一个输入 FIFO，插件 mmap 帧文件、画像素、按脏矩形发布，从 FIFO 读
//! `down/move/up/key/stop`，把 `App::touch`/`App::key` 返回的 `Effect` 就地
//! 执行（`skyward-net` 的 `web::open_with`/`save`），不碰 recovery 的任何状态。
//!
//! # 范围（v1）
//!
//! **不做完整模式。** 也就是不 chroot Chromium、不装插件包、不走 CDP 截图
//! （`crates/skyward/src/cdp.rs` 整份不在本 crate 里）。界面上点“完整模式”
//! 相关的按钮会收到一个三语提示，程序不崩：`Effect::BrowserPlugin*` 一律只
//! 报一条 toast 并记日志。
//!
//! 其它已知边界：
//!
//! - `SKYWARD_USER_AGENT` 不生效：`skyward-net` 的 UA 是编译期常量
//!   （`crates/skyward-net/src/web.rs:23`），插件不改 vendored 源码。
//! - 没有 supplicant：网络由宿主提供，插件在 `App` 里报一条“已连接”的 WLAN
//!   （`App::online` 是加载页面的前置条件，见 `app.rs:2587`、`app.rs:6990`）。
//! - 软键盘是 `skyward-ui` 自带的，插件只是把触摸转发进去。
//! - 协议 v1 宿主只发 `down/move/up/key/stop`；`swipe/pinch/text/rotate/reload/start`
//!   保留未发，这里照协议解析并忽略（`swipe` 会尽力重放成 down/move…/up）。

// 开发机上（非 unix）只有纯逻辑模块参与编译，帧/字体/worker 那几块用不上，
// 它们的公开项在那里当然“没人用”；真机上是全用到的。
#![cfg_attr(not(unix), allow(dead_code))]

mod dirty;
mod header;
mod input;

#[cfg(unix)]
mod fonts;
#[cfg(unix)]
mod frame;
#[cfg(unix)]
mod info;
#[cfg(unix)]
mod worker;

#[cfg(unix)]
fn main() {
    if let Err(e) = run() {
        // stdout 已经是宿主的 SKYWARD_LOG（协议 §2）。
        println!("skyward-browser: {e:#}");
        std::process::exit(1);
    }
}

#[cfg(not(unix))]
fn main() {
    println!("skyward-browser 是 aarch64-linux-android 程序，不能在开发机上直接跑");
    std::process::exit(1);
}

#[cfg(unix)]
fn run() -> anyhow::Result<()> {
    use anyhow::anyhow;
    use skyward_net::http::Servers;
    use skyward_ui::app::{Effect, Screen};
    use skyward_ui::{App, Canvas};
    use std::sync::{Arc, Mutex};

    let frame_path = var("SKYWARD_PLUGIN_FRAME")
        .ok_or_else(|| anyhow!("SKYWARD_PLUGIN_FRAME 没设：这个程序只能由宿主按协议启动"))?;
    let input_path = var("SKYWARD_PLUGIN_INPUT").ok_or_else(|| anyhow!("SKYWARD_PLUGIN_INPUT 没设"))?;

    let mut frame = frame::Frame::new(std::path::Path::new(&frame_path))?;
    let (w, h) = (frame.width(), frame.height());
    let mut fifo = Fifo::open(std::path::Path::new(&input_path))?;
    let fonts = fonts::load()?;
    let info = info::device(w, h);
    let dns = info::dns();
    println!("plugin: 面板 {w}x{h}，stride {}，DNS {dns:?}", frame.stride());

    let mut app = App::new(Screen::Browser, w, h, px_per_dp(w));
    app.state.lang = info::lang();
    app.state.dark = false;
    // 让页面真的能加载：见文件头的说明。
    app.set_wlan(info::wlan(&dns));

    let servers: Servers = Arc::new(Mutex::new(dns));
    let mut canvas = Canvas::new(w, h);
    let mut reader: Option<worker::Worker> = None;

    // 启动 URL（argv[1] / SKYWARD_URL）：直接交给 worker，App 收到 Opened 就上屏。
    if let Some(url) = info::start_url() {
        println!("plugin: 启动 URL {url}");
        app.state.browser.address = url.clone();
        app.state.browser.url = url.clone();
        let effect = Effect::BrowserOpen { url, cookie: None };
        dispatch(&mut app, &servers, &mut reader, effect, now_ms());
    }

    // 第一帧，然后 ready（publish 会抬 ready 位）。
    draw(&mut app, &mut frame, &mut canvas, &fonts, &info, now_ms());
    println!("plugin: 首帧已发布（{} 个脏矩形）", frame.frames());

    let mut published = 0u64;
    loop {
        let now = now_ms();
        let deadline = app.deadline(now).unwrap_or(now + 1000);
        let wait = deadline.saturating_sub(now).clamp(0, 250) as i32;

        let mut fds = [
            libc::pollfd { fd: fifo.fd(), events: libc::POLLIN, revents: 0 },
            libc::pollfd {
                fd: reader.as_ref().map(|w| w.fd()).unwrap_or(-1),
                events: libc::POLLIN,
                revents: 0,
            },
        ];
        let count = if reader.is_some() { 2 } else { 1 };
        unsafe { libc::poll(fds.as_mut_ptr(), count, wait) };

        let mut changed = false;
        let mut quit = false;
        for command in fifo.read() {
            match command {
                input::Command::Stop => {
                    println!("plugin: 宿主让退出");
                    quit = true;
                    break;
                }
                input::Command::Key { name } if name.eq_ignore_ascii_case("Power") => {
                    println!("plugin: 电源键 → 退出");
                    quit = true;
                    break;
                }
                other => changed |= handle(&mut app, &fonts, other, now),
            }
        }

        if let Some(worker) = &reader {
            for event in worker.events() {
                worker::apply(&mut app, event, now);
                changed = true;
            }
        }
        for effect in app.tick(now) {
            dispatch(&mut app, &servers, &mut reader, effect, now);
            changed = true;
        }

        if quit {
            break;
        }
        if changed || app.take_dirty() {
            let count = draw(&mut app, &mut frame, &mut canvas, &fonts, &info, now);
            published += 1;
            // 每帧一行太吵，只在尺寸/脏矩形异常时看一眼。
            if published % 120 == 0 {
                println!("plugin: 第 {published} 帧，{count} 个脏矩形");
            }
        }
    }

    frame.quit();
    println!("plugin: 退出（共 {} 帧）", frame.frames());
    Ok(())
}

/// 画一帧并发布；返回脏矩形个数。
#[cfg(unix)]
fn draw(
    app: &mut skyward_ui::App,
    frame: &mut frame::Frame,
    canvas: &mut skyward_ui::Canvas,
    fonts: &skyward_ui::Fonts,
    info: &skyward_info::DeviceInfo,
    now: u64,
) -> u32 {
    let clock = clock_text(app.state.time_zone);
    frame.publish(|pixels| {
        let _ = app.frame(fonts, info);
        app.compose(canvas, fonts, info, &clock, now);
        // 通道序就是 Canvas::data 的（协议 §3），整块直拷。
        pixels.copy_from_slice(&canvas.data);
    })
}

/// 状态栏的时钟，`skyward-ui` 的格式化器（`ui.rs:896` 同款）。
#[cfg(unix)]
fn clock_text(zone: usize) -> String {
    use std::time::{SystemTime, UNIX_EPOCH};
    let unix = SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs() as i64).unwrap_or(0);
    skyward_ui::fmt::clock(unix, zone)
}

/// 触摸/按键：喂给 `App`，它自己管手势与软键盘。
#[cfg(unix)]
fn handle(app: &mut skyward_ui::App, fonts: &skyward_ui::Fonts, command: input::Command, now: u64) -> bool {
    use input::Command;
    use skyward_ui::app::Touch;
    match command {
        Command::Down { x, y } => {
            let _ = app.touch(Touch::Down(x, y), fonts, now);
            true
        }
        Command::Move { x, y } => {
            let _ = app.touch(Touch::Move(x, y), fonts, now);
            true
        }
        Command::Up { .. } => {
            let _ = app.touch(Touch::Up, fonts, now);
            true
        }
        Command::Key { name } => match key(&name) {
            Some(k) => {
                let _ = app.key(k, now);
                true
            }
            None => {
                println!("plugin: 键 {name} 在 v0.3.4 的界面里没有对应物，忽略");
                false
            }
        },
        // 协议 v1 不发 swipe；发了就尽力重放成一段 down/move…/up，让 App 自己算惯性。
        Command::Swipe { x0, y0, x1, y1, ms } => {
            swipe(app, fonts, x0, y0, x1, y1, ms, now);
            true
        }
        other => {
            println!("plugin: 忽略命令 {other:?}");
            false
        }
    }
}

#[cfg(unix)]
fn key(name: &str) -> Option<skyward_ui::app::Key> {
    use skyward_ui::app::Key;
    match name {
        // v0.3.4 的 `Key` 只有四个变体；Menu/Escape 都当返回。
        "Back" | "Menu" | "Escape" => Some(Key::Back),
        "VolumeUp" => Some(Key::VolumeUp),
        "VolumeDown" => Some(Key::VolumeDown),
        "Power" => Some(Key::Power),
        _ => None,
    }
}

/// 把一次滑动重放成若干触摸事件：时间戳落在 `[now-ms, now]` 里，这样紧接着的
/// 真实事件时间不会倒流。
#[cfg(unix)]
fn swipe(
    app: &mut skyward_ui::App,
    fonts: &skyward_ui::Fonts,
    x0: f32,
    y0: f32,
    x1: f32,
    y1: f32,
    ms: u32,
    now: u64,
) {
    use skyward_ui::app::Touch;
    const STEPS: u32 = 8;
    let ms = u64::from(ms.clamp(1, 600));
    let base = now.saturating_sub(ms);
    let _ = app.touch(Touch::Down(x0, y0), fonts, base);
    for step in 1..=STEPS {
        let at = base + ms * u64::from(step) / u64::from(STEPS);
        let f = step as f32 / STEPS as f32;
        let _ = app.touch(Touch::Move(x0 + (x1 - x0) * f, y0 + (y1 - y0) * f), fonts, at);
    }
    let _ = app.touch(Touch::Up, fonts, now);
}

/// 页面要的活，就地做。照 `crates/skyward/src/ui.rs:3114-3215` 抄，去掉 recovery 自己的部分。
#[cfg(unix)]
fn dispatch(
    app: &mut skyward_ui::App,
    servers: &skyward_net::http::Servers,
    reader: &mut Option<worker::Worker>,
    effect: skyward_ui::app::Effect,
    now: u64,
) {
    use skyward_ui::app::Effect;
    let start = |task: worker::Task, reader: &mut Option<worker::Worker>, app: &mut skyward_ui::App| {
        if let Some(old) = reader.take() {
            old.stop();
        }
        match worker::Worker::start(task, servers.clone()) {
            Ok(worker) => *reader = Some(worker),
            Err(e) => app.browser_opened(Err(format!("{e:#}"))),
        }
    };
    match effect {
        Effect::BrowserOpen { url, cookie } => start(worker::Task::Open { url, cookie }, reader, app),
        Effect::BrowserSubmit { url, fields, post, cookie } => {
            start(worker::Task::Submit { url, fields, post, cookie }, reader, app)
        }
        Effect::BrowserDownload { url, path, .. } => {
            let task = worker::Task::Save { url, path: std::path::PathBuf::from(path) };
            match worker::Worker::start(task, servers.clone()) {
                Ok(worker) => *reader = Some(worker),
                Err(e) => app.browser_save_ended(Err(format!("{e:#}")), now),
            }
        }
        Effect::StopBrowser => {
            if let Some(worker) = &*reader {
                worker.stop();
            }
        }
        // v1 不做完整模式：只报一条提示，不崩。
        Effect::BrowserPluginInstall { .. }
        | Effect::BrowserPluginStart { .. }
        | Effect::BrowserPluginReload
        | Effect::BrowserPluginStop
        | Effect::BrowserPluginTap { .. }
        | Effect::BrowserPluginPinch { .. }
        | Effect::BrowserPluginText(_)
        | Effect::BrowserPluginRemove { .. } => {
            let notice = app.state.lang.pick([
                "这个版本不带完整模式（Chromium）",
                "這個版本不帶完整模式（Chromium）",
                "This build has no full mode (Chromium)",
            ]);
            println!("plugin: {notice} {effect:?}");
            app.report(notice, now);
        }
        // 别的都是 recovery 的页面要的，插件没有那些页面。
        _ => {}
    }
}

/// 输入 FIFO，只读、非阻塞，自己攒半行（协议 §4）。
#[cfg(unix)]
struct Fifo {
    fd: std::os::fd::OwnedFd,
    pending: String,
}

#[cfg(unix)]
impl Fifo {
    fn open(path: &std::path::Path) -> anyhow::Result<Fifo> {
        use anyhow::Context;
        use std::os::fd::FromRawFd;
        use std::os::unix::fs::OpenOptionsExt;
        use std::os::unix::io::IntoRawFd;
        let file = std::fs::OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NONBLOCK)
            .open(path)
            .with_context(|| format!("打开输入 FIFO {}", path.display()))?;
        Ok(Fifo { fd: unsafe { std::os::fd::OwnedFd::from_raw_fd(file.into_raw_fd()) }, pending: String::new() })
    }

    fn fd(&self) -> std::os::fd::RawFd {
        use std::os::fd::AsRawFd;
        self.fd.as_raw_fd()
    }

    /// 读走现在能读到的，返回其中的完整命令行。
    fn read(&mut self) -> Vec<input::Command> {
        use std::os::fd::AsRawFd;
        let mut buf = [0u8; 4096];
        loop {
            let n = unsafe { libc::read(self.fd.as_raw_fd(), buf.as_mut_ptr().cast(), buf.len()) };
            if n <= 0 {
                break;
            }
            self.pending.push_str(&String::from_utf8_lossy(&buf[..n as usize]));
        }
        let mut out = Vec::new();
        while let Some(at) = self.pending.find('\n') {
            let line: String = self.pending.drain(..=at).collect();
            out.push(input::parse(&line));
        }
        // 半行留着等下一次；但宿主不该发这么长的行，别让它无限涨。
        if self.pending.len() > 64 * 1024 {
            println!("plugin: 输入里有一行超过 64 KiB，丢掉");
            self.pending.clear();
        }
        out
    }
}

#[cfg(unix)]
fn now_ms() -> u64 {
    let mut ts = libc::timespec { tv_sec: 0, tv_nsec: 0 };
    unsafe { libc::clock_gettime(libc::CLOCK_MONOTONIC, &mut ts) };
    (ts.tv_sec as u64) * 1000 + (ts.tv_nsec as u64) / 1_000_000
}

/// dp 比例：面板宽度按 412dp 算（v0.3.4 的 CDP 视口就是 412×915），限在 1..=4。
#[cfg(unix)]
fn px_per_dp(w: u32) -> f32 {
    (w as f32 / 412.0).clamp(1.0, 4.0)
}

#[cfg(unix)]
fn var(name: &str) -> Option<String> {
    match std::env::var(name) {
        Ok(v) if !v.trim().is_empty() => Some(v),
        _ => None,
    }
}
