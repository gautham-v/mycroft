import Foundation

/// The page inside the YouTube player's web view. YouTube's embed runs with its controls off
/// (controls=0) under a clear layer that takes every click, so none of YouTube's own overlays (title
/// bar, More videos, logo, share) ever wake; the IFrame API drives it from one thin bar of our own that
/// shows on hover or pause and fades out two seconds into playback. Even with controls=0 YouTube still
/// flashes its title, center icon, More videos and logo for a few seconds whenever playback starts, so
/// `frameStyleScript` hides them inside YouTube's frame.
///
/// Mouse: click plays or pauses, double-click toggles full screen. Touch: a tap shows or hides the bar (after a
/// beat, to tell it from a double-tap), a double-tap on the left or right half skips 10 s back or forward like
/// YouTube's app, and further taps on that side within 0.7 s keep skipping, the sum shown on that side.
/// Keys: Space, ←/→ (5 s), F, M, C. Captions start off; the bar's CC button turns them on.
///
/// Full screen is the element Fullscreen API where WebKit has it (Mac, iPad). On iPhone it doesn't, so
/// the page asks the app instead (`nativeFullscreen`): the app pauses here and opens a full-screen
/// cover running this page with `inCover`, whose button closes it again.
///
/// `nativeFullscreen` also marks the iOS page (the `touch` class), which swaps the bar for a layer of big
/// touch controls (`touchControls`): in the cover, iOS Safari's full-screen player, with round glass buttons
/// (close top left, captions top right, speed above the bar, skip back 10 / play / skip forward 10 in the
/// middle) and a glass bar of time, scrubber and time left; inline, YouTube's mobile player, with the same
/// center trio, captions and speed top right, "position / length" and full screen bottom, and the scrubber
/// as a thin line along the bottom edge. The skip buttons share the double-tap's 10 s and running total.
///
/// Messages to the `openDispatchYouTube` handler: `{type: "playing"}` once playback first starts,
/// `{type: "failed"}` when the API or the video fails (the layer and bar are removed, YouTube's own
/// player or error shows), `{type: "blocked"}` when the video's owner doesn't allow it in other apps (error 101 or
/// 150; the reader says so itself), `{type: "fullscreen" | "exitFullscreen", time}`, and `{type: "time", time, duration}`
/// whenever the position crosses a second (the transcript follows it), and `{type: "state", playing}` whenever it
/// starts or stops playing. `window.odPlayer.resume(t)` seeks and plays (once the player is ready, if it isn't yet),
/// `window.odPlayer.toggle()` plays or pauses
/// and `seekBy(s)` skips (Space and ←/→ in the app's window).
///
/// SponsorBlock: `window.odPlayer.setSegments(list)` (or `window.odPendingSegments = list` before the page is up,
/// read at start) takes `{start, end, category, action: skip | mute | show | full | poi, label, color,
/// videoDuration}` and replaces the list each time, keeping which skips were undone (by start, end and category).
/// Once the length is known, segments whose `videoDuration` is more than 2 s off it are dropped. `skip`, `mute`
/// and `show` are coloured spans under the progress fill on every scrubber, `poi` a tick above it and `full` a
/// pill top left while the controls show (above the bar's left end in the iPhone cover, clear of the toast). While playing, `tick()`
/// seeks out of a `skip` segment (past any that follow it; to the very end if it runs to the end of the video)
/// and toasts "Skipped <label>" with Undo, which goes back to its start and leaves that segment alone from then
/// on. A seek the viewer makes into one (scrubber, ←/→, skip buttons, double-tap, resume) is never skipped:
/// the toast offers "<Label>" with Skip instead, until playback leaves the segment. In a `mute` segment the
/// player is muted (unless the viewer already had it muted) and a "Muted · <label>" pill shows; the viewer's own
/// mute toggle wins until the segment ends. The toast is top centre, above the shield so its button takes taps
/// (Enter presses it on the Mac), and hides after 4 s.
enum ReaderYouTubePage {
    static let handlerName = "openDispatchYouTube"

