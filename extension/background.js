/*
 * Chrupio service worker.
 *
 * Content scripts push page state every 1 s while in a call (30 s otherwise) and
 * immediately on change. That message stream is the heartbeat driver: each
 * runtime message wakes this worker and resets its 30 s idle timer, so an
 * in-call tab yields a POST every ~1 s without relying on chrome.alarms
 * (whose 30 s minimum period is far above the native side's 12 s timeout).
 * Calls keep their tab exempt from Chrome's intensive background-timer
 * throttling (WebRTC/audio), so the 1 s content-script interval keeps running.
 * Only in-call tabs produce "meeting" POSTs. Per-tab state lives in
 * chrome.storage.session so it survives suspension. A 30 s chrome.alarms sweep
 * catches tabs whose content script died.
 *
 * Protocol (do not change without the Swift side):
 *   POST http://127.0.0.1:47811/v1/event
 *     {"type":"meeting", platform, tabId, callId, url, title, inMeeting, participants,
 *      activeSpeakers, selfName, ts, probe?}   probe: selector-tuning snapshot, shape in content/common.js
 *     {"type":"ended", platform, tabId, ts}
 *   POST http://127.0.0.1:47811/v1/snapshot
 *     {platform, tabId, callId, ts, snapshot}   page structure when a call shows nobody; shape in content/slack.js
 *
 * A page that only mirrors a call (Slack's pop-out huddle window) sends kind 'relay'; its people and
 * speakers are merged into the heartbeats of the tab that opened it (see mergeRelay in lib/policy.js).
 */
'use strict';

importScripts('lib/policy.js');
const { platformOf, meetingKeyOf, decide, callIdOf, createBackoff, mergeRelay, relayTarget } = self.ChrupioPolicy;

const APP_BASE = 'http://127.0.0.1:47811';
const EVENT_URL = APP_BASE + '/v1/event';
const HELLO_URL = APP_BASE + '/v1/hello';
const STALE_MS = 45000; // no message from a tracked tab for this long → ended + forgotten
const REQUEST_TIMEOUT_MS = 2000;
const SWEEP_ALARM = 'chrupio-sweep';
const STORAGE_KEY = 'tabs';

// ------------------------------------------------------------------ state

/** @type {Map<number, {platform:string,url:string,inMeeting:boolean,meetingKey:string|null,lastSeen:number,lastPostAt:number,state:object}>|null} */
let tabs = null;
let loading = null;
let appReachable = null; // null = unknown
let failureLogged = false;
// Pop-out window tabId -> {target, platform, state, at}. In memory: a relay is only used while fresh (5 s).
const relays = new Map();
const RELAY_PLATFORMS = new Set(['slack']);
// Chrome logs every refused fetch (net::ERR_CONNECTION_REFUSED) in the worker
// console; backing off keeps a stopped app from producing a log line per heartbeat.
const backoff = createBackoff(3000, 15000);

function load() {
  if (tabs) return Promise.resolve(tabs);
  if (!loading) {
    loading = chrome.storage.session
      .get(STORAGE_KEY)
      .then((res) => {
        const stored = (res && res[STORAGE_KEY]) || {};
        tabs = new Map(Object.entries(stored).map(([k, v]) => [Number(k), v]));
        return tabs;
      })
      .catch(() => {
        tabs = new Map();
        return tabs;
      });
  }
  return loading;
}

function persist() {
  if (!tabs) return;
  const obj = {};
  for (const [k, v] of tabs) obj[k] = v;
  chrome.storage.session.set({ [STORAGE_KEY]: obj }).catch(() => {});
}

// ------------------------------------------------------------------ helpers

async function post(payload, force, url = EVENT_URL) {
  if (!force && !backoff.canTry(Date.now())) return false;
  try {
    const res = await fetch(url, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      // The app compares this with its bundled copy and asks for a reload when it is older.
      body: JSON.stringify({ ...payload, extensionVersion: chrome.runtime.getManifest().version }),
      signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
      cache: 'no-store'
    });
    // Any answer means the app is running; back off only when it isn't, or a rejected
    // event would delay the heartbeats that follow it.
    appReachable = true;
    failureLogged = false;
    backoff.success();
    return res.ok;
  } catch (e) {
    appReachable = false;
    backoff.failure(Date.now());
    if (!failureLogged) {
      failureLogged = true;
      console.debug('[Chrupio] app not reachable at ' + APP_BASE + '; will retry on next heartbeat');
    }
    return false;
  }
}

// Presence ping, so the app shows the extension as connected when no call is open. Never starts a recording.
// Respects the backoff: a stopped app should not get a refused fetch per sweep.
function sendHello() {
  return post({}, false, HELLO_URL);
}

function sendEnded(tabId, platform) {
  // Respects the backoff too; while the app is down it ends the call on its own heartbeat timeout.
  return post({ type: 'ended', platform, tabId, ts: Date.now() }, false);
}

const PROBE_MAX_CHARS = 4096;
const SNAPSHOT_URL = APP_BASE + '/v1/snapshot';
const SNAPSHOT_MAX_CHARS = 290000; // the app takes up to 300 KB

