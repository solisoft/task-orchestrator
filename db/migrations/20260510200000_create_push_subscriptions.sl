// Migration: create_push_subscriptions
//
// One row per browser subscription returned by the Push API. The
// `endpoint` URL is unique (the browser/push-service guarantees one
// endpoint per device + service-worker registration), so we treat it
// as the natural identity for upsert + delete.
//
// Fields: endpoint (unique), p256dh, auth, user_agent, created_at.

fn up(db: Any) -> Any {
    db.create_collection("push_subscriptions");

    db.create_index("push_subscriptions", "idx_push_subs_endpoint",
        ["endpoint"], { "unique": true });
}

fn down(db: Any) -> Any {
    db.drop_index("push_subscriptions", "idx_push_subs_endpoint");
    db.drop_collection("push_subscriptions");
}
