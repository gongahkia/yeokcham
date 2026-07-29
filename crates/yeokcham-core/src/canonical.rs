use crate::{Error, ErrorKind, Result};

/// Builds a deterministic byte sequence from fixed-width fields and byte strings.
///
/// Integers use big-endian fixed-width encodings. Byte strings use a big-endian
/// `u64` length followed by exact bytes. Callers define fixed record field order.
#[derive(Default)]
pub struct CanonicalEncoder {
    bytes: Vec<u8>,
}

impl CanonicalEncoder {
    /// Creates an empty encoder.
    pub fn new() -> Self {
        Self::default()
    }

    /// Appends one byte.
    pub fn write_u8(&mut self, value: u8) {
        self.bytes.push(value);
    }

    /// Appends a fixed-width big-endian unsigned integer.
    pub fn write_u16(&mut self, value: u16) {
        self.bytes.extend_from_slice(&value.to_be_bytes());
    }

    /// Appends a fixed-width big-endian unsigned integer.
    pub fn write_u32(&mut self, value: u32) {
        self.bytes.extend_from_slice(&value.to_be_bytes());
    }

    /// Appends a fixed-width big-endian unsigned integer.
    pub fn write_u64(&mut self, value: u64) {
        self.bytes.extend_from_slice(&value.to_be_bytes());
    }

    /// Appends an exact fixed-width field with no length prefix.
    pub fn write_fixed(&mut self, value: &[u8]) {
        self.bytes.extend_from_slice(value);
    }

    /// Appends a length-delimited byte string.
    pub fn write_byte_string(&mut self, value: &[u8]) {
        self.write_u64(value.len() as u64);
        self.write_fixed(value);
    }

    /// Returns encoded bytes without consuming the encoder.
    pub fn as_bytes(&self) -> &[u8] {
        &self.bytes
    }

    /// Consumes the encoder and returns encoded bytes.
    pub fn into_bytes(self) -> Vec<u8> {
        self.bytes
    }
}

/// Parses deterministic fields from a bounded byte slice without allocating.
pub struct CanonicalDecoder<'a> {
    bytes: &'a [u8],
    offset: usize,
}

impl<'a> CanonicalDecoder<'a> {
    /// Creates a decoder over one already-bounded record byte slice.
    pub const fn new(bytes: &'a [u8]) -> Self {
        Self { bytes, offset: 0 }
    }

    /// Returns unread bytes in the record.
    pub const fn remaining(&self) -> usize {
        self.bytes.len() - self.offset
    }

    /// Reads one byte.
    pub fn read_u8(&mut self) -> Result<u8> {
        Ok(self.take(1)?[0])
    }

    /// Reads a fixed-width big-endian unsigned integer.
    pub fn read_u16(&mut self) -> Result<u16> {
        Ok(u16::from_be_bytes(self.read_fixed()?))
    }

    /// Reads a fixed-width big-endian unsigned integer.
    pub fn read_u32(&mut self) -> Result<u32> {
        Ok(u32::from_be_bytes(self.read_fixed()?))
    }

    /// Reads a fixed-width big-endian unsigned integer.
    pub fn read_u64(&mut self) -> Result<u64> {
        Ok(u64::from_be_bytes(self.read_fixed()?))
    }

    /// Reads an exact fixed-width field with no length prefix.
    pub fn read_fixed<const N: usize>(&mut self) -> Result<[u8; N]> {
        let bytes = self.take(N)?;
        let mut output = [0; N];
        output.copy_from_slice(bytes);
        Ok(output)
    }

