(** The explicit V1 archive and V2 cutover boundary from ADR-047.

    The adapter never converts V1 state.  It classifies the metadata root,
    archives a validated legacy tree by same-parent rename, and permits a
    fresh V2 root only after the external archive manifest verifies. *)

type classification =
  | Empty
  | V2
  | Legacy
  | Mixed_or_unknown of string
  | Incomplete of string

type manifest
type archive_plan

type archive_result = {
  archive_path : string;
  manifest_path : string;
}

type archive_outcome = Archived of archive_result | Already_archived of archive_result
type reset_outcome = Reset | Already_reset

type error =
  | Root_not_directory of string
  | Io_error of { operation : string; path : string; message : string }
  | Unsafe_archive_name of string
  | Not_legacy of classification
  | Archive_already_exists of string
  | Manifest_already_exists of string
  | Pending_manifest_mismatch of string
  | Archive_incomplete of string
  | Archive_manifest_invalid of { path : string; detail : string }
  | Archive_verification_failed of { path : string; detail : string }
  | Confirmation_required
  | V2_initialization_error of Yeokcham_store.error

val classification_to_string : classification -> string
val error_to_string : error -> string

(** [detect ~root] is read-only.  It fails closed on symlinks, malformed
    layouts, unknown content, and the V2-marker/V1-data hybrid. *)
val detect : root:string -> (classification, error) result

(** [plan_archive] requires a currently valid legacy metadata directory and a
    safe previously-unused same-parent archive name. *)
val plan_archive : root:string -> archive_name:string -> (archive_plan, error) result

(** [archive] performs the archive plan, or explicitly resumes publication of
    a manifest whose durable pending bytes already verify the relocated tree. *)
val archive : root:string -> archive_name:string -> (archive_outcome, error) result

(** [reset] requires an already verified archive and [confirm:true].  It
    creates only an empty V2 root and never changes the archived V1 tree. *)
val reset :
  root:string -> archive_name:string -> confirm:bool -> (reset_outcome, error) result

val manifest_encode : manifest -> string
val manifest_decode : string -> (manifest, string) result
