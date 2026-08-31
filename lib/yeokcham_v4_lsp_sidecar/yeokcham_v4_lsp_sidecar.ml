module Snapshot = Yeokcham_snapshot
module Config = Yeokcham_v4_semantic_config
open Lsp.Types

[@@@warning "-40-42"]

type snapshot_role = Base | Left | Right
type position = { line : int; character : int }
type range = { start : position; end_ : position }

type symbol = {
  snapshot : snapshot_role;
  snapshot_id : string;
  path : string;
  name : string;
  kind : string;
  ancestry : string list;
  range : range;
  selection_range : range;
  definitions : (string * range) list;
  references : (string * range) list;
  workspace_matches : (string * range) list;
}

type overlap_evidence =
  | Same_symbol_changed
  | Nearby_returned_ranges
  | Shared_definition_or_reference

type possible_overlap = {
  path : string;
  symbol : string;
  evidence : overlap_evidence;
  left_snapshot : string;
  right_snapshot : string;
}

type server_details = {
  configured_name : string;
  program : string;
  arguments : string list;
  reported_name : string option;
  reported_version : string option;
  capabilities : string list;
}

type available = {
  server : server_details;
  snapshots : (snapshot_role * string) list;
  symbols : symbol list;
  possible_overlaps : possible_overlap list;
}

type report =
  | Available of available
  | Unavailable of { server : string; reason : string }

type measured_symbol = { observation : symbol; bytes : string }

let maximum_packet_bytes = 256 * 1024
let maximum_total_bytes = 2 * 1024 * 1024
let maximum_header_bytes = 8192
let maximum_documents = 128
let maximum_positions = 512
let maximum_locations = 10_000
let initialization_timeout = 2.0
let session_timeout = 5.0

let snapshot_role_to_string = function
  | Base -> "base"
  | Left -> "left"
  | Right -> "right"

let overlap_evidence_to_string = function
  | Same_symbol_changed -> "same-symbol-changed"
  | Nearby_returned_ranges -> "nearby-returned-ranges"
  | Shared_definition_or_reference -> "shared-definition-or-reference"

let close_noerr descriptor =
  try Unix.close descriptor with Unix.Unix_error _ -> ()

let kill_and_reap process =
  (try Unix.kill process Sys.sigkill with Unix.Unix_error _ -> ());
  try ignore (Unix.waitpid [] process) with Unix.Unix_error _ -> ()

let remove_tree path =
  let rec remove path =
    try
      match (Unix.lstat path).Unix.st_kind with
      | Unix.S_DIR ->
          Sys.readdir path
          |> Array.iter (fun name -> remove (Filename.concat path name));
          Unix.rmdir path
      | Unix.S_REG | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO
      | Unix.S_SOCK ->
          Unix.unlink path
    with Unix.Unix_error (Unix.ENOENT, _, _) -> ()
  in
  remove path

let with_temporary_directory run =
  let directory = Filename.temp_file "yeokcham-v4-lsp-" "" in
  Unix.unlink directory;
  Unix.mkdir directory 0o700;
  Fun.protect
    ~finally:(fun () -> remove_tree directory)
    (fun () -> run directory)

exception Session_error of string

module Sync = struct
  type 'a t = 'a

  let return value = value
  let raise error = raise error

  module O = struct
    let ( let+ ) value continuation = continuation value
    let ( let* ) value continuation = continuation value
  end
end

type input = {
  input_descriptor : Unix.file_descr;
  mutable input_deadline : float;
  mutable received_bytes : int;
}

type output = {
  output_descriptor : Unix.file_descr;
  mutable output_deadline : float;
}

let wait_readable (input : input) =
  let remaining = input.input_deadline -. Unix.gettimeofday () in
  if remaining <= 0.0 then raise (Session_error "LSP request timed out");
  match Unix.select [ input.input_descriptor ] [] [] remaining with
  | [], _, _ -> raise (Session_error "LSP request timed out")
  | _ -> ()

