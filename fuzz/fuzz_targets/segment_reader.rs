#![no_main]

use libfuzzer_sys::fuzz_target;
use yeokcham_core::{SegmentReadLimits, SegmentReader};

fuzz_target!(|data: &[u8]| {
    let limits = SegmentReadLimits::new(64, 1 << 20, 1 << 20, 1 << 20, 4_096, 1 << 20)
        .expect("fixed fuzz limits are valid");
    let _ = SegmentReader::decode(data, limits);
});