// Structure of a call page that showed nobody's name; the app keeps the newest few for selector tuning.
function sendSnapshot(platform, snapshot, tabId, callId) {
  const body = { platform, tabId, callId: callId || null, ts: Date.now(), snapshot };
  if (JSON.stringify(body).length > SNAPSHOT_MAX_CHARS) return Promise.resolve(false);
  return post(body, true, SNAPSHOT_URL);
}

function sendHeartbeat(tabId, s, callId, probe) {
  const extra = {};
  if (probe && typeof probe === 'object' && JSON.stringify(probe).length < PROBE_MAX_CHARS) extra.probe = probe;
  return post({
    type: 'meeting',
    platform: s.platform,
    tabId,
    callId,
    url: s.url,
    title: s.title == null ? null : String(s.title),
    inMeeting: !!s.inMeeting,
    participants: Array.isArray(s.participants) ? s.participants : [],
    activeSpeakers: Array.isArray(s.activeSpeakers) ? s.activeSpeakers : [],
    selfName: s.selfName == null ? null : String(s.selfName),
    ts: Date.now(),
    ...extra
  });
}

async function endAndForget(tabId) {
  const map = await load();
  const rec = map.get(tabId);
  if (!rec) return;
  map.delete(tabId);
  persist();
  if (rec.inMeeting) await sendEnded(tabId, rec.platform);
}

// ------------------------------------------------------------------ core

/** The freshest relay into call tab `tabId`, or null. */
function relayInto(tabId, now) {
  let best = null;
  for (const r of relays.values()) {
    if (r.target === tabId && now - r.at <= 5000 && (!best || r.at > best.at)) best = r;
  }
  return best;
}

// What the app last got for a tab, so a relay change posts at once and repeats do not.
function postedKey(s) {
  return JSON.stringify([s.title || null, s.participants || [], s.activeSpeakers || []]);
}

const PERSIST_SEEN_MS = 10000;
const persistedSeen = new Map(); // tabId -> lastSeen last written to storage.session

function recordKey(r) {
  return JSON.stringify([r.platform, r.url, r.inMeeting, r.meetingKey, r.callId, r.posted, r.state]);
}

async function handleState(tabId, state, changed, probe) {
  const platform = platformOf(state.url);
  if (!platform || platform !== state.platform) return;
  const map = await load();
  const now = Date.now();
  const key = meetingKeyOf(platform, state.url);
  const prev = map.get(tabId);

  const isIn = !!state.inMeeting;
  const merged = mergeRelay(state, relayInto(tabId, now), now);
  const posted = postedKey(merged);
  // A probe rides on the next POST, so it forces one.
  const d = decide(prev, isIn, key, changed || !!probe || (prev && prev.posted !== posted), now);
  const callId = callIdOf(prev, isIn, d.endedPrev, now);
  // Update the record before any await so concurrent messages see the new state.
  const rec = {
    platform,
    url: state.url,
    inMeeting: isIn,
    meetingKey: key,
    callId,
    lastSeen: now,
    lastPostAt: d.lastPostAt,
    posted: d.postHeartbeat ? posted : prev && prev.posted,
    state
  };
  map.set(tabId, rec);
  // storage.session only when the record changed beyond its timestamps; lastSeen is refreshed
  // every PERSIST_SEEN_MS so the sweep after a worker restart does not see a live tab as stale.
  if (!prev || recordKey(prev) !== recordKey(rec) || now - (persistedSeen.get(tabId) || 0) >= PERSIST_SEEN_MS) {
    persistedSeen.set(tabId, now);
    persist();
  }

  if (d.endedPrev) await sendEnded(tabId, prev.platform);
  if (d.postHeartbeat) await sendHeartbeat(tabId, merged, callId, isIn ? probe : null);
}

async function handleRelay(windowTabId, openerTabId, state, probe, snapshot) {
  if (!RELAY_PLATFORMS.has(state.platform)) return;
  const map = await load();
  const now = Date.now();
  const target = relayTarget(map, openerTabId, state.platform);
  relays.set(windowTabId, { target, platform: state.platform, state, at: now });
  if (target == null) return;
  const rec = map.get(target);
  if (snapshot && state.inMeeting) sendSnapshot(state.platform, snapshot, target, rec.callId);
  const merged = mergeRelay(rec.state, relayInto(target, now), now);
  const posted = postedKey(merged);
  if (posted === rec.posted && !probe) return;
  rec.posted = posted;
  rec.lastPostAt = now;
  persist();
  await sendHeartbeat(target, merged, rec.callId, probe);
}

async function handleGone(tabId) {
  const map = await load();
  const rec = map.get(tabId);
  if (!rec || !rec.inMeeting) return;
  rec.inMeeting = false;
  rec.state = Object.assign({}, rec.state, { inMeeting: false, participants: [], activeSpeakers: [] });
  persist();
  await sendEnded(tabId, rec.platform);
}

