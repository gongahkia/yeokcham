type t =
  | Fixed of { chunk_size : int }
  | Buzhash_v1 of {
      window_size : int;
      min_size : int;
      average_size : int;
      max_size : int;
    }

type error =
  | Invalid_chunk_size of int
  | Invalid_buzhash_parameters of {
      window_size : int;
      min_size : int;
      average_size : int;
      max_size : int;
    }

let error_to_string = function
  | Invalid_chunk_size chunk_size ->
      Printf.sprintf "invalid fixed chunk size: %d" chunk_size
  | Invalid_buzhash_parameters { window_size; min_size; average_size; max_size } ->
      Printf.sprintf
        "invalid Buzhash-v1 parameters: window=%d min=%d average=%d max=%d"
        window_size min_size average_size max_size

let default =
  Buzhash_v1
    {
      window_size = 64;
      min_size = 16 * 1024;
      average_size = 64 * 1024;
      max_size = 128 * 1024;
    }

let fixed_64k = Fixed { chunk_size = 64 * 1024 }

let power_of_two value = value > 0 && value land (value - 1) = 0

let validate = function
  | Fixed { chunk_size } when chunk_size > 0 -> Ok ()
  | Fixed { chunk_size } -> Error (Invalid_chunk_size chunk_size)
  | Buzhash_v1 { window_size; min_size; average_size; max_size }
    when window_size > 0 && min_size > 0 && min_size <= average_size
         && average_size <= max_size && power_of_two average_size ->
      Ok ()
  | Buzhash_v1 { window_size; min_size; average_size; max_size } ->
      Error
        (Invalid_buzhash_parameters
           { window_size; min_size; average_size; max_size })

let buzhash_table =
  let state = ref 0x6a09e667f3bcc909L in
  Array.init 256 (fun _ ->
      state :=
        Int64.add (Int64.mul !state 6364136223846793005L)
          1442695040888963407L;
      !state)

let rotate_left value bits =
  let bits = bits mod 64 in
  if bits = 0 then value
  else
    Int64.logor (Int64.shift_left value bits)
      (Int64.shift_right_logical value (64 - bits))

type splitter =
  | Fixed_splitter of { chunk_size : int; current : Buffer.t }
  | Buzhash_splitter of {
      window_size : int;
      min_size : int;
      average_size : int;
      max_size : int;
      window : bytes;
      mutable seen : int;
      mutable hash : int64;
      mutable current_length : int;
      current : Buffer.t;
    }

let create_splitter strategy =
  match validate strategy with
  | Error error -> Error error
  | Ok () -> (
      match strategy with
      | Fixed { chunk_size } ->
          Ok (Fixed_splitter { chunk_size; current = Buffer.create chunk_size })
      | Buzhash_v1 { window_size; min_size; average_size; max_size } ->
          Ok
            (Buzhash_splitter
               {
                 window_size;
                 min_size;
                 average_size;
                 max_size;
                 window = Bytes.make window_size '\000';
                 seen = 0;
                 hash = 0L;
                 current_length = 0;
                 current = Buffer.create max_size;
               }))

let emit current reversed =
  let chunk = Buffer.contents current in
  Buffer.clear current;
  chunk :: reversed

let feed splitter bytes =
  let chunks = ref [] in
  String.iter
    (fun incoming ->
      match splitter with
      | Fixed_splitter { chunk_size; current } ->
          Buffer.add_char current incoming;
          if Buffer.length current = chunk_size then chunks := emit current !chunks
      | Buzhash_splitter state ->
          let outgoing =
            if state.seen < state.window_size then None
            else Some (Bytes.get state.window (state.seen mod state.window_size))
          in
          state.hash <-
            Int64.logxor (rotate_left state.hash 1)
              buzhash_table.(Char.code incoming);
          Option.iter
            (fun character ->
              state.hash <-
                Int64.logxor state.hash
                  (rotate_left buzhash_table.(Char.code character)
                     state.window_size))
            outgoing;
          Bytes.set state.window (state.seen mod state.window_size) incoming;
          state.seen <- state.seen + 1;
          state.current_length <- state.current_length + 1;
          Buffer.add_char state.current incoming;
          let mask = Int64.of_int (state.average_size - 1) in
          let cut =
            state.current_length >= state.max_size
            || (state.current_length >= state.min_size
               && Int64.equal (Int64.logand state.hash mask) 0L)
          in
          if cut then (
            chunks := emit state.current !chunks;
            state.current_length <- 0))
    bytes;
  List.rev !chunks

let finish = function
  | Fixed_splitter { current; _ } | Buzhash_splitter { current; _ } ->
      if Buffer.length current = 0 then [] else emit current []

let split strategy bytes =
  match create_splitter strategy with
  | Error error -> Error error
  | Ok splitter ->
      let chunks = feed splitter bytes in
      Ok (chunks @ finish splitter)

let chunks_are_canonical strategy chunks =
  match validate strategy with
  | Error _ -> false
  | Ok () ->
      if List.exists String.is_empty chunks then false
      else
        match split strategy (String.concat "" chunks) with
        | Ok expected -> List.equal String.equal expected chunks
        | Error _ -> false
