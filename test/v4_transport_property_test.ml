module Transport = Yeokcham_v4_transport
module Trust = Yeokcham_v4_trust

let capability =
  Trust.signing_capability_of_private_key (String.make 32 'a') |> Result.get_ok

let publisher =
  Trust.signing_public_key capability
  |> Trust.device_of_public_key |> Result.get_ok

let repository =
  Trust.Repository_id.of_string
    "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
  |> Result.get_ok

let certificate =
  Trust.root_certificate ~repository ~device:publisher capability
  |> Result.get_ok |> Trust.certificate_id

let generated_linear_feeds_preserve_parent_availability =
  QCheck2.Test.make ~count:200
    ~name:"generated canonical relay feeds retain every parent before receipt"
    QCheck2.Gen.(int_range 0 40)
    (fun length ->
      let rec build parent reversed index =
        if index = length then List.rev reversed
        else
          let publication =
            Transport.create_publication ~repository ~publisher ~certificate
              ~parents:(Option.to_list parent)
              ~manifest:(Transport.sha256 ("manifest-" ^ string_of_int index))
              ~signing_capability:capability
            |> Result.get_ok
          in
          build
            (Some (Transport.publication_id publication))
            (publication :: reversed) (index + 1)
      in
      Transport.validate_feed ~known:[] (build None [] 0) |> Result.is_ok)

let () =
  Alcotest.run "V4 transport properties"
    [
      ( "feed",
        [
          QCheck_alcotest.to_alcotest
            generated_linear_feeds_preserve_parent_availability;
        ] );
    ]
