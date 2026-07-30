use std::{
    num::NonZeroU64,
    sync::atomic::{AtomicU64, Ordering},
};

use crate::{
    Backend, BackendCursor, BackendFuture, BackendKey, BackendListLimits, BackendListPage,
    BackendObjectMetadata, BackendPrefix, BackendPutResult, BackendReadRequest,
    BackendResumablePutStart, BackendUploadSession, Error, ErrorKind, Result,
};

const BACKEND_OPERATION_COUNT: usize = 9;

/// One operation exposed by the backend contract.
#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub enum BackendOperation {
    /// An immutable create-only publication.
    PutIfAbsent,
    /// A bounded object read.
    Get,
    /// An object metadata lookup.
    Head,
    /// A bounded object listing.
    List,
    /// A maintenance-only deletion.
    Delete,
    /// A resumable upload-session creation.
    StartResumablePutIfAbsent,
    /// A resumable upload write.
    WriteResumable,
    /// A resumable upload completion.
    CompleteResumable,
    /// A resumable upload abort.
    AbortResumable,
}

impl BackendOperation {
    const fn index(self) -> usize {
        match self {
            Self::PutIfAbsent => 0,
            Self::Get => 1,
            Self::Head => 2,
            Self::List => 3,
            Self::Delete => 4,
            Self::StartResumablePutIfAbsent => 5,
            Self::WriteResumable => 6,
            Self::CompleteResumable => 7,
            Self::AbortResumable => 8,
        }
    }
}

/// A backend wrapper that fails exactly one configured operation attempt before delegation.
pub struct FaultInjectingBackend<B> {
    inner: B,
    fail_on_call: NonZeroU64,
    operation_count: AtomicU64,
}

impl<B> FaultInjectingBackend<B> {
    /// wraps a backend and fails the configured one-based operation attempt before delegation.
    pub fn new(inner: B, fail_on_call: NonZeroU64) -> Self {
        Self {
            inner,
            fail_on_call,
            operation_count: AtomicU64::new(0),
        }
    }

    /// returns the number of operation attempts observed by this wrapper.
    pub fn operation_count(&self) -> u64 {
        self.operation_count.load(Ordering::Relaxed)
    }

    /// returns the wrapped backend.
    pub fn into_inner(self) -> B {
        self.inner
    }

    fn before_operation(&self) -> Result<()> {
        let previous = self
            .operation_count
            .fetch_update(Ordering::Relaxed, Ordering::Relaxed, |count| {
                count.checked_add(1)
            })
            .map_err(|_| Error::new(ErrorKind::Internal, "backend operation counter overflowed"))?;
        let call = previous.checked_add(1).ok_or_else(|| {
            Error::new(ErrorKind::Internal, "backend operation counter overflowed")
        })?;
        if call == self.fail_on_call.get() {
            return Err(Error::new(
                ErrorKind::Io,
                "injected backend operation failure",
            ));
        }
        Ok(())
    }
}

impl<B> std::fmt::Debug for FaultInjectingBackend<B> {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("FaultInjectingBackend(<redacted>)")
    }
}

impl<B: Backend> Backend for FaultInjectingBackend<B> {
    fn put_if_absent<'a>(
        &'a self,
        key: &'a BackendKey,
        data: &'a [u8],
    ) -> BackendFuture<'a, BackendPutResult> {
        Box::pin(async move {
            self.before_operation()?;
            self.inner.put_if_absent(key, data).await
        })
    }

    fn get<'a>(
        &'a self,
        key: &'a BackendKey,
        request: BackendReadRequest,
    ) -> BackendFuture<'a, Vec<u8>> {
        Box::pin(async move {
            self.before_operation()?;
            self.inner.get(key, request).await
        })
    }

    fn head<'a>(&'a self, key: &'a BackendKey) -> BackendFuture<'a, BackendObjectMetadata> {
        Box::pin(async move {
            self.before_operation()?;
            self.inner.head(key).await
        })
    }

    fn list<'a>(
        &'a self,
        prefix: &'a BackendPrefix,
        cursor: Option<&'a BackendCursor>,
        limits: BackendListLimits,
    ) -> BackendFuture<'a, BackendListPage> {
        Box::pin(async move {
            self.before_operation()?;
            self.inner.list(prefix, cursor, limits).await
        })
    }

    fn delete<'a>(&'a self, key: &'a BackendKey) -> BackendFuture<'a, ()> {
        Box::pin(async move {
            self.before_operation()?;
            self.inner.delete(key).await
        })
    }

    fn start_resumable_put_if_absent<'a>(
        &'a self,
        key: &'a BackendKey,
        total_length: u64,
    ) -> BackendFuture<'a, BackendResumablePutStart> {
        Box::pin(async move {
            self.before_operation()?;
            self.inner
                .start_resumable_put_if_absent(key, total_length)
                .await
        })
    }

    fn write_resumable<'a>(
        &'a self,
        session: &'a BackendUploadSession,
        offset: u64,
        data: &'a [u8],
    ) -> BackendFuture<'a, ()> {
        Box::pin(async move {
            self.before_operation()?;
            self.inner.write_resumable(session, offset, data).await
        })
    }

    fn complete_resumable<'a>(
        &'a self,
        session: &'a BackendUploadSession,
    ) -> BackendFuture<'a, BackendPutResult> {
        Box::pin(async move {
            self.before_operation()?;
            self.inner.complete_resumable(session).await
        })
    }

    fn abort_resumable<'a>(&'a self, session: &'a BackendUploadSession) -> BackendFuture<'a, ()> {
        Box::pin(async move {
            self.before_operation()?;
            self.inner.abort_resumable(session).await
        })
    }
}

