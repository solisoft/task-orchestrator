# Run model — zombie detection in `run_current_status`.
#
# `bin/task-run` writes a `<slug>.pid` next to the .status journal at
# launch and removes it on EXIT. If the wrapper is SIGKILLed (OOM,
# `pkill -9`, parent crash) the EXIT trap doesn't fire, the .status
# stays at "running …", and without help the UI shows the run as live
# forever. The model's job is to spot that — `run_current_status`
# returns a synthesized `failed:agent died (...)` for any non-terminal
# status whose pidfile points at a dead process.
#
# These specs work directly against $TASK_ORCH_STATE on disk (pointed
# at /tmp/task-orch-spec-state by .env.test), seeding fixture files
# per scenario.
fn _rs_state_dir(repo)
  root = getenv("TASK_ORCH_STATE") ?? ""
  return root + "/" + repo
end

fn _rs_reset(repo, slug)
  dir = _rs_state_dir(repo)
  System.run_sync(["mkdir", "-p", dir])
  for ext in [".status", ".pid", ".log", ".log.jsonl", ".pr"]
    path = dir + "/" + slug + ext
    Trusted.delete(path) rescue null
  end
  Task.delete(Task.key_for(repo, slug)) rescue null
end

fn _rs_seed_done_task(repo, slug)
  Task.create({
    "_key": Task.key_for(repo, slug),
    "project": repo,
    "slug": slug,
    "title": "run spec task",
    "status": "done"
  })
end

fn _rs_write_status(repo, slug, token)
  path = _rs_state_dir(repo) + "/" + slug + ".status"
  Trusted.write(path, "2026-05-10T00:00:00+00:00\t" + token + "\n")
end

fn _rs_write_pid(repo, slug, pid)
  path = _rs_state_dir(repo) + "/" + slug + ".pid"
  Trusted.write(path, str(pid) + "\n")
end

# A PID guaranteed to be unused. `kill -0` against this returns 1.
const _rs_dead_pid = 4194303

describe("run_current_status zombie detection", fn() {
  before_each(fn() { _rs_reset("rs_repo", "rs_slug") })

  test("returns nil when no status file exists", fn() {
    assert_null(Run.run_current_status("rs_repo", "rs_slug"))
  })

  test("passes through a terminal done: token unchanged", fn() {
    _rs_write_status("rs_repo", "rs_slug", "done:no-commit")
    s = Run.run_current_status("rs_repo", "rs_slug")
    assert_eq(s["status"], "done:no-commit")
  })

  test(
    "passes through a terminal failed: token unchanged",
    fn() {
      _rs_write_status("rs_repo", "rs_slug", "failed:something")
      # Even with a dead pidfile present, terminal tokens win — they're
      # the journal's authoritative record.
      _rs_write_pid("rs_repo", "rs_slug", _rs_dead_pid)
      s = Run.run_current_status("rs_repo", "rs_slug")
      assert_eq(s["status"], "failed:something")
    }
  )

  test(
    "keeps `running …` while the recorded PID is alive",
    fn() {
      _rs_write_status("rs_repo", "rs_slug", "running /do-task")
      # Our own runner process is alive by definition.
      self_pid = (System.run_sync([
        "sh",
        "-c",
        "echo $PPID"
      ])["stdout"] ?? "").trim()
      _rs_write_pid("rs_repo", "rs_slug", self_pid)
      s = Run.run_current_status("rs_repo", "rs_slug")
      assert_eq(s["status"], "running /do-task")
    }
  )

  test(
    "synthesizes failed:agent died when the pidfile points at a dead PID",
    fn() {
      _rs_write_status("rs_repo", "rs_slug", "running /do-task")
      _rs_write_pid("rs_repo", "rs_slug", _rs_dead_pid)
      s = Run.run_current_status("rs_repo", "rs_slug")
      assert(s["status"].starts_with("failed:agent died"))
    }
  )

  test(
    "keeps `running …` when no pidfile exists and the log is fresh",
    fn() {
      _rs_write_status("rs_repo", "rs_slug", "running /do-task")
      # Fresh log, no pidfile — pre-pidfile launch, still healthy.
      Trusted.write(_rs_state_dir("rs_repo") + "/rs_slug.log", "alive\n")
      s = Run.run_current_status("rs_repo", "rs_slug")
      assert_eq(s["status"], "running /do-task")
    }
  )

  # Regression: a row the success path moved to `done` must not be
  # repainted `failed:agent died` just because the journal's last line
  # is non-terminal and the pidfile points at a gone process.
  test(
    "does NOT synthesize failed: when the Task row is already 'done'",
    fn() {
      _rs_write_status("rs_repo", "rs_slug", "running /do-task")
      _rs_write_pid("rs_repo", "rs_slug", _rs_dead_pid)
      _rs_seed_done_task("rs_repo", "rs_slug")
      s = Run.run_current_status("rs_repo", "rs_slug")
      assert_eq(s["status"], "running /do-task")
    }
  )
})

