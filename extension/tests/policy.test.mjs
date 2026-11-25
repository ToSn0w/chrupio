import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const P = require('../lib/policy.js');

test('platformOf maps only https meeting hosts', () => {
  assert.equal(P.platformOf('https://meet.google.com/abc-defg-hij'), 'meet');
  assert.equal(P.platformOf('https://teams.cloud.microsoft/v2/'), 'teams');
  assert.equal(P.platformOf('https://teams.live.com/v2/'), 'teams');
  assert.equal(P.platformOf('https://app.slack.com/client/T1/C1'), 'slack');
  assert.equal(P.platformOf('http://meet.google.com/abc-defg-hij'), null);
  assert.equal(P.platformOf('https://example.com'), null);
  assert.equal(P.platformOf(undefined), null);
});

test('meetingKeyOf uses the Meet code, platform for SPAs', () => {
  assert.equal(P.meetingKeyOf('meet', 'https://meet.google.com/ABC-defg-hij?authuser=1'), 'abc-defg-hij');
  assert.equal(P.meetingKeyOf('meet', 'https://meet.google.com/landing'), null);
  assert.equal(P.meetingKeyOf('teams', 'https://teams.microsoft.com/v2/#/chat'), 'teams');
});

test('decide: not-in-call tabs never post heartbeats', () => {
  assert.deepEqual(P.decide(undefined, false, 'slack', true, 1000), { endedPrev: false, postHeartbeat: false, lastPostAt: 0 });
  const prev = { inMeeting: false, meetingKey: 'slack', lastPostAt: 0 };
  assert.equal(P.decide(prev, false, 'slack', false, 99999).postHeartbeat, false);
});

test('decide: joining posts immediately, then at most every ~1 s unless changed', () => {
  const t0 = 1_000_000;
  const d0 = P.decide({ inMeeting: false, meetingKey: 'x', lastPostAt: 0 }, true, 'x', false, t0);
  assert.equal(d0.postHeartbeat, true);
  const rec = { inMeeting: true, meetingKey: 'x', lastPostAt: d0.lastPostAt };
  assert.equal(P.decide(rec, true, 'x', false, t0 + 400).postHeartbeat, false);
  assert.equal(P.decide(rec, true, 'x', true, t0 + 400).postHeartbeat, true);
  // Content ticks land ~1 s apart with jitter; 0.75 s is still due.
  assert.equal(P.decide(rec, true, 'x', false, t0 + 750).postHeartbeat, true);
});

test('decide: content heartbeats every 1-1.25 s are all posted', () => {
  let rec;
  let t = 0;
  const posts = [];
  for (let i = 0; i < 40; i++) {
    t += 1000 + (i % 2) * 250; // content tick: 1 or 1.25 s
    const d = P.decide(rec, true, 'abc-defg-hij', false, t);
    if (d.postHeartbeat) posts.push(t);
    rec = { inMeeting: true, meetingKey: 'abc-defg-hij', lastPostAt: d.lastPostAt };
  }
  assert.equal(posts.length, 40);
  for (let i = 1; i < posts.length; i++) assert.ok(posts[i] - posts[i - 1] <= 1500);
});

test('platformOf maps the Zoom web client only under /wc/', () => {
  assert.equal(P.platformOf('https://app.zoom.us/wc/123456789/join'), 'zoom');
  assert.equal(P.platformOf('https://us02web.zoom.us/wc/join/123456789'), 'zoom');
  assert.equal(P.platformOf('https://zoom.us/wc/123/start'), 'zoom');
  assert.equal(P.platformOf('https://zoom.us/j/123'), null);
  assert.equal(P.platformOf('https://evilzoom.us/wc/1'), null);
  assert.equal(P.meetingKeyOf('zoom', 'https://app.zoom.us/wc/1/join'), 'zoom');
});

