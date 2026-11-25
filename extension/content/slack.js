/* Chrupio: Slack huddle scraper (app.slack.com). Depends on content/common.js. */
(function (root) {
  'use strict';
  const OK = root.Chrupio || (typeof require === 'function' ? require('./common.js') : null);

  // ---------------------------------------------------------------- pure parsing (tested in Node)

  // "Huddle with Jane Doe and Bob Smith", "3 people in the huddle: Jane, Bob and you",
  // "Jane Doe, Bob Smith and 2 others are in this huddle".
  const HUDDLE_LIST_PATTERNS = [
    /huddle\s+with\s+(.+)$/i,
    /(?:people|participants|members|osoby|uczestnicy)\s+in\s+(?:the\s+|this\s+)?huddle\s*:\s*(.+)$/i,
    /huddle\s*(?:participants|members)?\s*:\s*(.+)$/i,
    /^(.+?)\s+(?:are|is)\s+in\s+(?:the|this)\s+huddle\b/i
  ];

  /** Names listed in a huddle summary label; [] for "Huddle in #general" or no list. */
  function huddleNamesFromLabel(label) {
    if (label == null) return [];
    const s = String(label).replace(/ /g, ' ').replace(/\s+/g, ' ').trim();
    // "Start a huddle with Jane" / "Join huddle with …" are invitations, not attendance.
    if (/^(?:start|join|begin|invite|rozpocznij|dołącz)\b/i.test(s)) return [];
    for (const re of HUDDLE_LIST_PATTERNS) {
      const m = re.exec(s);
      if (!m) continue;
      const out = [];
      for (const part of m[1].split(/\s*(?:,|;|&|\band\b|\boraz\b)\s*/i)) {
        const n = OK.cleanName(part.replace(/\.$/, ''));
        if (!n || n.startsWith('#') || OK.isJunkName(n) || /\bhuddle\b/i.test(n)) continue;
        if (/^\d+\s+\w+$/.test(n)) continue; // "2 others" in any wording
        out.push(n);
      }
      return OK.dedupeNames(out);
    }
    return [];
  }

  const SLACK_ID_RE = /^[UWB][A-Z0-9]{7,}\b/; // member ids (U01ABCDEF12), not names

  /**
   * Name of a huddle participant from its attributes, most specific first:
   * {ariaLabel, title, alt, qaName, dataQa}. Returns {name, label} or null.
   */
  function participantFromAttrs(a) {
    if (!a) return null;
    const qa = OK.nameFromPrefixedAttr(a.dataQa, 'huddle_participant_') || OK.nameFromPrefixedAttr(a.dataQa, 'huddle-participant-');
    if (qa && !SLACK_ID_RE.test(qa)) return { name: qa, label: a.ariaLabel || qa };
    for (const raw of [a.ariaLabel, a.title, a.qaName, a.alt]) {
      if (!raw || /\bhuddle\b/i.test(raw)) continue; // controls and summaries, not one person
      const n = OK.nameFromProfileLabel(raw) || OK.nameFromAriaLabel(raw);
      if (n && !OK.isJunkName(n)) return { name: n, label: raw };
    }
    return null;
  }

  /**
   * Name on a huddle video tile (Slack 2026 grid, `.p-huddle_peer_tile`): its "View Jane Doe's profile" label,
   * then the screen-reader description ("Jane Doe, audio is on"), then its first short text.
   */
  function peerTileName(t) {
    if (!t) return '';
    for (const raw of [t.ariaLabel, ...(t.labels || [])]) {
      const m = raw && /^\s*(?:View|Zobacz)\s+(?:profil(?:e)?\s+(?:użytkownika\s+)?)?(.+?)(?:['’]s?\s+profile)?\s*$/i.exec(raw);
      if (m && /profil/i.test(raw)) {
        const n = OK.cleanName(m[1]);
        if (n && !OK.isJunkName(n)) return n;
      }
    }
    for (const raw of [t.description, t.text]) {
      if (!raw) continue;
      const n = OK.cleanName(String(raw).split(/\s*(?:,|·|\|)\s*/)[0].replace(/\s*\((?:you|ty)\)$/i, ''));
      if (n && n.length <= 60 && !OK.isJunkName(n) && !/\b(?:audio|video|huddle|muted)\b/i.test(n)) return n;
    }
    return '';
  }

  // Avatar URLs carry the member id: https://ca.slack-edge.com/T0ABCDEF1-U05ABCDEF12-0123abcd4567-48.
  const AVATAR_ID_RE = /slack-edge\.com\/[TE][A-Z0-9]{6,}-([UW][A-Z0-9]{6,})-/;

  /** Slack member id from an avatar image URL, or null. */
  function userIdFromAvatarSrc(src) {
    const m = AVATAR_ID_RE.exec(String(src || ''));
    return m ? m[1] : null;
  }

  // Screen-reader announcements in the huddle's live region: "Jane Doe joined the huddle".
  const ANNOUNCEMENTS = [
    [/^(.+?)\s+(?:has\s+)?joined(?:\s+the)?(?:\s+huddle)\b/i, 'joined'],
    [/^(.+?)\s+(?:has\s+)?left(?:\s+the)?(?:\s+huddle)\b/i, 'left'],
    [/^(.+?)\s+dołączył[aoy]?\s+do\s+(?:huddle|spotkania|rozmowy)\b/i, 'joined'],
    [/^(.+?)\s+opuścił[aoy]?\s+(?:huddle|spotkanie|rozmowę)\b/i, 'left'],
    [/^(.+?)\s+(?:is\s+)?(?:speaking|talking)\b/i, 'speaking'],
    [/^(.+?)\s+mówi\b/i, 'speaking']
  ];

  /** {kind: 'joined'|'left'|'speaking', name} from one live-region announcement, or null. */
  function parseAnnouncement(text) {
    const s = String(text == null ? '' : text).replace(/\u00a0/g, ' ').replace(/\s+/g, ' ').trim();
    if (!s || s.length > 160) return null;
    for (const [re, kind] of ANNOUNCEMENTS) {
      const m = re.exec(s);
      if (!m) continue;
      const name = OK.cleanName(m[1]);
      if (!name || OK.isJunkName(name) || /\bhuddle\b/i.test(name) || /^(?:you|ty)$/i.test(name)) return null;
      return { kind, name };
    }
    return null;
  }

  /**
   * True for a page that shows only the huddle: the pop-out huddle window Slack opens with window.open
   * (about:blank, filled by the client tab) or a /huddle/ page without the client around it. Such a page
   * relays what it sees to the client tab's call instead of reporting a call of its own.
   */
  function isHuddleWindowPage(href, hasClientChrome) {
    if (/^about:/i.test(String(href || ''))) return true;
    if (hasClientChrome) return false;
    try {
      return /^\/huddles?(?:\/|$)/i.test(new URL(href).pathname);
    } catch (_) {
      return false;
    }
  }

  /**
   * Label naming the person behind an avatar image: its alt, else the label of an ancestor at most
   * 2 levels up that is not a control and wraps exactly this one avatar. Wider labelled hosts are
   * sidebar sections ("All", "Channels and direct messages"), not a person.
   * hosts: [{label, control, avatars}] for the parent and grandparent, nearest first.
   */
  function avatarLabel(alt, hosts) {
    if (alt) return alt;
    for (const h of (hosts || []).slice(0, 2)) {
      if (!h || !h.label) continue;
      return !h.control && h.avatars === 1 ? h.label : '';
    }
    return '';
  }

  /**
   * Stores id -> name in `users` (a Map kept newest-last). Junk names and member ids are dropped;
   * a weak source (avatar labels) never replaces a name already stored. True when the map changed.
   */
  function rememberUserIn(users, id, raw, weak, max) {
    if (!id || !/^[UW][A-Z0-9]{6,}$/.test(id)) return false;
    const name = OK.cleanName(String(raw || '').replace(/^@/, ''));
    if (!name || OK.isJunkName(name) || SLACK_ID_RE.test(name)) return false;
    const stored = users.get(id);
    if (stored === name) return false;
    if (stored && weak) return false;
    users.delete(id); // newest last, so the cap drops the oldest
    users.set(id, name);
    while (users.size > (max || 2000)) users.delete(users.keys().next().value);
    return true;
  }

  /**
   * class, data-qa, aria-label and style of each tile and its descendants to depth 3, for finding the
   * speaking marker. Every known name (longest first, case-insensitive) becomes name-1, name-2, ... in
   * aria-labels, whose remaining words outside a UI-state allowlist become w; no text, alt or title is read. Works on element-like objects (tagName, getAttribute, children).
   */
  function tileStructure(tiles, names, maxDepth) {
    const depthLimit = maxDepth === undefined ? 3 : maxDepth;
    const known = [...new Set((names || []).map((n) => String(n || '').trim()).filter((n) => n.length >= 2))].sort((a, b) => b.length - a.length);
    const aliases = new Map();
    const escape = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    function pseudonymize(label) {
      let out = label;
      for (const n of known) {
        const re = new RegExp(escape(n), 'gi');
        if (!re.test(out)) continue;
        const key = n.toLowerCase();
        if (!aliases.has(key)) aliases.set(key, 'name-' + (aliases.size + 1));
        out = out.replace(re, aliases.get(key));
      }
      return out;
    }
    // aria-label words outside a small UI-state allowlist (and the name-N aliases) become "w", so names not yet known never leak.
    const ARIA_WORDS = new Set(['speaking', 'talking', 'muted', 'unmuted', 'mic', 'microphone', 'camera', 'video', 'on', 'off', 'is', 'are', 'and', 'active', 'screen', 'sharing', 'presenting', 'raised', 'hand', 'avatar', 'huddle', 'you']);
    const scrubAria = (v) => pseudonymize(v).replace(/name-\d+|[\p{L}\p{N}_]+/gu, (w) => (/^name-\d+$/.test(w) || ARIA_WORDS.has(w.toLowerCase()) ? w : 'w'));
    // style may carry background-image avatar URLs with workspace and user ids: drop every url(...).
    const scrub = (v) => pseudonymize(v).replace(/url\([^)]*\)/gi, 'url()').replace(/https?:\/\/\S+/gi, 'url');
    let budget = 200;
    function walk(el, depth) {
      budget -= 1;
      const attr = (name) => {
        const v = el.getAttribute ? el.getAttribute(name) : null;
        return v === null || v === undefined || v === '' ? undefined : String(v);
      };
      const node = { t: String(el.tagName || '').toLowerCase() };
      const cls = attr('class');
      const qa = attr('data-qa');
      const aria = attr('aria-label');
      const style = attr('style');
      if (cls) node.cls = scrub(cls).slice(0, 160);
      if (qa) node.qa = scrub(qa).slice(0, 80);
      if (aria) node.aria = scrubAria(aria).slice(0, 120);
      if (style) node.style = scrub(style).slice(0, 160);
      const kids = Array.from(el.children || []);
      if (kids.length && depth < depthLimit) {
        node.c = [];
        for (const k of kids.slice(0, 12)) {
          if (budget <= 0) break;
          node.c.push(walk(k, depth + 1));
        }
      }
      return node;
    }
    const out = [];
    for (const t of Array.from(tiles || [])) {
      if (budget <= 0) break;
      out.push(walk(t, 0));
    }
    return out;
  }

  if (typeof module !== 'undefined' && module.exports) {
    module.exports = { huddleNamesFromLabel, participantFromAttrs, peerTileName, userIdFromAvatarSrc, parseAnnouncement, isHuddleWindowPage, avatarLabel, rememberUserIn, tileStructure };
    return;
  }

  // ---------------------------------------------------------------- browser
  //
  // Slack web shows a running huddle in up to three places, and which ones exist depends on how the user
  // opened it: the bottom bar and channel header in the client tab (avatars only, names in hover tooltips),
  // the huddle window Slack pops out with window.open (video grid, captions, the people list), and the
  // full-screen huddle view inside the client. Participants and speakers come from every strategy that
  // finds something, strongest first:
  //   tile      grid tiles (".p-huddle_peer_tile") with their active-speaker overlay
  //   label     aria-labels/titles on huddle avatars, rows and summaries ("Huddle with Jane and Bob")
  //   avatar    avatar images whose member id (in the image URL) has a name elsewhere on the page
  //             (message senders, @mentions, labelled avatars), remembered across pages
  //   announce  the huddle's screen-reader live region ("Jane Doe joined the huddle")
  //   generic   the avatar or tile whose subtree mutates much more than the others (voice-level ring)
  // The pop-out window relays its state to the client tab's call (see background.js) instead of
  // reporting a call of its own.

  // match_about_blank also lands in Slack's blank iframes (embeds, print frames); only a top-level blank
  // page can be the huddle window.
  if (window.top !== window && /^about:/i.test(location.href)) return;

  // Injected again after an extension update; a reporter from the old version has stopped.
  const running = window.__chrupioSlack;
  if (running && typeof running.alive === 'function' && running.alive()) return;
  window.__chrupioSlack = { alive: () => true };

  // Controls only present while a huddle is active for this user.
  const LEAVE_SELECTORS = [
    '[data-qa="huddle_toolbar__leave_button"]',
    '[data-qa="huddle_channel_header_button__leave_button"]',
    '[data-qa="huddle_mini_player_leave_button"]',
    '[data-qa="huddle_leave_button"]',
    '[data-qa="huddle-leave-button"]',
    '[data-qa*="huddle"][data-qa*="leave"]',
    '[data-qa*="huddle"] [data-qa*="leave"]',
    'button[aria-label*="Leave huddle" i]',
    'button[aria-label*="Huddle verlassen" i]',
    'button[aria-label*="Quitter le huddle" i]',
    'button[aria-label*="Salir de la huddle" i]',
    'button[aria-label*="Sair da huddle" i]',
    'button[aria-label*="Opuść huddle" i]',
    'button[aria-label*="Opuść spotkanie" i]'
  ];

  // Huddle UI roots (bottom bar, channel header, mini player, huddle window). Trusted for in-call detection.
  const HUDDLE_ROOT_SELECTORS = [
    '[data-qa="huddle_grid_component"]',
    '[data-qa="huddle_bottom_bar_content"]',
    '[data-qa="huddle_toolbar_buttons_center"]',
    '[data-qa="huddle_sidebar_footer"]',
    '[data-qa="huddle_sidebar_footer_container"]',
    '[data-qa="huddle_footer"]',
    '[data-qa="huddle_mini_player"]',
    '[data-qa="huddle_window"]',
    '[data-qa*="huddle_participant_list"]',
    '[data-qa*="huddle"][role="dialog"]',
    '[class*="p-huddle"][role="dialog"]',
    '[class*="p-huddle"]'
  ];

  // Broader containers searched for participants only (never for in-call detection).
  const LOOSE_ROOT_SELECTORS = [
    '[data-qa*="huddle" i]',
    '[class*="huddle" i]',
    '[aria-label*="huddle" i]'
  ];

  // The client around a huddle; a page without it is the pop-out huddle window.
  const CLIENT_CHROME = '[data-qa="channel_sidebar"], [data-qa="message_pane"], .p-client_workspace, .p-client';
  // A root containing these is the whole client, not a huddle widget.
  const TOO_BROAD = '[data-qa="message_pane"], [data-qa="channel_sidebar"], [data-qa="slack_kit_list"]';
  const CONTROL = 'button, a, input, [role="button"], [role="menuitem"], [role="tab"]';
  // Chat/thread rows inside the huddle window would otherwise yield message authors.
  const MESSAGE_AREA = '[data-qa*="message"], [role="log"], [data-qa*="thread"], [data-qa*="composer"]';
  const SKIP_CONTROLS = '[data-qa*="leave"], [data-qa*="mute"], [data-qa*="invite"], [data-qa*="toggle"], [data-qa*="share"]';

  // Elements trusted to hold a name in their text as well as their attributes.
  const PARTICIPANT_SELECTORS = [
    '[data-qa*="huddle_participant"]',
    '[data-qa*="huddle-participant"]',
    '[data-qa*="participant" i]',
    '[class*="huddle_participant"]',
    '[class*="participant" i]',
    '[class*="p-huddle_member" i]',
    '[class*="huddle_people" i] [role="listitem"]'
  ];
  // Avatars and generic rows: attribute-borne names only.
  const AVATAR_SELECTORS = [
    '[data-qa*="participant_avatar"]',
    '[class*="p-huddle_avatar"]',
    '[class*="avatar" i][aria-label]',
    '[class*="avatar" i][title]',
    'img[alt]',
    '[data-qa*="member" i][aria-label]',
    '[role="listitem"]'
  ];
  const TILE_CONTAINER = '[data-qa*="participant" i], [class*="participant" i], [class*="tile" i]';
  const MAX_ROOTS = 20;
  const MAX_ELEMENTS = 300;

  const SPEAKING_SELECTORS = [
    '[data-qa*="speaking"]',
    '[class*="speaking" i]:not([class*="not_speaking" i]):not([class*="not-speaking" i]):not([class*="nonspeaking" i])',
    '[class*="talking" i]',
    '[data-speaking="true"]',
    '[data-is-speaking="true"]',
    '[class*="active_speaker" i]',
    '[class*="active-speaker" i]',
    '[class*="activeSpeaker" i]'
  ];

  const SPEAKING_ANY = SPEAKING_SELECTORS.join(', ');

  // Slack's 2026 huddle grid: one tile per person, a child overlay only while that person speaks.
  // Attribute forms first; the gridcell id is the one hook seen on the self tile in 484EE0B7.
  const PEER_TILE = '[data-qa^="huddle_peer_tile_userId_"], [data-qa*="huddle_peer_tile" i], .p-huddle_peer_tile, [role="gridcell"][id^="huddle-grid-gridcell-"]';
  const ACTIVE_SPEAKER = [
    '.p-huddle_peer_tile__overlay--active_speaker',
    '[class*="peer_tile"][class*="active_speaker"]',
    '[data-qa*="active_speaker" i]',
    '[data-active-speaker="true"]',
    '[aria-label*="is speaking" i]',
    '[aria-label*=" mówi" i]'
  ].join(', ');
  const SELF_TILE = '[id^="huddle-grid-gridcell-self_"]';
  // Names of people who spoke (captions, event log) and the compact player's avatars.
  const SPOKEN_NAMES = '.p-huddle_closed_caption_event__member_name, .p-huddle_event_log__member_name, [class*="closed_caption"] [class*="member_name"]';
  // Avatar stacks in the bottom bar, channel header and sidebar; the image URL carries the member id.
  const AVATAR_STACK = '[data-qa="huddle_avatar_stack__member"], [class*="p-huddle_avatar_stack__avatar"]';
  // Screen-reader live regions; Slack announces joins and leaves there.
  const LIVE_REGION = '[role="status"], [role="alert"], [aria-live="polite"], [aria-live="assertive"]';

  // Where member ids meet names elsewhere on the page.
  const SENDER = '[data-message-sender]';
  const MENTION = '[data-member-id]';
  const SELF_BUTTON = '[data-qa="user-button"]';

  // ------------------------------------------------ member directory (id -> name), kept in chrome.storage.local

  // Renamed from 'slackUsers', which avatar labels had filled with sidebar section names.
  const USERS_KEY = 'slackUsers2';
  const OLD_USERS_KEY = 'slackUsers';
  const MAX_USERS = 2000;
  const LEARN_MS = 10000;
  const SAVE_MS = 60000;
  const users = new Map();
  let usersChanged = false;
  let learnedAt = 0;
  let savedAt = 0;

  try {
    chrome.storage.local.get([USERS_KEY, OLD_USERS_KEY]).then((r) => {
      for (const [id, name] of Object.entries((r && r[USERS_KEY]) || {})) if (!users.has(id) && typeof name === 'string') rememberUserIn(users, id, name, true, MAX_USERS);
      if (r && r[OLD_USERS_KEY]) chrome.storage.local.remove(OLD_USERS_KEY).catch(() => {});
    }, () => {});
  } catch (_) {
    /* no storage in this context */
  }

  function rememberUser(id, raw, weak) {
    if (rememberUserIn(users, id, raw, weak, MAX_USERS)) usersChanged = true;
  }

  const AVATAR_IMG = 'img[src*="slack-edge.com"]';

  function hostInfo(el) {
    if (!el || el.nodeType !== 1) return null;
    const label = el.getAttribute('aria-label') || el.getAttribute('title') || '';
    if (!label) return { label: '' };
    return { label, control: el.matches(CONTROL), avatars: el.querySelectorAll(AVATAR_IMG).length };
  }

  /** Names for member ids from message senders, @mentions and labelled avatars; bounded, every 10 s. */
  function learnUsers(selfName, now) {
    if (now - learnedAt < LEARN_MS) return;
    learnedAt = now;
    let budget = 600;
    for (const el of document.querySelectorAll(SENDER)) {
      if (--budget < 0) break;
      rememberUser(el.getAttribute('data-message-sender'), el.textContent);
    }
    for (const el of document.querySelectorAll(MENTION)) {
      if (--budget < 0) break;
      rememberUser(el.getAttribute('data-member-id'), el.getAttribute('data-member-label') || el.textContent);
    }
    for (const img of document.querySelectorAll(AVATAR_IMG)) {
      if (--budget < 0) break;
      const id = userIdFromAvatarSrc(img.getAttribute('src'));
      if (!id) continue;
      const parent = img.parentElement;
      const label = avatarLabel(img.getAttribute('alt'), [hostInfo(parent), hostInfo(parent && parent.parentElement)]);
      const p = label ? participantFromAttrs({ alt: label, ariaLabel: label }) : null;
      if (p) rememberUser(id, p.name, true);
    }
    // The account button's avatar is the local user's.
    const selfImg = document.querySelector(SELF_BUTTON + ' img[src*="slack-edge.com"]');
    if (selfImg && selfName) rememberUser(userIdFromAvatarSrc(selfImg.getAttribute('src')), selfName);
    if (usersChanged && now - savedAt >= SAVE_MS) {
      savedAt = now;
      usersChanged = false;
      try {
        chrome.storage.local.set({ [USERS_KEY]: Object.fromEntries(users) }).catch(() => {});
      } catch (_) {
        /* extension reloaded */
      }
    }
  }

  // ------------------------------------------------ live-region announcements

  const announced = new Map(); // nameKey -> name of people the live region said joined (and not left)
  let announcedSpeaker = null; // {name, at}
  let announceCount = 0;
  const regionTexts = new WeakMap();
  let lastInMeeting = false;

  function readAnnouncement(region) {
    const text = (region.textContent || '').trim();
    if (!text || regionTexts.get(region) === text) return;
    regionTexts.set(region, text);
    if (region.closest(MESSAGE_AREA)) return;
    for (const line of text.split(/[\r\n]+|(?<=\.)\s+/)) {
      const a = parseAnnouncement(line);
      if (!a) continue;
      announceCount++;
      const key = OK.nameKey(a.name);
      if (a.kind === 'joined') announced.set(key, a.name);
      else if (a.kind === 'left') announced.delete(key);
      else announcedSpeaker = { name: a.name, at: Date.now() };
    }
  }

  const liveObserver = new MutationObserver((records) => {
    if (!lastInMeeting) return;
    const n = Math.min(records.length, 300);
    for (let i = 0; i < n; i++) {
      const t = records[i].target;
      const el = t && (t.nodeType === 1 ? t : t.parentElement);
      const region = el && el.closest && el.closest(LIVE_REGION);
      if (region) readAnnouncement(region);
    }
  });
  // Attached only during a call: characterData on the whole document is costly while idle.
  const LIVE_OPTIONS = { childList: true, subtree: true, characterData: true };
  let liveAttached = false;
  function setLiveObserving(on) {
    if (on === liveAttached) return;
    liveAttached = on;
    if (!on) {
      liveObserver.disconnect();
      announced.clear();
      announcedSpeaker = null;
      return;
    }
    for (const d of pipDoc ? [document, pipDoc] : [document]) {
      try {
        liveObserver.observe(d.documentElement, LIVE_OPTIONS);
      } catch (_) {
        /* no document yet */
      }
    }
  }

  // ------------------------------------------------ huddle sidebar diagnostics (sent in the probe)

  const SIDEBAR_FOOTER = '[data-qa="huddle_sidebar_footer"], [class*="p-huddle_sidebar_footer"]';
  const sidebar = { el: null, added: 0, removed: 0, classChanges: new Map() };
  const sidebarObserver = new MutationObserver((records) => {
    for (const r of records) {
      if (r.type === 'childList') {
        sidebar.added += r.addedNodes.length;
        sidebar.removed += r.removedNodes.length;
      } else if (r.type === 'attributes' && r.target.nodeType === 1) {
        const cls = String(r.target.getAttribute('class') || '').slice(0, 100);
        if (sidebar.classChanges.size < 20 || sidebar.classChanges.has(cls)) sidebar.classChanges.set(cls, (sidebar.classChanges.get(cls) || 0) + 1);
      }
    }
  });

  function watchSidebar(on) {
    const el = on ? document.querySelector(SIDEBAR_FOOTER) : null;
    if (el === sidebar.el) return;
    sidebarObserver.disconnect();
    sidebar.el = el;
    if (el) sidebarObserver.observe(el, { childList: true, subtree: true, attributes: true, attributeFilter: ['class'] });
  }

  function sidebarProbe() {
    if (!sidebar.el) return null;
    const out = {
      sidebar: {
        avatars: sidebar.el.querySelectorAll(AVATAR_STACK).length,
        added: sidebar.added,
        removed: sidebar.removed,
        classes: [...sidebar.classChanges].sort((a, b) => b[1] - a[1]).slice(0, 8).map(([cls, count]) => ({ cls, count }))
      }
    };
    sidebar.added = 0;
    sidebar.removed = 0;
    sidebar.classChanges.clear();
    return out;
  }

  // "Bring huddle to front" can move the huddle into a Document Picture-in-Picture window owned by this
  // tab. That window gets no content script, but its document is reachable from here.
  let pipDoc = null;
  function docs() {
    let d = null;
    try {
      const w = window.documentPictureInPicture && window.documentPictureInPicture.window;
      d = (w && w.document) || null;
    } catch (_) {
      d = null;
    }
    if (d !== pipDoc) {
      pipDoc = d;
      if (d && liveAttached) {
        try {
          liveObserver.observe(d.documentElement, LIVE_OPTIONS);
        } catch (_) {
          /* window closing */
        }
      }
    }
    return d ? [document, d] : [document];
  }

  function queryDocs(selectors) {
    const out = [];
    for (const d of docs()) out.push(...OK.queryAll(d, selectors));
    return out;
  }

  // ------------------------------------------------ detection

  function hasClientChrome() {
    return !!document.querySelector(CLIENT_CHROME);
  }

  function huddleWindow() {
    return isHuddleWindowPage(location.href, hasClientChrome());
  }

  function huddleRoots() {
    return queryDocs(HUDDLE_ROOT_SELECTORS);
  }

  /** Narrow plus loose roots, outermost only, without whole-client containers. */
  function participantRoots() {
    const all = [];
    for (const el of queryDocs([...HUDDLE_ROOT_SELECTORS, ...LOOSE_ROOT_SELECTORS])) {
      if (el === el.ownerDocument.body || el === el.ownerDocument.documentElement) continue;
      if (el.matches(CONTROL)) continue;
      if (el.querySelector(TOO_BROAD)) continue;
      all.push(el);
      if (all.length >= MAX_ROOTS * 3) break;
    }
    return all.filter((el) => !all.some((o) => o !== el && o.contains(el))).slice(0, MAX_ROOTS);
  }

  function detectInMeeting(popOut) {
    if (queryDocs(LEAVE_SELECTORS).length) return true;
    // The pop-out window holds nothing but the huddle: tiles or captions there mean a call.
    if (popOut && document.querySelector(PEER_TILE + ', ' + SPOKEN_NAMES)) return true;
    if (pipDoc && pipDoc.querySelector(PEER_TILE)) return true;
    // Fallback: a huddle root that contains a mic toggle means we are connected.
    // data-qa only: English aria-labels would miss other locales, and the
    // channel-header "Start/Join huddle" button never contains a mute control.
    for (const r of huddleRoots()) {
      if (r.querySelector('[data-qa*="mute"], [data-qa*="mic"]')) return true;
    }
    return false;
  }

  function attrsOf(el) {
    const img = el.matches('img[alt]') ? el : el.querySelector('img[alt]');
    return {
      ariaLabel: el.getAttribute('aria-label'),
      title: el.getAttribute('title'),
      alt: img ? img.getAttribute('alt') : null,
      qaName: el.getAttribute('data-qa-name'),
      dataQa: el.getAttribute('data-qa')
    };
  }

  function isSpeaking(el, label) {
    if (OK.labelSaysSpeaking(label)) return true;
    try {
      return el.matches(SPEAKING_ANY) || !!el.querySelector(SPEAKING_ANY);
    } catch (_) {
      return false; // invalid selector
    }
  }

  /** Member id of an avatar element from its image URL or its own attributes. */
  function memberIdOf(el) {
    const img = el.matches('img') ? el : el.querySelector('img');
    const fromSrc = img ? userIdFromAvatarSrc(img.getAttribute('src')) : null;
    if (fromSrc) return fromSrc;
    for (const name of ['data-member-id', 'data-user-id', 'data-qa-user-id']) {
      const v = el.getAttribute(name);
      if (v && /^[UW][A-Z0-9]{6,}$/.test(v)) return v;
    }
    const qa = /userId_([UW][A-Z0-9]{6,})/.exec(el.getAttribute('data-qa') || '');
    return qa ? qa[1] : null;
  }

  /** Participants (and speakers) from the video grid, captions and the event log. */
  function peerTiles(state, picks) {
    const tiles = [];
    const seen = new Set();
    for (const el of queryDocs([PEER_TILE])) {
      // The data-qa node and the gridcell can be the same tile nested twice.
      const tile = el.closest('.p-huddle_peer_tile') || el.closest('[role="gridcell"][id^="huddle-grid-gridcell-"]') || el;
      if (seen.has(tile)) continue;
      seen.add(tile);
      const labelled = [tile, ...tile.querySelectorAll('[aria-label]')].map((n) => n.getAttribute('aria-label')).filter(Boolean);
      const description = tile.querySelector('[id*="a11y_huddle_peer_tile_description"]');
      let name = peerTileName({
        ariaLabel: tile.getAttribute('aria-label'),
        labels: labelled,
        description: description ? description.textContent : null,
        text: OK.firstNameText(tile)
      });
      if (!name) {
        const id = memberIdOf(tile) || memberIdOf(el);
        name = (id && users.get(id)) || '';
      }
      if (!name) continue;
      const self = tile.matches(SELF_TILE) || !!tile.closest(SELF_TILE) || !!tile.querySelector(SELF_TILE);
      if (self && !state.selfName) state.selfName = name;
      state.participants.push(name);
      const speaking = tile.matches(ACTIVE_SPEAKER) || !!tile.querySelector(ACTIVE_SPEAKER);
      if (speaking) picks.tile.push(name);
      else if (isSpeaking(tile, tile.getAttribute('aria-label'))) picks.cls.push(name);
      tiles.push({ el: tile, name, sel: 'peer_tile' });
    }
    for (const el of queryDocs([SPOKEN_NAMES])) {
      const n = OK.cleanName(el.textContent);
      if (n && !OK.isJunkName(n)) state.participants.push(n);
    }
    return tiles;
  }

  /** Avatar-stack members named by their label or by the member directory. */
  function avatarMembers(state, picks, counts) {
    const out = [];
    const seen = new Set();
    for (const el of queryDocs([AVATAR_STACK])) {
      const member = el.closest('[data-qa="huddle_avatar_stack__member"]') || el;
      if (seen.has(member)) continue;
      seen.add(member);
      counts.avatars++;
      const p = participantFromAttrs(attrsOf(member));
      const id = memberIdOf(member);
      const name = (p && p.name) || (id && users.get(id)) || '';
      if (!name) {
        if (id) counts.unresolved++;
        continue;
      }
      state.participants.push(name);
      if (isSpeaking(member, p && p.label)) picks.cls.push(name);
      out.push({ el: member, name, sel: 'avatar_stack' });
    }
    return out;
  }

  function detectSelfName() {
    const el = OK.queryFirst(document, [
      SELF_BUTTON,
      'button[data-qa="user_menu_button"]',
      '[data-qa="current_user_name"]'
    ]);
    if (!el) return null;
    const raw = el.getAttribute('aria-label') || el.textContent || '';
    // "User: Jane Doe" / "Użytkownik: Jane Doe" / "Jane Doe, Active"
    const n = OK.cleanName(OK.stripLabelPrefix(raw).split(',')[0]);
    return n && !OK.isJunkName(n) ? n : null;
  }

  function detectTitle(roots) {
    const el = OK.queryFirst(document, [
      '[data-qa="huddle_window_titlebar_title"]',
      '[data-qa="huddle_details_title"]',
      '[data-qa="huddle_channel_name"]',
      '[data-qa*="huddle"] [data-qa*="channel_name"]',
      '[data-qa="huddle_title"]'
    ]);
    if (el) {
      const t = OK.cleanName(el.textContent);
      if (t) return t;
    }
    // "Huddle in project-acme" on the huddle workspace dialog.
    for (const r of [...queryDocs(['[class*="p-huddle"][role="dialog"][aria-label]', '[data-qa*="huddle"][aria-label]']), ...roots]) {
      const label = r.getAttribute('aria-label') || '';
      const m = /huddle (?:in|with)\s+(.+)$/i.exec(label);
      if (m) return 'Huddle in ' + OK.cleanName(m[1]).replace(/^#/, '');
    }
    return huddleWindow() ? OK.cleanTitle(document.title, [/\s*[|\-–—]\s*Slack.*$/i]) : null;
  }

  let speakerSeen = false;
  let othersSeen = false;
  let lastCounts = { avatars: 0, unresolved: 0 };

  function detect(speech) {
    const popOut = huddleWindow();
    const inMeeting = detectInMeeting(popOut);
    lastInMeeting = inMeeting;
    // A call ending clears announced joins, so the next call does not start with the last one's people.
    setLiveObserving(inMeeting);
    watchSidebar(inMeeting);
    const state = {
      inMeeting,
      title: null,
      selfName: detectSelfName(),
      participants: [],
      activeSpeakers: [],
      via: []
    };
    if (!inMeeting) return state;
    const now = Date.now();
    learnUsers(state.selfName, now);
    const roots = participantRoots();
    state.title = detectTitle(roots);

    const picks = { tile: [], label: [], cls: [], announce: [], generic: [] };
    const counts = { avatars: 0, unresolved: 0 };
    const seen = new Set();
    const tiles = new Map(); // name -> {el, name, sel}
    for (const t of peerTiles(state, picks)) tiles.set(OK.nameKey(t.name), t);
    for (const t of avatarMembers(state, picks, counts)) if (!tiles.has(OK.nameKey(t.name))) tiles.set(OK.nameKey(t.name), t);
    let budget = MAX_ELEMENTS;
    for (const r of roots) {
      // Summary labels on the root or its controls: "Huddle with Jane Doe and Bob Smith".
      for (const el of [r, ...r.querySelectorAll('[aria-label*="huddle" i], [title*="huddle" i]')]) {
        for (const raw of [el.getAttribute('aria-label'), el.getAttribute('title')]) {
          for (const n of huddleNamesFromLabel(raw)) state.participants.push(n);
        }
      }
      const groups = [
        [OK.queryAll(r, PARTICIPANT_SELECTORS), PARTICIPANT_SELECTORS, false],
        [OK.queryAll(r, AVATAR_SELECTORS), AVATAR_SELECTORS, true]
      ];
      for (const [nodes, selectors, attrsOnly] of groups) {
        for (const el of nodes) {
          if (seen.has(el) || --budget < 0) continue;
          seen.add(el);
          if (el.closest(SKIP_CONTROLS) || el.closest(MESSAGE_AREA)) continue;
          let p = participantFromAttrs(attrsOf(el));
          if (!p && !attrsOnly) {
            const text = OK.firstNameText(el);
            if (text && !/\bhuddle\b/i.test(text)) p = { name: text, label: text };
          }
          if (!p) {
            const id = memberIdOf(el);
            if (id && users.has(id)) p = { name: users.get(id), label: '' };
          }
          if (!p) continue;
          if (OK.hasSelfMarker(p.label) && !state.selfName) state.selfName = p.name;
          state.participants.push(p.name);
          if (isSpeaking(el, p.label)) (OK.labelSaysSpeaking(p.label) ? picks.label : picks.cls).push(p.name);
          const key = OK.nameKey(p.name);
          if (!tiles.has(key)) {
            const tile = el.closest(TILE_CONTAINER) || el;
            tiles.set(key, { el: r.contains(tile) ? tile : el, name: p.name, sel: OK.matchedSelector(el, selectors) });
          }
        }
      }
    }
    // Joins the live region announced (people whose avatar is not on screen).
    for (const name of announced.values()) state.participants.push(name);
    if (announcedSpeaker && now - announcedSpeaker.at < 3000) picks.announce.push(announcedSpeaker.name);
    // Generic fallback: the speaker's avatar ring / level meter keeps mutating.
    picks.generic = speech ? speech.track([...tiles.values()]) : [];

    const add = (list, label) => {
      if (!list.length) return;
      state.via.push(label);
      state.activeSpeakers.push(...list);
    };
    add(picks.tile, 'tile');
    add(picks.label, 'label');
    add(picks.announce, 'announce');
    // A speaking class on every tile is decoration, not speech.
    if (picks.cls.length && (tiles.size < 2 || OK.dedupeNames(picks.cls).length < tiles.size)) add(picks.cls, 'cls');
    if (!state.activeSpeakers.length) add(picks.generic, 'generic');
    state.participants = OK.dedupeNames(state.participants);
    state.activeSpeakers = OK.dedupeNames(state.activeSpeakers);
    const self = state.selfName ? OK.nameKey(state.selfName) : null;
    if (state.participants.some((n) => OK.nameKey(n) !== self)) othersSeen = true;
    if (state.activeSpeakers.length) speakerSeen = true;
    lastCounts = counts;
    return state;
  }

  /** Huddle structure for selector tuning, until this page has shown both another participant and a speaker. */
  function snapshot(state) {
    if (speakerSeen && othersSeen) return null;
    const hits = {};
    for (const sel of [PEER_TILE, ACTIVE_SPEAKER, SELF_TILE, SPOKEN_NAMES, AVATAR_STACK, LIVE_REGION, SENDER, MENTION, ...LEAVE_SELECTORS, ...HUDDLE_ROOT_SELECTORS, ...LOOSE_ROOT_SELECTORS, ...PARTICIPANT_SELECTORS, ...AVATAR_SELECTORS, ...SPEAKING_SELECTORS]) {
      try {
        hits[sel] = queryDocs([sel]).length;
      } catch (_) {
        hits[sel] = -1;
      }
    }
    // Tile candidates for selector tuning: labels, data-qa and classes of grid cells / peer tiles.
    const tileCandidates = [];
    for (const el of queryDocs([PEER_TILE, '[role="gridcell"]', '[data-qa*="huddle" i][aria-label]', '[class*="huddle" i][aria-label]'])) {
      if (tileCandidates.length >= 30) break;
      if (el.closest(MESSAGE_AREA)) continue;
      tileCandidates.push({
        tag: el.tagName.toLowerCase(),
        role: el.getAttribute('role') || undefined,
        id: (el.id || '').slice(0, 60) || undefined,
        qa: el.getAttribute('data-qa') || undefined,
        cls: String(el.getAttribute('class') || '').slice(0, 120) || undefined,
        aria: (el.getAttribute('aria-label') || '').slice(0, 120) || undefined,
        labels: Array.from(el.querySelectorAll('[aria-label]'), (n) => n.getAttribute('aria-label')).filter(Boolean).slice(0, 6).map((l) => l.slice(0, 80)),
        speaking: el.matches(ACTIVE_SPEAKER) || !!el.querySelector(ACTIVE_SPEAKER),
        named: peerTileName({ ariaLabel: el.getAttribute('aria-label') }) || undefined
      });
    }
    // Distinct huddle data-qa values on the page: renamed hooks show up here.
    const qa = new Set();
    for (const el of queryDocs(['[data-qa*="huddle" i]', '[data-qa*="peer" i]', '[data-qa*="speak" i]'])) {
      if (qa.size >= 60) break;
      qa.add(el.getAttribute('data-qa'));
    }
    let roots = participantRoots();
    const fromBody = !roots.length;
    if (fromBody) roots = [document.body];
    // Peer tiles (or, with the grid closed, bottom-bar avatars) to depth 3 with names pseudonymized:
    // whatever changes on one of them between snapshots is the speaking-marker candidate.
    const tileElements = queryDocs([PEER_TILE]);
    const tileNames = [...state.participants, ...state.activeSpeakers, ...users.values()];
    for (const el of tileElements) {
      const named = peerTileName({ ariaLabel: el.getAttribute('aria-label') });
      if (named) tileNames.push(named);
    }
    const tiles = tileStructure((tileElements.length ? tileElements : queryDocs([AVATAR_STACK])).slice(0, 12), tileNames);
    return {
      v: 4,
      platform: 'slack',
      tiles,
      path: location.protocol === 'about:' ? location.href : location.pathname,
      popOut: huddleWindow(),
      pip: !!pipDoc,
      fromBody,
      participants: state.participants,
      speakers: state.activeSpeakers,
      avatars: lastCounts.avatars,
      unresolvedAvatars: lastCounts.unresolved,
      knownMembers: users.size,
      announcements: announceCount,
      hits,
      matched: Object.keys(hits).filter((k) => hits[k] > 0),
      tileCandidates,
      huddleQa: [...qa],
      frames: Array.from(document.querySelectorAll('iframe')).map((f) => {
        try {
          return new URL(f.src, location.href).host + new URL(f.src, location.href).pathname.slice(0, 40);
        } catch (_) {
          return '';
        }
      }),
      dom: OK.domSnapshot(roots, {
        skip: MESSAGE_AREA + ', ' + TOO_BROAD,
        // Member ids of avatars, so an unnamed avatar can be traced to the directory.
        extra: (el) => (el.tagName === 'IMG' ? { uid: userIdFromAvatarSrc(el.getAttribute('src')) || undefined } : null)
      })
    };
  }

  window.__chrupioSlack = OK.createReporter('slack', detect, { snapshot, relay: huddleWindow, probeExtra: sidebarProbe });
})(typeof globalThis !== 'undefined' ? globalThis : this);
