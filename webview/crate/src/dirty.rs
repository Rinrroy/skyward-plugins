//! 找出这一帧哪些行真的变了。
//!
//! 整帧 1440×3200×4 ≈ 18 MB，每帧整拷会拖死宿主，所以按行哈希比较上一帧，
//! 把变了的行并成脏矩形发布（协议 §3）。纯逻辑，可在开发机上单测。

use crate::header::Rect;

/// 记住上一帧每一行的哈希。
pub struct Rows {
    width: u32,
    hashes: Vec<u64>,
    /// 还没比过（第一帧），此时整帧都算脏。
    primed: bool,
}

impl Rows {
    pub fn new(width: u32) -> Rows {
        Rows { width, hashes: Vec::new(), primed: false }
    }

    /// 面板尺寸变了就重来（旋转、宿主换分辨率）。
    pub fn resize(&mut self, width: u32) {
        if width != self.width {
            self.width = width;
            self.hashes.clear();
            self.primed = false;
        }
    }

    /// 下一帧当作全新的整帧。
    pub fn forget(&mut self) {
        self.hashes.clear();
        self.primed = false;
    }

    /// 比较 `data`（`height` 行，每行 `stride` 字节，只有前 `width*4` 字节有意义），
    /// 返回变了的行区间，并记住这一帧。
    pub fn diff(&mut self, data: &[u8], stride: usize, height: u32) -> Vec<Rect> {
        let height = height as usize;
        let row = stride.min(data.len());
        if row == 0 || height == 0 {
            return Vec::new();
        }
        self.hashes.resize(height, 0);
        let first = !self.primed;

        let mut rects = Vec::new();
        let mut run: Option<(usize, usize)> = None; // (起行, 行数)
        for y in 0..height {
            let start = y * stride;
            if start >= data.len() {
                break;
            }
            let end = (start + row).min(data.len());
            let hash = hash_row(&data[start..end]);
            let changed = first || hash != self.hashes[y];
            self.hashes[y] = hash;
            match (changed, run) {
                (true, Some((top, n))) if top + n == y => run = Some((top, n + 1)),
                (true, Some((top, n))) => {
                    rects.push(Rect::new(0, top as u32, self.width, n as u32));
                    run = Some((y, 1));
                }
                (true, None) => run = Some((y, 1)),
                (false, Some((top, n))) => {
                    rects.push(Rect::new(0, top as u32, self.width, n as u32));
                    run = None;
                }
                (false, None) => {}
            }
        }
        if let Some((top, n)) = run {
            rects.push(Rect::new(0, top as u32, self.width, n as u32));
        }
        self.primed = true;
        rects
    }
}

/// 一行像素的哈希：按 8 字节块混合，够快也够稳（碰撞只是少刷几行，下一帧会补上）。
fn hash_row(bytes: &[u8]) -> u64 {
    const K: u64 = 0x9e37_79b9_7f4a_7c15;
    let mut h = 0xcbf2_9ce4_8422_2325u64 ^ (bytes.len() as u64).wrapping_mul(K);
    let mut chunks = bytes.chunks_exact(8);
    for c in &mut chunks {
        let v = u64::from_le_bytes([c[0], c[1], c[2], c[3], c[4], c[5], c[6], c[7]]);
        h = (h ^ v).wrapping_mul(K).rotate_left(31);
    }
    let tail = chunks.remainder();
    if !tail.is_empty() {
        let mut v = 0u64;
        for (i, b) in tail.iter().enumerate() {
            v |= (*b as u64) << (i * 8);
        }
        h = (h ^ v).wrapping_mul(K).rotate_left(31);
    }
    h ^= h >> 29;
    h = h.wrapping_mul(K);
    h ^ (h >> 32)
}

#[cfg(test)]
mod tests {
    use super::*;

    const W: u32 = 4;
    const STRIDE: usize = 16;

    fn frame(height: u32) -> Vec<u8> {
        vec![0u8; STRIDE * height as usize]
    }

    #[test]
    fn first_frame_is_whole_dirty() {
        let mut rows = Rows::new(W);
        let data = frame(3);
        assert_eq!(rows.diff(&data, STRIDE, 3), vec![Rect::new(0, 0, W, 3)]);
    }

    #[test]
    fn identical_frames_are_clean() {
        let mut rows = Rows::new(W);
        let data = frame(3);
        rows.diff(&data, STRIDE, 3);
        assert!(rows.diff(&data, STRIDE, 3).is_empty());
    }

    #[test]
    fn one_changed_row() {
        let mut rows = Rows::new(W);
        let mut data = frame(3);
        rows.diff(&data, STRIDE, 3);
        data[STRIDE + 1] = 0xff;
        assert_eq!(rows.diff(&data, STRIDE, 3), vec![Rect::new(0, 1, W, 1)]);
    }

    #[test]
    fn neighbouring_rows_merge() {
        let mut rows = Rows::new(W);
        let mut data = frame(5);
        rows.diff(&data, STRIDE, 5);
        data[STRIDE] = 1;
        data[STRIDE * 2] = 2;
        data[STRIDE * 4] = 3;
        assert_eq!(
            rows.diff(&data, STRIDE, 5),
            vec![Rect::new(0, 1, W, 2), Rect::new(0, 4, W, 1)]
        );
    }

    #[test]
    fn dirty_rects_never_exceed_the_frame() {
        let mut rows = Rows::new(W);
        let mut data = frame(4);
        rows.diff(&data, STRIDE, 4);
        for b in data.iter_mut() {
            *b = 0xaa;
        }
        let rects = rows.diff(&data, STRIDE, 4);
        assert_eq!(rects, vec![Rect::new(0, 0, W, 4)]);
        assert!(rects.iter().all(|r| r.y + r.h <= 4 && r.x + r.w <= W));
    }

    #[test]
    fn resize_forgets_everything() {
        let mut rows = Rows::new(W);
        let data = frame(3);
        rows.diff(&data, STRIDE, 3);
        rows.resize(8);
        assert_eq!(rows.diff(&data, STRIDE, 3), vec![Rect::new(0, 0, 8, 3)]);
    }

    #[test]
    fn forget_republishes_the_whole_frame() {
        let mut rows = Rows::new(W);
        let data = frame(2);
        rows.diff(&data, STRIDE, 2);
        rows.forget();
        assert_eq!(rows.diff(&data, STRIDE, 2), vec![Rect::new(0, 0, W, 2)]);
    }

    #[test]
    fn short_data_does_not_panic() {
        let mut rows = Rows::new(W);
        // 数据比声明的行数短：只比较真实存在的行。
        let rects = rows.diff(&[0u8; 8], STRIDE, 10);
        assert!(rects.iter().all(|r| r.y < 1));
    }

    #[test]
    fn hash_notices_a_single_byte() {
        let a = vec![0u8; 64];
        let mut b = a.clone();
        b[63] = 1;
        assert_ne!(hash_row(&a), hash_row(&b));
        assert_eq!(hash_row(&a), hash_row(&a.clone()));
    }
}
