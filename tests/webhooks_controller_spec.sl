# WebhooksController — GitHub/GitLab PR-event ingestion. The routes are
# unscoped (no login), but every delivery must authenticate against the
# Setting-stored secret: HMAC-SHA256 over the raw body for GitHub, plain
# token compare for GitLab. The specs drive the real HTTP path with a
# pre-serialised JSON body string so the signature is computed over the
# exact bytes the server receives.

fn _wh_secret
  "wh-spec-secret"
end

# Same trick as `_tq_origin` in tasks_controller_spec — probe a GET to
# discover the dynamic test-server host so cookie-bearing POSTs (a prior
# spec may have left a session in the jar) pass the CSRF origin check.
fn _wh_origin
  probe = get("/login")
  url = probe["url"] ?? ""
  prefix = "http://"
  return url if !url.starts_with(prefix)
  rest = url.substring(prefix.length(), url.length())
  slash = rest.index_of("/")
  return prefix + rest.substring(0, slash) if slash > 0
  url
end

fn _wh_github_payload(action, pr_url, branch, merged, draft)
  {
    "action": action,
    "pull_request": {
      "html_url": pr_url,
      "number": 7,
      "head": {"ref": branch},
      "merged": merged,
      "draft": draft
    },
    "repository": {
      "full_name": "acme/widget",
      "clone_url": "https://github.example.com/acme/widget.git",
      "ssh_url": "git@github.example.com:acme/widget.git",
      "html_url": "https://github.example.com/acme/widget"
    }
  }
end

fn _wh_post_github(payload, delivery_id)
  body = payload.to_json
  sig = "sha256=" + Crypto.hmac(body, _wh_secret())
  pst = post
  pst("/webhooks/github", body, {"headers": {
    "Origin": _wh_origin(),
    "Content-Type": "application/json",
    "x-github-event": "pull_request",
    "x-github-delivery": delivery_id,
    "x-hub-signature-256": sig
  }})
end

fn _wh_gitlab_payload(action, state, mr_url, branch, draft)
  {
    "object_kind": "merge_request",
    "object_attributes": {
      "action": action,
      "state": state,
      "url": mr_url,
      "iid": 9,
      "source_branch": branch,
      "work_in_progress": draft,
      "updated_at": "2026-06-03 10:00:00 UTC"
    },
    "project": {
      "path_with_namespace": "acme/widget",
      "git_http_url": "https://gitlab.example.com/acme/widget.git",
      "git_ssh_url": "git@gitlab.example.com:acme/widget.git",
      "web_url": "https://gitlab.example.com/acme/widget"
    }
  }
end

fn _wh_post_gitlab(payload, token)
  pst = post
  pst("/webhooks/gitlab", payload.to_json, {"headers": {
    "Origin": _wh_origin(),
    "Content-Type": "application/json",
    "x-gitlab-event": "Merge Request Hook",
    "x-gitlab-token": token
  }})
end

# Seed a task in `status` with an optional pr_url already attached.
fn _wh_seed_task(slug, status, pr_url)
  Task.create({
    "project": "proj",
    "slug": slug,
    "title": "webhook spec " + slug,
    "status": status,
    "pr_url": pr_url
  }, {"key": "proj--" + slug})
end

