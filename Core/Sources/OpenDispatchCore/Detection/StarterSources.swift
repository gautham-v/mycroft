import Foundation

/// A well-known source to start from, offered by the empty "Add sources" sheet and the first-run board. A suggestion only: nothing is
/// added until it is chosen, and it goes through the detector like a search result.
public struct StarterSource: Sendable, Hashable, Identifiable {
    public var title: String
    /// The site, for its favicon.
    public var host: String
    public var feedUrl: String
    public var place: SourcePlace
    /// A row's second line: the site, "YouTube", "Podcast · Publisher", "X · @handle".
    public var detail: String
    /// A channel's avatar or a show's artwork; others use the site's favicon.
    public var imageUrl: String?

    public var id: String { feedUrl }

    public init(title: String, host: String, feedUrl: String, place: SourcePlace = .site, detail: String? = nil, imageUrl: String? = nil) {
        self.title = title
        self.host = host
        self.feedUrl = feedUrl
        self.place = place
        self.detail = detail ?? host
        self.imageUrl = imageUrl
    }
}

public struct StarterPack: Sendable, Hashable, Identifiable {
    public var name: String
    public var sources: [StarterSource]

    public var id: String { name }

    public init(name: String, sources: [StarterSource]) {
        self.name = name
        self.sources = sources
    }
}

/// The feeds were read and found recently updated when this list was made (October 2026). Reddit limits requests by address, so its
/// communities couldn't all be read at once, but they are long-standing ones.
public enum StarterSources {
    /// The categories that are a kind of source rather than a subject, which come last.
    public static let formats: Set<String> = ["YouTube", "Podcasts", "Newsletters", "Reddit", "X", "Bluesky"]

    /// The few packs the first-run board offers, each a handful: adding a whole category there would be a lot to start with.
    public static let boardPacks: [StarterPack] = ["News", "Tech", "AI", "Sports"].compactMap { name in
        packs.first { $0.name == name }.map { StarterPack(name: $0.name, sources: Array($0.sources.prefix(3))) }
    }

    private static func site(_ title: String, _ host: String, _ feedUrl: String) -> StarterSource {
        StarterSource(title: title, host: host, feedUrl: feedUrl)
    }

    private static func channel(_ title: String, _ id: String, _ avatar: String) -> StarterSource {
        StarterSource(title: title, host: "youtube.com", feedUrl: FeedDetection.youtubeFeedURL(channelID: id), place: .youtube, detail: "YouTube", imageUrl: avatar)
    }

    private static func show(_ title: String, _ publisher: String, _ feedUrl: String, _ artwork: String) -> StarterSource {
        StarterSource(title: title, host: "", feedUrl: feedUrl, place: .podcast, detail: "Podcast · \(publisher)", imageUrl: artwork)
    }

    private static func community(_ name: String) -> StarterSource {
        StarterSource(title: "r/\(name)", host: "reddit.com", feedUrl: "\(RedditPages.origin)/r/\(name)/.rss", place: .reddit, detail: "Reddit")
    }

    private static func xAccount(_ name: String, _ handle: String) -> StarterSource {
        StarterSource(title: name, host: "x.com", feedUrl: "\(XPages.origin)/\(handle)", place: .x, detail: "X · @\(handle)")
    }

    private static func bluesky(_ name: String, _ handle: String, _ did: String) -> StarterSource {
        StarterSource(title: name, host: "bsky.app", feedUrl: "https://bsky.app/profile/\(did)/rss", place: .bluesky, detail: "Bluesky · @\(handle)")
    }

