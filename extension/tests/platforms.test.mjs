import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
require('../content/common.js');
const Slack = require('../content/slack.js');
const Zoom = require('../content/zoom.js');
const Meet = require('../content/meet.js');

// ---------------------------------------------------------------- Google Meet

test('Meet hasSpeakingClass reads the voice-level indicator classes', () => {
  assert.equal(Meet.hasSpeakingClass(['IisKdb Oaajhc']), true);
  assert.equal(Meet.hasSpeakingClass(['DYfzY cYKTje gjg47c']), false);
  assert.equal(Meet.hasSpeakingClass(['IisKdb gjg47c HX2H7']), false, 'silence class wins on the same element');
  assert.equal(Meet.hasSpeakingClass(['foo', 'bar wEsLMd']), true);
  assert.equal(Meet.hasSpeakingClass([null, '']), false);
});

test('Meet outermostTiles keeps one element per nested participant id', () => {
  const el = (parent) => ({ parent, contains(o) { for (let n = o; n; n = n.parent) if (n === this) return true; return false; } });
  const ann = el(null);
  const annInner = el(el(ann));
  const bob = el(null);
  const pip = el(ann); // another person's tile shown inside Ann's
  const items = [
    { el: ann, id: 'p/1' }, { el: annInner, id: 'p/1' }, { el: bob, id: 'p/2' }, { el: pip, id: 'p/3' }
  ];
  assert.deepEqual(Meet.outermostTiles(items).map((t) => t.id), ['p/1', 'p/2', 'p/3']);
});

test('Meet captionSpeakers names the block whose text changed', () => {
  const prev = new Map();
  const known = ['Jane Doe', 'Bob Smith'];
  const blocks = (janeText, bobText) => [
    { key: 1, lines: ['Jane Doe', janeText] },
    { key: 2, lines: ['You', bobText] },
    { key: 3, lines: ['Only one line'] }
  ];
  assert.deepEqual(Meet.captionSpeakers(blocks('Hello', 'Hi'), prev, known, 'Bob Smith'), [], 'first sight is a baseline');
  assert.deepEqual(Meet.captionSpeakers(blocks('Hello there', 'Hi'), prev, known, 'Bob Smith'), ['Jane Doe']);
  assert.deepEqual(Meet.captionSpeakers(blocks('Hello there', 'Hi all'), prev, known, 'Bob Smith'), ['Bob Smith'], 'You is the local user');
  assert.deepEqual(Meet.captionSpeakers(blocks('Hello there', 'Hi all'), prev, known, 'Bob Smith'), []);
});

test('Meet combineSpeakers: captions win, then labels; guards hints, falls back to mutation rate', () => {
  assert.deepEqual(Meet.combineSpeakers({ attr: ['Ann'], captions: ['ann', 'Bob'], cls: ['Cid'], generic: ['Cid'] }, 3),
    { speakers: ['ann', 'Bob'], via: ['captions'] });
  assert.deepEqual(Meet.combineSpeakers({ attr: ['Ann'], captions: [], generic: ['Cid'] }, 3), { speakers: ['Ann'], via: ['attr'] });
  assert.deepEqual(Meet.combineSpeakers({ cls: ['Ann', 'Bob', 'Cid'], visual: ['Ann', 'Bob', 'Cid'], generic: ['Bob'] }, 3),
    { speakers: ['Bob'], via: ['generic'] }, 'an indicator on every tile is decoration');
  assert.deepEqual(Meet.combineSpeakers({ cls: ['Bob'], visual: [], generic: ['Cid'] }, 3), { speakers: ['Bob'], via: ['cls'] });
  assert.deepEqual(Meet.combineSpeakers({}, 2), { speakers: [], via: [] });
});

// ---------------------------------------------------------------- Slack huddle

