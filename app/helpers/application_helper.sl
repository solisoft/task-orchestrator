# Application-wide view helpers

# Drop the first `# Title` line (and any blank line right after it) from
# a markdown blob — the page already shows the title as an `<h1>`, so
# rendering it again inside the body would duplicate the heading.
fn strip_title_heading(body: String) -> String
  lines = body.split("\n")
  out = []
  dropped = false
  for line in lines
    if !dropped
      s = line.trim()
      if s.starts_with("# ") && !s.starts_with("## ")
        dropped = true
      else
        out.push(line)
      end
    else
      out.push(line)
    end
  end

  if out.length > 0
    res = []
    i = 0
    while i < out.length && out[i].trim() == ""
      i = i + 1
    end

    while i < out.length
      res.push(out[i])
      i = i + 1
    end

    out = res
  end

  return out.join("\n")
end

# Truncate text to a maximum length with ellipsis

fn truncate_text(text: String, length: Int, suffix: String) -> String
  if len(text) <= length
    return text
  end

  suffix_len = len(suffix)
  prefix_len = length - suffix_len
  i = 0
  result = ""
  while i < prefix_len && i < len(text)
    result = result + text[i]
    i = i + 1
  end

  return result + suffix
end

# Capitalize first letter of a string

fn capitalize(text: String) -> String
  if len(text) == 0
    return text
  end

  return text.substring(0, 1).upcase() + text.substring(1, len(text))
end

# SEC-012: Reject href values that would let an attacker run JS through
# `javascript:` (or similar) URL schemes. HTML-escaping the URL is *not*
# enough — the browser still parses `javascript:alert(1)` inside an
# `href` attribute. Mirror the allowlist used by the markdown sanitiser.

fn _is_safe_link_url(url)
  lower = url.downcase()
  if lower.starts_with("http://") || lower.starts_with("https://") || lower.starts_with("mailto:")
    return true
  end

  if lower.starts_with("/") || lower.starts_with("#") || lower.starts_with("?")
    return true
  end

  # No allowed scheme prefix; treat as relative *only* if there is no
  # scheme separator (`:`) before the first /?#. Anything else is a
  # custom scheme like javascript:/data: and must be refused.

  cut = len(lower)
  s = lower.index_of("/")
  if s != -1 && s < cut
    cut = s
  end

  q = lower.index_of("?")
  if q != -1 && q < cut
    cut = q
  end

  h_idx = lower.index_of("#")
  if h_idx != -1 && h_idx < cut
    cut = h_idx
  end

  has_colon = false
  for i in 0 .. cut
    if lower[i] == ":"
      has_colon = true
    end
  end

  return !has_colon
end

fn _safe_link_url(url)
  if _is_safe_link_url(url)
    return url
  end

  return "#"
end

fn h(text: String) -> String
  return text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace("\"", "&quot;")
end

# Generate an HTML link

fn link_to(text: String, url: String) -> String
  return "<a href=\"" + h(_safe_link_url(url)) + "\">" + h(text) + "</a>"
end

# Generate an HTML link with CSS class

fn link_to_class(text: String, url: String, css_class: String) -> String
  return "<a href=\"" + h(_safe_link_url(url)) + "\" class=\"" + h(css_class) + "\">" + h(text) + "</a>"
end

# Pluralize a word based on count

fn pluralize(count: Int, singular: String, plural: String) -> String
  if count == 1
    return str(count) + " " + singular
  end

  return str(count) + " " + plural
end

# Simple pluralize (adds 's')

fn pluralize_simple(count: Int, word: String) -> String
  if count == 1
    return str(count) + " " + word
  end

  return str(count) + " " + word + "s"
end

fn round_dollar(amount)
  return Math.floor(amount * 100.0 + 0.5) / 100.0
end

# Render an ISO 8601 timestamp as a short, human-readable date like
# "13 May 2026". Returns "" for nil/empty/unparseable inputs so views
# can call this unconditionally on optional fields.

fn format_date(iso)
  if iso == null
    return ""
  end

  if iso == ""
    return ""
  end

  dt = DateTime.parse(iso) rescue null
  if dt == null
    return ""
  end

  months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

  m = dt.month()
  if m < 1 || m > 12
    return ""
  end

  return str(dt.day()) + " " + months[m - 1] + " " + str(dt.year())
end
