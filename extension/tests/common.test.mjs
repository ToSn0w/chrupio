import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const OK = require('../content/common.js');

test('exports are attached to globalThis and module.exports', () => {
  assert.equal(typeof OK.cleanName, 'function');
  assert.equal(globalThis.Chrupio.cleanName, OK.cleanName);
});

test('cleanName trims, collapses whitespace and keeps first line', () => {
  assert.equal(OK.cleanName('  Jane   Doe  '), 'Jane Doe');
  assert.equal(OK.cleanName('Jane Doe\nmic_off\nmore_vert'), 'Jane Doe');
  assert.equal(OK.cleanName('​Jane Doe﻿'), 'Jane Doe');
  assert.equal(OK.cleanName(null), '');
  assert.equal(OK.cleanName(undefined), '');
  assert.equal(OK.cleanName('"Jane"'), 'Jane');
});

test('cleanName strips role markers like (You), (Guest), [External]', () => {
  assert.equal(OK.cleanName('Jane Doe (You)'), 'Jane Doe');
  assert.equal(OK.cleanName('Jane Doe (you)'), 'Jane Doe');
  assert.equal(OK.cleanName('Jan Kowalski (Gość) (Ty)'), 'Jan Kowalski');
  assert.equal(OK.cleanName('Bob [External]'), 'Bob');
  assert.equal(OK.cleanName('Ann (Organizer)'), 'Ann');
  assert.equal(OK.cleanName('Ann (Marketing)'), 'Ann (Marketing)');
});

test('isJunkName rejects UI chrome and status strings', () => {
  const junk = [
    '', '   ', 'You', '(You)', 'you', 'Presentation', 'More options', 'Muted',
    'Mic off', 'camera off', 'mic_off', 'more_vert', 'frame_person',
    'Jane is presenting', 'Jane’s presentation', '+3', '12', '4 others',
    'Join now', 'Leave call', 'In this meeting (3)', 'Others invited (2)',
    'Your microphone is off', 'https://meet.google.com/abc', '…', 'x'.repeat(81)
  ];
  for (const s of junk) assert.equal(OK.isJunkName(s), true, `expected junk: ${JSON.stringify(s)}`);
});

test('isJunkName accepts real names, including unicode', () => {
  const ok = ['Jane Doe', 'Łukasz Bąk', 'José Álvarez', '李雷', "O'Brien", 'Anne-Marie', 'J', 'Ann (Marketing)'];
  for (const s of ok) assert.equal(OK.isJunkName(s), false, `expected name: ${JSON.stringify(s)}`);
});

test('isJunkName rejects Meet UI sentences and panel names', () => {
  const junk = [
    'Others might still see your full video.',
    'Stickers',
    'Backgrounds and effects',
    'Take notes with Gemini',
    'You can turn this off in settings',
    'Something went wrong!'
  ];
  for (const s of junk) assert.equal(OK.isJunkName(s), true, `expected junk: ${JSON.stringify(s)}`);
});

test('isJunkName keeps names with initials, suffixes and up to 4 words', () => {
  const ok = ['Anna K.', 'John Smith Jr.', 'J. R. Tolkien', 'Maria de la Cruz', 'Dr. Ewa Nowak'];
  for (const s of ok) assert.equal(OK.isJunkName(s), false, `expected name: ${JSON.stringify(s)}`);
  assert.equal(OK.isJunkName('Ana Maria de la Cruz'), true);
});

test('dedupeNames cleans, filters junk and dedupes case/diacritic-insensitively', () => {
  const out = OK.dedupeNames([
    'Jane Doe', ' jane  doe ', 'Jane Doe (You)', 'You', 'mic_off', 'Lukasz', 'Łukasz',
    'Bob\nMuted', '', null, 'Presentation', 'Bob'
  ]);
  assert.deepEqual(out, ['Jane Doe', 'Lukasz', 'Bob']);
});

test('dedupeNames preserves first-seen order and handles empty input', () => {
  assert.deepEqual(OK.dedupeNames(['C', 'A', 'B', 'a']), ['C', 'A', 'B']);
  assert.deepEqual(OK.dedupeNames([]), []);
  assert.deepEqual(OK.dedupeNames(undefined), []);
});

