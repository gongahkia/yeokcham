"""Application boundary for a manual private Save through the existing M1b API."""

import os
from dataclasses import dataclass
from typing import Literal

from .errors import Code, ContentError
from .identities import SnapshotId, WorkspaceId
from .object_files import StorageCode, StoreError, io_error
from .observation import (
    DEFAULT_LIMITS,
    ObservationCode,
    ObservationEvidence,
    ObservationLimits,
    ObservationRefused,
    observe_directory,
)
from .private_store import CaptureResult, PrivateStore, WorkspaceState


@dataclass(frozen=True)
class SaveRecorded:
    result: CaptureResult
    observation: ObservationEvidence | None

    @property
    def status(self) -> Literal["completed", "unchanged"]:
        return "completed" if self.result.changed else "unchanged"


@dataclass(frozen=True)
class SaveRefused:
    code: ObservationCode | StorageCode | Code
    detail: str
    snapshot: SnapshotId | None = None
    observation: ObservationEvidence | None = None
    refusal: ObservationRefused | None = None

    @property
    def status(self) -> Literal["refused"]:
        return "refused"


SaveOutcome = SaveRecorded | SaveRefused


def _validate(workspace: WorkspaceId, expected: WorkspaceState, key: bytes) -> None:
    if (
        type(workspace) is not WorkspaceId
        or type(expected) is not WorkspaceState
        or expected.workspace != workspace
    ):
        raise TypeError("exact workspace expectation required")
    if type(key) is not bytes or not 1 <= len(key) <= 128:
        raise ValueError("request key requires 1..128 bytes")


def _failure(
    error: StoreError | ContentError | OSError,
    snapshot: SnapshotId | None,
    evidence: ObservationEvidence | None,
) -> SaveRefused:
    if isinstance(error, OSError):
        error = io_error(error)
    detail = "\n".join([str(error), *getattr(error, "__notes__", [])])
    return SaveRefused(error.code, detail, snapshot, evidence)


def save_directory(
    store: PrivateStore,
    workspace: WorkspaceId,
    root: bytes,
    *,
    expected: WorkspaceState,
    key: bytes,
    limits: ObservationLimits = DEFAULT_LIMITS,
) -> SaveOutcome:
    """Observe a caller-provisioned root and submit a complete detached closure."""
    _validate(workspace, expected, key)
    snapshot = None
    evidence = None
    try:
        store.files.check_binding()

        protected = frozenset(
            (info.st_dev, info.st_ino)
            for fd in (store.files.root, store.files.objects, store.files.locks)
            for info in (os.fstat(fd),)
        )
        with observe_directory(root, limits=limits, _protected=protected) as observed:
            if isinstance(observed, ObservationRefused):
                return SaveRefused(observed.code, observed.detail, refusal=observed)
            snapshot, evidence = observed.snapshot, observed.evidence
            result = store.append_capture(
                workspace, snapshot, observed.resolve, expected=expected, key=key
            )
            return SaveRecorded(result, evidence)
    except (StoreError, ContentError, OSError) as error:
        return _failure(error, snapshot, evidence)


def resume_save(
    store: PrivateStore,
    workspace: WorkspaceId,
    *,
    snapshot: SnapshotId,
    expected: WorkspaceState,
    key: bytes,
) -> SaveOutcome:
    """Retry an existing exact intent through M1b without observing the root again."""
    _validate(workspace, expected, key)
    if type(snapshot) is not SnapshotId:
        raise TypeError("exact snapshot required")
    try:
        if store.lookup_request(workspace, key) is None:
            return SaveRefused(Code.UNAVAILABLE, "original request is absent", snapshot)
        result = store.append_capture(
            workspace, snapshot, lambda _: None, expected=expected, key=key
        )
        return SaveRecorded(result, None)
    except (StoreError, ContentError, OSError) as error:
        return _failure(error, snapshot, None)
