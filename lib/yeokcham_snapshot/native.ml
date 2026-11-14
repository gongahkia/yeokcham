type kind = File | Directory | Link | Fifo | Socket | Character | Block
type directory

external open_at : Unix.file_descr option -> string -> bool -> Unix.file_descr
  = "yeokcham_scan_open_at"

external inspect_at : Unix.file_descr -> string -> kind * string
  = "yeokcham_scan_inspect_at"

external fingerprint : Unix.file_descr -> string = "yeokcham_scan_fingerprint"

external readlink_at : Unix.file_descr -> string -> string
  = "yeokcham_scan_readlink_at"

external open_directory : Unix.file_descr -> directory
  = "yeokcham_scan_open_directory"

external read_directory : directory -> string = "yeokcham_scan_read_directory"
external close_directory : directory -> unit = "yeokcham_scan_close_directory"

let names descriptor =
  let directory = open_directory descriptor in
  Fun.protect
    ~finally:(fun () -> close_directory directory)
    (fun () ->
      let rec loop reversed =
        match read_directory directory with
        | "." | ".." -> loop reversed
        | name -> loop (name :: reversed)
        | exception End_of_file -> List.sort String.compare reversed
      in
      loop [])
