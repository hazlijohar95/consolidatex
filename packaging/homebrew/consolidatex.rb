cask "consolidatex" do
  version "__VERSION__"
  sha256 "__SHA256__"

  url "https://github.com/hazlijohar95/consolidatex/releases/download/v#{version}/Consolidatex-v#{version}.zip"
  name "Consolidatex"
  desc "Switch between AI coding subscriptions (Claude Code, Codex, opencode, Kiro) from the terminal or menu bar"
  homepage "https://github.com/hazlijohar95/consolidatex"

  depends_on macos: ">= :ventura"

  app "Consolidatex.app"
  binary "#{appdir}/Consolidatex.app/Contents/Resources/acc"

  caveats <<~EOS
    Finish setup (imports your existing accounts and hooks up your shell):
      acc setup
  EOS

  zap trash: [
    "~/.config/acc",
  ]
end
