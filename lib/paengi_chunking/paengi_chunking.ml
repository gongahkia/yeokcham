type t =
  | Fixed of { chunk_size : int }
  | Gear_v1 of { min_size : int; average_size : int; max_size : int }

type error =
  | Invalid_chunk_size of int
  | Invalid_gear_parameters of { min_size : int; average_size : int; max_size : int }

let error_to_string = function
  | Invalid_chunk_size chunk_size ->
      Printf.sprintf "invalid fixed chunk size: %d" chunk_size
  | Invalid_gear_parameters { min_size; average_size; max_size } ->
      Printf.sprintf "invalid Gear-v1 parameters: min=%d average=%d max=%d"
        min_size average_size max_size

let default = Gear_v1 { min_size = 16 * 1024; average_size = 64 * 1024; max_size = 128 * 1024 }
let fixed_64k = Fixed { chunk_size = 64 * 1024 }

let power_of_two value = value > 0 && value land (value - 1) = 0

let validate = function
  | Fixed { chunk_size } when chunk_size > 0 -> Ok ()
  | Fixed { chunk_size } -> Error (Invalid_chunk_size chunk_size)
  | Gear_v1 { min_size; average_size; max_size }
    when min_size > 0 && min_size <= average_size && average_size <= max_size
         && power_of_two average_size ->
      Ok ()
  | Gear_v1 { min_size; average_size; max_size } ->
      Error (Invalid_gear_parameters { min_size; average_size; max_size })

let gear_table =
  let state = ref 0x6a09e667f3bcc909L in
  Array.init 256 (fun _ ->
      state :=
        Int64.add (Int64.mul !state 6364136223846793005L)
          1442695040888963407L;
      !state)

type state = { length : int; hash : int64 }

let initial_state = { length = 0; hash = 0L }

let next strategy state character =
  match strategy with
  | Fixed { chunk_size } ->
      let length = state.length + 1 in
      let cut = length = chunk_size in
      ((if cut then initial_state else { state with length }), cut)
  | Gear_v1 { min_size; average_size; max_size } ->
      let length = state.length + 1 in
      let hash =
        Int64.add (Int64.shift_left state.hash 1) gear_table.(Char.code character)
      in
      let mask = Int64.of_int (average_size - 1) in
      let cut =
        length >= max_size
        || (length >= min_size && Int64.equal (Int64.logand hash mask) 0L)
      in
      ((if cut then initial_state else { length; hash }), cut)

let split strategy bytes =
  match validate strategy with
  | Error error -> Error error
  | Ok () ->
      let length = String.length bytes in
      if length = 0 then Ok []
      else
        let state = ref initial_state in
        let start = ref 0 in
        let chunks = ref [] in
        for offset = 0 to length - 1 do
          let next_state, cut = next strategy !state bytes.[offset] in
          state := next_state;
          if cut then (
            chunks := String.sub bytes !start (offset + 1 - !start) :: !chunks;
            start := offset + 1)
        done;
        if !start < length then
          chunks := String.sub bytes !start (length - !start) :: !chunks;
        Ok (List.rev !chunks)

let chunks_are_canonical strategy chunks =
  match validate strategy with
  | Error _ -> false
  | Ok () ->
      let rec check state = function
        | [] -> true
        | [ chunk ] ->
            if String.is_empty chunk then false
            else
              let state = ref state in
              let accepted = ref true in
              String.iteri
                (fun offset character ->
                  let next_state, cut = next strategy !state character in
                  if cut && offset <> String.length chunk - 1 then accepted := false;
                  state := next_state)
                chunk;
              !accepted
        | chunk :: rest ->
            if String.is_empty chunk then false
            else
              let state = ref state in
              let saw_cut = ref false in
              let accepted = ref true in
              String.iteri
                (fun offset character ->
                  let next_state, cut = next strategy !state character in
                  if cut then (
                    if offset <> String.length chunk - 1 then accepted := false;
                    saw_cut := true);
                  state := next_state)
                chunk;
              !accepted && !saw_cut && check !state rest
      in
      check initial_state chunks
