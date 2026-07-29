let test_unit () = Alcotest.(check bool) "true is true" true true

let reverse_involution =
  QCheck2.Test.make ~count:100 ~name:"reverse is involutive"
    QCheck2.Gen.(list int)
    (fun values -> List.rev (List.rev values) = values)

let () =
  Alcotest.run "foundation"
    [
      ("unit", [ Alcotest.test_case "assertions execute" `Quick test_unit ]);
      ( "property",
        [ QCheck_alcotest.to_alcotest ~speed_level:`Quick reverse_involution ]
      );
    ]