test('hasSelfMarker detects the local-user suffix only', () => {
  assert.equal(OK.hasSelfMarker('Jane Doe (You)'), true);
  assert.equal(OK.hasSelfMarker('Jan (Ty)'), true);
  assert.equal(OK.hasSelfMarker('Jane Doe (You)\nmic_off'), true);
  assert.equal(OK.hasSelfMarker('Jane Doe'), false);
  assert.equal(OK.hasSelfMarker('Young (Guest)'), false);
  assert.equal(OK.hasSelfMarker(null), false);
});

test('nameFromAriaLabel extracts the name from Teams/Meet style labels', () => {
  assert.equal(OK.nameFromAriaLabel('Jane Doe, Muted, Video off'), 'Jane Doe');
  assert.equal(OK.nameFromAriaLabel('Jane Doe (You), camera off'), 'Jane Doe');
  assert.equal(OK.nameFromAriaLabel('Jane Doe is speaking'), 'Jane Doe');
  assert.equal(OK.nameFromAriaLabel('Profile picture of Jane Doe'), 'Jane Doe');
  assert.equal(OK.nameFromAriaLabel('Jane Doe · Organizer'), 'Jane Doe');
  assert.equal(OK.nameFromAriaLabel(''), '');
  assert.equal(OK.nameFromAriaLabel(null), '');
});

test('labelSaysSpeaking', () => {
  assert.equal(OK.labelSaysSpeaking('Jane Doe is speaking'), true);
  assert.equal(OK.labelSaysSpeaking('Jane Doe, Speaking, Video on'), true);
  assert.equal(OK.labelSaysSpeaking('Jan mówi'), true);
  assert.equal(OK.labelSaysSpeaking('Jane Doe is not speaking'), false);
  assert.equal(OK.labelSaysSpeaking('Jane Doe, Muted'), false);
  assert.equal(OK.labelSaysSpeaking(null), false);
});

test('cleanTitle strips app suffixes and unread counters', () => {
  assert.equal(OK.cleanTitle('Weekly sync | Microsoft Teams', ['Microsoft Teams']), 'Weekly sync');
  assert.equal(OK.cleanTitle('(3) Standup - Microsoft Teams', ['Microsoft Teams']), 'Standup');
  assert.equal(OK.cleanTitle('Meet - abc-defg-hij', [/^meet\s*-\s*/i]), 'abc-defg-hij');
  assert.equal(OK.cleanTitle('Microsoft Teams', ['Microsoft Teams']), null);
  assert.equal(OK.cleanTitle(null, []), null);
});

test('sameState ignores ts and compares lists element-wise', () => {
  const a = { inMeeting: true, title: 't', selfName: 's', url: 'u', participants: ['A', 'B'], activeSpeakers: [] };
  assert.equal(OK.sameState(a, { ...a, ts: 5, participants: ['A', 'B'] }), true);
  assert.equal(OK.sameState(a, { ...a, participants: ['B', 'A'] }), false);
  assert.equal(OK.sameState(a, { ...a, inMeeting: false }), false);
  assert.equal(OK.sameState(a, null), false);
});

test('cleanName strips localized self/role/presentation markers', () => {
  assert.equal(OK.cleanName('Jana Nowak (Du)'), 'Jana Nowak');
  assert.equal(OK.cleanName('Jeanne (Vous) (Invité)'), 'Jeanne');
  assert.equal(OK.cleanName('Jane Doe (Presentation)'), 'Jane Doe');
  assert.equal(OK.cleanName('Jane Doe (Präsentation)'), 'Jane Doe');
  assert.equal(OK.cleanName('Jane Doe (Companion)'), 'Jane Doe');
});

test('isJunkName rejects device names, sharing labels and localized "you"', () => {
  const junk = [
    'MacBook Pro Microphone', 'Default - MacBook Pro Speakers', 'AirPods Pro', 'External Headset',
    'Jane Doe is sharing', 'Jane’s screen', 'Content shared by Jane', 'Präsentation von Jane',
    'Du', 'Sie', 'Você', 'あなた', 'Video is off', 'Raised hand'
  ];
  for (const s of junk) assert.equal(OK.isJunkName(s), true, `expected junk: ${JSON.stringify(s)}`);
  assert.equal(OK.isJunkName('Sienna Miller'), false);
});

test('dedupeNames collapses presentation tiles and device rows into people', () => {
  assert.deepEqual(
    OK.dedupeNames(['Jane Doe', 'Jane Doe (Presentation)', 'Jane Doe is presenting', 'MacBook Pro Microphone', 'Bob (You)', 'You']),
    ['Jane Doe', 'Bob']
  );
});

