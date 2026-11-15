val intent : Yeokcham_v1_store.loaded -> Yeokcham_v1_transport.Core_clone.intent option
val recovered : Yeokcham_v1_store.loaded -> Yeokcham_v1_transport.Core_clone.intent -> bool
val pending : Yeokcham_v1_store.loaded -> bool
val require_normal : Yeokcham_v1_store.loaded -> (unit, string) result
val check_plan : Yeokcham_v1_store.loaded -> Yeokcham_v1_model.Core.Plan_id.t -> (unit, string) result
val check_preparation : Yeokcham_v1_store.loaded -> Yeokcham_v1_model.Core.Digest.t -> (unit, string) result
