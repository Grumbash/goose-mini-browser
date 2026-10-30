//! The process's weight (docs/adr/0003): its physical footprint, the figure
//! Activity Monitor shows as Memory; and the Mac's, to weigh it against.

use crate::guarded;

const TASK_VM_INFO: i32 = 22;
const PHYS_FOOTPRINT: usize = 18; // task_vm_info.phys_footprint, counted in u64 words

unsafe extern "C" {
    static mach_task_self_: u32;
    fn task_info(task: u32, flavor: i32, info: *mut u64, count: *mut u32) -> i32;
    fn getrusage(who: i32, usage: *mut Rusage) -> i32;
    fn mach_host_self() -> u32;
    fn host_statistics64(host: u32, flavor: i32, info: *mut VmStatistics64, count: *mut u32)
    -> i32;
    fn sysctlbyname(
        name: *const u8,
        old: *mut u64,
        old_len: *mut usize,
        new: *const u8,
        new_len: usize,
    ) -> i32;
    fn getpagesize() -> i32;
    fn host_statistics(host: u32, flavor: i32, info: *mut u32, count: *mut u32) -> i32;
}

const HOST_CPU_LOAD_INFO: i32 = 3;

const HOST_VM_INFO64: i32 = 4;

/// struct vm_statistics64 (mach/vm_statistics.h): page counts and events.
#[repr(C, align(8))]
#[derive(Default)]
struct VmStatistics64 {
    free_count: u32,
    active_count: u32,
    inactive_count: u32,
    wire_count: u32,
    zero_fill_count: u64,
    reactivations: u64,
    pageins: u64,
    pageouts: u64,
    faults: u64,
    cow_faults: u64,
    lookups: u64,
    hits: u64,
    purges: u64,
    purgeable_count: u32,
    speculative_count: u32,
    decompressions: u64,
    compressions: u64,
    swapins: u64,
    swapouts: u64,
    compressor_page_count: u32,
    throttled_count: u32,
    external_page_count: u32,
    internal_page_count: u32,
    total_uncompressed_pages_in_compressor: u64,
}

const RUSAGE_SELF: i32 = 0;

#[repr(C)]
#[derive(Default)]
struct Timeval {
    sec: i64,
    usec: i32,
}

/// struct rusage: the times, then fourteen counters Tusk doesn't read.
#[repr(C)]
#[derive(Default)]
struct Rusage {
    user: Timeval,
    system: Timeval,
    rest: [i64; 14],
}

/// How many cores the Mac has, to give CPU time as a share of all of them.
#[unsafe(no_mangle)]
pub extern "C" fn tp_cores() -> i64 {
    std::thread::available_parallelism().map_or(1, |n| n.get() as i64)
}

/// The CPU time the process has used, on every thread, in nanoseconds: the
/// readout's CPU is its growth over a while. A negative error code on failure.
#[unsafe(no_mangle)]
pub extern "C" fn tp_cpu_ns() -> i64 {
    let mut u = Rusage::default();
    if unsafe { getrusage(RUSAGE_SELF, &mut u) } != 0 {
        return crate::ERR_ARGUMENT as i64;
    }
    let ns = |t: &Timeval| t.sec * 1_000_000_000 + t.usec as i64 * 1000;
    ns(&u.user) + ns(&u.system)
}

/// The Mac's memory, in bytes: all of it into `total`, and what is in use
/// into `used`, as Activity Monitor counts Memory Used: app memory (anonymous
/// pages that can't be purged), wired and compressed. A negative error code
/// on failure.
#[unsafe(no_mangle)]
pub extern "C" fn tp_mac_memory(total: *mut i64, used: *mut i64) -> i32 {
    guarded(|| {
        if total.is_null() || used.is_null() {
            return Err(crate::ERR_ARGUMENT);
        }
        let mut bytes = 0u64;
        let mut len = std::mem::size_of::<u64>();
        let name = b"hw.memsize\0";
        if unsafe { sysctlbyname(name.as_ptr(), &mut bytes, &mut len, std::ptr::null(), 0) } != 0 {
            return Err(crate::ERR_ARGUMENT);
        }
        let mut v = VmStatistics64::default();
        let mut count = (std::mem::size_of::<VmStatistics64>() / 4) as u32; // in 32-bit words
        if unsafe { host_statistics64(mach_host_self(), HOST_VM_INFO64, &mut v, &mut count) } != 0 {
            return Err(crate::ERR_ARGUMENT);
        }
        let page = unsafe { getpagesize() } as u64;
        let app = (v.internal_page_count as u64).saturating_sub(v.purgeable_count as u64);
        let in_use = (app + v.wire_count as u64 + v.compressor_page_count as u64) * page;
        unsafe {
            total.write_unaligned(bytes as i64);
            used.write_unaligned(in_use.min(bytes) as i64);
        }
        Ok(0)
    })
}