describe("run_indicator", fn() {
  before_each(fn() { _rs_reset("rs_repo", "rs_slug") })

  test("returns 'failed' for a zombie run", fn() {
    _rs_write_status("rs_repo", "rs_slug", "running /do-task")
    _rs_write_pid("rs_repo", "rs_slug", _rs_dead_pid)
    assert_eq(Run.run_indicator("rs_repo", "rs_slug"), "failed")
  })

  # Acceptance: kanban dot stays green for a `done` row even when the
  # on-disk artefacts (zombie pid, stale `running` journal) would
  # otherwise route through the failure path.
  test(
    "returns 'done' for a zombie run whose Task row is 'done'",
    fn() {
      _rs_write_status("rs_repo", "rs_slug", "running /do-task")
      _rs_write_pid("rs_repo", "rs_slug", _rs_dead_pid)
      _rs_seed_done_task("rs_repo", "rs_slug")
      assert_eq(Run.run_indicator("rs_repo", "rs_slug"), "done")
    }
  )
})

# Helper: write `body` to the run's .log file inside the spec fixture.
fn _rs_write_log(repo, slug, body)
  path = _rs_state_dir(repo) + "/" + slug + ".log"
  Trusted.write(path, body)
end

describe(
  "run_log_delta — byte-cursor diffing for the WS stream",
  fn() {
    before_each(fn() { _rs_reset("rs_repo", "rs_slug") })

    test(
      "returns chunk='' and offset=0 when the .log doesn't exist yet",
      fn() {
        d = Run.run_log_delta("rs_repo", "rs_slug", 0)
        assert_eq(d["chunk"], "")
        assert_eq(d["offset"], 0)
      }
    )

    test("returns the full body at offset 0", fn() {
      _rs_write_log("rs_repo", "rs_slug", "hello world")
      d = Run.run_log_delta("rs_repo", "rs_slug", 0)
      assert_eq(d["chunk"], "hello world")
      assert_eq(d["offset"], 11)
    })

    test("returns only bytes appended past the cursor", fn() {
      _rs_write_log("rs_repo", "rs_slug", "hello world")
      d = Run.run_log_delta("rs_repo", "rs_slug", 6)
      assert_eq(d["chunk"], "world")
      assert_eq(d["offset"], 11)
    })

    test(
      "returns chunk='' when the cursor is at EOF (no new bytes)",
      fn() {
        _rs_write_log("rs_repo", "rs_slug", "frozen")
        d = Run.run_log_delta("rs_repo", "rs_slug", 6)
        assert_eq(d["chunk"], "")
        assert_eq(d["offset"], 6)
      }
    )

    test(
      "resends from byte 0 when the file shrank under the cursor (truncate recovery)",
      fn() {
        _rs_write_log("rs_repo", "rs_slug", "short")
        d = Run.run_log_delta("rs_repo", "rs_slug", 9999)
        assert_eq(d["chunk"], "short")
        assert_eq(d["offset"], 5)
      }
    )
  }
)

describe(
  "run_log_size — total byte count of the .log file",
  fn() {
    before_each(fn() { _rs_reset("rs_repo", "rs_slug") })

    test("returns 0 when the .log doesn't exist", fn() { assert_eq(Run.run_log_size("rs_repo", "rs_slug"), 0) })

    test("returns the exact byte length of the .log", fn() {
      _rs_write_log("rs_repo", "rs_slug", "abc")
      assert_eq(Run.run_log_size("rs_repo", "rs_slug"), 3)
    })

    test(
      "returns full size even when log exceeds 16 KB (tail vs total)",
      fn() {
        parts = []
        for i in 0 .. 20001
          parts.push("x")
        end
        big = parts.join("")
        _rs_write_log("rs_repo", "rs_slug", big)
        assert(Run.run_log_size("rs_repo", "rs_slug") > 16384)
        assert_eq(Run.run_log_size("rs_repo", "rs_slug"), 20001)
      }
    )

    test(
      "run_log_delta using the full size as offset returns chunk='' at EOF",
      fn() {
        parts = []
        for i in 0 .. 20001
          parts.push("x")
        end
        big = parts.join("")
        _rs_write_log("rs_repo", "rs_slug", big)
        full_size = Run.run_log_size("rs_repo", "rs_slug")
        d = Run.run_log_delta("rs_repo", "rs_slug", full_size)
        assert_eq(d["chunk"], "")
        assert_eq(d["offset"], full_size)
      }
    )
  }
)

