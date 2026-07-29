# Encoding fixtures

Each file is one lowercase hexadecimal byte sequence followed by LF. Fixtures are source-controlled decoder inputs, never generated test outputs. `cbor-*` exercises Paengi CBOR Profile 1; `envelope-*` exercises Fixed Object Envelope 1.

Valid fixtures must decode and re-encode byte-identically. Malformed fixtures must return the named structured error category without an uncaught exception.