    public static let packs: [StarterPack] = [
        StarterPack(name: "News", sources: [
            site("NPR", "npr.org", "https://feeds.npr.org/1001/rss.xml"),
            site("BBC News", "bbc.co.uk", "https://feeds.bbci.co.uk/news/rss.xml"),
            site("The Guardian", "theguardian.com", "https://www.theguardian.com/world/rss"),
            site("PBS News", "pbs.org", "https://www.pbs.org/newshour/feeds/rss/headlines"),
            site("CBS News", "cbsnews.com", "https://www.cbsnews.com/latest/rss/main"),
            site("ABC News", "abcnews.com", "https://abcnews.go.com/abcnews/topstories"),
            site("NBC News", "nbcnews.com", "https://feeds.nbcnews.com/nbcnews/public/news"),
            site("Axios", "axios.com", "https://api.axios.com/feed/"),
            site("Semafor", "semafor.com", "https://www.semafor.com/rss.xml"),
            site("Vox", "vox.com", "https://www.vox.com/rss/index.xml"),
            site("ProPublica", "propublica.org", "https://www.propublica.org/feeds/propublica/main"),
        ]),
        StarterPack(name: "Tech", sources: [
            site("The Verge", "theverge.com", "https://www.theverge.com/rss/index.xml"),
            site("Ars Technica", "arstechnica.com", "https://feeds.arstechnica.com/arstechnica/index"),
            site("Hacker News", "news.ycombinator.com", "https://hnrss.org/newest?points=100"),
            site("TechCrunch", "techcrunch.com", "https://techcrunch.com/feed/"),
            site("Engadget", "engadget.com", "https://www.engadget.com/rss.xml"),
            site("The Register", "theregister.com", "https://www.theregister.com/headlines.atom"),
            site("Techmeme", "techmeme.com", "https://www.techmeme.com/feed.xml"),
            site("Slashdot", "slashdot.org", "https://rss.slashdot.org/Slashdot/slashdotMain"),
            site("Rest of World", "restofworld.org", "https://restofworld.org/feed/latest"),
        ]),
        StarterPack(name: "AI", sources: [
            site("Simon Willison", "simonwillison.net", "https://simonwillison.net/atom/everything/"),
            site("OpenAI News", "openai.com", "https://openai.com/news/rss.xml"),
            site("Google DeepMind Blog", "deepmind.google", "https://deepmind.google/blog/rss.xml"),
            site("Hugging Face", "huggingface.co", "https://huggingface.co/blog/feed.xml"),
            site("Import AI", "importai.substack.com", "https://importai.substack.com/feed"),
            site("Latent Space", "latent.space", "https://www.latent.space/feed"),
            site("Interconnects", "interconnects.ai", "https://www.interconnects.ai/feed"),
            site("One Useful Thing", "oneusefulthing.org", "https://www.oneusefulthing.org/feed"),
            site("Ahead of AI", "magazine.sebastianraschka.com", "https://magazine.sebastianraschka.com/feed"),
            site("Lil'Log", "lilianweng.github.io", "https://lilianweng.github.io/index.xml"),
            site("TechCrunch AI", "techcrunch.com", "https://techcrunch.com/category/artificial-intelligence/feed/"),
            site("Ars Technica AI", "arstechnica.com", "https://arstechnica.com/ai/feed/"),
            site("The Verge AI", "theverge.com", "https://www.theverge.com/rss/ai-artificial-intelligence/index.xml"),
            community("MachineLearning"),
        ]),
        StarterPack(name: "Sports", sources: [
            site("ESPN", "espn.com", "https://www.espn.com/espn/rss/news"),
            site("CBS Sports", "cbssports.com                ", "https://www.cbssports.com/rss/headlines/"),
            site("BBC Sport", "bbc.co.uk", "https://feeds.bbci.co.uk/sport/rss.xml"),
            site("Yahoo Sports", "sports.yahoo.com", "https://sports.yahoo.com/rss/"),
            site("The Guardian Sport", "theguardian.com", "https://www.theguardian.com/uk/sport/rss"),
            site("SB Nation", "sbnation.com", "https://www.sbnation.com/rss/index.xml"),
            site("Sporting News", "sportingnews.com", "https://www.sportingnews.com/us/rss"),
            community("sports"),
        ]),
        StarterPack(name: "NFL", sources: [
            site("ESPN NFL", "espn.com", "https://www.espn.com/espn/rss/nfl/news"),
            site("CBS Sports NFL", "cbssports.com                ", "https://www.cbssports.com/rss/headlines/nfl/"),
            site("Pro Football Talk", "nbcsports.com", "https://profootballtalk.nbcsports.com/feed/"),
            site("Yahoo Sports NFL", "sports.yahoo.com", "https://sports.yahoo.com/nfl/rss/"),
            site("NFLTradeRumors", "nfltraderumors.co", "https://nfltraderumors.co/feed/"),
            community("nfl"),
        ]),
        StarterPack(name: "NBA", sources: [
            site("ESPN NBA", "espn.com", "https://www.espn.com/espn/rss/nba/news"),
            site("CBS Sports NBA", "cbssports.com                ", "https://www.cbssports.com/rss/headlines/nba/"),
            site("Yahoo Sports NBA", "sports.yahoo.com", "https://sports.yahoo.com/nba/rss/"),
            site("Hoops Rumors", "hoopsrumors.com", "https://www.hoopsrumors.com/feed"),
            community("nba"),
        ]),
        StarterPack(name: "Soccer", sources: [
            site("BBC Football", "bbc.co.uk", "https://feeds.bbci.co.uk/sport/football/rss.xml"),
            site("The Guardian Football", "theguardian.com", "https://www.theguardian.com/football/rss"),
            site("ESPN Soccer", "espn.com", "https://www.espn.com/espn/rss/soccer/news"),
            site("CBS Sports Soccer", "cbssports.com                ", "https://www.cbssports.com/rss/headlines/soccer/"),
            community("soccer"),
        ]),
        StarterPack(name: "Baseball", sources: [
            site("ESPN MLB", "espn.com", "https://www.espn.com/espn/rss/mlb/news"),
            site("CBS Sports MLB", "cbssports.com                ", "https://www.cbssports.com/rss/headlines/mlb/"),
            site("MLB Trade Rumors", "mlbtraderumors.com", "https://www.mlbtraderumors.com/feed"),
            site("FanGraphs", "blogs.fangraphs.com", "https://blogs.fangraphs.com/feed/"),
            site("Pitcher List", "pitcherlist.com", "https://pitcherlist.com/feed/"),
            site("Yahoo Sports MLB", "sports.yahoo.com", "https://sports.yahoo.com/mlb/rss/"),
            community("baseball"),
        ]),
        StarterPack(name: "Business", sources: [
            site("CNBC", "cnbc.com", "https://www.cnbc.com/id/100003114/device/rss/rss.html"),
            site("Marginal Revolution", "marginalrevolution.com", "https://marginalrevolution.com/feed"),
            site("Quartz", "qz.com", "https://qz.com/rss"),
            site("Retail Dive", "retaildive.com", "https://www.retaildive.com/feeds/news/"),
        ]),
        StarterPack(name: "Science", sources: [
            site("Quanta Magazine", "quantamagazine.org", "https://www.quantamagazine.org/feed/"),
            site("ScienceDaily", "sciencedaily.com", "https://www.sciencedaily.com/rss/all.xml"),
            site("Ars Technica Science", "arstechnica.com", "https://arstechnica.com/science/feed/"),
            site("Phys.org", "phys.org", "https://phys.org/rss-feed/"),
            site("Live Science", "livescience.com", "https://www.livescience.com/feeds.xml"),
            community("science"),
        ]),
        StarterPack(name: "Politics", sources: [
            site("The Hill", "thehill.com", "https://thehill.com/feed/"),
            site("NPR Politics", "npr.org", "https://feeds.npr.org/1014/rss.xml"),
            site("The Guardian US Politics", "theguardian.com", "https://www.theguardian.com/us-news/us-politics/rss"),
            site("Reason", "reason.com", "https://reason.com/feed/"),
        ]),
        StarterPack(name: "World", sources: [
            site("BBC World", "bbc.co.uk", "https://feeds.bbci.co.uk/news/world/rss.xml"),
            site("Al Jazeera", "aljazeera.com", "https://www.aljazeera.com/xml/rss/all.xml"),
            site("DW", "dw.com", "https://rss.dw.com/rdf/rss-en-all"),
            site("France 24", "france24.com", "https://www.france24.com/en/rss"),
            site("The Guardian World", "theguardian.com", "https://www.theguardian.com/world/rss"),
            site("Rest of World", "restofworld.org", "https://restofworld.org/feed/latest"),
        ]),
        StarterPack(name: "Culture", sources: [
            site("Longreads", "longreads.com", "https://longreads.com/feed/"),
            site("Aeon", "aeon.co", "https://aeon.co/feed.rss"),
            site("The Marginalian", "themarginalian.org", "https://www.themarginalian.org/feed/"),
            site("Kottke", "kottke.org", "https://feeds.kottke.org/main"),
            site("Open Culture", "openculture.com", "https://www.openculture.com/feed"),
        ]),
        StarterPack(name: "Movies & TV", sources: [
            site("Variety", "variety.com", "https://variety.com/feed/"),
            site("The Hollywood Reporter", "hollywoodreporter.com", "https://www.hollywoodreporter.com/feed/"),
            site("IndieWire", "indiewire.com", "https://www.indiewire.com/feed/"),
            site("/Film", "slashfilm.com", "https://www.slashfilm.com/feed/"),
            site("The A.V. Club", "avclub.com", "https://www.avclub.com/rss"),
            site("RogerEbert.com", "rogerebert.com", "https://www.rogerebert.com/feed"),
            community("movies"),
            community("television"),
        ]),
        StarterPack(name: "Music", sources: [
            site("Stereogum", "stereogum.com", "https://www.stereogum.com/feed/"),
            site("NME", "nme.com", "https://www.nme.com/feed"),
            site("Consequence", "consequence.net", "https://consequence.net/feed/"),
            site("NPR Music", "npr.org", "https://feeds.npr.org/1039/rss.xml"),
            community("Music"),
        ]),
        StarterPack(name: "Gaming", sources: [
            site("Polygon", "polygon.com ", "https://www.polygon.com/rss/index.xml"),
            site("Kotaku", "kotaku.com", "https://kotaku.com/rss"),
            site("IGN", "ign.com", "https://feeds.ign.com/ign/all"),
            site("PC Gamer", "pcgamer.com", "https://www.pcgamer.com/rss/"),
            site("Eurogamer", "eurogamer.net", "https://www.eurogamer.net/feed"),
            site("Rock Paper Shotgun", "rockpapershotgun.com", "https://www.rockpapershotgun.com/feed"),
            site("GameSpot", "gamespot.com", "https://www.gamespot.com/feeds/mashup/"),
            community("Games"),
        ]),
        StarterPack(name: "Books", sources: [
            site("Literary Hub", "lithub.com", "https://lithub.com/feed/"),
            site("Book Riot", "bookriot.com", "https://bookriot.com/feed/"),
            site("The Guardian Books", "theguardian.com", "https://www.theguardian.com/books/rss"),
            site("The Paris Review", "theparisreview.org", "https://www.theparisreview.org/blog/feed/"),
            site("Reactor", "reactormag.com", "https://reactormag.com/feed/"),
            community("books"),
        ]),
        StarterPack(name: "Programming", sources: [
            site("Lobsters", "lobste.rs", "https://lobste.rs/rss"),
            site("GitHub Blog", "github.blog", "https://github.blog/feed/"),
            site("Martin Fowler", "martinfowler.com", "https://martinfowler.com/feed.atom"),
            site("Julia Evans", "jvns.ca", "https://jvns.ca/atom.xml"),
            site("Dan Luu", "danluu.com", "https://danluu.com/atom.xml"),
            site("Cloudflare Blog", "blog.cloudflare.com", "https://blog.cloudflare.com/rss/"),
            site("Swift by Sundell", "swiftbysundell.com", "https://swiftbysundell.com/rss"),
            site("The Go Blog", "go.dev", "https://go.dev/blog/feed.atom"),
            site("Rust Blog", "blog.rust-lang.org", "https://blog.rust-lang.org/feed.xml"),
            site("Swift Forums", "forums.swift.org", "https://forums.swift.org/latest.rss"),
            community("programming"),
        ]),
        StarterPack(name: "Apple", sources: [
            site("Daring Fireball", "daringfireball.net", "https://daringfireball.net/feeds/main"),
            site("MacRumors", "macrumors.com", "https://feeds.macrumors.com/MacRumors-All"),
            site("9to5Mac", "9to5mac.com", "https://9to5mac.com/feed/"),
            site("Six Colors", "sixcolors.com", "https://sixcolors.com/feed/"),
            site("AppleInsider", "appleinsider.com", "https://appleinsider.com/rss/news/"),
            site("MacStories", "macstories.net", "https://www.macstories.net/feed/"),
            site("The Eclectic Light Company", "eclecticlight.co", "https://eclecticlight.co/feed/"),
            community("apple"),
        ]),
        StarterPack(name: "Startups", sources: [
            site("Y Combinator", "ycombinator.com", "https://www.ycombinator.com/blog/rss/"),
            site("TechCrunch Startups", "techcrunch.com", "https://techcrunch.com/category/startups/feed/"),
            site("a16z", "a16z.news", "https://www.a16z.news/feed"),
            site("TechCrunch Venture", "techcrunch.com", "https://techcrunch.com/category/venture/feed/"),
        ]),
        StarterPack(name: "Design", sources: [
            site("Smashing Magazine", "smashingmagazine.com", "https://www.smashingmagazine.com/feed/"),
            site("Nielsen Norman Group", "nngroup.com", "https://www.nngroup.com/feed/rss/"),
            site("Dezeen", "dezeen.com", "https://www.dezeen.com/feed/"),
            site("Creative Bloq", "creativebloq.com", "https://www.creativebloq.com/feeds.xml"),
            site("A List Apart", "alistapart.com", "https://alistapart.com/main/feed/"),
            site("Sidebar", "sidebar.io", "https://sidebar.io/feed.xml"),
            site("Colossal", "thisiscolossal.com", "https://www.thisiscolossal.com/feed/"),
            site("Design Milk", "design-milk.com", "https://design-milk.com/feed/"),
        ]),
        StarterPack(name: "Security", sources: [
            site("Krebs on Security", "krebsonsecurity.com", "https://krebsonsecurity.com/feed/"),
            site("Schneier on Security", "schneier.com", "https://www.schneier.com/feed/atom/"),
            site("BleepingComputer", "bleepingcomputer.com", "https://www.bleepingcomputer.com/feed/"),
            site("The Hacker News", "thehackernews.com", "https://feeds.feedburner.com/TheHackersNews"),
            site("Dark Reading", "darkreading.com", "https://www.darkreading.com/rss.xml"),
            site("Troy Hunt", "troyhunt.com", "https://www.troyhunt.com/rss/"),
            community("netsec"),
        ]),
        StarterPack(name: "Health", sources: [
            site("KFF Health News", "kffhealthnews.org", "https://kffhealthnews.org/feed/"),
            site("NPR Health", "npr.org", "https://feeds.npr.org/1128/rss.xml"),
            site("The Guardian Health", "theguardian.com", "https://www.theguardian.com/society/health/rss"),
            site("Medical Xpress", "medicalxpress.com", "https://medicalxpress.com/rss-feed/"),
        ]),
        StarterPack(name: "Money", sources: [
            site("A Wealth of Common Sense", "awealthofcommonsense.com", "https://awealthofcommonsense.com/feed/"),
            site("Mr. Money Mustache", "mrmoneymustache.com", "https://www.mrmoneymustache.com/feed/"),
            site("Kiplinger", "kiplinger.com", "https://www.kiplinger.com/feed/all"),
            site("The Points Guy", "thepointsguy.com", "https://thepointsguy.com/feed/"),
            site("Of Dollars And Data", "ofdollarsanddata.com", "https://ofdollarsanddata.com/feed/"),
            site("NerdWallet", "nerdwallet.com", "https://www.nerdwallet.com/blog/feed/"),
            community("personalfinance"),
        ]),
        StarterPack(name: "Climate", sources: [
            site("Carbon Brief", "carbonbrief.org", "https://www.carbonbrief.org/feed/"),
            site("Grist", "grist.org", "https://grist.org/feed/"),
            site("Inside Climate News", "insideclimatenews.org", "https://insideclimatenews.org/feed/"),
            site("Canary Media", "canarymedia.com", "https://www.canarymedia.com/rss.rss"),
            site("The Guardian Environment", "theguardian.com", "https://www.theguardian.com/environment/rss"),
            site("Electrek", "electrek.co", "https://electrek.co/feed/"),
            site("Clean Technica", "cleantechnica.com", "https://cleantechnica.com/feed/"),
        ]),
        StarterPack(name: "Space", sources: [
            site("NASA", "nasa.gov", "https://www.nasa.gov/feed/"),
            site("Space.com", "space.com", "https://www.space.com/feeds.xml"),
            site("SpaceNews", "spacenews.com", "https://spacenews.com/feed/"),
            site("Universe Today", "universetoday.com", "https://www.universetoday.com/feed"),
            site("The Planetary Society", "planetary.org", "https://www.planetary.org/rss/articles"),
            site("NASASpaceflight", "nasaspaceflight.com", "https://www.nasaspaceflight.com/feed/"),
            site("Space Daily", "spacedaily.com", "https://www.spacedaily.com/spacedaily.xml"),
            community("space"),
        ]),
        StarterPack(name: "Food", sources: [
            site("Smitten Kitchen", "smittenkitchen.com", "https://smittenkitchen.com/feed/"),
            site("Eater", "eater.com", "https://www.eater.com/rss/index.xml"),
            site("Minimalist Baker", "minimalistbaker.com", "https://minimalistbaker.com/feed/"),
            site("Budget Bytes", "budgetbytes.com", "https://www.budgetbytes.com/feed/"),
            community("Cooking"),
        ]),
        StarterPack(name: "Travel", sources: [
            site("Condé Nast Traveler", "cntraveler.com", "https://www.cntraveler.com/feed/rss"),
            site("Atlas Obscura", "atlasobscura.com", "https://www.atlasobscura.com/feeds/latest"),
            site("The Guardian Travel", "theguardian.com", "https://www.theguardian.com/travel/rss"),
            site("Nomadic Matt", "nomadicmatt.com", "https://www.nomadicmatt.com/feed/"),
            site("The Points Guy", "thepointsguy.com", "https://thepointsguy.com/feed/"),
            site("One Mile at a Time", "onemileatatime.com", "https://onemileatatime.com/feed/"),
            community("travel"),
        ]),
        StarterPack(name: "Cars", sources: [
            site("Car and Driver", "caranddriver.com", "https://www.caranddriver.com/rss/all.xml/"),
            site("Jalopnik", "jalopnik.com", "https://www.jalopnik.com/feed/"),
            site("Motor1", "motor1.com", "https://www.motor1.com/rss/news/all/"),
            site("Electrek", "electrek.co", "https://electrek.co/feed/"),
            site("InsideEVs", "insideevs.com", "https://insideevs.com/rss/news/all/"),
            site("The Drive", "thedrive.com", "https://www.thedrive.com/feed"),
            site("Autoblog", "autoblog.com", "https://www.autoblog.com/rss.xml"),
        ]),
        StarterPack(name: "Photography", sources: [
            site("PetaPixel", "petapixel.com", "https://petapixel.com/feed/"),
            site("DPReview", "dpreview.com", "https://www.dpreview.com/feeds/news.xml"),
            site("Fstoppers", "fstoppers.com", "https://fstoppers.com/rss.xml"),
            site("Digital Camera World", "digitalcameraworld.com", "https://www.digitalcameraworld.com/feeds.xml"),
            site("Digital Photography School", "digital-photography-school.com", "https://digital-photography-school.com/feed/"),
            community("photography"),
        ]),
        StarterPack(name: "History", sources: [
            site("Smithsonian Magazine", "smithsonianmag.com", "https://www.smithsonianmag.com/rss/latest_articles/"),
            site("Atlas Obscura", "atlasobscura.com", "https://www.atlasobscura.com/feeds/latest"),
            site("HistoryExtra", "historyextra.com", "https://www.historyextra.com/feed/"),
            site("JSTOR Daily", "daily.jstor.org", "https://daily.jstor.org/feed/"),
            site("Public Domain Review", "publicdomainreview.org", "https://publicdomainreview.org/rss.xml"),
            community("history"),
        ]),
        StarterPack(name: "YouTube", sources: [
            channel("Marques Brownlee", "UCBJycsmduvYEL83R_U4JriQ", "https://yt3.ggpht.com/qu4TmIaYUlS41-dJ9gZ7DUR3nilvmB5_11i6OKSdvNnBNiyOusZP1bMN6ICnuxtjFBb6ioKgRQ=s176-c-k-c0x00ffffff-no-rj-mo"),
            channel("Veritasium", "UCHnyfMqiRRG1u-2MsSQLbXA", "https://yt3.ggpht.com/7vCbvtCqtjQ3YLgsJt7Y952MQV1sBvhllSCSxHP8_sVZdcPCBrITfhkN2RdyCuwPnsByq-1GoA=s176-c-k-c0x00ffffff-no-rj-mo"),
            channel("Kurzgesagt – In a Nutshell", "UCsXVk37bltHxD1rDPwtNM8Q", "https://yt3.googleusercontent.com/ytc/AIdro_n1Ribd7LwdP_qKtqWL3ZDfIgv9M1d6g78VwpHGXVR2Ir4=s176-c-k-c0x00ffffff-no-rj-mo"),
            channel("Vsauce", "UC6nSFpj9HTCZ5t-N3Rm3-HA", "https://yt3.googleusercontent.com/ytc/AIdro_mpYedipdXUXCKkwjQEeFrepFlDHZ0LiczqWeKyG0YmJvA=s176-c-k-c0x00ffffff-no-rj-mo"),
            channel("3Blue1Brown", "UCYO_jab_esuFRV4b17AJtAw", "https://yt3.googleusercontent.com/ytc/AIdro_nFzZFPLxPZRHcE3SSwzdrbuWqfoWYwLAu0_2iO6blQYAU=s176-c-k-c0x00ffffff-no-rj-mo"),
            channel("Fireship", "UCsBjURrPoezykLs9EqgamOA", "https://yt3.ggpht.com/3fPNbkf_xPyCleq77ZhcxyeorY97NtMHVNUbaAON_RBDH9ydL4hJkjxC8x_4mpuopkB8oI7Ct6Y=s176-c-k-c0x00ffffff-no-rj-mo"),
            channel("TED", "UCAuUUnT6oDeKwE6v1NGQxug", "https://yt3.googleusercontent.com/ytc/AIdro_koIFcCOrvh0KThLNOiazAIDu6hcs8bjkGNwe1f6A_OYm8=s176-c-k-c0x00ffffff-no-rj-mo"),
            channel("Linus Tech Tips", "UCXuqSBlHAE6Xw-yeJA0Tunw", "https://yt3.ggpht.com/gnvYLhXy8FAlPXZ2RTrkrgj-5kyt0vdE2FUGVOiKGdEZIa-wN5A-7nwZBlWJLzUMmoh1NWAU=s176-c-k-c0x00ffffff-no-rj-mo"),
            channel("SmarterEveryDay", "UC6107grRI4m0o2-emgoDnAA", "https://yt3.googleusercontent.com/ytc/AIdro_l59Ewmp0DHZBRWbY9dVqjd2_mWwvrn8ad0bJfmdbMRYcA=s176-c-k-c0x00ffffff-no-rj-mo"),
            channel("Mark Rober", "UCY1kMZp36IQSyNx_9h4mpCg", "https://yt3.googleusercontent.com/ytc/AIdro_ksXY2REjZ6gYKSgnWT5jC_zT9mX900vyFtVinR8KbHww=s176-c-k-c0x00ffffff-no-rj-mo"),
            channel("CGP Grey", "UC2C_jShtL725hvbm1arSV9w", "https://yt3.googleusercontent.com/ytc/AIdro_nxrDGcxMGo8yKf2_Dw0eaGEWj39IAIdZQjAuz-_mBHjUI=s176-c-k-c0x00ffffff-no-rj-mo"),
            channel("Tom Scott", "UCBa659QWEk1AI4Tg--mrJ2A", "https://yt3.ggpht.com/WxHs0Jf1Jp_4ZU84wxnRL0owNHkzaLUEiD-GIfgCrVjZ0JhgriPTdPfGrkf-U7zwIs5zQl9ccg=s176-c-k-c0x00ffffff-no-rj-mo"),
            channel("Vox", "UCLXo7UDZvByw2ixzpQCufnA", "https://yt3.ggpht.com/iak9xjDjDoQHn9UNWSvkobPuxAzK1ApefjPH7HGObwo71AbaiEqdafMjmUJCgOoBFWNKPS2t2eI=s176-c-k-c0x00ffffff-no-rj-mo"),
            channel("Wendover Productions", "UC9RM-iSvTu1uPJb8X5yp3EQ", "https://yt3.ggpht.com/OnFIYArpFofrmngLXAsDGHsoVUpPA-yW3oD2ug7J2tq7H4BUcnnQvyfaQ8vw6s5JCiXJu1hb5A=s176-c-k-c0x00ffffff-no-rj-mo"),
            channel("RealLifeLore", "UCP5tjEmvPItGyLhmjdwP7Ww", "https://yt3.googleusercontent.com/ytc/AIdro_lK3FQppzWeqpXhyk8SpqvzzlrKr-pqjpRtY3PUfeF9poY=s176-c-k-c0x00ffffff-no-rj-mo"),
            channel("PBS Space Time", "UC7_gcs09iThXybpVgjHZ_7g", "https://yt3.ggpht.com/A7npG37dOJQffCnkUAyHI8wxnYhWA2q9SQY58AJ_bZUgKv30RtKD9sz5FQs4fs9-xWCg9S0P5jw=s176-c-k-c0x00ffffff-no-rj-mo"),
            channel("Numberphile", "UCoxcjq-8xIDTYp3uz647V5A", "https://yt3.googleusercontent.com/ytc/AIdro_nmbQSAGKk1OZCBBf_sPJqLoFfYOVDWRDzALocBjGQtHeI=s176-c-k-c0x00ffffff-no-rj-mo"),
            channel("Andrej Karpathy", "UCXUPKJO5MZQN11PqgIvyuvQ", "https://yt3.googleusercontent.com/ytc/AIdro_nDvyq2NoPL626bk1IbxQ94SfQsD-B0qgZchghtQNkLWoEz=s176-c-k-c0x00ffffff-no-rj-mo"),
            channel("Lex Fridman", "UCSHZKyawb77ixDdsGog4iWA", "https://yt3.googleusercontent.com/ytc/AIdro_ljfMy9kUR1PH9VRf-XsTsPqFMgORC_zodOQVEAm4hx36lC=s176-c-k-c0x00ffffff-no-rj-mo"),
            channel("Anthropic", "UCrDwWp7EBBv4NwvScIpBDOA", "https://yt3.ggpht.com/ux-GXUpB4PkI-qXVOpj9gGEiCkytT0Q78ka4srlxOm_Y3m1gEh5qy8Vu6vTjGSDztMT0NybtC7I=s176-c-k-c0x00ffffff-no-rj-mo"),
            channel("NFL on ESPN", "UCiio0ydw439X13KyZgMIcHw", "https://yt3.ggpht.com/R2uD99CTZM18cSZQQooqr40WOde5DA-2kim-dqwBm6UBG36Z6Lv--a-kBgyEe_6yA9SyhNTNNQ=s176-c-k-c0x00ffffff-no-rj-mo"),
            channel("Johnny Harris", "UCmGSJVG3mCRXVOP4yZrU1Dw", "https://yt3.googleusercontent.com/ytc/AIdro_kswBDn49WW5IneVE-5RlKyud5GvdzyQQ5SJQyVvJ4S3pk=s176-c-k-c0x00ffffff-no-rj-mo"),
            channel("Bon Appétit", "UCbpMy0Fg74eXXkvxJrtEn3w", "https://yt3.ggpht.com/cXS_yturdFtxAvqzJRnbMtZRYKCv3CDD7VHqHmhGZ2jgM8PYnOAbAbhZaK-Wb1NWgIrxrUjJiA=s176-c-k-c0x00ffffff-no-rj-mo"),
            channel("Computerphile", "UC9-y-6csu5WGm29I7JiwpnA", "https://yt3.ggpht.com/ebHMyRfch3u2UTZN1WQJDp9J5U7o38T_WnGkd2QhAIQwBgvozdaOCOnfDMtngtoHWutJvLl4i0c=s176-c-k-c0x00ffffff-no-rj-mo"),
        ]),
        StarterPack(name: "Podcasts", sources: [
            show("The Daily", "The New York Times", "https://feeds.simplecast.com/Sl5CSM3S", "https://is1-ssl.mzstatic.com/image/thumb/Podcasts221/v4/ab/64/66/ab6466a9-9a7d-e20e-7a3d-bc5be37d29ce/mza_15084852813176276273.jpg/100x100bb.jpg"),
            show("Hard Fork", "The New York Times", "https://feeds.simplecast.com/6HKOhNgS", "https://is1-ssl.mzstatic.com/image/thumb/Podcasts221/v4/de/c5/20/dec52092-6be0-9007-875c-6aa8e690a905/mza_12490014444602578825.jpg/100x100bb.jpg"),
            show("Acquired", "Ben Gilbert and David Rosenthal", "https://feeds.transistor.fm/acquired", "https://is1-ssl.mzstatic.com/image/thumb/Podcasts211/v4/a8/e1/de/a8e1deff-9f88-4e55-a541-b0dc793c0cdc/mza_11539673419613154037.jpg/100x100bb.jpg"),
            show("Planet Money", "NPR", "https://feeds.npr.org/510289/podcast.xml", "https://is1-ssl.mzstatic.com/image/thumb/Podcasts211/v4/85/df/53/85df5334-0fae-28a9-2bc4-b97b81061d0e/mza_10839245066228881011.jpg/100x100bb.jpg"),
            show("Radiolab", "WNYC Studios", "https://feeds.simplecast.com/EmVW7VGp", "https://is1-ssl.mzstatic.com/image/thumb/Podcasts211/v4/2b/b2/4d/2bb24d28-f3bb-916f-6bf3-9e125ba5219b/mza_4476298389845914795.jpg/100x100bb.jpg"),
            show("Lex Fridman Podcast", "Lex Fridman", "https://lexfridman.com/feed/podcast/", "https://is1-ssl.mzstatic.com/image/thumb/Podcasts211/v4/ea/42/d7/ea42d7b1-8d4e-dd97-da5d-c508756550ca/mza_16782152345430036863.jpg/100x100bb.jpg"),
            show("This American Life", "This American Life", "https://www.thisamericanlife.org/podcast/rss.xml", "https://is1-ssl.mzstatic.com/image/thumb/Podcasts211/v4/3d/e6/0f/3de60f5a-d3ec-95a1-430e-5ec54f6ea5d2/mza_8055625314950437990.png/100x100bb.jpg"),
            show("Stuff You Should Know", "iHeartPodcasts", "https://www.omnycontent.com/d/playlist/e73c998e-6e60-432f-8610-ae210140c5b1/a91018a4-ea4f-4130-bf55-ae270180c327/44710ecc-10bb-48d1-93c7-ae270180c33e/podcast.rss", "https://is1-ssl.mzstatic.com/image/thumb/Podcasts221/v4/aa/82/91/aa82912f-23ee-6f6a-583c-a4e993164d0e/mza_12111158076643383507.jpg/100x100bb.jpg"),
            show("99% Invisible", "Roman Mars", "https://feeds.simplecast.com/BqbsxVfO", "https://is1-ssl.mzstatic.com/image/thumb/Podcasts211/v4/79/d0/35/79d035ea-9043-b43e-7380-33cd47bd968b/mza_2606971010425550919.jpg/100x100bb.jpg"),
            show("Freakonomics Radio", "Freakonomics Radio + Stitcher", "https://feeds.simplecast.com/Y8lFbOT4", "https://is1-ssl.mzstatic.com/image/thumb/Podcasts115/v4/f7/0c/c5/f70cc540-ce36-d96f-b111-c970aad5505c/mza_17703422762227531425.jpg/100x100bb.jpg"),
            show("Dwarkesh Podcast", "Dwarkesh Patel", "https://apple.dwarkesh-podcast.workers.dev/feed.rss", "https://is1-ssl.mzstatic.com/image/thumb/Podcasts211/v4/af/6f/48/af6f4828-86a2-d4c3-b998-de2af1fdc8c0/mza_949624848217027907.jpg/100x100bb.jpg"),
            show("Decoder with Nilay Patel", "The Verge", "https://feeds.megaphone.fm/recodedecode", "https://is1-ssl.mzstatic.com/image/thumb/Podcasts211/v4/45/b2/ea/45b2ea67-03e4-2eb9-b333-fdcd9ead3f80/mza_1465024791640209731.jpg/100x100bb.jpg"),
            show("Accidental Tech Podcast", "Marco Arment, Casey Liss, John Siracusa", "https://cdn.atp.fm/rss/public?wtvryzdm", "https://is1-ssl.mzstatic.com/image/thumb/Podcasts126/v4/91/22/42/9122426f-df98-4302-6ba3-da67b0648e70/mza_5041274938111919910.png/100x100bb.jpg"),
            show("The Ezra Klein Show", "New York Times Opinion", "https://feeds.simplecast.com/kEKXbjuJ", "https://is1-ssl.mzstatic.com/image/thumb/Podcasts221/v4/9d/ca/35/9dca35d8-e7d2-7e4f-63b5-c2ff4973a3f5/mza_16891544429738729361.jpg/100x100bb.jpg"),
            show("Pivot", "New York Magazine", "https://feeds.megaphone.fm/pivot", "https://is1-ssl.mzstatic.com/image/thumb/Podcasts221/v4/13/22/39/1322397a-976e-3c8f-7764-91cc38d0dd70/mza_12130189257448841692.jpeg/100x100bb.jpg"),
            show("SmartLess", "Jason Bateman, Sean Hayes, Will Arnett", "https://feeds.simplecast.com/hNaFxXpO", "https://is1-ssl.mzstatic.com/image/thumb/Podcasts211/v4/b1/93/5f/b1935f9f-35be-9144-e813-626bd8dabfb4/mza_4132654708551836825.jpg/100x100bb.jpg"),
            show("Huberman Lab", "Scicomm Media", "https://feeds.megaphone.fm/hubermanlab", "https://is1-ssl.mzstatic.com/image/thumb/Podcasts221/v4/9a/d3/19/9ad31912-0b5a-a16e-2d7c-9fd074698b9c/mza_8994222203629500925.jpg/100x100bb.jpg"),
            show("Odd Lots", "Bloomberg", "https://www.omnycontent.com/d/playlist/e73c998e-6e60-432f-8610-ae210140c5b1/8a94442e-5a74-4fa2-8b8d-ae27003a8d6b/982f5071-765c-403d-969d-ae27003a8d83/podcast.rss", "https://is1-ssl.mzstatic.com/image/thumb/Podcasts211/v4/f3/99/6a/f3996a52-e4a4-bf0d-b7d6-e376c4058568/mza_15550359494736224565.jpg/100x100bb.jpg"),
            show("The Bill Simmons Podcast", "The Ringer", "https://feeds.megaphone.fm/the-bill-simmons-podcast", "https://is1-ssl.mzstatic.com/image/thumb/Podcasts211/v4/7a/98/73/7a987302-599c-9285-c210-fca2c83b9450/mza_1946147658144436679.jpg/100x100bb.jpg"),
            show("Latent Space: The AI Engineer Podcast", "Latent.Space", "https://podcast.latent.space/feed.xml", "https://is1-ssl.mzstatic.com/image/thumb/Podcasts221/v4/5c/7d/2a/5c7d2ade-4458-04e8-9838-979d187712ed/mza_16100858243175777898.jpg/100x100bb.jpg"),
            show("Serial", "Serial Productions & The New York Times", "https://feeds.simplecast.com/PpzWFGhg", "https://is1-ssl.mzstatic.com/image/thumb/Podcasts221/v4/9a/fb/87/9afb8760-0e05-2b3e-24a2-7e14cce74570/mza_14816055607064169808.jpg/100x100bb.jpg"),
        ]),
        StarterPack(name: "Newsletters", sources: [
            site("Astral Codex Ten", "astralcodexten.com", "https://www.astralcodexten.com/feed"),
            site("Letters from an American", "heathercoxrichardson.substack.com", "https://heathercoxrichardson.substack.com/feed"),
            site("One Useful Thing", "oneusefulthing.org", "https://www.oneusefulthing.org/feed"),
            site("Import AI", "importai.substack.com", "https://importai.substack.com/feed"),
        ]),
        StarterPack(name: "Reddit", sources: [
            community("movies"),
            community("news"),
            community("worldnews"),
            community("technology"),
            community("science"),
            community("programming"),
            community("MachineLearning"),
            community("explainlikeimfive"),
            community("todayilearned"),
            community("books"),
            community("space"),
            community("gaming"),
            community("nfl"),
            community("nba"),
            community("soccer"),
            community("personalfinance"),
            community("askscience"),
        ]),
        StarterPack(name: "X", sources: [
            xAccount("Andrej Karpathy", "karpathy"),
            xAccount("Sam Altman", "sama"),
            xAccount("Anthropic", "AnthropicAI"),
            xAccount("OpenAI", "OpenAI"),
            xAccount("Simon Willison", "simonw"),
            xAccount("Paul Graham", "paulg"),
            xAccount("Naval", "naval"),
            xAccount("Lex Fridman", "lexfridman"),
            xAccount("Dwarkesh Patel", "dwarkesh_sp"),
            xAccount("Marques Brownlee", "MKBHD"),
            xAccount("NASA", "NASA"),
            xAccount("National Geographic", "NatGeo"),
            xAccount("The New York Times", "nytimes"),
            xAccount("BBC Breaking News", "BBCBreaking"),
            xAccount("NFL", "NFL"),
            xAccount("ESPN", "espn"),
        ]),
        StarterPack(name: "Bluesky", sources: [
            bluesky("The New York Times", "nytimes.com", "did:plc:eclio37ymobqex2ncko63h4r"),
            bluesky("NPR", "npr.org", "did:plc:ln72v57ivz2g46uqf4xxqiuh"),
            bluesky("The Washington Post", "washingtonpost.com", "did:plc:k5nskatzhyxersjilvtnz4lh"),
            bluesky("The Verge", "theverge.com", "did:plc:7exlcsle4mjfhu3wnhcgizz6"),
            bluesky("404 Media", "404media.co", "did:plc:vcepp6trx4vpe5ourxso4tjl"),
            bluesky("ProPublica", "propublica.org", "did:plc:k4jt6heuiamymgi46yeuxtpt"),
            bluesky("The Onion", "theonion.com", "did:plc:a4pqq234yw7fqbddawjo7y35"),
            bluesky("Simon Willison", "simonwillison.net", "did:plc:kft6lu4trxowqmter2b6vg6z"),
            bluesky("Marques Brownlee", "mkbhd.com", "did:plc:ys5aypbbeqmwn42edy5t3sho"),
            bluesky("P(aul) Frazee", "pfrazee.com", "did:plc:ragtjsm2j2vknwkz3zp4oxrd"),
            bluesky("Jay 🦋", "jay.bsky.team", "did:plc:oky5czdrnfjpqslsw2a5iclo"),
            bluesky("AT Protocol Developers", "atproto.com", "did:plc:ewvi7nxzyoun6zhxrhs64oiz"),
            bluesky("WIRED", "wired.com", "did:plc:inz4fkbbp7ms3ixufw6xuvdi"),
            bluesky("The Atlantic", "theatlantic.com", "did:plc:nyxviptfyic2lvuorkr5yy3y"),
        ]),
    ]
}
