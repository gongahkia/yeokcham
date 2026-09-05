module Envelope = Yeokcham_envelope
module Gc = Yeokcham_v1_gc
module Store = Yeokcham_store

let id value =
  let nibble = "0123456789abcdef".[value mod 16] in
  Store.Stored_object_id.of_hex (String.make 64 nibble) |> Result.get_ok

let info value =
  {
    Store.id = id value;
    object_type = (if value mod 2 = 0 then Envelope.Content else Envelope.Tree);
    stored_bytes = value + 1;
  }

let root_never_becomes_collectable =
  QCheck2.Test.make ~count:200
    ~name:"V1 GC never classifies a declared reachable object as collectable"
    QCheck2.Gen.(pair (int_range 1 15) (int_range 0 14))
    (fun (count, selected) ->
      let objects = List.init count info in
      let state_head = id 15 in
      let objects =
        {
          Store.id = state_head;
          object_type = Envelope.V1_project_state;
          stored_bytes = 1;
        }
        :: objects
      in
      let selected = id (selected mod count) in
      match
        Gc.classify ~state_head ~objects
          ~reachable:[ (selected, [ Gc.State_head ]) ]
      with
      | Error _ -> false
      | Ok plan ->
          List.exists
            (fun object_ ->
              Store.Stored_object_id.equal object_.Gc.object_id selected
              &&
              match object_.Gc.disposition with
              | Gc.Retain _ -> true
              | Gc.Collect -> false)
            plan.Gc.objects)

let () =
  Alcotest.run "V1 GC properties"
    [
      ( "reachability",
        [ QCheck_alcotest.to_alcotest root_never_becomes_collectable ] );
    ]
