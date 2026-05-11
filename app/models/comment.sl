# Comment — discussion thread entries attached to a Feature.
# Persisted in solidb `comments` collection.
#
# Identity: `_key` = `<feature_slug>--<counter>` (auto-incrementing counter
# to avoid collisions when multiple comments are created rapidly).

class Comment < Model
  validates("feature_slug", { "presence": true })
  validates("author",       { "presence": true })
  validates("body",         { "presence": true })

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
