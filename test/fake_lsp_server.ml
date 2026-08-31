let content_length line =
  let prefix = "Content-Length:" in
  if String.starts_with ~prefix line then
    String.sub line (String.length prefix)
      (String.length line - String.length prefix)
    |> String.trim |> int_of_string_opt
  else None

let read_packet () =
  let rec headers length =
    match input_line stdin with
    | "" | "\r" -> length
    | line ->
        let length =
          match content_length line with
          | Some value -> Some value
          | None -> length
        in
        headers length
  in
  match headers None with
  | None -> None
  | Some length ->
      let bytes = really_input_string stdin length in
      Some (Yojson.Safe.from_string bytes)

let write_packet json =
  let body = Yojson.Safe.to_string json in
  Printf.printf "Content-Length: %d\r\n\r\n%s%!" (String.length body) body

let identifier (packet : Yojson.Safe.t) : Yojson.Safe.t option =
  match packet with
  | `Assoc fields -> List.assoc_opt "id" fields
  | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ | `Null ->
      None

let method_name (packet : Yojson.Safe.t) : Yojson.Safe.t option =
  match packet with
  | `Assoc fields -> List.assoc_opt "method" fields
  | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ | `Null ->
      None

let root_uri = function
  | `Assoc fields -> (
      match List.assoc_opt "params" fields with
      | Some (`Assoc parameters) -> (
          match List.assoc_opt "rootUri" parameters with
          | Some (`String uri) -> Some uri
          | _ -> None)
      | _ -> None)
  | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ | `Null ->
      None

let result id value =
  write_packet
    (`Assoc [ ("jsonrpc", `String "2.0"); ("id", id); ("result", value) ])

let initialize_result =
  `Assoc
    [
      ( "capabilities",
        `Assoc
          [
            ("documentSymbolProvider", `Bool true);
            ("definitionProvider", `Bool true);
            ("referencesProvider", `Bool true);
            ("workspaceSymbolProvider", `Bool true);
          ] );
      ( "serverInfo",
        `Assoc [ ("name", `String "fake-lsp"); ("version", `String "1.0") ] );
    ]

let symbol =
  `Assoc
    [
      ("name", `String "version");
      ("kind", `Int 13);
      ( "range",
        `Assoc
          [
            ("start", `Assoc [ ("line", `Int 0); ("character", `Int 0) ]);
            ("end", `Assoc [ ("line", `Int 0); ("character", `Int 15) ]);
          ] );
      ( "selectionRange",
        `Assoc
          [
            ("start", `Assoc [ ("line", `Int 0); ("character", `Int 4) ]);
            ("end", `Assoc [ ("line", `Int 0); ("character", `Int 11) ]);
          ] );
    ]

let document_uri = function
  | `Assoc fields -> (
      match List.assoc_opt "params" fields with
      | Some (`Assoc parameters) -> (
          match List.assoc_opt "textDocument" parameters with
          | Some (`Assoc document) -> (
              match List.assoc_opt "uri" document with
              | Some (`String uri) -> Some uri
              | _ -> None)
          | _ -> None)
      | _ -> None)
  | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ | `Null ->
      None

let snapshot_symbol () =
  let source =
    try In_channel.with_open_bin "main.ml" In_channel.input_all
    with Sys_error _ -> ""
  in
  let name =
    match source with
    | "let version = 1\n" -> "base-version"
    | "let version = 2\n" -> "left-version"
    | "let version = 3\n" -> "right-version"
    | _ -> "unknown-version"
  in
  match symbol with
  | `Assoc fields ->
      `Assoc (("name", `String name) :: List.remove_assoc "name" fields)
  | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ | `Null ->
      symbol

let shared_location packet =
  match document_uri packet with
  | None -> `List []
  | Some uri ->
      `List
        [
          `Assoc
            [
              ("uri", `String uri);
              ( "range",
                `Assoc
                  [
                    ("start", `Assoc [ ("line", `Int 0); ("character", `Int 0) ]);
                    ("end", `Assoc [ ("line", `Int 0); ("character", `Int 15) ]);
                  ] );
            ];
        ]

let mode, capture =
  match Array.to_list Sys.argv with
  | [ _; mode; "--capture"; path ] -> (mode, Some path)
  | [ _; mode ] -> (mode, None)
  | _ -> exit 64

let capture_root packet =
  match (capture, root_uri packet) with
  | Some path, Some uri ->
      Out_channel.with_open_bin path (fun channel ->
          Out_channel.output_string channel uri)
  | None, _ | _, None -> ()

let rejected_server_request id method_name parameters =
  write_packet
    (`Assoc
       [
         ("jsonrpc", `String "2.0");
         ("id", `String "server-edit");
         ("method", `String method_name);
         ("params", parameters);
       ]);
  match read_packet () with
  | Some (`Assoc fields) -> (
      match List.assoc_opt "error" fields with
      | Some (`Assoc error) -> (
          match List.assoc_opt "code" error with
          | Some (`Int -32601) -> result id initialize_result
          | _ -> exit 65)
      | _ -> exit 65)
  | Some _ -> exit 65
  | None -> exit 65

let handle packet =
  match (identifier packet, method_name packet) with
  | Some id, Some (`String "initialize") -> (
      capture_root packet;
      match mode with
      | "timeout" -> Unix.sleepf 6.0
      | "malformed" ->
          print_string "Content-Length: 1\r\n\r\n{";
          flush stdout
      | "oversized" ->
          print_string "Content-Length: 300000\r\n\r\n";
          flush stdout
      | "apply-edit" ->
          rejected_server_request id "workspace/applyEdit"
            (`Assoc [ ("edit", `Assoc []) ])
      | "execute-command" ->
          rejected_server_request id "workspace/executeCommand"
            (`Assoc [ ("command", `String "malicious") ])
      | "normal" | "nearby" | "references" -> result id initialize_result
      | _ -> exit 64)
  | Some id, Some (`String "textDocument/documentSymbol") ->
      result id
        (`List
           [
             (match mode with
             | "nearby" | "references" -> snapshot_symbol ()
             | _ -> symbol);
           ])
  | Some id, Some (`String "textDocument/definition") ->
      result id
        (match mode with
        | "references" -> shared_location packet
        | _ -> `List [])
  | Some id, Some (`String "textDocument/references")
  | Some id, Some (`String "workspace/symbol") ->
      result id (`List [])
  | Some id, Some (`String "shutdown") -> result id `Null
  | Some id, Some (`String _) -> result id `Null
  | Some _, None | Some _, Some _ | None, _ -> ()

let rec run () =
  match read_packet () with
  | None -> ()
  | Some packet ->
      handle packet;
      run ()

let () = run ()