test('Slack peerTileName reads names from 2026 huddle grid tiles', () => {
  assert.equal(Slack.peerTileName({ ariaLabel: "View Jane Doe's profile" }), 'Jane Doe');
  assert.equal(Slack.peerTileName({ ariaLabel: "View James' profile" }), 'James');
  assert.equal(Slack.peerTileName({ labels: ['Mute', 'Zobacz profil użytkownika Łukasz Żurek'] }), 'Łukasz Żurek');
  assert.equal(Slack.peerTileName({ description: 'Piotr Nowak, audio is off' }), 'Piotr Nowak');
  assert.equal(Slack.peerTileName({ description: 'audio is on', text: 'Gustavo Lima' }), 'Gustavo Lima');
  assert.equal(Slack.peerTileName({ ariaLabel: 'Reactions', text: '' }), '');
});

test('Slack huddleNamesFromLabel reads attendee lists from summary labels', () => {
  assert.deepEqual(Slack.huddleNamesFromLabel('Huddle with Jane Doe and Bob Smith'), ['Jane Doe', 'Bob Smith']);
  assert.deepEqual(Slack.huddleNamesFromLabel('Huddle with Jane Doe, Bob Smith, and 2 others'), ['Jane Doe', 'Bob Smith']);
  assert.deepEqual(Slack.huddleNamesFromLabel('3 people in the huddle: Jane Doe, Łukasz Bąk and you'), ['Jane Doe', 'Łukasz Bąk']);
  assert.deepEqual(Slack.huddleNamesFromLabel('Jane Doe and Bob Smith are in this huddle'), ['Jane Doe', 'Bob Smith']);
});

test('Slack huddleNamesFromLabel ignores channels, controls and invitations', () => {
  assert.deepEqual(Slack.huddleNamesFromLabel('Huddle in #general'), []);
  assert.deepEqual(Slack.huddleNamesFromLabel('Leave huddle'), []);
  assert.deepEqual(Slack.huddleNamesFromLabel('Start a huddle with Jane Doe'), []);
  assert.deepEqual(Slack.huddleNamesFromLabel('Join huddle with Jane Doe'), []);
  assert.deepEqual(Slack.huddleNamesFromLabel(null), []);
});

test('Slack participantFromAttrs takes names from avatar/tile attributes', () => {
  assert.equal(Slack.participantFromAttrs({ ariaLabel: 'Jane Doe, muted' }).name, 'Jane Doe');
  assert.equal(Slack.participantFromAttrs({ alt: 'Profile picture of Bob Smith' }).name, 'Bob Smith');
  assert.equal(Slack.participantFromAttrs({ title: 'Ann Lee (you)' }).name, 'Ann Lee');
  assert.equal(Slack.participantFromAttrs({ dataQa: 'huddle_participant_Jane Doe' }).name, 'Jane Doe');
  const speaking = Slack.participantFromAttrs({ ariaLabel: 'Bob Smith is speaking' });
  assert.equal(speaking.name, 'Bob Smith');
  assert.equal(speaking.label, 'Bob Smith is speaking');
});

test('Slack participantFromAttrs rejects controls, ids and empty avatars', () => {
  assert.equal(Slack.participantFromAttrs({ ariaLabel: 'Leave huddle' }), null);
  assert.equal(Slack.participantFromAttrs({ ariaLabel: 'Mute', alt: '' }), null);
  assert.equal(Slack.participantFromAttrs({ dataQa: 'huddle_participant_U01ABCDEF12-3f4e5d6c7b8a' , alt: 'Avatar' }), null);
  assert.equal(Slack.participantFromAttrs({ title: '+3' }), null);
  assert.equal(Slack.participantFromAttrs({}), null);
});

// ---------------------------------------------------------------- Zoom web client

test('Zoom parseZoomLabel strips role groups and marks self', () => {
  assert.deepEqual(Zoom.parseZoomLabel('Jane Doe (Host, me), Computer audio unmuted, Video on'), { name: 'Jane Doe', self: true, speaking: false });
  assert.deepEqual(Zoom.parseZoomLabel('Bob Smith (Co-host), Computer audio muted'), { name: 'Bob Smith', self: false, speaking: false });
  assert.deepEqual(Zoom.parseZoomLabel('Ann Lee (Guest)'), { name: 'Ann Lee', self: false, speaking: false });
  assert.deepEqual(Zoom.parseZoomLabel('Łukasz Bąk (me)'), { name: 'Łukasz Bąk', self: true, speaking: false });
  assert.equal(Zoom.parseZoomLabel('Ann (Marketing)').name, 'Ann (Marketing)');
});

