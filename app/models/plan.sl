# Plan — DB-backed plan state, persisted in the solidb `plans` collection.
#
# Identity: `_key` = `<project>--<plan_id>` (the unique index on (project, plan_id)
# enforces uniqueness; the composite key lets us look up by stable URL piece
# without a `where` round-trip).
#
# Plans are created by `spawn_plan_agent` (tasks_controller.sl) when the user
# clicks "Plan it", and are written to by `bin/plan-run` as the agent runs.
# The plans_controller reads back the list for thePlans index page.

class Plan < Model
  validates("project",  { "presence": true })
  validates("plan_id", { "presence": true })

  before_save("touch_timestamps")

  static def key_for(project, plan_id)
    project + "--" + plan_id
  end

  static def find_by_plan_id(plan_id)
    Plan.find_by("_key", plan_id)
  end

  static def for_project(project)
    Plan.where({ "project": project }).order("plan_id", "desc").all()
  end

  static def append_log(plan_id, text)
    let plan = Plan.find_by_plan_id(plan_id)
    if plan != nil
      plan.log = (plan.log ?? "") + text
      plan.save()
    end
  end

  static def append_status(plan_id, status)
    let plan = Plan.find_by_plan_id(plan_id)
    if plan != nil
      plan.status = status
      plan.updated_at = DateTime.now().to_iso()
      plan.save()
    end
  end

  static def update_pending_question(plan_id, pq)
    let plan = Plan.find_by_plan_id(plan_id)
    if plan != nil
      plan.pending_question = pq
      plan.save()
    end
  end

  def touch_timestamps()
    let now = DateTime.now().to_iso()
    if self.created_at == nil
      self.created_at = now
    end
    self.updated_at = now
  end

  def prompt_emoji()
    let s = (self.prompt ?? "").strip()
    if s == ""
      return ""
    end
    let n = 12
    if s.length() < n
      n = s.length()
    end
    s.substring(0, n).replace_all("\n", " ")
  end

  def write_pending_answer(qid, value)
    let answer = { "id": qid, "value": value }
    self.pending_question = answer
    self.save()
  end
end