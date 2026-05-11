# WebPush — VAPID-signed Web Push delivery.
#
# Soli has no native ECDSA primitive, so we shell out to the Node
# `web-push` CLI for both VAPID key generation and per-subscription
# delivery. The CLI is a single dependency (`npm i -g web-push`).
#
# Keys are stored in the `Setting` key/value table under the keys
# `vapid_public_key` / `vapid_private_key` and generated lazily on
# first use, so the operator doesn't have to bake them into env vars.
#
# Test mock: when the sentinel file `/tmp/_task_orch_web_push.active`
# exists, every `send_to_all` invocation appends a JSON line
# `{ "payload": ... }` to `/tmp/_task_orch_web_push.log` and returns
# immediately — no real network or shell call. The status-change spec
# uses this to assert call count. The mock gates on a filesystem
# sentinel rather than a `Setting` row because other specs run
# `Setting.delete_all()` in parallel against the shared test DB; the
# sentinel file isolates this hook from that contention.

const _web_push_vapid_subject = "mailto:noreply@task-orchestrator.local"

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
    return { "sent": 0, "pruned": 0, "mocked": false }
  end
  let body = JSON.stringify(payload)
  let sent = 0
  let pruned = 0
  for sub in PushSubscription.all()
    let res = _web_push_send_one(sub, body, keys)
    if res["pruned"]
      PushSubscription.remove_by_endpoint(sub.endpoint) rescue null
      pruned = pruned + 1
    elsif res["ok"]
      sent = sent + 1
    end
  end
  { "sent": sent, "pruned": pruned, "mocked": false }
end

# Return the stored VAPID public key, generating the keypair if it
# doesn't yet exist. Returns "" if generation fails (e.g. `web-push`
# CLI not installed) — the caller surfaces an empty body to the SW.
def web_push_public_key()
  let keys = web_push_ensure_keys()
  if keys == nil
    return ""
  end
  return keys["public"] ?? ""
end

# Lazily generate + cache the VAPID keypair. Returns
#   { "public": "...", "private": "..." }
# or nil when the CLI isn't available. Once stored in `Setting`, the
# pair is reused across restarts so subscriptions remain valid.
def web_push_ensure_keys()
  let pub  = Setting.get("vapid_public_key")  ?? ""
  let priv = Setting.get("vapid_private_key") ?? ""
  if pub != "" and priv != ""
    return { "public": pub, "private": priv }
  end
  # Test override — skip the shell call entirely. Specs seed these
  # `Setting` rows so the helper short-circuits before shelling out
  # to the Node CLI (which the spec environment doesn't have).
  let mock_pub  = Setting.get("vapid_test_public")  ?? ""
  let mock_priv = Setting.get("vapid_test_private") ?? ""
  if mock_pub != "" and mock_priv != ""
    Setting.set("vapid_public_key",  mock_pub)
    Setting.set("vapid_private_key", mock_priv)
    return { "public": mock_pub, "private": mock_priv }
  end
  let res = System.run_sync(["bash", "-c",
    "web-push generate-vapid-keys --json 2>/dev/null"]) rescue nil
  if res == nil or res["exit_code"] != 0
    return nil
  end
  let parsed = JSON.parse(res["stdout"] ?? "") rescue nil
  if parsed == nil
    return nil
  end
  let new_pub  = parsed["publicKey"]  ?? ""
  let new_priv = parsed["privateKey"] ?? ""
  if new_pub == "" or new_priv == ""
    return nil
  end
  Setting.set("vapid_public_key",  new_pub)
  Setting.set("vapid_private_key", new_priv)
  return { "public": new_pub, "private": new_priv }
end

# Shell out to `web-push send-notification` for a single subscription.
# Returns { "ok": Bool, "pruned": Bool }; `pruned` is true when the
# push service rejected with 404/410 so the caller drops the row.
#
# Test override: when the `Setting` row `web_push_test_send_outcome`
# is set to `"ok"` or `"pruned"`, return that outcome directly. Specs
# use this to exercise the per-row sent / pruned counter loop without
# needing the Node CLI installed.
def _web_push_send_one(sub, body, keys)
  let test_outcome = Setting.get("web_push_test_send_outcome") ?? ""
  if test_outcome == "ok"
    return { "ok": true, "pruned": false }
  end
  if test_outcome == "pruned"
    return { "ok": false, "pruned": true }
  end
  let cmd = ["web-push", "send-notification",
             "--endpoint=" + sub.endpoint,
             "--key=" + (sub.p256dh ?? ""),
             "--auth=" + (sub.auth ?? ""),
             "--vapid-subject=" + _web_push_vapid_subject,
             "--vapid-pubkey=" + keys["public"],
             "--vapid-pvtkey=" + keys["private"],
             "--payload=" + body]
  let res = System.run_sync(cmd) rescue nil
  if res == nil
    return { "ok": false, "pruned": false }
  end
  if res["exit_code"] == 0
    return { "ok": true, "pruned": false }
  end
  let combined = (res["stdout"] ?? "") + (res["stderr"] ?? "")
  if combined.contains("404") or combined.contains("410")
    return { "ok": false, "pruned": true }
  end
  return { "ok": false, "pruned": false }
end
