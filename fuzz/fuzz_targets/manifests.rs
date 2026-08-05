#![no_main]

use libfuzzer_sys::fuzz_target;
use yeokcham_core::{
    BlobManifest, ChunkRecord, ChunkedBlobRecord, MetadataObjectManifest, MetadataObjectRecord,
    TinyBlobAggregation, TinyBlobGroupManifest, WholeBlobRecord,
};

fuzz_target!(|data: &[u8]| {
    let _ = BlobManifest::decode(data, 1 << 20);
    let _ = MetadataObjectManifest::decode(data, 1 << 20);
    let _ = WholeBlobRecord::decode(data, 1 << 20);
    let _ = MetadataObjectRecord::decode(data, 1 << 20);
    let _ = TinyBlobAggregation::decode(data, 4_096, 1 << 20);
    let _ = TinyBlobGroupManifest::decode(data, 1 << 20);
    let _ = ChunkRecord::decode(data, 1 << 20);
    let _ = ChunkedBlobRecord::decode(data, 4_096);
});
