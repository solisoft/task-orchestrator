# Comments controller — create comments on feature briefs.
# Nested under features: POST /features/:id/comments

fn create(req)
  let feature_id = req["params"]["id"]
  let form = req["all"] ?? {}
  let body = (form["body"] ?? "").trim()
  let author = ""
  if req["current_user"] != nil
    author = req["current_user"].email ?? req["current_user"].display_name ?? ""
  end
  if body == ""
    return {"status": 422, "body": "Comment body is required"}
  end
  if author == ""
    return {"status": 422, "body": "Must be signed in to comment"}
  end
  let comment = Comment.create_comment(feature_id, author, body)
  if comment._errors
    return {"status": 422, "body": "Failed to save comment"}
  end
  # Re-render the comment list + form on the feature page.
  let feature = Feature.find_by("_key", feature_id)
  let comments = Comment.for_feature(feature_id)
  let html = render_partial("comments/list", { "comments": comments })
            + render_partial("comments/form", {
                "feature": feature,
                "current_user": req["current_user"]
              })
  {
    "status": 200,
    "headers": {"Content-Type": "text/html; charset=utf-8"},
    "body": html
  }
end
