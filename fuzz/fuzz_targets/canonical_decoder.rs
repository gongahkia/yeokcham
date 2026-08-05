#![no_main]

use libfuzzer_sys::fuzz_target;
use yeokcham_core::CanonicalDecoder;

fuzz_target!(|data: &[u8]| {
    let mut decoder = CanonicalDecoder::new(data);
    let _ = decoder.read_u8();
    let _ = decoder.read_u16();
    let _ = decoder.read_u32();
    let _ = decoder.read_u64();
    let _ = decoder.read_fixed::<32>();
    let _ = decoder.read_raw_bytes(data.len());
    let _ = decoder.read_byte_string();
    let _ = decoder.finish();
});
