# View helpers for the run/log views. Pure functions only — these get
# called inside `<% %>` template blocks where we can't reach into the
# Run model directly.

# Tailwind classes to apply to a single line of formatted log output,
# based on the leading glyph emitted by `bin/_stream-format.jq` plus the
# raw `[ISO]` lines emitted by `bin/task-run`.
def task_log_line_class(line: String) -> Any
  let s = line.trim()
  if s == ""
    return "h-2"
  end
  if s.starts_with("⚙ ")
    return "text-slate-500"
  end
  if s.starts_with("▸ ")
    return "text-indigo-300"
  end
  if s.starts_with("💬 ")
    return "text-slate-100"
  end
  if s.starts_with("↩ ")
    return "text-slate-400 pl-4"
  end
  if s.starts_with("✓ ")
    return "text-emerald-300 font-semibold"
  end
  if s.starts_with("FAIL:") or s.contains("failed:")
    return "text-red-300"
  end
  # Lines from task-run itself begin with `[ISO-timestamp]`.
  if s.starts_with("[")
    return "text-slate-500"
  end
  return "text-slate-300"
end

# Render the status_token from `<task>.status` into something a human
# wants to read on a status pill. Returns a hash:
#   { "icon": "⏳", "label": "Running /do-task", "tone": "amber"|"emerald"|"red"|"slate" }
def task_status_pill(status_token: Any) -> Any
  if status_token == nil
    return { "icon": "·", "label": "no run yet", "tone": "slate" }
  end
  let token = status_token
  if token.starts_with("done:")
    return { "icon": "✓", "label": "Done", "tone": "emerald" }
  end
  if token.starts_with("failed:")
    let reason = token.substring(7, token.length)
    return { "icon": "✗", "label": "Failed — " + reason, "tone": "red" }
  end
  if token == "starting"
    return { "icon": "•", "label": "Starting", "tone": "amber" }
  end
  if token.contains("/do-task")
    return { "icon": "▸", "label": "Running /do-task", "tone": "amber" }
  end
  if token.contains("/review-task")
    return { "icon": "▸", "label": "Running /review-task", "tone": "amber" }
  end
  if token.contains("worktree")
    return { "icon": "▸", "label": "Preparing worktree", "tone": "amber" }
  end
  if token.contains("PR") or token.contains("pushing")
    return { "icon": "▸", "label": token, "tone": "amber" }
  end
  return { "icon": "•", "label": token, "tone": "amber" }
end

# Tailwind class fragment for a status pill, given a tone name.
def task_status_pill_classes(tone: String) -> Any
  if tone == "emerald"
    return "bg-emerald-400/15 text-emerald-300 border-emerald-400/30"
  end
  if tone == "red"
    return "bg-red-500/15 text-red-300 border-red-500/30"
  end
  if tone == "amber"
    return "bg-amber-400/15 text-amber-300 border-amber-400/30"
  end
  return "bg-slate-700/40 text-slate-300 border-slate-600/40"
end

# "2m 14s" / "1h 5m 12s" — minus signs collapsed to "0s" so we never
# render a future timestamp as a negative duration after a clock skew.
def task_format_elapsed(iso_then: String) -> Any
  if iso_then == nil or iso_then == ""
    return ""
  end
  let then_dt = DateTime.parse(iso_then) rescue nil
  if then_dt == nil
    return ""
  end
  let secs = DateTime.now().to_unix() - then_dt.to_unix()
  if secs < 0
    secs = 0
  end
  if secs < 60
    return str(secs) + "s"
  end
  if secs < 3600
    return str(secs / 60) + "m " + str(secs % 60) + "s"
  end
  return str(secs / 3600) + "h " + str((secs % 3600) / 60) + "m"
end

def task_run_indicator(repo: String, slug: String) -> Any
  return run_indicator(repo, slug)
end

def task_run_pr_url(repo: String, slug: String) -> Any
  return run_pr_url(repo, slug)
end
