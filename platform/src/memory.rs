//! The process's weight (docs/adr/0003): its physical footprint, the figure
//! Activity Monitor shows as Memory.

use crate::guarded;

const TASK_VM_INFO: i32 = 22;
const PHYS_FOOTPRINT: usize = 18; // task_vm_info.phys_footprint, counted in u64 words

unsafe extern "C" {
    static mach_task_self_: u32;
    fn task_info(task: u32, flavor: i32, info: *mut u64, count: *mut u32) -> i32;
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
