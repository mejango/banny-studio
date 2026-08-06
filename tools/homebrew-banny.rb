class Banny < Formula
  desc "Banny Studio CLI: author, validate, preview, and render .bs shows"
  homepage "https://github.com/mejango/banny-studio"
  url "https://github.com/mejango/banny-studio/releases/download/cli-vVERSION/banny-VERSION-macos.zip"
  sha256 "SHA256_FROM_RELEASE_SCRIPT"
  version "VERSION"

  def install
    bin.install "banny"
    bin.install_symlink "banny" => "banny-tool"
  end

  test do
    assert_match "banny #{version}", shell_output("#{bin}/banny --version")
    assert_match '"contractVersion":2', shell_output("#{bin}/banny capabilities --json")
  end
end
