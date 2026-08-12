use std::{
    convert::Infallible,
    io::{self, Read, Write},
    sync::{Arc, Mutex},
};

use mls_rs::{
    identity::{
        basic::{BasicCredential, BasicIdentityProvider},
        SigningIdentity,
    },
    CipherSuite, CipherSuiteProvider, Client, CryptoProvider, ExtensionList, GroupStateStorage,
};
use mls_rs_core::group::{EpochRecord, GroupState};
use mls_rs_crypto_openssl::OpensslCryptoProvider;
use zeroize::Zeroizing;

const IPC_VERSION: u64 = 1;
const IPC_HELLO: u64 = 1;
const IPC_ACKNOWLEDGEMENT: u64 = 2;
const IPC_REQUEST: u64 = 3;
const IPC_RESPONSE: u64 = 4;
const CAPABILITY_MLS: u64 = 1;
const OPERATION_MLS: u64 = 1;
const RESULT_COMPLETED: u64 = 1;
const RESULT_REFUSED: u64 = 2;
const REQUEST_SCHEMA_VERSION: u64 = 1;
const REQUEST_BOOTSTRAP: u64 = 1;
const REQUEST_EXPORTER: u64 = 2;
const GROUP_ID_BYTES: usize = 32;
const DEVICE_ID_BYTES: usize = 32;
const EXPORTER_BYTES: usize = 32;
const MAX_FRAME_BYTES: usize = 64 * 1024;
const MAX_PAYLOAD_BYTES: usize = 48 * 1024;
const MAX_RUNTIME_STATE_BYTES: usize = 24 * 1024;
const MAX_ARRAY_ITEMS: usize = 32;
const EXPORTER_LABEL: &[u8] = b"yeokcham:v2:metadata-exporter:1\0";

#[derive(Clone, Debug, PartialEq, Eq)]
enum Cbor {
    Uint(u64),
    Bytes(Vec<u8>),
    Array(Vec<Cbor>),
}

fn encode_length(major: u8, length: u64, out: &mut Vec<u8>) {
    let prefix = major << 5;
    if length <= 23 {
        out.push(prefix | length as u8);
    } else if length <= u8::MAX as u64 {
        out.extend_from_slice(&[prefix | 24, length as u8]);
    } else if length <= u16::MAX as u64 {
        out.push(prefix | 25);
        out.extend_from_slice(&(length as u16).to_be_bytes());
    } else if length <= u32::MAX as u64 {
        out.push(prefix | 26);
        out.extend_from_slice(&(length as u32).to_be_bytes());
    } else {
        out.push(prefix | 27);
        out.extend_from_slice(&length.to_be_bytes());
    }
}

fn encode(value: &Cbor, out: &mut Vec<u8>) {
    match value {
        Cbor::Uint(value) => encode_length(0, *value, out),
        Cbor::Bytes(value) => {
            encode_length(2, value.len() as u64, out);
            out.extend_from_slice(value);
        }
        Cbor::Array(values) => {
            encode_length(4, values.len() as u64, out);
            for value in values {
                encode(value, out);
            }
        }
    }
}

fn encoded(value: &Cbor) -> Vec<u8> {
    let mut out = Vec::new();
    encode(value, &mut out);
    out
}

fn read_length(input: &[u8], position: &mut usize, additional: u8) -> Result<u64, String> {
    let read = |position: &mut usize, count: usize| -> Result<&[u8], String> {
        let end = position
            .checked_add(count)
            .ok_or_else(|| "CBOR length overflows".to_string())?;
        let value = input
            .get(*position..end)
            .ok_or_else(|| "truncated CBOR length".to_string())?;
        *position = end;
        Ok(value)
    };
    match additional {
        0..=23 => Ok(u64::from(additional)),
        24 => {
            let value = read(position, 1)?[0];
            if value < 24 {
                Err("noncanonical one-byte CBOR length".into())
            } else {
                Ok(u64::from(value))
            }
        }
        25 => {
            let value = u16::from_be_bytes(read(position, 2)?.try_into().unwrap());
            if value <= u8::MAX as u16 {
                Err("noncanonical two-byte CBOR length".into())
            } else {
                Ok(u64::from(value))
            }
        }
        26 => {
            let value = u32::from_be_bytes(read(position, 4)?.try_into().unwrap());
            if value <= u16::MAX as u32 {
                Err("noncanonical four-byte CBOR length".into())
            } else {
                Ok(u64::from(value))
            }
        }
        27 => {
            let value = u64::from_be_bytes(read(position, 8)?.try_into().unwrap());
            if value <= u32::MAX as u64 {
                Err("noncanonical eight-byte CBOR length".into())
            } else {
                Ok(value)
            }
        }
        _ => Err("indefinite or reserved CBOR length".into()),
    }
}

