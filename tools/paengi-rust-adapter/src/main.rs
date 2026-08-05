use std::io::{self, Read};

use tree_sitter::{Node, Parser};

const PROTOCOL_VERSION: i64 = 1;
const ADAPTER_VERSION: &str = "0.1.0";
const TREE_SITTER_VERSION: &str = "0.26.11";
const RUST_GRAMMAR_VERSION: &str = "0.24.2";
const MAX_REQUEST_BYTES: usize = 4 * 1024 * 1024;
const MAX_RESPONSE_BYTES: usize = 4 * 1024 * 1024;
const MAX_FILES: usize = 4_096;
const MAX_SOURCE_BYTES: usize = 4 * 1024 * 1024;
const MAX_ITEMS: usize = 4_096;
const MAX_DIAGNOSTICS: usize = 4_096;
const MAX_PATH_BYTES: usize = 4 * 1024;
const MAX_NAME_BYTES: usize = 4 * 1024;

#[derive(Debug)]
struct AdapterError {
    code: &'static str,
    message: String,
}

impl AdapterError {
    fn new(code: &'static str, message: impl Into<String>) -> Self {
        Self {
            code,
            message: message.into(),
        }
    }
}

#[derive(Clone, Debug)]
enum Json {
    Null,
    Bool,
    Number(String),
    String(String),
    Array(Vec<Json>),
    Object(Vec<(String, Json)>),
}

struct JsonParser<'a> {
    bytes: &'a [u8],
    position: usize,
}

impl<'a> JsonParser<'a> {
    fn parse(source: &'a str) -> Result<Json, AdapterError> {
        let mut parser = Self {
            bytes: source.as_bytes(),
            position: 0,
        };
        let value = parser.value()?;
        parser.skip_whitespace();
        if parser.position != parser.bytes.len() {
            return Err(AdapterError::new(
                "malformed-request",
                "trailing JSON bytes",
            ));
        }
        Ok(value)
    }

    fn skip_whitespace(&mut self) {
        while matches!(
            self.bytes.get(self.position),
            Some(b' ' | b'\n' | b'\r' | b'\t')
        ) {
            self.position += 1;
        }
    }

    fn value(&mut self) -> Result<Json, AdapterError> {
        self.skip_whitespace();
        match self.bytes.get(self.position) {
            Some(b'n') => self.literal(b"null", Json::Null),
            Some(b't') => self.literal(b"true", Json::Bool),
            Some(b'f') => self.literal(b"false", Json::Bool),
            Some(b'"') => self.string().map(Json::String),
            Some(b'[') => self.array(),
            Some(b'{') => self.object(),
            Some(b'-' | b'0'..=b'9') => self.number(),
            Some(_) => Err(AdapterError::new("malformed-request", "invalid JSON value")),
            None => Err(AdapterError::new(
                "malformed-request",
                "unexpected end of JSON",
            )),
        }
    }

    fn literal(&mut self, token: &[u8], value: Json) -> Result<Json, AdapterError> {
        if self.bytes.get(self.position..self.position + token.len()) == Some(token) {
            self.position += token.len();
            Ok(value)
        } else {
            Err(AdapterError::new(
                "malformed-request",
                "invalid JSON literal",
            ))
        }
    }

    fn string(&mut self) -> Result<String, AdapterError> {
        if self.bytes.get(self.position) != Some(&b'"') {
            return Err(AdapterError::new(
                "malformed-request",
                "expected JSON string",
            ));
        }
        self.position += 1;
        let mut output = Vec::new();
        while let Some(byte) = self.bytes.get(self.position).copied() {
            self.position += 1;
            match byte {
                b'"' => {
                    return String::from_utf8(output).map_err(|_| {
                        AdapterError::new("malformed-request", "invalid UTF-8 JSON string")
                    });
                }
                b'\\' => self.escape(&mut output)?,
                0..=0x1f => {
                    return Err(AdapterError::new(
                        "malformed-request",
                        "JSON control byte in string",
                    ));
                }
                _ => output.push(byte),
            }
        }
        Err(AdapterError::new(
            "malformed-request",
            "unterminated JSON string",
        ))
    }

