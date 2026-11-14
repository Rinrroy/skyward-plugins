//! 帧文件头：布局常量与字节读写。
//!
//! 这里只有纯字节操作，所以能在开发机上跑单测；`frame.rs` 只是在它上面加了
//! mmap。布局见 `.tmp/plugin-protocol.md` §3（协议 v1）。

/// 头部字节数，像素从这一偏移开始。
pub const HEADER: usize = 4096;
pub const MAGIC: [u8; 4] = *b"SWFR";
pub const VERSION: u32 = 1;

pub const OFF_MAGIC: usize = 0;
pub const OFF_VERSION: usize = 4;
pub const OFF_WIDTH: usize = 8;
pub const OFF_HEIGHT: usize = 12;
pub const OFF_STRIDE: usize = 16;
pub const OFF_SEQ: usize = 20;
pub const OFF_FLAGS: usize = 24;
pub const OFF_DIRTY_COUNT: usize = 28;
pub const OFF_DIRTY: usize = 32;

/// 脏矩形最多 16 个。
pub const MAX_DIRTY: usize = 16;
/// 每个脏矩形 16 字节：`x, y, w, h` 各一个 u32。
pub const DIRTY_LEN: usize = 16;

pub const FLAG_READY: u32 = 1;
pub const FLAG_QUIT: u32 = 1 << 1;
pub const FLAG_KEYBOARD: u32 = 1 << 2;

/// 一个脏矩形，面板像素坐标。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Rect {
    pub x: u32,
    pub y: u32,
    pub w: u32,
    pub h: u32,
}

impl Rect {
    pub const fn new(x: u32, y: u32, w: u32, h: u32) -> Rect {
        Rect { x, y, w, h }
    }

    /// 能否把两个矩形都装下。
    pub fn union(self, other: Rect) -> Rect {
        let x = self.x.min(other.x);
        let y = self.y.min(other.y);
        let r = (self.x + self.w).max(other.x + other.w);
        let b = (self.y + self.h).max(other.y + other.h);
        Rect::new(x, y, r - x, b - y)
    }

    pub fn is_empty(self) -> bool {
        self.w == 0 || self.h == 0
    }
}

pub fn get_u32(head: &[u8], off: usize) -> u32 {
    let b = &head[off..off + 4];
    u32::from_le_bytes([b[0], b[1], b[2], b[3]])
}

pub fn put_u32(head: &mut [u8], off: usize, v: u32) {
    head[off..off + 4].copy_from_slice(&v.to_le_bytes());
}

/// 宿主写的面板尺寸与行字节数；`None` 表示宿主还没填好。
pub fn panel(head: &[u8]) -> Option<(u32, u32, u32)> {
    if head.len() < HEADER || head[OFF_MAGIC..OFF_MAGIC + 4] != MAGIC {
        return None;
    }
    if get_u32(head, OFF_VERSION) != VERSION {
        return None;
    }
    let (w, h, stride) = (
        get_u32(head, OFF_WIDTH),
        get_u32(head, OFF_HEIGHT),
        get_u32(head, OFF_STRIDE),
    );
    if w == 0 || h == 0 || stride < w.saturating_mul(4) {
        return None;
    }
    Some((w, h, stride))
}

pub fn flags(head: &[u8]) -> u32 {
    get_u32(head, OFF_FLAGS)
}

pub fn has_flag(head: &[u8], bit: u32) -> bool {
    flags(head) & bit != 0
}

pub fn set_flag(head: &mut [u8], bit: u32, on: bool) {
    let f = flags(head);
    let f = if on { f | bit } else { f & !bit };
    put_u32(head, OFF_FLAGS, f);
}

pub fn seq(head: &[u8]) -> u32 {
    get_u32(head, OFF_SEQ)
}

pub fn put_seq(head: &mut [u8], v: u32) {
    put_u32(head, OFF_SEQ, v);
}

/// 读出 dirty 表（按 `dirty_count` 截断，最多 16 个）。
pub fn dirty(head: &[u8]) -> Vec<Rect> {
    let n = (get_u32(head, OFF_DIRTY_COUNT) as usize).min(MAX_DIRTY);
    let mut out = Vec::with_capacity(n);
    for i in 0..n {
        let o = OFF_DIRTY + i * DIRTY_LEN;
        out.push(Rect::new(
            get_u32(head, o),
            get_u32(head, o + 4),
            get_u32(head, o + 8),
            get_u32(head, o + 12),
        ));
    }
    out
}

