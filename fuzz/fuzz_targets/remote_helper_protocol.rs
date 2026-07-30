#![no_main]

use libfuzzer_sys::fuzz_target;
use yeokcham_cli::remote_helper_protocol::parse_command;

fuzz_target!(|data: &[u8]| {
    let _ = parse_command(data);
});
