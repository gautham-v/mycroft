/* OpenDispatch reader highlights. Runs in the article web view (WKContentWorld.defaultClient).

   Anchoring: a highlight is a text quote (exact text plus ~32 characters before and after) over the
   article's text content. The text is normalized the way it renders: runs of whitespace collapse to one
   space, and a space stands in at block boundaries and <br>, so a selection across paragraphs reads
   "one two" instead of "onetwo". Every normalized character remembers the text node and offset it came
   from, which turns a quote back into a DOM Range.

   Painting: one CSS Custom Highlight per color (`CSS.highlights`, styled by ::highlight(od-hl-<color>)
   in reader.css). Nothing is added to the DOM, so the fitted height of the web view never changes.

   Swift calls window.__odHL.set(list), .selectionAnchor(), .hit(x, y), .locate(id) and .clearSelection();
   the page posts {type: resolved | tap | context} to the openDispatchHighlights message handler. */
(function () {
  if (window.__odHL) return;

  var COLORS = ['yellow', 'green', 'blue', 'pink', 'purple', 'underline'];
  var CONTEXT = 32;
  var SKIP = { SCRIPT: 1, STYLE: 1, NOSCRIPT: 1, TEMPLATE: 1, SVG: 1 };

  var idx = null;     // { text, nodes[], offs[], mapped[] }: built once per document
  var items = [];     // [{ id, text, prefix, suffix, color }]
  var ranges = {};    // id -> Range

  function post(msg) {
    try { window.webkit.messageHandlers.openDispatchHighlights.postMessage(msg); } catch (e) {}
  }

  // MARK: Text index

  function isSpace(c) {
    return c === 32 || c === 9 || c === 10 || c === 12 || c === 13 || c === 160;
  }

  function build() {
    var root = document.querySelector('article') || document.body;
    var text = '';
    var nodes = [];   // nodes[i], offs[i]: where normalized char i came from; null for a stand-in space
    var offs = [];
    var mapped = [];  // indexes of the characters that have a source
    var sep = false;

    function push(ch, node, off) {
      if (node) mapped.push(text.length);
      text += ch;
      nodes.push(node);
      offs.push(off);
      sep = false;
    }

    function addText(n) {
      var d = n.data;
      for (var i = 0; i < d.length; i++) {
        var c = d.charCodeAt(i);
        var last = text.length ? text.charCodeAt(text.length - 1) : 32;
        if (isSpace(c)) {
          if (text.length && last !== 32) push(' ', n, i);
        } else {
          if (sep && text.length && last !== 32) push(' ', null, 0);
          push(d.charAt(i), n, i);
        }
      }
    }

    function walk(n) {
      if (n.nodeType === 3) { addText(n); return; }
      if (n.nodeType !== 1 || SKIP[n.tagName.toUpperCase()]) return;
      if (n.tagName === 'BR') { sep = true; return; }
      var display = getComputedStyle(n).display;
      if (display === 'none') return;
      var block = display.indexOf('inline') !== 0;
      if (block) sep = true;
      for (var c = n.firstChild; c; c = c.nextSibling) walk(c);
      if (block) sep = true;
    }

    walk(root);
    return { text: text, nodes: nodes, offs: offs, mapped: mapped };
  }

  function index() {
    if (!idx) idx = build();
    return idx;
  }

  // First position in `mapped` whose character satisfies pred (monotonic: false... then true...).
  function firstMapped(ix, pred) {
    var lo = 0, hi = ix.mapped.length;
    while (lo < hi) {
      var mid = (lo + hi) >> 1;
      var i = ix.mapped[mid];
      if (pred(ix.nodes[i], ix.offs[i])) hi = mid; else lo = mid + 1;
    }
    return lo;
  }

  // Normalized index of a DOM boundary: the start of the first character at or after it, or the end of
  // the last character before it.
  function startIndex(ix, probe) {
    var k = firstMapped(ix, function (node, off) { return probe.comparePoint(node, off) >= 0; });
    return k < ix.mapped.length ? ix.mapped[k] : ix.text.length;
  }

  function endIndex(ix, probe) {
    var k = firstMapped(ix, function (node, off) { return probe.comparePoint(node, off) >= 0; });
    return k > 0 ? ix.mapped[k - 1] + 1 : 0;
  }

  function collapsedAt(node, off) {
    var r = document.createRange();
    r.setStart(node, off);
    r.collapse(true);
    return r;
  }

  // MARK: Selection -> anchor

  function selectionAnchor() {
    var sel = window.getSelection();
    if (!sel || sel.rangeCount === 0 || sel.isCollapsed) return null;
    var sr = sel.getRangeAt(0);
    var article = document.querySelector('article');
    if (!article || !article.contains(sr.commonAncestorContainer)) return null;
    var ix = index();
    var s = startIndex(ix, collapsedAt(sr.startContainer, sr.startOffset));
    var e = endIndex(ix, collapsedAt(sr.endContainer, sr.endOffset));
    while (s < e && ix.text.charCodeAt(s) === 32) s++;
    while (e > s && ix.text.charCodeAt(e - 1) === 32) e--;
    if (e <= s) return null;
    return {
      text: ix.text.slice(s, e),
      prefix: ix.text.slice(Math.max(0, s - CONTEXT), s),
      suffix: ix.text.slice(e, e + CONTEXT)
    };
  }

  // MARK: Anchor -> Range

  function commonSuffix(a, b) {
    var n = 0;
    while (n < a.length && n < b.length && a.charCodeAt(a.length - 1 - n) === b.charCodeAt(b.length - 1 - n)) n++;
    return n;
  }

  function commonPrefix(a, b) {
    var n = 0;
    while (n < a.length && n < b.length && a.charCodeAt(n) === b.charCodeAt(n)) n++;
    return n;
  }

  function rangeFor(ix, s, e) {
    // First mapped character at or after s, last one before e.
    var lo = 0, hi = ix.mapped.length;
    while (lo < hi) { var m = (lo + hi) >> 1; if (ix.mapped[m] >= s) hi = m; else lo = m + 1; }
    var k0 = lo;
    lo = 0; hi = ix.mapped.length;
    while (lo < hi) { var m2 = (lo + hi) >> 1; if (ix.mapped[m2] >= e) hi = m2; else lo = m2 + 1; }
    var k1 = lo - 1;
    if (k0 >= ix.mapped.length || k1 < k0) return null;
    var i0 = ix.mapped[k0], i1 = ix.mapped[k1];
    var r = document.createRange();
    r.setStart(ix.nodes[i0], ix.offs[i0]);
    r.setEnd(ix.nodes[i1], ix.offs[i1] + 1);
    return r;
  }

  // The occurrence of the quote whose surroundings best match prefix/suffix.
  function resolve(h) {
    var ix = index();
    var t = h.text;
    if (!t) return null;
    var best = -1, bestScore = -1, from = 0, seen = 0, at;
    while ((at = ix.text.indexOf(t, from)) !== -1 && seen < 500) {
      seen++;
      var before = ix.text.slice(Math.max(0, at - (h.prefix || '').length), at);
      var after = ix.text.slice(at + t.length, at + t.length + (h.suffix || '').length);
      var score = commonSuffix(h.prefix || '', before) + commonPrefix(h.suffix || '', after);
      if (score > bestScore) { best = at; bestScore = score; }
      from = at + 1;
    }
    return best < 0 ? null : rangeFor(ix, best, best + t.length);
  }

  // MARK: Painting

  function paint() {
    var supported = window.CSS && CSS.highlights && typeof Highlight !== 'undefined';
    var groups = {};
    var found = [], missing = [];
    ranges = {};
    items.forEach(function (h) {
      var r = resolve(h);
      if (r) {
        ranges[h.id] = r;
        found.push(h.id);
        (groups[h.color] = groups[h.color] || []).push(r);
      } else {
        missing.push(h.id);
      }
    });
    if (supported) {
      COLORS.forEach(function (c) { CSS.highlights.delete('od-hl-' + c); });
      Object.keys(groups).forEach(function (c) {
        CSS.highlights.set('od-hl-' + c, new Highlight(...groups[c]));
      });
    }
    found.sort(function (a, b) { return ranges[a].compareBoundaryPoints(Range.START_TO_START, ranges[b]); });
    post({ type: 'resolved', order: found, missing: missing, supported: !!supported });
  }

  // MARK: Hit testing

  function caretPoint(x, y) {
    if (document.caretRangeFromPoint) {
      var r = document.caretRangeFromPoint(x, y);
      return r ? { node: r.startContainer, offset: r.startOffset } : null;
    }
    if (document.caretPositionFromPoint) {
      var p = document.caretPositionFromPoint(x, y);
      return p ? { node: p.offsetNode, offset: p.offset } : null;
    }
    return null;
  }

  function overRect(r, x, y) {
    var rects = r.getClientRects();
    for (var i = 0; i < rects.length; i++) {
      var b = rects[i];
      if (x >= b.left - 1 && x <= b.right + 1 && y >= b.top - 1 && y <= b.bottom + 1) return true;
    }
    return false;
  }

  // Id of the highlight under a client point (the shortest when they overlap), or null.
  function hit(x, y) {
    var p = caretPoint(x, y);
    if (!p) return null;
    var best = null, bestLen = Infinity;
    Object.keys(ranges).forEach(function (id) {
      var r = ranges[id];
      var inside = false;
      try { inside = r.isPointInRange(p.node, p.offset); } catch (e) {}
      if (inside && overRect(r, x, y)) {
        var len = r.toString().length;
        if (len < bestLen) { best = id; bestLen = len; }
      }
    });
    return best;
  }

  // MARK: Page events

  document.addEventListener('click', function (e) {
    if (e.button !== 0 || e.defaultPrevented) return;
    var sel = window.getSelection();
    if (sel && !sel.isCollapsed) return;
    if (e.target && e.target.closest && e.target.closest('a')) return;
    var id = hit(e.clientX, e.clientY);
    if (id) post({ type: 'tap', id: id, y: ranges[id].getBoundingClientRect().top + window.scrollY });
  }, true);

  // Sent before the native menu is built (Mac), so Swift knows what the menu is about.
  document.addEventListener('contextmenu', function (e) {
    var anchor = selectionAnchor();
    post({ type: 'context', anchor: anchor, id: anchor ? null : hit(e.clientX, e.clientY) });
  }, true);

  window.__odHL = {
    set: function (list) { items = list || []; paint(); },
    selectionAnchor: selectionAnchor,
    hit: hit,
    // Top of a highlight in page coordinates, or null when it isn't in this version of the article.
    locate: function (id) {
      var r = ranges[id];
      if (!r) return null;
      var rects = r.getClientRects();
      var top = rects.length ? rects[0].top : r.getBoundingClientRect().top;
      return top + window.scrollY;
    },
    clearSelection: function () {
      var sel = window.getSelection();
      if (sel) sel.removeAllRanges();
    }
  };
})();
