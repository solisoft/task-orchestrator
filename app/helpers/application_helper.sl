# Application-wide view helpers

# Drop the first `# Title` line (and any blank line right after it) from
# a markdown blob — the page already shows the title as an `<h1>`, so
# rendering it again inside the body would duplicate the heading.
def strip_title_heading(body: String) -> String
    let lines = body.split("\n")
    let out = []
    let dropped = false
    for line in lines
        if not dropped
            let s = line.trim()
            if s.starts_with("# ") and not s.starts_with("## ")
                dropped = true
                next
            end
        end
        out.push(line)
    end
    if out.length > 0 and out[0].trim() == ""
        let res = []
        for i in 1..out.length
            res.push(out[i])
        end
        out = res
    end
    return out.join("\n")
end

# Truncate text to a maximum length with ellipsis
def truncate_text(text: String, length: Int, suffix: String) -> String
    if len(text) <= length
        return text
    end
    return text.substring(0, length - len(suffix)) + suffix
end

# Capitalize first letter of a string
def capitalize(text: String) -> String
    if len(text) == 0
        return text
    end
    return text.substring(0, 1).upcase() + text.substring(1, len(text))
end

# SEC-012: Reject href values that would let an attacker run JS through
# `javascript:` (or similar) URL schemes. HTML-escaping the URL is *not*
# enough — the browser still parses `javascript:alert(1)` inside an
# `href` attribute. Mirror the allowlist used by the markdown sanitiser.
def _is_safe_link_url(url)
    lower = url.downcase()
    if lower.starts_with("http://") or lower.starts_with("https://") or lower.starts_with("mailto:")
        return true
    end
    if lower.starts_with("/") or lower.starts_with("#") or lower.starts_with("?")
        return true
    end
    # No allowed scheme prefix; treat as relative *only* if there is no
    # scheme separator (`:`) before the first /?#. Anything else is a
    # custom scheme like javascript:/data: and must be refused.
    cut = len(lower)
    s = lower.index_of("/")
    if s != -1 and s < cut
        cut = s
    end
    q = lower.index_of("?")
    if q != -1 and q < cut
        cut = q
    end
    h = lower.index_of("#")
    if h != -1 and h < cut
        cut = h
    end
    return !lower.substring(0, cut).contains(":")
end

def _safe_link_url(url)
    if _is_safe_link_url(url)
        return url
    end
    return "#"
end

# Generate an HTML link
def link_to(text: String, url: String) -> String
    return "<a href=\"" + h(_safe_link_url(url)) + "\">" + h(text) + "</a>"
end

# Generate an HTML link with CSS class
def link_to_class(text: String, url: String, css_class: String) -> String
    return "<a href=\"" + h(_safe_link_url(url)) + "\" class=\"" + h(css_class) + "\">" + h(text) + "</a>"
end

# Pluralize a word based on count
def pluralize(count: Int, singular: String, plural: String) -> String
    if count == 1
        return str(count) + " " + singular
    end
    return str(count) + " " + plural
end

# Simple pluralize (adds 's')
def pluralize_simple(count: Int, word: String) -> String
    if count == 1
        return str(count) + " " + word
    end
    return str(count) + " " + word + "s"
end

def round_dollar(amount)
    return Math.floor(amount * 100.0 + 0.5) / 100.0
end

# Render an ISO 8601 timestamp as a short, human-readable date like
# "13 May 2026". Returns "" for nil/empty/unparseable inputs so views
# can call this unconditionally on optional fields.
def format_date(iso)
    if iso == nil
        return ""
    end
    if iso == ""
        return ""
    end
    let dt = DateTime.parse(iso) rescue nil
    if dt == nil
        return ""
    end
    let months = [
        "Jan", "Feb", "Mar", "Apr", "May", "Jun",
        "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"
    ]
    let m = dt.month()
    if m < 1 or m > 12
        return ""
    end
    return str(dt.day()) + " " + months[m - 1] + " " + str(dt.year())
end
