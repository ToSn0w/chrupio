/*
 * Chrupio service-worker policy: pure functions, no chrome APIs.
 * Loaded by background.js via importScripts() and by Node tests via require().
 */
(function (root) {
  'use strict';

  const HEARTBEAT_MS = 1000; // in-call POST rate, so activeSpeakers reach the app at 1 s resolution
  const HEARTBEAT_SLACK_MS = 300; // tolerate timer jitter in content-script ticks

  const PLATFORM_HOSTS = {
    'meet.google.com': 'meet',
    'teams.microsoft.com': 'teams',
    'teams.live.com': 'teams',
    'teams.cloud.microsoft': 'teams',
    'app.slack.com': 'slack'
  };

  function platformOf(url) {
    try {
      const u = new URL(url);
      if (u.protocol !== 'https:') return null;
      // Zoom web client: zoom.us, app.zoom.us and vanity/regional hosts, only under /wc/.
      if ((u.hostname === 'zoom.us' || u.hostname.endsWith('.zoom.us')) && u.pathname.startsWith('/wc/')) return 'zoom';
      return PLATFORM_HOSTS[u.hostname] || null;
    } catch (_) {
      return null;
    }
  }

  /** Identity of the meeting within a tab; a change means the old meeting ended. */
  function meetingKeyOf(platform, url) {
    if (platform !== 'meet') return platform; // Teams/Slack/Zoom are SPAs; URL changes mid-call.
    try {
      const m = /^\/([a-z]{3}-[a-z]{4}-[a-z]{3})(?:$|[/?#])/i.exec(new URL(url).pathname);
      return m ? m[1].toLowerCase() : null;
    } catch (_) {
      return null;
    }
  }

  /**
   * Decide what to send for an incoming content-script state message.
   * prev: stored record ({inMeeting, meetingKey, lastPostAt}) or undefined.
   * Returns {endedPrev, postHeartbeat, lastPostAt}.
   * Only in-meeting tabs produce "meeting" heartbeats; leaving produces one "ended".
   */
  function decide(prev, isIn, key, changed, now) {
    const wasIn = !!(prev && prev.inMeeting);
    const endedPrev = wasIn && (!isIn || prev.meetingKey !== key);
    const prevPostAt = prev && !endedPrev ? prev.lastPostAt || 0 : 0;
    const due = now - prevPostAt >= HEARTBEAT_MS - HEARTBEAT_SLACK_MS;
    const postHeartbeat = !!isIn && (!!changed || due || !wasIn || endedPrev);
    return { endedPrev, postHeartbeat, lastPostAt: postHeartbeat ? now : prevPostAt };
  }

  /**
   * Call identity within a tab: the time the tab joined this call, so two calls back to
   * back in one tab are two meetings in the app. null while not in a call.
   */
  function callIdOf(prev, isIn, endedPrev, now) {
    if (!isIn) return null;
    const wasIn = !!(prev && prev.inMeeting);
    if (!wasIn || endedPrev || !prev.callId) return now;
    return prev.callId;
  }

  /**
   * Exponential backoff for an unreachable app, so a stopped app costs one
   * failed request per backoff window instead of one per heartbeat per tab.
   */
  function createBackoff(baseMs, maxMs) {
    const base = baseMs || 3000;
    const max = maxMs || 15000;
    let failures = 0;
    let nextAt = 0;
    return {
      canTry(now) {
        return now >= nextAt;
      },
      success() {
        failures = 0;
        nextAt = 0;
      },
      failure(now) {
        failures++;
        nextAt = now + Math.min(max, base * Math.pow(2, failures - 1));
      },
      get failures() {
        return failures;
      }
    };
  }

  const RELAY_FRESH_MS = 5000; // a relayed window state older than this no longer counts

  function relayKey(name) {
    return String(name || '')
      .normalize('NFKD')
      .replace(/[\u0300-\u036f]/g, '')
      .replace(/\s+/g, ' ')
      .trim()
      .toLowerCase()
      .replace(/ł/g, 'l') // the one Polish letter NFKD does not decompose
      .replace(/ø/g, 'o');
  }

  /**
   * A call tab's state with what its pop-out window relayed (Slack's huddle window shows the
   * people and speakers the client tab cannot see). Participants are the union; the window's
   * speakers win when it has any, since its grid marks the speaker directly.
   * relay: {state, at} or null. Returns the tab state unchanged when there is nothing fresh.
   */
  function mergeRelay(state, relay, now) {
    if (!state || !state.inMeeting || !relay || !relay.state || !relay.state.inMeeting) return state;
    if (now - (relay.at || 0) > RELAY_FRESH_MS) return state;
    const union = (a, b) => {
      const seen = new Set();
      const out = [];
      for (const n of [...(a || []), ...(b || [])]) {
        const k = relayKey(n);
        if (!k || seen.has(k)) continue;
        seen.add(k);
        out.push(n);
      }
      return out;
    };
    const relayed = relay.state.activeSpeakers || [];
    return Object.assign({}, state, {
      title: state.title || relay.state.title || null,
      selfName: state.selfName || relay.state.selfName || null,
      participants: union(state.participants, relay.state.participants),
      activeSpeakers: relayed.length ? union(relayed, []) : state.activeSpeakers || []
    });
  }

  /**
   * The call tab a relaying window belongs to: its opener when that tab is in a call on the same
   * platform, else the only such tab. tabs: Map of tabId -> record ({platform, inMeeting}).
   */
  function relayTarget(tabs, openerTabId, platform) {
    const opener = openerTabId != null ? tabs.get(openerTabId) : null;
    if (opener && opener.inMeeting && opener.platform === platform) return openerTabId;
    const inCall = [...tabs].filter(([, r]) => r.inMeeting && r.platform === platform);
    return inCall.length === 1 ? inCall[0][0] : null;
  }

  const api = { HEARTBEAT_MS, HEARTBEAT_SLACK_MS, RELAY_FRESH_MS, PLATFORM_HOSTS, platformOf, meetingKeyOf, decide, callIdOf, createBackoff, mergeRelay, relayTarget };
  root.ChrupioPolicy = api;
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
