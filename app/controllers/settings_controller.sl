// Settings controller — key/value config editor.

fn show(req)
  render("settings/show", {
    "title": "Settings",
    "agent_type": Setting.get("agent_type") ?? "claude",
    "agent_path": Setting.get("agent_path") ?? ""
  })
end

fn update(req)
  let agent_type = (req["form"]["agent_type"] ?? "").trim()
  let agent_path = (req["form"]["agent_path"] ?? "").trim()
  if agent_type == ""
    return render("settings/show", {
      "title": "Settings",
      "agent_type": agent_type,
      "agent_path": agent_path,
      "error": "Agent type is required"
    })
  end
  Setting.set("agent_type", agent_type)
  if agent_path != ""
    Setting.set("agent_path", agent_path)
  end
  redirect("/settings")
end