test('decide: leaving or switching Meet code ends the previous meeting', () => {
  const rec = { inMeeting: true, meetingKey: 'aaa-bbbb-ccc', lastPostAt: 5 };
  assert.deepEqual(P.decide(rec, false, 'aaa-bbbb-ccc', true, 10), { endedPrev: true, postHeartbeat: false, lastPostAt: 0 });
  const sw = P.decide(rec, true, 'ddd-eeee-fff', true, 10);
  assert.equal(sw.endedPrev, true);
  assert.equal(sw.postHeartbeat, true);
});

test('createBackoff doubles up to the cap and resets on success', () => {
  const b = P.createBackoff(3000, 15000);
  assert.equal(b.canTry(0), true);
  b.failure(0);
  assert.equal(b.canTry(2999), false);
  assert.equal(b.canTry(3000), true);
  b.failure(3000); // +6 s
  assert.equal(b.canTry(8999), false);
  assert.equal(b.canTry(9000), true);
  b.failure(9000); // +12 s
  b.failure(21000); // capped +15 s
  assert.equal(b.canTry(35999), false);
  assert.equal(b.canTry(36000), true);
  b.success();
  assert.equal(b.failures, 0);
  assert.equal(b.canTry(36000), true);
});

test('callIdOf: a new id per joined call, kept while in it', () => {
  assert.equal(P.callIdOf(undefined, false, false, 1000), null);
  assert.equal(P.callIdOf(undefined, true, false, 1000), 1000);
  const inCall = { inMeeting: true, meetingKey: 'a', callId: 1000 };
  assert.equal(P.callIdOf(inCall, true, false, 5000), 1000);
  // Same tab, new Meet code: the old call ended, the new one gets its own id.
  assert.equal(P.callIdOf(inCall, true, true, 6000), 6000);
  // Left and rejoined (e.g. back-to-back huddles in one Slack tab).
  assert.equal(P.callIdOf({ inMeeting: false, callId: 1000 }, true, false, 7000), 7000);
  assert.equal(P.callIdOf(inCall, false, true, 8000), null);
});

test('mergeRelay unions participants and prefers the window speakers while fresh', () => {
  const tab = { inMeeting: true, url: 'https://app.slack.com/client/T1/C1', title: 'Huddle in x', participants: ['Łukasz Żurek'], activeSpeakers: ['Łukasz Żurek'] };
  const relay = { at: 1000, state: { inMeeting: true, title: null, participants: ['Lukasz Zurek', 'Jane Doe'], activeSpeakers: ['Jane Doe'] } };
  const m = P.mergeRelay(tab, relay, 2000);
  assert.deepEqual(m.participants, ['Łukasz Żurek', 'Jane Doe']);
  assert.deepEqual(m.activeSpeakers, ['Jane Doe']);
  assert.equal(m.title, 'Huddle in x');
  assert.equal(m.url, tab.url);
  // A window without speakers keeps the tab's; stale or ended relays change nothing.
  assert.deepEqual(P.mergeRelay(tab, { at: 1000, state: { ...relay.state, activeSpeakers: [] } }, 2000).activeSpeakers, ['Łukasz Żurek']);
  assert.equal(P.mergeRelay(tab, relay, 1000 + P.RELAY_FRESH_MS + 1), tab);
  assert.equal(P.mergeRelay(tab, { at: 1000, state: { ...relay.state, inMeeting: false } }, 2000), tab);
  assert.equal(P.mergeRelay(tab, null, 2000), tab);
});

test('relayTarget picks the opener in a call, else the only call tab on that platform', () => {
  const tabs = new Map([
    [1, { platform: 'slack', inMeeting: true }],
    [2, { platform: 'slack', inMeeting: false }],
    [3, { platform: 'meet', inMeeting: true }]
  ]);
  assert.equal(P.relayTarget(tabs, 1, 'slack'), 1);
  assert.equal(P.relayTarget(tabs, 2, 'slack'), 1);
  assert.equal(P.relayTarget(tabs, undefined, 'slack'), 1);
  tabs.set(4, { platform: 'slack', inMeeting: true });
  assert.equal(P.relayTarget(tabs, undefined, 'slack'), null);
  assert.equal(P.relayTarget(tabs, 4, 'slack'), 4);
});
