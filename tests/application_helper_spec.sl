describe("application_helper", fn() {
  describe("strip_title_heading", fn() {
    test("removes the first # Title line", fn() {
      result = strip_title_heading("# Title\n\nSome body text")
      assert_eq(result, "Some body text")
    })

    test("keeps ## Title (not a first-level heading)", fn() {
      result = strip_title_heading("# Title\n\n## Section\n\nBody")
      assert(result.contains("## Section"))
    })

    test("returns full body when no # Title prefix", fn() {
      result = strip_title_heading("Some body text")
      assert_eq(result, "Some body text")
    })

    test("drops leading blank line after # Title", fn() {
      result = strip_title_heading("# Title\n\n\nBody")
      assert_not(result.starts_with("\n"))
    })
  })

  describe("truncate_text", fn() {
    test(
      "returns text unchanged when shorter than length",
      fn() {
        result = truncate_text("Hello", 10, "...")
        assert_eq(result, "Hello")
      }
    )

    test("truncates with ellipsis when text is longer", fn() {
      result = truncate_text("Hello World", 8, "...")
      assert_eq(result, "Hello...")
    })

    test("uses custom suffix", fn() {
      result = truncate_text("Hello World", 8, ">>")
      assert_eq(result, "Hello >>")
    })
  })

  describe("capitalize", fn() {
    test("capitalizes first letter", fn() { assert_eq(capitalize("hello"), "Hello") })

    test("leaves already capitalized string unchanged", fn() { assert_eq(capitalize("Hello"), "Hello") })

    test("returns empty string for empty input", fn() { assert_eq(capitalize(""), "") })
  })

  describe("_is_safe_link_url", fn() {
    test("accepts http and https", fn() {
      assert(_is_safe_link_url("http://example.com"))
      assert(_is_safe_link_url("https://example.com"))
    })

    test("accepts mailto", fn() { assert(_is_safe_link_url("mailto:test@example.com")) })

    test("accepts absolute paths", fn() {
      assert(_is_safe_link_url("/some/path"))
      assert(_is_safe_link_url("/"))
    })

    test("accepts fragment and query", fn() {
      assert(_is_safe_link_url("#fragment"))
      assert(_is_safe_link_url("?query=value"))
    })

    test("rejects javascript URLs", fn() {
      assert(!_is_safe_link_url("javascript:alert(1)"))
      assert(!_is_safe_link_url("javascript:void(0)"))
    })

    test("rejects data URLs", fn() { assert(!_is_safe_link_url("data:text/html,<script>alert(1)</script>")) })

    test("treats relative URLs without scheme as safe", fn() { assert(_is_safe_link_url("some/path")) })
  })

  describe("link_to", fn() {
    test("generates anchor tag with safe URL", fn() {
      result = link_to("Click", "/some/path")
      assert(result.contains("<a"))
      assert(result.contains("href=\"/some/path\""))
      assert(result.contains(">Click<"))
    })

    test("escapes link text", fn() {
      result = link_to("<script>", "/path")
      assert(result.contains("&lt;script&gt;"))
    })
  })

  describe("pluralize", fn() {
    test("singular for count of 1", fn() { assert_eq(pluralize(1, "item", "items"), "1 item") })

    test("plural for count not 1", fn() { assert_eq(pluralize(3, "item", "items"), "3 items") })

    test("zero uses plural", fn() { assert_eq(pluralize(0, "item", "items"), "0 items") })
  })

  describe("pluralize_simple", fn() {
    test("adds s for plural", fn() { assert_eq(pluralize_simple(2, "task"), "2 tasks") })

    test("no s for singular", fn() { assert_eq(pluralize_simple(1, "task"), "1 task") })
  })

  describe("round_dollar", fn() {
    test("rounds to two decimal places", fn() {
      assert_eq(round_dollar(10.456), 10.46)
      assert_eq(round_dollar(10.454), 10.45)
    })

    test("keeps exact cents unchanged", fn() { assert_eq(round_dollar(10.5), 10.5) })
  })

  describe("format_date", fn() {
    test("formats ISO timestamp", fn() { assert_eq(format_date("2026-05-13T10:30:00Z"), "13 May 2026") })

    test("returns empty for nil", fn() { assert_eq(format_date(nil), "") })

    test("returns empty for empty string", fn() { assert_eq(format_date(""), "") })

    test("returns empty for unparseable input", fn() { assert_eq(format_date("not-a-date"), "") })
  })
})
