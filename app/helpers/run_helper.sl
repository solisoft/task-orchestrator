# View helpers for the run/log views. Pure functions only — these get
# called inside `<% %>` template blocks where we can't reach into the
# Run model directly. Run model functions (run_indicator, run_pr_url,
# etc.) are auto-loaded from app/models/run.sl so no import is needed.

# Tailwind classes to apply to a single line of formatted log output,
# based on the leading glyph emitted by `bin/_stream-format.jq` plus the
# raw `[ISO]` lines emitted by `bin/task-run`.
fn task_log_line_class(line: String) -> Any
  s = line.trim()
  return "h-2" if s == ""
  return "text-slate-500" if s.starts_with("⚙ ")
  return "text-indigo-300" if s.starts_with("▸ ")
  return "text-slate-100" if s.starts_with("💬 ")
  return "text-slate-400 pl-4" if s.starts_with("↩ ")
  return "text-red-300/90" if s.starts_with("- ")
  return "text-emerald-300/90" if s.starts_with("+ ")
  return "text-emerald-300 font-semibold" if s.starts_with("✓ ")
  return "text-red-300" if s.starts_with("FAIL:") || s.contains("failed:")

  # Lines from task-run itself begin with `[ISO-timestamp]`.
  return "text-slate-500" if s.starts_with("[")
  return "text-slate-300"
end

# Render the status_token from `<task>.status` into something a human
# wants to read on a status pill. Returns a hash:
#   { "icon": "⏳", "label": "Running /do-task", "tone": "amber"|"emerald"|"red"|"slate" }
fn task_status_pill(status_token) -> Any
  if status_token.nil?
    return {
      "icon": "·",
      "label": "no run yet",
      "tone": "slate"
    }
  end

  token = status_token
  if token.starts_with("done:")
    return {
      "icon": "✓",
      "label": "Done",
      "tone": "emerald"
    }
  end

  if token.starts_with("failed:")
    reason = token.substring(7, token.length)
    return {
      "icon": "✗",
      "label": "Failed — " + reason,
      "tone": "red"
    }
  end
  if token == "starting"
    return {
      "icon": "•",
      "label": "Starting",
      "tone": "amber"
    }
  end

  if token.contains("/do-task")
    return {
      "icon": "▸",
      "label": "Running /do-task",
      "tone": "amber"
    }
  end

  if token.contains("/review-task")
    return {
      "icon": "▸",
      "label": "Running /review-task",
      "tone": "amber"
    }
  end

  if token.contains("worktree")
    return {
      "icon": "▸",
      "label": "Preparing worktree",
      "tone": "amber"
    }
  end

  if token.contains("PR") || token.contains("pushing")
    return {
      "icon": "▸",
      "label": token,
      "tone": "amber"
    }
  end

  return {
    "icon": "•",
    "label": token,
    "tone": "amber"
  }
end

# Tailwind class fragment for a status pill, given a tone name.
fn task_status_pill_classes(tone: String) -> Any
  return "bg-emerald-400/15 text-emerald-300 border-emerald-400/30" if tone == "emerald"
  return "bg-red-500/15 text-red-300 border-red-500/30" if tone == "red"
  return "bg-amber-400/15 text-amber-300 border-amber-400/30" if tone == "amber"
  return "bg-slate-700/40 text-slate-300 border-slate-600/40"
end

# "2m 14s" / "1h 5m 12s" — minus signs collapsed to "0s" so we never
# render a future timestamp as a negative duration after a clock skew.
fn task_format_elapsed(iso_then: String) -> Any
  return "" if iso_then.nil? || iso_then == ""
  then_dt = DateTime.parse(iso_then) rescue nil
  return "" if then_dt.nil?
  secs = DateTime.now().to_unix() - then_dt.to_unix()
  secs = 0 if secs < 0
  return str(secs) + "s" if secs < 60
  return str(secs / 60) + "m " + str(secs % 60) + "s" if secs < 3600
  return str(secs / 3600) + "h " + str((secs % 3600) / 60) + "m"
end

fn task_run_indicator(repo: String, slug: String) -> Any
  return Run.run_indicator(repo, slug)
end

# Tailwind classes + glyph for a TodoWrite item, given its `status`
# field. Returns `{ "icon": "...", "classes": "..." }`. Statuses outside
# the known set fall back to the pending styling.
fn task_todo_chrome(status) -> Any
  s = status ?? ""
  if s == "completed"
    return {"icon": "✓", "classes": "text-emerald-300/90 line-through decoration-emerald-300/40"}
  end

  if s == "in_progress"
    return {"icon": "▸", "classes": "text-amber-200 font-medium"}
  end

  if s == "cancelled"
    return {"icon": "✗", "classes": "text-slate-500 line-through"}
  end

  return {"icon": "○", "classes": "text-slate-400"}
end

fn task_run_pr_url(repo: String, slug: String) -> Any
  return Run.run_pr_url(repo, slug)
end
