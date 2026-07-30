#![no_main]

use std::collections::BTreeMap;

use libfuzzer_sys::fuzz_target;
use yeokcham_core::{
    DeviceId, GitObjectId, GitRefState, HeadState, RefEvent, RefEventReadLimits, RefName,
    RefSnapshot, RefSnapshotReadLimits, RepositoryId,
};

fn ref_event_seed() -> Vec<u8> {
    let repository_id: RepositoryId = "550e8400-e29b-41d4-a716-446655440000"
        .parse()
        .expect("fixed repository ID");
    let device_id: DeviceId = "6ba7b814-9dad-41d1-80b4-00c04fd430c8"
        .parse()
        .expect("fixed device ID");
    let main = RefName::from_bytes(b"refs/heads/main").expect("fixed ref");
    let state = GitRefState::new(
        BTreeMap::from([(main.clone(), GitObjectId::from_bytes([7; GitObjectId::BYTE_LENGTH]))]),
        HeadState::Symbolic(main),
    )
    .expect("fixed state");
    RefEvent::new(repository_id, device_id, 1, [0; 32], [8; 32], state)
        .expect("fixed event")
        .encode()
}

fuzz_target!(|data: &[u8]| {
    let _ = RefName::from_bytes(data);
    let limits =
        RefSnapshotReadLimits::new(4_096, 1 << 20, 4_096).expect("fixed fuzz limits are valid");
    let _ = RefSnapshot::decode(data, limits);
    let event_limits =
        RefEventReadLimits::new(4_096, 1 << 20, 4_096).expect("fixed fuzz limits are valid");
    let _ = RefEvent::decode(data, event_limits);
    let mut structured = ref_event_seed();
    for (index, byte) in data.iter().enumerate() {
        let offset = index % structured.len();
        structured[offset] ^= byte;
    }
    let _ = RefEvent::decode(&structured, event_limits);
});