/// The Mac's CPU time since it started, over all its cores, in scheduler
/// ticks: busy (user, system and nice, as Activity Monitor's CPU Load
/// counts it) into `busy`, and in all into `total`. The Mac's load over a
/// while is the growth of one over the growth of the other.
#[unsafe(no_mangle)]
pub extern "C" fn tp_mac_cpu(busy: *mut i64, total: *mut i64) -> i32 {
    guarded(|| {
        if busy.is_null() || total.is_null() {
            return Err(crate::ERR_ARGUMENT);
        }
        // host_cpu_load_info: user, system, idle and nice ticks.
        let mut ticks = [0u32; 4];
        let mut count = 4u32;
        if unsafe {
            host_statistics(
                mach_host_self(),
                HOST_CPU_LOAD_INFO,
                ticks.as_mut_ptr(),
                &mut count,
            )
        } != 0
        {
            return Err(crate::ERR_ARGUMENT);
        }
        let [user, system, idle, nice] = ticks.map(|t| t as i64);
        unsafe {
            busy.write_unaligned(user + system + nice);
            total.write_unaligned(user + system + idle + nice);
        }
        Ok(0)
    })
}

/// The process's physical footprint in bytes, or a negative error code.
#[unsafe(no_mangle)]
pub extern "C" fn tp_memory_footprint() -> i64 {
    let code = guarded(|| Ok(0));
    if code != 0 {
        return code as i64;
    }
    let mut info = [0u64; 64];
    let mut count = (std::mem::size_of_val(&info) / 4) as u32; // in 32-bit words
    let r = unsafe { task_info(mach_task_self_, TASK_VM_INFO, info.as_mut_ptr(), &mut count) };
    if r != 0 || (count as usize) < (PHYS_FOOTPRINT + 1) * 2 {
        return crate::ERR_ARGUMENT as i64;
    }
    info[PHYS_FOOTPRINT] as i64
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_macs_memory_is_some_of_it_used() {
        let (mut total, mut used) = (0i64, 0i64);
        assert_eq!(tp_mac_memory(&mut total, &mut used), 0);
        assert!(total >= 8 << 30, "{total}");
        // At least this process, and never more than there is.
        assert!(
            used >= tp_memory_footprint() && used <= total,
            "{used} of {total}"
        );
        assert_eq!(
            tp_mac_memory(std::ptr::null_mut(), &mut used),
            crate::ERR_ARGUMENT
        );
    }

    #[test]
    fn the_macs_cpu_ticks_grow_and_some_are_busy() {
        let (mut busy, mut total) = (0i64, 0i64);
        assert_eq!(tp_mac_cpu(&mut busy, &mut total), 0);
        assert!(busy > 0 && busy < total, "{busy} of {total}");
        let spin = std::time::Instant::now();
        while spin.elapsed() < std::time::Duration::from_millis(100) {
            std::hint::black_box(0);
        }
        let (mut busy2, mut total2) = (0i64, 0i64);
        assert_eq!(tp_mac_cpu(&mut busy2, &mut total2), 0);
        assert!(busy2 > busy && total2 > total);
        assert_eq!(
            tp_mac_cpu(&mut busy, std::ptr::null_mut()),
            crate::ERR_ARGUMENT
        );
    }

    #[test]
    fn the_mac_has_cores() {
        assert!((1..=1024).contains(&tp_cores()));
    }

    #[test]
    fn cpu_time_grows_with_work() {
        assert_eq!(std::mem::size_of::<Rusage>(), 144);
        let before = tp_cpu_ns();
        let start = std::time::Instant::now();
        let mut x = 0u64;
        while start.elapsed().as_millis() < 30 {
            x = std::hint::black_box(x.wrapping_mul(31).wrapping_add(7));
        }
        let used = tp_cpu_ns() - before;
        assert!((20_000_000..10_000_000_000).contains(&used), "{used}");
    }

    #[test]
    fn the_footprint_is_this_process_size() {
        let before = tp_memory_footprint();
        assert!(before > 1 << 20 && before < 1 << 34, "{before}");
        // While this process holds a touched block of 256 MiB, its footprint
        // is at least that. (Growth isn't a fair check: tests on other
        // threads free as much meanwhile.)
        let block = std::hint::black_box(vec![1u8; 256 << 20]);
        let after = tp_memory_footprint();
        assert!(after >= 256 << 20, "{before} -> {after}");
        drop(block);
    }
}
