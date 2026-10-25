// OPML smoke test: ./node_modules/.bin/tsx scripts/opml-check.ts
import assert from "node:assert/strict";
import { decodeEntities, parse, serialize } from "../src/lib/opml";

// --- round trip ------------------------------------------------------------------

const folders = [
  { id: 1, title: "Labs & Research" },
  { id: 2, title: "Empty" },
  { id: 3, title: "Video" },
];
const sources = [
  { title: "Anthropic News", url: "https://www.anthropic.com", feedUrl: "https://www.anthropic.com/news/rss.xml", kind: "rss" as const, folderId: 1 },
  { title: `Quotes "and" <tags>`, url: "https://example.com", feedUrl: "https://example.com/feed?a=1&b=2", kind: "rss" as const, folderId: 1 },
  {
    title: "Fireship",
    url: "https://www.youtube.com/channel/UCsBjURrPoezykLs9EqgamOA",
    feedUrl: "https://www.youtube.com/feeds/videos.xml?channel_id=UCsBjURrPoezykLs9EqgamOA",
    kind: "youtube" as const,
    folderId: 3,
  },
  { title: "A scraped page", url: "https://lab.example/news", feedUrl: "https://lab.example/news", kind: "page" as const, folderId: null },
  { title: "Orphan (folder not exported)", url: "https://o.example", feedUrl: "https://o.example/rss", kind: "rss" as const, folderId: 99 },
];

const xml = serialize(folders, sources, new Date("2026-10-24T12:00:00Z"));
assert.match(xml, /^<\?xml version="1.0" encoding="UTF-8"\?>\n<opml version="2.0"/);
assert.match(xml, /<dateCreated>Sat, 24 Oct 2026 12:00:00 GMT<\/dateCreated>/);
assert.ok(!xml.includes(`title="Empty"`), "empty folders are left out");
assert.ok(xml.includes(`xmlUrl="https://example.com/feed?a=1&amp;b=2"`), "attribute values are escaped");

const back = parse(xml);
assert.deepEqual(
  back.folders.map((f) => [f.title, f.sources.map((s) => s.title)]),
  [
    ["Labs & Research", ["Anthropic News", `Quotes "and" <tags>`]],
    ["Video", ["Fireship"]],
  ],
);
assert.deepEqual(
  back.unfiled.map((s) => [s.title, s.kind]),
  [
    ["A scraped page", "page"],
    ["Orphan (folder not exported)", "rss"],
  ],
);
const quoted = back.folders[0].sources[1];
assert.equal(quoted.feedUrl, "https://example.com/feed?a=1&b=2");
assert.equal(quoted.htmlUrl, "https://example.com");
assert.equal(back.folders[1].sources[0].kind, "youtube");

// --- messy real-world exports ------------------------------------------------------

// Feedly-ish: no xmlns, `text` only on folders, mixed attribute case, single quotes, comments,
// double-escaped titles, a feed nested under another feed, a wrapper outline, duplicates.
const MESSY = `<?xml version="1.0" encoding="UTF-8"?>
<!-- exported by some reader -->
<opml version="1.0">
  <head><title>Feedly &amp; friends</title></head>
  <body>
    <outline text="Tech" title="Tech">
      <outline type="rss" text="Ars Technica" title="Ars Technica" xmlUrl="https://feeds.arstechnica.com/arstechnica/index" htmlUrl="https://arstechnica.com"/>
      <outline text="AT&amp;amp;T &#8211; Blog" xmlurl="https://att.example/feed"></outline>
      <outline text='Single quoted' XMLURL='https://sq.example/rss'/>
      <!-- <outline text="Commented out" xmlUrl="https://nope.example/rss"/> -->
      <outline text="Sub">
        <outline text="Deep" xmlUrl="https://deep.example/atom.xml"/>
      </outline>
    </outline>
    <outline text="tech">
      <outline text="Merged case-insensitively" xmlUrl="https://merged.example/feed"/>
      <outline text="Ars dup" xmlUrl="https://feeds.arstechnica.com/arstechnica/index"/>
    </outline>
    <outline title="Untitled wrapper has a title attr only">
      <outline text="In wrapper" xmlUrl="feed://wrapped.example/rss"/>
    </outline>
    <outline text="">
      <outline text="Blank folder passes through" xmlUrl="https://blank.example/rss"/>
    </outline>
    <outline type="rss" text="Parent feed" xmlUrl="https://parent.example/rss">
      <outline text="Child of feed" xmlUrl="https://child.example/rss"/>
    </outline>
    <outline text="Top level, no type" xmlUrl="https://top.example/rss"/>
    <outline text="Not a feed, no children"/>
    <outline type="link" text="A link" url="https://link.example/rss"/>
  </body>
</opml>`;

const messy = parse(MESSY);
assert.deepEqual(
  messy.folders.map((f) => [f.title, f.sources.map((s) => s.title)]),
  [
    ["Tech", ["Ars Technica", "AT&T – Blog", "Single quoted", "Merged case-insensitively"]],
    ["Sub", ["Deep"]],
    ["Untitled wrapper has a title attr only", ["In wrapper"]],
  ],
);
assert.deepEqual(
  messy.unfiled.map((s) => s.title),
  ["Blank folder passes through", "Parent feed", "Child of feed", "Top level, no type", "A link"],
);
assert.equal(messy.folders[2].sources[0].feedUrl, "https://wrapped.example/rss", "feed:// becomes https://");
assert.equal(messy.folders[0].sources[0].htmlUrl, "https://arstechnica.com");
assert.equal(messy.folders[0].sources[1].htmlUrl, null);
assert.ok(messy.folders.every((f) => f.sources.every((s) => s.kind === null)), "foreign exports carry no kind");

// Inoreader-ish: everything wrapped in a single "Subscriptions" outline, one folder deep.
const INOREADER = `<?xml version="1.0" encoding="UTF-8"?><opml version="1.0"><head><title>Subscriptions in Inoreader</title></head><body><outline text="Subscriptions" title="Subscriptions"><outline text="News" title="News"><outline text="BBC" title="BBC" type="rss" xmlUrl="https://feeds.bbci.co.uk/news/rss.xml" htmlUrl="https://www.bbc.co.uk/news"/></outline><outline text="Loose" title="Loose" type="rss" xmlUrl="https://loose.example/rss"/></outline></body></opml>`;
const ino = parse(INOREADER);
assert.deepEqual(
  ino.folders.map((f) => [f.title, f.sources.map((s) => s.title)]),
  [
    ["News", ["BBC"]],
    ["Subscriptions", ["Loose"]],
  ],
);

// Entities and rejection.
assert.equal(decodeEntities("Tom &amp;amp; Jerry &#x2014; &lt;b&gt; &bogus;"), "Tom & Jerry — <b> &bogus;");
assert.throws(() => parse("<rss><channel/></rss>"), /Not an OPML file/);
assert.throws(() => parse("not xml at all"), /Not an OPML file/);
assert.deepEqual(parse(`<opml version="2.0"><body/></opml>`), { folders: [], unfiled: [] });

console.log("opml-check: all assertions passed");
