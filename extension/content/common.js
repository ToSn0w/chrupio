/*
 * Chrupio shared content-script helpers.
 *
 * Loaded as a classic content script before meet.js / teams.js / slack.js,
 * and also importable from Node (tests) via module.exports.
 * The pure helpers (name cleaning, junk filtering, dedup, speaking-rate pick)
 * touch no DOM or chrome APIs. createSpeakingDetector() and createReporter()
 * are browser-only.
 *
 * In a call, a state message carries an optional `probe` at most every 30 s,
 * only when it changed, always < 4 KB. The worker forwards it unchanged as
 * `probe` on the "meeting" event so the app can store it for selector tuning:
 *   {v: 1, platform, tileCount,
 *    tiles: [{name, sel, recent, total}],  // top 8 by mutations; sel = selector that matched,
 *                                          // recent = in the last 1.5 s, total = since last probe
 *    attrs: [{name, count}],               // top 8 mutated attribute names since last probe
 *    generic: [names],                     // speakers picked by the mutation-rate detector
 *    active: [names],                      // activeSpeakers actually sent
 *    via: {strategy: count},               // scrapes in which each strategy found a speaker (Meet)
 *    extra?: object}                       // platform diagnostics (Slack: huddle sidebar mutations)
 *
 * A reporter given opts.snapshot also attaches `snapshot` (see domSnapshot) 15 s into a call and
 * every 5 min after, when that function returns one; the worker POSTs it to /v1/snapshot.
 */