describe(
  "run_stream_payload — model-layer builder for the WS frame",
  fn() {
    before_each(fn() { _rs_reset("rs_repo", "rs_slug") })

    test(
      "connect → snapshot carrying the entire log and current status",
      fn() {
        _rs_write_log("rs_repo", "rs_slug", "boot...\nready\n")
        _rs_write_status("rs_repo", "rs_slug", "running /do-task")
        # Pidfile points at our own runner so `run_current_status` skips
        # the zombie synthesis path and reports the journal token verbatim.
        self_pid = (System.run_sync([
          "sh",
          "-c",
          "echo $PPID"
        ])["stdout"] ?? "").trim()
        _rs_write_pid("rs_repo", "rs_slug", self_pid)
        p = Run.run_stream_payload("rs_repo", "rs_slug", "connect", 0, 0)
        assert_eq(p["event"], "snapshot")
        assert_eq(p["log_chunk"], "boot...\nready\n")
        assert_eq(p["log_offset"], "boot...\nready\n".length)
        assert_eq(p["terminal"], false)
        assert_eq(p["status"]["status"], "running /do-task")
      }
    )

    test(
      "tick → delta with only the bytes appended past the cursor",
      fn() {
        _rs_write_log("rs_repo", "rs_slug", "abcdefghij")
        p = Run.run_stream_payload("rs_repo", "rs_slug", "message", 4, 0)
        assert_eq(p["event"], "delta")
        assert_eq(p["log_chunk"], "efghij")
        assert_eq(p["log_offset"], 10)
      }
    )

    test(
      "flips terminal=true once the journal reaches done:",
      fn() {
        _rs_write_log("rs_repo", "rs_slug", "all green\n")
        _rs_write_status("rs_repo", "rs_slug", "done:https://example.invalid/pr/1")
        p = Run.run_stream_payload("rs_repo", "rs_slug", "message", 0, 0)
        assert_eq(p["terminal"], true)
      }
    )

    test(
      "flips terminal=true once the journal reaches failed:",
      fn() {
        _rs_write_log("rs_repo", "rs_slug", "oh no\n")
        _rs_write_status("rs_repo", "rs_slug", "failed:oom")
        p = Run.run_stream_payload("rs_repo", "rs_slug", "message", 0, 0)
        assert_eq(p["terminal"], true)
      }
    )

    test("a stale offset past EOF resends from byte 0", fn() {
      _rs_write_log("rs_repo", "rs_slug", "rewound")
      p = Run.run_stream_payload("rs_repo", "rs_slug", "message", 9999, 0)
      assert_eq(p["log_chunk"], "rewound")
      assert_eq(p["log_offset"], 7)
    })

    test("normalises a negative or nil offset to 0", fn() {
      _rs_write_log("rs_repo", "rs_slug", "xyz")
      a = Run.run_stream_payload("rs_repo", "rs_slug", "message", -1, 0)
      assert_eq(a["log_chunk"], "xyz")
      b = Run.run_stream_payload("rs_repo", "rs_slug", "message", nil, 0)
      assert_eq(b["log_chunk"], "xyz")
    })

    test(
      "connect with prefix_end>0 backfills bytes 0..prefix_end via prefix_chunk",
      fn() {
        _rs_write_log("rs_repo", "rs_slug", "early bytes\nlate bytes\n")
        # SSR painted only the tail starting at byte 12 ("late bytes\n").
        # Cursor is the full size, so log_chunk should be "" and the missing
        # 12-byte prefix arrives as prefix_chunk.
        full = "early bytes\nlate bytes\n".length
        p = Run.run_stream_payload("rs_repo", "rs_slug", "connect", full, 12)
        assert_eq(p["event"], "snapshot")
        assert_eq(p["log_chunk"], "")
        assert_eq(p["prefix_chunk"], "early bytes\n")
      }
    )

    test(
      "delta frame never carries prefix_chunk even when prefix_end>0",
      fn() {
        _rs_write_log("rs_repo", "rs_slug", "abcdef")
        p = Run.run_stream_payload("rs_repo", "rs_slug", "message", 0, 3)
        assert_null(p["prefix_chunk"])
      }
    )

    test(
      "prefix_end=0 (no SSR cap) skips prefix_chunk on connect",
      fn() {
        _rs_write_log("rs_repo", "rs_slug", "small log\n")
        p = Run.run_stream_payload("rs_repo", "rs_slug", "connect", 10, 0)
        assert_null(p["prefix_chunk"])
      }
    )
  }
)

