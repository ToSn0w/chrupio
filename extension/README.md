# Chrupio Companion (Chrome extension)

Tells the Chrupio macOS app when you are in a browser meeting and who is in it.
Supports Google Meet, Microsoft Teams (web), Slack huddles and the Zoom web client in Chrome.
Plain JavaScript, Manifest V3, no build step.

## Install

1. Open `chrome://extensions` in Chrome.
2. Turn on **Developer mode** (top right).
3. Click **Load unpacked**, press Cmd+Shift+G and select `~/Library/Application Support/Chrupio/ChromeExtension`
   (the app writes it on launch and refreshes it after updates). For development, select this `extension/` folder instead.
4. Pin the extension and click its icon. The popup shows "Connected to Chrupio"
   when the app is running, otherwise "Chrupio app not running".
5. Reload any Meet / Teams / Slack tabs that were already open, so the content
   scripts are injected.

After editing files, click the reload icon on the extension card, then reload the meeting tabs.

## What it sends

The service worker POSTs JSON to `http://127.0.0.1:47811/v1/event`:

- Every ~1 s per tab that is in a call, and immediately on change (tabs not in a call send nothing):
  `{"type":"meeting","platform":"meet|teams|slack|zoom","tabId":1,"url":"…","title":"…"|null,"inMeeting":true,"participants":["…"],"activeSpeakers":["…"],"selfName":"…"|null,"ts":1700000000000}`
- When a tab that was in a meeting leaves it, navigates away or closes:
  `{"type":"ended","platform":"meet","tabId":1,"ts":1700000000000}`

Every event also carries `"extensionVersion":"0.4.6"`. Separately, when the worker starts and on each
30 s sweep alarm, it POSTs `{"extensionVersion":"0.4.6"}` to `/v1/hello` so the app shows the extension
as connected while no call is open. A hello never starts a recording.

The popup calls `GET http://127.0.0.1:47811/health` and expects `{"ok":true}`.
If the app is not reachable, the worker logs one `console.debug` line and backs off
(3 s doubling to 15 s) before the next heartbeat attempt, so Chrome's own
`ERR_CONNECTION_REFUSED` lines stay rare. `ended` and hello pings respect it too.

At most every 30 s in a call, a `meeting` event also carries a `probe` object (< 4 KB) describing the
participant tiles found and their attribute-mutation counts, for selector tuning; its shape is documented
at the top of `content/common.js`.

Active speakers come from explicit markers (speaking attributes, aria-labels, classes) first; when none
match, a generic detector counts attribute mutations inside each participant tile over 1.5 s and picks
the tile whose voice-level animation is clearly busier than the rest.

Heartbeat timing: the content script checks every 250 ms, scrapes at most once a second (or at once when
the generic detector sees the speaker set change), and messages the worker every 1 s
while in a call (every 30 s otherwise). Each message wakes the MV3 worker and resets its
idle timer; `chrome.alarms` (30 s minimum) drives the dead-tab sweep and the hello ping.

## Layout

| File | Role |
| --- | --- |
| `manifest.json` | MV3 manifest, host permissions for the app and the meeting origins |
| `lib/policy.js` | Pure worker logic (platform/meeting key, post decision, backoff), shared with tests |
| `background.js` | Service worker: per-tab state (in `chrome.storage.session`), heartbeat and `ended` logic, tab close/navigation handling, 30 s alarm sweep for dead tabs |
| `content/common.js` | Name cleaning, junk filter, dedup, aria-label parsing, the mutation-rate speaking detector, and the reporter loop |
| `content/meet.js`, `content/teams.js`, `content/slack.js`, `content/zoom.js` | Per-platform detection of in-call state, participants, active speakers, self name, title |
| `popup.html`, `popup.js` | Connection status and the current meeting |
| `tests/*.test.mjs` | Node tests for `content/common.js`, `lib/policy.js` and the Slack/Zoom label parsers |

## Tests

```sh
cd extension
node --test tests/
```

## Notes

- Participant names come from what the page renders. Meet and Teams only render
  tiles for people on screen; open the People / Participants panel to get the full list.
- Active-speaker detection is best effort and depends on markup the platforms change without notice.
- The extension requests no `tabs` permission. A tracked tab whose URL becomes unreadable is treated as having left the meeting site.
