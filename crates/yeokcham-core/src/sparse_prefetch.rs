use std::{
    collections::BTreeSet,
    fmt,
    path::{Component, Path, PathBuf},
};

use crate::{Error, ErrorKind, Result};

const MAXIMUM_SPARSE_PATHS: usize = 1_024;
const MAXIMUM_SPARSE_PATH_BYTES: usize = 4_096;
const MAXIMUM_PREFETCH_BYTES: u64 = 4 * 1024 * 1024 * 1024;

/// Default maximum bytes a daemon may prefetch for one repository selection.
pub const DEFAULT_SPARSE_PREFETCH_REPOSITORY_BYTES: u64 = 64 * 1024 * 1024;

/// Default maximum bytes all daemon sparse-prefetch selections may reserve.
pub const DEFAULT_SPARSE_PREFETCH_PROCESS_BYTES: u64 = 256 * 1024 * 1024;

/// Bounded, deterministic sparse-prefetch policy for a local daemon.
#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub struct SparsePrefetchPolicy {
    maximum_repository_bytes: u64,
    maximum_process_bytes: u64,
}

impl SparsePrefetchPolicy {
    /// Creates one sparse-prefetch policy with explicit repository and process budgets.
    pub fn new(maximum_repository_bytes: u64, maximum_process_bytes: u64) -> Result<Self> {
        if maximum_repository_bytes == 0
            || maximum_repository_bytes > maximum_process_bytes
            || maximum_process_bytes > MAXIMUM_PREFETCH_BYTES
        {
            return Err(Error::new(
                ErrorKind::InvalidInput,
                "sparse prefetch policy is invalid",
            ));
        }
        Ok(Self {
            maximum_repository_bytes,
            maximum_process_bytes,
        })
    }

    /// Returns the maximum bytes reserved by one repository selection.
    pub const fn maximum_repository_bytes(self) -> u64 {
        self.maximum_repository_bytes
    }

    /// Returns the maximum bytes reserved by all selections in one daemon.
    pub const fn maximum_process_bytes(self) -> u64 {
        self.maximum_process_bytes
    }
}

impl Default for SparsePrefetchPolicy {
    fn default() -> Self {
        Self {
            maximum_repository_bytes: DEFAULT_SPARSE_PREFETCH_REPOSITORY_BYTES,
            maximum_process_bytes: DEFAULT_SPARSE_PREFETCH_PROCESS_BYTES,
        }
    }
}

/// One explicit current sparse-path selection eligible for prefetch.
#[derive(Clone, Eq, PartialEq)]
pub struct SparsePrefetchSelection {
    sparse_paths: Vec<PathBuf>,
    byte_budget: u64,
}

impl SparsePrefetchSelection {
    /// Validates one exact current sparse-path selection within the policy budget.
    pub fn new(
        paths: impl IntoIterator<Item = PathBuf>,
        byte_budget: u64,
        policy: SparsePrefetchPolicy,
    ) -> Result<Self> {
        if byte_budget == 0 || byte_budget > policy.maximum_repository_bytes() {
            return Err(Error::new(
                ErrorKind::InvalidInput,
                "sparse prefetch byte budget is invalid",
            ));
        }
        let mut sparse_paths = BTreeSet::new();
        for path in paths {
            validate_sparse_path(&path)?;
            if sparse_paths.len() == MAXIMUM_SPARSE_PATHS {
                return Err(Error::new(
                    ErrorKind::Unsupported,
                    "sparse prefetch path limit is exceeded",
                ));
            }
            sparse_paths.insert(path);
        }
        if sparse_paths.is_empty() {
            return Err(Error::new(
                ErrorKind::InvalidInput,
                "sparse prefetch paths are empty",
            ));
        }
        Ok(Self {
            sparse_paths: sparse_paths.into_iter().collect(),
            byte_budget,
        })
    }

    /// Returns exact current sparse paths in deterministic order.
    pub fn sparse_paths(&self) -> &[PathBuf] {
        &self.sparse_paths
    }

    /// Returns the maximum bytes eligible for this selection.
    pub const fn byte_budget(&self) -> u64 {
        self.byte_budget
    }

    /// States that the current `HEAD` is included and no historical prediction is used.
    pub const fn includes_current_head_only(&self) -> bool {
        true
    }
}

impl fmt::Debug for SparsePrefetchSelection {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("SparsePrefetchSelection")
            .field("path_count", &self.sparse_paths.len())
            .field("byte_budget", &self.byte_budget)
            .finish()
    }
}

fn validate_sparse_path(path: &Path) -> Result<()> {
    if path.as_os_str().is_empty()
        || path.is_absolute()
        || path.as_os_str().len() > MAXIMUM_SPARSE_PATH_BYTES
        || path.components().any(|component| {
            matches!(
                component,
                Component::Prefix(_)
                    | Component::RootDir
                    | Component::CurDir
                    | Component::ParentDir
            )
        })
    {
        return Err(Error::new(
            ErrorKind::InvalidInput,
            "sparse prefetch path is invalid",
        ));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn selects_sorted_unique_current_paths_within_budget() {
        let policy = SparsePrefetchPolicy::default();
        let selection = SparsePrefetchSelection::new(
            [
                PathBuf::from("z"),
                PathBuf::from("app"),
                PathBuf::from("app"),
            ],
            8 * 1024 * 1024,
            policy,
        )
        .expect("selection");
        assert_eq!(
            selection.sparse_paths(),
            [PathBuf::from("app"), PathBuf::from("z")]
        );
        assert!(selection.includes_current_head_only());
    }

    #[test]
    fn rejects_unsafe_paths_and_out_of_budget_policy() {
        let policy = SparsePrefetchPolicy::default();
        let path = SparsePrefetchSelection::new([PathBuf::from("../private")], 1, policy)
            .expect_err("unsafe path");
        let budget = SparsePrefetchSelection::new(
            [PathBuf::from("app")],
            DEFAULT_SPARSE_PREFETCH_REPOSITORY_BYTES + 1,
            policy,
        )
        .expect_err("budget");
        let invalid_policy = SparsePrefetchPolicy::new(1, 0).expect_err("policy");
        assert_eq!(path.kind(), ErrorKind::InvalidInput);
        assert_eq!(budget.kind(), ErrorKind::InvalidInput);
        assert_eq!(invalid_policy.kind(), ErrorKind::InvalidInput);
    }

    #[test]
    fn types_are_send_sync_and_redact_paths() {
        fn assert_send_sync<T: Send + Sync>() {}
        let selection = SparsePrefetchSelection::new(
            [PathBuf::from("private-source")],
            1,
            SparsePrefetchPolicy::default(),
        )
        .expect("selection");
        assert_send_sync::<SparsePrefetchPolicy>();
        assert_send_sync::<SparsePrefetchSelection>();
        assert!(!format!("{selection:?}").contains("private-source"));
    }
}
