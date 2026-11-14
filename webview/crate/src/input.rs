//! 输入 FIFO 的命令解析。
//!
//! 一行一条命令，UTF-8，`\n` 结尾（见协议 §4）。解析是纯函数，所以能在开发机
//! 上单测；`main.rs` 只负责把读到的行交给它。

/// 宿主发来的一条命令。
#[derive(Clone, Debug, PartialEq)]
pub enum Command {
    /// 触摸按下，面板像素。
    Down { x: f32, y: f32 },
    /// 按住移动。
    Move { x: f32, y: f32 },
    /// 抬起；坐标只作参考（v0.3.4 的 `App::Touch::Up` 不带坐标）。
    Up { x: f32, y: f32 },
    /// 宿主已判定为滑动并做过滤波的惯性滑动。
    Swipe { x0: f32, y0: f32, x1: f32, y1: f32, ms: u32 },
    /// 双指缩放，中心是面板像素，`scale > 1` 放大。
    Pinch { cx: f32, cy: f32, scale: f64 },
    /// 实体键，名字见协议 §4（`Back`/`Menu`/`Enter`/…）。
    Key { name: String },
    /// 恢复的软键盘送来的文字，转义已解开。
    Text { text: String },
    /// 面板方向变化，单位度。
    Rotate { degrees: u16 },
    /// 已就绪后进入首页。
    Start,
    /// 重新加载当前页。
    Reload,
    /// 宿主请求退出。
    Stop,
    /// 认不出来的行：按协议忽略，但记日志。
    Unknown { line: String },
}

/// 解析一行（不含结尾换行；带 `\r` 也认）。
pub fn parse(line: &str) -> Command {
    let line = line.trim_end_matches(['\r', '\n']);
    let line = line.trim_start();
    if line.is_empty() {
        return Command::Unknown { line: String::new() };
    }
    let (verb, rest) = match line.find(char::is_whitespace) {
        Some(i) => (&line[..i], line[i..].trim_start()),
        None => (line, ""),
    };
    let words: Vec<&str> = rest.split_whitespace().collect();

    match verb {
        "down" => match pair(&words) {
            Some((x, y)) => Command::Down { x, y },
            None => Command::Unknown { line: line.to_string() },
        },
        "move" => match pair(&words) {
            Some((x, y)) => Command::Move { x, y },
            None => Command::Unknown { line: line.to_string() },
        },
        "up" => {
            // 协议带坐标，但坐标可省：v0.3.4 的 Up 用不上它们。
            let (x, y) = pair(&words).unwrap_or((0.0, 0.0));
            Command::Up { x, y }
        }
        "swipe" => {
            if words.len() < 4 {
                return Command::Unknown { line: line.to_string() };
            }
            match (num(words[0]), num(words[1]), num(words[2]), num(words[3])) {
                (Some(x0), Some(y0), Some(x1), Some(y1)) => Command::Swipe {
                    x0,
                    y0,
                    x1,
                    y1,
                    ms: words.get(4).and_then(|w| num(w)).unwrap_or(0.0).max(0.0) as u32,
                },
                _ => Command::Unknown { line: line.to_string() },
            }
        }
        "pinch" => {
            // 两种写法都收：`pinch <cx> <cy> <scale>` 和 `pinch <scale>`。
            let (cx, cy, scale) = match words.len() {
                1 => (0.0, 0.0, num(words[0])),
                2.. => (
                    num(words[0]).unwrap_or(0.0),
                    num(words[1]).unwrap_or(0.0),
                    num(words[2]),
                ),
                _ => (0.0, 0.0, None),
            };
            match scale {
                Some(scale) if scale > 0.0 => Command::Pinch { cx, cy, scale: f64::from(scale) },
                _ => Command::Unknown { line: line.to_string() },
            }
        }
        "key" => match words.first() {
            Some(name) => Command::Key { name: (*name).to_string() },
            None => Command::Unknown { line: line.to_string() },
        },
        "text" => Command::Text { text: unescape(rest) },
        "rotate" => match words.first().and_then(|w| num(w)) {
            Some(d) if d >= 0.0 => Command::Rotate { degrees: (d as u16) % 360 },
            _ => Command::Unknown { line: line.to_string() },
        },
        "start" => Command::Start,
        "reload" => Command::Reload,
        "stop" => Command::Stop,
        _ => Command::Unknown { line: line.to_string() },
    }
}

