# PreToolUse hook that auto-wraps foreground `soli serve` calls with
# `timeout 120s`. Lives at `.claude/hooks/timeout-soli-serve.sh`,
# seeded by `bin/task-run` into every fresh worktree's
# `.claude/settings.local.json`. See the script header for the why.
#
# The spec shells out to the script via stdin and asserts on the JSON
# it emits (or its silent pass-through). We test the script itself, not
# the surrounding Claude Code wiring — coverage of "does the harness
# actually load this hook" is integration, not unit-level.

# Path is relative to the test runner's cwd (= project root). Tests
# never `cd` away, so this is reliable.
const _hook_path = "./.claude/hooks/timeout-soli-serve.sh"

# Invoke the hook with `command` as the tool input. Returns a hash:
#   { "exit_code": <int>, "stdout": <str>, "stderr": <str>, "parsed": <hash|nil> }
# `parsed` is the JSON-decoded stdout, or nil when stdout is empty
# (the hook's silent pass-through signal).
def _invoke(command)
  let payload = JSON.stringify({ "tool_input": { "command": command } })
  # bash -c reads the payload from $1 and pipes it into the hook, so we
  # never have to wrestle with shell-quoting raw JSON.
  let res = System.run_sync([
    "bash", "-c",
    "printf %s \"$1\" | " + _hook_path,
    "--", payload
  ])
  let out = (res["stdout"] ?? "").trim()
  let parsed = nil
  if out != ""
    parsed = JSON.parse(out) rescue nil
  end
  return {
    "exit_code": res["exit_code"],
    "stdout":    out,
    "stderr":    res["stderr"] ?? "",
    "parsed":    parsed
  }
end

# Convenience: pull the rewritten command out of the hook's JSON output.
def _rewritten(res)
  return res["parsed"]["hookSpecificOutput"]["updatedInput"]["command"]
end

describe("timeout-soli-serve hook", fn()
  describe("rewrites unwrapped `soli serve`", fn()
    test("wraps the original bug case: `soli serve ... | head -N`", fn()
      let res = _invoke("soli serve . --port 5099 --dev 2>&1 | head -20")
      assert_eq(res["exit_code"], 0)
      assert_eq(
        _rewritten(res),
        "timeout 120s soli serve . --port 5099 --dev 2>&1 | head -20"
      )
    end)

    test("wraps a backgrounded `soli serve ... &` too (safety net)", fn()
      # Even when the agent did the right thing and backgrounded the
      # serve, we still wrap. If they forget the matching `kill`, the
      # 120s timeout still bounds the leak.
      let res = _invoke("soli serve . --port 5099 --dev > /tmp/s.log 2>&1 &")
      assert_eq(_rewritten(res),
        "timeout 120s soli serve . --port 5099 --dev > /tmp/s.log 2>&1 &")
    end)

    test("wraps `soli serve` after a `cd && ...`", fn()
      let res = _invoke("cd /tmp/proj && soli serve . --dev")
      assert_eq(_rewritten(res), "cd /tmp/proj && timeout 120s soli serve . --dev")
    end)

    test("wraps each occurrence when `soli serve` appears multiple times", fn()
      let res = _invoke("soli serve . --port 1 & soli serve . --port 2")
      assert_eq(_rewritten(res),
        "timeout 120s soli serve . --port 1 & timeout 120s soli serve . --port 2")
    end)

    test("emits hookSpecificOutput with permissionDecision=allow", fn()
      let res = _invoke("soli serve .")
      let hso = res["parsed"]["hookSpecificOutput"]
      assert_eq(hso["hookEventName"], "PreToolUse")
      assert_eq(hso["permissionDecision"], "allow")
    end)
  end)

  describe("passes through (exit 0, no stdout)", fn()
    test("when the command is already `timeout <N>s soli serve ...`", fn()
      let res = _invoke("timeout 60s soli serve . --port 5099 --dev")
      assert_eq(res["exit_code"], 0)
      assert_eq(res["stdout"], "")
      assert_null(res["parsed"])
    end)

    test("when the command is `timeout 5m soli serve` (other duration units)", fn()
      let res = _invoke("timeout 5m soli serve . --dev")
      assert_eq(res["stdout"], "")
    end)

    test("when `soli serve` doesn't appear at all", fn()
      let res = _invoke("ls -la")
      assert_eq(res["exit_code"], 0)
      assert_eq(res["stdout"], "")
    end)

    test("for other `soli` subcommands like `soli test` or `soli lint`", fn()
      let r1 = _invoke("soli test tests/foo_spec.sl")
      let r2 = _invoke("soli lint app/controllers/")
      assert_eq(r1["stdout"], "")
      assert_eq(r2["stdout"], "")
    end)

    test("for a no-op JSON payload (empty command field)", fn()
      # The hook should never crash on a missing/empty command. This
      # protects against PreToolUse firing for non-Bash matchers that
      # somehow leak through, or malformed inputs.
      let payload = JSON.stringify({ "tool_input": { "command": "" } })
      let res = System.run_sync([
        "bash", "-c",
        "printf %s \"$1\" | " + _hook_path,
        "--", payload
      ])
      assert_eq(res["exit_code"], 0)
      assert_eq((res["stdout"] ?? "").trim(), "")
    end)
  end)
end)
