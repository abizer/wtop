class Wtop < Formula
  desc "Real-time power monitor for Apple Silicon Macs"
  homepage "https://github.com/abizer/wtop"
  url "https://github.com/abizer/wtop.git", tag: "v0.1.0"
  license "MIT"

  depends_on :macos
  depends_on xcode: ["15.0", :build]

  def install
    system "swift", "build", "-c", "release", "--disable-sandbox"
    bin.install ".build/release/wtop"
  end

  def caveats
    <<~EOS
      wtop opens a native macOS window showing live power metrics.

      For full per-process energy data, run with sudo:
        sudo #{bin}/wtop

      Without sudo, system power, CPU cores, and user-process
      energy are still available.
    EOS
  end

  test do
    # App launches a window — just verify the binary exists and runs
    assert_predicate bin/"wtop", :executable?
  end
end