let read_one (input : input) =
  let bytes = Bytes.create 1 in
  let rec loop () =
    wait_readable input;
    try
      match Unix.read input.input_descriptor bytes 0 1 with
      | 0 -> None
      | _ ->
          input.received_bytes <- input.received_bytes + 1;
          if input.received_bytes > maximum_total_bytes then
            raise (Session_error "LSP output exceeded 2 MiB");
          Some (Bytes.get bytes 0)
    with Unix.Unix_error ((Unix.EAGAIN | Unix.EWOULDBLOCK), _, _) -> loop ()
  in
  loop ()

let read_line (input : input) =
  let buffer = Buffer.create 64 in
  let rec loop () =
    if Buffer.length buffer > maximum_header_bytes then
      raise (Session_error "LSP header exceeded 8 KiB");
    match read_one input with
    | None ->
        if Buffer.length buffer = 0 then None
        else raise (Session_error "truncated LSP header")
    | Some '\n' -> Some (Buffer.contents buffer)
    | Some character ->
        Buffer.add_char buffer character;
        loop ()
  in
  loop ()

let read_exactly (input : input) length =
  if length < 0 || length > maximum_packet_bytes then
    raise (Session_error "LSP packet exceeded 256 KiB");
  let bytes = Bytes.create length in
  let rec loop offset =
    if offset = length then Some (Bytes.unsafe_to_string bytes)
    else (
      wait_readable input;
      try
        let read =
          Unix.read input.input_descriptor bytes offset (length - offset)
        in
        if read = 0 then None
        else (
          input.received_bytes <- input.received_bytes + read;
          if input.received_bytes > maximum_total_bytes then
            raise (Session_error "LSP output exceeded 2 MiB");
          loop (offset + read))
      with Unix.Unix_error ((Unix.EAGAIN | Unix.EWOULDBLOCK), _, _) ->
        loop offset)
  in
  loop 0

let write_all (output : output) value =
  let rec loop offset =
    if offset = String.length value then ()
    else
      let remaining = output.output_deadline -. Unix.gettimeofday () in
      if remaining <= 0.0 then raise (Session_error "LSP request timed out");
      match Unix.select [] [ output.output_descriptor ] [] remaining with
      | _, [], _ -> raise (Session_error "LSP request timed out")
      | _ -> (
          try
            let written =
              Unix.write_substring output.output_descriptor value offset
                (String.length value - offset)
            in
            if written = 0 then
              raise (Session_error "LSP stdin write returned zero");
            loop (offset + written)
          with Unix.Unix_error ((Unix.EAGAIN | Unix.EWOULDBLOCK), _, _) ->
            loop offset)
  in
  loop 0

module Rpc_io =
  Lsp.Io.Make
    (Sync)
    (struct
      type nonrec input = input
      type nonrec output = output

      let read_line = read_line
      let read_exactly = read_exactly
      let write output values = List.iter (write_all output) values
    end)

let position_of_lsp (position : Position.t) : position =
  { line = position.line; character = position.character }

let range_of_lsp (range : Range.t) : range =
  { start = position_of_lsp range.start; end_ = position_of_lsp range.end_ }

let range_nearby left right =
  let before_or_equal left right =
    left.line < right.line
    || (left.line = right.line && left.character <= right.character)
  in
  before_or_equal left.start right.end_
  && before_or_equal right.start left.end_
  || left.start.line = right.end_.line
     && abs (left.start.character - right.end_.character) <= 1
  || right.start.line = left.end_.line
     && abs (right.start.character - left.end_.character) <= 1

let kind_to_string kind =
  Lsp.Types.SymbolKind.yojson_of_t kind |> Yojson.Safe.to_string

let relative_path ~workspace uri =
  let candidate = Lsp.Types.DocumentUri.to_path uri in
  let workspace = Unix.realpath workspace in
  let candidate = Unix.realpath candidate in
  let prefix = workspace ^ Filename.dir_sep in
  if String.starts_with ~prefix candidate then
    Some
      (String.sub candidate (String.length prefix)
         (String.length candidate - String.length prefix))
  else None