describe(
  "run_log_prefix — byte-range read for the snapshot backfill",
  fn() {
    before_each(fn() { _rs_reset("rs_repo", "rs_slug") })

    test(
      "returns the requested byte prefix when log is longer",
      fn() {
        _rs_write_log("rs_repo", "rs_slug", "abcdefghij")
        assert_eq(Run.run_log_prefix("rs_repo", "rs_slug", 4), "abcd")
      }
    )

    test(
      "caps at the log's actual length when end_offset overshoots",
      fn() {
        _rs_write_log("rs_repo", "rs_slug", "abc")
        assert_eq(Run.run_log_prefix("rs_repo", "rs_slug", 99), "abc")
      }
    )

    test(
      "returns '' when end_offset is 0, negative, or nil",
      fn() {
        _rs_write_log("rs_repo", "rs_slug", "abc")
        assert_eq(Run.run_log_prefix("rs_repo", "rs_slug", 0), "")
        assert_eq(Run.run_log_prefix("rs_repo", "rs_slug", -1), "")
        assert_eq(Run.run_log_prefix("rs_repo", "rs_slug", nil), "")
      }
    )

    test("returns '' when the log file does not exist", fn() {
      assert_eq(Run.run_log_prefix("rs_repo", "rs_slug", 10), "")
    })
  }
)

describe("run.sl utility functions", fn() {
  test("task_branch_name prepends task/", fn() {
    assert_eq(Run.task_branch_name("my-feature"), "task/my-feature")
    assert_eq(Run.task_branch_name("slug"), "task/slug")
  })

  test(
    "find_project returns nil for non-existent directory",
    fn() { assert_null(Project.find_project("--no-such-dir-xyz--")) }
  )

  test(
    "set_pr_merged_mock stores and clears via Setting",
    fn() {
      Setting.set("_pr_merged_mock", nil)
      Run.set_pr_merged_mock(true)
      stored = Setting.get("_pr_merged_mock")
      assert_eq(stored, true)
      Run.set_pr_merged_mock(nil)
    }
  )

  test(
    "pr_merged falls through to gh call when mock is nil",
    fn() {
      Setting.set("_pr_merged_mock", nil)
      result = Run.pr_merged("https://github.com/owner/repo/pull/999999")
      assert_eq(result, false)
    }
  )

  test("project_has_remote returns false when the repo has no origin", fn() {
    dir = "/tmp/_rs_proj_no_remote"
    System.run_sync(["rm", "-rf", dir])
    System.run_sync(["git", "init", "-q", "-b", "main", dir])
    assert_eq(Run.project_has_remote(dir), false)
    System.run_sync(["rm", "-rf", dir])
  })

  test("project_has_remote returns true when the repo has an origin", fn() {
    dir = "/tmp/_rs_proj_remote"
    origin_dir = "/tmp/_rs_proj_remote_origin.git"
    System.run_sync(["rm", "-rf", dir, origin_dir])
    System.run_sync(["git", "init", "-q", "-b", "main", dir])
    System.run_sync(["git", "init", "-q", "--bare", origin_dir])
    System.run_sync(["git", "-C", dir, "remote", "add", "origin", origin_dir])
    assert_eq(Run.project_has_remote(dir), true)
    System.run_sync(["rm", "-rf", dir, origin_dir])
  })
})

