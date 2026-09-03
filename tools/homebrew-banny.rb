class Banny < Formula
  desc "Banny Studio CLI: author, validate, preview, and render .bs shows"
  homepage "https://github.com/mejango/banny-studio"
  url "https://github.com/mejango/banny-studio/releases/download/cli-vVERSION/banny-VERSION-macos.zip"
  sha256 "SHA256_FROM_RELEASE_SCRIPT"
  version "VERSION"

  def install
    root = buildpath/"banny-live-host-#{version}-macos"
    root = buildpath unless root.directory?
    libexec.install root/"banny"
    libexec.install root/"BannyStudio_BannyLive.bundle"
    libexec.install root/"BannyAssets"
    bin.install_symlink libexec/"banny"
    bin.install_symlink libexec/"banny" => "banny-tool"
  end

  test do
    assert_match "banny #{version}", shell_output("#{bin}/banny --version")
    assert_match '"contractVersion" : 3', shell_output("#{bin}/banny capabilities --json")
    assert_match '"--director"', shell_output("#{bin}/banny help 'room serve' --json")
    assert_match '"--director-url"', shell_output("#{bin}/banny help 'room serve' --json")
    assert_match '"--director-model"', shell_output("#{bin}/banny help 'room serve' --json")
    assert_match '"bodies"', shell_output("#{bin}/banny catalog --json")
  end
end