describe("WebhooksController#github auth", fn() {
  before_each(fn() {
    assert_test_db()
    Task.delete_all()
    Setting.delete_all()
    Setting.set("github_webhook_secret", _wh_secret())
  })

  test("rejects when no secret is configured", fn() {
    Setting.unset("github_webhook_secret")
    response = _wh_post_github(_wh_github_payload("opened", "https://x/pr/1", "task/a", false, false), "d-1")
    assert_eq(res_status(response), 401)
  })

  test("rejects a tampered signature", fn() {
    body = _wh_github_payload("opened", "https://x/pr/1", "task/a", false, false).to_json
    pst = post
    response = pst("/webhooks/github", body, {"headers": {
      "Origin": _wh_origin(),
      "Content-Type": "application/json",
      "x-github-event": "pull_request",
      "x-hub-signature-256": "sha256=deadbeef"
    }})
    assert_eq(res_status(response), 401)
  })

  test("accepts a delivery signed with a per-project secret only", fn() {
    Setting.unset("github_webhook_secret")
    Setting.set("github_webhook_secret:proj", _wh_secret())
    payload = _wh_github_payload("opened", "https://x/pr/2", "feature/none", false, false)
    response = _wh_post_github(payload, "d-2")
    assert_eq(res_status(response), 200)
  })

  test("acks a signed ping without touching tasks", fn() {
    body = {"zen": "Keep it logically awesome."}.to_json
    sig = "sha256=" + Crypto.hmac(body, _wh_secret())
    pst = post
    response = pst("/webhooks/github", body, {"headers": {
      "Origin": _wh_origin(),
      "Content-Type": "application/json",
      "x-github-event": "ping",
      "x-hub-signature-256": sig
    }})
    assert_eq(res_status(response), 200)
  })
})

describe("WebhooksController#github transitions", fn() {
  before_each(fn() {
    assert_test_db()
    Task.delete_all()
    Setting.delete_all()
    Setting.set("github_webhook_secret", _wh_secret())
  })

  test("merged PR moves a review task to done", fn() {
    _wh_seed_task("merge-me", "review", "https://x/pr/10")
    response = _wh_post_github(_wh_github_payload("closed", "https://x/pr/10", "task/merge-me", true, false), "d-10")
    assert_eq(res_status(response), 200)
    t = Task.find_by_slug("proj", "merge-me")
    assert_eq(t.status, "done")
    assert_eq(t.pr_state, "merged")
    assert_not_null(t.finished_at)
  })

  test("merged PR moves an inprogress task to done", fn() {
    _wh_seed_task("early-merge", "inprogress", "https://x/pr/11")
    response = _wh_post_github(_wh_github_payload("closed", "https://x/pr/11", "task/early-merge", true, false), "d-11")
    assert_eq(res_status(response), 200)
    t = Task.find_by_slug("proj", "early-merge")
    assert_eq(t.status, "done")
    assert_eq(t.pr_state, "merged")
  })

  test("merged PR leaves a done task untouched", fn() {
    _wh_seed_task("already-done", "done", "https://x/pr/12")
    payload = _wh_github_payload("closed", "https://x/pr/12", "task/already-done", true, false)
    response = _wh_post_github(payload, "d-12")
    assert_eq(res_status(response), 200)
    t = Task.find_by_slug("proj", "already-done")
    assert_eq(t.status, "done")
    assert_eq(t.pr_state, "merged")
  })

  test("PR closed without merge fails the task", fn() {
    _wh_seed_task("close-me", "review", "https://x/pr/13")
    response = _wh_post_github(_wh_github_payload("closed", "https://x/pr/13", "task/close-me", false, false), "d-13")
    assert_eq(res_status(response), 200)
    t = Task.find_by_slug("proj", "close-me")
    assert_eq(t.status, "failed")
    assert_eq(t.pr_state, "closed")
    assert_eq(t.failure_reason, "PR closed without merge")
  })

  test("draft flips update pr_state without moving status", fn() {
    _wh_seed_task("draft-me", "inprogress", "https://x/pr/14")
    _wh_post_github(_wh_github_payload("converted_to_draft", "https://x/pr/14", "task/draft-me", false, true), "d-14a")
    t = Task.find_by_slug("proj", "draft-me")
    assert_eq(t.pr_state, "draft")
    assert_eq(t.status, "inprogress")
    _wh_post_github(_wh_github_payload("ready_for_review", "https://x/pr/14", "task/draft-me", false, false), "d-14b")
    t2 = Task.find_by_slug("proj", "draft-me")
    assert_eq(t2.pr_state, "open")
  })

  test("auto-links an opened PR by task/<slug> branch", fn() {
    _wh_seed_task("link-me", "inprogress", nil)
    Setting.set("_project_for_repo_mock", "proj")
    response = _wh_post_github(_wh_github_payload("opened", "https://x/pr/15", "task/link-me", false, false), "d-15")
    assert_eq(res_status(response), 200)
    t = Task.find_by_slug("proj", "link-me")
    assert_eq(t.pr_url, "https://x/pr/15")
    assert_eq(t.pr_state, "open")
    assert_eq(t.pr_host, "github")
    assert_eq(t.pr_number, 7)
  })

  test("duplicate delivery is a no-op", fn() {
    _wh_seed_task("dup-me", "review", "https://x/pr/16")
    _wh_post_github(_wh_github_payload("closed", "https://x/pr/16", "task/dup-me", true, false), "d-16")
    response = _wh_post_github(_wh_github_payload("closed", "https://x/pr/16", "task/dup-me", true, false), "d-16")
    assert_eq(res_status(response), 200)
    assert(res_body(response).contains("duplicate"))
    t = Task.find_by_slug("proj", "dup-me")
    assert_eq(t.status, "done")
  })

  test("unknown repo/branch acks with 200 and mutates nothing", fn() {
    _wh_seed_task("bystander", "review", "https://x/pr/17")
    payload = _wh_github_payload("closed", "https://x/pr/999", "feature/elsewhere", true, false)
    response = _wh_post_github(payload, "d-17")
    assert_eq(res_status(response), 200)
    assert(res_body(response).contains("no matching task"))
    t = Task.find_by_slug("proj", "bystander")
    assert_eq(t.status, "review")
  })
})

