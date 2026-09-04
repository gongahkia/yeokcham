(** A deterministic, local wire-core measurement for TRANSPORT-002.

    It deliberately exercises the largest raw object accepted by the V2 relay,
    without opening a socket or creating source files. Process CPU, RSS, and
    wall time are measured by the invoking [/usr/bin/time] command. *)

module Transfer = Yeokcham_v4_transport.V2
module Wire = Yeokcham_v4_transport.V2_wire

let require_ok = function
  | Ok value -> value
  | Error _ -> failwith "benchmark failure"

let pseudo_random_segment index length =
  let state = ref (Int32.add 0x1234_5678l (Int32.of_int index)) in
  let bytes = Bytes.create length in
  for offset = 0 to length - 1 do
    state := Int32.add (Int32.mul !state 1_103_515_245l) 12_345l;
    Bytes.set bytes offset
      (Char.chr
         (Int32.to_int
            (Int32.logand (Int32.shift_right_logical !state 16) 0xffl)))
  done;
  Bytes.unsafe_to_string bytes

let () =
  let project = String.make 64 'a' in
  let object_id = String.make 64 'b' in
  let offer =
    Transfer.object_offer ~project ~object_id
      ~raw_size:Transfer.max_raw_object_bytes
    |> require_ok
  in
  let ranges = Transfer.partition offer |> require_ok in
  let rec measure index raw_total wire_total first_wire = function
    | [] -> (raw_total, wire_total, first_wire)
    | range :: rest ->
        let raw = pseudo_random_segment index (Transfer.range_length range) in
        let compressed = Wire.compress raw |> require_ok in
        let restored =
          Wire.decompress ~raw_length:(String.length raw) compressed
          |> require_ok
        in
        if not (String.equal raw restored) then
          failwith "wire round trip changed bytes";
        let first_wire =
          match first_wire with
          | Some value -> Some value
          | None -> Some (String.length compressed)
        in
        measure (index + 1)
          (raw_total + String.length raw)
          (wire_total + String.length compressed)
          first_wire rest
  in
  let raw_bytes, wire_bytes, first_wire = measure 0 0 0 None ranges in
  Printf.printf "raw_bytes=%d\nsegments=%d\nwire_bytes=%d\n" raw_bytes
    (List.length ranges) wire_bytes;
  Printf.printf "resume_avoided_raw_bytes=%d\nresume_avoided_wire_bytes=%d\n"
    Transfer.segment_bytes
    (Option.value ~default:0 first_wire)
