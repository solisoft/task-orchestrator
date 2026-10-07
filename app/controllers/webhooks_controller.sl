# WebhooksController — GitHub / GitLab PR-event ingestion.
#
# Unscoped routes (no session): each request authenticates itself
# against a Setting-stored secret instead. GitHub signs the raw body
# with HMAC-SHA256 (`X-Hub-Signature-256: sha256=<hex>`); GitLab sends
# the shared secret verbatim in `X-Gitlab-Token`. A missing secret is a
# hard 401 — we never accept unsigned deliveries.
#
# Response policy: 401 for auth failures, 400 for unparseable JSON, and
# 200 for everything else — including "no matching task" and malformed-
# but-authenticated payloads. Non-2xx makes both providers retry, and a
# payload we couldn't act on now won't be more actionable on redelivery.
class WebhooksController < ApplicationController

  # POST /webhooks/github — `pull_request` events.
  def github(req)
    secrets = Setting.webhook_secrets("github")
    if secrets.length() == 0
      return {"status": 401, "body": "github_webhook_secret not configured"}
    end

    signature = req["headers"]["x-hub-signature-256"] ?? ""
    if !this._signature_ok(req["body"] ?? "", signature, secrets)
      return {"status": 401, "body": "bad signature"}
    end

    event = req["headers"]["x-github-event"] ?? ""
    return {"status": 200, "body": "pong"} if event == "ping"
    return {"status": 200, "body": "ignored event: " + event} if event != "pull_request"

    payload = req["json"]
    return {"status": 400, "body": "unparseable JSON body"} if payload.nil?

    pr = payload["pull_request"] ?? {}
    repo = payload["repository"] ?? {}
    ev = {
      "host": "github",
      "event_id": req["headers"]["x-github-delivery"] ?? "",
      "action": payload["action"] ?? "",
      "pr_url": pr["html_url"] ?? "",
      "pr_number": pr["number"],
      "branch": (pr["head"] ?? {})["ref"] ?? "",
      "draft": pr["draft"] == true,
      "merged": pr["merged"] == true,
      "repo_full_name": repo["full_name"] ?? "",
      "clone_urls": [repo["clone_url"] ?? "", repo["ssh_url"] ?? "", repo["html_url"] ?? ""]
    }
    result = this._apply_event(ev) rescue nil
    result ?? {"status": 200, "body": "malformed payload ignored"}
  end

  # POST /webhooks/gitlab — `Merge Request Hook` events.
  def gitlab(req)
    secrets = Setting.webhook_secrets("gitlab")
    if secrets.length() == 0
      return {"status": 401, "body": "gitlab_webhook_secret not configured"}
    end

    token = req["headers"]["x-gitlab-token"] ?? ""
    if !this._token_ok(token, secrets)
      return {"status": 401, "body": "bad token"}
    end

    event = req["headers"]["x-gitlab-event"] ?? ""
    if event != "Merge Request Hook"
      return {"status": 200, "body": "ignored event: " + event}
    end

    payload = req["json"]
    return {"status": 400, "body": "unparseable JSON body"} if payload.nil?

    oa = payload["object_attributes"] ?? {}
    repo = payload["project"] ?? {}
    # Newer GitLab sends `draft`; older versions only `work_in_progress`.
    draft = oa["draft"] == true || oa["work_in_progress"] == true
    # GitLab has no delivery-id header — synthesise one from fields that
    # change with every meaningful event so duplicates short-circuit.
    event_id = "gitlab:" + (oa["url"] ?? "") + ":" + (oa["action"] ?? "") + ":" + str(oa["updated_at"] ?? "")
    merged = (oa["action"] ?? "") == "merge" || (oa["state"] ?? "") == "merged"
    ev = {
      "host": "gitlab",
      "event_id": event_id,
      "action": this._gitlab_action(oa),
      "pr_url": oa["url"] ?? "",
      "pr_number": oa["iid"],
      "branch": oa["source_branch"] ?? "",
      "draft": draft,
      "merged": merged,
      "repo_full_name": repo["path_with_namespace"] ?? "",
      "clone_urls": [repo["git_http_url"] ?? "", repo["git_ssh_url"] ?? "", repo["web_url"] ?? ""]
    }
    result = this._apply_event(ev) rescue nil
    result ?? {"status": 200, "body": "malformed payload ignored"}
  end

  # True when the GitHub HMAC signature matches any configured secret —
  # global or per-project; the project isn't known until the (verified)
  # payload is parsed, so every candidate gets a constant-time try.
  def _signature_ok(body, signature, secrets)
    for secret in secrets
      expected = "sha256=" + Crypto.hmac(body, secret)
      return true if Crypto.secure_compare(expected, signature)
    end
    false
  end

  # GitLab counterpart: the token is sent verbatim, compare against each
  # configured secret.
  def _token_ok(token, secrets)
    for secret in secrets
      return true if Crypto.secure_compare(token, secret)
    end
    false
  end

  # Translate GitLab's MR action vocabulary into the GitHub-shaped one
  # `_apply_event` consumes. GitLab signals draft flips as a generic
  # `update` — we recover the direction from the draft flag at apply time.
  def _gitlab_action(oa)
    action = oa["action"] ?? ""
    return "opened" if action == "open" || action == "reopen"
    return "closed" if action == "merge" || action == "close"
    return "update" if action == "update"
    action
  end

  # Shared GitHub/GitLab core: find the card, dedup, apply the transition.
  # `ev` is the normalised event hash both webhook actions build.
  def _apply_event(ev)
    task = this._find_task(ev)
    if task.nil?
      return {"status": 200, "body": "no matching task"}
    end

    # Replay guard — providers redeliver on timeouts/manual retries.
    # Status guards in the pr_* helpers make duplicates harmless anyway;
    # this just skips the redundant save + log line.
    if ev["event_id"] != "" && task.pr_event_id == ev["event_id"]
      return {"status": 200, "body": "duplicate delivery ignored"}
    end

    task.change_author = "webhook:" + ev["host"]
    task.pr_event_id = ev["event_id"]
    this._apply_action(task, ev)
    {"status": 200, "body": "ok"}
  end

  # Action → Task transition. GitLab actions arrive pre-translated to
  # this GitHub-shaped vocabulary by `_gitlab_action`.
  def _apply_action(task, ev)
    action = ev["action"]
    if action == "opened" || action == "reopened"
      return task.pr_opened!(ev["pr_url"], ev["pr_number"], ev["host"], ev["draft"])
    end

    return task.pr_state!("open") if action == "ready_for_review"
    return task.pr_state!("draft") if action == "converted_to_draft"
    if action == "update"
      # GitLab draft flips arrive as a generic `update`; mirror the flag.
      state = ev["draft"] ? "draft" : "open"
      return task.pr_state!(state)
    end

    return this._apply_closed(task, ev) if action == "closed"
    # synchronize / labeled / assigned / … — nothing card-worthy, but
    # persist the event id we already stamped so dedup stays accurate.
    task.save()
  end

  # Closed PR: merged → auto-done (+ feature stage refresh), otherwise
  # the card flips to failed so the board surfaces the dropped work.
  def _apply_closed(task, ev)
    if ev["merged"]
      task.pr_merged_done!()
      Feature.refresh_for_task(task) rescue null
    else
      task.pr_closed_failed!("PR closed without merge")
    end
  end

  # Card lookup, cheap → expensive:
  #   1. pr_url match — the normal flow, `bin/task-run` stored it.
  #   2. branch fallback — a `task/<slug>` branch + repo→project mapping;
  #      this is also the auto-link path for PRs opened by hand.
  def _find_task(ev)
    task = Task.find_by_pr_url(ev["pr_url"])
    return task if task.present?

    branch = ev["branch"] ?? ""
    prefix = "task/"
    return nil if !branch.starts_with(prefix)
    slug = branch.substring(prefix.length(), branch.length())
    return nil if slug == ""
    project = Run.project_for_repo(ev["repo_full_name"], ev["clone_urls"])
    return nil if project.nil?
    Task.find_by_slug(project, slug)
  end
end
