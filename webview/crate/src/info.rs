//! 插件需要的设备与网络事实。
//!
//! `skyward_info::DeviceInfo` 没有 `Default`（`crates/skyward-info/src/lib.rs:24`），
//! 而 `App::compose` 要一份 `&DeviceInfo`；插件只画浏览器的页面，所以这里手工填一份。
//! 域名服务器按协议 §2 的优先级取：`SKYWARD_DNS` → `/proc/net/route` 网关 → 公共 DNS。

use skyward_info::{Boot, Cpu, DeviceInfo, PatchLevel, Storage};
use skyward_net::supplicant::Security;
use skyward_net::wlan::{Joined, Link, Power, Stage, Wlan};
use skyward_ui::Lang;
use skyward_vab::SnapshotState;
use std::net::Ipv4Addr;

/// 宿主没给 DNS、网关也拿不到时的兜底。
const FALLBACK_DNS: [Ipv4Addr; 2] = [Ipv4Addr::new(223, 5, 5, 5), Ipv4Addr::new(119, 29, 29, 29)];

/// 浏览器页面会读的那几项；面板尺寸由宿主给，其余不影响画浏览器。
pub fn device(w: u32, h: u32) -> DeviceInfo {
    DeviceInfo {
        model: String::new(),
        codename: String::new(),
        soc: None,
        cpu: Cpu { cores: 8, max_khz: None },
        ram_kib: 8 * 1024 * 1024,
        panel: Some((w, h)),
        screen: None,
        os_version: None,
        android: None,
        locale: Some(locale()),
        security_patch: Some(PatchLevel { year: 2025, month: 1, day: 1 }),
        kernel: String::from("6.1.0"),
        storage: Storage { total: 0, free: None },
        battery: None,
        slot: None,
        snapshot: SnapshotState::None,
        boot: Boot { unlocked: Some(true), verified: None },
    }
}

/// 界面语言：`SKYWARD_LOCALE` → `LANG` → 简体中文。
pub fn lang() -> Lang {
    for name in ["SKYWARD_LOCALE", "LANG", "LC_ALL"] {
        if let Ok(tag) = std::env::var(name) {
            if let Ok(lang) = Lang::for_locale(&tag) {
                return lang;
            }
        }
    }
    Lang::Hans
}

fn locale() -> String {
    for name in ["SKYWARD_LOCALE", "LANG"] {
        if let Ok(tag) = std::env::var(name) {
            if !tag.trim().is_empty() {
                return tag;
            }
        }
    }
    String::from("zh-CN")
}

/// 协议 §2 的 `SKYWARD_DNS`（逗号分隔），空就退回网关，再退回公共 DNS。
pub fn dns() -> Vec<Ipv4Addr> {
    if let Ok(list) = std::env::var("SKYWARD_DNS") {
        let given: Vec<Ipv4Addr> = list
            .split(',')
            .filter_map(|one| one.trim().parse::<Ipv4Addr>().ok())
            .collect();
        if !given.is_empty() {
            println!("plugin: DNS 来自 SKYWARD_DNS {given:?}");
            return given;
        }
    }
    if let Some(gateway) = gateway() {
        println!("plugin: DNS 退回网关 {gateway}");
        return vec![gateway];
    }
    println!("plugin: DNS 退回公共 {FALLBACK_DNS:?}");
    FALLBACK_DNS.to_vec()
}

/// 伪造一条已连接的 WLAN。
///
/// v0.3.4 的 `App::online`（`crates/skyward-ui/src/app.rs:2587`）要求
/// `wlan.joined.stage` 是 `Stage::Connected`，否则任何一次加载都会跳去 WLAN 页面
/// （`app.rs:6990`）。插件没有 supplicant，网络由宿主提供，所以这里报一条
/// “已连接”的状态，好让浏览器真的去读页面。
pub fn wlan(dns: &[Ipv4Addr]) -> Wlan {
    let router = gateway();
    let address = router.unwrap_or(Ipv4Addr::new(192, 168, 1, 2));
    Wlan {
        power: Power::On,
        networks: Vec::new(),
        joined: Some(Joined {
            ssid: b"skyward".to_vec(),
            name: String::from("skyward"),
            security: Security::Open,
            stage: Stage::Connected(Link {
                address,
                mask: Ipv4Addr::new(255, 255, 255, 0),
                router,
                dns: dns.to_vec(),
                signal: -50,
                frequency: 2412,
                speed: None,
                generation: None,
                mac: String::from("02:00:00:00:00:00"),
                reach: None,
            }),
        }),
    }
}

/// 启动 URL：`argv[1]`（协议 §2），没有再看 `SKYWARD_URL`。
pub fn start_url() -> Option<String> {
    let url = std::env::args().nth(1).filter(|a| !a.trim().is_empty());
    let url = url.or_else(|| std::env::var("SKYWARD_URL").ok());
    url.map(|u| u.trim().to_string()).filter(|u| !u.is_empty())
}

/// `/proc/net/route` 里的默认网关。
fn gateway() -> Option<Ipv4Addr> {
    let text = std::fs::read_to_string("/proc/net/route").ok()?;
    for line in text.lines().skip(1) {
        let mut fields = line.split_whitespace();
        let (_iface, dest, gateway) = (fields.next(), fields.next(), fields.next());
        if dest == Some("00000000") {
            if let Some(ip) = gateway.and_then(hex_v4) {
                return Some(ip);
            }
        }
    }
    None
}

/// `/proc/net/route` 的地址是小端十六进制。
fn hex_v4(hex: &str) -> Option<Ipv4Addr> {
    let raw = u32::from_str_radix(hex, 16).ok()?;
    Some(Ipv4Addr::from(raw.to_le_bytes()))
}
