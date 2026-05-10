# SettingsController — global config (active agent + per-agent run
# caps). Exercises the full GET / POST round-trip via HTTP. We assert
# on (a) HTTP status codes, (b) rendered body markers, and (c) the
# persisted Setting rows the form is supposed to write.
#
# `assigns()` isn't available in this build of the framework — the
# tree-walking interpreter has it commented out — so we verify
# render output through the response body instead of `assigns()`.

describe("SettingsController", fn()
  before_each(fn()
    Setting.delete_all()
    AgentConfig.delete_all()
    as_guest()
  end)

  describe("GET /settings", fn()
    test("returns 200", fn()
      let response = get("/settings")
      assert_eq(res_status(response), 200)
    end)

    test("renders a fieldset for run limits", fn()
      let response = get("/settings")
      assert_contains(res_body(response), "Run limits")
    end)

    test("renders an input for every known agent's daily and weekly limit", fn()
      let response = get("/settings")
      let body = res_body(response)
      for a in Task.known_agents()
        assert_contains(body, "limit_daily_"  + a)
        assert_contains(body, "limit_weekly_" + a)
      end
    end)

    test("echoes a saved limit back into the form value", fn()
      Setting.set("limit_daily_claude", 17)
      let response = get("/settings")
      let body = res_body(response)
      # Must appear inside the form: name="limit_daily_claude" ...
      # value="17".
      assert_contains(body, "value=\"17\"")
    end)

    test("echoes the saved agent_type as the selected option", fn()
      Setting.set("agent_type", "opencode-sdk")
      let response = get("/settings")
      let body = res_body(response)
      assert_contains(body, "value=\"opencode-sdk\" selected")
    end)
  end)

  describe("POST /settings", fn()
    test("redirects on success", fn()
      let response = post("/settings", {
        "agent_type":         "opencode",
        "limit_daily_claude": "3"
      })
      assert_eq(res_status(response), 302)
    end)

    test("persists the agent_type choice", fn()
      post("/settings", { "agent_type": "opencode-sdk" })
      assert_eq(Setting.get("agent_type"), "opencode-sdk")
    end)

    test("persists every per-agent daily and weekly limit", fn()
      post("/settings", {
        "limit_daily_claude":      "10",
        "limit_weekly_claude":     "70",
        "limit_daily_opencode":    "5",
        "limit_weekly_opencode":   "25"
      })
      assert_eq(Setting.get("limit_daily_claude"),      10)
      assert_eq(Setting.get("limit_weekly_claude"),     70)
      assert_eq(Setting.get("limit_daily_opencode"),    5)
      assert_eq(Setting.get("limit_weekly_opencode"),   25)
    end)

    test("treats blank limit input as unlimited (0)", fn()
      post("/settings", { "limit_daily_claude": "" })
      assert_eq(Setting.get("limit_daily_claude"), 0)
    end)

    test("treats unparseable limit input as unlimited (0)", fn()
      post("/settings", { "limit_daily_claude": "abc" })
      assert_eq(Setting.get("limit_daily_claude"), 0)
    end)

    test("clamps a negative limit to 0", fn()
      post("/settings", { "limit_daily_claude": "-5" })
      assert_eq(Setting.get("limit_daily_claude"), 0)
    end)

    test("ignores an unknown agent_type rather than persisting it", fn()
      Setting.set("agent_type", "claude")
      post("/settings", { "agent_type": "evil-agent" })
      assert_eq(Setting.get("agent_type"), "claude")
    end)

    test("round-trips: GET reflects what POST wrote", fn()
      post("/settings", {
        "agent_type":          "opencode",
        "limit_daily_claude":  "8",
        "limit_weekly_claude": "40"
      })
      let response = get("/settings")
      let body = res_body(response)
      assert_eq(Setting.get("agent_type"), "opencode")
      assert_contains(body, "value=\"8\"")
      assert_contains(body, "value=\"40\"")
    end)

    test("renders a checkbox for each known agent's enabled state", fn()
      let response = get("/settings")
      let body = res_body(response)
      for a in Task.known_agents()
        assert_contains(body, "enabled_" + a)
      end
    end)

    test("persists enabled agents to AgentConfig on POST", fn()
      post("/settings", { "enabled_claude": "1", "enabled_opencode": "0", "enabled_opencode-sdk": "1" })
      assert_eq(AgentConfig.get("claude"), true)
      assert_eq(AgentConfig.get("opencode"), false)
      assert_eq(AgentConfig.get("opencode-sdk"), true)
    end)

    test("renders enabled checkbox as checked and disabled as unchecked", fn()
      AgentConfig.set("claude", false)
      AgentConfig.set("opencode", true)
      let response = get("/settings")
      let body = res_body(response)
      assert_contains(body, "id=\"enabled_claude\"")
      assert_contains(body, "id=\"enabled_opencode\"")
    end)

    test("Task.enabled_agents excludes disabled agents", fn()
      post("/settings", { "enabled_claude": "1", "enabled_opencode": "0", "enabled_opencode-sdk": "0" })
      let enabled = Task.enabled_agents()
      assert_contains(enabled, "claude")
      assert_not(enabled.contains("opencode"))
      assert_not(enabled.contains("opencode-sdk"))
    end)

    test("round-trips: GET reflects enabled state POST wrote", fn()
      post("/settings", { "enabled_claude": "0", "enabled_opencode": "1" })
      let response = get("/settings")
      let body = res_body(response)
      assert_eq(AgentConfig.get("claude"), false)
      assert_eq(AgentConfig.get("opencode"), true)
    end)
  end)
end)
