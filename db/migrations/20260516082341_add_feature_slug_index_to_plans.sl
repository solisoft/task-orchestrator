// Migration: add_feature_slug_index_to_plans
//
// The feature show page reads plans via
//   Plan.where({ "feature_slug": feature._key }).order("plan_id", "desc").all()
// Without an index this is a full collection scan; the dev bar flagged
// the query under "missing index". A sparse index keeps the row cost
// down for plans that pre-date the feature_slug tag (it's nil on those).

fn up(db: Any) -> Any {
    db.create_index("plans", "idx_plans_feature_slug",
        ["feature_slug"], { "sparse": true });
}

fn down(db: Any) -> Any {
    db.drop_index("plans", "idx_plans_feature_slug");
}