describe("WebhooksController#gitlab", fn() {
  before_each(fn() {
    assert_test_db()
    Task.delete_all()
    Setting.delete_all()
    Setting.set("gitlab_webhook_secret", _wh_secret())
  })

  test("rejects a wrong token", fn() {
    response = _wh_post_gitlab(_wh_gitlab_payload("open", "opened", "https://x/mr/1", "task/a", false), "wrong")
    assert_eq(res_status(response), 401)
  })

  test("rejects when no secret is configured", fn() {
    Setting.unset("gitlab_webhook_secret")
    response = _wh_post_gitlab(_wh_gitlab_payload("open", "opened", "https://x/mr/1", "task/a", false), _wh_secret())
    assert_eq(res_status(response), 401)
  })

  test("merge event moves a review task to done", fn() {
    _wh_seed_task("gl-merge", "review", "https://x/mr/20")
    payload = _wh_gitlab_payload("merge", "merged", "https://x/mr/20", "task/gl-merge", false)
    response = _wh_post_gitlab(payload, _wh_secret())
    assert_eq(res_status(response), 200)
    t = Task.find_by_slug("proj", "gl-merge")
    assert_eq(t.status, "done")
    assert_eq(t.pr_state, "merged")
  })

  test("close event fails the task", fn() {
    _wh_seed_task("gl-close", "review", "https://x/mr/21")
    payload = _wh_gitlab_payload("close", "closed", "https://x/mr/21", "task/gl-close", false)
    response = _wh_post_gitlab(payload, _wh_secret())
    assert_eq(res_status(response), 200)
    t = Task.find_by_slug("proj", "gl-close")
    assert_eq(t.status, "failed")
    assert_eq(t.pr_state, "closed")
  })

  test("auto-links an opened MR by source branch", fn() {
    _wh_seed_task("gl-link", "inprogress", nil)
    Setting.set("_project_for_repo_mock", "proj")
    payload = _wh_gitlab_payload("open", "opened", "https://x/mr/22", "task/gl-link", false)
    response = _wh_post_gitlab(payload, _wh_secret())
    assert_eq(res_status(response), 200)
    t = Task.find_by_slug("proj", "gl-link")
    assert_eq(t.pr_url, "https://x/mr/22")
    assert_eq(t.pr_state, "open")
    assert_eq(t.pr_host, "gitlab")
  })

  test("non-MR events are ignored", fn() {
    pst = post
    response = pst("/webhooks/gitlab", {"object_kind": "push"}.to_json, {"headers": {
      "Origin": _wh_origin(),
      "Content-Type": "application/json",
      "x-gitlab-event": "Push Hook",
      "x-gitlab-token": _wh_secret()
    }})
    assert_eq(res_status(response), 200)
    assert(res_body(response).contains("ignored"))
  })
})
