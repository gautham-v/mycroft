import Foundation

/// The JavaScript behind Read aloud, injected into the article web view (our own content world, like
/// `ReaderHTML.fitScript`). It finds the sentences, highlights the one being spoken and reports clicks
/// and the selection back. Nothing in the DOM changes (the view is fitted to its content height).
///
/// `window.odSpeech`:
/// - `extract(title, lang)` walks the text blocks in reading order, splits each into sentences with
///   `Intl.Segmenter` and keeps a DOM Range per sentence. Returns `[[text, endsBlock], …]`.
/// - `show(i)` highlights sentence `i` (CSS Custom Highlight API, `::highlight(od-speech)` in reader.css)
///   and returns `[top, bottom, firstLineBottom]` in the view's coordinates, which are the page's: the
///   web view never scrolls itself.
/// - `selectionIndex()` is the sentence the selection starts in, `setActive(on)` turns click-to-jump on.
///
/// Messages to the `openDispatchSpeech` handler: `ready`, `jump` (index), `selection` (value).
enum ReaderSpeechScript {
    static let handlerName = "openDispatchSpeech"
    static let highlightName = "od-speech"

    static let source = """
    (function () {
      if (window.odSpeech) return;
      // Text is read from these blocks. The last group catches text that sits straight in a container
      // (posts, loose text between paragraphs); a text node belongs to its closest block only.
      var BLOCKS = 'p,li,h1,h2,h3,h4,h5,h6,blockquote,figcaption,div,td,th,dt,dd';
      // Never read: code blocks, scripts, controls, anything hidden from the page.
      var SKIP = 'pre,script,style,noscript,svg,button,select,textarea,template,[hidden],[aria-hidden="true"]';
      var sentences = [];
      var active = false;
      var hadSelection = false;
      var segmenter = null;

      function post(message) {
        try { window.webkit.messageHandlers.\(handlerName).postMessage(message); } catch (e) {}
      }

      // WebKit's segmenter has no abbreviation rules, so "Dr. Smith" and "Jan. 5" would split. Rejoin the
      // usual English ones: titles, "No." and months before a number, initials before a name.
      var ABBR = /(?:^|[\\s("'])(?:Mr|Mrs|Ms|Mx|Dr|Prof|Sr|Jr|St|Mt|vs|Inc|Ltd|Co|Corp|Fig|Vol|Rev|Gen|Gov|Sen|Rep|Lt|Col|Capt|Sgt|e\\.g|i\\.e|cf)\\.$/;
      var BEFORE_NUMBER = /(?:^|[\\s("'])(?:No|Nos|Jan|Feb|Mar|Apr|Jun|Jul|Aug|Sep|Sept|Oct|Nov|Dec|pp?)\\.$/;
      var INITIAL = /(?:^|[\\s("'])[A-Z]\\.$/;
      function continues(prev, next) {
        if (ABBR.test(prev)) return true;
        if (BEFORE_NUMBER.test(prev) && /^\\d/.test(next)) return true;
        return INITIAL.test(prev) && /^[A-Z]/.test(next);
      }

      function split(text, english) {
        var out = [];
        if (segmenter) {
          for (var seg of segmenter.segment(text)) out.push([seg.index, seg.index + seg.segment.length]);
        } else {
          var re = /[^.!?]+[.!?]+["')\\]]*\\s*|[^.!?]+$/g, m;
          while ((m = re.exec(text))) out.push([m.index, m.index + m[0].length]);
        }
        if (!english) return out;
        var joined = [];
        for (var i = 0; i < out.length; i++) {
          var last = joined[joined.length - 1];
          if (last && continues(text.slice(last[0], last[1]).trim(), text.slice(out[i][0], out[i][1]).trim())) last[1] = out[i][1];
          else joined.push(out[i]);
        }
        return joined;
      }

      // A rendered block's text with whitespace collapsed as the page shows it, and for each character
      // where it came from (null for the space a <br> stands for).
      function blockText(block, visible) {
        var chars = [], map = [];
        function push(ch, node, offset) {
          if (ch === ' ' && (chars.length === 0 || chars[chars.length - 1] === ' ')) return;
          chars.push(ch);
          map.push(node ? [node, offset] : null);
        }
        var walker = document.createTreeWalker(block, NodeFilter.SHOW_TEXT | NodeFilter.SHOW_ELEMENT, null);
        var n;
        while ((n = walker.nextNode())) {
          if (n.nodeType === 1) { if (n.tagName === 'BR') push(' ', null, 0); continue; }
          var el = n.parentElement;
          if (!el || el.closest(BLOCKS) !== block || !visible(el)) continue;
          var v = n.nodeValue;
          for (var i = 0; i < v.length; i++) push(/\\s/.test(v[i]) ? ' ' : v[i], n, i);
        }
        while (chars.length && chars[chars.length - 1] === ' ') { chars.pop(); map.pop(); }
        return { text: chars.join(''), map: map };
      }

      function norm(s) { return s.toLowerCase().replace(/\\s+/g, ' ').trim(); }

      function extract(title, lang) {
        try { segmenter = new Intl.Segmenter(lang || undefined, { granularity: 'sentence' }); } catch (e) { segmenter = null; }
        var english = !lang || /^en/i.test(lang);
        var seen = new Map();
        function visible(el) {
          if (seen.has(el)) return seen.get(el);
          var ok = !el.closest(SKIP) && el.getClientRects().length > 0 && getComputedStyle(el).visibility !== 'hidden';
          seen.set(el, ok);
          return ok;
        }
        sentences = [];
        var root = document.querySelector('article') || document.body;
        var blocks = root.querySelectorAll(BLOCKS);
        var skippedTitle = !title;
        for (var b = 0; b < blocks.length; b++) {
          var info = blockText(blocks[b], visible);
          if (!info.text) continue;
          // The headline is read from the native header; drop a copy of it at the top of the body.
          if (!skippedTitle) {
            skippedTitle = true;
            if (norm(info.text) === norm(title)) continue;
          }
          var first = sentences.length;
          var spans = split(info.text, english);
          for (var k = 0; k < spans.length; k++) {
            var s = spans[k][0], e = spans[k][1];
            while (s < e && (info.text[s] === ' ' || !info.map[s])) s++;
            while (e > s && (info.text[e - 1] === ' ' || !info.map[e - 1])) e--;
            if (s >= e || !/[\\p{L}\\p{N}]/u.test(info.text.slice(s, e))) continue;
            var range = document.createRange();
            range.setStart(info.map[s][0], info.map[s][1]);
            range.setEnd(info.map[e - 1][0], info.map[e - 1][1] + 1);
            sentences.push({ range: range, text: info.text.slice(s, e), endsBlock: false });
          }
          if (sentences.length > first) sentences[sentences.length - 1].endsBlock = true;
        }
        return sentences.map(function (s) { return [s.text, s.endsBlock ? 1 : 0]; });
      }

      // One Highlight stays registered and is emptied or refilled: WebKit doesn't repaint text whose
      // Highlight is deleted from the registry, so the last sentence stayed tinted after Stop.
      var spoken = null;
      function painter() {
        if (!spoken) { spoken = new Highlight(); CSS.highlights.set('\(highlightName)', spoken); }
        return spoken;
      }

      function clear() {
        try { painter().clear(); } catch (e) {}
      }

      function show(i) {
        var s = sentences[i];
        if (!s) { clear(); return null; }
        try { var h = painter(); h.clear(); h.add(s.range); } catch (e) {}
        var r = s.range.getBoundingClientRect();
        var rects = s.range.getClientRects();
        var first = rects.length ? rects[0] : r;
        return [r.top, r.bottom, first.bottom];
      }

      // The first sentence that ends at or after the point.
      function indexAt(node, offset, exact) {
        for (var i = 0; i < sentences.length; i++) {
          var c;
          try { c = sentences[i].range.comparePoint(node, offset); } catch (e) { continue; }
          if (c === 0) return i;
          if (c < 0) return exact ? -1 : i;
        }
        return -1;
      }

      function selectionIndex() {
        var sel = window.getSelection();
        if (!sel || sel.rangeCount === 0 || sel.isCollapsed) return -1;
        var r = sel.getRangeAt(0);
        return indexAt(r.startContainer, r.startOffset, false);
      }

      document.addEventListener('click', function (e) {
        if (!active || e.defaultPrevented || !sentences.length) return;
        if (e.target.closest && e.target.closest('a,button,input,select,textarea,summary,video,audio,iframe')) return;
        var sel = window.getSelection();
        if (sel && !sel.isCollapsed) return;
        // A click on a highlight belongs to Highlights & Notes (reader-highlights.js), not a jump.
        if (window.__odHL && window.__odHL.hit(e.clientX, e.clientY)) return;
        var caret = document.caretRangeFromPoint ? document.caretRangeFromPoint(e.clientX, e.clientY) : null;
        if (!caret) return;
        var i = indexAt(caret.startContainer, caret.startOffset, true);
        if (i >= 0) post({ type: 'jump', index: i });
      }, false);

      document.addEventListener('selectionchange', function () {
        var sel = window.getSelection();
        var has = !!sel && sel.rangeCount > 0 && !sel.isCollapsed;
        if (has !== hadSelection) { hadSelection = has; post({ type: 'selection', value: has }); }
      });

      window.odSpeech = {
        extract: extract,
        show: show,
        clear: clear,
        selectionIndex: selectionIndex,
        setActive: function (on) { active = !!on; if (!active) clear(); }
      };
      post({ type: 'ready' });
    })();
    """
}
