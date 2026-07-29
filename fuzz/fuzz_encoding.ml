module Encoding = Paengi_encoding

let read_file path =
  let channel = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr channel)
    (fun () -> In_channel.input_all channel)

let check input =
  match Encoding.decode input with
  | Error _ -> ()
  | Ok value ->
      if not (String.equal input (Encoding.encode value)) then
        failwith "decoder accepted non-canonical input"

let () =
  match Array.to_list Sys.argv with
  | [ _; input_path ] ->
      AflPersistent.run (fun () -> check (read_file input_path))
  | _ -> invalid_arg "usage: fuzz_encoding INPUT"