    fn escape(&mut self, output: &mut Vec<u8>) -> Result<(), AdapterError> {
        let byte =
            self.bytes.get(self.position).copied().ok_or_else(|| {
                AdapterError::new("malformed-request", "unterminated JSON escape")
            })?;
        self.position += 1;
        match byte {
            b'"' | b'\\' | b'/' => output.push(byte),
            b'b' => output.push(0x08),
            b'f' => output.push(0x0c),
            b'n' => output.push(b'\n'),
            b'r' => output.push(b'\r'),
            b't' => output.push(b'\t'),
            b'u' => self.unicode_escape(output)?,
            _ => {
                return Err(AdapterError::new(
                    "malformed-request",
                    "invalid JSON escape",
                ))
            }
        }
        Ok(())
    }

    fn unicode_escape(&mut self, output: &mut Vec<u8>) -> Result<(), AdapterError> {
        let first = self.hex_codepoint()?;
        let codepoint = if (0xd800..=0xdbff).contains(&first) {
            if self.bytes.get(self.position..self.position + 2) != Some(b"\\u") {
                return Err(AdapterError::new(
                    "malformed-request",
                    "unpaired JSON surrogate",
                ));
            }
            self.position += 2;
            let second = self.hex_codepoint()?;
            if !(0xdc00..=0xdfff).contains(&second) {
                return Err(AdapterError::new(
                    "malformed-request",
                    "invalid JSON surrogate pair",
                ));
            }
            0x10000 + ((first - 0xd800) << 10) + (second - 0xdc00)
        } else if (0xdc00..=0xdfff).contains(&first) {
            return Err(AdapterError::new(
                "malformed-request",
                "unpaired JSON surrogate",
            ));
        } else {
            first
        };
        let character = char::from_u32(codepoint)
            .ok_or_else(|| AdapterError::new("malformed-request", "invalid JSON codepoint"))?;
        let mut encoded = [0; 4];
        output.extend_from_slice(character.encode_utf8(&mut encoded).as_bytes());
        Ok(())
    }

    fn hex_codepoint(&mut self) -> Result<u32, AdapterError> {
        let digits = self
            .bytes
            .get(self.position..self.position + 4)
            .ok_or_else(|| AdapterError::new("malformed-request", "short JSON unicode escape"))?;
        self.position += 4;
        let mut value = 0u32;
        for digit in digits {
            let nibble = match digit {
                b'0'..=b'9' => u32::from(digit - b'0'),
                b'a'..=b'f' => u32::from(10 + digit - b'a'),
                b'A'..=b'F' => u32::from(10 + digit - b'A'),
                _ => {
                    return Err(AdapterError::new(
                        "malformed-request",
                        "invalid JSON unicode escape",
                    ))
                }
            };
            value = (value << 4) | nibble;
        }
        Ok(value)
    }

    fn array(&mut self) -> Result<Json, AdapterError> {
        self.position += 1;
        let mut values = Vec::new();
        self.skip_whitespace();
        if self.bytes.get(self.position) == Some(&b']') {
            self.position += 1;
            return Ok(Json::Array(values));
        }
        loop {
            values.push(self.value()?);
            self.skip_whitespace();
            match self.bytes.get(self.position) {
                Some(b',') => self.position += 1,
                Some(b']') => {
                    self.position += 1;
                    return Ok(Json::Array(values));
                }
                _ => {
                    return Err(AdapterError::new(
                        "malformed-request",
                        "invalid JSON array separator",
                    ))
                }
            }
        }
    }

