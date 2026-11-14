//! 帧文件：mmap，以及不撕裂地发布一帧。
//!
//! 头部布局与写出顺序见协议 §3；这里只把 `header.rs` 的字节操作和
//! `dirty.rs` 的行比较接到真正的共享内存上。

use crate::dirty::Rows;
use crate::header::{self, HEADER};
use anyhow::{anyhow, bail, Context, Result};
use std::fs::OpenOptions;
use std::os::unix::io::AsRawFd;
use std::path::Path;

/// 宿主建好的帧文件，`mmap(MAP_SHARED)` 之后的视图。
pub struct Frame {
    ptr: *mut u8,
    len: usize,
    width: u32,
    height: u32,
    stride: usize,
    rows: Rows,
    frames: u64,
}

impl Frame {
    pub fn new(path: &Path) -> Result<Frame> {
        let file = OpenOptions::new()
            .read(true)
            .write(true)
            .open(path)
            .with_context(|| format!("打开帧文件 {}", path.display()))?;
        let len = file.metadata().with_context(|| format!("读 {} 的大小", path.display()))?.len() as usize;
        let fd = file.as_raw_fd();
        let ptr = unsafe {
            libc::mmap(std::ptr::null_mut(), len, libc::PROT_READ | libc::PROT_WRITE, libc::MAP_SHARED, fd, 0)
        };
        if ptr == libc::MAP_FAILED {
            bail!("mmap {} 失败：{}", path.display(), std::io::Error::last_os_error());
        }
        // mmap 之后 fd 就可以关了，映射还活着。
        drop(file);
        let ptr = ptr.cast::<u8>();

        let head = unsafe { std::slice::from_raw_parts(ptr, HEADER.min(len)) };
        let (width, height, stride) = header::panel(head)
            .ok_or_else(|| anyhow!("{} 的帧头无效（magic/version/尺寸）", path.display()))?;
        let stride = stride as usize;
        if stride != width as usize * 4 {
            bail!("协议要求 stride = width*4，宿主给的是 {stride}");
        }
        let need = HEADER + height as usize * stride;
        if len < need {
            bail!("{} 只有 {len} 字节，{width}x{height} 需要 {need}", path.display());
        }
        Ok(Frame { ptr, len, width, height, stride, rows: Rows::new(width), frames: 0 })
    }

    pub fn width(&self) -> u32 {
        self.width
    }

    pub fn height(&self) -> u32 {
        self.height
    }

    pub fn stride(&self) -> usize {
        self.stride
    }

    /// 已经发布过多少帧。
    pub fn frames(&self) -> u64 {
        self.frames
    }

    fn head(&self) -> &[u8] {
        unsafe { std::slice::from_raw_parts(self.ptr, HEADER) }
    }

    fn head_mut(&mut self) -> &mut [u8] {
        unsafe { std::slice::from_raw_parts_mut(self.ptr, HEADER) }
    }

    fn pixels(&self) -> &[u8] {
        unsafe { std::slice::from_raw_parts(self.ptr.add(HEADER), self.len - HEADER) }
    }

    fn pixels_mut(&mut self) -> &mut [u8] {
        unsafe { std::slice::from_raw_parts_mut(self.ptr.add(HEADER), self.len - HEADER) }
    }

    /// 宿主写在帧头里的 flags。
    pub fn flags(&self) -> u32 {
        header::flags(self.head())
    }

    /// 发布一帧：`draw` 往像素区画，画完比较行哈希、写脏矩形、抬 seq。
    ///
    /// 返回这一帧的脏矩形个数（0 表示宿主按整帧拷，正常不会出现）。
    pub fn publish<F>(&mut self, draw: F) -> u32
    where
        F: FnOnce(&mut [u8]),
    {
        // 1. seq |= 1 起笔，宿主看到奇数就不会上屏。
        let seq = {
            let head = self.head_mut();
            let seq = header::seq(head) | 1;
            header::put_seq(head, seq);
            seq
        };
        // 2. 写像素。
        draw(self.pixels_mut());
        // 3. 写脏表与 dirty_count，抬 ready。像素区用裸指针取，免得和
        // `self.rows` 的可变借用撞车；映射活着、长度在 `new` 里校验过。
        let pixels = unsafe { std::slice::from_raw_parts(self.ptr.add(HEADER), self.len - HEADER) };
        let rects = self.rows.diff(pixels, self.stride, self.height);
        let count = {
            let head = self.head_mut();
            let count = header::put_dirty(head, &rects);
            header::put_u32(head, header::OFF_DIRTY_COUNT, count);
            header::set_flag(head, header::FLAG_READY, true);
            count
        };
        // 4. 最后抬 seq，变偶数，宿主据此上屏。
        let head = self.head_mut();
        header::put_seq(head, seq.wrapping_add(1));
        self.frames += 1;
        count
    }

    /// 告诉宿主插件要退出了（协议 §3 flags 位 1）。
    pub fn quit(&mut self) {
        header::set_flag(self.head_mut(), header::FLAG_QUIT, true);
    }

    /// 尺寸变了就重新开始比较（宿主改帧头时用得上）。
    pub fn resize(&mut self, width: u32, height: u32) {
        self.width = width;
        self.height = height;
        self.rows.resize(width);
    }
}

impl Drop for Frame {
    fn drop(&mut self) {
        unsafe { libc::munmap(self.ptr.cast(), self.len) };
    }
}