    /// Injected into every frame. In YouTube's player frame (only with controls=0, so the controls=1
    /// fallback keeps YouTube's own UI) it hides everything YouTube lays over the video: the mobile
    /// player's overlay (#player-controls, which WebKit gets because its user agent has no "Safari") and
    /// the desktop player's, keeping the video and the buffering spinner. Captions show only while the
    /// page has posted `{odCaptions: true}`, since YouTube turns some on by itself. If YouTube renames
    /// these the only loss is the flash coming back.
    static let frameStyleScript = #"""
    (function () {
      if (!/(^|\.)youtube(-nocookie)?\.com$/.test(location.hostname) || !/[?&]controls=0(&|$)/.test(location.search)) return;
      var style = document.createElement('style');
      style.textContent = '#player-controls, .html5-video-player > :not(.html5-video-container)' +
        ':not(.ytp-caption-window-container):not(.ytp-spinner) { display: none !important; }' +
        'html:not(.od-captions) .ytp-caption-window-container { display: none !important; }';
      (document.head || document.documentElement).appendChild(style);
      window.addEventListener('message', function (e) {
        if (e.source === window.parent && e.data && typeof e.data.odCaptions === 'boolean')
          document.documentElement.classList.toggle('od-captions', e.data.odCaptions);
      });
    })();
    """#

    /// The iOS page's controls (see the header): one layer, laid out by CSS as Safari's full-screen player
    /// (`cover` on the stage) or as YouTube's mobile player. The skip icons are SF's gobackward.10 /
    /// goforward.10 drawn by hand: an open circle with an arrowhead, the 10 inside (the forward one mirrored).
    private static let touchControls = #"""
    <div id="tui">
      <button id="tclose" class="hit g" aria-label="Exit full screen"><svg viewBox="0 0 24 24" fill="none"
        stroke="currentColor" stroke-width="2.4" stroke-linecap="round"><path d="M6.5 6.5l11 11M17.5 6.5l-11 11"/></svg></button>
      <button id="tcc" class="hit g" aria-label="Captions"><svg class="off-cc" viewBox="0 0 24 24" fill="none"
        stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><rect x="2.8" y="5.3" width="18.4" height="13.4" rx="2.6"/>
        <path d="M10.6 10.2a2.3 2.3 0 1 0 0 3.6M16.6 10.2a2.3 2.3 0 1 0 0 3.6"/></svg><svg class="on-cc" viewBox="0 0 24 24">
        <rect x="2" y="4.5" width="20" height="15" rx="3" fill="currentColor"/><path d="M10.6 10.2a2.3 2.3 0 1 0 0 3.6M16.6
        10.2a2.3 2.3 0 1 0 0 3.6" fill="none" stroke="#000" stroke-width="2" stroke-linecap="round"/></svg></button>
      <button id="tspeed" class="hit g" aria-label="Playback speed"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor"
        stroke-width="2" stroke-linecap="round"><path d="M4.6 17.5a8.6 8.6 0 1 1 14.8 0"/><path d="M12 14.2l3.6-4.6"/></svg><span
        id="trate">1×</span></button>
      <div id="tmid">
        <button id="tback" class="hit g" aria-label="Back 10 seconds"><svg viewBox="3 2 26 26" fill="none" stroke="currentColor"
          stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><path d="M8.93 9.93A10 10 0 1 0 16 7M18.5 3.8L14 7l4.5 3.2"/><text
          x="16" y="20.6" text-anchor="middle" font-size="9.5" font-weight="700" fill="currentColor" stroke="none"
          font-family="-apple-system,Helvetica,sans-serif">10</text></svg></button>
        <button id="tplay" class="hit g" aria-label="Play or pause"><svg class="off-play" viewBox="0 0 24 24"><path
          d="M7.5 4.8v14.4L19.5 12z" fill="currentColor"/></svg><svg class="on-play" viewBox="0 0 24 24" fill="currentColor"><rect
          x="6" y="4.8" width="4.2" height="14.4" rx="1"/><rect x="13.8" y="4.8" width="4.2" height="14.4" rx="1"/></svg></button>
        <button id="tfwd" class="hit g" aria-label="Forward 10 seconds"><svg viewBox="3 2 26 26" fill="none" stroke="currentColor"
          stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><path transform="translate(32 0) scale(-1 1)"
          d="M8.93 9.93A10 10 0 1 0 16 7M18.5 3.8L14 7l4.5 3.2"/><text x="16" y="20.6" text-anchor="middle" font-size="9.5"
          font-weight="700" fill="currentColor" stroke="none" font-family="-apple-system,Helvetica,sans-serif">10</text></svg></button>
      </div>
      <div id="tpill"><span id="tct">0:00 / 0:00</span></div>
      <button id="tfs" class="hit g" aria-label="Full screen"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor"
        stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M4 9.5V4h5.5M20 9.5V4h-5.5M4 14.5V20h5.5M20
        14.5V20h-5.5"/></svg></button>
      <div id="tbar" class="g">
        <span id="tcur" class="tt">0:00</span>
        <div id="ttrack" class="hit" role="slider" aria-label="Position"><i id="trail"></i><i id="tbuf"></i><i id="tfill"></i><b
          id="tknob"></b></div>
        <span id="tleft" class="tt"></span>
      </div>
    </div>
    """#

    /// `src`, `title` and `poster` must already be attribute-escaped.
    static func html(src: String, title: String, poster: String, nativeFullscreen: Bool, inCover: Bool) -> String {
        let chevrons = String(repeating: #"<svg viewBox="0 0 24 24" fill="white"><path d="M7 5.5v13L18 12z"/></svg>"#, count: 3)
        let stageClass = nativeFullscreen ? (inCover ? "touch cover" : "touch") : ""
        return #"""
        <!doctype html>
        <html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
        <meta name="referrer" content="strict-origin-when-cross-origin">
        <style>
        html,body{margin:0;padding:0;height:100%;background:#000;overflow:hidden;-webkit-user-select:none;user-select:none;
          -webkit-tap-highlight-color:transparent}
        /* The bar grows with the player (the viewport is the player): 17px icons up to ~810px wide, 20px at
           960 (theater), 26px from ~1240 (full screen). Everything else follows the icon size. */
        #stage{position:absolute;inset:0;background:#000;color:#fff;--i:clamp(17px,2.09vw,26px);
          --tr:max(3px,calc(var(--i)*.2));--k:max(11px,calc(var(--i)*.65));--c:clamp(64px,calc(var(--i)*3.6),96px);
          font:500 max(12px,calc(var(--i)*.68))/1 -apple-system,BlinkMacSystemFont,"Helvetica Neue",sans-serif}
        #stage.idle{cursor:none}
        iframe{position:absolute;inset:0;width:100%;height:100%;border:0}
        #shield{position:absolute;inset:0}
        .ctl{opacity:0;transition:opacity .2s ease;pointer-events:none}
        #stage.show .ctl{opacity:1;pointer-events:auto}
        #scrim{position:absolute;left:0;right:0;bottom:0;height:calc(var(--i)*5.5);max-height:45%;
          background:linear-gradient(rgba(0,0,0,0),rgba(0,0,0,.5))}
        #bar{position:absolute;left:0;right:0;bottom:0;display:flex;align-items:center;gap:max(14px,calc(var(--i)*.9));
          padding:max(12px,calc(var(--i)*.7)) max(16px,var(--i))}
        button{appearance:none;-webkit-appearance:none;border:0;background:none;color:inherit;font:inherit;cursor:pointer;
          padding:5px;margin:-5px;display:grid;place-items:center;flex:none}
        button svg{width:var(--i);height:var(--i);display:block}
        button:focus-visible{outline:2px solid rgba(255,255,255,.75);outline-offset:1px;border-radius:5px}
        [hidden]{display:none!important}
        .t{font-variant-numeric:tabular-nums;opacity:.92;flex:none}
        #track{flex:1;min-width:40px;height:calc(var(--k) + 10px);position:relative;cursor:pointer;touch-action:none}
        #track i{position:absolute;left:0;top:50%;height:var(--tr);margin-top:calc(var(--tr)/-2);border-radius:99px}
        #rail{right:0;background:rgba(255,255,255,.28)}
        #buf{background:rgba(255,255,255,.3);width:0}
        #fill{background:#fff;width:0}
        #knob{position:absolute;top:50%;left:0;width:var(--k);height:var(--k);margin:calc(var(--k)/-2) 0 0 calc(var(--k)/-2);
          border-radius:50%;
          background:#fff;transform:scale(0);transition:transform .12s ease}
        #track:hover #knob,#track.drag #knob{transform:scale(1)}
        #speed{font-weight:650;min-width:2.3em}
        /* A plain tinted circle: a backdrop blur over YouTube's frame only half draws. */
        .round{position:absolute;left:50%;top:50%;width:var(--c);height:var(--c);margin:calc(var(--c)/-2) 0 0 calc(var(--c)/-2);
          padding:0;border-radius:50%;background:rgba(0,0,0,.5)}
        .round svg{width:40%;height:40%}
        #big svg{margin-left:4%}
        #stage:not(.paused) #big{display:none}
        #cover{position:absolute;inset:0;background:#000 center/cover no-repeat;display:none}
        #cover::before{content:"";position:absolute;inset:0;background:rgba(0,0,0,.45)}
        #stage.ended #cover{display:block}
        .on-play,.on-muted,.on-cc,.on-fs{display:none}
        #stage.playing .on-play,#stage.muted .on-muted,#stage.cc .on-cc,#stage.fs .on-fs{display:block}
        #stage.playing .off-play,#stage.muted .off-muted,#stage.cc .off-cc,#stage.fs .off-fs{display:none}
        @media (min-width:1005px){#stage{font-weight:600}}
        @media (max-width:480px){#bar{gap:12px;padding:10px 12px}}
        /* Touch: 44pt tap areas around the icons, whatever their drawn size. */
        @media (hover:none){#mute{display:none}
          #bar button{padding:calc((44px - var(--i))/2);margin:calc((var(--i) - 44px)/2)}}
        /* iOS (the touch class) hides the bar and shows the touch layer instead, sized from --s (skip buttons),
           --p (play), --cb (corner buttons) and --ph (the glass bar), smaller where the player is short (inline,
           or the cover held upright). The layer fades with the controls, but only its buttons take touches, so
           the double-tap still reaches the shield. */
        #tui{display:none}
        #stage.touch{--s:68px;--p:104px;--cb:52px;--ph:52px;--m:20px;--ts:15px;font-size:var(--ts)}
        @media (max-height:300px){#stage.touch{--s:48px;--p:68px;--cb:38px;--ph:40px;--m:10px;--ts:13px}}
        #stage.touch #bar,#stage.touch #big{display:none}
        #stage.touch #scrim{inset:0;height:auto;max-height:none;background:rgba(0,0,0,.35);pointer-events:none!important}
        #stage.touch #tui{display:block;position:absolute;inset:0;opacity:0;transition:opacity .2s ease;pointer-events:none}
        #stage.touch.show #tui{opacity:1}
        #tui .hit{pointer-events:none}
        #stage.show #tui .hit{pointer-events:auto}
        /* The glass: dark, blurred, with a faint light rim. */
        #tui .g{background:rgba(40,40,40,.55);-webkit-backdrop-filter:blur(20px) saturate(1.5);
          backdrop-filter:blur(20px) saturate(1.5);box-shadow:inset 0 0 0 1px rgba(255,255,255,.14)}
        #tui button{padding:0;margin:0;border-radius:50%;display:grid;place-items:center;color:#fff}
        #tui button svg{width:50%;height:50%}
        #tmid{position:absolute;left:0;right:0;top:50%;transform:translateY(-50%);display:flex;justify-content:center;
          align-items:center;gap:calc(var(--s)*.45);pointer-events:none}
        #tmid button{width:var(--s);height:var(--s)}
        #tmid button svg{width:56%;height:56%}
        #tmid #tplay{width:var(--p);height:var(--p)}
        #tmid #tplay svg{width:42%;height:42%}
        #tplay .off-play{margin-left:6%}
        #tclose,#tcc,#tspeed,#tfs{position:absolute;width:var(--cb);height:var(--cb)}
        #tclose{left:var(--m);top:var(--m)}
        #tcc{right:var(--m);top:var(--m)}
        #tspeed{right:var(--m);bottom:calc(var(--m) + var(--ph) + 12px);font-weight:650;font-size:calc(var(--ts) - 3px);
          grid-auto-flow:row;align-content:center;gap:1px}
        #tspeed svg{width:calc(var(--cb)*.42);height:calc(var(--cb)*.42);justify-self:center}
        #tfs{right:var(--m);bottom:26px}
        #stage:not(.cover) #tclose,#stage.cover #tfs{display:none}
        #tpill{position:absolute;left:var(--m);bottom:26px;height:calc(var(--ph)*.72);padding:0 12px;border-radius:99px;
          display:flex;align-items:center;font-weight:600;font-variant-numeric:tabular-nums}
        #tpill{background:rgba(40,40,40,.55);-webkit-backdrop-filter:blur(20px) saturate(1.5);backdrop-filter:blur(20px) saturate(1.5)}
        #stage.cover #tpill{display:none}
        #tbar{display:flex;align-items:center;position:absolute;left:var(--m);right:var(--m);bottom:var(--m);height:var(--ph);
          padding:0 22px;gap:14px;border-radius:99px;font-weight:600;font-variant-numeric:tabular-nums}
        #ttrack{position:relative;flex:1;height:32px;touch-action:none}
        #ttrack i{position:absolute;left:0;top:50%;height:8px;margin-top:-4px;border-radius:99px}
        #trail{right:0;background:rgba(255,255,255,.3)}
        #tbuf{background:rgba(255,255,255,.3);width:0}
        #tfill{background:#fff;width:0}
        #tknob{display:none;position:absolute;top:50%;left:0;width:16px;height:16px;margin:-8px 0 0 -8px;border-radius:50%;
          background:#fff;transition:transform .12s ease}
        /* Inline the bar dissolves (display:contents) and the scrubber lines the bottom edge, its hit area 28px tall. */
        #stage:not(.cover) #tbar{display:contents}
        #stage:not(.cover) .tt{display:none}
        #stage:not(.cover) #ttrack{position:absolute;left:0;right:0;bottom:0;height:28px}
        #stage:not(.cover) #ttrack i{top:calc(100% - 9px);height:3px;margin-top:-1.5px}
        #stage:not(.cover) #tknob{display:block;top:calc(100% - 9px)}
        #ttrack.drag #tknob{transform:scale(1.4)}
        #stage:not(.cover) #tspeed{top:var(--m);right:calc(var(--m)*2 + var(--cb));bottom:auto}
        #stage:not(.cover) #tspeed svg{display:none}
        #stage:not(.cover) #tspeed{font-size:var(--ts)}
        /* The double-tap skip: a half ellipse on the side tapped, three chevrons running outward over the total. */
        .skip{position:absolute;top:0;bottom:0;width:36%;display:flex;flex-direction:column;align-items:center;
          justify-content:center;gap:8px;background:rgba(255,255,255,.2);opacity:0;transition:opacity .25s ease;
          pointer-events:none}
        #skipL{left:0;border-radius:0 50% 50% 0/0 50% 50% 0}
        #skipR{right:0;border-radius:50% 0 0 50%/50% 0 0 50%}
        .skip.go{opacity:1;transition:opacity .08s ease}
        .chs{display:flex}
        #skipL .chs{transform:scaleX(-1)}
        .chs svg{width:calc(var(--i)*.8);height:calc(var(--i)*.8);opacity:.3}
        .skip.go .chs svg{animation:chev .6s ease-in-out infinite}
        .chs svg:nth-child(2){animation-delay:.15s!important}
        .chs svg:nth-child(3){animation-delay:.3s!important}
        @keyframes chev{0%,100%{opacity:.3}50%{opacity:1}}
        .skip b{font-weight:650;font-size:max(13px,calc(var(--i)*.6))}
        /* SponsorBlock. Spans sit under the fill (so progress stays white across them) and over the rail and
           buffer; points sit over the fill. The toast and the muted pill stack top centre; the toast alone takes
           touches (above the shield), and the pill for a whole-video label sits top left with the controls (bottom
           left in the cover, where the top row is the close button, the toast and captions). */
        .sb{opacity:.9;min-width:3px}
        #track i.poi{width:4px;margin-left:-2px;height:calc(var(--tr)*2.6);margin-top:calc(var(--tr)*-1.3);border-radius:2px}
        #ttrack i.poi{width:4px;margin-left:-2px;height:14px;margin-top:-7px;border-radius:2px}
        #stage:not(.cover) #ttrack i.poi{height:9px;margin-top:-4.5px}
        #sbfull,#sbmute,#sbtoast{background:rgba(28,28,28,.72);-webkit-backdrop-filter:blur(20px) saturate(1.5);
          backdrop-filter:blur(20px) saturate(1.5);box-shadow:inset 0 0 0 1px rgba(255,255,255,.14);color:#fff;
          font-size:max(12px,calc(var(--i)*.64));font-weight:600;white-space:nowrap}
        #sbfull{position:absolute;left:max(16px,var(--i));top:max(12px,calc(var(--i)*.7));display:flex;align-items:center;
          gap:.55em;height:calc(var(--i)*1.6);max-width:40%;padding:0 .95em 0 .8em;border-radius:99px;pointer-events:none!important}
        #sbfull i{width:.65em;height:.65em;border-radius:50%;flex:none}
        #sbfull span{overflow:hidden;text-overflow:ellipsis}
        #sbtop{position:absolute;left:50%;top:max(12px,calc(var(--i)*.7));transform:translateX(-50%);display:flex;
          flex-direction:column;align-items:center;gap:6px;max-width:calc(100% - 32px);pointer-events:none}
        #sbtoast{display:flex;align-items:center;gap:.7em;max-width:100%;height:calc(var(--i)*1.95);padding:0 .3em 0 1.05em;
          border-radius:99px;font-size:max(13px,calc(var(--i)*.72));pointer-events:auto;touch-action:manipulation;
          opacity:0;visibility:hidden;transform:translateY(-6px);
          transition:opacity .2s ease,transform .2s ease,visibility 0s .2s}
        #sbtoast.on{opacity:1;visibility:visible;transform:none;transition-delay:0s}
        #sbmsg{overflow:hidden;text-overflow:ellipsis;min-width:0}
        #sbtoast button{position:relative;align-self:stretch;margin:.3em 0;padding:0 .9em;border-radius:99px;
          background:rgba(255,255,255,.2);font-weight:650}
        #sbtoast button:hover{background:rgba(255,255,255,.3)}
        #sbmute{display:flex;align-items:center;gap:.5em;height:calc(var(--i)*1.5);padding:0 .9em 0 .7em;border-radius:99px;
          pointer-events:none}
        #sbmute svg{width:1.3em;height:1.3em;flex:none}
        /* Touch: the toast lines up with the corner buttons and stays clear of them (captions, speed inline; close,
           captions in the cover), with a taller button whose hit area reaches past the pill. */
        #stage.touch #sbfull{left:var(--m);top:calc(var(--m) + var(--cb)*.14);height:calc(var(--cb)*.72);font-size:calc(var(--ts) - 1px)}
        #stage.touch.cover #sbfull{top:auto;bottom:calc(var(--m) + var(--ph) + 12px)}
        #stage.touch #sbtop{top:calc(var(--m) + var(--cb)*.06);max-width:calc(100% - 2*(var(--m)*2 + var(--cb)*2 + 9px))}
        #stage.touch.cover #sbtop{max-width:calc(100% - 2*(var(--m)*1.5 + var(--cb)))}
        #stage.touch #sbtoast{height:calc(var(--cb)*.88);font-size:var(--ts)}
        #stage.touch:not(.cover) #sbfull{padding:0 .8em 0 .65em;font-size:calc(var(--ts) - 2px)}
        #stage.touch:not(.cover) #sbtoast{font-size:calc(var(--ts) - 1px)}
        #stage.touch #sbtoast button{margin:2px 0}
        #stage.touch #sbtoast button::after{content:"";position:absolute;inset:-8px -6px}
        #stage.touch #sbmute{height:calc(var(--cb)*.66);font-size:calc(var(--ts) - 1px)}
        @media (prefers-reduced-motion:reduce){.ctl,#knob,#tknob,#tui,.skip{transition:none}.skip.go .chs svg{animation:none;opacity:1}
          #sbtoast{transition:none;transform:none}}
        </style></head>
        <body><div id="stage" class="\#(stageClass)">
          <iframe id="yt" src="\#(src)" title="\#(title)"
            allow="accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture; web-share"
            referrerpolicy="strict-origin-when-cross-origin"></iframe>
          <div id="shield"></div>
          <div id="cover" style="background-image:url('\#(poster)')">
            <button id="replay" class="round" aria-label="Replay"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor"
              stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><path d="M4.5 12a7.5 7.5 0 1 0 2.2-5.3"/>
              <path d="M4.2 3.8v4.6h4.6"/></svg></button>
          </div>
          <div id="skipL" class="skip"><div class="chs">\#(chevrons)</div><b></b></div>
          <div id="skipR" class="skip"><div class="chs">\#(chevrons)</div><b></b></div>
          <div id="scrim" class="ctl"></div>
          <button id="big" class="round ctl" aria-label="Play"><svg viewBox="0 0 24 24"><path d="M7.5 4.8v14.4L19.5 12z"
            fill="currentColor"/></svg></button>
          <div id="bar" class="ctl">
            <button id="play" aria-label="Play or pause"><svg class="off-play" viewBox="0 0 24 24"><path d="M7.5 4.8v14.4L19.5 12z"
              fill="currentColor"/></svg><svg class="on-play" viewBox="0 0 24 24" fill="currentColor"><rect x="6" y="4.8"
              width="4.2" height="14.4" rx="1"/><rect x="13.8" y="4.8" width="4.2" height="14.4" rx="1"/></svg></button>
            <span id="cur" class="t">0:00</span>
            <div id="track" role="slider" aria-label="Position"><i id="rail"></i><i id="buf"></i><i id="fill"></i><b id="knob"></b></div>
            <span id="left" class="t"></span>
            <button id="mute" aria-label="Mute"><svg viewBox="0 0 24 24"><path d="M3.5 9.2h3.6L12 5v14l-4.9-4.2H3.5z"
              fill="currentColor"/><path class="off-muted" d="M15.3 8.8a4.5 4.5 0 0 1 0 6.4M18 6.2a8.3 8.3 0 0 1 0 11.6" fill="none"
              stroke="currentColor" stroke-width="1.9" stroke-linecap="round"/><path class="on-muted" d="M15.5 9.5l5 5M20.5 9.5l-5 5"
              fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round"/></svg></button>
            <button id="cc" aria-label="Captions"><svg class="off-cc" viewBox="0 0 24 24" fill="none" stroke="currentColor"
              stroke-width="1.8" stroke-linecap="round"><rect x="2.8" y="5.3" width="18.4" height="13.4" rx="2.6"/>
              <path d="M10.6 10.2a2.3 2.3 0 1 0 0 3.6M16.6 10.2a2.3 2.3 0 1 0 0 3.6"/></svg><svg class="on-cc" viewBox="0 0 24 24">
              <rect x="2" y="4.5" width="20" height="15" rx="3" fill="currentColor"/><path d="M10.6 10.2a2.3 2.3 0 1 0 0 3.6M16.6
              10.2a2.3 2.3 0 1 0 0 3.6" fill="none" stroke="#000" stroke-width="2" stroke-linecap="round"/></svg></button>
            <button id="speed" aria-label="Playback speed">1×</button>
            <button id="fs" aria-label="Full screen"><svg class="off-fs" viewBox="0 0 24 24" fill="none" stroke="currentColor"
              stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M4 9.5V4h5.5M20 9.5V4h-5.5M4 14.5V20h5.5M20
              14.5V20h-5.5"/></svg><svg class="on-fs" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"
              stroke-linecap="round" stroke-linejoin="round"><path d="M9.5 4v5.5H4M14.5 4v5.5H20M9.5 20v-5.5H4M14.5 20v-5.5H20"/>
              </svg></button>
          </div>
          <div id="sbfull" class="ctl" hidden><i></i><span></span></div>
          \#(nativeFullscreen ? touchControls : "")
          <div id="sbtop">
            <div id="sbtoast" role="status"><span id="sbmsg"></span><button id="sbbtn"></button></div>
            <div id="sbmute" hidden><svg viewBox="0 0 24 24"><path d="M3.5 9.2h3.6L12 5v14l-4.9-4.2H3.5z" fill="currentColor"/><path
              d="M15.5 9.5l5 5M20.5 9.5l-5 5" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round"/></svg><span
              id="sbmutetext"></span></div>
          </div>
        </div>
        <script>
        (function () {
          var NATIVE_FS = \#(nativeFullscreen), IN_COVER = \#(inCover), TOUCH = !!document.getElementById('tui');
          var RATES = [1, 1.25, 1.5, 2, 0.75];
          function $(id) { return document.getElementById(id); }
          var stage = $('stage'), iframe = $('yt'), track = $('track');
          var player = null, ready = false, failed = false, state = -1, started = false;
          var active = false, overBar = false, dragging = false, dragT = 0, lastSeek = 0, hideTimer = 0, lastTouch = 0;
          var muted = false, ccOn = false, rate = 0, lastSecond = -1, pendingSeek = null;
          var canFS = !!(document.fullscreenEnabled || document.webkitFullscreenEnabled);

          function post(m) {
            try { window.webkit.messageHandlers.\#(handlerName).postMessage(m); } catch (e) {}
          }
          function fmt(s) {
            s = Math.max(0, Math.floor(s || 0));
            var h = Math.floor(s / 3600), m = Math.floor(s % 3600 / 60), x = s % 60;
            return (h ? h + ':' + (m < 10 ? '0' : '') : '') + m + ':' + (x < 10 ? '0' : '') + x;
          }
          function now() { return ready ? player.getCurrentTime() || 0 : 0; }
          function duration() { return ready ? player.getDuration() || 0 : 0; }
          function isPlaying() { return state === 1 || state === 3; }
          function isFS() { return !!(document.fullscreenElement || document.webkitFullscreenElement); }

          function render() {
            var d = duration(), t = dragging ? dragT : now(), f = d ? Math.min(1, t / d) : 0;
            $('cur').textContent = fmt(t);
            $('left').textContent = d ? '−' + fmt(d - t) : '';
            if (TOUCH) {
              $('tcur').textContent = fmt(t);
              $('tleft').textContent = d ? '−' + fmt(d - t) : '';
              $('tct').textContent = fmt(t) + ' / ' + fmt(d);
              $('tfill').style.width = $('tknob').style.left = f * 100 + '%';
              $('tbuf').style.width = (ready ? player.getVideoLoadedFraction() || 0 : 0) * 100 + '%';
              $('ttrack').setAttribute('aria-valuetext', fmt(t) + ' of ' + fmt(d));
            }
            $('fill').style.width = $('knob').style.left = f * 100 + '%';
            $('buf').style.width = (ready ? player.getVideoLoadedFraction() || 0 : 0) * 100 + '%';
            track.setAttribute('aria-valuetext', fmt(t) + ' of ' + fmt(d));
          }
          function update() {
            var ended = state === 0, paused = ready && !isPlaying() && !ended;
            var show = !failed && (paused || active || overBar || dragging || stage.contains(document.activeElement) &&
              document.activeElement !== document.body);
            stage.classList.toggle('playing', isPlaying());
            stage.classList.toggle('paused', paused);
            stage.classList.toggle('ended', ended);
            stage.classList.toggle('show', show && !ended);
            stage.classList.toggle('idle', !show && isPlaying());
            stage.classList.toggle('muted', muted);
            stage.classList.toggle('cc', ccOn);
            stage.classList.toggle('fs', IN_COVER || isFS());
          }
          // Show the bar, then hide it two seconds after the last movement.
          function poke() {
            active = true;
            clearTimeout(hideTimer);
            hideTimer = setTimeout(function () { active = false; update(); }, TOUCH ? 3000 : 2000);
            update();
          }
          function hide() { clearTimeout(hideTimer); active = false; update(); }

          function toggle() {
            if (!ready) return;
            if (isPlaying()) player.pauseVideo();
            else { if (state === 0) player.seekTo(0, true); player.playVideo(); }
          }
          function seekBy(d) {
            if (!ready) return;
            var t = Math.max(0, Math.min(duration(), now() + d));
            player.seekTo(t, true);
            seeked(t);
            render();
          }
          function toggleMute() {
            if (!ready) return;
            if (muteSeg) muteOverride = true;
            muted = !muted;
            if (muted) player.mute(); else player.unMute();
            update();
          }
          // The captions module is undocumented but long-standing: unloading it stops captions, loading it
          // shows the default track (or the one in the viewer's language). frameStyleScript hides them
          // in YouTube's frame until we say otherwise, because YouTube turns some on by itself.
          function showCaptions(on) { try { iframe.contentWindow.postMessage({ odCaptions: on }, '*'); } catch (e) {} }
          function captionsOff() { try { player.unloadModule('captions'); } catch (e) {} }
          function toggleCaptions() {
            if (!ready) return;
            ccOn = !ccOn;
            update();
            showCaptions(ccOn);
            if (!ccOn) { captionsOff(); return; }
            try { player.loadModule('captions'); } catch (e) {}
            setTimeout(function () {
              try {
                if (!ccOn || (player.getOption('captions', 'track') || {}).languageCode) return;
                var list = player.getOption('captions', 'tracklist') || [], lang = (navigator.language || 'en').slice(0, 2);
                var pick = list.filter(function (t) { return (t.languageCode || '').slice(0, 2) === lang; })[0] || list[0];
                if (pick) player.setOption('captions', 'track', { languageCode: pick.languageCode });
              } catch (e) {}
            }, 500);
          }
          function cycleSpeed() {
            if (!ready) return;
            rate = (rate + 1) % RATES.length;
            player.setPlaybackRate(RATES[rate]);
            $('speed').textContent = RATES[rate] + '×';
            if (TOUCH) $('trate').textContent = RATES[rate] + '×';
          }
          function fullscreen() {
            if (IN_COVER) { post({ type: 'exitFullscreen', time: now() }); return; }
            if (canFS) {
              if (isFS()) (document.exitFullscreen || document.webkitExitFullscreen).call(document);
              else (stage.requestFullscreen || stage.webkitRequestFullscreen).call(stage);
            } else if (NATIVE_FS && ready) {
              player.pauseVideo();
              post({ type: 'fullscreen', time: now() });
            }
          }
          if (!canFS && !NATIVE_FS && !IN_COVER) $('fs').hidden = true;
          document.addEventListener('fullscreenchange', update);
          document.addEventListener('webkitfullscreenchange', update);

          // The YouTube API never loaded or the video can't play here: get out of the way and reload with
          // YouTube's own controls (frameStyleScript leaves those alone), so its player or its error and
          // Watch on YouTube link can be used.
          function fail() {
            if (failed) return;
            failed = true;
            $('shield').remove();
            $('bar').remove();
            $('big').remove();
            $('sbtop').remove();
            $('sbfull').remove();
            iframe.src = iframe.src.replace('controls=0', 'controls=1');
            update();
            post({ type: 'failed' });
          }
          var failTimer = setTimeout(fail, 12000);

          function setState(s) {
            var was = isPlaying();
            state = s;
            if (isPlaying() !== was) post({ type: 'state', playing: isPlaying() });
            if (isPlaying() && !started) {
              started = true;
              if (!ccOn) captionsOff();
              post({ type: 'playing' });
            }
            render();
            update();
          }
          // The embed autoplays on its own, so it can be playing before the API attaches; then no
          // onStateChange comes for that start (the page would think it paused: the poster stays up and a
          // click plays instead of pausing). The state the API last heard is read back every tick instead.
          function tick() {
            var s = player.getPlayerState();
            if (typeof s === 'number' && s !== state) setState(s); else render();
            var second = Math.floor(now());
            if (second !== lastSecond) { lastSecond = second; post({ type: 'time', time: now(), duration: duration() }); }
            segmentTick();
          }

          // SponsorBlock segments (see the header). `segs` is what Swift sent, `live` the part of it that fits this
          // video, `undone` the skips the viewer reversed (keyed by start, end and category, so it survives a
          // new list), `landedKey` the skip segment the viewer seeked into, `lastManual` when they last seeked.
          var segs = [], live = [], undone = {}, segDur = 0, landedKey = null, lastManual = 0, justSkipped = null;
          var muteSeg = null, muteOverride = false, toastFn = null, toastKind = '', toastTimer = 0;
          var segTracks = [{ tr: track, fill: $('fill'), knob: $('knob') }];
          if (TOUCH) segTracks.push({ tr: $('ttrack'), fill: $('tfill'), knob: $('tknob') });
          function cap(s) { return s.charAt(0).toUpperCase() + s.slice(1); }
          function inSeg(g, t, tail) { return t >= g.s && t < g.e - tail; }
          // A skip segment holding t, undone or not.
          function skipAt(t) {
            for (var i = 0; i < live.length; i++) if (live[i].action === 'skip' && inSeg(live[i], t, 0.25)) return live[i];
            return null;
          }
          function setSegments(list) {
            if (failed) return;
            segs = [];
            (Array.isArray(list) ? list : []).forEach(function (x) {
              if (!x) return;
              var a = x.action, s = +x.start, e = a === 'poi' ? s : +x.end;
              if (['skip', 'mute', 'show', 'full', 'poi'].indexOf(a) < 0 || !(s >= 0)) return;
              if (a !== 'full' && !(a === 'poi' || e > s)) return;
              segs.push({ s: s, e: isFinite(e) ? e : 0, action: a, label: String(x.label || x.category || ''),
                color: /^#[0-9a-f]{3,8}$/i.test(x.color) ? x.color : '#00d400', vd: +x.videoDuration || 0,
                key: x.start + '|' + x.end + '|' + x.category });
            });
            drawSegments();
          }
          // Drop segments cut for another version of the video, then redraw the markers and the whole-video pill.
          function drawSegments() {
            if (failed) return;
            var d = segDur = duration(), full = null;
            live = segs.filter(function (g) { return !(d && g.vd > 0 && Math.abs(g.vd - d) > 2); });
            segTracks.forEach(function (x) {
              [].slice.call(x.tr.querySelectorAll('.sb')).forEach(function (el) { el.remove(); });
            });
            live.forEach(function (g) {
              if (g.action === 'full') { full = full || g; return; }
              if (!d || g.s >= d) return;
              segTracks.forEach(function (x) {
                var el = document.createElement('i'), poi = g.action === 'poi';
                el.className = poi ? 'sb poi' : 'sb';
                el.style.background = g.color;
                el.style.left = g.s / d * 100 + '%';
                if (!poi) el.style.width = (Math.min(g.e, d) - g.s) / d * 100 + '%';
                x.tr.insertBefore(el, poi ? x.knob : x.fill);
              });
            });
            $('sbfull').hidden = !full;
            if (full) {
              $('sbfull').lastChild.textContent = cap(full.label);
              $('sbfull').firstChild.style.background = full.color;
            }
          }
          function toast(msg, btn, fn, ms, kind) {
            if (failed) return;
            $('sbmsg').textContent = msg;
            $('sbbtn').textContent = btn;
            toastFn = fn;
            toastKind = kind;
            $('sbtoast').classList.add('on');
            clearTimeout(toastTimer);
            toastTimer = setTimeout(hideToast, ms);
          }
          function hideToast() {
            if (failed) return;
            clearTimeout(toastTimer);
            toastFn = null;
            toastKind = '';
            $('sbtoast').classList.remove('on');
          }
          function toastAct() { var f = toastFn; hideToast(); if (f) f(); }
          // The viewer seeked to t: no skipping out of whatever they landed in, but offer it.
          function seeked(t) {
            lastManual = Date.now();
            landedKey = null;
            justSkipped = null;
            hideToast();
            var g = skipAt(t);
            if (!g) return;
            landedKey = g.key;
            if (!undone[g.key]) toast(cap(g.label), 'Skip', function () {
              var d = duration();
              player.seekTo(g.e >= d - 1 ? d : g.e, true);
            }, 4000, 'landed');
          }
          // Leave the skip segment at t (and any that run on from it) and say so.
          function autoSkip(g, d) {
            var hit = [g], e = g.e, more = true;
            while (more && hit.length < 12) {
              more = false;
              live.forEach(function (h) {
                if (h.action === 'skip' && hit.indexOf(h) < 0 && !undone[h.key] && h.s <= e + 0.25 && h.e > e) {
                  hit.push(h); e = h.e; more = true;
                }
              });
            }
            justSkipped = { key: g.key, at: Date.now() };
            landedKey = null;
            player.seekTo(e >= d - 1 ? d : e, true);
            toast('Skipped ' + g.label, 'Undo', function () {
              hit.forEach(function (h) { undone[h.key] = true; });
              lastManual = Date.now();
              justSkipped = null;
              player.seekTo(g.s, true);
              if (state === 0) player.playVideo();
            }, 4000, 'skipped');
          }
          function segmentTick() {
            if (failed) return;
            var d = duration(), t = now(), i, g = null;
            if (d !== segDur) drawSegments();
            for (i = 0; i < live.length; i++) if (live[i].action === 'mute' && inSeg(live[i], t, 0)) { g = live[i]; break; }
            // Mute for the length of the segment unless the viewer has it muted; their own toggle wins until it ends.
            if (g && !muteSeg) { muteOverride = false; if (!muted) player.mute(); }
            else if (!g && muteSeg && !muteOverride && !muted) player.unMute();
            if (!g) muteOverride = false;
            muteSeg = g;
            $('sbmute').hidden = !g || muteOverride || muted;
            if (g) $('sbmutetext').textContent = 'Muted · ' + g.label;
            var settled = Date.now() - lastManual > 800;
            var here = skipAt(t);
            if (landedKey && settled && !(here && here.key === landedKey)) {
              landedKey = null;
              if (toastKind === 'landed') hideToast();
            }
            if (!isPlaying() || dragging || !settled || !d) return;
            g = skipAt(t);
            if (!g || undone[g.key] || g.key === landedKey) return;
            if (justSkipped && justSkipped.key === g.key && Date.now() - justSkipped.at < 1500) return;
            autoSkip(g, d);
          }

          window.onYouTubeIframeAPIReady = function () {
            player = new YT.Player('yt', { events: {
              onReady: function () {
                ready = true;
                clearTimeout(failTimer);
                muted = player.isMuted();
                captionsOff();
                if (pendingSeek !== null) { player.seekTo(pendingSeek, true); seeked(pendingSeek); player.playVideo(); pendingSeek = null; }
                setInterval(tick, 250);
                tick();
                update();
              },
              onStateChange: function (e) { setState(e.data); },
              onError: function (e) {
                if (e.data === 101 || e.data === 150) post({ type: 'blocked' }); else fail();
              }
            } });
          };

          // Double-tap skip (touch): the second tap on a side within TAP_GAP skips, and so does any tap on the
          // same side while the feedback from the last skip is still up (STREAK), adding to the total shown.
          var SKIP = 10, TAP_GAP = 260, STREAK = 700;
          var lastTap = null, tapTimer = 0, streak = null, skipTimer = 0;
          function skip(side) {
            if (!ready) return;
            var total = streak && streak.side === side ? streak.total + SKIP : SKIP;
            streak = { side: side, total: total };
            seekBy(side * SKIP);
            var el = $(side < 0 ? 'skipL' : 'skipR'), other = $(side < 0 ? 'skipR' : 'skipL');
            other.classList.remove('go');
            el.querySelector('b').textContent = total + ' seconds';
            el.classList.add('go');
            clearTimeout(skipTimer);
            skipTimer = setTimeout(function () { el.classList.remove('go'); streak = null; }, STREAK);
            hide();
          }
          function tap() {
            if (stage.classList.contains('show') && isPlaying()) hide(); else poke();
          }

          // Mouse: click plays or pauses, double-click is full screen. Touch: a tap shows or hides the bar.
          $('shield').addEventListener('click', function (e) {
            if (Date.now() - lastTouch < 800) return;
            toggle();
            poke();
          });
          $('shield').addEventListener('dblclick', fullscreen);
          $('shield').addEventListener('touchend', function (e) {
            e.preventDefault();
            lastTouch = Date.now();
            var r = this.getBoundingClientRect(), side = e.changedTouches[0].clientX < r.left + r.width / 2 ? -1 : 1;
            clearTimeout(tapTimer);
            if (ready && (lastTap === side || streak && streak.side === side)) { lastTap = null; skip(side); return; }
            if (lastTap !== null) tap();
            streak = null;
            lastTap = side;
            tapTimer = setTimeout(function () { lastTap = null; tap(); }, TAP_GAP);
          });
          stage.addEventListener('mousemove', function () { if (Date.now() - lastTouch > 800) poke(); });
          stage.addEventListener('mouseleave', function () { overBar = false; hide(); });
          $('bar').addEventListener('mouseenter', function () { overBar = true; update(); });
          $('bar').addEventListener('mouseleave', function () { overBar = false; poke(); });
          $('bar').addEventListener('touchstart', function () { lastTouch = Date.now(); poke(); }, { passive: true });

          function on(id, fn) {
            var el = $(id);
            if (!el) return;
            // A mouse click shouldn't leave focus on the button (Space would then press it again).
            el.addEventListener('mousedown', function (e) { e.preventDefault(); });
            el.addEventListener('click', function (e) { e.stopPropagation(); fn(); poke(); });
          }
          on('play', toggle);
          on('big', toggle);
          on('replay', toggle);
          on('mute', toggleMute);
          on('cc', toggleCaptions);
          on('speed', cycleSpeed);
          on('fs', fullscreen);
          on('tplay', toggle);
          on('tback', function () { skip(-1); });
          on('tfwd', function () { skip(1); });
          on('tcc', toggleCaptions);
          on('tspeed', cycleSpeed);
          on('tfs', fullscreen);
          on('tclose', fullscreen);
          if (TOUCH) $('tui').addEventListener('touchstart', function () { lastTouch = Date.now(); poke(); }, { passive: true });

          function bindTrack(tr) {
            function dragTo(e) {
              var r = tr.getBoundingClientRect();
              dragT = Math.max(0, Math.min(1, (e.clientX - r.left) / r.width)) * duration();
              if (Date.now() - lastSeek > 150) { lastSeek = Date.now(); player.seekTo(dragT, false); }
              render();
            }
            function endDrag() {
              if (!dragging) return;
              dragging = false;
              tr.classList.remove('drag');
              player.seekTo(dragT, true);
              seeked(dragT);
              render();
              poke();
            }
            tr.addEventListener('pointerdown', function (e) {
              if (!ready) return;
              e.preventDefault();
              dragging = true;
              tr.classList.add('drag');
              tr.setPointerCapture(e.pointerId);
              dragTo(e);
              update();
            });
            tr.addEventListener('pointermove', function (e) { if (dragging) dragTo(e); });
            tr.addEventListener('pointerup', endDrag);
            tr.addEventListener('pointercancel', endDrag);
          }
          bindTrack(track);
          if (TOUCH) bindTrack($('ttrack'));

          document.addEventListener('keydown', function (e) {
            if (e.metaKey || e.ctrlKey || e.altKey || failed) return;
            var tag = e.target && e.target.tagName;
            if (tag === 'BUTTON' && (e.key === ' ' || e.key === 'Enter')) return;
            switch (e.key) {
              case ' ': toggle(); break;
              case 'ArrowLeft': seekBy(-5); break;
              case 'ArrowRight': seekBy(5); break;
              case 'f': case 'F': fullscreen(); break;
              case 'm': case 'M': toggleMute(); break;
              case 'c': case 'C': toggleCaptions(); break;
              case 'Enter': if (!toastFn) return; toastAct(); break;
              case 'Escape': if (IN_COVER) fullscreen(); else return; break;
              default: return;
            }
            e.preventDefault();
            poke();
          });

          // The toast sits above the shield, so its button takes the taps itself; no focus on a mouse press.
          $('sbbtn').addEventListener('mousedown', function (e) { e.preventDefault(); });
          $('sbbtn').addEventListener('click', function (e) { e.stopPropagation(); toastAct(); });
          $('sbtop').addEventListener('touchstart', function () { lastTouch = Date.now(); }, { passive: true });

          window.odPlayer = {
            resume: function (t) {
              if (failed) return;
              if (!ready) { pendingSeek = t; return; }
              player.seekTo(t, true); seeked(t); player.playVideo();
            },
            toggle: function () { if (failed) return; toggle(); poke(); },
            seekBy: function (d) { if (failed) return; seekBy(d); poke(); },
            setSegments: setSegments,
            fail: fail
          };
          if (window.odPendingSegments) { setSegments(window.odPendingSegments); window.odPendingSegments = null; }
          render();
          update();
        })();
        </script>
        <script src="https://www.youtube.com/iframe_api" onerror="window.odPlayer.fail()"></script>
        </body></html>
        """#
    }
}
