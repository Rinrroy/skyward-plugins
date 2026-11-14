//! 浏览器的后台线程：从 `crates/skyward/src/browser.rs` 抄来的 `Worker`。
//!
//! 为什么是抄而不是 `use`：`crates/skyward/Cargo.toml` 只有 `[[bin]]`，没有
//! library target，别的 crate 够不到 `crate::browser`。抄的只有
//! `Task`/`Event`/`Worker`/`note` 这一小段，`cdp.rs`（完整模式）整份不抄。
//!
//! 相对原版去掉了宿主自己的活：`Install`/`Full*` 那几类任务、以及把日志写进
//! recovery 的 kmsg——插件的 stdout 已经被宿主接到 `SKYWARD_LOG`（协议 §2）。

use anyhow::Result;
use skyward_net::http::{self, Servers};
use skyward_net::web::{self, Opened, Saving};
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, Receiver};
use std::sync::{Arc, Mutex};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

/// 保存进度最多这么频繁地报一次。
const PROGRESS_EVERY: Duration = Duration::from_millis(200);

pub enum Task {
    Open { url: String, cookie: Option<String> },
    Submit { url: String, fields: Vec<(String, String)>, post: bool, cookie: Option<String> },
    Save { url: String, path: PathBuf },
}

pub enum Event {
    Opened(Result<Opened, String>),
    Saved(Saving),
    Ended(Result<u64, String>),
}

pub struct Worker {
    events: Receiver<Event>,
    wake: OwnedFd,
    stop: Arc<AtomicBool>,
    agent: Arc<Mutex<Option<ureq::Agent>>>,
    thread: Option<JoinHandle<()>>,
}

impl Worker {
    pub fn start(task: Task, servers: Servers) -> Result<Worker> {
        let mut fds = [0; 2];
        if unsafe { libc::pipe2(fds.as_mut_ptr(), libc::O_CLOEXEC | libc::O_NONBLOCK) } != 0 {
            return Err(anyhow::anyhow!(
                "建浏览器线程的唤醒管道：{}",
                std::io::Error::last_os_error()
            ));
        }
        let (wake, signal) = unsafe { (OwnedFd::from_raw_fd(fds[0]), OwnedFd::from_raw_fd(fds[1])) };
        let (tx, events) = mpsc::channel();
        let stop = Arc::new(AtomicBool::new(false));
        let agent: Arc<Mutex<Option<ureq::Agent>>> = Arc::new(Mutex::new(None));
        let (stopping, using) = (stop.clone(), agent.clone());
        let thread = thread::Builder::new()
            .name(String::from("browser"))
            .spawn(move || {
                let tell = |event: Event| {
                    let _ = tx.send(event);
                    unsafe { libc::write(signal.as_raw_fd(), [1u8].as_ptr().cast(), 1) };
                };
                let a = http::agent(servers);
                *using.lock().expect("没有别的线程在持这把锁") = Some(a.clone());
                match task {
                    Task::Open { url, cookie } => {
                        note(&format!("open {url}"));
                        let opened = web::open_with(&a, &url, cookie.as_deref()).map_err(|e| format!("{e:#}"));
                        tell(Event::Opened(opened));
                    }
                    Task::Submit { url, fields, post, cookie } => {
                        note(&format!(
                            "submit {} {url} with {} fields",
                            if post { "POST" } else { "GET" },
                            fields.len()
                        ));
                        let opened = web::submit(&a, &url, &fields, post, cookie.as_deref()).map_err(|e| format!("{e:#}"));
                        tell(Event::Opened(opened));
                    }
                    Task::Save { url, path } => {
                        note(&format!("save {url} to {}", path.display()));
                        let mut told = Instant::now() - PROGRESS_EVERY;
                        let mut progress = |saving: Saving| {
                            if told.elapsed() >= PROGRESS_EVERY || saving.total.is_some_and(|t| saving.done >= t) {
                                told = Instant::now();
                                tell(Event::Saved(saving));
                            }
                        };
                        let ended = web::save(&a, &url, &path, &stopping, &mut progress).map_err(|e| {
                            if stopping.load(Ordering::Relaxed) {
                                String::from("stopped as asked")
                            } else {
                                format!("{e:#}")
                            }
                        });
                        tell(Event::Ended(ended));
                    }
                }
            })
            .map_err(|e| anyhow::anyhow!("起浏览器线程：{e}"))?;
        Ok(Worker { events, wake, stop, agent, thread: Some(thread) })
    }

    /// 有事可做时会被 `poll` 唤醒的那个 fd。
    pub fn fd(&self) -> RawFd {
        self.wake.as_raw_fd()
    }

    /// 上次调用以来攒下的事件。
    pub fn events(&self) -> Vec<Event> {
        let mut drain = [0u8; 64];
        while unsafe { libc::read(self.wake.as_raw_fd(), drain.as_mut_ptr().cast(), drain.len()) } > 0 {}
        self.events.try_iter().collect()
    }

    pub fn stop(&self) {
        self.stop.store(true, Ordering::Relaxed);
        if let Some(a) = self.agent.lock().expect("没有别的线程在持这把锁").take() {
            a.shutdown();
        }
    }
}

impl Drop for Worker {
    fn drop(&mut self) {
        if let Some(thread) = self.thread.take() {
            thread.join().expect("浏览器线程不会 panic");
        }
    }
}

/// 把一个事件交给页面，照 `crates/skyward/src/ui.rs:2348-2381` 的做法。
pub fn apply(app: &mut skyward_ui::App, event: Event, now: u64) {
    match event {
        Event::Opened(opened) => app.browser_opened(opened),
        Event::Saved(progress) => app.browser_saved(progress.done, progress.total),
        Event::Ended(ended) => app.browser_save_ended(ended, now),
    }
}

/// 记一行日志：宿主的 stdout 就是 `SKYWARD_LOG`（协议 §2），不用自己开文件。
fn note(line: &str) {
    println!("browser: {line}");
}
