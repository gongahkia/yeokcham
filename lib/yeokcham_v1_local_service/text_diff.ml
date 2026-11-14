type kind = Context | Removed | Added
type line = { kind : kind; text : string; newline : bool }

type hunk = {
  old_start : int;
  old_count : int;
  new_start : int;
  new_count : int;
  lines : line list;
}

type t = Text of hunk list | Opaque of string

let max_bytes = 2 * 1024 * 1024
let max_cells = 4_000_000

let lines bytes =
  let length = String.length bytes in
  let rec split start reversed =
    if start = length then Array.of_list (List.rev reversed)
    else
      match String.index_from_opt bytes start '\n' with
      | Some stop ->
          split (stop + 1)
            ((String.sub bytes start (stop - start), true) :: reversed)
      | None ->
          Array.of_list
            (List.rev
               ((String.sub bytes start (length - start), false) :: reversed))
  in
  split 0 []

let utf8 bytes = Result.is_ok (Yeokcham_encoding.text bytes)
let line kind (text, newline) = { kind; text; newline }
let old_width = function Context | Removed -> 1 | Added -> 0
let new_width = function Context | Added -> 1 | Removed -> 0

let hunks operations =
  let operations = Array.of_list operations in
  let length = Array.length operations in
  let ranges = ref [] in
  Array.iteri
    (fun i operation ->
      if operation.kind <> Context then
        let first = max 0 (i - 3) and last = min length (i + 4) in
        match !ranges with
        | (previous, stop) :: rest when first <= stop ->
            ranges := (previous, max stop last) :: rest
        | _ -> ranges := (first, last) :: !ranges)
    operations;
  let old_offsets = Array.make (length + 1) 0
  and new_offsets = Array.make (length + 1) 0 in
  Array.iteri
    (fun i operation ->
      old_offsets.(i + 1) <- old_offsets.(i) + old_width operation.kind;
      new_offsets.(i + 1) <- new_offsets.(i) + new_width operation.kind)
    operations;
  List.rev !ranges
  |> List.map (fun (first, last) ->
      let old_count = old_offsets.(last) - old_offsets.(first)
      and new_count = new_offsets.(last) - new_offsets.(first) in
      {
        old_start = (old_offsets.(first) + if old_count = 0 then 0 else 1);
        old_count;
        new_start = (new_offsets.(first) + if new_count = 0 then 0 else 1);
        new_count;
        lines = Array.sub operations first (last - first) |> Array.to_list;
      })

let compare ~before ~after =
  if String.length before > max_bytes || String.length after > max_bytes then
    Opaque "text display exceeds 2 MiB per side"
  else if
    String.contains before '\000'
    || String.contains after '\000'
    || not (utf8 before && utf8 after)
  then Opaque "opaque bytes (NUL or invalid UTF-8)"
  else if before = after then Text []
  else
    let old = lines before and new_ = lines after in
    let old_length = Array.length old and new_length = Array.length new_ in
    let prefix = ref 0 in
    while
      !prefix < old_length && !prefix < new_length
      && old.(!prefix) = new_.(!prefix)
    do
      incr prefix
    done;
    let suffix = ref 0 in
    while
      !suffix < old_length - !prefix
      && !suffix < new_length - !prefix
      && old.(old_length - 1 - !suffix) = new_.(new_length - 1 - !suffix)
    do
      incr suffix
    done;
    let n = old_length - !prefix - !suffix
    and m = new_length - !prefix - !suffix in
    if n + 1 > max_cells / (m + 1) then
      Opaque "text alignment exceeds 4,000,000 cells"
    else
      let scores = Array.make_matrix (n + 1) (m + 1) 0 in
      for i = n - 1 downto 0 do
        for j = m - 1 downto 0 do
          scores.(i).(j) <-
            (if old.(!prefix + i) = new_.(!prefix + j) then
               1 + scores.(i + 1).(j + 1)
             else max scores.(i + 1).(j) scores.(i).(j + 1))
        done
      done;
      let reversed = ref [] in
      for i = 0 to !prefix - 1 do
        reversed := line Context old.(i) :: !reversed
      done;
      let rec align i j =
        if i = n && j = m then ()
        else if i < n && j < m && old.(!prefix + i) = new_.(!prefix + j) then (
          reversed := line Context old.(!prefix + i) :: !reversed;
          align (i + 1) (j + 1))
        else if i < n && (j = m || scores.(i + 1).(j) >= scores.(i).(j + 1))
        then (
          reversed := line Removed old.(!prefix + i) :: !reversed;
          align (i + 1) j)
        else (
          reversed := line Added new_.(!prefix + j) :: !reversed;
          align i (j + 1))
      in
      align 0 0;
      for i = old_length - !suffix to old_length - 1 do
        reversed := line Context old.(i) :: !reversed
      done;
      Text (hunks (List.rev !reversed))
