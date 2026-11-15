type hunk = { first : int; last : int; replacement : string list }

let max_bytes = 2 * 1024 * 1024
let max_cells = 4_000_000
let ( let* ) = Result.bind

let lines bytes =
  let length = String.length bytes in
  let rec loop start reversed =
    if start = length then Array.of_list (List.rev reversed)
    else
      match String.index_from_opt bytes start '\n' with
      | Some stop ->
          loop (stop + 1) (String.sub bytes start (stop + 1 - start) :: reversed)
      | None ->
          Array.of_list
            (List.rev (String.sub bytes start (length - start) :: reversed))
  in
  loop 0 []

let text bytes =
  (not (String.contains bytes '\000'))
  && Result.is_ok (Yeokcham_encoding.text bytes)

let diff ~base ~result =
  if String.length base > max_bytes || String.length result > max_bytes then
    Error "line-hunks-v1 exceeds 2 MiB per input"
  else if not (text base && text result) then
    Error "line-hunks-v1 requires UTF-8 without NUL"
  else if base = result then Ok []
  else
    let before = lines base and after = lines result in
    let n0 = Array.length before and m0 = Array.length after in
    let prefix = ref 0 and suffix = ref 0 in
    while !prefix < n0 && !prefix < m0 && before.(!prefix) = after.(!prefix) do
      incr prefix
    done;
    while
      !suffix < n0 - !prefix
      && !suffix < m0 - !prefix
      && before.(n0 - 1 - !suffix) = after.(m0 - 1 - !suffix)
    do
      incr suffix
    done;
    let n = n0 - !prefix - !suffix and m = m0 - !prefix - !suffix in
    if n + 1 > max_cells / (m + 1) then
      Error "line-hunks-v1 exceeds 4,000,000 alignment cells"
    else
      let scores = Array.make_matrix (n + 1) (m + 1) 0 in
      for i = n - 1 downto 0 do
        for j = m - 1 downto 0 do
          scores.(i).(j) <-
            (if before.(!prefix + i) = after.(!prefix + j) then
               1 + scores.(i + 1).(j + 1)
             else max scores.(i + 1).(j) scores.(i).(j + 1))
        done
      done;
      let pending = ref None and replacements = ref [] and hunks = ref [] in
      let begin_at i = if !pending = None then pending := Some (!prefix + i) in
      let flush i =
        match !pending with
        | None -> ()
        | Some first ->
            hunks :=
              {
                first;
                last = !prefix + i;
                replacement = List.rev !replacements;
              }
              :: !hunks;
            pending := None;
            replacements := []
      in
      let rec align i j =
        if i = n && j = m then flush i
        else if i < n && j < m && before.(!prefix + i) = after.(!prefix + j)
        then (
          flush i;
          align (i + 1) (j + 1))
        else if i < n && (j = m || scores.(i + 1).(j) >= scores.(i).(j + 1))
        then (
          begin_at i;
          align (i + 1) j)
        else (
          begin_at i;
          replacements := after.(!prefix + j) :: !replacements;
          align i (j + 1))
      in
      align 0 0;
      Ok (List.rev !hunks)

let apply ~base hunks =
  let source = lines base in
  let output = Buffer.create (String.length base) in
  let rec loop cursor = function
    | [] ->
        for i = cursor to Array.length source - 1 do
          Buffer.add_string output source.(i)
        done;
        Ok (Buffer.contents output)
    | h :: rest ->
        if h.first < cursor || h.last < h.first || h.last > Array.length source
        then Error "invalid or overlapping base-relative hunks"
        else (
          for i = cursor to h.first - 1 do
            Buffer.add_string output source.(i)
          done;
          List.iter (Buffer.add_string output) h.replacement;
          loop h.last rest)
  in
  loop 0 hunks

let overlaps a b =
  if a = b then false
  else if a.first = a.last && b.first = b.last then a.first = b.first
  else if a.first = a.last then b.first <= a.first && a.first <= b.last
  else if b.first = b.last then a.first <= b.first && b.first <= a.last
  else max a.first b.first < min a.last b.last

let merge ~base ~variants =
  let changed =
    List.filter (( <> ) base) variants |> List.sort_uniq String.compare
  in
  match changed with
  | [] -> Ok base
  | [ value ] -> Ok value
  | _ ->
      let* all =
        List.fold_left
          (fun acc value ->
            let* all = acc in
            let* hunks = diff ~base ~result:value in
            Ok (hunks @ all))
          (Ok []) changed
      in
      let all =
        List.sort_uniq
          (fun a b ->
            Stdlib.compare
              (a.first, a.last, a.replacement)
              (b.first, b.last, b.replacement))
          all
      in
      let rec check = function
        | [] | [ _ ] -> Ok ()
        | a :: (b :: _ as rest) ->
            if overlaps a b then Error "conflicting base-relative line hunks"
            else check rest
      in
      let* () = check all in
      apply ~base all
