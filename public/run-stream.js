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

  function appendLogChunk(logEl, chunk) {
    if (!logEl || !chunk) return;
    var pre = logEl.querySelector("pre");
    if (!pre) {
      // First chunk into an empty panel: replace the "no log yet"
      // placeholder with a fresh <pre>.
      logEl.innerHTML =
        '<pre class="font-mono text-xs leading-relaxed p-4 whitespace-pre-wrap m-0"></pre>';
      pre = logEl.querySelector("pre");
    }
    var lines = chunk.split("\n");
    var frag = document.createDocumentFragment();
    for (var i = 0; i < lines.length; i++) {
      // Skip a trailing empty string that comes from a chunk ending
      // in "\n" — we don't want to render an empty <span> for it.
      if (i === lines.length - 1 && lines[i] === "") break;
      var span = document.createElement("span");
      span.className = "block " + lineClass(lines[i]);
      span.textContent = lines[i];
      frag.appendChild(span);
    }
    pre.appendChild(frag);
    // Keep the bottom in view as new lines arrive.
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
    this.tickMs = parseInt(root.getAttribute("data-stream-tick-ms") || "300", 10) || 300;
    // Identifiers echoed on every tick. Soli's `router_websocket` routes
    // are static, so the URL alone can't tell the handler which resource
    // we're following. The page renders these into data-stream-* attrs.
    this.identifiers = {};
    var keys = ["project", "slug", "plan_id", "feature_id"];
    for (var i = 0; i < keys.length; i++) {
      var v = root.getAttribute("data-stream-" + keys[i].replace("_", "-"));
      if (v != null && v !== "") this.identifiers[keys[i]] = v;
    }
    this.backoffMs = 500;
    this.maxBackoffMs = 8000;
    this.closed = false;
    this.terminal = false;
    this.suppressed = false; // true while the plan/feature panel is awaiting an answer
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
    for (var k in this.identifiers) {
      if (Object.prototype.hasOwnProperty.call(this.identifiers, k)) {
        msg[k] = this.identifiers[k];
      }
    }
    try {
      this.ws.send(JSON.stringify(msg));
      this.firstMessageSent = true;
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
  };

  Controller.prototype.handleMessage = function (raw) {
    var msg;
    try { msg = JSON.parse(raw); } catch (e) { return; }
    var ev = msg.event || msg.type;
    if (ev === "delta" || ev === "snapshot") {
      if (typeof msg.log_chunk === "string" && msg.log_chunk.length) {
        appendLogChunk(this.find(this.logSel), msg.log_chunk);
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
        // GET lands the user on it cleanly.
        if (msg.reload === true) {
          // Defer slightly so any final DOM mutations from this frame land
          // before the reload — useful when the user is mid-scroll.
          setTimeout(function () { window.location.reload(); }, 50);
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