/// 写 dirty 表并返回实际写入的个数（超过 16 个时并成一个外接矩形）。
pub fn put_dirty(head: &mut [u8], rects: &[Rect]) -> u32 {
    let rects: Vec<Rect> = rects.iter().copied().filter(|r| !r.is_empty()).collect();
    let rects = if rects.len() > MAX_DIRTY {
        vec![rects.iter().copied().fold(rects[0], Rect::union)]
    } else {
        rects
    };
    for (i, r) in rects.iter().enumerate() {
        let o = OFF_DIRTY + i * DIRTY_LEN;
        put_u32(head, o, r.x);
        put_u32(head, o + 4, r.y);
        put_u32(head, o + 8, r.w);
        put_u32(head, o + 12, r.h);
    }
    rects.len() as u32
}

#[cfg(test)]
mod tests {
    use super::*;

    fn host_header(w: u32, h: u32) -> Vec<u8> {
        let mut head = vec![0u8; HEADER];
        head[..4].copy_from_slice(&MAGIC);
        put_u32(&mut head, OFF_VERSION, VERSION);
        put_u32(&mut head, OFF_WIDTH, w);
        put_u32(&mut head, OFF_HEIGHT, h);
        put_u32(&mut head, OFF_STRIDE, w * 4);
        head
    }

    #[test]
    fn offsets_match_the_protocol() {
        // 协议 §3 的偏移表，改这里就是改协议，必须两边一起改。
        assert_eq!((OFF_MAGIC, OFF_VERSION, OFF_WIDTH, OFF_HEIGHT), (0, 4, 8, 12));
        assert_eq!((OFF_STRIDE, OFF_SEQ, OFF_FLAGS, OFF_DIRTY_COUNT), (16, 20, 24, 28));
        assert_eq!(OFF_DIRTY, 32);
        assert_eq!(OFF_DIRTY + MAX_DIRTY * DIRTY_LEN, 288);
        assert_eq!(HEADER, 4096);
    }

    #[test]
    fn panel_reads_a_host_header() {
        let head = host_header(1440, 3200);
        assert_eq!(panel(&head), Some((1440, 3200, 5760)));
    }

    #[test]
    fn panel_rejects_bad_headers() {
        let mut head = host_header(1440, 3200);
        head[0] = b'X';
        assert_eq!(panel(&head), None);

        let mut head = host_header(1440, 3200);
        put_u32(&mut head, OFF_VERSION, 2);
        assert_eq!(panel(&head), None);

        let head = host_header(0, 3200);
        assert_eq!(panel(&head), None);

        let mut head = host_header(1440, 3200);
        put_u32(&mut head, OFF_STRIDE, 100);
        assert_eq!(panel(&head), None);
    }

    #[test]
    fn flags_round_trip() {
        let mut head = vec![0u8; HEADER];
        assert!(!has_flag(&head, FLAG_READY));
        set_flag(&mut head, FLAG_READY, true);
        assert!(has_flag(&head, FLAG_READY));
        set_flag(&mut head, FLAG_QUIT, true);
        assert_eq!(flags(&head), FLAG_READY | FLAG_QUIT);
        set_flag(&mut head, FLAG_READY, false);
        assert_eq!(flags(&head), FLAG_QUIT);
    }

    #[test]
    fn dirty_round_trips() {
        let mut head = vec![0u8; HEADER];
        let n = put_dirty(&mut head, &[Rect::new(0, 10, 1440, 20), Rect::new(5, 5, 1, 1)]);
        assert_eq!(n, 2);
        put_u32(&mut head, OFF_DIRTY_COUNT, n);
        assert_eq!(
            dirty(&head),
            vec![Rect::new(0, 10, 1440, 20), Rect::new(5, 5, 1, 1)]
        );
    }

    #[test]
    fn empty_dirty_means_the_whole_frame() {
        let mut head = vec![0u8; HEADER];
        assert_eq!(put_dirty(&mut head, &[]), 0);
        assert!(dirty(&head).is_empty());
    }

    #[test]
    fn too_many_rects_collapse_into_one() {
        let mut head = vec![0u8; HEADER];
        let rects: Vec<Rect> = (0..20).map(|i| Rect::new(0, i, 10, 1)).collect();
        let n = put_dirty(&mut head, &rects);
        assert_eq!(n, 1);
        put_u32(&mut head, OFF_DIRTY_COUNT, n);
        assert_eq!(dirty(&head), vec![Rect::new(0, 0, 10, 20)]);
    }

    #[test]
    fn zero_sized_rects_are_dropped() {
        let mut head = vec![0u8; HEADER];
        let n = put_dirty(&mut head, &[Rect::new(0, 0, 0, 5), Rect::new(1, 1, 2, 2)]);
        assert_eq!(n, 1);
    }
}
