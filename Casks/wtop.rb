cask "wtop" do
  version "0.1.0"
  sha256 :no_check # Update with actual sha256 after first release

  url "https://github.com/abizer/wtop/releases/download/v#{version}/wtop.app.zip"
  name "wtop"
  desc "Real-time power monitor for Apple Silicon Macs"
  homepage "https://github.com/abizer/wtop"

  depends_on macos: ">= :sonoma"
  depends_on arch: :arm64

  app "wtop.app"

  zap trash: [
    "~/Library/Caches/me.abizer.wtop",
    "~/Library/Preferences/me.abizer.wtop.plist",
  ]
end
