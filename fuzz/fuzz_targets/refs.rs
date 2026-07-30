#![no_main]

use libfuzzer_sys::fuzz_target;
use yeokcham_core::{RefName, RefSnapshot, RefSnapshotReadLimits};

fuzz_target!(|data: &[u8]| {
    let _ = RefName::from_bytes(data);
    let limits =
        RefSnapshotReadLimits::new(4_096, 1 << 20, 4_096).expect("fixed fuzz limits are valid");
    let _ = RefSnapshot::decode(data, limits);
});
