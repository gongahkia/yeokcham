"""Stable refusal categories for the pure content boundary."""

from enum import Enum


class Code(str, Enum):
    INVALID_ENCODING = "InvalidEncoding"
    UNSUPPORTED = "UnsupportedFormat"
    INVALID_CONTENT = "InvalidContent"
    NONCANONICAL = "NoncanonicalRepresentation"
    INTEGRITY = "IntegrityFailure"
    UNAVAILABLE = "Unavailable"
    RESOURCE_LIMIT = "ResourceLimit"


class ContentError(Exception):
    def __init__(self, code: Code, message: str):
        self.code = code
        super().__init__(message)


def require(condition: bool, code: Code, message: str) -> None:
    if not condition:
        raise ContentError(code, message)