(function (root) {
  'use strict';

  // ---------------------------------------------------------------- pure helpers

  // Exact (case-insensitive) strings that are UI chrome, never a person.
  const JUNK_EXACT = new Set([
    'all',
    'you', '(you)', 'me', '(me)', 'ty', '(ty)', 'du', 'tú', 'tu', 'vous', 'toi',
    'sie', 'jij', 'você', 'voce', 'voi', 'вы', 'ты', 'あなた', '自分', '你', '您', '나',
    'presentation', 'presenting', 'prezentacja', 'screen', 'screen share',
    'more options', 'more actions', 'więcej opcji', 'options', 'menu',
    'muted', 'unmuted', 'mute', 'unmute', 'mic off', 'mic on', 'microphone off',
    'microphone on', 'camera off', 'camera on', 'video off', 'video on',
    'wyciszony', 'wyciszona', 'wyciszono',
    'pin', 'unpin', 'pinned', 'remove', 'spotlight', 'raise hand', 'lower hand',
    'join', 'join now', 'ask to join', 'leave', 'leave call', 'hang up',
    'participants', 'people', 'everyone', 'chat', 'reactions', 'more',
    'guest', 'host', 'organizer', 'organiser', 'presenter', 'attendee',
    'in this call', 'in call', 'in the meeting', 'in meeting', 'waiting',
    'huddle', 'start huddle', 'leave huddle', 'invite', 'invite people',
    'speaking', 'is speaking', 'connecting', 'reconnecting', 'loading',
    'unknown', 'anonymous', 'unknown user', 'meeting', 'call', 'close',
    'show more', 'show less', 'see all', 'contributors', 'others', 'avatar',
    'profile picture', 'mic', 'camera', 'share', 'share screen', 'settings',
    'turn off camera', 'turn on camera', 'turn off microphone', 'turn on microphone',
    'everyone else', 'add people', 'view all', 'raised hand', 'hand raised',
    'spotlighted', 'companion', 'companion mode', 'meeting chat', 'captions',
    // Google Meet panels, effects and toolbar entries seen in tiles and rosters.
    'stickers', 'emoji', 'emojis', 'effects', 'visual effects', 'backgrounds',
    'backgrounds and effects', 'apply visual effects', 'filters', 'appearance',
    'send a reaction', 'reaction', 'hand raise', 'activities', 'polls', 'q&a',
    'breakout rooms', 'whiteboard', 'recording', 'transcript', 'transcripts',
    'gemini', 'take notes with gemini', 'meeting details', 'meeting tools',
    'host controls', 'present now', 'turn on captions', 'turn off captions',
    'change layout', 'adjust view', 'full screen', 'pin to screen', 'minimize',
    'framing', 'noise cancellation', 'info', 'unread', 'you are presenting',
    "you're presenting", 'call details', 'new meeting', 'meeting room',
    // Slack sidebar sections whose labels wrap member avatars.
    'all', 'channels and direct messages'
  ]);

  // Substrings / patterns that mark a string as a status line, not a name.
  const JUNK_PATTERNS = [
    // Slack emoji codes and lowercase slugs: raised_hand::skin-tone-2, acme-pl.
    /::/,
    /^[a-z0-9]+(?:[-_][a-z0-9]+)+$/,
    // Notetaker bots: "Fireflies.ai Notetaker Łukasz", "Diego's Grain Notetaker". Mirrors Meeting.botWords.
    /(?:^|[^\p{L}])(?:notetaker|fireflies|otter|grain|fathom)(?:$|[^\p{L}])/iu,
    /^[a-z]+(?:_[a-z0-9]+)+$/, // Material icon ligatures: mic_off, more_vert, frame_person
    /\bis (?:presenting|sharing)\b/i,
    /\b(?:'s|’s) (?:presentation|screen|content|window)\b/i,
    /^(?:content |screen )?shared by\b/i,
    /^(?:präsentation|presentación|présentation|apresentação|presentazione|prezentacja)\b/i,
    // Audio/video device names that leak into tiles and device pickers.
    /^(?:default|communications|standard|domyślny)\s*[-–:]/i,
    /\b(?:microphone|mikrofon|micrófono|speakers?|lautsprecher|głośnik\w*|altavoz|headset|headphones|airpods|webcam|built-in|bluetooth|virtual camera|blackhole)\b/i,
    /\bprezentuje\b/i,
    /\bmore options\b/i,
    /\b(?:has|have) (?:joined|left)\b/i,
    /\b(?:joined|left) the (?:call|meeting|huddle)\b/i,
    /\bmicrophone (?:is )?(?:off|on|muted)\b/i,
    /\b(?:camera|video) (?:is )?(?:off|on)\b/i,
    /\byour (?:microphone|camera|video|screen)\b/i,
    /\bclick to\b/i,
    /\bkeyboard shortcut\b/i,
    // Roster section headers: "In this meeting (3)", "Others invited (2)".
    /^(?:in this (?:meeting|call)|in the (?:meeting|call)|others invited|invited|attendees|presenters|suggestions|w tym spotkaniu|zaproszeni)\b/i,
    /^\+\s?\d+$/, // "+3" overflow avatars
    /^\d+$/, // bare counters
    /^\d+\s+(?:others?|more|participants?|people|osób|osoby)$/i,
    /^https?:\/\//i,
    // Slack sidebar and channel chrome that leaks into huddle scans.
    /^(?:channels?|kanały)\s+(?:and|i)\s+(?:direct messages|wiadomości bezpośrednie)$/i,
    /^(?:direct messages|wiadomości bezpośrednie|channels|kanały|threads|wątki|activity|aktywność|later|huddles)$/i,
    /^(?:channel|kanał)\b.*\((?:private|prywatny)\)$/i,
    /^(?:channel|kanał)\s+#/i,
    /^channel\s/i,
    /^(?:view|zobacz)\s.*\bprofil(?:e)?\b/i,
    /^[\p{P}\p{S}\s]+$/u // only punctuation/symbols
  ];

  // Parenthesised / trailing markers to strip from a display name.
  const SUFFIX_MARKERS = [
    'you', 'me', 'ty', 'du', 'vous', 'tú', 'tu', 'sie', 'jij', 'você', 'voi', 'вы', 'ты',
    'あなた', '自分', '你', '您', 'guest', 'gość', 'gast', 'invité', 'invitado', 'host',
    'organizer', 'organiser', 'organizator', 'organisator', 'presenter', 'external',
    'externe', 'zewnętrzny', 'unverified', 'co-host', 'cohost', 'meeting host',
    'presentation', 'presenting', 'prezentacja', 'präsentation', 'presentación',
    'présentation', 'apresentação', 'presentazione', 'companion', 'meeting room'
  ];
  const SUFFIX_RE = new RegExp(
    '\\s*[\\(\\[]\\s*(?:' + SUFFIX_MARKERS.map(escapeRe).join('|') + ')\\s*[\\)\\]]\\s*$',
    'i'
  );
  // Teams prints an unparenthesised "Unverified" after external accounts: "Marek Unverified".
  const BARE_SUFFIX_RE = /\s+(?:unverified|niezweryfikowany|niezweryfikowana|nicht verifiziert|non vérifié)$/i;
  const SELF_MARKERS = ['you', 'me', 'ty', 'du', 'vous', 'tú', 'tu', 'sie', 'jij', 'você', 'voi', 'вы', 'ты', 'あなた', '自分', '你', '您'];
  // Several markers may follow the self one: "Jane (You) (Guest)".
  const SELF_MARKER_RE = new RegExp(
    '[\\(\\[]\\s*(?:' + SELF_MARKERS.map(escapeRe).join('|') + ')\\s*[\\)\\]](?:\\s*[\\(\\[][^\\)\\]]*[\\)\\]])*\\s*$',
    'i'
  );

  const MAX_NAME_LENGTH = 80;
  // Real display names rarely have more than 4 words; UI sentences do.
  const MAX_NAME_WORDS = 4;

  function escapeRe(s) {
    return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  }

  /** Normalise a raw text/aria value into a candidate display name ('' if none). */
  function cleanName(raw) {
    if (raw == null) return '';
    let s = String(raw);
    // Zero-width / bidi control characters, NBSP.
    s = s.replace(/[​-‏‪-‮⁠-⁤﻿]/g, '');
    s = s.replace(/ /g, ' ');
    // First non-empty line only (tiles often contain "Name\nmic_off").
    const lines = s.split(/[\r\n]+/).map((l) => l.trim()).filter(Boolean);
    s = lines.length ? lines[0] : '';
    s = s.replace(/\s+/g, ' ').trim();
    // Strip trailing role markers repeatedly: "Jane (Guest) (You)".
    let prev;
    do {
      prev = s;
      s = s.replace(SUFFIX_RE, '').trim();
      s = s.replace(BARE_SUFFIX_RE, '').trim();
    } while (s !== prev);
    // Strip surrounding quotes.
    s = s.replace(/^["'“”‘’]+|["'“”‘’]+$/g, '').trim();
    // Slack DM huddle title: "Conversation with Piotr Sadowski" names the other person.
    s = s.replace(/^conversation with\s+/i, '').trim();
    return s;
  }

  /** True when the (already cleaned or raw) string is UI chrome, not a person. */
  function isJunkName(name) {
    const s = cleanName(name);
    if (!s) return true;
    if (s.length > MAX_NAME_LENGTH) return true;
    if (JUNK_EXACT.has(s.toLowerCase())) return true;
    for (const re of JUNK_PATTERNS) if (re.test(s)) return true;
    if (isSentenceLike(s)) return true;
    return false;
  }

  /**
   * True for UI sentences such as "Others might still see your full video.":
   * more than MAX_NAME_WORDS words, or a trailing "." after a word longer than
   * an abbreviation, so "Anna K." and "John Smith Jr." still pass.
   */
  function isSentenceLike(s) {
    const words = s.split(/\s+/).filter(Boolean);
    if (words.length > MAX_NAME_WORDS) return true;
    if (/[.!?…]$/.test(s)) {
      const last = words[words.length - 1].replace(/[.!?…]+$/, '');
      if (/[!?…]$/.test(s) || last.length > 3) return true;
    }
    return false;
  }

  /** True when the raw label marks the local user, e.g. "Jane Doe (You)". */
  function hasSelfMarker(raw) {
    if (raw == null) return false;
    const firstLine = String(raw).split(/[\r\n]+/).map((l) => l.trim()).filter(Boolean)[0] || '';
    return SELF_MARKER_RE.test(firstLine.replace(/ /g, ' '));
  }

  /** Clean, drop junk, dedupe case/diacritic-insensitively; keeps first spelling and order. */
  function dedupeNames(list) {
    const out = [];
    const seen = new Set();
    for (const raw of list || []) {
      const name = cleanName(raw);
      if (isJunkName(name)) continue;
      const key = nameKey(name);
      if (seen.has(key)) continue;
      seen.add(key);
      out.push(name);
    }
    return out;
  }

  function nameKey(name) {
    return cleanName(name)
      // camelCase run together: "PiotrMazur" keys as "piotr mazur".
      .replace(/(\p{Ll})(\p{Lu})/gu, '$1 $2')
      .normalize('NFKD')
      .replace(/[̀-ͯ]/g, '')
      .toLowerCase()
      // Letters NFKD does not decompose.
      .replace(/[łøđßæœı]/g, (c) => ({ ł: 'l', ø: 'o', đ: 'd', ß: 'ss', æ: 'ae', œ: 'oe', ı: 'i' })[c]);
  }

  /**
   * Extract the name from an aria-label like
   * "Jane Doe, Muted, Video off" / "Jane Doe is speaking" / "Jane Doe (You), camera off".
   */
  function nameFromAriaLabel(label) {
    if (label == null) return '';
    let s = String(label).replace(/ /g, ' ').trim();
    if (!s) return '';
    // Slack: "View Jane Doe’s Profile" / "View James' profile" / "Zobacz profil użytkownika Jan".
    const view = /^(?:view|zobacz)\s+(?:profil(?:e)?\s+(?:użytkownika\s+)?(.+?)|(.+?)['’]s?\s+profile)\s*$/i.exec(s);
    if (view) s = view[1] || view[2];
    // Comma / bullet / pipe separated status parts: keep the first.
    s = s.split(/\s*(?:,|·|•|\||;)\s*/)[0];
    // Trailing status verbs.
    s = s.replace(
      /\s+(?:is\s+)?(?:speaking|talking|presenting|sharing|muted|unmuted|mówi|prezentuje|udostępnia)\b.*$/i,
      ''
    );
    // Leading generic prefixes.
    s = s.replace(/^(?:participant|uczestnik|profile(?: picture)?(?: of| for)?|avatar(?: of| for)?|video of|tile for)\s*[:\-]?\s+/i, '');
    const n = cleanName(s);
    return n && !isJunkName(n) ? n : '';
  }

  /** Does the label indicate the person is currently speaking? */
  function labelSaysSpeaking(label) {
    if (!label) return false;
    const s = String(label);
    if (/\b(?:not|isn['’]t)\s+speaking\b/i.test(s)) return false;
    return /\b(?:is\s+)?(?:speaking|talking)\b|\bmówi\b|\bspricht\b|\bhabla\b|\bparle\b/i.test(s);
  }

  /**
   * Name from an account/avatar label, strictly: only "Profile picture of X",
   * "Account manager for X", "Avatar of X", Polish "użytkownika X".
   * Returns '' for labels like "Your profile picture with status displayed as Available".
   */
  function nameFromProfileLabel(label) {
    if (label == null) return '';
    const s = String(label).replace(/\u00a0/g, ' ').trim();
    const m = /(?:profile(?: picture| photo| image)?|avatar|account(?: manager)?|picture)\s+(?:of|for)\s+(.+)$/i.exec(s) ||
      /użytkownika\s+(.+)$/i.exec(s);
    if (!m) return '';
    const n = cleanName(m[1].split(/\s*(?:,|\.\s|\.$|·|\||;|\()\s*/)[0]);
    if (!n || isJunkName(n) || /^(?:your|you)\b/i.test(n)) return '';
    return n;
  }

  /**
   * Name encoded after a fixed prefix in an attribute, e.g. Teams roster
   * data-tid="participantsInCall-Jane Doe". Rejects ids (GUIDs, "8:orgid:…", emails).
   */
  function nameFromPrefixedAttr(value, prefix) {
    if (value == null || !prefix) return '';
    const v = String(value);
    if (v.slice(0, prefix.length).toLowerCase() !== prefix.toLowerCase()) return '';
    const rest = v.slice(prefix.length);
    if (!/\p{L}/u.test(rest)) return '';
    if (/[@:\/]/.test(rest)) return '';
    if (/^[0-9a-f]{8}-[0-9a-f]{4}-/i.test(rest) || /^[0-9a-f-]{16,}$/i.test(rest)) return '';
    const n = cleanName(rest);
    return n && !isJunkName(n) ? n : '';
  }

  /** Strip a short "User: " / "Użytkownik: " style prefix from a label. */
  function stripLabelPrefix(label) {
    if (label == null) return '';
    return String(label).replace(/^[^:\n]{1,30}:\s+/, '');
  }

  /** Remove app suffixes from a document/page title. */
  function cleanTitle(raw, suffixes) {
    if (raw == null) return null;
    let s = String(raw).replace(/\s+/g, ' ').trim();
    for (const suf of suffixes || []) {
      const re = suf instanceof RegExp ? suf : new RegExp('\\s*[|\\-–—]?\\s*' + escapeRe(suf) + '\\s*$', 'i');
      s = s.replace(re, '').trim();
    }
    s = s.replace(/^\(\d+\)\s*/, '').trim(); // "(3) Title" unread counters
    return s || null;
  }

  function sameList(a, b) {
    if (a === b) return true;
    if (!a || !b || a.length !== b.length) return false;
    for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) return false;
    return true;
  }

  /** Shallow structural equality for the state object (ignores ts). */
  function sameState(a, b) {
    if (!a || !b) return false;
    return (
      a.inMeeting === b.inMeeting &&
      a.title === b.title &&
      a.selfName === b.selfName &&
      a.url === b.url &&
      sameList(a.participants, b.participants) &&
      sameList(a.activeSpeakers, b.activeSpeakers)
    );
  }

  // ---------------------------------------------------------------- speaking activity (pure)

  const ACTIVITY_WINDOW_MS = 1500;
  const ACTIVITY_MIN_COUNT = 4; // attribute mutations within the window for a tile to count as animated

  /** How many of the ascending timestamps fall within (now - windowMs, now]. */
  function countRecent(times, now, windowMs) {
    const from = now - (windowMs || ACTIVITY_WINDOW_MS);
    let n = 0;
    for (let i = times.length - 1; i >= 0 && times[i] > from; i--) if (times[i] <= now) n++;
    return n;
  }

  /**
   * Keys of the tiles that look like they are speaking, from [key, count] pairs
   * (attribute mutations per tile over the window). Voice-level meters animate
   * only on the speaker, while hover/decoration animations move every tile alike,
   * so a tile speaks when it is at least minCount above the lower-median tile and
   * at least twice as busy. A lone tile has no baseline and is never picked.
   */
  function pickBusyTiles(counts, opts) {
    const minCount = (opts && opts.minCount) || ACTIVITY_MIN_COUNT;
    const list = (counts || []).filter((c) => c && Number.isFinite(c[1]));
    if (list.length < 2) return [];
    const sorted = list.map((c) => c[1]).sort((a, b) => a - b);
    // Every tile equally busy: decoration, not speech.
    if (sorted[0] >= minCount && sorted[sorted.length - 1] < 2 * sorted[0]) return [];
    const base = sorted[Math.floor((sorted.length - 1) / 2)];
    return list.filter((c) => c[1] - base >= minCount && c[1] >= 2 * base).map((c) => c[0]);
  }

  // ---------------------------------------------------------------- DOM helpers (browser only)

  /** querySelectorAll over several selectors; invalid selectors are skipped. */
  function queryAll(rootNode, selectors) {
    const out = [];
    const seen = new Set();
    for (const sel of selectors) {
      let nodes;
      try {
        nodes = rootNode.querySelectorAll(sel);
      } catch (_) {
        continue;
      }
      for (const n of nodes) {
        if (!seen.has(n)) {
          seen.add(n);
          out.push(n);
        }
      }
    }
    return out;
  }

  function queryFirst(rootNode, selectors) {
    for (const sel of selectors) {
      try {
        const n = rootNode.querySelector(sel);
        if (n) return n;
      } catch (_) {
        /* invalid selector */
      }
    }
    return null;
  }

  function isVisible(el) {
    if (!el || !el.isConnected) return false;
    if (el.getClientRects().length === 0) return false;
    const style = el.ownerDocument.defaultView.getComputedStyle(el);
    return style.visibility !== 'hidden' && style.display !== 'none';
  }

  /** Visible text of an element without descendant icon ligatures, first line. */
  function textOf(el) {
    if (!el) return '';
    return cleanName(el.innerText != null ? el.innerText : el.textContent);
  }

  /**
   * Find the most plausible name text inside a container: scans text-bearing
   * leaf elements and returns the first that is not junk.
   */
  function firstNameText(container) {
    if (!container) return '';
    const walker = container.ownerDocument.createTreeWalker(container, 4 /* SHOW_TEXT */);
    let node;
    while ((node = walker.nextNode())) {
      const parent = node.parentElement;
      if (!parent) continue;
      if (parent.closest('button,[role="button"],[aria-hidden="true"],i,svg,style,script')) continue;
      const name = cleanName(node.nodeValue);
      if (name && !isJunkName(name)) return name;
    }
    return '';
  }

  /** First selector of the list that the element matches ('' if none). */
  function matchedSelector(el, selectors) {
    for (const sel of selectors) {
      try {
        if (el.matches(sel)) return sel;
      } catch (_) {
        /* invalid selector */
      }
    }
    return '';
  }

  // ---------------------------------------------------------------- generic speaking detector (browser only)

  // Attribute names that carry voice-meter animation: class/style/data-*/aria-*, plus SVG geometry.
  const ACTIVITY_ATTRS = /^(?:class|style|data-.*|aria-.*|d|transform|points|r|height|width|x|y|opacity)$/;
  const MAX_TILES = 64;
  const MAX_TIMES = 120; // per tile, enough for 80 mutations/s over the window
  const MAX_RECORDS = 500; // per observer batch
  const MAX_DEPTH = 40; // ancestor walk from a mutated node to its tile
  const EVAL_MS = 250; // re-evaluate speakers from inside the observer at most this often

  /**
   * One MutationObserver over the subtrees of the current participant tiles.
   * Platforms call track([{el, name, sel}]) on each scrape; it returns the names
   * the mutation-rate rule (pickBusyTiles) considers speaking. onChange fires when
   * that set changes between scrapes, so a new speaker is sent without waiting.
   */
  function createSpeakingDetector(opts) {
    const windowMs = (opts && opts.windowMs) || ACTIVITY_WINDOW_MS;
    const onChange = opts && opts.onChange;
    let tiles = new Map(); // tile element -> {name, sel, times, total}
    let owner = new WeakMap(); // node -> tile element | null (cache of the ancestor walk)
    let attrCounts = new Map();
    let lastSig = '';
    let evalAt = 0;
    let dead = false;

    const observer = new MutationObserver(onRecords);

    function tileOf(node) {
      const path = [];
      let n = node;
      let found = null;
      for (let depth = 0; n && depth < MAX_DEPTH; depth++, n = n.parentNode) {
        if (tiles.has(n)) {
          found = n;
          break;
        }
        if (owner.has(n)) {
          found = owner.get(n);
          break;
        }
        path.push(n);
      }
      for (const p of path) owner.set(p, found);
      return found;
    }

    function onRecords(records) {
      if (dead) return;
      const now = Date.now();
      const count = Math.min(records.length, MAX_RECORDS);
      for (let i = 0; i < count; i++) {
        const r = records[i];
        const attr = r.attributeName;
        if (!attr || !ACTIVITY_ATTRS.test(attr)) continue;
        if (r.oldValue === r.target.getAttribute(attr)) continue; // re-set to the same value
        const el = tileOf(r.target);
        const t = el && tiles.get(el);
        if (!t) continue;
        t.times.push(now);
        if (t.times.length > MAX_TIMES) t.times.splice(0, t.times.length - MAX_TIMES);
        t.total++;
        attrCounts.set(attr, (attrCounts.get(attr) || 0) + 1);
      }
      if (onChange && now - evalAt >= EVAL_MS) {
        evalAt = now;
        const sig = speaking(now).join('\n');
        if (sig !== lastSig) {
          lastSig = sig;
          onChange();
        }
      }
    }

    function setTiles(list) {
      const next = new Map();
      for (const t of list || []) {
        if (!t || !t.el || !t.name || next.has(t.el)) continue;
        if (next.size >= MAX_TILES) break;
        const prev = tiles.get(t.el);
        next.set(t.el, prev ? Object.assign(prev, { name: t.name, sel: t.sel || prev.sel }) : { name: t.name, sel: t.sel || '', times: [], total: 0 });
      }
      let same = next.size === tiles.size;
      if (same) for (const el of next.keys()) if (!tiles.has(el)) same = false;
      tiles = next;
      if (same || dead) return;
      // Tile set changed: re-observe and drop the cached ancestor walks.
      observer.disconnect();
      owner = new WeakMap();
      for (const el of tiles.keys()) {
        try {
          observer.observe(el, { attributes: true, attributeOldValue: true, subtree: true });
        } catch (_) {
          /* detached node */
        }
      }
    }

    /** Names whose tile is busy now (deduped, in tile order). */
    function speaking(now) {
      const at = now || Date.now();
      const counts = [];
      for (const [el, t] of tiles) counts.push([el, countRecent(t.times, at, windowMs)]);
      const busy = new Set(pickBusyTiles(counts));
      const names = [];
      for (const [el, t] of tiles) if (busy.has(el) && !names.includes(t.name)) names.push(t.name);
      return names;
    }

    function track(list) {
      setTiles(list);
      const names = speaking(Date.now());
      lastSig = names.join('\n');
      return names;
    }

    /** Tuning snapshot (see the probe shape at the top); resets the since-last-probe counters. */
    function probe(limit) {
      const n = limit || 8;
      const now = Date.now();
      const rows = [];
      for (const t of tiles.values()) {
        rows.push({ name: String(t.name).slice(0, 40), sel: String(t.sel).slice(0, 60), recent: countRecent(t.times, now, windowMs), total: t.total });
        t.total = 0;
      }
      rows.sort((a, b) => b.total - a.total || b.recent - a.recent);
      const attrs = [...attrCounts].sort((a, b) => b[1] - a[1]).slice(0, n).map(([name, count]) => ({ name: name.slice(0, 40), count }));
      attrCounts = new Map();
      return { tileCount: tiles.size, tiles: rows.slice(0, n), attrs, generic: speaking(now) };
    }

    function stop() {
      dead = true;
      observer.disconnect();
      tiles = new Map();
    }

    return { track, speaking, probe, stop };
  }

  // ---------------------------------------------------------------- runtime loop (browser only)

  // ---------------------------------------------------------------- structure snapshot

  const SNAPSHOT_MAX_NODES = 1500;
  const SNAPSHOT_MAX_DEPTH = 30;

  function clip(v, n) {
    if (v == null) return undefined;
    const s = String(v).replace(/\s+/g, ' ').trim();
    if (!s) return undefined;
    return s.length > n ? s.slice(0, n) + '…' : s;
  }

  /**
   * Shape of the DOM under `roots` for selector tuning, sent when a call shows nobody's name:
   * tags, data-qa, class, role, aria-label, title, alt and other data-* attributes, plus the text of
   * short leaf elements (where tile names live). Subtrees matching `skip` (chat, threads, composer)
   * are marked, never read. Works on any element-like objects (tagName, getAttribute, attributes, children).
   */
  function domSnapshot(roots, opts) {
    const skip = (opts && opts.skip) || null;
    const maxNodes = (opts && opts.maxNodes) || SNAPSHOT_MAX_NODES;
    const maxDepth = (opts && opts.maxDepth) || SNAPSHOT_MAX_DEPTH;
    // opts.extra(el): more fields for a node, e.g. the member id behind an unlabelled avatar.
    const extra = (opts && opts.extra) || null;
    let count = 0;
    let truncated = false;
    function walk(el, depth) {
      if (count >= maxNodes) {
        truncated = true;
        return null;
      }
      count++;
      const node = { t: String(el.tagName || '').toLowerCase() };
      const attr = (name) => (el.getAttribute ? el.getAttribute(name) : null);
      if (skip && el.matches && el.matches(skip)) {
        node.qa = clip(attr('data-qa'), 80);
        node.skipped = true;
        return node;
      }
      const fields = { qa: ['data-qa', 80], cls: ['class', 160], role: ['role', 40], aria: ['aria-label', 120], title: ['title', 120], alt: ['alt', 80] };
      for (const [key, [name, n]] of Object.entries(fields)) {
        const v = clip(attr(name), n);
        if (v !== undefined) node[key] = v;
      }
      const data = {};
      for (const a of Array.from(el.attributes || [])) {
        if (/^data-/.test(a.name) && a.name !== 'data-qa') data[a.name] = clip(a.value, 40) || '';
      }
      if (Object.keys(data).length) node.data = data;
      if (extra) {
        try {
          for (const [k, v] of Object.entries(extra(el) || {})) if (v !== undefined && !(k in node)) node[k] = v;
        } catch (_) {
          /* best effort */
        }
      }
      const kids = Array.from(el.children || []);
      if (!kids.length) {
        const text = clip(el.textContent, 60);
        if (text && text.length <= 40) node.text = text;
      } else if (depth < maxDepth) {
        const c = [];
        for (const k of kids) {
          const w = walk(k, depth + 1);
          if (w) c.push(w);
        }
        if (c.length) node.c = c;
      } else {
        node.more = kids.length;
      }
      return node;
    }
    const out = [];
    for (const r of roots) {
      const w = walk(r, 0);
      if (w) out.push(w);
    }
    return { nodes: count, truncated, roots: out };
  }

  const PROBE_MAX_CHARS = 4000;

  /** JSON of the probe trimmed to fit maxChars (drops tile rows, then attrs), or null if it cannot fit. */
  function probeJson(probe, maxChars) {
    const max = maxChars || PROBE_MAX_CHARS;
    const p = Object.assign({}, probe, { tiles: (probe.tiles || []).slice(), attrs: (probe.attrs || []).slice() });
    let json = JSON.stringify(p);
    if (json.length > max && p.extra !== undefined) {
      delete p.extra; // diagnostics go first
      json = JSON.stringify(p);
    }
    while (json.length > max && (p.tiles.length || p.attrs.length)) {
      if (p.tiles.length) p.tiles.pop();
      else p.attrs.pop();
      json = JSON.stringify(p);
    }
    return json.length > max ? null : json;
  }

  /**
   * Starts observing the page and reporting state to the service worker.
   * `detect(speech)` must return {inMeeting, title, participants, activeSpeakers, selfName};
   * `speech` is the page's generic speaking detector (see createSpeakingDetector).
   * opts.pollAlways: scrape every POLL_MS even without DOM mutations in this document
   * (the call UI lives in a same-origin iframe the observer does not see).
   * opts.relay(): true on a page that only mirrors a call reported by another tab (Slack's pop-out
   * huddle window); its state goes out as kind 'relay' and background.js merges it into that call.
   */
  function createReporter(platform, detect, opts) {
    const pollAlways = !!(opts && opts.pollAlways);
    // opts.snapshot(state): structure snapshot (see domSnapshot) when the call shows nobody, else null.
    const snapshotOf = (opts && opts.snapshot) || null;
    const SNAPSHOT_FIRST_MS = 15000; // let the call UI settle after joining
    const SNAPSHOT_EVERY_MS = 300000;
    const TICK_MS = 250; // timer resolution; scraping is rate-limited below
    const POLL_MS = 1000; // max scrape rate for plain DOM churn
    const HEARTBEAT_MS = 1000; // resend unchanged in-call state this often (native timeout is 12 s)
    const IDLE_HEARTBEAT_MS = 30000; // unchanged not-in-call state: just keep the SW record fresh
    const SLACK_MS = 100; // timer jitter tolerated when checking intervals
    const PROBE_MS = 30000;
    // An unchanged probe still goes out this often, so a recording that started after the first one gets it.
    const PROBE_RESEND_MS = 120000;
    const relayOf = (opts && opts.relay) || null;
    // opts.probeExtra(): platform-specific diagnostics merged into the probe as `extra`.
    const probeExtraOf = (opts && opts.probeExtra) || null;
    const IDLE_POLL_MS = 5000; // outside a call, DOM churn is scraped at most this often
    let last = null;
    let knownSelf = null; // self name seen earlier on this page (e.g. Meet green room avatar)
    let lastSentAt = 0;
    let lastScrapeAt = 0;
    let lastProbeAt = 0;
    let lastProbeJson = '';
    let lastProbeSentAt = 0;
    let inCallSince = 0;
    let lastSnapshotAt = 0;
    let dirty = true;
    let urgent = false; // generic detector saw the speaker set change
    let dead = false;
    let observer = null;
    let timer = null;
    let speech = null;
    let generic = [];
    let viaCounts = {}; // strategy -> scrapes that found a speaker with it, since the last probe

    function send(msg) {
      if (dead) return;
      // chrome.runtime.id disappears when the extension is reloaded: stop quietly.
      if (!chrome.runtime || !chrome.runtime.id) {
        stop();
        return;
      }
      try {
        chrome.runtime.sendMessage(msg, () => {
          // Reading lastError silences "Receiving end does not exist" while the SW wakes.
          void chrome.runtime.lastError;
        });
      } catch (_) {
        // Extension was reloaded/uninstalled: this content script is orphaned.
        stop();
      }
    }

    // The detector sees only the tiles detect() hands it; wrap it to remember its pick for the probe.
    const tracker = {
      track(list) {
        generic = speech ? speech.track(list) : [];
        return generic;
      }
    };

    function scrape() {
      let s;
      generic = [];
      try {
        s = detect(tracker) || {};
      } catch (e) {
        s = { inMeeting: false };
      }
      const participants = dedupeNames(s.participants || []);
      let selfName = s.selfName ? cleanName(s.selfName) || null : null;
      if (selfName && isJunkName(selfName)) selfName = null;
      if (selfName) knownSelf = selfName;
      else selfName = knownSelf;
      if (selfName && !isJunkName(selfName) && s.inMeeting) {
        if (!participants.some((p) => nameKey(p) === nameKey(selfName))) participants.unshift(selfName);
      }
      const activeSpeakers = dedupeNames(s.activeSpeakers || []);
      // Which detection strategies found speakers (platforms that report it), counted for the probe.
      if (s.inMeeting && Array.isArray(s.via)) for (const v of s.via) viaCounts[v] = (viaCounts[v] || 0) + 1;
      return {
        platform,
        url: location.href,
        title: s.title ? cleanName(s.title) || null : null,
        inMeeting: !!s.inMeeting,
        participants: s.inMeeting ? participants : [],
        activeSpeakers: s.inMeeting ? activeSpeakers : [],
        selfName: selfName && !isJunkName(selfName) ? selfName : null
      };
    }

    function takeProbe(state, now) {
      if (!speech || !state.inMeeting || now - lastProbeAt < PROBE_MS) return null;
      lastProbeAt = now;
      const p = speech.probe(8);
      const via = viaCounts;
      viaCounts = {};
      let extra;
      try {
        extra = probeExtraOf ? probeExtraOf() || undefined : undefined;
      } catch (_) {
        extra = undefined;
      }
      const json = probeJson({ v: 1, platform, tileCount: p.tileCount, tiles: p.tiles, attrs: p.attrs, generic: p.generic, active: state.activeSpeakers, via, extra });
      if (!json || (json === lastProbeJson && now - lastProbeSentAt < PROBE_RESEND_MS)) return null;
      lastProbeJson = json;
      lastProbeSentAt = now;
      return JSON.parse(json);
    }

    function takeSnapshot(state, now) {
      if (!state.inMeeting) {
        inCallSince = 0;
        return null;
      }
      if (!inCallSince) inCallSince = now;
      if (!snapshotOf || now - inCallSince < SNAPSHOT_FIRST_MS || now - lastSnapshotAt < SNAPSHOT_EVERY_MS) return null;
      lastSnapshotAt = now;
      try {
        return snapshotOf(state) || null;
      } catch (_) {
        return null;
      }
    }

    function tick() {
      if (dead) return;
      const now = Date.now();
      const interval = last && last.inMeeting ? HEARTBEAT_MS : IDLE_HEARTBEAT_MS;
      const due = now - lastSentAt >= interval - SLACK_MS;
      const poll = last && last.inMeeting ? POLL_MS : IDLE_POLL_MS;
      if (!urgent && !due && !((dirty || pollAlways) && now - lastScrapeAt >= poll - SLACK_MS)) return;
      urgent = false;
      dirty = false;
      lastScrapeAt = now;
      const state = scrape();
      const changed = !sameState(state, last);
      if (changed || due) {
        last = state;
        lastSentAt = now;
        const probe = takeProbe(state, now);
        const snapshot = takeSnapshot(state, now);
        let relay = false;
        try {
          relay = !!(relayOf && relayOf());
        } catch (_) {
          relay = false;
        }
        const msg = { kind: relay ? 'relay' : 'state', state, changed, ts: now };
        if (probe) msg.probe = probe;
        if (snapshot) msg.snapshot = snapshot;
        send(msg);
      }
    }

    function stop() {
      dead = true;
      if (observer) observer.disconnect();
      if (speech) speech.stop();
      if (timer) clearInterval(timer);
    }

    speech = createSpeakingDetector({
      onChange: () => {
        urgent = true;
        tick();
      }
    });
    observer = new MutationObserver(() => {
      dirty = true;
    });
    observer.observe(document.documentElement, {
      childList: true,
      subtree: true,
      attributes: true,
      attributeFilter: ['aria-label', 'data-participant-id', 'data-self-name', 'data-tid', 'data-qa', 'class', 'aria-pressed']
    });
    timer = setInterval(tick, TICK_MS);
    window.addEventListener('pagehide', () => {
      let relay = false;
      try {
        relay = !!(relayOf && relayOf());
      } catch (_) {
        relay = false;
      }
      send({ kind: relay ? 'relayGone' : 'gone', platform, ts: Date.now() });
    });
    window.addEventListener('popstate', () => (dirty = true));
    tick();

    // False once this copy is orphaned by an extension update, so a fresh copy can take over.
    const alive = () => !dead && !!(chrome.runtime && chrome.runtime.id);
    return { stop, scrape, alive };
  }

  const api = {
    cleanName,
    isJunkName,
    hasSelfMarker,
    dedupeNames,
    nameKey,
    nameFromAriaLabel,
    labelSaysSpeaking,
    nameFromProfileLabel,
    nameFromPrefixedAttr,
    stripLabelPrefix,
    cleanTitle,
    sameState,
    countRecent,
    pickBusyTiles,
    probeJson,
    domSnapshot,
    queryAll,
    queryFirst,
    isVisible,
    textOf,
    firstNameText,
    matchedSelector,
    createSpeakingDetector,
    createReporter
  };

  root.Chrupio = Object.assign(root.Chrupio || {}, api);
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