test('hasSelfMarker handles localized and stacked markers', () => {
  assert.equal(OK.hasSelfMarker('Jana (Du)'), true);
  assert.equal(OK.hasSelfMarker('Jeanne (Vous)'), true);
  assert.equal(OK.hasSelfMarker('Jane (You) (Guest)'), true);
  assert.equal(OK.hasSelfMarker('Jane (Guest)'), false);
});

test('nameFromAriaLabel strips sharing status', () => {
  assert.equal(OK.nameFromAriaLabel('Jane Doe is sharing'), 'Jane Doe');
  assert.equal(OK.nameFromAriaLabel('Jane Doe sharing, Muted'), 'Jane Doe');
});

test('nameFromProfileLabel only accepts labels that name a person', () => {
  assert.equal(OK.nameFromProfileLabel('Profile picture of Jane Doe.'), 'Jane Doe');
  assert.equal(OK.nameFromProfileLabel('Account manager for Jane Doe'), 'Jane Doe');
  assert.equal(OK.nameFromProfileLabel('Profile picture of Jane Doe, status Available'), 'Jane Doe');
  assert.equal(OK.nameFromProfileLabel('Zdjęcie profilowe użytkownika Jan Kowalski'), 'Jan Kowalski');
  assert.equal(OK.nameFromProfileLabel('Your profile picture with status displayed as Available.'), '');
  assert.equal(OK.nameFromProfileLabel('Profile, account and settings'), '');
  assert.equal(OK.nameFromProfileLabel('Jane Doe'), '');
  assert.equal(OK.nameFromProfileLabel(null), '');
});

test('nameFromPrefixedAttr extracts names and rejects ids', () => {
  assert.equal(OK.nameFromPrefixedAttr('participantsInCall-Jane Doe', 'participantsInCall-'), 'Jane Doe');
  assert.equal(OK.nameFromPrefixedAttr('participantsInCall-Łukasz Bąk (Guest)', 'participantsInCall-'), 'Łukasz Bąk');
  assert.equal(OK.nameFromPrefixedAttr('participantsInCall-8:orgid:1234', 'participantsInCall-'), '');
  assert.equal(OK.nameFromPrefixedAttr('participantsInCall-3f2504e0-4f89-11d3-9a0c-0305e82c3301', 'participantsInCall-'), '');
  assert.equal(OK.nameFromPrefixedAttr('participantsInCall-jane@x.com', 'participantsInCall-'), '');
  assert.equal(OK.nameFromPrefixedAttr('roster-Jane', 'participantsInCall-'), '');
  assert.equal(OK.nameFromPrefixedAttr(null, 'participantsInCall-'), '');
});

test('stripLabelPrefix removes a short leading "Label: "', () => {
  assert.equal(OK.stripLabelPrefix('User: Jane Doe'), 'Jane Doe');
  assert.equal(OK.stripLabelPrefix('Użytkownik: Jan'), 'Jan');
  assert.equal(OK.stripLabelPrefix('Jane Doe'), 'Jane Doe');
});

// ---------------------------------------------------------------- structure snapshot

function fakeEl(tag, attrs = {}, children = [], text = '') {
  return {
    tagName: tag.toUpperCase(),
    getAttribute: (n) => (n in attrs ? attrs[n] : null),
    attributes: Object.entries(attrs).map(([name, value]) => ({ name, value })),
    children,
    textContent: children.length ? children.map((c) => c.textContent).join(' ') : text,
    matches: (sel) => sel.split(',').some((s) => s.trim() === '[data-qa*="message"]' && (attrs['data-qa'] || '').includes('message'))
  };
}

test('domSnapshot keeps attributes and short leaf text, never reads skipped subtrees', () => {
  const Common = require('../content/common.js');
  const tree = fakeEl('div', { 'data-qa': 'huddle_window', class: 'p-huddle' }, [
    fakeEl('div', { 'data-qa': 'tile', 'data-user-id': 'U123', 'aria-label': 'Jane Doe' }, [fakeEl('span', {}, [], 'Jane Doe')]),
    fakeEl('div', { 'data-qa': 'message_pane' }, [fakeEl('span', {}, [], 'secret chat text')]),
    fakeEl('p', {}, [], 'x'.repeat(80))
  ]);
  const snap = Common.domSnapshot([tree], { skip: '[data-qa*="message"]' });
  const json = JSON.stringify(snap);
  assert.equal(snap.roots[0].qa, 'huddle_window');
  assert.equal(snap.roots[0].c[0].data['data-user-id'], 'U123');
  assert.equal(snap.roots[0].c[0].c[0].text, 'Jane Doe');
  assert.equal(snap.roots[0].c[1].skipped, true);
  assert.ok(!json.includes('secret chat text'));
  assert.equal(snap.roots[0].c[2].text, undefined);
});

