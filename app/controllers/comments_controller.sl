# Comments controller — create comments on feature briefs.
# Nested under features: POST /features/:id/comments
class CommentsController < ApplicationController

  # Bulk-load attachment metadata into `{ blob_id => row }` so the
  # comments/_list partial can resolve filenames + content types in O(1)
  # without firing one Blob lookup per attachment.
  def _attachments_meta_for(comments)
    ids = comments.reduce(fn(ids, c) {
      bids = c.attachment_blob_ids ?? []
      for b in bids
        ids.push(b)
      end
      ids
    }, [])
    return {} if ids.length == 0
    rows = @sdbql{
      FOR d IN comment_attachments
        FILTER d._key IN #{ids}
        RETURN { "_key": d._key, "name": d.name, "type": d.type, "size": d["size"] }
    }
      rescue []
    rows.reduce(fn(h, r) {
      h[r["_key"]] = r
      h
    }, {})
  end

  # POST /comments/:key/delete
  # Removes a comment + all its attachment blobs (Comment.cleanup_uploads
  # fires via before_delete). Only the comment author may delete.
  def destroy(req)
    key = req["params"]["key"]
    comment = Comment.find_by("_key", key) rescue nil
    if comment.nil?
      return {"status": 404, "body": "Comment not found"}
    end

    user = req["current_user"]
    if user.nil?
      return {"status": 401, "body": "Sign in required"}
    end

    me = user.email ?? ""
    cauthor = comment.author ?? ""
    if cauthor != me
      return {"status": 403, "body": "You can only delete your own comments"}
    end

    feature_slug = comment.feature_slug ?? ""
    comment.delete()
    redirect("/features/" + feature_slug)
  end

  def create(req)
    feature_id = req["params"]["id"]
    form = req["all"] ?? {}
    body = (form["body"] ?? "").trim()
    author = ""
    author = req["current_user"].email ?? req["current_user"].display_name ?? "" if req["current_user"].present?

    # Accept comments that only carry attachments — body becomes a placeholder
    # so the validates("body", {presence:true}) check still passes.
    has_attachments = find_uploaded_file(req, "attachment").present? rescue false
    if body == "" && !has_attachments
      return {"status": 422, "body": "Comment body or an attachment is required"}
    end

    body = "(attachment)" if body == ""
    if author == ""
      return {"status": 422, "body": "Must be signed in to comment"}
    end

    comment = Comment.create_comment(feature_id, author, body)
    if comment._errors
      return {"status": 422, "body": "Failed to save comment"}
    end

    # Attach the uploaded file if one was submitted. `find_uploaded_file`
    # is single-shot — the form widget posts each file sequentially via
    # client-side JS, so a single comment-create request only carries the
    # body. Subsequent file uploads target the auto-mounted POST
    # /comments/:id/attachment endpoint.
    file = find_uploaded_file(req, "attachment") rescue nil
    comment.attach_attachment(file) rescue nil if file.present?

    # Re-render the comment list + a fresh (empty) form. The htmx target
    # on the form is `#comments-content` with `innerHTML` swap, so this
    # body replaces both the thread and the form atomically — clearing
    # the textarea without duplicating the form on the page.
    feature = Feature.find_by("_key", feature_id)
    comments = Comment.for_feature(feature_id)
    me_email = ""
    me_email = req["current_user"].email ?? "" if req["current_user"].present?
    html = render_partial(
      "comments/list",
      {
        "comments": comments,
        "attachments_meta": this._attachments_meta_for(comments),
        "current_user_email": me_email
      }
    )
    + "<div class=\"mt-5 pt-5 border-t border-white/5\">"
    + render_partial(
      "comments/form",
      {"feature": feature, "current_user": req["current_user"]}
    )
    + "</div>"
    {
      "status": 200,
      "headers": {"Content-Type": "text/html; charset=utf-8", "X-Comment-Key": comment._key},
      "body": html
    }
  end
end

# Surface the new comment's key so the form's JS can post any
# additional file attachments to /comments/<key>/attachment
# (the auto-mounted endpoint declared via `uploads(...)`).
