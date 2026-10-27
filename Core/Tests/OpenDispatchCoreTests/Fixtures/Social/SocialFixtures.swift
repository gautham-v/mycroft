// Social post samples: shapes of the responses and pages read on 2026-10-27, trimmed (Bluesky and Mastodon JSON,
// LinkedIn's public post page, Threads and Instagram preview tags and embeds). Not fetched at test time.

enum SocialFixtures {
    /// getPostThread: text with a link facet (after an emoji, so the facet's byte range is not its character range),
    /// an external link card.
    static let blueskyCard = ##"""
    {"thread":{"$type":"app.bsky.feed.defs#threadViewPost","post":{
      "uri":"at://did:plc:kft6lu4trxowqmter2b6vg6z/app.bsky.feed.post/3mykwxawoa22u",
      "author":{"did":"did:plc:kft6lu4trxowqmter2b6vg6z","handle":"simonwillison.net","displayName":"Simon Willison","avatar":"https://cdn.bsky.app/img/avatar/plain/did:plc:kft6lu4trxowqmter2b6vg6z/a"},
      "record":{"$type":"app.bsky.feed.post","createdAt":"2026-10-23T19:45:54.167Z",
        "text":"é✨ Notes on Kimi K3.1 - a big deal\n\nsimonwillison.net/2026/Oct/23/... #llms @bsky.app",
        "facets":[
          {"index":{"byteStart":39,"byteEnd":72},"features":[{"$type":"app.bsky.richtext.facet#link","uri":"https://simonwillison.net/2026/Oct/23/kimi-k31-pro/"}]},
          {"index":{"byteStart":73,"byteEnd":78},"features":[{"$type":"app.bsky.richtext.facet#tag","tag":"llms"}]},
          {"index":{"byteStart":79,"byteEnd":88},"features":[{"$type":"app.bsky.richtext.facet#mention","did":"did:plc:z72i7hdynmk6r22z27h6tvur"}]}]},
      "embed":{"$type":"app.bsky.embed.external#view","external":{"uri":"https://simonwillison.net/2026/Oct/23/kimi-k31-pro/","title":"Introducing Kimi K3.1 Pro","description":"Kimi K3.1 Pro landed","thumb":"https://cdn.bsky.app/img/feed_thumbnail/plain/did:plc:kft6lu4trxowqmter2b6vg6z/b"}}}}}
    """##

    /// Two photos, with alt text on one.
    static let blueskyImages = ##"""
    {"thread":{"post":{"uri":"at://did:plc:t2dnigzpoovty4qcxzgv73fu/app.bsky.feed.post/3myqf3elq7s2m",
      "author":{"did":"did:plc:t2dnigzpoovty4qcxzgv73fu","handle":"jane.example.com","displayName":""},
      "record":{"createdAt":"2026-10-22T10:00:00.000Z","text":""},
      "embed":{"$type":"app.bsky.embed.images#view","images":[
        {"thumb":"https://cdn.bsky.app/t1","fullsize":"https://cdn.bsky.app/f1","alt":"A tennis court","aspectRatio":{"width":423,"height":500}},
        {"thumb":"https://cdn.bsky.app/t2","fullsize":"https://cdn.bsky.app/f2","alt":""}]}}}}
    """##

    static let blueskyVideo = ##"""
    {"thread":{"post":{"uri":"at://did:plc:2jspkem5l66pgvdhkcibmh3d/app.bsky.feed.post/3mykmsu7tnc23",
      "author":{"did":"did:plc:2jspkem5l66pgvdhkcibmh3d","handle":"zoo.example.com","displayName":"Zoo"},
      "record":{"createdAt":"2026-10-23T16:44:29.000Z","text":"punkin dunkin"},
      "embed":{"$type":"app.bsky.embed.video#view","playlist":"https://video.bsky.app/watch/did/cid/playlist.m3u8","thumbnail":"https://video.bsky.app/watch/did/cid/thumbnail.jpg","aspectRatio":{"width":1080,"height":1920}}}}}
    """##

    /// A quote post with its own photo; the quoted post carries an image. (`recordWithMedia`.)
    static let blueskyQuoteWithMedia = ##"""
    {"thread":{"post":{"uri":"at://did:plc:j54ofwzkxbeyjs6m2jwvwuro/app.bsky.feed.post/3mxkb3qz4cs27",
      "author":{"did":"did:plc:j54ofwzkxbeyjs6m2jwvwuro","handle":"maud.example.com","displayName":"maud"},
      "record":{"createdAt":"2026-10-10T19:49:31.000Z","text":"posting the photo"},
      "embed":{"$type":"app.bsky.embed.recordWithMedia#view",
        "media":{"$type":"app.bsky.embed.images#view","images":[{"thumb":"https://cdn.bsky.app/m-t","fullsize":"https://cdn.bsky.app/m-f","alt":""}]},
        "record":{"$type":"app.bsky.embed.record#view","record":{"$type":"app.bsky.embed.record#viewRecord",
          "uri":"at://did:plc:5dha4eux2jvil7raud3rlbed/app.bsky.feed.post/3mxk4ubvur22l",
          "author":{"did":"did:plc:5dha4eux2jvil7raud3rlbed","handle":"rob.example.com","displayName":"rob","avatar":"https://cdn.bsky.app/avatar/rob"},
          "value":{"$type":"app.bsky.feed.post","createdAt":"2026-10-10T18:33:45.612Z","text":"Probably the coolest thing"},
          "embeds":[{"$type":"app.bsky.embed.images#view","images":[{"thumb":"https://cdn.bsky.app/q-t","fullsize":"https://cdn.bsky.app/q-f","alt":""}]}]}}}}}}
    """##

    /// A quoted post that is gone.
    static let blueskyQuoteGone = ##"""
    {"thread":{"post":{"uri":"at://did:plc:aaa/app.bsky.feed.post/3x","author":{"handle":"a.example.com","displayName":"A"},
      "record":{"createdAt":"2026-10-10T19:49:31.000Z","text":"look at this"},
      "embed":{"$type":"app.bsky.embed.record#view","record":{"$type":"app.bsky.embed.record#viewNotFound","uri":"at://did:plc:b/app.bsky.feed.post/3y","notFound":true}}}}}
    """##

    static let blueskyNotFound = ##"{"error":"NotFound","message":"Post not found"}"##

    /// A status with three photos (alt text), a link with hidden and cut parts, and an account on the local server.
    static let mastodonPhotos = ##"""
    {"id":"117502470959656060","created_at":"2026-10-25T16:23:38.704Z","spoiler_text":"","url":"https://mastodon.social/@Gargron/117502470959656060",
     "content":"<p>Okay, I&#39;m new to this, but I&#39;ve put prints up on a little shop.</p><p><a href=\"https://www.createdrops.com/autumn-collection-2026-2\" target=\"_blank\" rel=\"nofollow noopener\" translate=\"no\"><span class=\"invisible\">https://www.</span><span class=\"ellipsis\">createdrops.com/autumn-collect</span><span class=\"invisible\">ion-2026-2</span></a></p>",
     "account":{"id":"1","username":"Gargron","acct":"Gargron","display_name":"Eugen Rochko","url":"https://mastodon.social/@Gargron","avatar":"https://files.mastodon.social/a.png","avatar_static":"https://files.mastodon.social/a.png"},
     "media_attachments":[
       {"id":"1","type":"image","url":"https://files.mastodon.social/o1.jpg","preview_url":"https://files.mastodon.social/s1.jpg","description":"A narrow street","meta":{"original":{"width":2345,"height":3536}}},
       {"id":"2","type":"image","url":"https://files.mastodon.social/o2.jpg","preview_url":"https://files.mastodon.social/s2.jpg","description":null,"meta":{"original":{"width":2345,"height":3536}}}],
     "emojis":[],"card":null,"quote":null}
    """##

    /// A remote account, a content warning, a custom emoji in the text and in the name, a video, a link card.
    static let mastodonRemote = ##"""
    {"id":"9","created_at":"2026-10-27T10:00:00.000Z","spoiler_text":"Long thread ahead","url":"https://fosstodon.org/@kim@functional.cafe/9",
     "content":"<p>In case anyone needs it :blobcat:, a waterfall.</p><p><a href=\"https://functional.cafe/tags/nature\" class=\"mention hashtag\" rel=\"tag\">#<span>nature</span></a></p>",
     "emojis":[{"shortcode":"blobcat","url":"https://cdn.example/blobcat.png","static_url":"https://cdn.example/blobcat-static.png"}],
     "account":{"id":"2","username":"kim","acct":"kim@functional.cafe","display_name":"Kim :verified:","url":"https://functional.cafe/@kim","avatar":"https://cdn.example/kim.png","avatar_static":"https://cdn.example/kim-static.png"},
     "media_attachments":[{"id":"3","type":"video","url":"https://cdn.example/v.mp4","preview_url":"https://cdn.example/v.png","description":"A waterfall","meta":{"original":{"width":1080,"height":1920}}},
                          {"id":"4","type":"gifv","url":"https://cdn.example/g.mp4","preview_url":"https://cdn.example/g.png","meta":{}},
                          {"id":"5","type":"audio","url":"https://cdn.example/a.mp3","preview_url":null,"meta":{}}],
     "card":{"url":"https://example.com/article","title":"An article","provider_name":"Example","image":"https://cdn.example/card.jpg"}}
    """##

    /// A post that quotes another (accepted), starting with the "RE:" line servers add for clients without quotes.
    static let mastodonQuote = ##"""
    {"id":"117512460970936517","created_at":"2026-10-27T10:44:14.000Z","spoiler_text":"","url":"https://mastodon.social/@rec/117512461000110123",
     "content":"<p class=\"quote-inline\">RE: <a href=\"https://mastodon.social/@sauv/117512455371012662\"><span class=\"invisible\">https://</span><span class=\"ellipsis\">mastodon.social/@sauv/</span><span class=\"invisible\">117512455371012662</span></a></p><p>It is all on <span class=\"h-card\"><a href=\"https://hcxp.co/@IDIOTEQ\" class=\"u-url mention\">@<span>IDIOTEQ</span></a></span> <br>Find the link below</p>",
     "account":{"username":"rec","acct":"rec","display_name":"Records","url":"https://mastodon.social/@rec","avatar":"https://cdn.example/rec.png"},
     "media_attachments":[],"emojis":[],"card":null,
     "quote":{"state":"accepted","quoted_status":{"id":"117512455379252132","created_at":"2026-10-27T10:42:48.000Z","url":"https://mastodon.social/@sauv/117512455371012662",
       "content":"<p>NEW ALBUM, film premiere today</p>","emojis":[],
       "account":{"username":"sauv","acct":"sauv","display_name":"Sauv","url":"https://mastodon.social/@sauv","avatar":"https://cdn.example/sauv.png"},
       "media_attachments":[{"id":"7","type":"image","url":"https://cdn.example/q.jpg","preview_url":"https://cdn.example/q-s.jpg","meta":{}}]}}}
    """##

    /// A quote the quoted author hasn't approved: the "RE:" line stays.
    static let mastodonQuotePending = ##"""
    {"id":"5","created_at":"2026-10-27T10:44:14.000Z","url":"https://mastodon.social/@a/5","content":"<p class=\"quote-inline\">RE: https://example.com</p><p>Hi</p>",
     "account":{"username":"a","acct":"a","display_name":"A","url":"https://mastodon.social/@a","avatar":"x"},"media_attachments":[],"quote":{"state":"pending"}}
    """##

    /// LinkedIn's public post page, trimmed to what the parser reads: the author lockup (a ghost avatar), the
    /// commentary with a wrapped link and a hashtag, a video, the JSON-LD (its comments carry dates of their own)
    /// and, in the comments, an image that isn't the post's.
    static let linkedinVideoPost = ##"""
    <html><head><title>My Firefox browser agent is now 1.7x faster | Gautham Vemulapalli</title>
    <meta property="og:description" content="My Firefox browser agent is now 1.7x faster than Claude in Chrome.">
    <meta property="og:image" content="https://dms.licdn.com/playlist/vid/v2/D5605AQFEW6gE-qg5jg/thumbnail-with-play-button-overlay-high/B56a/0/1?e=2147483647&amp;v=beta&amp;t=x">
    <script type="application/ld+json">{"@context":"http://schema.org","@type":"VideoObject","datePublished":"2026-09-30T19:36:01.901Z","comment":[{"@type":"Comment","datePublished":"2026-10-01T03:00:31.868Z","text":"Nice","creator":{"@type":"Person","name":"Laurent Chevrette"}}],"contentUrl":"https://dms.licdn.com/playlist/vid/v2/x/mp4-720p/B56a/0/1","creator":{"name":"Gautham Vemulapalli","url":"https://www.linkedin.com/in/gautham-v","@type":"Person"}}</script>
    </head><body>
    <div class="share-native-video" data-test-id="feed-native-video-content"><video muted class="share-native-video__node video-js" data-sources="[{&quot;src&quot;:&quot;https://dms.licdn.com/playlist/vid/v2/x/mp4-720p/B56a/0/1?e=2147483647&amp;v=beta&amp;t=hi&quot;,&quot;type&quot;:&quot;video/mp4&quot;,&quot;data-bitrate&quot;:386598},{&quot;src&quot;:&quot;https://dms.licdn.com/playlist/vid/v2/x/mp4-640p/B56a/0/1?e=2147483647&amp;v=beta&amp;t=lo&quot;,&quot;type&quot;:&quot;video/mp4&quot;,&quot;data-bitrate&quot;:303458}]" data-poster-url="https://media.licdn.com/dms/image/v2/D5605AQFEW6gE-qg5jg/videocover-high/B56a/0/1?e=2147483647&amp;v=beta&amp;t=p" data-aspect-ratio="1.7777778" playsinline></video></div>
    <div class="base-main-feed-card__entity-lockup"><div class="flex items-center font-sans mb-1" data-test-id="main-feed-activity-card__entity-lockup">
      <a href="https://www.linkedin.com/in/gautham-v?trk=public_post_feed-actor-image"><img class="inline-block" data-delayed-url="https://static.licdn.com/aero-v1/sc/h/9c8pery4andzj6ohjkjp54ma2" data-ghost-url="https://static.licdn.com/aero-v1/sc/h/9c8pery4andzj6ohjkjp54ma2" alt="View profile for Gautham Vemulapalli"></a>
      <div><a class="text-sm link-styled" href="https://www.linkedin.com/in/gautham-v?trk=public_post_feed-actor-name" data-tracking-control-name="public_post_feed-actor-name" aria-label="View profile for Gautham Vemulapalli">
              Gautham Vemulapalli
            </a></div><span><time class="flex-none">3w</time></span></div></div>
    <div class="attributed-text-segment-list__container"><p class="attributed-text-segment-list__content whitespace-pre-wrap" dir="ltr" data-test-id="main-feed-activity-card__commentary">My Firefox browser agent is now 1.7x faster than Claude in Chrome.