fn decode_one(input: &[u8], position: &mut usize, depth: usize) -> Result<Cbor, String> {
    if depth > 8 {
        return Err("CBOR nesting exceeds bound".into());
    }
    let initial = *input
        .get(*position)
        .ok_or_else(|| "truncated CBOR item".to_string())?;
    *position += 1;
    let major = initial >> 5;
    let length = read_length(input, position, initial & 0x1f)?;
    match major {
        0 => Ok(Cbor::Uint(length)),
        2 => {
            let length = usize::try_from(length).map_err(|_| "CBOR bytes exceed host bounds")?;
            if length > MAX_PAYLOAD_BYTES {
                return Err("CBOR bytes exceed IPC payload bound".into());
            }
            let end = position
                .checked_add(length)
                .ok_or_else(|| "CBOR byte length overflows".to_string())?;
            let value = input
                .get(*position..end)
                .ok_or_else(|| "truncated CBOR bytes".to_string())?
                .to_vec();
            *position = end;
            Ok(Cbor::Bytes(value))
        }
        4 => {
            let length = usize::try_from(length).map_err(|_| "CBOR array exceeds host bounds")?;
            if length > MAX_ARRAY_ITEMS {
                return Err("CBOR array exceeds bound".into());
            }
            let mut values = Vec::with_capacity(length);
            for _ in 0..length {
                values.push(decode_one(input, position, depth + 1)?);
            }
            Ok(Cbor::Array(values))
        }
        _ => Err("unsupported CBOR type".into()),
    }
}

fn decode(input: &[u8]) -> Result<Cbor, String> {
    let mut position = 0;
    let value = decode_one(input, &mut position, 0)?;
    if position != input.len() {
        return Err("trailing CBOR bytes".into());
    }
    if encoded(&value) != input {
        return Err("noncanonical CBOR encoding".into());
    }
    Ok(value)
}

fn array(value: Cbor, name: &str, count: usize) -> Result<Vec<Cbor>, String> {
    match value {
        Cbor::Array(values) if values.len() == count => Ok(values),
        Cbor::Array(_) => Err(format!("{name} has wrong field count")),
        Cbor::Uint(_) | Cbor::Bytes(_) => Err(format!("{name} must be an array")),
    }
}

fn uint(value: Cbor, name: &str) -> Result<u64, String> {
    match value {
        Cbor::Uint(value) => Ok(value),
        Cbor::Bytes(_) | Cbor::Array(_) => Err(format!("{name} must be an unsigned integer")),
    }
}

fn bytes(value: Cbor, name: &str) -> Result<Vec<u8>, String> {
    match value {
        Cbor::Bytes(value) => Ok(value),
        Cbor::Uint(_) | Cbor::Array(_) => Err(format!("{name} must be bytes")),
    }
}

fn check_id(value: Vec<u8>, name: &str) -> Result<Vec<u8>, String> {
    if value.len() == GROUP_ID_BYTES {
        Ok(value)
    } else {
        Err(format!("{name} must contain {GROUP_ID_BYTES} bytes"))
    }
}

#[derive(Clone)]
struct Frame {
    kind: u64,
    body: Cbor,
}

fn decode_frame(input: &[u8]) -> Result<Frame, String> {
    let values = array(decode(input)?, "IPC frame", 4)?;
    let mut fields = values.into_iter();
    let version = uint(fields.next().unwrap(), "IPC version")?;
    let kind = uint(fields.next().unwrap(), "IPC kind")?;
    let body = fields.next().unwrap();
    let features = uint(fields.next().unwrap(), "IPC mandatory features")?;
    if version != IPC_VERSION {
        return Err("unsupported IPC version".into());
    }
    if features != 0 {
        return Err("unsupported IPC mandatory features".into());
    }
    Ok(Frame { kind, body })
}

fn frame(kind: u64, body: Cbor) -> Vec<u8> {
    encoded(&Cbor::Array(vec![
        Cbor::Uint(IPC_VERSION),
        Cbor::Uint(kind),
        body,
        Cbor::Uint(0),
    ]))
}

fn sorted_unique(values: &[u64], name: &str) -> Result<(), String> {
    if values.is_empty() {
        return Err(format!("{name} must not be empty"));
    }
    if values.len() > MAX_ARRAY_ITEMS {
        return Err(format!("{name} exceeds bound"));
    }
    if values.iter().any(|value| *value == 0) {
        return Err(format!("{name} must be positive"));
    }
    if values.windows(2).any(|pair| pair[0] >= pair[1]) {
        return Err(format!("{name} must be sorted and unique"));
    }
    Ok(())
}

