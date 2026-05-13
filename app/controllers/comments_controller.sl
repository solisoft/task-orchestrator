# Comments controller — create comments on feature briefs.
# Nested under features: POST /features/:id/comments

# Bulk-load attachment metadata into `{ blob_id => row }` so the
# comments/_list partial can resolve filenames + content types in O(1)
# without firing one Blob lookup per attachment.
fn _attachments_meta_for(comments)
  let ids = []
  for c in comments
    let bids = c.attachment_blob_ids ?? []
    for b in bids
      ids.push(b)
    end
  end
  if ids.length() == 0
    return {}
  end
  let rows = @sdbql{
    FOR d IN comment_attachments
      FILTER d._key IN #{ids}
      RETURN { "_key": d._key, "name": d.name, "type": d.type, "size": d["size"] }
  } rescue []
  let h = {}
  for r in rows
    h[r["_key"]] = r
  end
  h
end

# POST /comments/:key/delete
# Removes a comment + all its attachment blobs (Comment.cleanup_uploads
# fires via before_delete). Only the comment author may delete.
fn destroy(req)
  let key = req["params"]["key"]
  let comment = Comment.find_by("_key", key) rescue nil
  if comment == nil
    return {"status": 404, "body": "Comment not found"}
  end
  let user = req["current_user"]
  if user == nil
    return {"status": 401, "body": "Sign in required"}
  end
  let me = user.email ?? ""
  let cauthor = comment.author ?? ""
  if cauthor != me
    return {"status": 403, "body": "You can only delete your own comments"}
  end
  let feature_slug = comment.feature_slug ?? ""
  comment.delete()
  redirect("/features/" + feature_slug)
end

fn create(req)
  let feature_id = req["params"]["id"]
  let form = req["all"] ?? {}
  let body = (form["body"] ?? "").trim()
  let author = ""
  if req["current_user"] != nil
    author = req["current_user"].email ?? req["current_user"].display_name ?? ""
  end
  # Accept comments that only carry attachments — body becomes a placeholder
  # so the validates("body", {presence:true}) check still passes.
  let has_attachments = find_uploaded_file(req, "attachment") != nil rescue false
  if body == "" and not has_attachments
    return {"status": 422, "body": "Comment body or an attachment is required"}
  end
  if body == ""
    body = "(attachment)"
  end
  if author == ""
    return {"status": 422, "body": "Must be signed in to comment"}
  end
  let comment = Comment.create_comment(feature_id, author, body)
  if comment._errors
    return {"status": 422, "body": "Failed to save comment"}
  end
  # Attach the uploaded file if one was submitted. `find_uploaded_file`
  # is single-shot — the form widget posts each file sequentially via
  # client-side JS, so a single comment-create request only carries the
  # body. Subsequent file uploads target the auto-mounted POST
  # /comments/:id/attachment endpoint.
  let file = find_uploaded_file(req, "attachment") rescue nil
  if file != nil
    comment.attach_attachment(file) rescue nil
  end
  # Re-render the comment list + a fresh (empty) form. The htmx target
  # on the form is `#comments-content` with `innerHTML` swap, so this
  # body replaces both the thread and the form atomically — clearing
  # the textarea without duplicating the form on the page.
  let feature = Feature.find_by("_key", feature_id)
  let comments = Comment.for_feature(feature_id)
  let me_email = ""
  if req["current_user"] != nil
    me_email = req["current_user"].email ?? ""
  end
  let html = render_partial("comments/list", {
               "comments": comments,
               "attachments_meta": _attachments_meta_for(comments),
               "current_user_email": me_email
             }) +
             "<div class=\"mt-5 pt-5 border-t border-white/5\">" +
             render_partial("comments/form", {
               "feature": feature,
               "current_user": req["current_user"]
             }) +
             "</div>"
  {
    "status": 200,
    "headers": {
      "Content-Type": "text/html; charset=utf-8",
      # Surface the new comment's key so the form's JS can post any
      # additional file attachments to /comments/<key>/attachment
      # (the auto-mounted endpoint declared via `uploads(...)`).
      "X-Comment-Key": comment._key
    },
    "body": html
  }
end
