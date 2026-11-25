# Contributing to Chrupio

Bug reports and pull requests are welcome. For anything bigger than a bug fix or a small improvement, open an issue first and describe the change, so we can agree on the approach before you write the code.

## Requirements

- macOS 15 or later, Apple Silicon
- Xcode command-line tools (Swift 6.2) and `cmake` (`brew install cmake`); the app build compiles whisper.cpp from source, about 2 minutes the first time
- Node.js 20 or later, for the Chrome extension tests
- Claude Code, installed and logged in, if you want summaries to work while you test

## Build and test

```sh
swift build
swift test
node --test extension/tests
```

`scripts/install.sh` builds the app, downloads the whisper `small` model and installs it to `~/Applications/Chrupio.app`. `scripts/build-app.sh` builds `dist/Chrupio.app` without installing it. It signs ad hoc by default, so macOS asks for microphone and screen-recording permissions after every rebuild; set `CHRUPIO_DEV_IDENTITY=1` to sign with a trusted identity (created once in your login keychain) that keeps them.

To load the extension while developing, open `chrome://extensions`, turn on Developer mode, click Load unpacked and select the `extension/` folder. Keep the `key` in `extension/manifest.json`: the app accepts connections only from the extension ID that key produces.

## Code

- Logic that does not need the UI goes in `ChrupioCore` and comes with tests. Tests that touch files use temporary directories, never your real meetings in `~/Library/Application Support/Chrupio`.
- Keep pull requests to one change. Run all three test commands above before opening one.

## Design rules

The app uses one visual system, defined in `Sources/Chrupio/Theme.swift`. Views use its tokens and styles (`brutalistPanel`, `BrutalistButtonStyle`, `tagChip`, `BrutalistToggleStyle`, `SquareIconButtonStyle`) instead of their own colours, borders or fonts.

- Colours: black (`Theme.ink`), white (`Theme.surface`) and one orange (`Theme.accent`). Greys only for secondary text, pressed rows and unlit meter bars.
- Orange is a fill behind black text, or a mark on black. Never orange text on white.
- Red (`Theme.Color.error`) only for errors and the recording markers, as text or icon colour, never as a fill.
- Headings and labels are bold upper case. Body text, meeting titles, names and file paths stay in normal case.
- Font: IBM Plex Mono, bundled with the app.
- The extension popup uses the same tokens in plain CSS.

## License

Chrupio is GPL-3.0. By opening a pull request you agree that your contribution is licensed under GPL-3.0, the same licence as the project. There is no CLA or sign-off to add.
