/* Chrupio: Google Meet scraper. Depends on content/common.js. */
(function (root) {
  'use strict';
  const OK = root.Chrupio || (typeof require === 'function' ? require('./common.js') : null);

  // ---------------------------------------------------------------- pure speaker logic (tested in Node)
  //
  // Meet changes its markup often and obfuscates class names, so speakers come from several
  // independent signals, strongest first:
  //   attr      aria-label / data attribute that says "speaking"
  //   captions  the caption block whose text changed since the last scrape (when captions are on)
  //   cls       known voice-level classes on an element inside the tile (hints, may go stale)
  //   visual    a coloured ring or outline drawn on the tile
  //   generic   the tile whose subtree mutates much more than the others (voice-level bars)
  // cls and visual are dropped when they mark every tile (decoration); generic is used only when
  // nothing else found a speaker.

  // Voice-level indicator classes seen on Meet tiles while the person talks; the silence class marks
  // the same element when quiet. Hints only: the other strategies do not depend on them.
  const SPEAKING_CLASSES = ['Oaajhc', 'HX2H7', 'wEsLMd', 'OgVli'];
  const SILENT_CLASSES = ['gjg47c'];

  /** True when one of the class strings (className of elements in a tile) shows a speaking indicator. */
  function hasSpeakingClass(classLists) {
    for (const raw of classLists || []) {
      const classes = String(raw || '').split(/\s+/);
      if (classes.some((c) => SILENT_CLASSES.includes(c))) continue;
      if (classes.some((c) => SPEAKING_CLASSES.includes(c))) return true;
    }
    return false;
  }

  /**
   * Drops items ({el, id}) nested inside another item of the same participant id. Meet repeats
   * data-participant-id on nested elements of one tile; splitting a tile's mutations between them
   * hides the busy tile. A different participant's tile inside another (picture in picture) stays.
   */
  function outermostTiles(items) {
    const list = items || [];
    return list.filter((t) => !list.some((o) => o.el !== t.el && o.id && o.id === t.id &&
      typeof o.el.contains === 'function' && o.el.contains(t.el)));
  }

  /**
   * Speakers from the captions panel. blocks: [{key, lines}] in screen order, lines[0] being the
   * speaker's name; prev: Map key -> text from the last scrape (updated in place). A block speaks when
   * its text changed. "You" is the local user (selfName). Known participants are matched first.
   */
  function captionSpeakers(blocks, prev, known, selfName, fresh) {
    const byKey = new Map((known || []).map((n) => [OK.nameKey(n), n]));
    const out = [];
    const seen = new Set();
    for (const b of blocks || []) {
      const lines = (b.lines || []).map((l) => String(l).trim()).filter(Boolean);
      if (lines.length < 2) continue;
      const text = lines.slice(1).join(' ');
      const before = prev.get(b.key);
      prev.set(b.key, text);
      // A block first seen is a baseline, except after the first pass (fresh): then it is new speech.
      if (before === text || (before === undefined && !fresh)) continue;
      const raw = OK.cleanName(lines[0]);
      let name = byKey.get(OK.nameKey(raw)) || '';
      if (!name && /^(?:you|ty|du|vous|tú)$/i.test(raw)) name = selfName || '';
      if (!name && !OK.isJunkName(raw)) name = raw;
      if (name && !seen.has(OK.nameKey(name))) {
        seen.add(OK.nameKey(name));
        out.push(name);
      }
    }
    if (prev.size > 200) for (const k of [...prev.keys()].slice(0, prev.size - 200)) prev.delete(k);
    return out;
  }

  // Captions toggle labels. "on" labels turn captions on (captions are off now), "off" labels the reverse.
  const CAPTIONS_ON_LABELS = [
    'turn on captions', 'turn on closed captions', 'show captions', 'włącz napisy', 'pokaż napisy',
    'untertitel aktivieren', 'untertitel einschalten', 'activar subtítulos', 'activer les sous-titres',
    'ativar legendas', 'attiva sottotitoli', 'ondertiteling inschakelen'
  ];
  const CAPTIONS_OFF_LABELS = [
    'turn off captions', 'turn off closed captions', 'hide captions', 'wyłącz napisy', 'ukryj napisy',
    'untertitel deaktivieren', 'untertitel ausschalten', 'desactivar subtítulos', 'désactiver les sous-titres',
    'desativar legendas', 'disattiva sottotitoli', 'ondertiteling uitschakelen'
  ];

  /**
   * Captions state from toolbar buttons [{label, pressed}]: {state: 'on'|'off'|'unknown', index}.
   * index is the button that turns captions on when they are off. A pressed "captions" toggle is on.
   */
  function captionsToggleState(buttons) {
    const list = buttons || [];
    const norm = (l) => String(l || '').replace(/\u00a0/g, ' ').replace(/\s*\([^)]*\)\s*$/, '').trim().toLowerCase();
    for (let i = 0; i < list.length; i++) {
      const l = norm(list[i].label);
      if (CAPTIONS_OFF_LABELS.some((x) => l.startsWith(x))) return { state: 'on', index: i };
    }
    for (let i = 0; i < list.length; i++) {
      const l = norm(list[i].label);
      if (CAPTIONS_ON_LABELS.some((x) => l.startsWith(x))) return { state: list[i].pressed === 'true' ? 'on' : 'off', index: i };
    }
    return { state: 'unknown', index: -1 };
  }

  /** Names whose caption text changed within windowMs before now, from stamps (Map name -> ms). */
  function recentCaptionSpeakers(stamps, now, windowMs) {
    const out = [];
    for (const [name, at] of stamps) {
      if (now - at <= windowMs) out.push(name);
      else if (now - at > 60000) stamps.delete(name);
    }
    return out;
  }

  /**
   * Final speakers from per-strategy picks ({attr, captions, cls, visual, generic} name lists) and
   * the number of named tiles. Returns {speakers, via}; via names the strategies that contributed.
   */
  function combineSpeakers(picks, named) {
    const speakers = [];
    const via = [];
    const add = (list, label) => {
      if (!list || !list.length) return;
      via.push(label);
      for (const n of list) if (!speakers.some((s) => OK.nameKey(s) === OK.nameKey(n))) speakers.push(n);
    };
    // Captions name the speaker from Meet's own speech recognition: when they do, they win.
    if (picks.captions && picks.captions.length) {
      add(picks.captions, 'captions');
      return { speakers, via };
    }
    add(picks.attr, 'attr');
    // An indicator on every tile is decoration, not speech.
    if (picks.cls && picks.cls.length < named) add(picks.cls, 'cls');
    if (picks.visual && picks.visual.length < named) add(picks.visual, 'visual');
    if (!speakers.length) add(picks.generic, 'generic');
    return { speakers, via };
  }

  if (typeof module !== 'undefined' && module.exports) {
    module.exports = { hasSpeakingClass, outermostTiles, captionSpeakers, captionsToggleState, recentCaptionSpeakers, combineSpeakers, SPEAKING_CLASSES };
    return;
  }

  // ---------------------------------------------------------------- browser

  // Injected again after an extension update; a reporter from the old version has stopped.
  const running = window.__chrupioMeet;
  if (running && typeof running.alive === 'function' && running.alive()) return;
  window.__chrupioMeet = { alive: () => true };

  const MEETING_PATH = /^\/[a-z]{3}-[a-z]{4}-[a-z]{3}(?:$|[/?#])/i;

  // Leave-call button labels (English + common locales). Matched as aria-label substrings.
  const LEAVE_LABELS = [
    'leave call', 'opuść rozmowę', 'opuść połączenie', 'zakończ połączenie',
    'salir de la llamada', 'abandonar la llamada', 'quitter l\'appel', 'quitter l’appel',
    'anruf verlassen', 'anruf beenden', 'sair da chamada', 'abbandona la chiamata',
    'lascia la chiamata', 'abbandona chiamata',
    'gesprek verlaten', 'opustit hovor', 'покинуть видеовстречу', 'завершить звонок',
    '通話から退出', '退出通话', '나가기'
  ];

  // Leave button by stable jsname / icon, independent of UI language.
  const LEAVE_SELECTORS = ['button[jsname="CQylAd"]', '[role="button"][jsname="CQylAd"]'];

  // Lobby (green room) controls: their presence means we are NOT in the call yet.
  // jsname values are Meet's long-lived Join now / Ask to join button ids (locale-independent).
  const LOBBY_SELECTORS = ['button[jsname="Qx7uuf"]', '[role="button"][jsname="Qx7uuf"]'];
  const LOBBY_TEXT = /^(?:join now|ask to join|join here too|switch here|dołącz teraz|poproś o dołączenie|unirse ahora|solicitar unirse|participer|demander à participer|jetzt teilnehmen|teilnahme anfragen|participar agora|pedir para participar|partecipa ora|chiedi di partecipare)$/i;

  const TILE_SELECTORS = ['[data-participant-id]', '[data-requested-participant-id]'];

  // People side panel list items (aria-label is the display name). Panel items
  // usually also carry data-participant-id (picked up as tiles); these are the
  // English/Polish fallbacks. A bare "[role=listitem][aria-label]" is too broad
  // (chat messages, captions), so it is not used.
  const PANEL_ITEM_SELECTORS = [
    '[role="list"][aria-label*="articipant" i] [role="listitem"]',
    '[role="list"][aria-label*="uczestnik" i] [role="listitem"]',
    '[role="list"][aria-label*="in call" i] [role="listitem"]',
    '[role="list"][aria-label*="w rozmowie" i] [role="listitem"]'
  ];

  // Captions panel (only present when the user turned captions on).
  const CAPTION_REGION_SELECTORS = [
    '[role="region"][aria-label*="caption" i]',
    '[role="region"][aria-label*="napisy" i]',
    '[role="region"][aria-label*="untertitel" i]',
    '[role="region"][aria-label*="subtítulos" i]',
    '[role="region"][aria-label*="sous-titres" i]',
    '[role="region"][aria-label*="legendas" i]',
    '[role="region"][aria-label*="sottotitoli" i]',
    'div[jsname="dsyhDe"]',
    'div[jsname="tgaKEf"]',
    '.a4cQT'
  ];
  // Speaker-name elements inside a caption block (class fallback, after the avatar-based scan).
  const CAPTION_NAME_SELECTORS = ['.NWpY1d', '.KcIKyf', '.zs7s8d'];
  // How long after its caption text last changed a person still counts as speaking.
  const CAPTION_ACTIVE_MS = 2000;

  const SPEAKING_CLASS_SELECTOR = SPEAKING_CLASSES.map((c) => '.' + c).join(',');

  function onMeetingPath() {
    return MEETING_PATH.test(location.pathname);
  }

  function hasLeaveButton() {
    for (const b of OK.queryAll(document, LEAVE_SELECTORS)) if (OK.isVisible(b)) return true;
    const buttons = OK.queryAll(document, ['button[aria-label]', '[role="button"][aria-label]']);
    for (const b of buttons) {
      const label = (b.getAttribute('aria-label') || '').toLowerCase();
      if (LEAVE_LABELS.some((l) => label.includes(l))) return true;
    }
    // Icon-ligature fallback: the red hang-up button renders the "call_end" icon.
    for (const i of document.querySelectorAll('button i, [role="button"] i')) {
      if ((i.textContent || '').trim() === 'call_end') return true;
    }
    return false;
  }

  function inLobby() {
    for (const b of OK.queryAll(document, LOBBY_SELECTORS)) if (OK.isVisible(b)) return true;
    for (const b of document.querySelectorAll('button, [role="button"]')) {
      const t = (b.innerText || '').trim();
      if (t && LOBBY_TEXT.test(t) && OK.isVisible(b)) return true;
    }
    return false;
  }

  function detectInMeeting() {
    if (!onMeetingPath()) return false;
    if (hasLeaveButton()) return true;
    // Fallback for unknown locales / renamed leave button: at least two distinct
    // participants on stage and no green-room join control. One tile is not enough:
    // the green room may render the local preview with a participant id.
    if (inLobby()) return false;
    const ids = new Set();
    for (const t of OK.queryAll(document, TILE_SELECTORS)) {
      ids.add(t.getAttribute('data-participant-id') || t.getAttribute('data-requested-participant-id'));
    }
    ids.delete(null);
    ids.delete('');
    return ids.size >= 2;
  }

  function tileName(tile) {
    // 1) the tile's own aria-label (not its buttons: "Pin Jane to your main screen")
    const label = tile.getAttribute('aria-label');
    if (label) {
      const n = OK.nameFromAriaLabel(label);
      if (n && !OK.isJunkName(n)) return { name: n, self: OK.hasSelfMarker(label) };
    }
    // 2) first plausible text node outside buttons (the name badge)
    const text = OK.firstNameText(tile);
    if (text) return { name: text, self: false };
    // 3) explicit self-name attribute on or inside the tile
    const selfEl = tile.matches('[data-self-name]') ? tile : tile.querySelector('[data-self-name]');
    if (selfEl) {
      const n = OK.cleanName(selfEl.getAttribute('data-self-name'));
      if (n && !OK.isJunkName(n)) return { name: n, self: true };
    }
    return null;
  }

  /** 'attr', 'cls', 'visual' or false for one tile. */
  function tileIsSpeaking(tile) {
    // Attribute / aria hints first.
    if (tile.querySelector('[data-is-speaking="true"], [data-speaking="true"], [data-audio-level-active="true"]')) return 'attr';
    for (const el of [tile, ...tile.querySelectorAll('[aria-label]')]) {
      if (OK.labelSaysSpeaking(el.getAttribute('aria-label'))) return 'attr';
    }
    // Known voice-level classes.
    let hinted;
    try {
      hinted = tile.querySelectorAll(SPEAKING_CLASS_SELECTOR);
    } catch (_) {
      hinted = [];
    }
    if (hinted.length && hasSpeakingClass(Array.from(hinted, (el) => el.getAttribute('class')))) return 'cls';
    // Visual heuristic: Meet draws a coloured ring on the speaking tile. Check the tile's overlay
    // descendants for a visible border or inset shadow (bounded to a few elements).
    const view = tile.ownerDocument.defaultView;
    const candidates = tile.querySelectorAll(':scope > div, :scope > div > div, :scope > div > div > div');
    let checked = 0;
    for (const el of candidates) {
      if (++checked > 20) break;
      if (el.offsetWidth <= 40 || el.offsetHeight <= 40) continue;
      const cs = view.getComputedStyle(el);
      // Opaque or partly opaque colour; fully transparent rings are hidden placeholders.
      const colour = (c) => /rgba?\((?:\d+, ){2}\d+(?:, (?:0?\.\d*[1-9]\d*|1))?\)/.test(c) && !/rgba\((?:\d+, ){3}0\)|transparent/.test(c);
      const border = parseFloat(cs.borderTopWidth) >= 2 && cs.borderTopStyle !== 'none' && colour(cs.borderTopColor);
      const shadow = cs.boxShadow && cs.boxShadow !== 'none' && /inset/.test(cs.boxShadow) && colour(cs.boxShadow);
      if (border || shadow) return 'visual';
    }
    return false;
  }

  // Caption block element -> stable key; blocks are reused while their text grows.
  const captionKeys = new WeakMap();
  const captionTexts = new Map();
  let captionSeq = 0;

  /** Caption blocks as {key, lines}: the smallest element around each avatar with a name and a text line. */
  function captionBlocks() {
    const region = OK.queryFirst(document, CAPTION_REGION_SELECTORS);
    if (!region) return [];
    const blocks = [];
    const seen = new Set();
    for (const img of region.querySelectorAll('img')) {
      let el = img.parentElement;
      for (let depth = 0; el && el !== region && depth < 5; depth++, el = el.parentElement) {
        const lines = (el.innerText || '').split(/[\r\n]+/).map((l) => l.trim()).filter(Boolean);
        if (lines.length >= 2) {
          if (!seen.has(el)) {
            seen.add(el);
            if (!captionKeys.has(el)) captionKeys.set(el, ++captionSeq);
            blocks.push({ key: captionKeys.get(el), lines });
          }
          break;
        }
      }
    }
    if (blocks.length) return blocks;
    // No avatars (layout change): name elements by class, block = nearest ancestor with a text line too.
    for (const nameEl of OK.queryAll(region, CAPTION_NAME_SELECTORS)) {
      let el = nameEl.parentElement;
      for (let depth = 0; el && depth < 4; depth++, el = el.parentElement) {
        const lines = (el.innerText || '').split(/[\r\n]+/).map((l) => l.trim()).filter(Boolean);
        if (lines.length >= 2) {
          if (!seen.has(el)) {
            seen.add(el);
            if (!captionKeys.has(el)) captionKeys.set(el, ++captionSeq);
            blocks.push({ key: captionKeys.get(el), lines: [OK.cleanName(nameEl.innerText), ...lines.slice(1)] });
          }
          break;
        }
        if (el === region) break;
      }
    }
    return blocks;
  }

  // ------------------------------------------------ captions: auto-enable and observe

  const captionStamps = new Map(); // speaker name -> ms of their last caption change
  let captionsPrimed = false; // first pass done: later new blocks are new speech
  let captionObserver = null;
  let observedRegion = null;
  let knownNames = [];
  let knownSelf = null;
  let captionsTries = 0;
  let captionsNextTry = 0;
  let captionsUserOff = false; // captions were on and someone turned them off: leave them off
  let captionsWereOn = false;

  /** Stamp the people whose caption text changed. Runs from the observer and from each scrape. */
  function scanCaptions() {
    const now = Date.now();
    const names = captionSpeakers(captionBlocks(), captionTexts, knownNames, knownSelf, captionsPrimed);
    captionsPrimed = true;
    for (const n of names) captionStamps.set(n, now);
  }

  /** Observe the captions region (re-attached when Meet replaces it). */
  function watchCaptions() {
    const region = OK.queryFirst(document, CAPTION_REGION_SELECTORS);
    if (region === observedRegion) return !!region;
    if (captionObserver) captionObserver.disconnect();
    observedRegion = region;
    captionObserver = null;
    if (!region) return false;
    captionObserver = new MutationObserver(scanCaptions);
    captionObserver.observe(region, { childList: true, subtree: true, characterData: true });
    return true;
  }

  function captionButtons() {
    return OK.queryAll(document, ['button[aria-label]', '[role="button"][aria-label]']);
  }

  /** Turn Meet's captions on once per call: click the toggle by label, else press "c". */
  function ensureCaptions(now) {
    const els = captionButtons();
    const t = captionsToggleState(els.map((b) => ({ label: b.getAttribute('aria-label'), pressed: b.getAttribute('aria-pressed') })));
    const on = t.state === 'on' || !!observedRegion;
    if (on) {
      captionsWereOn = true;
      return;
    }
    if (captionsWereOn && t.state === 'off') captionsUserOff = true;
    if (captionsUserOff || captionsTries >= 3 || now < captionsNextTry) return;
    captionsTries++;
    captionsNextTry = now + 5000;
    if (t.index >= 0) {
      els[t.index].click();
      return;
    }
    // Meet's shortcut for captions; only when focus is not in a text field.
    const a = document.activeElement;
    if (a && (a.isContentEditable || /^(?:input|textarea|select)$/i.test(a.tagName))) return;
    const init = { key: 'c', code: 'KeyC', keyCode: 67, which: 67, bubbles: true, cancelable: true };
    (a || document.body).dispatchEvent(new KeyboardEvent('keydown', init));
    (a || document.body).dispatchEvent(new KeyboardEvent('keyup', init));
  }

  function resetCaptions() {
    captionsTries = 0;
    captionsNextTry = 0;
    captionsUserOff = false;
    captionsWereOn = false;
    captionsPrimed = false;
    captionStamps.clear();
    if (captionObserver) captionObserver.disconnect();
    captionObserver = null;
    observedRegion = null;
  }

  function detectSelfName() {
    const el = document.querySelector('[data-self-name]');
    if (el) {
      const n = OK.cleanName(el.getAttribute('data-self-name'));
      if (n && !OK.isJunkName(n)) return n;
    }
    // Account avatar (home page / green room; usually absent in-call, the reporter
    // remembers it). aria-label "Google Account: Jane Doe\n(jane@x.com)" in any locale:
    // the link always points at accounts.google.com.
    const acct = OK.queryFirst(document, [
      'a[href*="accounts.google.com"][aria-label*=":"]',
      'a[aria-label^="Google Account" i]',
      '[aria-label^="Konto Google" i]'
    ]);
    if (acct) {
      const m = /:\s*([^()\n@]+?)\s*(?:\(|\n|$)/.exec(acct.getAttribute('aria-label') || '');
      if (m) {
        const n = OK.cleanName(m[1]);
        if (n && !OK.isJunkName(n)) return n;
      }
    }
    return null;
  }

  function detectTitle() {
    const el = document.querySelector('[data-meeting-title]');
    if (el) {
      const t = OK.cleanName(el.getAttribute('data-meeting-title') || el.textContent);
      if (t) return t;
    }
    return OK.cleanTitle(document.title, [/^(?:google\s+)?meet\s*[-–—:]\s*/i, 'Google Meet', 'Meet']);
  }

  function detect(speech) {
    const inMeeting = detectInMeeting();
    const state = {
      inMeeting,
      title: detectTitle(),
      selfName: detectSelfName(),
      participants: [],
      activeSpeakers: []
    };
    if (!inMeeting) {
      inCallAt = 0;
      resetCaptions();
      return state;
    }

    const picks = { attr: [], captions: [], cls: [], visual: [], generic: [] };
    const tiles = outermostTiles(OK.queryAll(document, TILE_SELECTORS).map((el) => ({
      el,
      id: el.getAttribute('data-participant-id') || el.getAttribute('data-requested-participant-id')
    })));
    const tracked = [];
    const names = new Set();
    for (const { el: tile } of tiles) {
      const r = tileName(tile);
      if (!r) continue;
      names.add(OK.nameKey(r.name));
      if (r.self && !state.selfName) state.selfName = r.name;
      state.participants.push(r.name);
      tracked.push({ el: tile, name: r.name, sel: OK.matchedSelector(tile, TILE_SELECTORS) });
      const speaking = tileIsSpeaking(tile);
      if (speaking) picks[speaking].push(r.name);
    }
    for (const item of OK.queryAll(document, PANEL_ITEM_SELECTORS)) {
      const label = item.getAttribute('aria-label');
      const n = label ? OK.nameFromAriaLabel(label) : OK.firstNameText(item);
      if (!n) continue;
      if (label && OK.hasSelfMarker(label) && !state.selfName) state.selfName = n;
      state.participants.push(n);
    }
    knownNames = state.participants.slice();
    knownSelf = state.selfName;
    const now = Date.now();
    // Wait for the call UI to settle before touching the toolbar.
    if (!inCallAt) inCallAt = now;
    if (now - inCallAt > 3000) {
      try {
        ensureCaptions(now);
      } catch (_) {
        /* toolbar changed */
      }
    }
    if (watchCaptions()) scanCaptions();
    picks.captions = recentCaptionSpeakers(captionStamps, now, CAPTION_ACTIVE_MS);
    // Generic fallback: the speaking tile's voice-level bars keep mutating its subtree.
    picks.generic = speech ? speech.track(tracked) : [];
    const result = combineSpeakers(picks, names.size);
    state.activeSpeakers = result.speakers;
    state.via = result.via;
    if (result.speakers.length) speakerSeen = true;
    lastTiles = tracked.map((t) => t.el);
    return state;
  }

  let speakerSeen = false;
  let lastTiles = [];
  let inCallAt = 0;

  /** Tile structure for selector tuning, while no strategy has found a speaker in this page yet. */
  function snapshot(state) {
    if (speakerSeen || lastTiles.length < 2) return null;
    const hits = {};
    for (const sel of [...TILE_SELECTORS, ...PANEL_ITEM_SELECTORS, ...CAPTION_REGION_SELECTORS, ...CAPTION_NAME_SELECTORS, SPEAKING_CLASS_SELECTOR, '.' + SILENT_CLASSES[0]]) {
      try {
        hits[sel] = document.querySelectorAll(sel).length;
      } catch (_) {
        hits[sel] = -1;
      }
    }
    return {
      v: 1,
      platform: 'meet',
      path: location.pathname,
      participants: state.participants,
      hits,
      captions: { region: !!observedRegion, tries: captionsTries, userOff: captionsUserOff, speakers: captionStamps.size },
      dom: OK.domSnapshot(lastTiles.slice(0, 3), { maxNodes: 600 })
    };
  }

  window.__chrupioMeet = OK.createReporter('meet', detect, { snapshot });
})(typeof globalThis !== 'undefined' ? globalThis : this);
