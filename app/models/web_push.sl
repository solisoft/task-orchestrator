# WebPush — VAPID-signed Web Push delivery.
#
# Soli ships in-process VAPID primitives (`vapid_generate_keys`,
# `vapid_send`), so this helper does all crypto/HTTP work inside the
# runtime — no external CLI required.
#
# Keys are stored in the `Setting` key/value table under the keys
# `vapid_public_key` / `vapid_private_key` and generated lazily on
# first use, so the operator doesn't have to bake them into env vars.
#
# Test mock: when the sentinel file `/tmp/_task_orch_web_push.active`
# exists, every `send_to_all` invocation appends a JSON line
# `{ "payload": ... }` to `/tmp/_task_orch_web_push.log` and returns
# immediately — no real network call. The status-change spec uses this
# to assert call count. The mock gates on a filesystem sentinel rather
# than a `Setting` row because other specs run `Setting.delete_all()`
# in parallel against the shared test DB; the sentinel file isolates
# this hook from that contention.

const _web_push_vapid_subject = "mailto:noreply@task-orchestrator.local"
const _web_push_log_path = "/tmp/task-orch-push.log"

def _web_push_log(msg)
  let ts = DateTime.now().to_iso() rescue ""
  let line = "[" + ts + "] " + msg + "\n"
  let prev = (Trusted.read(_web_push_log_path) rescue "")
  Trusted.write(_web_push_log_path, prev + line)
end

# Send `payload` (a hash; serialised to JSON for the SW to parse) to
# every active subscription. Returns:
#   { "sent": N, "pruned": M, "mocked": Bool }
# Pruning happens when the push service returns 404/410 — those rows
# are dead and we don't want to keep retrying them.
def web_push_send_to_all(payload)
  let sentinel = "/tmp/_task_orch_web_push.active"
  if Trusted.exists(sentinel)
    let log_path = "/tmp/_task_orch_web_push.log"
    let prev = (Trusted.read(log_path) rescue "")
    let line = JSON.stringify({ "payload": payload }) + "\n"
    Trusted.write(log_path, prev + line)
    return { "sent": 0, "pruned": 0, "mocked": true }
  end
  let keys = web_push_ensure_keys()
  if keys == nil
    _web_push_log("web_push_send_to_all: no VAPID keys — skipping send")
    return { "sent": 0, "pruned": 0, "mocked": false }
  end
  let body = JSON.stringify(payload)
  let sent = 0
  let pruned = 0
  let count = 0
  for sub in PushSubscription.all()
    count = count + 1
    let res = _web_push_send_one(sub, body, keys)
    if res["pruned"]
      _web_push_log("web_push_send_to_all: pruned endpoint " + (sub.endpoint ?? "?"))
      PushSubscription.remove_by_endpoint(sub.endpoint) rescue null
      pruned = pruned + 1
    elsif res["ok"]
      sent = sent + 1
    else
      let short_ep = (sub.endpoint ?? "?")
      if short_ep.length() > 60
        short_ep = short_ep.substring(0, 60)
      end
      _web_push_log("web_push_send_to_all: send failed for " + short_ep + "...")
    end
  end
  _web_push_log("web_push_send_to_all: sent=" + str(sent) + " pruned=" + str(pruned) + " total=" + str(count))
  { "sent": sent, "pruned": pruned, "mocked": false }
end

# Return the stored VAPID public key, generating the keypair if it
# doesn't yet exist. Returns "" only if the builtin fails to produce
# a keypair (effectively unreachable in normal operation).
def web_push_public_key()
  let keys = web_push_ensure_keys()
  if keys == nil
    return ""
  end
  return keys["public"] ?? ""
end

# Lazily generate + cache the VAPID keypair. Returns
#   { "public": "...", "private": "..." }
# or nil only when `vapid_generate_keys` itself raises (so we still
# have a defensive path; callers degrade to an empty key). Once stored
# in `Setting`, the pair is reused across restarts so subscriptions
# remain valid.
def web_push_ensure_keys()
  let pub  = Setting.get("vapid_public_key")  ?? ""
  let priv = Setting.get("vapid_private_key") ?? ""
  if pub != "" and priv != ""
    return { "public": pub, "private": priv }
  end
  # Test override — specs seed these `Setting` rows so the helper
  # short-circuits with deterministic fake keys before reaching the
  # in-process builtin. Some specs feed bogus values intentionally to
  # exercise the per-row send/prune branches.
  let mock_pub  = Setting.get("vapid_test_public")  ?? ""
  let mock_priv = Setting.get("vapid_test_private") ?? ""
  if mock_pub != "" and mock_priv != ""
    Setting.set("vapid_public_key",  mock_pub)
    Setting.set("vapid_private_key", mock_priv)
    return { "public": mock_pub, "private": mock_priv }
  end
  let generated = vapid_generate_keys() rescue nil
  if generated == nil
    return nil
  end
  let new_pub  = generated["public_key"]  ?? ""
  let new_priv = generated["private_key"] ?? ""
  if new_pub == "" or new_priv == ""
    return nil
  end
  Setting.set("vapid_public_key",  new_pub)
  Setting.set("vapid_private_key", new_priv)
  return { "public": new_pub, "private": new_priv }
end

# Deliver a single subscription via the runtime's `vapid_send` builtin.
# Returns { "ok": Bool, "pruned": Bool }; `pruned` is true when the
# push service responded 404/410 so the caller drops the row.
#
# Test override: when the `Setting` row `web_push_test_send_outcome`
# is set to `"ok"` or `"pruned"`, return that outcome directly. Specs
# use this to exercise the per-row sent / pruned counter loop without
# making real HTTP calls.
def _web_push_send_one(sub, body, keys)
  let test_outcome = Setting.get("web_push_test_send_outcome") ?? ""
  if test_outcome == "ok"
    return { "ok": true, "pruned": false }
  end
  if test_outcome == "pruned"
    return { "ok": false, "pruned": true }
  end
  let subscription = {
    "endpoint": sub.endpoint,
    "keys": {
      "p256dh": sub.p256dh ?? "",
      "auth":   sub.auth   ?? ""
    }
  }
  try
    let res = vapid_send(
      subscription,
      body,
      keys["private"],
      keys["public"],
      _web_push_vapid_subject
    )
    let status = res["status"] ?? 0
        if status < 200 or status >= 300
      let ep_short = (sub.endpoint ?? "?")
      if ep_short.length() > 60
        ep_short = ep_short.substring(0, 60)
      end
      _web_push_log("_web_push_send_one: vapid_send returned status " + str(status) +
                    " for " + ep_short + "... body=" + (res["body"] ?? ""))
    end
    return _web_push_outcome_from_status(status)
  catch e
    let short_ep = (sub.endpoint ?? "?")
    if short_ep.length() > 60
      short_ep = short_ep.substring(0, 60)
    end
    _web_push_log("_web_push_send_one: vapid_send threw for " + short_ep +
                  "...: " + str(e))
    return { "ok": false, "pruned": false }
  end
end

# Decode a push-service HTTP status into the `{ ok, pruned }` shape
# the loop counter expects. 404/410 mean the subscription is dead and
# the row should be dropped; 2xx is a successful delivery; anything
# else is a transient or unexpected failure that we count as neither.
def _web_push_outcome_from_status(status)
  if status == 404 or status == 410
    return { "ok": false, "pruned": true }
  end
  if status >= 200 and status < 300
    return { "ok": true, "pruned": false }
  end
  return { "ok": false, "pruned": false }
end
