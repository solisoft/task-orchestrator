# PushSubscription — one row per browser subscription returned by the
# Push API. The `endpoint` URL is the natural identity (the browser /
# push service issues one endpoint per device + service-worker
# registration), so we upsert by it and rely on the unique index from
# the migration to reject duplicates at the DB level.
#
# Fields:
#   endpoint   — the push-service URL the server POSTs payloads to
#   p256dh     — the user-agent's public ECDH key (base64url)
#   auth       — the user-agent's auth secret (base64url)
#   user_agent — UA string at subscribe time, kept for debugging
#   created_at — ISO timestamp set on first save

class PushSubscription < Model
  validates("endpoint", { "presence": true })
  validates("p256dh",   { "presence": true })
  validates("auth",     { "presence": true })

  before_save("touch_timestamps")

  static def find_by_endpoint(endpoint)
    PushSubscription.find_by("endpoint", endpoint)
  end

  # Upsert: if a row with this endpoint exists, refresh the keys/UA
  # (the browser may have rotated keys); otherwise create a new row.
  # Returns the persisted instance — caller should check `_errors`.
  static def upsert(attrs)
    let endpoint = attrs["endpoint"]
    let existing = PushSubscription.find_by_endpoint(endpoint)
    if existing == nil
      return PushSubscription.create(attrs)
    end
    existing.p256dh     = attrs["p256dh"]     ?? existing.p256dh
    existing.auth       = attrs["auth"]       ?? existing.auth
    existing.user_agent = attrs["user_agent"] ?? existing.user_agent
    existing.save()
    return existing
  end

  # Remove the row whose endpoint matches. Returns true if a row was
  # deleted, false otherwise. Used by the controller's `destroy` action
  # and by the helper when the push service responds 404/410 (dead
  # endpoint — don't keep retrying).
  static def remove_by_endpoint(endpoint)
    let existing = PushSubscription.find_by_endpoint(endpoint)
    if existing == nil
      return false
    end
    existing.delete()
    return true
  end

  def touch_timestamps()
    if self.created_at == nil
      self.created_at = DateTime.now().to_iso()
    end
  end
end