/// Immutable counters for one backend operation kind.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct BackendOperationMetrics {
    attempted: u64,
    succeeded: u64,
    failed: u64,
    requested_bytes: u64,
    returned_bytes: u64,
}

impl BackendOperationMetrics {
    /// returns attempted calls, including calls that failed.
    pub const fn attempted(self) -> u64 {
        self.attempted
    }

    /// returns calls that returned success.
    pub const fn succeeded(self) -> u64 {
        self.succeeded
    }

    /// returns calls that returned an error.
    pub const fn failed(self) -> u64 {
        self.failed
    }

    /// returns bytes supplied to put or resumable-write calls.
    pub const fn requested_bytes(self) -> u64 {
        self.requested_bytes
    }

    /// returns bytes returned by successful get calls.
    pub const fn returned_bytes(self) -> u64 {
        self.returned_bytes
    }
}

/// A point-in-time, non-transactional snapshot of backend wrapper counters.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct BackendMetrics {
    operations: [BackendOperationMetrics; BACKEND_OPERATION_COUNT],
}

impl BackendMetrics {
    /// returns counters for one backend operation kind.
    pub const fn operation(self, operation: BackendOperation) -> BackendOperationMetrics {
        self.operations[operation.index()]
    }
}

#[derive(Default)]
struct AtomicBackendOperationMetrics {
    attempted: AtomicU64,
    succeeded: AtomicU64,
    failed: AtomicU64,
    requested_bytes: AtomicU64,
    returned_bytes: AtomicU64,
}

impl AtomicBackendOperationMetrics {
    fn start(&self, requested_bytes: u64) {
        saturating_increment(&self.attempted, 1);
        saturating_increment(&self.requested_bytes, requested_bytes);
    }

    fn finish<T>(&self, result: &Result<T>, returned_bytes: u64) {
        match result {
            Ok(_) => {
                saturating_increment(&self.succeeded, 1);
                saturating_increment(&self.returned_bytes, returned_bytes);
            }
            Err(_) => saturating_increment(&self.failed, 1),
        }
    }

    fn snapshot(&self) -> BackendOperationMetrics {
        BackendOperationMetrics {
            attempted: self.attempted.load(Ordering::Relaxed),
            succeeded: self.succeeded.load(Ordering::Relaxed),
            failed: self.failed.load(Ordering::Relaxed),
            requested_bytes: self.requested_bytes.load(Ordering::Relaxed),
            returned_bytes: self.returned_bytes.load(Ordering::Relaxed),
        }
    }
}

/// A backend wrapper that records bounded operation and byte counters.
pub struct MetricsBackend<B> {
    inner: B,
    operations: [AtomicBackendOperationMetrics; BACKEND_OPERATION_COUNT],
}

impl<B> MetricsBackend<B> {
    /// wraps a backend with saturating in-process counters.
    pub fn new(inner: B) -> Self {
        Self {
            inner,
            operations: std::array::from_fn(|_| AtomicBackendOperationMetrics::default()),
        }
    }

    /// returns a non-transactional snapshot of current counters.
    pub fn metrics(&self) -> BackendMetrics {
        BackendMetrics {
            operations: std::array::from_fn(|index| self.operations[index].snapshot()),
        }
    }

    /// returns the wrapped backend.
    pub fn into_inner(self) -> B {
        self.inner
    }