let locations_of_lsp ~workspace locations =
  locations
  |> List.filter_map (fun location ->
      match relative_path ~workspace location.Lsp.Types.Location.uri with
      | None -> None
      | Some path -> Some (path, range_of_lsp location.Lsp.Types.Location.range))
  |> List.sort_uniq compare
  |> fun locations ->
  if List.length locations > maximum_locations then
    raise (Session_error "LSP returned too many locations")
  else locations

let locations_of_definition ~workspace = function
  | `Location locations -> locations_of_lsp ~workspace locations
  | `LocationLink links ->
      links
      |> List.filter_map (fun link ->
          match
            relative_path ~workspace link.Lsp.Types.LocationLink.targetUri
          with
          | None -> None
          | Some path -> Some (path, range_of_lsp link.targetRange))
      |> List.sort_uniq compare
      |> fun locations ->
      if List.length locations > maximum_locations then
        raise (Session_error "LSP returned too many locations")
      else locations

let server_capabilities result =
  let capabilities = result.Lsp.Types.InitializeResult.capabilities in
  let enabled = function
    | Some (`Bool false) | None -> false
    | Some _ -> true
  in
  let document_symbol =
    enabled capabilities.Lsp.Types.ServerCapabilities.documentSymbolProvider
  in
  let definition =
    enabled capabilities.Lsp.Types.ServerCapabilities.definitionProvider
  in
  let references =
    enabled capabilities.Lsp.Types.ServerCapabilities.referencesProvider
  in
  let workspace_symbol =
    enabled capabilities.Lsp.Types.ServerCapabilities.workspaceSymbolProvider
  in
  let names =
    [
      ("document-symbol", document_symbol);
      ("definition", definition);
      ("references", references);
      ("workspace-symbol", workspace_symbol);
    ]
    |> List.filter_map (fun (name, present) ->
        if present then Some name else None)
  in
  if List.length names <> 4 then
    raise
      (Session_error
         "configured server lacks a required read-only LSP capability");
  names

let client_capabilities () =
  let document_symbol =
    Lsp.Types.DocumentSymbolClientCapabilities.create
      ~hierarchicalDocumentSymbolSupport:true ()
  in
  let text_document =
    Lsp.Types.TextDocumentClientCapabilities.create
      ~documentSymbol:document_symbol
      ~definition:(Lsp.Types.DefinitionClientCapabilities.create ())
      ~references:(Lsp.Types.ReferenceClientCapabilities.create ())
      ()
  in
  let workspace =
    Lsp.Types.WorkspaceClientCapabilities.create ~applyEdit:false
      ~configuration:false ~workspaceFolders:false ()
  in
  let general =
    Lsp.Types.GeneralClientCapabilities.create
      ~positionEncodings:[ Lsp.Types.PositionEncodingKind.UTF16 ]
      ()
  in
  Lsp.Types.ClientCapabilities.create ~general ~textDocument:text_document
    ~workspace ()

let start_process ~workspace (server : Config.server) =
  let stdin_read, stdin_write = Unix.pipe () in
  let stdout_read, stdout_write = Unix.pipe () in
  let null = Unix.openfile "/dev/null" [ Unix.O_WRONLY ] 0o600 in
  try
    match Unix.fork () with
    | 0 -> (
        try
          Unix.chdir workspace;
          Unix.dup2 stdin_read Unix.stdin;
          Unix.dup2 stdout_write Unix.stdout;
          Unix.dup2 null Unix.stderr;
          List.iter close_noerr
            [ stdin_read; stdin_write; stdout_read; stdout_write; null ];
          Unix.execv server.program
            (Array.of_list (server.program :: server.arguments))
        with _ -> exit 127)
    | process ->
        close_noerr stdin_read;
        close_noerr stdout_write;
        close_noerr null;
        (process, stdin_write, stdout_read)
  with error ->
    List.iter close_noerr
      [ stdin_read; stdin_write; stdout_read; stdout_write; null ];
    raise error

let send_packet output packet = Rpc_io.write output packet

let reject_server_request output request =
  let error =
    Jsonrpc.Response.Error.make ~code:Jsonrpc.Response.Error.Code.MethodNotFound
      ~message:
        "Yeokcham semantic sidecars refuse server-initiated state changes"
      ()
  in
  send_packet output
    (Jsonrpc.Packet.Response
       (Jsonrpc.Response.error request.Jsonrpc.Request.id error))

let rec wait_for_response input output identifier =
  match Rpc_io.read input with
  | None -> raise (Session_error "LSP server closed stdout before responding")
  | Some (Jsonrpc.Packet.Response response) ->
      if Jsonrpc.Id.equal response.Jsonrpc.Response.id identifier then response
      else wait_for_response input output identifier
  | Some (Jsonrpc.Packet.Batch_response responses) -> (
      match
        List.find_opt
          (fun response ->
            Jsonrpc.Id.equal response.Jsonrpc.Response.id identifier)
          responses
      with
      | Some response -> response
      | None -> wait_for_response input output identifier)
  | Some (Jsonrpc.Packet.Request request) ->
      reject_server_request output request;
      wait_for_response input output identifier
  | Some (Jsonrpc.Packet.Batch_call calls) ->
      List.iter
        (function
          | `Request request -> reject_server_request output request
          | `Notification _ -> ())
        calls;
      wait_for_response input output identifier
  | Some (Jsonrpc.Packet.Notification _) ->
      wait_for_response input output identifier

let request input output counter request =
  if !counter >= maximum_positions then
    raise (Session_error "LSP request limit exceeded");
  incr counter;
  let identifier = `Int !counter in
  let packet = Lsp.Client_request.to_jsonrpc_request request ~id:identifier in
  send_packet output (Jsonrpc.Packet.Request packet);
  match (wait_for_response input output identifier).Jsonrpc.Response.result with
  | Ok result -> (
      try Lsp.Client_request.response_of_json request result
      with Jsonrpc.Json.Of_json _ ->
        raise (Session_error "LSP returned malformed result"))
  | Error error ->
      raise
        (Session_error
           ("LSP request failed: " ^ error.Jsonrpc.Response.Error.message))

let notify_initialized output =
  send_packet output
    (Jsonrpc.Packet.Notification
       (Lsp.Client_notification.to_jsonrpc Lsp.Client_notification.Initialized))

let flatten_document_symbols symbols =
  let rec loop ancestry reversed = function
    | [] -> List.rev reversed
    | symbol :: rest ->
        let current =
          ( symbol.Lsp.Types.DocumentSymbol.name,
            symbol.Lsp.Types.DocumentSymbol.kind,
            ancestry,
            symbol.Lsp.Types.DocumentSymbol.range,
            symbol.Lsp.Types.DocumentSymbol.selectionRange )
        in
        let nested =
          match symbol.Lsp.Types.DocumentSymbol.children with
          | None -> []
          | Some children -> loop (ancestry @ [ symbol.name ]) [] children
        in
        loop ancestry (List.rev_append nested (current :: reversed)) rest
  in
  loop [] [] symbols

let document_symbol_entries ~workspace response =
  match response with
  | None -> []
  | Some (`DocumentSymbol symbols) -> flatten_document_symbols symbols
  | Some (`SymbolInformation symbols) ->
      symbols
      |> List.filter_map (fun symbol ->
          match
            relative_path ~workspace
              symbol.Lsp.Types.SymbolInformation.location.uri
          with
          | None -> None
          | Some _ ->
              Some
                ( symbol.name,
                  symbol.kind,
                  (match symbol.containerName with
                  | None -> []
                  | Some value -> [ value ]),
                  symbol.location.range,
                  symbol.location.range ))

let safe_regular_file path =
  try (Unix.lstat path).Unix.st_kind = Unix.S_REG
  with Unix.Unix_error _ -> false

let files_for_workspace ~workspace paths =
  paths
  |> List.filter (fun path ->
      safe_regular_file (Filename.concat workspace path))
  |> List.sort_uniq String.compare
  |> fun files ->
  if List.length files > maximum_documents then
    raise (Session_error "semantic document limit exceeded")
  else files

let utf8_width bytes offset limit =
  let byte index = Char.code bytes.[index] in
  if offset >= limit then None
  else
    match byte offset with
    | value when value < 0x80 -> Some (1, 1)
    | value
      when value land 0xe0 = 0xc0
           && offset + 1 < limit
           && byte (offset + 1) land 0xc0 = 0x80 ->
        Some (2, 1)
    | value
      when value land 0xf0 = 0xe0
           && offset + 2 < limit
           && byte (offset + 1) land 0xc0 = 0x80
           && byte (offset + 2) land 0xc0 = 0x80 ->
        Some (3, 1)
    | value
      when value land 0xf8 = 0xf0
           && offset + 3 < limit
           && byte (offset + 1) land 0xc0 = 0x80
           && byte (offset + 2) land 0xc0 = 0x80
           && byte (offset + 3) land 0xc0 = 0x80 ->
        Some (4, 2)
    | _ -> None

let byte_offset_of_position bytes position =
  let length = String.length bytes in
  let rec line_start line offset =
    if line = position.line then Some offset
    else if offset >= length then None
    else
      match String.index_from_opt bytes offset '\n' with
      | None -> None
      | Some newline -> line_start (line + 1) (newline + 1)
  in
  match line_start 0 0 with
  | None -> None
  | Some start ->
      let limit =
        match String.index_from_opt bytes start '\n' with
        | Some value -> value
        | None -> length
      in
      let rec character offset units =
        if units = position.character then Some offset
        else if
          offset >= limit
          && units + 1 = position.character
          && limit < length
          && bytes.[limit] = '\n'
        then Some (limit + 1)
        else if units > position.character || offset >= limit then None
        else
          match utf8_width bytes offset limit with
          | None -> None
          | Some (width, code_units) ->
              character (offset + width) (units + code_units)
      in
      character start 0

let exact_slice bytes range =
  match
    ( byte_offset_of_position bytes range.start,
      byte_offset_of_position bytes range.end_ )
  with
  | Some start, Some end_ when start <= end_ ->
      Some (String.sub bytes start (end_ - start))
  | _ -> None

let inspect_workspace ~store server ~role ~snapshot_id ~snapshot ~paths =
  with_temporary_directory (fun workspace ->
      match
        Snapshot.Materialize.write ~destination:workspace store snapshot
      with
      | Error error ->
          raise (Session_error (Snapshot.Materialize.error_to_string error))
      | Ok () ->
          let process, stdin, stdout = start_process ~workspace server in
          let input =
            {
              input_descriptor = stdout;
              input_deadline = Unix.gettimeofday () +. initialization_timeout;
              received_bytes = 0;
            }
          in
          let output =
            {
              output_descriptor = stdin;
              output_deadline = input.input_deadline;
            }
          in
          Fun.protect
            ~finally:(fun () ->
              close_noerr stdin;
              close_noerr stdout;
              kill_and_reap process)
            (fun () ->
              let counter = ref 0 in
              let root_uri = Lsp.Types.DocumentUri.of_path workspace in
              let initialized =
                Lsp.Types.InitializeParams.create
                  ~capabilities:(client_capabilities ())
                  ~clientInfo:
                    (Lsp.Types.InitializeParams.create_clientInfo
                       ~name:"yeokcham" ~version:"v4" ())
                  ~processId:(Unix.getpid ()) ~rootUri:root_uri ()
              in
              let result =
                request input output counter
                  (Lsp.Client_request.Initialize initialized)
              in
              let capabilities = server_capabilities result in
              notify_initialized output;
              let deadline = Unix.gettimeofday () +. session_timeout in
              input.input_deadline <- deadline;
              output.output_deadline <- deadline;
              let files = files_for_workspace ~workspace paths in
              let symbols = ref [] in
              List.iter
                (fun path ->
                  let file = Filename.concat workspace path in
                  let bytes =
                    In_channel.with_open_bin file In_channel.input_all
                  in
                  let uri = Lsp.Types.DocumentUri.of_path file in
                  let document = Lsp.Types.TextDocumentIdentifier.create ~uri in
                  let entries =
                    request input output counter
                      (Lsp.Client_request.DocumentSymbol
                         (Lsp.Types.DocumentSymbolParams.create
                            ~textDocument:document ()))
                    |> document_symbol_entries ~workspace
                  in
                  List.iter
                    (fun (name, kind, ancestry, range, selection_range) ->
                      let position = selection_range.Lsp.Types.Range.start in
                      let definitions =
                        request input output counter
                          (Lsp.Client_request.TextDocumentDefinition
                             (Lsp.Types.DefinitionParams.create ~position
                                ~textDocument:document ()))
                        |> Option.map (locations_of_definition ~workspace)
                        |> Option.value ~default:[]
                      in
                      let references =
                        request input output counter
                          (Lsp.Client_request.TextDocumentReferences
                             (Lsp.Types.ReferenceParams.create
                                ~context:
                                  (Lsp.Types.ReferenceContext.create
                                     ~includeDeclaration:true)
                                ~position ~textDocument:document ()))
                        |> Option.value ~default:[]
                        |> locations_of_lsp ~workspace
                      in
                      let workspace_matches =
                        request input output counter
                          (Lsp.Client_request.WorkspaceSymbol
                             (Lsp.Types.WorkspaceSymbolParams.create ~query:name
                                ()))
                        |> Option.value ~default:[]
                        |> List.filter_map (fun match_ ->
                            match
                              relative_path ~workspace
                                match_.Lsp.Types.SymbolInformation.location.uri
                            with
                            | None -> None
                            | Some candidate ->
                                Some
                                  (candidate, range_of_lsp match_.location.range))
                      in
                      symbols :=
                        {
                          observation =
                            {
                              snapshot = role;
                              snapshot_id;
                              path;
                              name;
                              kind = kind_to_string kind;
                              ancestry;
                              range = range_of_lsp range;
                              selection_range = range_of_lsp selection_range;
                              definitions;
                              references;
                              workspace_matches;
                            };
                          bytes;
                        }
                        :: !symbols)
                    entries)
                files;
              let server_info = result.Lsp.Types.InitializeResult.serverInfo in
              ( List.rev !symbols,
                {
                  configured_name = server.name;
                  program = server.program;
                  arguments = server.arguments;
                  reported_name =
                    Option.map
                      (fun info -> info.Lsp.Types.InitializeResult.name)
                      server_info;
                  reported_version =
                    Option.bind server_info (fun info -> info.version);
                  capabilities;
                } )))

let symbol_key (symbol : symbol) =
  (symbol.path, symbol.name, symbol.kind, symbol.ancestry)

let changed_same_symbol ~base (left : measured_symbol) (right : measured_symbol)
    =
  let key = symbol_key left.observation in
  symbol_key right.observation = key
  &&
  match
    List.find_opt (fun candidate -> symbol_key candidate.observation = key) base
  with
  | None -> false
  | Some baseline -> (
      match
        ( exact_slice baseline.bytes baseline.observation.range,
          exact_slice left.bytes left.observation.range,
          exact_slice right.bytes right.observation.range )
      with
      | Some baseline, Some left, Some right ->
          (not (String.equal baseline left))
          && not (String.equal baseline right)
      | None, _, _ | _, None, _ | _, _, None -> false)

let shared_locations (left : symbol) (right : symbol) =
  List.exists
    (fun location ->
      List.mem location right.definitions || List.mem location right.references)
    left.definitions
  || List.exists
       (fun location ->
         List.mem location right.definitions
         || List.mem location right.references)
       left.references

let overlaps sensitivity ~base ~left ~right =
  let pairs =
    left
    |> List.concat_map (fun left_symbol ->
        right
        |> List.filter_map (fun right_symbol ->
            let same_symbol =
              symbol_key left_symbol.observation
              = symbol_key right_symbol.observation
            in
            let candidate =
              match sensitivity with
              | Config.Same_symbol -> same_symbol
              | Config.Nearby_ranges ->
                  left_symbol.observation.path = right_symbol.observation.path
              | Config.References -> true
            in
            if candidate then Some (left_symbol, right_symbol) else None))
  in
  pairs
  |> List.filter_map (fun (left_symbol, right_symbol) ->
      let evidence =
        if changed_same_symbol ~base left_symbol right_symbol then
          Some Same_symbol_changed
        else
          match sensitivity with
          | Config.Same_symbol -> None
          | Config.Nearby_ranges
            when left_symbol.observation.path = right_symbol.observation.path
                 && range_nearby left_symbol.observation.range
                      right_symbol.observation.range ->
              Some Nearby_returned_ranges
          | Config.References
            when shared_locations left_symbol.observation
                   right_symbol.observation ->
              Some Shared_definition_or_reference
          | Config.Nearby_ranges | Config.References -> None
      in
      Option.map
        (fun evidence ->
          {
            path = left_symbol.observation.path;
            symbol =
              String.concat "."
                (left_symbol.observation.ancestry
                @ [ left_symbol.observation.name ]);
            evidence;
            left_snapshot = left_symbol.observation.snapshot_id;
            right_snapshot = right_symbol.observation.snapshot_id;
          })
        evidence)
  |> List.sort_uniq compare

let inspect ~store ~server ~base ~left ~right ~paths =
  let paths =
    paths
    |> List.filter (Config.matches_path server)
    |> List.sort_uniq String.compare
  in
  if paths = [] then
    Unavailable
      { server = server.name; reason = "no changed paths match this server" }
  else
    try
      let base_id, base_snapshot = base in
      let left_id, left_snapshot = left in
      let right_id, right_snapshot = right in
      let base_symbols, base_details =
        inspect_workspace ~store server ~role:Base ~snapshot_id:base_id
          ~snapshot:base_snapshot ~paths
      in
      let left_symbols, _ =
        inspect_workspace ~store server ~role:Left ~snapshot_id:left_id
          ~snapshot:left_snapshot ~paths
      in
      let right_symbols, _ =
        inspect_workspace ~store server ~role:Right ~snapshot_id:right_id
          ~snapshot:right_snapshot ~paths
      in
      let possible_overlaps =
        overlaps server.overlap_sensitivity ~base:base_symbols
          ~left:left_symbols ~right:right_symbols
      in
      Available
        {
          server = base_details;
          snapshots = [ (Base, base_id); (Left, left_id); (Right, right_id) ];
          symbols =
            List.map
              (fun measured -> measured.observation)
              (base_symbols @ left_symbols @ right_symbols);
          possible_overlaps;
        }
    with
    | Session_error reason -> Unavailable { server = server.name; reason }
    | Unix.Unix_error (error, operation, path) ->
        Unavailable
          {
            server = server.name;
            reason =
              Printf.sprintf "%s %s: %s" operation path
                (Unix.error_message error);
          }
    | Lsp.Io.Error reason -> Unavailable { server = server.name; reason }
    | Jsonrpc.Json.Of_json _ ->
        Unavailable
          { server = server.name; reason = "malformed JSON-RPC packet" }
    | Yojson.Json_error _ ->
        Unavailable
          { server = server.name; reason = "malformed JSON-RPC packet" }