    It runs 16 tasks &amp; 3 runs each:
    - 14.9s vs 25.5s per task
    - Less than half the input tokens

    I wrote up how: <a class="link" href="https://www.linkedin.com/redir/redirect?url=https%3A%2F%2Flnkd%2Ein%2FgB2qS63B&amp;urlhash=1eRL&amp;trk=public_post-text" target="_self" rel="nofollow" data-tracking-control-name="public_post-text">https://lnkd.in/gB2qS63B</a>

    Source: <a class="link" href="https://www.linkedin.com/redir/redirect?url=https%3A%2F%2Fgithub.com%2Fgautham-v%2Fagent-bridge&amp;urlhash=abcd&amp;trk=public_post-text">https://github.com/gautham-v/agent-bridge</a> <a href="https://www.linkedin.com/signup/cold-join?session_redirect=x&amp;trk=public_post-text-hashtag" data-tracking-control-name="public_post-text">#firefox</a> <a href="https://www.linkedin.com/in/someone-else?trk=public_post-text">Someone Else</a></p></div>
    <div data-test-id="comment__images-content"><img class="lazy-load" data-delayed-url="https://media.licdn.com/dms/image/v2/D562CAQEg0/comment-image-shrink_8192_480/B56a/0/1" alt="No alternative text description for this image"></div>
    </body></html>
    """##

    /// A post with two photos and no video: the structure here is assumed (the photo list's `feed-images-content`
    /// markup was not seen on a live page), and the author's picture is a real one.
    static let linkedinPhotosPost = ##"""
    <html><head><meta property="og:image" content="https://media.licdn.com/dms/image/v2/photo1/feedshare-shrink_800/0/1?e=1"></head><body>
    <div data-test-id="main-feed-activity-card__entity-lockup"><a href="https://www.linkedin.com/company/acme?trk=public_post_feed-actor-image"><img data-delayed-url="https://media.licdn.com/dms/image/v2/logo/company-logo_100_100/0/1" alt=""></a>
      <a href="https://www.linkedin.com/company/acme?trk=public_post_feed-actor-name" data-tracking-control-name="public_post_feed-actor-name">Acme Inc</a></div>
    <p data-test-id="main-feed-activity-card__commentary">We shipped.</p>
    <ul data-test-id="feed-images-content"><li><img data-delayed-url="https://media.licdn.com/dms/image/v2/photo1/feedshare-shrink_800/0/1?e=1" alt="Image"></li><li><img data-delayed-url="https://media.licdn.com/dms/image/v2/photo2/feedshare-shrink_800/0/1?e=1" alt="The team"></li></ul>
    </body></html>
    """##

    /// The login wall a post page shows when LinkedIn withholds it.
    static let linkedinWall = ##"<html><head><title>Sign Up | LinkedIn</title></head><body><form class="join-form"></form></body></html>"##

    /// Threads post page as a link-preview crawler gets it.
    static let threadsPreview = ##"""
    <html><head><meta property="og:site_name" content="Threads" /><meta property="og:title" content="Mark Zuckerberg (&#064;zuck) on Threads" />
    <meta property="og:description" content="09/17 = &#x1f44c;&#x270d;&#xfe0f;" /><meta property="og:url" content="https://www.threads.com/&#064;zuck/post/DOrreKBEtvX" />
    <meta property="og:image" content="https://scontent-sea5-1.xx.fbcdn.net/v/t39.92108-6/862860792_n.jpg?_nc_cat=108&amp;ccb=1-7" /></head><body></body></html>
    """##

    /// What a browser gets from Threads.
    static let threadsWall = ##"""
    <html><head><title>Threads</title><meta property="og:title" content="Threads &#x2022; Log in" /><meta property="og:description" content="Join Threads to share ideas." /></head><body></body></html>
    """##

    static let threadsEmbed = ##"""
    <html><body><div class="Embed"><div class="AvatarContainer"><img class="img" src="https://scontent-sea5-1.cdninstagram.com/v/t51.82787-19/825322135_n.jpg?stp=dst-jpg_s100x100_tt6&amp;_nc_cat=107" alt="zuck" height="36" width="36" /></div>
    <span class="BodyTextContainer"><span>09/17 = </span></span><div class="PostDateContainer"><span class="Timestamp">5:01 PM · Sep 16, 2025</span></div></div></body></html>
    """##

    static let instagramPreview = ##"""
    <html><head><meta name="twitter:title" content="NASA (&#064;nasa) &#x2022; Instagram photo" />
    <meta name="description" content="272K likes, 771 comments - nasa on May 26, 2025: &quot;On #MemorialDay, we remember and honor those who gave the last full measure of devotion.