test('Zoom parseZoomLabel reads tile footers and speaking labels', () => {
  assert.deepEqual(Zoom.parseZoomLabel('Jane Doe\nmic_off'), { name: 'Jane Doe', self: false, speaking: false });
  assert.deepEqual(Zoom.parseZoomLabel('Video of Bob Smith, talking'), { name: 'Bob Smith', self: false, speaking: true });
  assert.deepEqual(Zoom.parseZoomLabel('Jane Doe is talking'), { name: 'Jane Doe', self: false, speaking: true });
  assert.equal(Zoom.parseZoomLabel("Bob Smith's video").name, 'Bob Smith');
});

test('Zoom parseZoomLabel rejects chrome', () => {
  for (const s of ['', null, 'Participants', 'Mute', 'More', '+3', 'Leave']) {
    assert.equal(Zoom.parseZoomLabel(s), null, JSON.stringify(s));
  }
});

test('Slack userIdFromAvatarSrc reads the member id from avatar image URLs', () => {
  assert.equal(Slack.userIdFromAvatarSrc('https://ca.slack-edge.com/T03ABCDEF-U05XYZ1234-a1b2c3d4e5f6-72'), 'U05XYZ1234');
  assert.equal(Slack.userIdFromAvatarSrc('https://ca.slack-edge.com/E01ENTERPR-W012ABCDEF-0123456789ab-192'), 'W012ABCDEF');
  assert.equal(Slack.userIdFromAvatarSrc('https://a.slack-edge.com/80588/img/avatars/ava_0001-72.png'), null);
  assert.equal(Slack.userIdFromAvatarSrc('https://example.com/T03ABCDEF-U05XYZ1234-a1b2-72'), null);
  assert.equal(Slack.userIdFromAvatarSrc(null), null);
});

test('Slack parseAnnouncement reads joins, leaves and speakers from the live region', () => {
  assert.deepEqual(Slack.parseAnnouncement('Jane Doe joined the huddle'), { kind: 'joined', name: 'Jane Doe' });
  assert.deepEqual(Slack.parseAnnouncement('Jane Doe has left the huddle.'), { kind: 'left', name: 'Jane Doe' });
  assert.deepEqual(Slack.parseAnnouncement('Marek Wróbel dołączył do huddle'), { kind: 'joined', name: 'Marek Wróbel' });
  assert.deepEqual(Slack.parseAnnouncement('Zofia Jabłońska opuściła huddle'), { kind: 'left', name: 'Zofia Jabłońska' });
  assert.deepEqual(Slack.parseAnnouncement('Bob Smith is speaking'), { kind: 'speaking', name: 'Bob Smith' });
  assert.equal(Slack.parseAnnouncement('You joined the huddle'), null);
  assert.equal(Slack.parseAnnouncement('Message sent'), null);
  assert.equal(Slack.parseAnnouncement(''), null);
});

test('Slack isHuddleWindowPage spots the pop-out huddle window', () => {
  assert.equal(Slack.isHuddleWindowPage('about:blank', false), true);
  assert.equal(Slack.isHuddleWindowPage('https://app.slack.com/huddle/T1/C1', false), true);
  assert.equal(Slack.isHuddleWindowPage('https://app.slack.com/huddle/T1/C1', true), false);
  assert.equal(Slack.isHuddleWindowPage('https://app.slack.com/client/T1/C1', false), false);
  assert.equal(Slack.isHuddleWindowPage('not a url', false), false);
});

