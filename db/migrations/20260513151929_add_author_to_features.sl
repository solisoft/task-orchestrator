# Migration: add_author_to_features
#
# Adds the `author` field to features. Solidb collections are schemaless,
# so we only need a sparse index — existing rows without an author stay
# out of the index.
fn up(db) -> Any
  db.create_index("features", "idx_features_author", ["author"], {"sparse": true})
end

fn down(db) -> Any
  db.drop_index("features", "idx_features_author")
end
