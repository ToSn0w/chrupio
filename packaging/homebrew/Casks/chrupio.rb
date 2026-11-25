cask "chrupio" do
  version "1.0.0"
  sha256 "d372a83d424e5a358b1828edb932ec26b9ed128e228a86eca63f415fd5d7cef9"

  url "https://github.com/ToSn0w/chrupio/releases/download/v#{version}/Chrupio-#{version}.dmg"
  name "Chrupio"
  desc "Meeting notes summarized by your own Claude Code"
  homepage "https://github.com/ToSn0w/chrupio"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: ">= :sequoia"

  app "Chrupio.app"

  zap trash: [
    "~/Library/Application Support/Chrupio",
    "~/Library/Preferences/com.chrupio.app.plist",
    "~/Desktop/Chrupio Chrome Extension",
  ]

  caveats <<~EOS
    Load the Chrome extension unpacked (there is no Chrome Web Store listing).
    Open Chrupio once, then in chrome://extensions turn on Developer mode,
    click Load unpacked, press Cmd+Shift+G and select:
      ~/Library/Application Support/Chrupio/ChromeExtension
    Chrome then shows a Developer mode notice; that is expected.
    Summaries need Claude Code, logged in:
      curl -fsSL https://claude.ai/install.sh | bash
      claude /login
    Meeting notes are kept in ~/Chrupio Notes/ and are not removed by zap.
    Before uninstalling, open Settings > Claude Code and click
    Disconnect from Claude Code to remove Chrupio's tools and hooks.
    Chrupio's backups of your Claude Code files are not removed by zap:
      ~/.claude.json.chrupio-backup*  ~/.claude/settings.json.chrupio-backup*
    They can hold MCP server secrets; delete them once Claude Code works.
  EOS
end