fn capabilities(value: Cbor, name: &str) -> Result<Vec<u64>, String> {
    let values = match value {
        Cbor::Array(values) => values,
        Cbor::Uint(_) | Cbor::Bytes(_) => return Err(format!("{name} must be an array")),
    };
    let values = values
        .into_iter()
        .map(|value| uint(value, name))
        .collect::<Result<Vec<_>, _>>()?;
    if values.windows(2).any(|pair| pair[0] >= pair[1]) {
        return Err(format!("{name} must be sorted and unique"));
    }
    if values.iter().any(|value| !matches!(*value, 1..=3)) {
        return Err(format!("{name} contains unsupported capability"));
    }
    Ok(values)
}

fn accept_hello(incoming: Frame) -> Result<(Vec<u8>, Vec<u8>), String> {
    if incoming.kind != IPC_HELLO {
        return Err("expected IPC hello".into());
    }
    let values = array(incoming.body, "IPC hello", 4)?;
    let mut fields = values.into_iter();
    let session = check_id(
        bytes(fields.next().unwrap(), "IPC hello session")?,
        "IPC hello session",
    )?;
    let versions = match fields.next().unwrap() {
        Cbor::Array(values) => values
            .into_iter()
            .map(|value| uint(value, "IPC supported version"))
            .collect::<Result<Vec<_>, _>>()?,
        Cbor::Uint(_) | Cbor::Bytes(_) => {
            return Err("IPC supported versions must be an array".into())
        }
    };
    sorted_unique(&versions, "IPC supported versions")?;
    if !versions.contains(&IPC_VERSION) {
        return Err("no compatible IPC version".into());
    }
    let required = capabilities(fields.next().unwrap(), "IPC required capabilities")?;
    let optional = capabilities(fields.next().unwrap(), "IPC optional capabilities")?;
    if required
        .iter()
        .any(|capability| optional.contains(capability))
    {
        return Err("IPC required and optional capabilities overlap".into());
    }
    if !required.contains(&CAPABILITY_MLS) {
        return Err("MLS capability must be required".into());
    }
    let acknowledgement = frame(
        IPC_ACKNOWLEDGEMENT,
        Cbor::Array(vec![
            Cbor::Bytes(session.clone()),
            Cbor::Uint(IPC_VERSION),
            Cbor::Array(vec![Cbor::Uint(CAPABILITY_MLS)]),
        ]),
    );
    Ok((session, acknowledgement))
}

#[derive(Clone)]
struct Request {
    session: Vec<u8>,
    sequence: u64,
    payload: Vec<u8>,
}

fn decode_request(frame: Frame, expected_session: &[u8]) -> Result<Request, String> {
    if frame.kind != IPC_REQUEST {
        return Err("expected IPC request".into());
    }
    let values = array(frame.body, "IPC request", 4)?;
    let mut fields = values.into_iter();
    let session = check_id(
        bytes(fields.next().unwrap(), "IPC request session")?,
        "IPC request session",
    )?;
    if session != expected_session {
        return Err("stale IPC request session".into());
    }
    let sequence = uint(fields.next().unwrap(), "IPC request sequence")?;
    if sequence != 0 {
        return Err("IPC request sequence must be zero".into());
    }
    let operation = uint(fields.next().unwrap(), "IPC request operation")?;
    if operation != OPERATION_MLS {
        return Err("IPC request operation is not MLS".into());
    }
    let payload = bytes(fields.next().unwrap(), "IPC request payload")?;
    if payload.len() > MAX_PAYLOAD_BYTES {
        return Err("IPC request payload exceeds bound".into());
    }
    Ok(Request {
        session,
        sequence,
        payload,
    })
}

fn response(request: &Request, result: u64, payload: Vec<u8>) -> Vec<u8> {
    frame(
        IPC_RESPONSE,
        Cbor::Array(vec![
            Cbor::Bytes(request.session.clone()),
            Cbor::Uint(request.sequence),
            Cbor::Uint(OPERATION_MLS),
            Cbor::Uint(result),
            Cbor::Bytes(payload),
        ]),
    )
}

#[derive(Clone, Default)]
struct StateStorage(Arc<Mutex<Option<(Vec<u8>, Zeroizing<Vec<u8>>)>>>);

impl StateStorage {
    fn put(&self, group_id: Vec<u8>, state: Vec<u8>) {
        *self.0.lock().unwrap() = Some((group_id, Zeroizing::new(state)));
    }

