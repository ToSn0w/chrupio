import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const OK = require('../content/common.js');

// ---------------------------------------------------------------- pure rate logic

test('countRecent counts timestamps inside the window only', () => {
  assert.equal(OK.countRecent([], 1000, 1500), 0);
  assert.equal(OK.countRecent([100, 600, 1200, 1900, 2000], 2000, 1500), 4);
  assert.equal(OK.countRecent([100, 500, 2500], 2000, 1500), 0);
  assert.equal(OK.countRecent([100, 200], 5000, 1500), 0);
});

test('pickBusyTiles picks the one busy tile among quiet ones', () => {
  assert.deepEqual(OK.pickBusyTiles([['a', 0], ['b', 18], ['c', 1], ['d', 0]]), ['b']);
  assert.deepEqual(OK.pickBusyTiles([['a', 10], ['b', 0]]), ['a']);
});

test('pickBusyTiles ignores tiles that are all equally busy', () => {
  assert.deepEqual(OK.pickBusyTiles([['a', 12], ['b', 11], ['c', 13]]), []);
  // Decoration on three tiles, one static tile: the median tile is busy, so nobody speaks.
  assert.deepEqual(OK.pickBusyTiles([['a', 10], ['b', 10], ['c', 10], ['d', 0]]), []);
});

test('pickBusyTiles needs a minimum rate and a baseline', () => {
  assert.deepEqual(OK.pickBusyTiles([['a', 3], ['b', 0], ['c', 0]]), []);
  assert.deepEqual(OK.pickBusyTiles([['a', 50]]), []);
  assert.deepEqual(OK.pickBusyTiles([]), []);
  // Busy tile over a noisy baseline must be both 4 above and twice the median.
  assert.deepEqual(OK.pickBusyTiles([['a', 9], ['b', 6], ['c', 6]]), []);
  assert.deepEqual(OK.pickBusyTiles([['a', 14], ['b', 6], ['c', 6]]), ['a']);
});

test('pickBusyTiles allows two simultaneous speakers among quiet tiles', () => {
  assert.deepEqual(OK.pickBusyTiles([['a', 12], ['b', 9], ['c', 0], ['d', 1]]), ['a', 'b']);
});

test('probeJson trims rows to fit and returns null when impossible', () => {
  const tiles = Array.from({ length: 50 }, (_, i) => ({ name: 'Person ' + i + 'x'.repeat(30), sel: '[data-participant-id]', recent: i, total: i }));
  const json = OK.probeJson({ v: 1, tiles, attrs: [{ name: 'class', count: 3 }] }, 1000);
  assert.ok(json.length <= 1000);
  const p = JSON.parse(json);
  assert.ok(p.tiles.length > 0 && p.tiles.length < 50);
  assert.equal(p.tiles[0].name.startsWith('Person 0'), true);
  assert.equal(OK.probeJson({ v: 1, pad: 'x'.repeat(200), tiles: [], attrs: [] }, 100), null);
});

// ---------------------------------------------------------------- detector with a fake MutationObserver

function withFakeObserver(fn) {
  const saved = globalThis.MutationObserver;
  const observers = [];
  globalThis.MutationObserver = class {
    constructor(cb) {
      this.cb = cb;
      this.targets = [];
      observers.push(this);
    }
    observe(t) {
      this.targets.push(t);
    }
    disconnect() {
      this.targets = [];
    }
  };
  try {
    return fn(observers);
  } finally {
    globalThis.MutationObserver = saved;
  }
}

function node(parent) {
  return { parentNode: parent || null, getAttribute: () => 'new' };
}

function mutate(obs, target, n, attr = 'class') {
  const records = Array.from({ length: n }, () => ({ attributeName: attr, oldValue: 'old', target }));
  obs.cb(records);
}

test('createSpeakingDetector maps nested mutations to their tile and picks the busy one', () => {
  withFakeObserver((observers) => {
    const tiles = ['Ann', 'Bob', 'Cid'].map((name) => ({ el: node(), name, sel: '[data-participant-id]' }));
    const bar = node(node(tiles[1].el)); // voice-level bar two levels inside Bob's tile
    const det = OK.createSpeakingDetector({});
    const obs = observers[0];
    assert.deepEqual(det.track(tiles), []);
    assert.equal(obs.targets.length, 3);
    mutate(obs, bar, 12);
    mutate(obs, tiles[0].el, 1);
    assert.deepEqual(det.track(tiles), ['Bob']);
    // Unchanged tile set: no re-observe.
    assert.equal(obs.targets.length, 3);
    const p = det.probe(8);
    assert.equal(p.tileCount, 3);
    assert.equal(p.tiles[0].name, 'Bob');
    assert.equal(p.tiles[0].total, 12);
    assert.equal(p.tiles[0].sel, '[data-participant-id]');
    assert.deepEqual(p.attrs, [{ name: 'class', count: 13 }]);
    assert.deepEqual(p.generic, ['Bob']);
    det.stop();
  });
});

