// run-stream.js — live WebSocket transport for the run viewer, the
// plan-task viewer, and the feature generate-tasks viewer.
//
// Replaces the htmx `every 2s` polling those panels used to do. The
// server pushes `delta` frames containing the new log bytes since a
// byte cursor we own; we append them in place without re-rendering
// the whole panel.
//
// Wire-up is data-attribute driven so the same client serves all three
// stream shapes (look for `data-stream-url`). The element with the
// attribute also points us at the log / todos / status / question DOM
// hooks via further `data-stream-*` attributes — see init() below.

(function () {
  "use strict";

  // Map of element → controller, so a single page can host multiple
  // streams (eg. the feature show page can refresh tasks AND a plan
  // panel during the proposed-tasks transition).
  var controllers = new WeakMap();

  function buildUrl(path) {
    var proto = location.protocol === "https:" ? "wss:" : "ws:";
    return proto + "//" + location.host + path;
  }

  function escapeHtml(s) {
    if (s == null) return "";
    return String(s)
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;")
      .replace(/'/g, "&#39;");
  }

  // Classify a log line for terminal-colour styling. Mirrors
  // task_log_line_class from app/helpers/run_helper.sl so the live
  // stream matches what the initial SSR snapshot rendered.
  function lineClass(line) {
    var s = (line || "").trimStart();
    if (s.startsWith("error") || s.startsWith("Error") || s.startsWith("failed:") || s.startsWith("✗"))
      return "text-red-300";
    if (s.startsWith("warn") || s.startsWith("WARN") || s.startsWith("⚠"))
      return "text-amber-300";
    if (s.startsWith("done:") || s.startsWith("✓"))
      return "text-emerald-300";
    if (s.startsWith("[") || s.startsWith("==>") || s.startsWith("→"))
      return "text-indigo-300";
    return "text-slate-300";
  }

  // Prepend a one-shot prefix chunk above whatever SSR painted. Used on
  // the run viewer when the server's snapshot carries `prefix_chunk` —
  // bytes the SSR `run_log_tail` cap left out. Preserves the user's
  // distance-from-bottom across the insert so the live tail doesn't
  // scroll away when the backfill arrives.
  function prependLogChunk(logEl, chunk) {
    if (!logEl || !chunk) return;
    var pre = logEl.querySelector("pre");
    if (!pre) {
      logEl.innerHTML =
        '<pre class="font-mono text-xs leading-relaxed p-4 whitespace-pre-wrap m-0"></pre>';
      pre = logEl.querySelector("pre");
    }
    var distFromBottom = logEl.scrollHeight - logEl.scrollTop;
    var frag = document.createDocumentFragment();
    var lines = chunk.split("\n");
    var trailingNewline = chunk.charCodeAt(chunk.length - 1) === 10;
    var last = trailingNewline ? lines.length - 1 : lines.length;
    for (var i = 0; i < last; i++) {
      var span = document.createElement("span");
      span.className = "block " + lineClass(lines[i]);
      span.textContent = lines[i];
      frag.appendChild(span);
    }
    pre.insertBefore(frag, pre.firstChild);
    logEl.scrollTop = logEl.scrollHeight - distFromBottom;
  }

  function appendLogChunk(logEl, chunk, isSnapshot) {
    if (!logEl || !chunk) return;
    var pre = logEl.querySelector("pre");
    if (!pre) {
      logEl.innerHTML =
        '<pre class="font-mono text-xs leading-relaxed p-4 whitespace-pre-wrap m-0"></pre>';
      pre = logEl.querySelector("pre");
    }
    if (isSnapshot) pre._partialSpan = null;

    var frag = document.createDocumentFragment();
    var start = 0;
    var len = chunk.length;

    // If the last span from the previous chunk was a partial line
    // (didn't end with \n), extend it in-place instead of starting
    // a new span.
    if (pre._partialSpan) {
      var nl = chunk.indexOf("\n");
      if (nl === -1) {
        pre._partialSpan.textContent += chunk;
        logEl.scrollTop = logEl.scrollHeight;
        return;
      }
      pre._partialSpan.textContent += chunk.substring(0, nl);
      pre._partialSpan = null;
      start = nl + 1;
    }

    while (start < len) {
      var nl2 = chunk.indexOf("\n", start);
      if (nl2 === -1) {
        var span = document.createElement("span");
        span.className = "block " + lineClass(chunk.substring(start));
        span.textContent = chunk.substring(start);
        frag.appendChild(span);
        pre._partialSpan = span;
        break;
      }
      var span = document.createElement("span");
      span.className = "block " + lineClass(chunk.substring(start, nl2));
      span.textContent = chunk.substring(start, nl2);
      frag.appendChild(span);
      start = nl2 + 1;
    }
    pre.appendChild(frag);
    logEl.scrollTop = logEl.scrollHeight;
  }

  function replaceHtml(el, html) {
    if (!el || html == null) return;
    el.innerHTML = html;
  }

  // ---- Stream controller ----------------------------------------------------

  function Controller(root) {
    this.root = root;
    this.url = root.getAttribute("data-stream-url");
    this.logSel = root.getAttribute("data-stream-log") || null;
    this.todosSel = root.getAttribute("data-stream-todos") || null;
    this.statusSel = root.getAttribute("data-stream-status") || null;
    this.questionSel = root.getAttribute("data-stream-question") || null;
    this.terminalSel = root.getAttribute("data-stream-terminal") || null;
    // Server-rendered initial byte length tells the server which bytes
    // we already painted, so the first delta starts from there.
    this.offset = parseInt(root.getAttribute("data-stream-offset") || "0", 10) || 0;
    // Byte where the SSR-painted tail begins in the file. Sent once at
    // subscribe so the server includes the missing prefix bytes in the
    // snapshot. Zero means SSR painted the whole log — no backfill.
    this.prefixEnd = parseInt(root.getAttribute("data-stream-prefix-end") || "0", 10) || 0;
    this.tickMs = parseInt(root.getAttribute("data-stream-tick-ms") || "300", 10) || 300;
    // Identifiers echoed on every tick. Soli's `router_websocket` routes
    // are static, so the URL alone can't tell the handler which resource
    // we're following. The page renders these into data-stream-* attrs.
    // Optional fragment-refetch wiring. When a stream goes terminal AND
    // `reload: true` arrives, prefer swapping a fragment via HTMX over a
    // full window.location.reload() — keeps panels (eg. the task code
    // review history) from jumping the user back to the top of the page.
    this.refetchUrl = root.getAttribute("data-stream-refetch-url") || null;
    this.refetchTarget = root.getAttribute("data-stream-refetch-target") || null;
    this.identifiers = {};
    var keys = ["project", "slug", "plan_id", "feature_id", "review_id"];
    for (var i = 0; i < keys.length; i++) {
      var v = root.getAttribute("data-stream-" + keys[i].replace("_", "-"));
      if (v != null && v !== "") this.identifiers[keys[i]] = v;
    }
    var token = root.getAttribute("data-stream-token");
    if (token != null && token !== "") this.identifiers.stream_token = token;
    this.backoffMs = 500;
    this.maxBackoffMs = 8000;
    this.closed = false;
    this.terminal = false;
    this.suppressed = false;
    this.tickWatchdog = null;
    this.firstMessageSent = false;
    this.ws = null;
    this.tickTimer = null;
  }

  Controller.prototype.find = function (sel) {
    if (!sel) return null;
    // Selectors are scoped to the document so the panel can refer to
    // sibling elements that aren't strictly descendants (e.g. the
    // status pill row sits above #run-log in `_log.html.slv`).
    return document.querySelector(sel);
  };

  Controller.prototype.connect = function () {
    if (this.closed || this.terminal) return;
    var c = this;
    try {
      c.ws = new WebSocket(buildUrl(c.url));
    } catch (err) {
      c.scheduleReconnect();
      return;
    }
    c.ws.onopen = function () {
      c.backoffMs = 500;
      // Send our current cursor so the server can start streaming
      // from the right byte. The initial offset matches the bytes
      // the SSR snapshot already painted.
      c.sendTick();
    };
    c.ws.onmessage = function (ev) {
      c.handleMessage(ev.data);
    };
    c.ws.onerror = function () {};
    c.ws.onclose = function () {
      c.clearTickTimer();
      if (c.terminal || c.closed) return;
      c.scheduleReconnect();
    };
  };

  Controller.prototype.scheduleReconnect = function () {
    if (this.closed || this.terminal) return;
    var c = this;
    var delay = c.backoffMs;
    c.backoffMs = Math.min(c.backoffMs * 2, c.maxBackoffMs);
    setTimeout(function () { c.connect(); }, delay);
  };

  Controller.prototype.sendTick = function () {
    if (this.suppressed || this.terminal || this.closed) return;
    if (!this.ws || this.ws.readyState !== 1) return;
    var msg = { type: this.firstMessageSent ? "tick" : "subscribe",
                offset: this.offset };
    // `prefix_end` is a one-shot field on the subscribe message — the
    // server only emits a `prefix_chunk` on the connect frame, so there's
    // no point re-sending it on every tick.
    if (!this.firstMessageSent && this.prefixEnd > 0) {
      msg.prefix_end = this.prefixEnd;
    }
    for (var k in this.identifiers) {
      if (Object.prototype.hasOwnProperty.call(this.identifiers, k)) {
        msg[k] = this.identifiers[k];
      }
    }
    try {
      this.ws.send(JSON.stringify(msg));
      this.firstMessageSent = true;
      var c = this;
      c.tickWatchdog = setTimeout(function () {
        c.clearTickTimer();
        if (!c.terminal && !c.closed) c.scheduleReconnect();
      }, c.tickMs * 2);
    } catch (err) {
      // The next onclose will fire and the reconnect timer will handle it.
    }
  };

  Controller.prototype.armNextTick = function () {
    var c = this;
    c.clearTickTimer();
    if (c.suppressed || c.terminal || c.closed) return;
    c.tickTimer = setTimeout(function () { c.sendTick(); }, c.tickMs);
  };

  Controller.prototype.clearTickTimer = function () {
    if (this.tickTimer) {
      clearTimeout(this.tickTimer);
      this.tickTimer = null;
    }
    if (this.tickWatchdog) {
      clearTimeout(this.tickWatchdog);
      this.tickWatchdog = null;
    }
  };

  Controller.prototype.handleMessage = function (raw) {
    if (this.tickWatchdog) { clearTimeout(this.tickWatchdog); this.tickWatchdog = null; }
    var msg;
    try { msg = JSON.parse(raw); } catch (e) { return; }
    var ev = msg.event || msg.type;
    if (ev === "delta" || ev === "snapshot") {
      if (ev === "snapshot" && typeof msg.prefix_chunk === "string" && msg.prefix_chunk.length) {
        prependLogChunk(this.find(this.logSel), msg.prefix_chunk);
      }
      if (typeof msg.log_chunk === "string" && msg.log_chunk.length) {
        appendLogChunk(this.find(this.logSel), msg.log_chunk, ev === "snapshot");
      }
      if (typeof msg.log_offset === "number") this.offset = msg.log_offset;
      if (typeof msg.todos_html === "string") replaceHtml(this.find(this.todosSel), msg.todos_html);
      if (typeof msg.status_html === "string") replaceHtml(this.find(this.statusSel), msg.status_html);
      // `question_html` carries either the question card or an empty
      // string. An empty string clears the panel back to the running
      // state when the user's answer is consumed.
      if (typeof msg.question_html === "string") {
        replaceHtml(this.find(this.questionSel), msg.question_html);
        this.suppressed = msg.question_html.length > 0;
      }
      if (msg.terminal === true) {
        this.terminal = true;
        this.clearTickTimer();
        if (typeof msg.terminal_html === "string") {
          replaceHtml(this.find(this.terminalSel), msg.terminal_html);
        }
        this.close();
        // `reload` is the plan/feature streams' way of transitioning the
        // page to its post-agent layout: when the controller would have
        // returned a different partial after the agent finished, a fresh
        // GET lands the user on it cleanly. Panels that opt into
        // fragment-refetch (data-stream-refetch-url + -target) get a
        // scoped htmx swap instead — keeps scroll position intact.
        if (msg.reload === true) {
          var refetchUrl = this.refetchUrl;
          var refetchTarget = this.refetchTarget;
          setTimeout(function () {
            if (refetchUrl && refetchTarget && window.htmx && typeof window.htmx.ajax === "function") {
              try {
                window.htmx.ajax("GET", refetchUrl, { target: refetchTarget, swap: "outerHTML" });
                return;
              } catch (e) {
                // Fall through to full reload on any htmx error.
              }
            }
            window.location.reload();
          }, 50);
        }
        return;
      }
      this.armNextTick();
    }
  };

  Controller.prototype.close = function () {
    this.closed = true;
    this.clearTickTimer();
    if (this.ws) {
      try { this.ws.close(); } catch (e) {}
      this.ws = null;
    }
  };

  // ---- Boot ----------------------------------------------------------------

  function initOne(root) {
    if (controllers.has(root)) return;
    if (!root.getAttribute("data-stream-url")) return;
    if (typeof WebSocket === "undefined") return;
    var c = new Controller(root);
    controllers.set(root, c);
    c.connect();
  }

  function initAll(scope) {
    var nodes = (scope || document).querySelectorAll("[data-stream-url]");
    for (var i = 0; i < nodes.length; i++) initOne(nodes[i]);
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", function () { initAll(document); });
  } else {
    initAll(document);
  }

  // htmx swaps can drop a `data-stream-url` element into the DOM (eg.
  // the feature generate-tasks panel arrives via an htmx POST), so
  // boot any new ones after every swap.
  document.addEventListener("htmx:afterSwap", function (ev) {
    var target = (ev.detail && ev.detail.target) || ev.target;
    initAll(target || document);
  });

  // Tear down before the page unloads — keeps the server from holding
  // a dead socket open for a few seconds.
  window.addEventListener("beforeunload", function () {
    var nodes = document.querySelectorAll("[data-stream-url]");
    for (var i = 0; i < nodes.length; i++) {
      var c = controllers.get(nodes[i]);
      if (c) c.close();
    }
  });
})();