    fn state(&self) -> Result<Vec<u8>, String> {
        self.0
            .lock()
            .unwrap()
            .as_ref()
            .map(|(_, state)| state.to_vec())
            .ok_or_else(|| "MLS runtime did not persist the created state".to_string())
    }
}

impl GroupStateStorage for StateStorage {
    type Error = Infallible;

    fn state(&self, group_id: &[u8]) -> Result<Option<Zeroizing<Vec<u8>>>, Self::Error> {
        Ok(self
            .0
            .lock()
            .unwrap()
            .as_ref()
            .and_then(|(stored_group, state)| {
                (stored_group.as_slice() == group_id).then(|| state.clone())
            }))
    }

    fn epoch(
        &self,
        _group_id: &[u8],
        _epoch_id: u64,
    ) -> Result<Option<Zeroizing<Vec<u8>>>, Self::Error> {
        Ok(None)
    }

    fn write(
        &mut self,
        state: GroupState,
        _epoch_inserts: Vec<EpochRecord>,
        _epoch_updates: Vec<EpochRecord>,
    ) -> Result<(), Self::Error> {
        *self.0.lock().unwrap() = Some((state.id, state.data));
        Ok(())
    }

    fn max_epoch_id(&self, _group_id: &[u8]) -> Result<Option<u64>, Self::Error> {
        Ok(None)
    }
}

fn create_state(group_id: Vec<u8>, device_id: Vec<u8>) -> Result<Vec<u8>, String> {
    let provider = OpensslCryptoProvider::default();
    let (secret_key, public_key) = provider
        .cipher_suite_provider(CipherSuite::CURVE25519_AES128)
        .ok_or_else(|| "MLS provider lacks the selected cipher suite".to_string())?
        .signature_key_generate()
        .map_err(|error| format!("MLS signing key creation failed: {error}"))?;
    let signing_identity = SigningIdentity::new(
        BasicCredential::new(device_id).into_credential(),
        public_key,
    );
    let storage = StateStorage::default();
    let client = Client::builder()
        .crypto_provider(provider)
        .identity_provider(BasicIdentityProvider::new())
        .group_state_storage(storage.clone())
        .signing_identity(signing_identity, secret_key, CipherSuite::CURVE25519_AES128)
        .build();
    let mut group = client
        .create_group_with_id(
            group_id,
            ExtensionList::default(),
            ExtensionList::default(),
            None,
        )
        .map_err(|error| format!("MLS group creation failed: {error}"))?;
    group
        .write_to_storage()
        .map_err(|error| format!("MLS state persistence failed: {error}"))?;
    let state = storage.state()?;
    if state.is_empty() || state.len() > MAX_RUNTIME_STATE_BYTES {
        return Err("MLS snapshot violates runtime bound".into());
    }
    Ok(state)
}

fn exporter_key(group_id: Vec<u8>, device_id: &[u8], state: Vec<u8>) -> Result<Vec<u8>, String> {
    if state.is_empty() || state.len() > MAX_RUNTIME_STATE_BYTES {
        return Err("MLS snapshot violates runtime bound".into());
    }
    let storage = StateStorage::default();
    storage.put(group_id.clone(), state);
    let client = Client::builder()
        .crypto_provider(OpensslCryptoProvider::default())
        .identity_provider(BasicIdentityProvider::new())
        .group_state_storage(storage)
        .build();
    let group = client
        .load_group(&group_id)
        .map_err(|error| format!("MLS snapshot reload failed: {error}"))?;
    if group.group_id() != group_id.as_slice() {
        return Err("MLS snapshot group ID differs from request".into());
    }
    let members = group.roster().members();
    let initial_member_matches = matches!(members.as_slice(), [member]
        if member
            .signing_identity()
            .credential
            .as_basic()
            .is_some_and(|credential| credential.identifier() == device_id));
    if !initial_member_matches {
        return Err("MLS snapshot does not contain exactly the requested initial device".into());
    }
    let key = group
        .export_secret(EXPORTER_LABEL, &group_id, EXPORTER_BYTES)
        .map_err(|error| format!("MLS exporter derivation failed: {error}"))?;
    Ok(key.as_bytes().to_vec())
}