    /// Reads a length-delimited byte string without allocating.
    pub fn read_byte_string(&mut self) -> Result<&'a [u8]> {
        let length = usize::try_from(self.read_u64()?).map_err(|_| {
            Error::new(ErrorKind::CorruptData, "canonical record length is invalid")
        })?;
        self.take(length)
    }

    /// Rejects a record with unread trailing bytes.
    pub fn finish(self) -> Result<()> {
        if self.remaining() != 0 {
            return Err(Error::new(
                ErrorKind::CorruptData,
                "canonical record has trailing bytes",
            ));
        }
        Ok(())
    }

    fn take(&mut self, length: usize) -> Result<&'a [u8]> {
        let end = self.offset.checked_add(length).ok_or_else(|| {
            Error::new(ErrorKind::CorruptData, "canonical record length is invalid")
        })?;
        let value = self
            .bytes
            .get(self.offset..end)
            .ok_or_else(|| Error::new(ErrorKind::CorruptData, "canonical record is truncated"))?;
        self.offset = end;
        Ok(value)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn emits_one_canonical_fixed_width_encoding() {
        let mut encoder = CanonicalEncoder::new();
        encoder.write_u8(0x01);
        encoder.write_u16(0x0203);
        encoder.write_u32(0x0405_0607);
        encoder.write_u64(0x0809_0a0b_0c0d_0e0f);
        encoder.write_fixed(&[0x10, 0x11]);
        encoder.write_byte_string(&[0x12, 0x13]);

        assert_eq!(
            encoder.as_bytes(),
            [
                0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e,
                0x0f, 0x10, 0x11, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0x12, 0x13,
            ]
        );
    }

    #[test]
    fn decodes_fixed_width_fields_and_raw_bytes() {
        let mut encoder = CanonicalEncoder::new();
        encoder.write_u8(1);
        encoder.write_u16(2);
        encoder.write_u32(3);
        encoder.write_u64(4);
        encoder.write_fixed(&[5, 6]);
        encoder.write_byte_string(b"\xffref");
        let mut decoder = CanonicalDecoder::new(encoder.as_bytes());

        assert_eq!(decoder.read_u8().expect("u8"), 1);
        assert_eq!(decoder.read_u16().expect("u16"), 2);
        assert_eq!(decoder.read_u32().expect("u32"), 3);
        assert_eq!(decoder.read_u64().expect("u64"), 4);
        assert_eq!(decoder.read_fixed::<2>().expect("fixed"), [5, 6]);
        assert_eq!(decoder.read_byte_string().expect("bytes"), b"\xffref");
        decoder.finish().expect("no trailing bytes");
    }

    #[test]
    fn rejects_truncated_fixed_width_and_byte_strings() {
        let mut fixed = CanonicalDecoder::new(&[0, 1]);
        let fixed_error = fixed.read_u32().expect_err("truncated integer must fail");
        let mut bytes = CanonicalDecoder::new(&[0, 0, 0, 0, 0, 0, 0, 2, 0]);
        let byte_error = bytes
            .read_byte_string()
            .expect_err("truncated byte string must fail");

        assert_eq!(fixed_error.kind(), ErrorKind::CorruptData);
        assert_eq!(byte_error.kind(), ErrorKind::CorruptData);
        assert_eq!(
            fixed_error.public_message(),
            "canonical record is truncated"
        );
        assert_eq!(byte_error.public_message(), "canonical record is truncated");
    }

    #[test]
    fn rejects_overflowing_byte_string_lengths() {
        let encoded_length = u64::MAX.to_be_bytes();
        let mut decoder = CanonicalDecoder::new(&encoded_length);
        let error = decoder
            .read_byte_string()
            .expect_err("overflowing byte string length must fail");

        assert_eq!(error.kind(), ErrorKind::CorruptData);
        assert_eq!(error.public_message(), "canonical record length is invalid");
    }

    #[test]
    fn rejects_trailing_bytes() {
        let decoder = CanonicalDecoder::new(&[0]);
        let error = decoder.finish().expect_err("trailing bytes must fail");

        assert_eq!(error.kind(), ErrorKind::CorruptData);
        assert_eq!(
            error.public_message(),
            "canonical record has trailing bytes"
        );
    }

    #[test]
    fn canonical_types_are_send_and_sync() {
        fn assert_send_sync<T: Send + Sync>() {}

        assert_send_sync::<CanonicalEncoder>();
        assert_send_sync::<CanonicalDecoder<'static>>();
    }
}