test('Slack participantFromAttrs reads "View X’s Profile" and skips sidebar labels', () => {
  assert.equal(Slack.participantFromAttrs({ ariaLabel: 'View Adam Nowicki’s Profile' }).name, 'Adam Nowicki');
  assert.equal(Slack.participantFromAttrs({ ariaLabel: 'Channels and direct messages' }), null);
  assert.equal(Slack.participantFromAttrs({ ariaLabel: 'Channel project-x (private)' }), null);
});

test('Meet captionSpeakers counts a new block as speech once primed', () => {
  const prev = new Map();
  Meet.captionSpeakers([{ key: 1, lines: ['Jane Doe', 'Hi'] }], prev, [], null, false);
  assert.deepEqual(Meet.captionSpeakers([{ key: 1, lines: ['Jane Doe', 'Hi'] }, { key: 2, lines: ['Bob', 'Yes'] }], prev, [], null, true), ['Bob']);
});

test('Meet captionsToggleState finds the captions button in English and Polish', () => {
  const b = (label, pressed) => ({ label, pressed });
  assert.deepEqual(Meet.captionsToggleState([b('Leave call'), b('Turn on captions (c)')]), { state: 'off', index: 1 });
  assert.deepEqual(Meet.captionsToggleState([b('Włącz napisy (c)')]), { state: 'off', index: 0 });
  assert.deepEqual(Meet.captionsToggleState([b('Turn off captions')]), { state: 'on', index: 0 });
  assert.deepEqual(Meet.captionsToggleState([b('Wyłącz napisy')]), { state: 'on', index: 0 });
  assert.deepEqual(Meet.captionsToggleState([b('Turn on captions', 'true')]), { state: 'on', index: 0 });
  assert.deepEqual(Meet.captionsToggleState([b('Chat with everyone')]), { state: 'unknown', index: -1 });
  assert.deepEqual(Meet.captionsToggleState(null), { state: 'unknown', index: -1 });
});

test('Meet recentCaptionSpeakers keeps recent names and forgets old ones', () => {
  const stamps = new Map([['Ann', 10000], ['Bob', 8500], ['Cid', -60000]]);
  assert.deepEqual(Meet.recentCaptionSpeakers(stamps, 11000, 2000), ['Ann']);
  assert.equal(stamps.has('Cid'), false, 'older than a minute is dropped');
  assert.equal(stamps.has('Bob'), true);
});

test('Slack sidebar section labels are junk, not names', () => {
  const OK = require('../content/common.js');
  for (const s of ['All', 'all', 'Channels and direct messages', 'Channel general', 'channel project-x']) assert.equal(OK.isJunkName(s), true, s);
  for (const s of ['Allan Smith', 'Channing Tatum']) assert.equal(OK.isJunkName(s), false, s);
});

test('Slack avatarLabel takes alt, or a near host wrapping exactly one avatar', () => {
  assert.equal(Slack.avatarLabel('Jane Doe', [{ label: 'All', control: false, avatars: 9 }]), 'Jane Doe');
  assert.equal(Slack.avatarLabel('', [{ label: 'Jane Doe', control: false, avatars: 1 }]), 'Jane Doe');
  assert.equal(Slack.avatarLabel('', [{ label: '' }, { label: 'Bob Smith', control: false, avatars: 1 }]), 'Bob Smith');
  assert.equal(Slack.avatarLabel('', [{ label: 'Channels and direct messages', control: false, avatars: 12 }]), '');
  assert.equal(Slack.avatarLabel('', [{ label: 'Jane Doe', control: true, avatars: 1 }]), '');
  assert.equal(Slack.avatarLabel('', [{ label: '' }, { label: '' }, { label: 'Far Away', control: false, avatars: 1 }]), '');
});

