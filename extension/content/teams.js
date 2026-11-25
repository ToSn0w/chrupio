/* Chrupio: Microsoft Teams (web) scraper. Depends on content/common.js. */
(function () {
  'use strict';
  // Injected again after an extension update; a reporter from the old version has stopped.
  const running = window.__chrupioTeams;
  if (running && typeof running.alive === 'function' && running.alive()) return;
  window.__chrupioTeams = { alive: () => true };

  const OK = globalThis.Chrupio;

  // Hang-up / leave controls only rendered in an active call.
  const HANGUP_SELECTORS = [
    '[data-tid="hangup-main-btn"]',
    '#hangup-button',
    '[data-tid="hangup-button"]',
    '[data-tid="call-hangup"]',
    '[data-tid="hangup-leave-button"]',
    '[data-tid="hangup-end-meeting-button"]',
    'button[aria-label^="Leave" i][data-tid*="hangup" i]',
    'button[id*="hangup" i]',
    '[data-inp="hangup-button"]',
    '[data-track-module-name="hangupButton"]'
  ];

  // Pre-join screen: never in a call while this is showing without a hangup control.
  const PREJOIN_SELECTORS = [
    '[data-tid="prejoin-join-button"]',
    '[data-tid="prejoin-display-name-input"]',
    '[data-tid="pre-join-screen"]'
  ];

  // Leave labels for the stage fallback (aria-label prefix, several locales).
  const LEAVE_LABEL_RE = /^(?:leave|hang up|end call|opuść|rozłącz|zakończ|verlassen|auflegen|quitter|raccrocher|salir|colgar|abandonar|sair|desligar|abbandona|esci|riaggancia|verlaten|ophangen|покинуть|завершить|退出|離開|終了|나가기)/i;

  // Containers whose presence also indicates the call stage is mounted.
  const CALL_STAGE_SELECTORS = [
    '[data-tid="call-composite"]',
    '[data-tid="calling-screen"]',
    '[data-tid="modern-stage-wrapper"]',
    '[data-tid="meeting-stage"]'
  ];

  // Video/avatar tiles on stage. aria-label usually "Name, Muted, Video off".
  const TILE_SELECTORS = [
    '[data-tid="video-tile"]',
    '[data-tid^="video-tile-"]',
    '[data-cid="calling-participant-stream"]',
    '[data-stream-type][aria-label]',
    '[data-tid="participant-tile"]',
    '[data-tid="calling-stream"]'
  ];

  // Roster (People pane) entries.
  const ROSTER_ITEM_SELECTORS = [
    '[data-tid^="participantsInCall-"]',
    '[data-tid="roster-participant"]',
    '[data-tid*="roster"] [role="treeitem"]',
    '[data-tid*="roster"] [role="listitem"]',
    '[aria-label*="participants" i] [role="treeitem"]',
    '[aria-label*="uczestnicy" i] [role="treeitem"]'
  ];

  const ROSTER_NAME_SELECTORS = [
    '[data-tid="roster-participant-name"]',
    '[data-tid*="participant-name"]',
    'span[title]',
    '[id^="roster-avatar-img-"]'
  ];

  const SPEAKING_SELECTORS = [
    '[data-tid="voice-level-stream-outline"][data-is-speaking="true"]',
    '[data-is-speaking="true"]',
    '[data-tid*="speaking" i]',
    '[class*="speaking" i]:not([class*="not-speaking" i])'
  ];

  function detectInMeeting() {
    // Hangup controls exist only while connected (also in the compact call
    // window shown when the user browses chat mid-call). Chat pages and the
    // pre-join screen have none.
    if (OK.queryFirst(document, HANGUP_SELECTORS)) return true;
    if (OK.queryFirst(document, PREJOIN_SELECTORS)) return false;
    // Some builds lazy-render the toolbar; the stage plus a "Leave" button suffices.
    if (OK.queryFirst(document, CALL_STAGE_SELECTORS)) {
      for (const b of document.querySelectorAll('button[aria-label]')) {
        if (LEAVE_LABEL_RE.test(b.getAttribute('aria-label') || '')) return true;
      }
    }
    return false;
  }

  function nameFromTile(tile) {
    const label = tile.getAttribute('aria-label');
    if (label) {
      const n = OK.nameFromAriaLabel(label);
      if (n && !OK.isJunkName(n)) return { name: n, label };
    }
    const named = OK.queryFirst(tile, ['[data-tid="display-name"]', '[data-tid*="displayname" i]', '[data-tid*="name" i]', 'span[title]']);
    if (named) {
      const raw = named.getAttribute('title') || named.textContent;
      const n = OK.cleanName(raw);
      if (n && !OK.isJunkName(n)) return { name: n, label: raw };
    }
    const text = OK.firstNameText(tile);
    return text ? { name: text, label: text } : null;
  }

  function nameFromRosterItem(item) {
    // New Teams roster rows: data-tid="participantsInCall-<display name>" (locale-independent).
    const tidName = OK.nameFromPrefixedAttr(item.getAttribute('data-tid'), 'participantsInCall-');
    for (const el of OK.queryAll(item, ROSTER_NAME_SELECTORS)) {
      const raw = el.getAttribute('title') || el.getAttribute('aria-label') || el.textContent;
      const n = OK.nameFromAriaLabel(raw);
      if (n && !OK.isJunkName(n)) return { name: n, label: raw };
    }
    const label = item.getAttribute('aria-label');
    if (tidName) return { name: tidName, label: label || tidName };
    if (label) {
      const n = OK.nameFromAriaLabel(label);
      if (n && !OK.isJunkName(n)) return { name: n, label };
    }
    const text = OK.firstNameText(item);
    return text ? { name: text, label: text } : null;
  }

  function isSpeaking(el, label) {
    if (OK.labelSaysSpeaking(label)) return true;
    if (OK.labelSaysSpeaking(el.getAttribute('aria-label'))) return true;
    return !!OK.queryFirst(el, SPEAKING_SELECTORS) || SPEAKING_SELECTORS.some((s) => {
      try {
        return el.matches(s);
      } catch (_) {
        return false;
      }
    });
  }

  function detectSelfName() {
    // Display-name elements hold the plain name (rendered when the account menu is open).
    const shown = OK.queryFirst(document, ['[data-tid="me-control-displayname"]', '[data-tid="me-control-display-name"]']);
    if (shown) {
      const n = OK.cleanName(shown.getAttribute('title') || shown.textContent);
      if (n && !OK.isJunkName(n)) return n;
    }
    // Avatar labels vary: "Profile picture of Jane Doe." (parse) vs. new Teams'
    // "Your profile picture with status displayed as Available." (no name: skip).
    for (const el of OK.queryAll(document, [
      '[data-tid="me-control-avatar-trigger"]',
      '#idna-me-control-avatar-trigger',
      'button[id*="me-control" i]',
      '[data-tid="me-control-avatar-trigger"] img[alt]',
      '#idna-me-control-avatar-trigger img[alt]'
    ])) {
      for (const raw of [el.getAttribute('aria-label'), el.getAttribute('title'), el.getAttribute('alt')]) {
        const n = OK.nameFromProfileLabel(raw);
        if (n) return n;
      }
    }
    return null;
  }

  function detectTitle() {
    const el = OK.queryFirst(document, [
      '[data-tid="call-title"]',
      '[data-tid="meeting-title"]',
      '[data-tid="calling-header-title"]',
      '[data-tid="call-status-title"]'
    ]);
    const t = el ? OK.cleanName(el.getAttribute('title') || el.textContent) : '';
    if (t) return t;
    // New Teams: "Chat | Jane Doe | Microsoft Teams", "Meeting with X | Microsoft Teams".
    return OK.cleanTitle(document.title, [
      'Microsoft Teams',
      /\s*\|\s*(?:Calendar|Chat|Teams|Activity|Calls)\s*$/i,
      /^(?:Meeting|Call|Chat|Calendar|Activity|Teams|Calls)\s*\|\s*/i
    ]);
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
    if (!inMeeting) return state;

    const sources = [
      [OK.queryAll(document, TILE_SELECTORS), nameFromTile, TILE_SELECTORS],
      [OK.queryAll(document, ROSTER_ITEM_SELECTORS), nameFromRosterItem, ROSTER_ITEM_SELECTORS]
    ];
    const tracked = [];
    for (const [nodes, extract, selectors] of sources) {
      for (const el of nodes) {
        const r = extract(el);
        if (!r) continue;
        if (OK.hasSelfMarker(r.label)) {
          if (!state.selfName) state.selfName = r.name;
        }
        state.participants.push(r.name);
        tracked.push({ el, name: r.name, sel: OK.matchedSelector(el, selectors) });
        if (isSpeaking(el, r.label)) state.activeSpeakers.push(r.name);
      }
    }
    // Generic fallback when no explicit speaking marker matched.
    const generic = speech ? speech.track(tracked) : [];
    if (!state.activeSpeakers.length) state.activeSpeakers.push(...generic);
    return state;
  }

  window.__chrupioTeams = OK.createReporter('teams', detect);
})();
