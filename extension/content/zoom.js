/* Chrupio: Zoom web client scraper (*.zoom.us/wc/*). Depends on content/common.js. */
(function (root) {
  'use strict';
  const OK = root.Chrupio || (typeof require === 'function' ? require('./common.js') : null);

  // ---------------------------------------------------------------- pure parsing (tested in Node)

  // Role groups Zoom appends to names: "(Host, me)", "(Co-host)", "(Guest)", Polish "(Gospodarz, ja)".
  const ROLE_GROUP_RE = /\s*\((?:[^()]*\b(?:host|co-host|cohost|me|you|guest|participant|gospodarz|współgospodarz|ja|ty)\b[^()]*)\)/gi;
  const SELF_GROUP_RE = /\((?:[^()]*[,\s])?(?:me|you|ja|ty)\s*\)/i;

  /**
   * Parse a Zoom tile footer / participants-panel label, e.g.
   * "Jane Doe (Host, me), Computer audio unmuted, Video on" or "Video of Bob, talking".
   * Returns {name, self, speaking} or null.
   */
  function parseZoomLabel(raw) {
    if (raw == null) return null;
    const firstLine = String(raw).split(/[\r\n]+/).map((l) => l.trim()).filter(Boolean)[0] || '';
    if (!firstLine) return null;
    const self = SELF_GROUP_RE.test(firstLine);
    const s = firstLine
      .replace(ROLE_GROUP_RE, '')
      .replace(/^video of\s+/i, '')
      .replace(/['’]s video\b.*$/i, '');
    const name = OK.nameFromAriaLabel(s);
    if (!name || OK.isJunkName(name)) return null;
    return { name, self, speaking: OK.labelSaysSpeaking(raw) };
  }

  if (typeof module !== 'undefined' && module.exports) {
    module.exports = { parseZoomLabel };
    return;
  }

  // ---------------------------------------------------------------- browser

  // Injected again after an extension update; a reporter from the old version has stopped.
  const running = window.__chrupioZoom;
  if (running && typeof running.alive === 'function' && running.alive()) return;
  window.__chrupioZoom = { alive: () => true };

  const LEAVE_SELECTORS = [
    'button.footer__leave-btn',
    '[class*="footer__leave-btn"]',
    '[class*="leave-meeting-btn" i]',
    'button[aria-label="Leave"]',
    'button[aria-label^="Leave meeting" i]',
    'button[aria-label^="End meeting" i]',
    'button[aria-label^="Opuść" i]'
  ];
  const PREJOIN_SELECTORS = ['.preview-join-button', '#preview-join-button', '[class*="preview-join-button"]', '#joinBtn'];
  const FOOTER_SELECTORS = ['#wc-footer', '[class*="footer__inner"]', '[class*="meeting-app"] footer'];
  const STAGE_SELECTORS = ['#wc-container-left', '[class*="video-container"]', '[class*="gallery-video-container"]'];

  // Video tiles; the name sits in a footer overlay.
  const TILE_SELECTORS = [
    '.video-avatar__avatar',
    '.gallery-video-container__video-frame',
    '.speaker-active-container__video-frame',
    '.speaker-bar-container__video-frame',
    '[class*="video-frame"][aria-label]',
    '[class*="video-container"] [class*="video-avatar"][aria-label]'
  ];
  const TILE_NAME_SELECTORS = [
    '.video-avatar__avatar-footer',
    '[class*="avatar-footer"]',
    '[class*="avatar-name"]',
    '[class*="display-name"]',
    '[class*="name-label"]'
  ];

  // Participants side panel rows.
  const PANEL_ITEM_SELECTORS = [
    '.participants-item__item-layout',
    '[class*="participants-item"][aria-label]',
    '.participants-li',
    '[class*="participants-li"]',
    '#participants-ul [role="listitem"]',
    '[class*="participants-section"] [role="listitem"]'
  ];
  const PANEL_NAME_SELECTORS = ['.participants-item__display-name', '[class*="display-name"]', '[class*="item__name"]'];

  // Explicit speaking markers on or inside a tile / row.
  const SPEAKING_SELECTORS = [
    '[class*="active-speaker" i]',
    '[class*="speaker-active" i]',
    '[class*="video-frame--active"]',
    '[class*="--speaking"]',
    '[class*="is-speaking" i]',
    '[class*="audio-unmute-animation" i]'
  ];
  // Ancestors that make a tile the speaker (speaker view's main slot, active gallery frame).
  const SPEAKING_FRAME = '.speaker-active-container__video-frame, [class*="video-frame--active"]';

  /** The page plus same-origin iframes (the app.zoom.us PWA hosts the meeting in one). */
  function docs() {
    const out = [document];
    for (const f of document.querySelectorAll('iframe')) {
      try {
        if (f.contentDocument && f.contentDocument.documentElement) out.push(f.contentDocument);
      } catch (_) {
        /* cross-origin */
      }
    }
    return out;
  }

  function detectInMeeting(ds) {
    for (const d of ds) if (OK.queryFirst(d, LEAVE_SELECTORS)) return true;
    for (const d of ds) if (OK.queryFirst(d, PREJOIN_SELECTORS)) return false;
    // Footer toolbar plus the video stage: the call UI is mounted.
    return ds.some((d) => OK.queryFirst(d, FOOTER_SELECTORS) && OK.queryFirst(d, STAGE_SELECTORS));
  }

  function nameFromTile(tile) {
    for (const raw of [tile.getAttribute('aria-label')]) {
      const r = raw && parseZoomLabel(raw);
      if (r) return Object.assign(r, { label: raw });
    }
    const named = OK.queryFirst(tile, TILE_NAME_SELECTORS);
    if (named) {
      const raw = named.getAttribute('aria-label') || named.getAttribute('title') || named.textContent;
      const r = parseZoomLabel(raw);
      if (r) return Object.assign(r, { label: raw });
    }
    return null;
  }

  function nameFromPanelItem(item) {
    const label = item.getAttribute('aria-label');
    const named = OK.queryFirst(item, PANEL_NAME_SELECTORS);
    for (const raw of [label, named && (named.getAttribute('title') || named.textContent)]) {
      const r = raw && parseZoomLabel(raw);
      if (r) return Object.assign(r, { label: raw, self: r.self || (!!label && SELF_GROUP_RE.test(label)) });
    }
    const text = OK.firstNameText(item);
    const r = text && parseZoomLabel(text);
    return r ? Object.assign(r, { label: text }) : null;
  }

  function isSpeaking(el, r) {
    if (r.speaking) return true;
    if (el.closest(SPEAKING_FRAME)) return true;
    for (const sel of SPEAKING_SELECTORS) {
      try {
        if (el.matches(sel) || el.querySelector(sel)) return true;
      } catch (_) {
        /* invalid selector */
      }
    }
    return false;
  }

  function detectTitle(ds) {
    for (const d of ds) {
      const el = OK.queryFirst(d, ['[class*="meeting-topic"]', '[class*="meeting-title"]', '[class*="meeting-info-container__topic"]']);
      const t = el ? OK.cleanName(el.getAttribute('title') || el.textContent) : '';
      if (t && !OK.isJunkName(t)) return t;
    }
    return OK.cleanTitle(document.title, ['Zoom Meeting', 'Zoom Webinar', 'Zoom']);
  }

  function detect(speech) {
    const ds = docs();
    const inMeeting = detectInMeeting(ds);
    const state = { inMeeting, title: detectTitle(ds), selfName: null, participants: [], activeSpeakers: [] };
    if (!inMeeting) return state;

    const tracked = [];
    const sources = [
      [TILE_SELECTORS, nameFromTile],
      [PANEL_ITEM_SELECTORS, nameFromPanelItem]
    ];
    for (const d of ds) {
      for (const [selectors, extract] of sources) {
        for (const el of OK.queryAll(d, selectors)) {
          const r = extract(el);
          if (!r) continue;
          if (r.self && !state.selfName) state.selfName = r.name;
          state.participants.push(r.name);
          tracked.push({ el, name: r.name, sel: OK.matchedSelector(el, selectors) });
          if (isSpeaking(el, r)) state.activeSpeakers.push(r.name);
        }
      }
      // Screen-reader announcements: "Jane Doe is talking".
      for (const live of d.querySelectorAll('[aria-live]')) {
        const text = (live.textContent || '').trim();
        if (text.length > 200 || !OK.labelSaysSpeaking(text)) continue;
        const n = OK.nameFromAriaLabel(text);
        if (n && !OK.isJunkName(n)) state.activeSpeakers.push(n);
      }
    }
    // Generic fallback when no explicit marker matched.
    const generic = speech ? speech.track(tracked) : [];
    if (!state.activeSpeakers.length) state.activeSpeakers.push(...generic);
    return state;
  }

  // The app.zoom.us PWA renders the call in an iframe the reporter's observer cannot see.
  window.__chrupioZoom = OK.createReporter('zoom', detect, { pollAlways: true });
})(typeof globalThis !== 'undefined' ? globalThis : this);
