(** Read-only local V4 health observations.

    [verify] uses the GC closure walk without its mutation lock path, then
    checks local repair-plan records. It never creates a lock, plan, object,
    quarantine, journal, or ordinary source file. *)

val verify : root:string -> Yeokcham_v4_health.report
