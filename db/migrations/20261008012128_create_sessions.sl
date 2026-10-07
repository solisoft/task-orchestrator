# Migration: create_sessions
#
# Backing collection for the `solidb` session driver
# (`SOLI_SESSION_DRIVER=solidb`, `SOLI_SOLIDB_COLLECTION=sessions`). The
# driver reads/writes documents keyed by session id but never creates its
# collection, so it has to exist before the server takes a login.
# `last_accessed` is what the driver's expiry sweep filters on
# (`FILTER doc.last_accessed < @cutoff REMOVE doc`).
fn up(db) -> Any
  db.create_collection("sessions")

  db.create_index("sessions", "idx_sessions_last_accessed", ["last_accessed"], {})
end

fn down(db) -> Any
  db.drop_index("sessions", "idx_sessions_last_accessed")
  db.drop_collection("sessions")
end
