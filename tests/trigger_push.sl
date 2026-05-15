describe("trigger push", fn()
  before_each(fn()
    assert_test_db()
  end)

  test("send", fn()
    let keys = web_push_ensure_keys()
    if keys == nil
      throw("no VAPID keys")
    end
    let subs = PushSubscription.all()
    if subs.length() == 0
      throw("no subscriptions")
    end
    let body = JSON.stringify({ "title": "Test from CLI", "status": "test", "url": "/test" })
    for sub in subs
      let res = _web_push_send_one(sub, body, keys)
      print("result: ok=" + str(res["ok"]) + " pruned=" + str(res["pruned"]))
    end
  end)
end)