fn pair(words: &[&str]) -> Option<(f32, f32)> {
    if words.len() < 2 {
        return None;
    }
    Some((num(words[0])?, num(words[1])?))
}

fn num(word: &str) -> Option<f32> {
    word.parse::<f32>().ok().filter(|v| v.is_finite())
}

/// 解开 `text` 的转义：`\\` → `\`，`\n` → 换行，其余字节原样（协议 §4）。
pub fn unescape(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut chars = text.chars();
    while let Some(c) = chars.next() {
        if c != '\\' {
            out.push(c);
            continue;
        }
        match chars.next() {
            Some('n') => out.push('\n'),
            Some('\\') => out.push('\\'),
            Some(other) => {
                // 不认识的转义原样保留反斜杠，免得吞字节。
                out.push('\\');
                out.push(other);
            }
            None => out.push('\\'),
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn touch_commands() {
        assert_eq!(parse("down 12 34"), Command::Down { x: 12.0, y: 34.0 });
        assert_eq!(parse("move 0.5 3200"), Command::Move { x: 0.5, y: 3200.0 });
        assert_eq!(parse("up 12 34"), Command::Up { x: 12.0, y: 34.0 });
    }

    #[test]
    fn up_tolerates_missing_coords() {
        assert_eq!(parse("up"), Command::Up { x: 0.0, y: 0.0 });
    }

    #[test]
    fn swipe_carries_its_duration() {
        assert_eq!(
            parse("swipe 10 20 30 40 250"),
            Command::Swipe { x0: 10.0, y0: 20.0, x1: 30.0, y1: 40.0, ms: 250 }
        );
        // 时长可省。
        assert_eq!(
            parse("swipe 10 20 30 40"),
            Command::Swipe { x0: 10.0, y0: 20.0, x1: 30.0, y1: 40.0, ms: 0 }
        );
    }

    #[test]
    fn pinch_takes_a_centre_or_just_a_scale() {
        assert_eq!(
            parse("pinch 100 200 1.5"),
            Command::Pinch { cx: 100.0, cy: 200.0, scale: 1.5 }
        );
        assert_eq!(parse("pinch 0.5"), Command::Pinch { cx: 0.0, cy: 0.0, scale: 0.5 });
    }

    #[test]
    fn keys_and_rotate() {
        assert_eq!(parse("key Back"), Command::Key { name: "Back".to_string() });
        assert_eq!(parse("rotate 90"), Command::Rotate { degrees: 90 });
        assert_eq!(parse("rotate 450"), Command::Rotate { degrees: 90 });
    }

    #[test]
    fn text_unescapes() {
        assert_eq!(parse("text hello world"), Command::Text { text: "hello world".to_string() });
        assert_eq!(parse(r"text a\\b\nc"), Command::Text { text: "a\\b\nc".to_string() });
        // 空文字是合法的（清空输入框）。
        assert_eq!(parse("text"), Command::Text { text: String::new() });
    }

    #[test]
    fn bare_commands() {
        assert_eq!(parse("start"), Command::Start);
        assert_eq!(parse("reload"), Command::Reload);
        assert_eq!(parse("stop"), Command::Stop);
    }

    #[test]
    fn crlf_and_padding_are_tolerated() {
        assert_eq!(parse("down 1 2\r\n"), Command::Down { x: 1.0, y: 2.0 });
        assert_eq!(parse("  stop  "), Command::Stop);
    }

    #[test]
    fn bad_input_is_unknown_not_a_panic() {
        for line in [
            "",
            "   ",
            "frobnicate 1 2",
            "down 1",
            "down x 2",
            "swipe 1 2 3",
            "pinch",
            "pinch 0",
            "pinch -1",
            "key",
            "rotate sideways",
        ] {
            assert!(
                matches!(parse(line), Command::Unknown { .. }),
                "{line:?} should be Unknown"
            );
        }
    }

    #[test]
    fn unknown_keeps_the_line_for_the_log() {
        match parse("frobnicate 1 2") {
            Command::Unknown { line } => assert_eq!(line, "frobnicate 1 2"),
            other => panic!("{other:?}"),
        }
    }
}
