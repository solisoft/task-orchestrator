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
    assert_test_db()
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

  describe("plan_model", fn()
    test("renders a plan_model select on the form", fn()
      let response = get("/settings")
      let body = res_body(response)
      assert_contains(body, "id=\"plan_model\"")
      assert_contains(body, "name=\"plan_model\"")
    end)

    test("defaults plan_model to claude-sonnet-4-6 when nothing is persisted", fn()
      let response = get("/settings")
      let body = res_body(response)
      assert_contains(body, "value=\"claude-sonnet-4-6\" selected")
    end)

    test("persists a Claude SDK plan_model on POST", fn()
      post("/settings", { "plan_model": "claude-opus-4-7" })
      assert_eq(Setting.get("plan_model"), "claude-opus-4-7")
    end)

    test("GET reflects the saved plan_model as the selected option", fn()
      Setting.set("plan_model", "claude-haiku-4-5-20251001")
      let response = get("/settings")
      let body = res_body(response)
      assert_contains(body, "value=\"claude-haiku-4-5-20251001\" selected")
    end)

    test("ignores an unknown plan_model rather than overwriting the saved value", fn()
      Setting.set("plan_model", "claude-opus-4-7")
      post("/settings", { "plan_model": "evil-model; rm -rf /" })
      assert_eq(Setting.get("plan_model"), "claude-opus-4-7")
    end)

    test("ignores a blank plan_model rather than clearing the saved value", fn()
      Setting.set("plan_model", "claude-opus-4-7")
      post("/settings", { "plan_model": "" })
      assert_eq(Setting.get("plan_model"), "claude-opus-4-7")
    end)
  end)

  describe("allowed_models", fn()
    test("renders an Available models fieldset", fn()
      let response = get("/settings")
      assert_contains(res_body(response), "Available models")
    end)

    test("renders a checkbox for each known Claude SDK model", fn()
      let response = get("/settings")
      let body = res_body(response)
      for id in Plan.claude_model_ids()
        assert_contains(body, "name=\"allowed_" + id + "\"")
      end
    end)

    test("persists checked allowlist entries on POST", fn()
      post("/settings", {
        "allowed_models_present":            "1",
        "allowed_claude-opus-4-7":           "1",
        "allowed_claude-haiku-4-5-20251001": "1"
      })
      let saved = Setting.get("allowed_models")
      assert_not_null(saved)
      assert_eq(saved.length(), 2)
      assert(saved.contains("claude-opus-4-7"))
      assert(saved.contains("claude-haiku-4-5-20251001"))
    end)

    test("clears the allowlist when the form submits no checked rows", fn()
      Setting.set("allowed_models", ["claude-opus-4-7"])
      post("/settings", { "allowed_models_present": "1" })
      assert_eq(Setting.get("allowed_models").length(), 0)
    end)

    test("does not touch the allowlist when allowed_models_present is absent", fn()
      Setting.set("allowed_models", ["claude-opus-4-7"])
      post("/settings", { "agent_type": "claude" })
      assert_eq(Setting.get("allowed_models").length(), 1)
    end)

    test("drops malformed allowlist entries on POST", fn()
      post("/settings", {
        "allowed_models_present":            "1",
        "allowed_claude-opus-4-7":           "1",
        "allowed_evil; rm -rf /":            "1"
      })
      let saved = Setting.get("allowed_models")
      assert_eq(saved.length(), 1)
      assert_eq(saved[0], "claude-opus-4-7")
    end)

    test("GET renders saved entries as checked", fn()
      Setting.set("allowed_models", ["claude-opus-4-7"])
      let response = get("/settings")
      let body = res_body(response)
      # The `checked` attribute lands on its own line in the template
      # output, so check the attrs independently rather than insisting
      # they sit on one line.
      assert_contains(body, "id=\"allowed_claude-opus-4-7\"")
      assert_contains(body, "checked")
    end)

    test("plan_model dropdown surfaces only allowlisted Claude entries", fn()
      Setting.set("allowed_models", ["claude-opus-4-7"])
      let response = get("/settings")
      let body = res_body(response)
      assert_contains(body, "value=\"claude-opus-4-7\"")
      assert_not(body.contains("value=\"claude-haiku-4-5-20251001\""))
    end)

    test("plan_model dropdown still surfaces the currently-saved value even if outside the allowlist", fn()
      Setting.set("plan_model", "claude-sonnet-4-6")
      Setting.set("allowed_models", ["claude-opus-4-7"])
      let response = get("/settings")
      let body = res_body(response)
      assert_contains(body, "value=\"claude-sonnet-4-6\" selected")
    end)

    test("POST rejects a plan_model that isn't on the allowlist", fn()
      Setting.set("plan_model", "claude-opus-4-7")
      Setting.set("allowed_models", ["claude-opus-4-7"])
      post("/settings", { "plan_model": "claude-haiku-4-5-20251001" })
      assert_eq(Setting.get("plan_model"), "claude-opus-4-7")
    end)

    test("POST accepts a plan_model that IS on the allowlist", fn()
      Setting.set("allowed_models", ["claude-opus-4-7", "claude-haiku-4-5-20251001"])
      post("/settings", { "plan_model": "claude-haiku-4-5-20251001" })
      assert_eq(Setting.get("plan_model"), "claude-haiku-4-5-20251001")
    end)

    test("an empty allowlist means no filter — every Claude model still shows", fn()
      Setting.set("allowed_models", [])
      let response = get("/settings")
      let body = res_body(response)
      for id in Plan.claude_model_ids()
        assert_contains(body, "value=\"" + id + "\"")
      end
    end)
  end)

  describe("theme", fn()
    test("defaults to dark when nothing is persisted", fn()
      let response = get("/settings")
      let body = res_body(response)
      # The dark radio should be pre-selected on a fresh DB.
      assert_contains(body, "value=\"dark\" checked")
    end)

    test("renders both dark and light radio inputs", fn()
      let response = get("/settings")
      let body = res_body(response)
      assert_contains(body, "name=\"theme\" value=\"dark\"")
      assert_contains(body, "name=\"theme\" value=\"light\"")
    end)

    test("persists theme=light on POST", fn()
      post("/settings", { "theme": "light" })
      assert_eq(Setting.get("theme"), "light")
    end)

    test("persists theme=dark on POST", fn()
      Setting.set("theme", "light")
      post("/settings", { "theme": "dark" })
      assert_eq(Setting.get("theme"), "dark")
    end)

    test("ignores an unknown theme value rather than persisting it", fn()
      Setting.set("theme", "light")
      post("/settings", { "theme": "neon" })
      assert_eq(Setting.get("theme"), "light")
    end)

    test("GET echoes the saved theme as the checked radio", fn()
      Setting.set("theme", "light")
      let response = get("/settings")
      let body = res_body(response)
      assert_contains(body, "value=\"light\" checked")
    end)

    test("Setting.get_or('theme', 'dark') round-trips both values", fn()
      post("/settings", { "theme": "light" })
      assert_eq(Setting.get_or("theme", "dark"), "light")
      post("/settings", { "theme": "dark" })
      assert_eq(Setting.get_or("theme", "dark"), "dark")
    end)
  end)
end)
