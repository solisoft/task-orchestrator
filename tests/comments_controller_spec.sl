# Comments controller — create and destroy comments on feature briefs.
# Routes sit inside the `authenticate` middleware block.

fn _comments_origin()
  let probe = get("/login")
  let url = probe["url"] ?? ""
  let prefix = "http://"
  if not url.starts_with(prefix)
    return url
  end
  let rest = url.substring(prefix.length(), url.length())
  let slash = rest.index_of("/")
  if slash > 0
    return prefix + rest.substring(0, slash)
  end
  url
end

describe("CommentsController", fn()
  before_each(fn()
    assert_test_db()
    Comment.delete_all()
    Feature.delete_all()
    User.delete_all()
  end)

  describe("POST /features/:id/comments", fn()
    test("redirects to login without authentication", fn()
      as_guest()
      let response = post("/features/feat-1/comments", { "body": "Hello" })
      assert_eq(res_status(response), 302)
    end)

    test("creates a comment when authenticated", fn()
      User.register("commenter@test.com", "password", "Commenter")
      login("commenter@test.com", "password")
      Feature.create({ "_key": "proj--feat", "project": "proj", "slug": "feat", "title": "Feature", "status": "draft" })
      let response = post("/features/proj--feat/comments", { "body": "Great feature!" },
        { "headers": { "Origin": _comments_origin() } })
      assert_eq(res_status(response), 200)
      let comments = Comment.for_feature("proj--feat")
      assert_eq(comments.length(), 1)
      assert_eq(comments[0].body, "Great feature!")
    end)
  end)
end)