    fn operation(&self, operation: BackendOperation) -> &AtomicBackendOperationMetrics {
        &self.operations[operation.index()]
    }
}

impl<B> std::fmt::Debug for MetricsBackend<B> {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("MetricsBackend(<redacted>)")
    }
}

impl<B: Backend> Backend for MetricsBackend<B> {
    fn put_if_absent<'a>(
        &'a self,
        key: &'a BackendKey,
        data: &'a [u8],
    ) -> BackendFuture<'a, BackendPutResult> {
        Box::pin(async move {
            let metrics = self.operation(BackendOperation::PutIfAbsent);
            metrics.start(length_as_u64(data.len()));
            let result = self.inner.put_if_absent(key, data).await;
            metrics.finish(&result, 0);
            result
        })
    }

    fn get<'a>(
        &'a self,
        key: &'a BackendKey,
        request: BackendReadRequest,
    ) -> BackendFuture<'a, Vec<u8>> {
        Box::pin(async move {
            let metrics = self.operation(BackendOperation::Get);
            metrics.start(0);
            let result = self.inner.get(key, request).await;
            let returned_bytes = result
                .as_ref()
                .map_or(0, |bytes| length_as_u64(bytes.len()));
            metrics.finish(&result, returned_bytes);
            result
        })
    }

    fn head<'a>(&'a self, key: &'a BackendKey) -> BackendFuture<'a, BackendObjectMetadata> {
        Box::pin(async move {
            let metrics = self.operation(BackendOperation::Head);
            metrics.start(0);
            let result = self.inner.head(key).await;
            metrics.finish(&result, 0);
            result
        })
    }

    fn list<'a>(
        &'a self,
        prefix: &'a BackendPrefix,
        cursor: Option<&'a BackendCursor>,
        limits: BackendListLimits,
    ) -> BackendFuture<'a, BackendListPage> {
        Box::pin(async move {
            let metrics = self.operation(BackendOperation::List);
            metrics.start(0);
            let result = self.inner.list(prefix, cursor, limits).await;
            metrics.finish(&result, 0);
            result
        })
    }

    fn delete<'a>(&'a self, key: &'a BackendKey) -> BackendFuture<'a, ()> {
        Box::pin(async move {
            let metrics = self.operation(BackendOperation::Delete);
            metrics.start(0);
            let result = self.inner.delete(key).await;
            metrics.finish(&result, 0);
            result
        })
    }

    fn start_resumable_put_if_absent<'a>(
        &'a self,
        key: &'a BackendKey,
        total_length: u64,
    ) -> BackendFuture<'a, BackendResumablePutStart> {
        Box::pin(async move {
            let metrics = self.operation(BackendOperation::StartResumablePutIfAbsent);
            metrics.start(0);
            let result = self
                .inner
                .start_resumable_put_if_absent(key, total_length)
                .await;
            metrics.finish(&result, 0);
            result
        })
    }

    fn write_resumable<'a>(
        &'a self,
        session: &'a BackendUploadSession,
        offset: u64,
        data: &'a [u8],
    ) -> BackendFuture<'a, ()> {
        Box::pin(async move {
            let metrics = self.operation(BackendOperation::WriteResumable);
            metrics.start(length_as_u64(data.len()));
            let result = self.inner.write_resumable(session, offset, data).await;
            metrics.finish(&result, 0);
            result
        })
    }

    fn complete_resumable<'a>(
        &'a self,
        session: &'a BackendUploadSession,
    ) -> BackendFuture<'a, BackendPutResult> {
        Box::pin(async move {
            let metrics = self.operation(BackendOperation::CompleteResumable);
            metrics.start(0);
            let result = self.inner.complete_resumable(session).await;
            metrics.finish(&result, 0);
            result
        })
    }

    fn abort_resumable<'a>(&'a self, session: &'a BackendUploadSession) -> BackendFuture<'a, ()> {
        Box::pin(async move {
            let metrics = self.operation(BackendOperation::AbortResumable);
            metrics.start(0);
            let result = self.inner.abort_resumable(session).await;
            metrics.finish(&result, 0);
            result
        })
    }
}

fn saturating_increment(value: &AtomicU64, amount: u64) {
    let _ = value.fetch_update(Ordering::Relaxed, Ordering::Relaxed, |current| {
        Some(current.saturating_add(amount))
    });
}

fn length_as_u64(length: usize) -> u64 {
    u64::try_from(length).unwrap_or(u64::MAX)
}

