module P = Yeokcham_v1_pages
module Raw = Yeokcham_store
module E = Yeokcham_encoding
module Envelope = Yeokcham_envelope

let ok render = function Ok v -> v | Error e -> Alcotest.fail (render e)
let pages r = ok P.error_to_string r

let reject = function
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "accepted malformed metadata"

let rec remove path =
  if (Unix.lstat path).Unix.st_kind = Unix.S_DIR then (
    Array.iter
      (fun name -> remove (Filename.concat path name))
      (Sys.readdir path);
    Unix.rmdir path)
  else Unix.unlink path

let fixture f =
  let root = Filename.temp_file "yeokcham-pages-" "" in
  Unix.unlink root;
  Unix.mkdir root 0o700;
  Fun.protect
    ~finally:(fun () -> remove root)
    (fun () ->
      let store = Raw.init ~root |> ok Raw.error_to_string in
      f store)

let array v = E.array v |> ok E.construction_error_to_string

let page store ~namespace kind fields =
  let payload =
    array (E.integer 1L :: E.bytes namespace :: E.integer kind :: fields)
  in
  Envelope.create ~object_type:Envelope.Core_metadata_page
    ~object_format_version:1 ~mandatory_features:0L ~payload ()
  |> ok Envelope.creation_error_to_string
  |> Raw.put store |> ok Raw.error_to_string

let roundtrip_and_bounds () =
  fixture (fun store ->
      let namespace = "private\000workspace" in
      let values =
        List.init 17001 (fun i ->
            (Printf.sprintf "key-%08d" i, string_of_int i))
      in
      let values = ("large", String.make P.max_value_bytes 'x') :: values in
      let id = P.store store ~namespace values |> pages in
      let again = P.store store ~namespace (List.rev values) |> pages in
      Alcotest.(check bool)
        "order independent canonical root" true
        (Raw.Stored_object_id.equal id again);
      let before =
        Raw.list_objects store |> ok Raw.error_to_string |> List.length
      in
      let actual = P.load store ~namespace id |> pages in
      Alcotest.(check bool)
        "large paged collection and complete value" true
        (actual = List.sort compare values);
      P.closure store ~namespace id
      |> pages
      |> List.iter (fun id ->
          let bytes =
            Raw.read_file_bounded ~path:(Raw.object_path store id)
              ~max_bytes:P.max_page_bytes
            |> ok Raw.error_to_string
          in
          Alcotest.(check bool)
            "bounded full envelopes" true
            (String.length bytes <= P.max_page_bytes));
      Alcotest.(check int)
        "reads stage no objects" before
        (Raw.list_objects store |> ok Raw.error_to_string |> List.length);
      reject (P.load store ~namespace:"another-workspace" id);
      reject (P.store store ~namespace [ ("same", "a"); ("same", "b") ]);
      reject
        (P.store store ~namespace
           [ ("large", String.make (P.max_value_bytes + 1) 'x') ]))

let inline_and_chunk_boundaries () =
  fixture (fun store ->
      let namespace = "boundaries" in
      let values =
        List.map
          (fun n ->
            (string_of_int n, String.init n (fun i -> Char.chr (i mod 256))))
          [ 0; 4096; 4097; 512 * 1024; (512 * 1024) + 1; 1024 * 1024 ]
      in
      let id = P.store store ~namespace values |> pages in
      Alcotest.(check bool)
        "exact bytes across inline/chunk boundaries" true
        (P.load store ~namespace id |> pages = List.sort compare values))

let malformed_collections () =
  fixture (fun store ->
      let namespace = "malformed" in
      let inline value = array [ E.integer 0L; E.bytes value ] in
      let row key value = array [ E.bytes key; inline value ] in
      List.iter
        (fun rows ->
          let id = page store ~namespace 0L [ array rows ] in
          reject (P.load store ~namespace id))
        [
          [ row "b" "1"; row "a" "2" ];
          [ row "a" "1"; row "a" "2" ];
          [ row "" "x" ];
          [ row (String.make 1025 'k') "x" ];
          [ row "a" (String.make 4097 'x') ];
        ];
      let leaf = page store ~namespace 0L [ array [ row "a" "value" ] ] in
      let child maximum id =
        array
          [ E.bytes maximum; E.bytes (Raw.Stored_object_id.to_raw_bytes id) ]
      in
      List.iter
        (fun children ->
          let id = page store ~namespace 1L [ array children ] in
          reject (P.load store ~namespace id))
        [
          [ child "a" leaf ];
          [ child "wrong" leaf ];
          [ child "a" leaf; child "a" leaf ];
          [ array [ E.bytes "a"; E.bytes "short" ] ];
        ];
      let chunk = page store ~namespace 2L [ E.bytes (String.make 4097 'v') ] in
      let index =
        page store ~namespace 3L
          [
            E.integer 4098L;
            array [ E.bytes (Raw.Stored_object_id.to_raw_bytes chunk) ];
          ]
      in
      let id =
        page store ~namespace 0L
          [
            array
              [
                array
                  [
                    E.bytes "a";
                    array
                      [
                        E.integer 1L;
                        E.bytes (Raw.Stored_object_id.to_raw_bytes index);
                      ];
                  ];
              ];
          ]
      in
      reject (P.load store ~namespace id))

