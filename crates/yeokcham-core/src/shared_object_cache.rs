use std::{
    collections::{BTreeMap, VecDeque},
    sync::Mutex,
};

use crate::{Error, ErrorKind, GitObject, GitObjectId, GitObjectKind, RepositoryId, Result};

/// Bounded process-memory cache of already verified Git objects shared by repository handles.
pub struct SharedObjectCache {
    maximum_bytes: usize,
    state: Mutex<SharedObjectCacheState>,
}

struct SharedObjectCacheState {
    entries: BTreeMap<SharedObjectCacheKey, GitObject>,
    order: VecDeque<SharedObjectCacheKey>,
    bytes: usize,
}

#[derive(Clone, Copy, Eq, Ord, PartialEq, PartialOrd)]
struct SharedObjectCacheKey {
    repository_id: RepositoryId,
    object_id: GitObjectId,
}

impl SharedObjectCache {
    /// Creates one cache with a strictly positive byte capacity.
    pub fn new(maximum_bytes: usize) -> Result<Self> {
        if maximum_bytes == 0 {
            return Err(Error::new(
                ErrorKind::InvalidInput,
                "shared object cache capacity is invalid",
            ));
        }
        Ok(Self {
            maximum_bytes,
            state: Mutex::new(SharedObjectCacheState {
                entries: BTreeMap::new(),
                order: VecDeque::new(),
                bytes: 0,
            }),
        })
    }

    /// Returns the maximum verified object-body bytes this cache retains.
    pub const fn maximum_bytes(&self) -> usize {
        self.maximum_bytes
    }

    /// Returns a verified cached object only when its expected kind still matches.
    pub fn get(
        &self,
        repository_id: RepositoryId,
        object_id: GitObjectId,
        kind: GitObjectKind,
    ) -> Option<GitObject> {
        let key = SharedObjectCacheKey {
            repository_id,
            object_id,
        };
        let mut state = self
            .state
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let object = state.entries.get(&key)?;
        if object.kind() != kind || object.verify_id().is_err() {
            let removed = state.entries.remove(&key).expect("cached key exists");
            state.bytes -= removed.data().len();
            state.order.retain(|candidate| *candidate != key);
            return None;
        }
        let object = object.clone();
        state.order.retain(|candidate| *candidate != key);
        state.order.push_back(key);
        Some(object)
    }

    /// Inserts one verified object, evicting least-recently-used entries as needed.
    pub fn insert(&self, repository_id: RepositoryId, object: &GitObject) -> Result<()> {
        object.verify_id()?;
        let bytes = object.data().len();
        if bytes > self.maximum_bytes {
            return Ok(());
        }
        let key = SharedObjectCacheKey {
            repository_id,
            object_id: object.id(),
        };
        let mut state = self
            .state
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        if let Some(previous) = state.entries.remove(&key) {
            state.bytes -= previous.data().len();
            state.order.retain(|candidate| *candidate != key);
        }
        while state.bytes > self.maximum_bytes - bytes {
            let old = state.order.pop_front().expect("cache capacity invariant");
            let removed = state.entries.remove(&old).expect("cache order invariant");
            state.bytes -= removed.data().len();
        }
        state.bytes += bytes;
        state.entries.insert(key, object.clone());
        state.order.push_back(key);
        Ok(())
    }

    /// Returns the current cached object count.
    pub fn object_count(&self) -> usize {
        self.state
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .entries
            .len()
    }

    /// Returns the current cached body-byte count.
    pub fn byte_count(&self) -> usize {
        self.state
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .bytes
    }

    /// Removes every disposable cached object.
    pub fn clear(&self) {
        let mut state = self
            .state
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        state.entries.clear();
        state.order.clear();
        state.bytes = 0;
    }
}

impl std::fmt::Debug for SharedObjectCache {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("SharedObjectCache")
            .field("maximum_bytes", &self.maximum_bytes)
            .field("object_count", &self.object_count())
            .field("byte_count", &self.byte_count())
            .finish()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn object(data: &[u8]) -> GitObject {
        let provisional = GitObject::new(
            GitObjectId::from_bytes([0; GitObjectId::BYTE_LENGTH]),
            GitObjectKind::Blob,
            data.to_vec(),
        );
        GitObject::new(
            provisional.recompute_id(),
            GitObjectKind::Blob,
            data.to_vec(),
        )
    }

    #[test]
    fn verifies_scopes_and_evicts_objects() {
        let cache = SharedObjectCache::new(3).expect("cache");
        let repository = RepositoryId::generate();
        let other = RepositoryId::generate();
        let first = object(b"one");
        let second = object(b"two");
        cache.insert(repository, &first).expect("first");
        assert_eq!(cache.get(other, first.id(), GitObjectKind::Blob), None);
        assert_eq!(
            cache.get(repository, first.id(), GitObjectKind::Blob),
            Some(first.clone())
        );
        cache.insert(repository, &second).expect("second");
        assert_eq!(cache.get(repository, first.id(), GitObjectKind::Blob), None);
        assert_eq!(cache.object_count(), 1);
        cache.clear();
        assert_eq!(cache.byte_count(), 0);
    }

    #[test]
    fn cache_type_is_send_and_sync() {
        fn assert_send_sync<T: Send + Sync>() {}
        assert_send_sync::<SharedObjectCache>();
    }
}