async function sweep() {
  const map = await load();
  const now = Date.now();
  for (const [tabId, rec] of [...map]) {
    let exists = true;
    try {
      await chrome.tabs.get(tabId);
    } catch (_) {
      exists = false;
    }
    if (!exists || now - rec.lastSeen > STALE_MS) await endAndForget(tabId);
  }
}

async function status() {
  const map = await load();
  const list = [];
  for (const [tabId, rec] of map) {
    list.push({
      tabId,
      platform: rec.platform,
      inMeeting: rec.inMeeting,
      title: rec.state && rec.state.title,
      url: rec.url,
      participants: (rec.state && rec.state.participants) || [],
      activeSpeakers: (rec.state && rec.state.activeSpeakers) || [],
      selfName: (rec.state && rec.state.selfName) || null,
      lastSeen: rec.lastSeen
    });
  }
  list.sort((a, b) => Number(b.inMeeting) - Number(a.inMeeting) || b.lastSeen - a.lastSeen);
  return { tabs: list, appReachable };
}

// ------------------------------------------------------------------ wiring

chrome.runtime.onMessage.addListener((msg, sender, sendResponse) => {
  if (!msg || typeof msg !== 'object') return false;
  const tabId = sender.tab && sender.tab.id;

  if (msg.kind === 'getStatus') {
    status().then(sendResponse, () => sendResponse({ tabs: [], appReachable }));
    return true;
  }
  // Only accept page state from top-level frames of real tabs.
  if (typeof tabId !== 'number' || tabId < 0 || sender.frameId !== 0) return false;

  if (msg.kind === 'relay' && msg.state && typeof msg.state === 'object') {
    const snapshot = msg.snapshot && typeof msg.snapshot === 'object' ? msg.snapshot : null;
    handleRelay(tabId, sender.tab.openerTabId, msg.state, msg.probe || null, snapshot).finally(() => sendResponse({ ok: true }));
    return true;
  }
  if (msg.kind === 'relayGone') {
    relays.delete(tabId);
    sendResponse({ ok: true });
    return false;
  }
  if (msg.kind === 'state' && msg.state) {
    if (msg.snapshot && typeof msg.snapshot === 'object' && msg.state.inMeeting) {
      const rec = tabs && tabs.get(tabId);
      sendSnapshot(msg.state.platform, msg.snapshot, tabId, rec && rec.inMeeting ? rec.callId : null);
    }
    handleState(tabId, msg.state, !!msg.changed, msg.probe || null).finally(() => sendResponse({ ok: true }));
    return true;
  }
  if (msg.kind === 'gone') {
    handleGone(tabId).finally(() => sendResponse({ ok: true }));
    return true;
  }
  return false;
});

chrome.tabs.onRemoved.addListener((tabId) => {
  relays.delete(tabId);
  endAndForget(tabId);
});

// Prerender / instant-navigation swaps replace the tab id; the old id is gone.
chrome.tabs.onReplaced.addListener((_addedTabId, removedTabId) => {
  endAndForget(removedTabId);
});

chrome.tabs.onUpdated.addListener(async (tabId, changeInfo, tab) => {
  if (!('url' in changeInfo) && changeInfo.status !== 'loading') return;
  const map = await load();
  const rec = map.get(tabId);
  if (!rec) return;
  // Without the "tabs" permission the URL is only visible for our host origins,
  // so an unreadable URL means the tab navigated off the meeting site.
  const url = changeInfo.url || (tab && tab.url) || null;
  const platform = url ? platformOf(url) : null;
  if (!platform) {
    await endAndForget(tabId);
    return;
  }
  const key = meetingKeyOf(platform, url);
  if (rec.inMeeting && (platform !== rec.platform || key !== rec.meetingKey)) {
    rec.inMeeting = false;
    rec.url = url;
    rec.meetingKey = key;
    persist();
    await sendEnded(tabId, rec.platform);
  }
});

function ensureAlarm() {
  chrome.alarms.get(SWEEP_ALARM).then((a) => {
    if (!a) chrome.alarms.create(SWEEP_ALARM, { periodInMinutes: 0.5 });
  });
}

chrome.alarms.onAlarm.addListener((alarm) => {
  if (alarm.name === SWEEP_ALARM) {
    sendHello();
    sweep();
  }
});

// Tabs opened before an install or update still run the old (now orphaned) content scripts.
async function injectIntoOpenTabs() {
  for (const script of chrome.runtime.getManifest().content_scripts || []) {
    let open = [];
    try {
      open = await chrome.tabs.query({ url: script.matches });
    } catch (_) {
      continue;
    }
    for (const tab of open) {
      if (typeof tab.id !== 'number' || tab.discarded) continue;
      chrome.scripting.executeScript({ target: { tabId: tab.id }, files: script.js }).catch(() => {});
    }
  }
}

chrome.runtime.onInstalled.addListener(() => {
  ensureAlarm();
  injectIntoOpenTabs();
});
chrome.runtime.onStartup.addListener(ensureAlarm);
ensureAlarm();
sendHello();
