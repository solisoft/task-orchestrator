# Comment — discussion thread entries attached to a Feature.
# Persisted in solidb `comments` collection.
#
# Identity: `_key` = `<feature_slug>--<counter>` (auto-incrementing counter
# to avoid collisions when multiple comments are created rapidly).

class Comment < Model
  validates("feature_slug", { "presence": true })
  validates("author",       { "presence": true })
  validates("body",         { "presence": true })

  # Built-in Soli uploader DSL — stores blobs in solidb collection
  # `comment_attachments` and exposes `attach_attachment(file)`,
  # `detach_attachment(blob_id)`, and the `attachment_blob_ids` field.
  uploader("attachment", {
    "multiple": true,
    "content_types": [
      "image/jpeg", "image/png", "image/webp", "image/gif", "image/svg+xml",
      "application/pdf",
      "application/msword",
      "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
      "application/vnd.ms-excel",
      "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
      "text/csv", "text/plain", "application/json",
      "application/zip", "application/x-zip-compressed"
    ],
    "max_size":   10_000_000,
    "collection": "comment_attachments"
  })

  before_delete("cleanup_uploads")

  def cleanup_uploads()
    detach_all_uploads(self)
  end

  static def create_comment(feature_slug, author, body)
    let existing = Comment.for_feature(feature_slug)
    let next_num = existing.length() + 1
    Comment.create({
      "_key":         feature_slug + "--" + str(next_num),
      "feature_slug": feature_slug,
      "author":       author,
      "body":         body,
      "created_at":   DateTime.now().to_iso()
    })
  end

  # Comments for a given feature, ordered oldest-first.
  static def for_feature(feature_slug)
    Comment.where({ "feature_slug": feature_slug }).order("created_at", "asc").all()
  end
end