    Ad astra per aspera.

    #NASA #Space&quot;." />
    <meta property="og:title" content="NASA on Instagram: &quot;On #MemorialDay, we remember..." />
    <meta property="og:description" content="272K likes, 771 comments - nasa on May 26, 2025: &quot;On #MemorialDay, we remember and honor those who gave the last full measure of devotion.

    Ad astra per aspera.

    #NASA #Space&quot;." />
    <meta property="og:image" content="https://scontent-sea5-1.cdninstagram.com/v/t51.75761-15/5012_n.jpg?stp=c191.0.575.574a_dst-jpg_e35_s640x640_tt6&amp;_nc_cat=103" /></head><body></body></html>
    """##

    static let instagramEmbed = ##"""
    <html><body><div class="Embed"><div class="Header"><div class="AvatarContainer"><a class="Avatar InsideRing" href="https://www.instagram.com/stories/nasa/"><img src="https://scontent-sea5-1.cdninstagram.com/v/t51.2885-19/29090066_n.jpg?stp=dst-jpg_s100x100_tt6" alt="nasa" /></a></div></div></div></body></html>
    """##

    /// The login wall Instagram serves to browsers (no preview tags at all).
    static let instagramWall = ##"<html><head><title>Instagram</title></head><body></body></html>"##
}