#[cfg(test)]
mod tests {
    use std::{
        future::Future,
        num::NonZeroU64,
        path::{Path, PathBuf},
        sync::{
            Arc,
            atomic::{AtomicUsize, Ordering},
        },
        task::{Context, Poll, Wake, Waker},
    };

    use uuid::Uuid;

    use super::*;
    use crate::{BackendReadLimits, FilesystemBackend};

    static TEST_COUNTER: AtomicUsize = AtomicUsize::new(0);

    struct TestDirectory(PathBuf);

    impl TestDirectory {
        fn new() -> Self {
            let sequence = TEST_COUNTER.fetch_add(1, Ordering::Relaxed);
            let path = std::env::temp_dir().join(format!(
                "yeokcham-backend-wrapper-test-{}-{sequence}",
                Uuid::new_v4()
            ));
            std::fs::create_dir(&path).expect("create test directory");
            Self(path)
        }

        fn path(&self) -> &Path {
            &self.0
        }
    }

    impl Drop for TestDirectory {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    struct NoopWake;

    impl Wake for NoopWake {
        fn wake(self: Arc<Self>) {}
    }

    fn block_on<T>(future: impl Future<Output = T>) -> T {
        let waker = Waker::from(Arc::new(NoopWake));
        let mut context = Context::from_waker(&waker);
        let mut future = Box::pin(future);
        match future.as_mut().poll(&mut context) {
            Poll::Ready(value) => value,
            Poll::Pending => panic!("backend wrapper future unexpectedly yielded"),
        }
    }

    fn key(bytes: &[u8]) -> BackendKey {
        BackendKey::from_bytes(bytes).expect("key")
    }

    #[test]
    fn fault_wrapper_fails_before_delegation_once() {
        fn assert_send_sync<T: Send + Sync>() {}
        fn assert_backend<T: Backend>() {}

        assert_send_sync::<FaultInjectingBackend<FilesystemBackend>>();
        assert_backend::<FaultInjectingBackend<Box<dyn Backend>>>();
        let directory = TestDirectory::new();
        let backend = FaultInjectingBackend::new(
            FilesystemBackend::create(directory.path().join("backend")).expect("backend"),
            NonZeroU64::new(1).expect("nonzero"),
        );
        let key = key(b"objects/a");
        assert_eq!(
            block_on(backend.put_if_absent(&key, b"secret"))
                .expect_err("injected failure")
                .kind(),
            ErrorKind::Io
        );
        assert_eq!(backend.operation_count(), 1);
        assert_eq!(
            block_on(backend.head(&key))
                .expect_err("inner operation was not called")
                .kind(),
            ErrorKind::NotFound
        );
        assert_eq!(backend.operation_count(), 2);
        assert_eq!(format!("{backend:?}"), "FaultInjectingBackend(<redacted>)");
    }

    #[test]
    fn metrics_wrapper_records_outcomes_and_bytes_without_changing_results() {
        fn assert_send_sync<T: Send + Sync>() {}

        assert_send_sync::<MetricsBackend<FilesystemBackend>>();
        let directory = TestDirectory::new();
        let backend = MetricsBackend::new(
            FilesystemBackend::create(directory.path().join("backend")).expect("backend"),
        );
        let key = key(b"objects/a");
        block_on(backend.put_if_absent(&key, b"secret")).expect("put");
        assert_eq!(
            block_on(backend.put_if_absent(&key, b"changed")).expect("repeat"),
            BackendPutResult::AlreadyExists(BackendObjectMetadata::new(6))
        );
        assert_eq!(
            block_on(backend.get(&key, BackendReadRequest::full(BackendReadLimits::new(6))))
                .expect("get"),
            b"secret"
        );
        assert_eq!(
            block_on(backend.get(&key, BackendReadRequest::full(BackendReadLimits::new(5))))
                .expect_err("limit")
                .kind(),
            ErrorKind::Unsupported
        );

        let metrics = backend.metrics();
        assert_eq!(
            metrics.operation(BackendOperation::PutIfAbsent),
            BackendOperationMetrics {
                attempted: 2,
                succeeded: 2,
                failed: 0,
                requested_bytes: 13,
                returned_bytes: 0,
            }
        );
        assert_eq!(
            metrics.operation(BackendOperation::Get),
            BackendOperationMetrics {
                attempted: 2,
                succeeded: 1,
                failed: 1,
                requested_bytes: 0,
                returned_bytes: 6,
            }
        );
        assert_eq!(format!("{backend:?}"), "MetricsBackend(<redacted>)");
    }
}