    fn object(&mut self) -> Result<Json, AdapterError> {
        self.position += 1;
        let mut fields = Vec::new();
        self.skip_whitespace();
        if self.bytes.get(self.position) == Some(&b'}') {
            self.position += 1;
            return Ok(Json::Object(fields));
        }
        loop {
            self.skip_whitespace();
            let key = self.string()?;
            if fields.iter().any(|(existing, _)| existing == &key) {
                return Err(AdapterError::new(
                    "malformed-request",
                    "duplicate JSON object key",
                ));
            }
            self.skip_whitespace();
            if self.bytes.get(self.position) != Some(&b':') {
                return Err(AdapterError::new(
                    "malformed-request",
                    "missing JSON object colon",
                ));
            }
            self.position += 1;
            let value = self.value()?;
            fields.push((key, value));
            self.skip_whitespace();
            match self.bytes.get(self.position) {
                Some(b',') => self.position += 1,
                Some(b'}') => {
                    self.position += 1;
                    return Ok(Json::Object(fields));
                }
                _ => {
                    return Err(AdapterError::new(
                        "malformed-request",
                        "invalid JSON object separator",
                    ))
                }
            }
        }
    }

    fn number(&mut self) -> Result<Json, AdapterError> {
        let start = self.position;
        while matches!(
            self.bytes.get(self.position),
            Some(b'-' | b'+' | b'.' | b'e' | b'E' | b'0'..=b'9')
        ) {
            self.position += 1;
        }
        let token = std::str::from_utf8(&self.bytes[start..self.position])
            .map_err(|_| AdapterError::new("malformed-request", "invalid JSON number"))?;
        if token.parse::<f64>().is_err() {
            return Err(AdapterError::new(
                "malformed-request",
                "invalid JSON number",
            ));
        }
        Ok(Json::Number(token.to_owned()))
    }
}

fn field<'a>(object: &'a Json, name: &str) -> Result<&'a Json, AdapterError> {
    match object {
        Json::Object(fields) => fields
            .iter()
            .find(|(key, _)| key == name)
            .map(|(_, value)| value)
            .ok_or_else(|| AdapterError::new("invalid-request", format!("missing field {name}"))),
        _ => Err(AdapterError::new(
            "invalid-request",
            "request is not a JSON object",
        )),
    }
}

fn string_field(object: &Json, name: &str) -> Result<String, AdapterError> {
    match field(object, name)? {
        Json::String(value) => Ok(value.clone()),
        _ => Err(AdapterError::new(
            "invalid-request",
            format!("field {name} is not a string"),
        )),
    }
}

fn number_field(object: &Json, name: &str) -> Result<i64, AdapterError> {
    match field(object, name)? {
        Json::Number(value) => value.parse::<i64>().map_err(|_| {
            AdapterError::new("invalid-request", format!("field {name} is not an integer"))
        }),
        _ => Err(AdapterError::new(
            "invalid-request",
            format!("field {name} is not an integer"),
        )),
    }
}

fn array_field<'a>(object: &'a Json, name: &str) -> Result<&'a [Json], AdapterError> {
    match field(object, name)? {
        Json::Array(values) => Ok(values),
        _ => Err(AdapterError::new(
            "invalid-request",
            format!("field {name} is not an array"),
        )),
    }
}

fn quote(value: &str) -> String {
    let mut output = String::with_capacity(value.len() + 2);
    output.push('"');
    for character in value.chars() {
        match character {
            '"' => output.push_str("\\\""),
            '\\' => output.push_str("\\\\"),
            '\u{08}' => output.push_str("\\b"),
            '\u{0c}' => output.push_str("\\f"),
            '\n' => output.push_str("\\n"),
            '\r' => output.push_str("\\r"),
            '\t' => output.push_str("\\t"),
            character if character <= '\u{1f}' => {
                output.push_str(&format!("\\u{:04x}", character as u32))
            }
            character => output.push(character),
        }
    }
    output.push('"');
    output
}

fn error_response(error: AdapterError) -> String {
    format!(
        "{{\"protocolVersion\":{PROTOCOL_VERSION},\"status\":\"error\",\"error\":{{\"code\":{},\"message\":{}}}}}",
        quote(error.code),
        quote(&error.message),
    )
}

