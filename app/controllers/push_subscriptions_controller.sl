# PushSubscriptionsController — browser subscribe / unsubscribe + a
# read-only endpoint the service worker hits to fetch the current
# VAPID public key.
#
# The browser POSTs the JSON payload `PushSubscription.toJSON()`
# produces:
#   { "endpoint": "...", "keys": { "p256dh": "...", "auth": "..." } }
# We flatten it into our model's columns. Mass-assignment is gated
# through `_permit_params`.

# POST /push_subscriptions
# Subscribe (or refresh) the calling browser. Idempotent: a repeated
# subscribe with the same endpoint refreshes the keys instead of
# erroring on the unique index.
fn create(req)
  let attrs = _push_permit_params(req)
  if attrs["endpoint"] == "" or attrs["p256dh"] == "" or attrs["auth"] == ""
    return _push_json(422, { "error": "endpoint, keys.p256dh, and keys.auth are required" })
  end
  let sub = PushSubscription.upsert(attrs)
  if sub._errors
    return _push_json(422, { "error": "save failed", "details": sub._errors })
  end
  return _push_json(201, { "ok": true, "endpoint": sub.endpoint })
end

# DELETE /push_subscriptions
# Unsubscribe by endpoint. The browser sends the same JSON shape it
# used to subscribe so we can look the row up without a server-side
# session.
fn destroy(req)
  let attrs = _push_permit_params(req)
  if attrs["endpoint"] == ""
    return _push_json(422, { "error": "endpoint is required" })
  end
  let removed = PushSubscription.remove_by_endpoint(attrs["endpoint"])
  if not removed
    return _push_json(404, { "ok": false, "error": "no such subscription" })
  end
  return _push_json(200, { "ok": true })
end

# GET /push/vapid-public-key
# Plain-text response so the SW / page script can fetch + base64-decode
# without going through JSON. An empty body means VAPID isn't
# configured on the server (e.g. the `web-push` CLI is missing) — the
# client treats that as "push disabled".
fn vapid_public_key(req)
  let key = web_push_public_key()
  return {
    "status": 200,
    "headers": { "Content-Type": "text/plain; charset=utf-8" },
    "body": key
  }
end

# Whitelist allowed fields. Reads from `req["json"]` first (the browser
# uses fetch() with JSON), falling back to merged form/query so plain
# form posts and the test client both work.
fn _push_permit_params(req)
  let merged = req["json"] ?? req["all"] ?? req["form"] ?? req["params"] ?? {}
  let endpoint = (merged["endpoint"] ?? "").trim()
  let keys = merged["keys"] ?? {}
  let p256dh = ""
  let auth = ""
  if keys != nil
    p256dh = (keys["p256dh"] ?? "").trim()
    auth   = (keys["auth"]   ?? "").trim()
  end
  # Some browsers POST the keys flat ({endpoint, p256dh, auth}); accept
  # that shape too so the controller works regardless of how the SW
  # serialises the subscription.
  if p256dh == ""
    p256dh = (merged["p256dh"] ?? "").trim()
  end
  if auth == ""
    auth = (merged["auth"] ?? "").trim()
  end
  let user_agent = (req["headers"]["user-agent"] ?? "").trim()
  return {
    "endpoint":   endpoint,
    "p256dh":     p256dh,
    "auth":       auth,
    "user_agent": user_agent
  }
end

# Build a JSON response with the conventional Content-Type.
fn _push_json(status, body)
  return {
    "status":  status,
    "headers": { "Content-Type": "application/json; charset=utf-8" },
    "body":    JSON.stringify(body)
  }
end