let[@warning "-4"] bounded_and_missing_readers () =
  fixture (fun store ->
      let namespace = "readers" in
      let id = P.store store ~namespace [ ("a", "value") ] |> pages in
      let path = Raw.object_path store id in
      let original = In_channel.with_open_bin path In_channel.input_all in
      Out_channel.with_open_bin path (fun out ->
          output_string out (String.make (P.max_page_bytes + 1) 'x'));
      (match P.load store ~namespace id with
      | Error (P.Store_error (Raw.Object_too_large _)) -> ()
      | Error e -> Alcotest.fail (P.error_to_string e)
      | Ok _ -> Alcotest.fail "oversized page decoded");
      Out_channel.with_open_bin path (fun out -> output_string out original);
      Unix.unlink path;
      match P.load store ~namespace id with
      | Error (P.Store_error (Raw.Io_error _)) -> ()
      | Error e -> Alcotest.fail (P.error_to_string e)
      | Ok _ -> Alcotest.fail "missing page accepted")

let[@warning "-4"] wrong_schema_and_identity () =
  fixture (fun store ->
      let namespace = "schema" in
      let id = page store ~namespace 4L [] in
      reject (P.load store ~namespace id);
      let id = P.store store ~namespace [ ("a", "value") ] |> pages in
      let other = P.store store ~namespace [ ("b", "value") ] |> pages in
      let bytes =
        In_channel.with_open_bin
          (Raw.object_path store other)
          In_channel.input_all
      in
      Out_channel.with_open_bin (Raw.object_path store id) (fun out ->
          output_string out bytes);
      match P.load store ~namespace id with
      | Error (P.Integrity _) -> ()
      | Error e -> Alcotest.fail (P.error_to_string e)
      | Ok _ -> Alcotest.fail "page identity substitution accepted")

let caller_control_bounds () =
  fixture (fun store ->
      let namespace = "bounded-control" in
      let rows =
        List.init 129 (fun i -> (string_of_int i, String.make 4097 'v'))
      in
      let root = P.store store ~namespace rows |> pages in
      let load max_rows max_value_bytes max_total_value_bytes =
        P.load_bounded store ~namespace ~max_rows ~max_value_bytes
          ~max_total_value_bytes root
      in
      reject (load 128 4097 max_int);
      reject (load 129 4096 max_int);
      reject (load 129 4097 (128 * 4097));
      Alcotest.(check int)
        "exact caller limits preserve complete collection" 129
        (load 129 4097 (129 * 4097) |> pages |> List.length))

let independent_vector () =
  fixture (fun store ->
      let id =
        P.store store ~namespace:"pages-v1" [ ("a", "A"); ("bad-\255", "B") ]
        |> pages
      in
      let hex bytes =
        String.init
          (String.length bytes * 2)
          (fun i ->
            let byte = Char.code bytes.[i / 2] in
            "0123456789abcdef".[if i mod 2 = 0 then byte lsr 4 else byte land 15])
      in
      let read name =
        let relative = "golden/composition/" ^ name in
        let path =
          if Sys.file_exists relative then relative else "test/" ^ relative
        in
        In_channel.with_open_bin path In_channel.input_all |> String.trim
      in
      Alcotest.(check string)
        "independent envelope"
        (read "metadata-page-envelope.hex")
        (Raw.get store id |> ok Raw.error_to_string |> Envelope.encode |> hex);
      Alcotest.(check string)
        "independent store identity"
        (read "metadata-page-id.hex")
        (Raw.Stored_object_id.to_hex id))

let () =
  Alcotest.run "Bounded metadata pages"
    [
      ( "pages",
        [
          Alcotest.test_case "paged canonical collections and large values"
            `Quick roundtrip_and_bounds;
          Alcotest.test_case "inline and repeated chunk boundaries" `Quick
            inline_and_chunk_boundaries;
          Alcotest.test_case "malformed ordering/references/pagination" `Quick
            malformed_collections;
          Alcotest.test_case "bounded and missing readers" `Quick
            bounded_and_missing_readers;
          Alcotest.test_case "schema and identity substitution" `Quick
            wrong_schema_and_identity;
          Alcotest.test_case "independent envelope and identity" `Quick
            independent_vector;
          Alcotest.test_case "caller row/value/aggregate bounds" `Quick
            caller_control_bounds;
        ] );
    ]