fn success_response(result: String) -> Result<String, AdapterError> {
    let response =
        format!("{{\"protocolVersion\":{PROTOCOL_VERSION},\"status\":\"ok\",\"result\":{result}}}");
    if response.len() > MAX_RESPONSE_BYTES {
        return Err(AdapterError::new(
            "response-too-large",
            "adapter response exceeds configured bound",
        ));
    }
    Ok(response)
}

fn valid_snapshot_id(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

fn safe_rust_path(path: &str) -> bool {
    !path.is_empty()
        && path.len() <= MAX_PATH_BYTES
        && path.ends_with(".rs")
        && !path.contains('\0')
        && !path.contains('\\')
        && path
            .split('/')
            .all(|segment| !segment.is_empty() && segment != "." && segment != "..")
}

fn decode_hex(value: &str) -> Result<Vec<u8>, AdapterError> {
    if value.len() % 2 != 0 {
        return Err(AdapterError::new(
            "invalid-request",
            "contentsHex has odd length",
        ));
    }
    let mut bytes = Vec::with_capacity(value.len() / 2);
    let mut pairs = value.as_bytes().chunks_exact(2);
    for pair in &mut pairs {
        let digit = |byte: u8| match byte {
            b'0'..=b'9' => Some(byte - b'0'),
            b'a'..=b'f' => Some(10 + byte - b'a'),
            b'A'..=b'F' => Some(10 + byte - b'A'),
            _ => None,
        };
        let high = digit(pair[0])
            .ok_or_else(|| AdapterError::new("invalid-request", "contentsHex is not hex"))?;
        let low = digit(pair[1])
            .ok_or_else(|| AdapterError::new("invalid-request", "contentsHex is not hex"))?;
        bytes.push((high << 4) | low);
    }
    Ok(bytes)
}

struct SourceFile {
    path: String,
    contents: String,
}

fn decode_sources(request: &Json) -> Result<Vec<SourceFile>, AdapterError> {
    let files = array_field(request, "files")?;
    if files.is_empty() {
        return Err(AdapterError::new(
            "no-rust-files",
            "request contains no Rust source files",
        ));
    }
    if files.len() > MAX_FILES {
        return Err(AdapterError::new(
            "file-limit",
            "request exceeds Rust source file limit",
        ));
    }
    let mut sources = Vec::with_capacity(files.len());
    let mut previous_path: Option<String> = None;
    for value in files {
        let path = string_field(value, "path")?;
        if !safe_rust_path(&path) {
            return Err(AdapterError::new(
                "invalid-path",
                "source path is not a safe project-relative .rs path",
            ));
        }
        if previous_path
            .as_ref()
            .is_some_and(|previous| previous >= &path)
        {
            return Err(AdapterError::new(
                "invalid-path",
                "source paths are not strictly sorted",
            ));
        }
        let bytes = decode_hex(&string_field(value, "contentsHex")?)?;
        if bytes.len() > MAX_SOURCE_BYTES {
            return Err(AdapterError::new(
                "source-too-large",
                "Rust source exceeds configured byte limit",
            ));
        }
        let contents = String::from_utf8(bytes).map_err(|_| {
            AdapterError::new("unsupported-encoding", "Rust source is not valid UTF-8")
        })?;
        previous_path = Some(path.clone());
        sources.push(SourceFile { path, contents });
    }
    Ok(sources)
}

#[derive(Clone)]
struct Item {
    path: String,
    kind: &'static str,
    start_byte: usize,
    end_byte: usize,
    name: Option<String>,
    name_start_byte: Option<usize>,
    name_end_byte: Option<usize>,
}

#[derive(Clone)]
struct Diagnostic {
    path: String,
    code: &'static str,
    start_byte: usize,
    end_byte: usize,
}

fn supported_item_kind(kind: &str) -> bool {
    matches!(
        kind,
        "const_item"
            | "enum_item"
            | "extern_crate_declaration"
            | "foreign_mod_item"
            | "function_item"
            | "impl_item"
            | "macro_definition"
            | "mod_item"
            | "static_item"
            | "struct_item"
            | "trait_item"
            | "type_item"
            | "union_item"
            | "use_declaration"
    )
}

fn collect_diagnostics(
    node: Node<'_>,
    path: &str,
    output: &mut Vec<Diagnostic>,
) -> Result<(), AdapterError> {
    if node.is_error() || node.is_missing() {
        if output.len() == MAX_DIAGNOSTICS {
            return Err(AdapterError::new(
                "diagnostic-limit",
                "parser diagnostics exceed configured limit",
            ));
        }
        output.push(Diagnostic {
            path: path.to_owned(),
            code: if node.is_missing() {
                "missing-token"
            } else {
                "syntax-error"
            },
            start_byte: node.start_byte(),
            end_byte: node.end_byte(),
        });
    }
    let mut cursor = node.walk();
    for child in node.children(&mut cursor) {
        collect_diagnostics(child, path, output)?;
    }
    Ok(())
}

fn item_from_node(node: Node<'_>, path: &str, source: &str) -> Result<Item, AdapterError> {
    let name_node = node.child_by_field_name("name");
    let name = match name_node {
        Some(name_node) => {
            let bytes = &source.as_bytes()[name_node.start_byte()..name_node.end_byte()];
            if bytes.len() > MAX_NAME_BYTES {
                return Err(AdapterError::new(
                    "response-too-large",
                    "Rust item name exceeds configured bound",
                ));
            }
            Some(
                std::str::from_utf8(bytes)
                    .map_err(|_| {
                        AdapterError::new(
                            "internal-error",
                            "Tree-sitter name split UTF-8 codepoint",
                        )
                    })?
                    .to_owned(),
            )
        }
        None => None,
    };
    Ok(Item {
        path: path.to_owned(),
        kind: match node.kind() {
            "const_item" => "const_item",
            "enum_item" => "enum_item",
            "extern_crate_declaration" => "extern_crate_declaration",
            "foreign_mod_item" => "foreign_mod_item",
            "function_item" => "function_item",
            "impl_item" => "impl_item",
            "macro_definition" => "macro_definition",
            "mod_item" => "mod_item",
            "static_item" => "static_item",
            "struct_item" => "struct_item",
            "trait_item" => "trait_item",
            "type_item" => "type_item",
            "union_item" => "union_item",
            "use_declaration" => "use_declaration",
            _ => return Err(AdapterError::new("internal-error", "unsupported item kind")),
        },
        start_byte: node.start_byte(),
        end_byte: node.end_byte(),
        name,
        name_start_byte: name_node.map(|value| value.start_byte()),
        name_end_byte: name_node.map(|value| value.end_byte()),
    })
}

fn parse_sources(
    sources: &[SourceFile],
) -> Result<(bool, Vec<Item>, Vec<Diagnostic>), AdapterError> {
    let mut parser = Parser::new();
    parser
        .set_language(&tree_sitter_rust::LANGUAGE.into())
        .map_err(|_| AdapterError::new("internal-error", "cannot load Rust grammar"))?;
    let mut complete = true;
    let mut items = Vec::new();
    let mut diagnostics = Vec::new();
    for source in sources {
        let tree = parser
            .parse(source.contents.as_bytes(), None)
            .ok_or_else(|| {
                AdapterError::new("parse-unavailable", "Rust parser returned no syntax tree")
            })?;
        let root = tree.root_node();
        complete &= !root.has_error();
        collect_diagnostics(root, &source.path, &mut diagnostics)?;
        let mut cursor = root.walk();
        for node in root.named_children(&mut cursor) {
            if supported_item_kind(node.kind()) {
                if items.len() == MAX_ITEMS {
                    return Err(AdapterError::new(
                        "item-limit",
                        "Rust items exceed configured limit",
                    ));
                }
                items.push(item_from_node(node, &source.path, &source.contents)?);
            }
        }
    }
    items.sort_by(|left, right| {
        left.path
            .cmp(&right.path)
            .then(left.start_byte.cmp(&right.start_byte))
            .then(left.end_byte.cmp(&right.end_byte))
            .then(left.kind.cmp(right.kind))
    });
    diagnostics.sort_by(|left, right| {
        left.path
            .cmp(&right.path)
            .then(left.start_byte.cmp(&right.start_byte))
            .then(left.end_byte.cmp(&right.end_byte))
            .then(left.code.cmp(right.code))
    });
    Ok((complete, items, diagnostics))
}

fn item_json(item: &Item) -> String {
    let name = item
        .name
        .as_ref()
        .map_or_else(|| "null".to_owned(), |value| quote(value));
    let name_start = item
        .name_start_byte
        .map_or_else(|| "null".to_owned(), |value| value.to_string());
    let name_end = item
        .name_end_byte
        .map_or_else(|| "null".to_owned(), |value| value.to_string());
    format!(
        "{{\"path\":{},\"itemKind\":{},\"startByte\":{},\"endByte\":{},\"syntacticName\":{name},\"nameStartByte\":{name_start},\"nameEndByte\":{name_end}}}",
        quote(&item.path),
        quote(item.kind),
        item.start_byte,
        item.end_byte,
    )
}

fn diagnostic_json(diagnostic: &Diagnostic) -> String {
    format!(
        "{{\"path\":{},\"code\":{},\"startByte\":{},\"endByte\":{}}}",
        quote(&diagnostic.path),
        quote(diagnostic.code),
        diagnostic.start_byte,
        diagnostic.end_byte,
    )
}

fn handshake_json() -> String {
    format!(
        "{{\"adapterVersion\":{},\"treeSitterVersion\":{},\"rustGrammarVersion\":{},\"requestLimitBytes\":{MAX_REQUEST_BYTES},\"responseLimitBytes\":{MAX_RESPONSE_BYTES},\"capabilities\":[\"virtual-files\",\"rust-syntax\",\"top-level-items\",\"utf8-byte-spans\"]}}",
        quote(ADAPTER_VERSION),
        quote(TREE_SITTER_VERSION),
        quote(RUST_GRAMMAR_VERSION),
    )
}

fn analyze_json(request: &Json) -> Result<String, AdapterError> {
    let snapshot_id = string_field(request, "snapshotId")?;
    if !valid_snapshot_id(&snapshot_id) {
        return Err(AdapterError::new(
            "invalid-snapshot-id",
            "snapshotId is not 64 lowercase hex characters",
        ));
    }
    let sources = decode_sources(request)?;
    let (parser_complete, items, diagnostics) = parse_sources(&sources)?;
    Ok(format!(
        "{{\"snapshotId\":{},\"adapterVersion\":{},\"treeSitterVersion\":{},\"rustGrammarVersion\":{},\"parserComplete\":{},\"items\":[{}],\"parserDiagnostics\":[{}]}}",
        quote(&snapshot_id),
        quote(ADAPTER_VERSION),
        quote(TREE_SITTER_VERSION),
        quote(RUST_GRAMMAR_VERSION),
        if parser_complete { "true" } else { "false" },
        items.iter().map(item_json).collect::<Vec<_>>().join(","),
        diagnostics.iter().map(diagnostic_json).collect::<Vec<_>>().join(","),
    ))
}

fn run(request: &Json) -> Result<String, AdapterError> {
    if number_field(request, "protocolVersion")? != PROTOCOL_VERSION {
        return Err(AdapterError::new(
            "unsupported-protocol",
            "protocolVersion is unsupported",
        ));
    }
    match string_field(request, "operation")?.as_str() {
        "handshake" => Ok(handshake_json()),
        "analyze" => analyze_json(request),
        _ => Err(AdapterError::new(
            "invalid-request",
            "operation is unsupported",
        )),
    }
}

fn main() {
    let mut request_bytes = Vec::new();
    if let Err(error) = io::stdin()
        .take((MAX_REQUEST_BYTES + 1) as u64)
        .read_to_end(&mut request_bytes)
    {
        print!(
            "{}",
            error_response(AdapterError::new("request-io", error.to_string()))
        );
        return;
    }
    let response = if request_bytes.len() > MAX_REQUEST_BYTES {
        Err(AdapterError::new(
            "request-too-large",
            "request exceeds configured byte limit",
        ))
    } else {
        String::from_utf8(request_bytes)
            .map_err(|_| AdapterError::new("malformed-request", "request is not UTF-8"))
            .and_then(|request| JsonParser::parse(&request))
            .and_then(|request| run(&request))
            .and_then(success_response)
    };
    match response {
        Ok(response) => print!("{response}"),
        Err(error) => print!("{}", error_response(error)),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn golden(name: &str) -> &'static str {
        match name {
            "handshake-request" => include_str!("../testdata/handshake-v1-request.json"),
            "handshake-response" => include_str!("../testdata/handshake-v1-response.json"),
            "analysis-request" => include_str!("../testdata/analysis-v1-request.json"),
            "analysis-response" => include_str!("../testdata/analysis-v1-response.json"),
            _ => panic!("unknown golden fixture"),
        }
    }

    #[test]
    fn protocol_v1_goldens_are_exact() {
        for (request_name, response_name) in [
            ("handshake-request", "handshake-response"),
            ("analysis-request", "analysis-response"),
        ] {
            let request = JsonParser::parse(golden(request_name).trim()).expect("valid request");
            let result = run(&request).expect("available result");
            let response = success_response(result).expect("bounded response");
            assert_eq!(response, golden(response_name).trim());
        }
    }

    #[test]
    fn utf8_item_spans_and_parser_damage_are_explicit() {
        let source = "pub fn café() {}\r\npub struct Unit;\r\n";
        let sources = [SourceFile {
            path: "src/lib.rs".to_owned(),
            contents: source.to_owned(),
        }];
        let (complete, items, diagnostics) = parse_sources(&sources).expect("parse result");
        assert!(complete);
        assert!(diagnostics.is_empty());
        assert_eq!(items[0].name.as_deref(), Some("café"));
        assert_eq!(items[0].name_start_byte, Some(7));
        assert_eq!(items[0].name_end_byte, Some(12));

        let damaged = [SourceFile {
            path: "src/damaged.rs".to_owned(),
            contents: "pub fn {".to_owned(),
        }];
        let (complete, _, diagnostics) = parse_sources(&damaged).expect("damaged parse result");
        assert!(!complete);
        assert!(!diagnostics.is_empty());
    }

    #[test]
    fn unsafe_or_non_utf8_sources_are_structured_errors() {
        let unsafe_request = JsonParser::parse(
            "{\"protocolVersion\":1,\"operation\":\"analyze\",\"snapshotId\":\"1111111111111111111111111111111111111111111111111111111111111111\",\"files\":[{\"path\":\"../escape.rs\",\"contentsHex\":\"\"}]}"
        ).expect("valid JSON");
        assert_eq!(
            run(&unsafe_request).expect_err("unsafe path").code,
            "invalid-path"
        );

        let non_utf8_request = JsonParser::parse(
            "{\"protocolVersion\":1,\"operation\":\"analyze\",\"snapshotId\":\"1111111111111111111111111111111111111111111111111111111111111111\",\"files\":[{\"path\":\"src/lib.rs\",\"contentsHex\":\"ff\"}]}"
        ).expect("valid JSON");
        assert_eq!(
            run(&non_utf8_request).expect_err("non-UTF-8 source").code,
            "unsupported-encoding"
        );
    }
}