test('Slack rememberUserIn drops junk and never lets a weak name overwrite a stored one', () => {
  const users = new Map();
  assert.equal(Slack.rememberUserIn(users, 'U01ABCDEF12', 'All', true), false);
  assert.equal(Slack.rememberUserIn(users, 'U01ABCDEF12', 'Channels and direct messages', false), false);
  assert.equal(users.size, 0);
  assert.equal(Slack.rememberUserIn(users, 'U01ABCDEF12', 'Jane Doe', false), true);
  assert.equal(Slack.rememberUserIn(users, 'U01ABCDEF12', 'Someone Else', true), false);
  assert.equal(Slack.rememberUserIn(users, 'U01ABCDEF12', 'All', false), false);
  assert.equal(users.get('U01ABCDEF12'), 'Jane Doe');
  assert.equal(Slack.rememberUserIn(users, 'U01ABCDEF12', 'Jane Q. Doe', false), true);
  assert.equal(users.get('U01ABCDEF12'), 'Jane Q. Doe');
  assert.equal(Slack.rememberUserIn(users, 'U02ABCDEF12', 'Bob Smith', true), true);
});

test('Slack tileStructure keeps class, data-qa, aria-label and style to depth 3 with names pseudonymized', () => {
  const el = (tag, attrs, children = []) => ({
    tagName: tag.toUpperCase(),
    getAttribute: (n) => (n in attrs ? attrs[n] : null),
    children,
    textContent: 'Anna Nowak'
  });
  const deep = el('i', { class: 'level-4' });
  const tile = el('div', { class: 'p-huddle_peer_tile', 'data-qa': 'huddle_peer_tile_userId_U1', 'aria-label': 'Anna Nowak, muted' }, [
    el('div', { class: 'p-huddle_peer_tile__overlay', style: 'opacity: 1' }, [
      el('span', { 'aria-label': 'anna nowak and Jane Doe', title: 'Anna Nowak' }, [el('b', {}, [deep])])
    ])
  ]);
  const [out] = Slack.tileStructure([tile], ['Anna Nowak', 'Jane Doe']);
  const json = JSON.stringify(out);
  assert.equal(out.qa, 'huddle_peer_tile_userId_U1');
  assert.equal(out.aria, 'name-1, muted');
  assert.equal(out.c[0].style, 'opacity: 1');
  assert.equal(out.c[0].c[0].aria, 'name-1 and name-2');
  assert.equal(out.c[0].c[0].c[0].c, undefined, 'stops at depth 3');
  assert.ok(!/Anna|Nowak|Jane|Doe/i.test(json));
});

test('Slack tileStructure aria-label keeps only allowlisted state words and name-N, other words become w', () => {
  const el = (label) => ({ tagName: 'DIV', getAttribute: (n) => (n === 'aria-label' ? label : null), children: [] });
  const aria = (label, names = []) => Slack.tileStructure([el(label)], names)[0].aria;
  assert.equal(aria('Zofia Kowalska is speaking'), 'w w is speaking');
  assert.equal(aria('Anna Nowak, Zofia Kowalska: Muted!', ['Anna Nowak']), 'name-1, w w: Muted!');
  assert.equal(aria('Jane Doe is sharing screen', ['Jane Doe']), 'name-1 is sharing screen');
  assert.equal(aria('Raised hand, Camera OFF'), 'Raised hand, Camera OFF');
});

test('Slack tileStructure strips URLs from style, pseudonymizes every attribute and caps node count', () => {
  const el = (attrs, children = []) => ({ tagName: 'DIV', getAttribute: (n) => (n in attrs ? attrs[n] : null), children });
  const [out] = Slack.tileStructure([el({ class: 'tile', 'data-qa': 'tile Jane Doe', style: 'background-image: url("https://ca.slack-edge.com/T0-U01ABCDEF12-abc-72")' })], ['Jane Doe']);
  assert.ok(!/slack-edge|U01ABCDEF12|Jane/i.test(JSON.stringify(out)));
  const wide = (d) => el({}, d ? Array.from({ length: 12 }, () => wide(d - 1)) : []);
  const count = (n) => 1 + (n.c || []).reduce((a, k) => a + count(k), 0);
  const all = Slack.tileStructure(Array.from({ length: 12 }, () => wide(3)), []);
  assert.ok(all.reduce((a, n) => a + count(n), 0) <= 200);
});