fn dispatch(payload: &[u8]) -> Result<Vec<u8>, String> {
    let values = array(decode(payload)?, "MLS request", 5)?;
    let mut fields = values.into_iter();
    let version = uint(fields.next().unwrap(), "MLS request version")?;
    if version != REQUEST_SCHEMA_VERSION {
        return Err("unsupported MLS request schema version".into());
    }
    let operation = uint(fields.next().unwrap(), "MLS request operation")?;
    let group_id = check_id(
        bytes(fields.next().unwrap(), "MLS request group ID")?,
        "MLS request group ID",
    )?;
    let device_id = bytes(fields.next().unwrap(), "MLS request device ID")?;
    if device_id.len() != DEVICE_ID_BYTES {
        return Err(format!(
            "MLS request device ID must contain {DEVICE_ID_BYTES} bytes"
        ));
    }
    let state = bytes(fields.next().unwrap(), "MLS request state")?;
    match operation {
        REQUEST_BOOTSTRAP => {
            if !state.is_empty() {
                return Err("MLS bootstrap request state must be empty".into());
            }
            let state = create_state(group_id, device_id)?;
            Ok(encoded(&Cbor::Array(vec![
                Cbor::Uint(REQUEST_SCHEMA_VERSION),
                Cbor::Bytes(state),
            ])))
        }
        REQUEST_EXPORTER => {
            let key = exporter_key(group_id, &device_id, state)?;
            Ok(encoded(&Cbor::Array(vec![
                Cbor::Uint(REQUEST_SCHEMA_VERSION),
                Cbor::Bytes(key),
            ])))
        }
        _ => Err("unsupported MLS request operation".into()),
    }
}

fn read_frame(input: &mut impl Read) -> Result<Vec<u8>, String> {
    let mut header = [0_u8; 4];
    input
        .read_exact(&mut header)
        .map_err(|error| format!("truncated IPC header: {error}"))?;
    let length = u32::from_be_bytes(header) as usize;
    if length > MAX_FRAME_BYTES {
        return Err("oversized IPC frame".into());
    }
    let mut frame = vec![0; length];
    input
        .read_exact(&mut frame)
        .map_err(|error| format!("truncated IPC frame: {error}"))?;
    Ok(frame)
}

fn write_frame(output: &mut impl Write, frame: Vec<u8>) -> Result<(), String> {
    if frame.len() > MAX_FRAME_BYTES {
        return Err("runtime response exceeds IPC frame bound".into());
    }
    output
        .write_all(&(frame.len() as u32).to_be_bytes())
        .and_then(|_| output.write_all(&frame))
        .and_then(|_| output.flush())
        .map_err(|error| format!("IPC write failed: {error}"))
}

fn run(input: &mut impl Read, output: &mut impl Write) -> Result<(), String> {
    let hello = decode_frame(&read_frame(input)?)?;
    let (session, acknowledgement) = accept_hello(hello)?;
    write_frame(output, acknowledgement)?;
    let request = decode_request(decode_frame(&read_frame(input)?)?, &session)?;
    let reply = match dispatch(&request.payload) {
        Ok(payload) => response(&request, RESULT_COMPLETED, payload),
        Err(error) => response(&request, RESULT_REFUSED, error.into_bytes()),
    };
    write_frame(output, reply)
}

fn main() {
    if let Err(error) = run(&mut io::stdin().lock(), &mut io::stdout().lock()) {
        let _ = writeln!(io::stderr(), "secure runtime refusal: {error}");
        std::process::exit(1);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn canonical_cbor_rejects_nonminimal_forms() {
        assert!(decode(&[0x18, 0x17]).is_err());
        assert_eq!(
            decode(&[0x82, 0x01, 0x42, 0x61, 0x62]).unwrap(),
            Cbor::Array(vec![Cbor::Uint(1), Cbor::Bytes(b"ab".to_vec())])
        );
    }

    #[test]
    fn initial_group_reloads_and_derives_one_exporter_key() {
        let group_id = vec![b'g'; GROUP_ID_BYTES];
        let state = create_state(group_id.clone(), vec![b'd'; DEVICE_ID_BYTES]).unwrap();
        assert!(!state.is_empty());
        let device_id = vec![b'd'; DEVICE_ID_BYTES];
        let first = exporter_key(group_id.clone(), &device_id, state.clone()).unwrap();
        let second = exporter_key(group_id, &device_id, state).unwrap();
        assert_eq!(first, second);
        assert_eq!(first.len(), EXPORTER_BYTES);
    }

    #[test]
    fn foreign_group_and_corrupt_state_refuse() {
        let group_id = vec![b'g'; GROUP_ID_BYTES];
        let state = create_state(group_id.clone(), vec![b'd'; DEVICE_ID_BYTES]).unwrap();
        assert!(exporter_key(
            vec![b'x'; GROUP_ID_BYTES],
            &[b'd'; DEVICE_ID_BYTES],
            state.clone()
        )
        .is_err());
        assert!(exporter_key(group_id.clone(), &[b'x'; DEVICE_ID_BYTES], state.clone()).is_err());
        assert!(exporter_key(group_id, &[b'd'; DEVICE_ID_BYTES], vec![0; state.len()]).is_err());
    }
}
