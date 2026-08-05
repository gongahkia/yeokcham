#![no_main]

use libfuzzer_sys::fuzz_target;
use yeokcham_core::SegmentIndex;

fuzz_target!(|data: &[u8]| {
    let _ = SegmentIndex::decode(data, 4_096, 1 << 20);
});
