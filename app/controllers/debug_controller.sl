fn show(req)
  {
    "status": 200,
    "headers": {"Content-Type": "text/plain"},
    "body":
      "Task.count() = " + str(Task.count() rescue "ERR") + "\n" +
      "lang count = " +
        str((Task.where({ "project": "lang" }).all().length) rescue "ERR") + "\n" +
      "run_state_root = " + str(run_state_root() rescue "ERR") + "\n"
  }
end
