"""Nominal immutable identities; reinterpretation must be explicit through raw bytes."""

from dataclasses import dataclass
from typing import ClassVar, Self


@dataclass(frozen=True)
class Identity:
    raw: bytes
    size: ClassVar[int] = 32

    def __post_init__(self) -> None:
        if type(self.raw) is not bytes:
            raise TypeError("identity requires immutable bytes")
        if len(self.raw) != self.size:
            raise ValueError(f"{type(self).__name__} requires {self.size} bytes")

    @classmethod
    def from_hex(cls, value: str) -> Self:
        if type(value) is not str or len(value) != cls.size * 2:
            raise ValueError("invalid hex length/type")
        if any(c not in "0123456789abcdefABCDEF" for c in value):
            raise ValueError("invalid hex character")
        return cls(bytes.fromhex(value))

    def hex(self) -> str:
        return self.raw.hex()


class RepositoryId(Identity):
    pass


class WorkspaceId(Identity):
    size = 16


class StoredObjectId(Identity):
    pass


class ContentId(Identity):
    pass


class FullContentId(Identity):
    pass


class SnapshotId(Identity):
    pass


class TreeId(Identity):
    pass


class ChunkId(Identity):
    pass


class RecordId(Identity):
    pass


@dataclass(frozen=True)
class CaptureId:
    workspace: WorkspaceId
    sequence: int

    def __post_init__(self) -> None:
        if type(self.workspace) is not WorkspaceId or type(self.sequence) is not int:
            raise TypeError("capture requires workspace and integer sequence")
        if not 0 <= self.sequence < 2**63:
            raise ValueError("sequence outside nonnegative signed int64")
