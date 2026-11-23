cask "wtop" do
  version "0.5.1"
  sha256 "05f49334965227d82544b17a5b4b5dab61980569555d2ced23aafe5f47d94b8a"

  url "https://github.com/abizer/wtop/releases/download/v#{version}/wtop.app.zip"
  name "wtop"
  desc "Real-time power monitor for Apple Silicon Macs"
  homepage "https://github.com/abizer/wtop"

  depends_on arch: :arm64
  depends_on macos: :sonoma

  app "wtop.app"

  postflight_steps do
    # Strip quarantine — app is ad-hoc signed, not notarized
    run "/usr/bin/xattr", args: ["-r", "-d", "com.apple.quarantine", "{{appdir}}/wtop.app"]
    # Install privileged helper daemon (prompts for password)
    run "wtop.app/Contents/Resources/install-helper.sh", base: :appdir, sudo: true
  end

  uninstall launchctl: "me.abizer.wtop.helper",
            delete:    "/Library/PrivilegedHelperTools/me.abizer.wtop.helper",
            trash:     "/Library/LaunchDaemons/me.abizer.wtop.helper.plist"

  zap trash: [
    "~/Library/Caches/me.abizer.wtop",
    "~/Library/Preferences/me.abizer.wtop.plist",
  ]

  caveats <<~EOS
    The privileged helper has been installed. It runs on-demand (only
    while wtop is open) and auto-exits 30 seconds after the app closes.
  EOS
end
