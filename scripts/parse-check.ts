import { parseFeedXml } from "../src/lib/parse";
import { extractFromHtml } from "../src/lib/extract";
import { findAlternateFeeds, findChannelIdInHtml } from "../src/lib/feed-detect";
import { relativeTime } from "../src/lib/time";

const HN = `<?xml version="1.0" encoding="UTF-8"?><rss version="2.0" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:atom="http://www.w3.org/2005/Atom"><channel><title>Hacker News: Newest</title><link>https://news.ycombinator.com/newest</link>
<item><title>Show HN: A tiny thing</title><description><![CDATA[
<p>Article URL: <a href="https://example.com/post">https://example.com/post</a></p>
<p>Comments URL: <a href="https://news.ycombinator.com/item?id=4242">https://news.ycombinator.com/item?id=4242</a></p>
<p>Points: 187</p>
<p># Comments: 64</p>
]]></description><pubDate>Fri, 23 Oct 2026 18:01:02 +0000</pubDate><link>https://example.com/post</link><dc:creator>pg</dc:creator><comments>https://news.ycombinator.com/item?id=4242</comments><guid isPermaLink="false">https://news.ycombinator.com/item?id=4242</guid></item>
</channel></rss>`;

const YT = `<?xml version="1.0" encoding="UTF-8"?><feed xmlns:yt="http://www.youtube.com/xml/schemas/2015" xmlns:media="http://search.yahoo.com/mrss/" xmlns="http://www.w3.org/2005/Atom">
<title>Fireship</title><link rel="alternate" href="https://www.youtube.com/channel/UCsBjURrPoezykLs9EqgamOA"/>
<entry><id>yt:video:dQw4w9WgXcQ</id><yt:videoId>dQw4w9WgXcQ</yt:videoId><yt:channelId>UCsBjURrPoezykLs9EqgamOA</yt:channelId><title>Rust in 100 seconds</title><link rel="alternate" href="https://www.youtube.com/watch?v=dQw4w9WgXcQ"/><author><name>Fireship</name></author><published>2026-10-22T14:00:00+00:00</published><updated>2026-10-22T15:00:00+00:00</updated>
<media:group><media:title>Rust in 100 seconds</media:title><media:content url="https://www.youtube.com/v/dQw4w9WgXcQ?version=3" type="application/x-shockwave-flash" width="640" height="390"/><media:thumbnail url="https://i2.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg" width="480" height="360"/><media:description>Learn Rust fast. Links &amp; more below.</media:description></media:group></entry></feed>`;

const BLOG = `<?xml version="1.0"?><rss version="2.0" xmlns:media="http://search.yahoo.com/mrss/" xmlns:content="http://purl.org/rss/1.0/modules/content/"><channel><title>Blog</title><link>https://blog.example.com/</link>
<item><title>Hello</title><link>/posts/hello</link><guid>abc</guid><pubDate>Thu, 22 Oct 2026 10:00:00 GMT</pubDate><description>Short &lt;b&gt;desc&lt;/b&gt;</description><content:encoded><![CDATA[<p>Body <img src="/img/a.png"></p>]]></content:encoded></item>
<item><title>With media</title><link>https://blog.example.com/m</link><media:content url="https://cdn.example.com/x.jpg" medium="image"/></item>
</channel></rss>`;

const ARTICLE = `<html><head><meta property="og:image" content="/og.png"><title>T</title></head><body><nav>menu</nav><article><h1>Title</h1>
${"<p>This is a long paragraph of meaningful article text that Readability should keep, with a <a href=\"/rel/link\">relative link</a>. </p>".repeat(8)}
<img src="pics/one.jpg" alt="x"><script>alert(1)</script><iframe src="https://evil.com/x"></iframe><iframe src="https://www.youtube-nocookie.com/embed/abc"></iframe></article></body></html>`;

async function main() {
  const hn = await parseFeedXml(HN, "rss", "https://hnrss.org/newest?points=100");
  console.log("HN:", hn.items[0]);
  const yt = await parseFeedXml(YT, "youtube", "https://www.youtube.com/feeds/videos.xml?channel_id=UCsBjURrPoezykLs9EqgamOA");
  console.log("YT:", yt.title, yt.items[0]);
  const blog = await parseFeedXml(BLOG, "rss", "https://blog.example.com/feed");
  console.log("BLOG:", blog.items);
  const ex = extractFromHtml(ARTICLE, "https://site.example.com/a/b.html");
  console.log("EXTRACT lead:", ex.leadImage);
  console.log("EXTRACT html:", ex.contentHtml?.slice(0, 300), "...", ex.contentHtml?.slice(-400));
  console.log("ALT:", findAlternateFeeds('<link rel="alternate" type="application/rss+xml" href="/feed.xml">', "https://x.com/blog"));
  console.log("CHAN:", findChannelIdInHtml('foo "channelId":"UCsBjURrPoezykLs9EqgamOA" bar'));
  console.log("TIME:", relativeTime(Date.now() - 23 * 60e3), relativeTime(Date.now() - 3 * 3600e3), relativeTime(Date.now() - 2 * 86400e3));
}
main();
