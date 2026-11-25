'use strict';

const HEALTH_URL = 'http://127.0.0.1:47811/health';
const PLATFORM_NAMES = { meet: 'Google Meet', teams: 'Microsoft Teams', slack: 'Slack huddle', zoom: 'Zoom' };

// One slow answer while the app is busy transcribing must not read as "not running"; two misses in a row do.
let misses = 0;

async function checkHealth() {
  const dot = document.getElementById('dot');
  const conn = document.getElementById('conn');
  let state = 'down';
  try {
    const res = await fetch(HEALTH_URL, { cache: 'no-store', signal: AbortSignal.timeout(3000) });
    const body = await res.json().catch(() => null);
    state = body && body.ok === true ? 'ok' : res.status === 403 ? 'refused' : 'down';
  } catch (_) {
    state = 'down';
  }
  misses = state === 'down' ? misses + 1 : 0;
  if (state === 'down' && misses < 2) return; // keep showing the last answer (or "Checking…")
  dot.className = 'dot ' + (state === 'ok' ? 'ok' : state === 'refused' ? 'bad refused' : 'bad');
  conn.textContent =
    state === 'ok' ? 'Connected to Chrupio' :
    state === 'refused' ? 'Chrupio refused this extension: reload it in chrome://extensions' :
    'Chrupio app not running';
}

function el(tag, attrs, text) {
  const n = document.createElement(tag);
  if (attrs) for (const [k, v] of Object.entries(attrs)) n.setAttribute(k, v);
  if (text != null) n.textContent = text;
  return n;
}

function renderMeeting(info) {
  const box = document.getElementById('meeting');
  box.replaceChildren(el('div', { class: 'label' }, 'Current meeting'));
  if (!info) {
    box.append(el('div', { class: 'empty' }, 'No meeting detected'));
    return;
  }
  const platform = PLATFORM_NAMES[info.platform] || info.platform;
  box.append(el('div', { class: 'meeting-title' }, info.title || platform));
  const count = info.participants.length;
  box.append(el('div', { class: 'meta' }, `${platform} · ${count} participant${count === 1 ? '' : 's'}`));
  if (!count) {
    box.append(el('div', { class: 'empty' }, 'Open the people panel if names are missing.'));
    return;
  }
  const speaking = new Set(info.activeSpeakers.map((s) => s.toLowerCase()));
  const self = (info.selfName || '').toLowerCase();
  const ul = el('ul');
  for (const name of info.participants) {
    const cls = [];
    if (speaking.has(name.toLowerCase())) cls.push('speaking');
    if (self && name.toLowerCase() === self) cls.push('self');
    ul.append(el('li', cls.length ? { class: cls.join(' ') } : null, name));
  }
  box.append(ul);
}

async function loadMeeting() {
  let status = null;
  try {
    status = await chrome.runtime.sendMessage({ kind: 'getStatus' });
  } catch (_) {
    status = null;
  }
  const tabs = (status && status.tabs) || [];
  let current = tabs.find((t) => t.inMeeting) || null;
  // Prefer the active tab when it is itself in a meeting.
  try {
    const [active] = await chrome.tabs.query({ active: true, currentWindow: true });
    const match = active && tabs.find((t) => t.tabId === active.id && t.inMeeting);
    if (match) current = match;
  } catch (_) {
    /* ignore */
  }
  renderMeeting(current);
}

function refresh() {
  checkHealth();
  loadMeeting();
}

document.getElementById('version').textContent = 'v' + chrome.runtime.getManifest().version;
refresh();
setInterval(refresh, 2000);
