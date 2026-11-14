//! 从负载里找字体。
//!
//! `skyward-ui` 的 `Fonts::load` 只认两个文件路径（`crates/skyward-ui/src/font.rs:254`），
//! 不内置任何字形，所以插件必须自己找到 `MiSansVF.ttf` 与 `KirkMono-Regular.ttf`。
//! 找不到就明确失败：没有字体画不出字，画一屏空白比报错更糟。

use anyhow::{bail, Context, Result};
use skyward_ui::Fonts;
use std::path::{Path, PathBuf};

/// 正文字体（可变字重）。
const SANS: &str = "MiSansVF.ttf";
/// 等宽字体（终端、日志、地址栏）。
const MONO: &str = "KirkMono-Regular.ttf";

/// 按固定顺序找字体并加载。
///
/// 顺序：`$SKYWARD_PLUGIN_FONTS` → `$SKYWARD_PLUGIN_ROOT/opt/skyward/share/fonts/`
/// → `$SKYWARD_PLUGIN_ROOT/fonts/`（与 `webview/build.sh` 的 payload 布局一致）。
pub fn load() -> Result<Fonts> {
    let mut tried = Vec::new();
    for dir in candidates() {
        let sans = dir.join(SANS);
        let mono = dir.join(MONO);
        if sans.is_file() && mono.is_file() {
            println!("plugin: 字体取自 {}", dir.display());
            return Fonts::load(&sans, 0, &mono).with_context(|| format!("加载 {}", dir.display()));
        }
        tried.push(dir.display().to_string());
    }
    bail!(
        "找不到字体：{}。需要在这两个目录之一放 {SANS} 和 {MONO}，或用 SKYWARD_PLUGIN_FONTS 指过去",
        if tried.is_empty() { String::from("（没有可用的目录：SKYWARD_PLUGIN_ROOT 也没设）") } else { tried.join("、") }
    )
}

fn candidates() -> Vec<PathBuf> {
    let mut out = Vec::new();
    if let Some(dir) = var("SKYWARD_PLUGIN_FONTS") {
        out.push(PathBuf::from(dir));
    }
    if let Some(root) = var("SKYWARD_PLUGIN_ROOT") {
        let root = Path::new(&root);
        out.push(root.join("opt/skyward/share/fonts"));
        out.push(root.join("fonts"));
    }
    out
}

fn var(name: &str) -> Option<String> {
    match std::env::var(name) {
        Ok(v) if !v.trim().is_empty() => Some(v),
        _ => None,
    }
}
