  5. Add a transport adapter only after verified receive is sound.
  6. Consider Git import/export after V4’s local and receive semantics are
     stable.
  7. Add macOS/WSL watchers only after the Linux proof and CI baseline;
     WSL needs real field testing rather than assuming inotify behavior.
  8. Leave CI-backed delivery late. It needs separate validation evidence
     and policy; automatically treating a CI result as deliver would
     violate the model’s rule that delivery is not approval.
  9. Retire V1–V3 last, through explicit deprecation/archive/migration
     policy—not deletion—once V4 has replacement paths.