test('createSpeakingDetector ignores uniform churn, same-value writes and unrelated attributes', () => {
  withFakeObserver((observers) => {
    const tiles = ['Ann', 'Bob', 'Cid'].map((name) => ({ el: node(), name }));
    const det = OK.createSpeakingDetector({});
    const obs = observers[0];
    det.track(tiles);
    for (const t of tiles) mutate(obs, t.el, 10);
    assert.deepEqual(det.speaking(), []);
    // Same value re-set and non-animation attributes do not count.
    const same = { parentNode: tiles[2].el, getAttribute: () => 'old' };
    const quiet = OK.createSpeakingDetector({});
    const obs2 = observers[1];
    quiet.track(tiles);
    mutate(obs2, same, 20);
    mutate(obs2, tiles[2].el, 20, 'src');
    assert.deepEqual(quiet.speaking(), []);
  });
});

test('createSpeakingDetector fires onChange when the busy set changes', () => {
  withFakeObserver((observers) => {
    let calls = 0;
    const tiles = ['Ann', 'Bob'].map((name) => ({ el: node(), name }));
    const det = OK.createSpeakingDetector({ onChange: () => calls++ });
    det.track(tiles);
    mutate(observers[0], tiles[0].el, 10);
    assert.equal(calls, 1);
    assert.deepEqual(det.speaking(), ['Ann']);
  });
});

// ---------------------------------------------------------------- reporter heartbeat

test('createReporter sends in-call state every ~1 s, idle every 30 s, speaker changes at once', () => {
  const saved = {
    chrome: globalThis.chrome,
    document: globalThis.document,
    location: globalThis.location,
    window: globalThis.window,
    setInterval: globalThis.setInterval,
    clearInterval: globalThis.clearInterval,
    now: Date.now
  };
  let clock = 1_000_000;
  let tickFn = null;
  const sent = [];
  try {
    withFakeObserver((observers) => {
      Date.now = () => clock;
      globalThis.chrome = { runtime: { id: 'x', lastError: null, sendMessage: (m) => sent.push(m) } };
      globalThis.document = { documentElement: {} };
      globalThis.location = { href: 'https://meet.google.com/abc-defg-hij' };
      globalThis.window = { addEventListener() {} };
      globalThis.setInterval = (fn) => {
        tickFn = fn;
        return 1;
      };
      globalThis.clearInterval = () => {};

      let inMeeting = false;
      let tiles = [];
      const rep = OK.createReporter('meet', (speech) => {
        const state = { inMeeting, title: 'T', participants: tiles.map((t) => t.name), activeSpeakers: [] };
        if (inMeeting) state.activeSpeakers = speech.track(tiles);
        return state;
      });
      assert.equal(sent.length, 1); // initial tick
      // Idle: nothing for 29 s, then a refresh.
      for (let i = 0; i < 116; i++) {
        clock += 250;
        tickFn();
      }
      assert.equal(sent.length, 1);
      clock += 1000;
      tickFn();
      assert.equal(sent.length, 2);

      inMeeting = true;
      tiles = ['Ann', 'Bob'].map((name) => ({ el: node(), name }));
      observers[1].cb([]); // page observer: DOM changed
      // Outside a call DOM churn is scraped at most every 5 s.
      clock += 1000;
      tickFn();
      assert.equal(sent.at(-1).state.inMeeting, false);
      clock += 4000;
      tickFn();
      assert.equal(sent.at(-1).state.inMeeting, true);
      const n0 = sent.length;
      for (let i = 0; i < 20; i++) {
        clock += 250;
        tickFn();
      }
      assert.equal(sent.length - n0, 5); // 5 s in call, one message per second

      // Ann starts speaking 300 ms after the last heartbeat: sent immediately, not on the next second.
      clock += 300;
      const detectorObserver = observers[0];
      mutate(detectorObserver, tiles[0].el, 10);
      assert.deepEqual(sent.at(-1).state.activeSpeakers, ['Ann']);
      assert.equal(sent.at(-1).changed, true);

      // Probe rides on a heartbeat at most every 30 s while in the call.
      const probes = [];
      for (let i = 0; i < 4 * 65; i++) {
        clock += 250;
        if (i % 4 === 0) mutate(detectorObserver, tiles[0].el, 1);
        tickFn();
        if (sent.at(-1).probe && !probes.includes(sent.at(-1))) probes.push(sent.at(-1));
      }
      assert.ok(probes.length >= 2 && probes.length <= 3);
      const p = probes[0].probe;
      assert.equal(p.v, 1);
      assert.equal(p.platform, 'meet');
      assert.ok(JSON.stringify(p).length < 4096);
      assert.equal(Array.isArray(p.tiles) && Array.isArray(p.attrs), true);
      rep.stop();
    });
  } finally {
    Object.assign(globalThis, {
      chrome: saved.chrome,
      document: saved.document,
      location: saved.location,
      window: saved.window,
      setInterval: saved.setInterval,
      clearInterval: saved.clearInterval
    });
    Date.now = saved.now;
  }
});

