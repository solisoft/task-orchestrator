# Comments controller — create and destroy comments on feature briefs.
# Routes sit inside the `authenticate` middleware block.
fn _comments_origin
  probe = get("/login")
  url = probe["url"] ?? ""
  prefix = "http://"
  return url if !url.starts_with(prefix)
  rest = url.substring(prefix.length(), url.length())
  slash = rest.index_of("/")
  return prefix + rest.substring(0, slash) if slash > 0
  url
end

describe("CommentsController", fn() {
  before_each(fn() {
    assert_test_db()
    Comment.delete_all()
    Feature.delete_all()
    User.delete_all()
  })

  describe("POST /features/:id/comments", fn() {
    test("redirects to login without authentication", fn() {
      as_guest()
      response = post("/features/feat-1/comments", {"body": "Hello"})
      assert_eq(res_status(response), 302)
    })

    test("creates a comment when authenticated", fn() {
      User.register("commenter@test.com", "password", "Commenter")
      login("commenter@test.com", "password")
      Feature.create({
        "project": "proj",
        "slug": "feat",
        "title": "Feature",
        "status": "draft"
      }, {"key": "proj--feat"})
      response = post(
        "/features/proj--feat/comments",
        {"body": "Great feature!"},
        {"headers": {"Origin": _comments_origin()}}
      )
      assert_eq(res_status(response), 200)
      comments = Comment.for_feature("proj--feat")
      assert_eq(comments.length(), 1)
      assert_eq(comments[0].body, "Great feature!")
    })

    test(
      "response surfaces the new comment key via X-Comment-Key",
      fn() {
        User.register("commenter@test.com", "password", "Commenter")
        login("commenter@test.com", "password")
        Feature.create({
          "project": "proj",
          "slug": "feat",
          "title": "Feature",
          "status": "draft"
        }, {"key": "proj--feat"})
        response = post(
          "/features/proj--feat/comments",
          {"body": "Header check"},
          {"headers": {"Origin": _comments_origin()}}
        )
        assert_eq(res_status(response), 200)
        headers = response["headers"] ?? {}
        key = headers["X-Comment-Key"] ?? headers["x-comment-key"] ?? ""
        assert(key != "")
      }
    )

    test(
      "returns 422 when body is empty and no attachment is supplied",
      fn() {
        User.register("commenter@test.com", "password", "Commenter")
        login("commenter@test.com", "password")
        Feature.create({
          "project": "proj",
          "slug": "empty-body",
          "title": "Empty",
          "status": "draft"
        }, {"key": "proj--empty-body"})
        response = post(
          "/features/proj--empty-body/comments",
          {"body": ""},
          {"headers": {"Origin": _comments_origin()}}
        )
        assert_eq(res_status(response), 422)
        assert_eq(Comment.for_feature("proj--empty-body").length(), 0)
      }
    )

    test(
      "returns 422 when body is whitespace-only and no attachment is supplied",
      fn() {
        User.register("commenter@test.com", "password", "Commenter")
        login("commenter@test.com", "password")
        Feature.create({
          "project": "proj",
          "slug": "ws-body",
          "title": "WS",
          "status": "draft"
        }, {"key": "proj--ws-body"})
        response = post(
          "/features/proj--ws-body/comments",
          {"body": "   \n  "},
          {"headers": {"Origin": _comments_origin()}}
        )
        assert_eq(res_status(response), 422)
        assert_eq(Comment.for_feature("proj--ws-body").length(), 0)
      }
    )
  })

  describe("POST /comments/:key/delete", fn() {
    test("returns 404 for an unknown comment key", fn() {
      User.register("destroyer@test.com", "password", "Destroyer")
      login("destroyer@test.com", "password")
      response = post("/comments/no-such-comment/delete", {}, {"headers": {"Origin": _comments_origin()}})
      assert_eq(res_status(response), 404)
    })

    test(
      "returns 403 when the caller is not the comment author",
      fn() {
        User.register("owner@test.com", "password", "Owner")
        User.register("intruder@test.com", "password", "Intruder")
        Feature.create({
          "project": "proj",
          "slug": "shared",
          "title": "Shared",
          "status": "draft"
        }, {"key": "proj--shared"})
        Comment.create_comment("proj--shared", "owner@test.com", "Mine")
        key = Comment.for_feature("proj--shared")[0]._key
        login("intruder@test.com", "password")
        response = post("/comments/" + key + "/delete", {}, {"headers": {"Origin": _comments_origin()}})
        assert_eq(res_status(response), 403)
        # Comment must still exist.
        assert_eq(Comment.for_feature("proj--shared").length(), 1)
      }
    )

    test(
      "deletes the comment and redirects to the feature when author matches",
      fn() {
        User.register("owner@test.com", "password", "Owner")
        login("owner@test.com", "password")
        Feature.create({
          "project": "proj",
          "slug": "mine",
          "title": "Mine",
          "status": "draft"
        }, {"key": "proj--mine"})
        Comment.create_comment("proj--mine", "owner@test.com", "Going away")
        key = Comment.for_feature("proj--mine")[0]._key
        response = post("/comments/" + key + "/delete", {}, {"headers": {"Origin": _comments_origin()}})
        assert_eq(res_status(response), 302)
        assert_eq(Comment.for_feature("proj--mine").length(), 0)
        headers = response["headers"] ?? {}
        loc = headers["Location"] ?? headers["location"] ?? ""
        assert_contains(loc, "/features/proj--mine")
      }
    )
  })
})