# `run_latest_todos` returns the agent's latest TodoWrite payload when
# the .log.jsonl carries one, else falls back to the spec md's
# `## Acceptance Criteria` bullets so the Run page panel is never empty
# during long /do-task stretches where the agent skips TodoWrite.
fn _rs_worktree_dir(repo, slug)
  root = getenv("TASK_ORCH_WORKTREES") ?? ""
  return root + "/" + repo + "/" + slug
end

fn _rs_write_spec(repo, slug, body)
  dir = _rs_worktree_dir(repo, slug) + "/tasks/todo"
  System.run_sync(["mkdir", "-p", dir])
  Trusted.write(dir + "/" + slug + ".md", body)
end

fn _rs_remove_worktree(repo, slug)
  dir = _rs_worktree_dir(repo, slug)
  System.run_sync(["rm", "-rf", dir])
end

fn _rs_write_jsonl(repo, slug, body)
  path = _rs_state_dir(repo) + "/" + slug + ".log.jsonl"
  Trusted.write(path, body)
end

describe(
  "run_latest_todos — spec-fallback when agent skips TodoWrite",
  fn() {
    before_each(fn() {
      _rs_reset("rs_repo", "rs_slug")
      _rs_remove_worktree("rs_repo", "rs_slug")
    })

    test(
      "returns TodoWrite payload from the jsonl when present",
      fn() {
        event = {"type": "assistant", "message": {"content": [{
          "type": "tool_use",
          "name": "TodoWrite",
          "input": {"todos": [{"content": "step one", "status": "in_progress"}, {
            "content": "step two",
            "status": "pending"
          }]}
        }]}}
        _rs_write_jsonl("rs_repo", "rs_slug", JSON.stringify(event) + "\n")
        todos = Run.run_latest_todos("rs_repo", "rs_slug")
        assert_eq(todos.length, 2)
        assert_eq(todos[0]["content"], "step one")
        assert_eq(todos[0]["status"], "in_progress")
      }
    )

    test(
      "falls back to spec's Acceptance Criteria bullets when no TodoWrite",
      fn() {
        _rs_write_jsonl("rs_repo", "rs_slug", "{\"type\":\"assistant\",\"message\":{\"content\":[]}}\n")
        _rs_write_spec("rs_repo", "rs_slug", "# Title\n" + "\n" + "## Issue\n"
        + "- decoy bullet that must NOT appear\n"
        + "\n"
        + "## Acceptance Criteria\n"
        + "- ship the synthesizer\n"
        + "- cover it with tests\n"
        + "* second-style bullet works too\n"
        + "\n"
        + "## Notes\n"
        + "- not part of the plan\n")
        todos = Run.run_latest_todos("rs_repo", "rs_slug")
        assert_eq(todos.length, 3)
        assert_eq(todos[0]["content"], "ship the synthesizer")
        assert_eq(todos[0]["status"], "pending")
        assert_eq(todos[0]["source"], "spec")
        assert_eq(todos[1]["content"], "cover it with tests")
        assert_eq(todos[2]["content"], "second-style bullet works too")
      }
    )

    test(
      "TodoWrite takes precedence even when the spec also has criteria",
      fn() {
        event = {"type": "assistant", "message": {"content": [{
          "type": "tool_use",
          "name": "TodoWrite",
          "input": {"todos": [{"content": "agent says go", "status": "pending"}]}
        }]}}
        _rs_write_jsonl("rs_repo", "rs_slug", JSON.stringify(event) + "\n")
        _rs_write_spec("rs_repo", "rs_slug", "## Acceptance Criteria\n- stale fallback\n")
        todos = Run.run_latest_todos("rs_repo", "rs_slug")
        assert_eq(todos.length, 1)
        assert_eq(todos[0]["content"], "agent says go")
        assert_null(todos[0]["source"])
      }
    )

    test("returns [] when neither jsonl nor spec exist", fn() {
      todos = Run.run_latest_todos("rs_repo", "rs_slug")
      assert_eq(todos.length, 0)
    })

    test(
      "returns [] when spec exists but has no Acceptance Criteria section",
      fn() {
        _rs_write_jsonl("rs_repo", "rs_slug", "{\"type\":\"assistant\",\"message\":{\"content\":[]}}\n")
        _rs_write_spec("rs_repo", "rs_slug", "# Title\n\n## Issue\n- only an issue here\n")
        todos = Run.run_latest_todos("rs_repo", "rs_slug")
        assert_eq(todos.length, 0)
      }
    )
  }
)
