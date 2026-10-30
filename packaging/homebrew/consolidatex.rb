class Consolidatex < Formula
  desc "Run several Claude Code, Codex and opencode subscriptions side by side"
  homepage "https://github.com/hazlijohar95/consolidatex"
  url "https://github.com/hazlijohar95/consolidatex/archive/refs/tags/v__VERSION__.tar.gz"
  sha256 "__SHA256__"
  license "MIT"
  head "https://github.com/hazlijohar95/consolidatex.git", branch: "main"

  depends_on macos: :ventura

  # Built from source on purpose: an app compiled on the user's Mac is not quarantined,
  # so it opens without Gatekeeper prompts even though releases are not yet notarized.
  def install
    args = ["--disable-sandbox", "-c", "release"]
    system "swift", "build", *args, "--product", "acc"
    system "swift", "build", *args, "--product", "Consolidatex"
    products = Utils.safe_popen_read("swift", "build", *args, "--show-bin-path").chomp
    system "script/bundle", products, prefix/"Consolidatex.app", version.to_s
    bin.install_symlink prefix/"Consolidatex.app/Contents/Resources/acc"
  end

  def caveats
    <<~EOS
      Finish setup (imports your accounts, hooks up your shell, adds the menu bar app):
        acc setup
    EOS
  end

  test do
    assert_match "acc #{version}", shell_output("#{bin}/acc version")
    assert_match "acc launch claude", shell_output("#{bin}/acc shell-init zsh")
  end
end