test('createReporter attaches a snapshot 15 s into a call, then at most every 5 min', () => {
  const saved = { chrome: globalThis.chrome, document: globalThis.document, location: globalThis.location, window: globalThis.window,
    setInterval: globalThis.setInterval, clearInterval: globalThis.clearInterval, now: Date.now };
  let clock = 2_000_000;
  let tickFn = null;
  const sent = [];
  try {
    withFakeObserver(() => {
      Date.now = () => clock;
      globalThis.chrome = { runtime: { id: 'x', lastError: null, sendMessage: (m) => sent.push(m) } };
      globalThis.document = { documentElement: {} };
      globalThis.location = { href: 'https://app.slack.com/client/T1/C1' };
      globalThis.window = { addEventListener() {} };
      globalThis.setInterval = (fn) => ((tickFn = fn), 1);
      globalThis.clearInterval = () => {};
      let calls = 0;
      const rep = OK.createReporter('slack', () => ({ inMeeting: true, title: 'T', participants: [], activeSpeakers: [] }),
        { snapshot: () => ({ v: 1, n: ++calls }) });
      const at = [];
      for (let i = 0; i < 4 * 700; i++) {
        clock += 250;
        tickFn();
        if (sent.at(-1).snapshot && !at.includes(sent.at(-1))) at.push(sent.at(-1));
      }
      assert.equal(at.length, 3); // ~15 s, ~315 s, ~615 s
      assert.ok(at[0].ts - 2_000_000 >= 15000 && at[0].ts - 2_000_000 < 17000);
      assert.equal(at[0].snapshot.n, 1);
      rep.stop();
    });
  } finally {
    Object.assign(globalThis, { chrome: saved.chrome, document: saved.document, location: saved.location, window: saved.window,
      setInterval: saved.setInterval, clearInterval: saved.clearInterval });
    Date.now = saved.now;
  }
});

test('createReporter relays from a mirror page and resends an unchanged probe every 2 min', () => {
  const saved = { chrome: globalThis.chrome, document: globalThis.document, location: globalThis.location, window: globalThis.window,
    setInterval: globalThis.setInterval, clearInterval: globalThis.clearInterval, now: Date.now };
  let clock = 3_000_000;
  let tickFn = null;
  let pagehide = null;
  const sent = [];
  try {
    withFakeObserver(() => {
      Date.now = () => clock;
      globalThis.chrome = { runtime: { id: 'x', lastError: null, sendMessage: (m) => sent.push(m) } };
      globalThis.document = { documentElement: {} };
      globalThis.location = { href: 'about:blank' };
      globalThis.window = { addEventListener: (type, fn) => type === 'pagehide' && (pagehide = fn) };
      globalThis.setInterval = (fn) => ((tickFn = fn), 1);
      globalThis.clearInterval = () => {};
      const rep = OK.createReporter('slack', () => ({ inMeeting: true, title: 'T', participants: ['Jane Doe'], activeSpeakers: [] }),
        { relay: () => true });
      for (let i = 0; i < 4 * 300; i++) {
        clock += 250;
        tickFn();
      }
      assert.ok(sent.length > 100);
      assert.ok(sent.every((m) => m.kind === 'relay'));
      const probes = sent.filter((m) => m.probe);
      // First at once, then the same probe again only after 120 s: 0, ~120, ~240 s of a 300 s run.
      assert.equal(probes.length, 3);
      pagehide();
      assert.equal(sent.at(-1).kind, 'relayGone');
      rep.stop();
    });
  } finally {
    Object.assign(globalThis, { chrome: saved.chrome, document: saved.document, location: saved.location, window: saved.window,
      setInterval: saved.setInterval, clearInterval: saved.clearInterval });
    Date.now = saved.now;
  }
});