test('domSnapshot stops at the node limit', () => {
  const Common = require('../content/common.js');
  const kids = Array.from({ length: 50 }, () => fakeEl('i'));
  const snap = Common.domSnapshot([fakeEl('div', {}, kids)], { maxNodes: 10 });
  assert.equal(snap.nodes, 10);
  assert.equal(snap.truncated, true);
});

test('cleanName drops a bare trailing Unverified (Teams external accounts)', () => {
  assert.equal(OK.cleanName('Marek Unverified'), 'Marek');
  assert.equal(OK.cleanName('Jane Doe (Unverified)'), 'Jane Doe');
  assert.equal(OK.cleanName('Unverified'), 'Unverified');
});

test('domSnapshot adds fields from opts.extra without overwriting', () => {
  const el = (tagName, attrs, children) => ({
    tagName,
    getAttribute: (n) => (n in attrs ? attrs[n] : null),
    attributes: Object.entries(attrs).map(([name, value]) => ({ name, value })),
    children: children || [],
    textContent: ''
  });
  const img = el('IMG', { src: 'https://ca.slack-edge.com/T1ABCDEF-U05XYZ1234-abc-72', role: 'img' });
  const snap = OK.domSnapshot([el('SPAN', { class: 'c-avatar' }, [img])], {
    extra: (n) => (n.tagName === 'IMG' ? { uid: 'U05XYZ1234', role: 'ignored' } : null)
  });
  assert.equal(snap.roots[0].c[0].uid, 'U05XYZ1234');
  assert.equal(snap.roots[0].c[0].role, 'img');
  assert.equal(snap.roots[0].uid, undefined);
});

test('nameFromAriaLabel strips Slack "View X’s Profile" and rejects sidebar chrome', () => {
  assert.equal(OK.nameFromAriaLabel('View Adam Nowicki’s Profile'), 'Adam Nowicki');
  assert.equal(OK.nameFromAriaLabel("View Adam Nowicki's Profile"), 'Adam Nowicki');
  assert.equal(OK.nameFromAriaLabel("View James' profile"), 'James');
  assert.equal(OK.nameFromAriaLabel('Zobacz profil użytkownika Łukasz Żurek'), 'Łukasz Żurek');
  assert.equal(OK.nameFromAriaLabel('Channels and direct messages'), '');
  assert.equal(OK.nameFromAriaLabel('Channel project-acme (private)'), '');
  assert.equal(OK.nameFromAriaLabel('Jane Doe, Muted'), 'Jane Doe');
  assert.equal(OK.isJunkName("View Adam Nowicki's Profile"), true);
  assert.equal(OK.isJunkName('Channels and direct messages'), true);
  assert.equal(OK.isJunkName('Channel general (private)'), true);
  assert.deepEqual(OK.dedupeNames(['View Ann’s Profile', 'Channels and direct messages', 'Ann']), ['Ann']);
});

test('isJunkName rejects Slack slugs, emoji codes, "All" and notetaker bots', () => {
  for (const s of ['acme-pl', 'raised_hand::skin-tone-2', 'All', "Diego's Grain Notetaker", 'Fireflies.ai Notetaker Łukasz']) {
    assert.equal(OK.isJunkName(s), true, `expected junk: ${JSON.stringify(s)}`);
  }
  for (const s of ['Harry Potter', 'Anna Hart', 'Piotr Sadowski']) assert.equal(OK.isJunkName(s), false, s);
});

test('cleanName keeps the name from "Conversation with", nameKey splits camelCase', () => {
  assert.equal(OK.cleanName('Conversation with Piotr Sadowski'), 'Piotr Sadowski');
  assert.equal(OK.nameKey('PiotrMazur'), OK.nameKey('Piotr Mazur'));
  assert.equal(OK.nameKey('Marek Wrobel'), OK.nameKey('Marek Wróbel'));
});
