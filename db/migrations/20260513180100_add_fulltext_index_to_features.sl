# Migration: add_fulltext_index_to_features
#
# Adds a fulltext index on (title, description) so that the features index
# page can search across feature titles and descriptions efficiently.
# Solidb collections are schemaless, so no collection-alter step is needed.

fn up(db: Any) -> Any {
    db.create_index("features", "idx_features_title_description_fulltext",
        ["title", "description"], { "type": "fulltext" });
}

fn down(db: Any) -> Any {
    db.drop_index("features", "idx_features_title_description_fulltext");
}
