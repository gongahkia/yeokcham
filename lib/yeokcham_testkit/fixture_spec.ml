type path = string list
type mode = Regular | Executable
type file_entry = { file_path : path; contents : string; mode : mode }
type symlink_entry = { link_path : path; target : path }
type entry = File of file_entry | Symlink of symlink_entry
type t = entry list

let entry_path = function
  | File file -> file.file_path
  | Symlink link -> link.link_path

let path_string = String.concat "/"
let compare_entry left right = compare (entry_path left) (entry_path right)
let equal = ( = )
let entry_count = List.length

let valid_component component =
  component <> "" && component <> "." && component <> ".."
  && (not (String.contains component '/'))
  && (not (String.contains component '\\'))
  && not (String.contains component '\000')

let valid_path = function
  | [] -> false
  | path -> List.for_all valid_component path

let rec is_prefix prefix path =
  match (prefix, path) with
  | [], _ -> true
  | _, [] -> false
  | prefix_head :: prefix_tail, path_head :: path_tail ->
      String.equal prefix_head path_head && is_prefix prefix_tail path_tail

let validate entries =
  let invalid_entry =
    List.find_opt
      (function
        | File file -> not (valid_path file.file_path)
        | Symlink link ->
            (not (valid_path link.link_path)) || not (valid_path link.target))
      entries
  in
  match invalid_entry with
  | Some entry ->
      Error
        (Printf.sprintf "invalid fixture path: %s"
           (path_string (entry_path entry)))
  | None -> (
      let sorted = List.sort compare_entry entries in
      if sorted <> entries then
        Error "fixture entries are not canonically ordered"
      else
        let paths = List.map entry_path entries in
        let rec find_conflict = function
          | [] -> None
          | path :: rest ->
              if List.exists (fun candidate -> is_prefix path candidate) rest
              then Some path
              else find_conflict rest
        in
        match find_conflict paths with
        | Some path ->
            Error
              (Printf.sprintf "conflicting fixture path: %s" (path_string path))
        | None -> Ok ())

let generated_bytes ~seed length =
  let multiplier = 6364136223846793005L in
  let increment = 1442695040888963407L in
  let state = ref (Int64.of_int seed) in
  String.init length (fun _ ->
      state := Int64.add (Int64.mul !state multiplier) increment;
      Int64.(to_int (logand (shift_right_logical !state 56) 255L)) |> Char.chr)

let file ?(mode = Regular) file_path contents =
  File { file_path; contents; mode }

let generate ~seed =
  let invalid_prefix =
    String.init 4 (function
      | 0 -> '\000'
      | 1 -> '\255'
      | 2 -> '\254'
      | _ -> '\128')
  in
  let wide =
    List.init 16 (fun index ->
        file
          [ "wide"; Printf.sprintf "file-%02d.txt" index ]
          (Printf.sprintf "fixture %02d seed %d\n" index seed))
  in
  let entries =
    [
      file
        [ "binary"; "non-utf8.bin" ]
        (invalid_prefix ^ generated_bytes ~seed 252);
      file
        [
          "deep";
          "level-01";
          "level-02";
          "level-03";
          "level-04";
          "level-05";
          "level-06";
          "level-07";
          "level-08";
          "leaf.txt";
        ]
        "deep fixture\n";
      file [ "empty" ] "";
      Symlink { link_path = [ "hello-link" ]; target = [ "text"; "hello.txt" ] };
      file [ "large"; "changing.bin" ] (generated_bytes ~seed 65536);
      file [ "lines"; "mixed.txt" ] "unix\nwindows\r\nclassic\r";
      file ~mode:Executable [ "mode"; "run.sh" ] "#!/bin/sh\nexit 0\n";
      file [ "text"; "hello.txt" ] "hello, yeokcham\n";
      file [ "unicode"; "paëngi-한글.txt" ] "unicode path\n";
    ]
    @ wide
  in
  List.sort compare_entry entries
