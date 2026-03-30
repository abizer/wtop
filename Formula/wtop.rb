class Wtop < Formula
  desc "Real-time power monitor for Apple Silicon Macs"
  homepage "https://github.com/abizer/wtop"
  url "https://github.com/abizer/wtop.git", tag: "v0.1.0"
  license "MIT"

  depends_on :macos
  depends_on arch: :arm64
  depends_on xcode: ["15.0", :build]

  def install
    system "swift", "build", "-c", "release", "--disable-sandbox"

    # Install the main app binary
    bin.install ".build/release/wtop"

    # Install the privileged helper and its LaunchDaemon plist
    # These get activated by `brew postinstall` or `just install-helper`
    libexec.install ".build/release/wtop-helper"
    (etc/"wtop").install "Resources/me.abizer.wtop.helper.plist"

    # Build the .app bundle for Spotlight/Raycast launching
    app_dir = prefix/"wtop.app/Contents"
    (app_dir/"MacOS").mkpath
    (app_dir/"Helpers").mkpath
    (app_dir/"Resources").mkpath
    cp ".build/release/wtop", app_dir/"MacOS/wtop"
    cp ".build/release/wtop-helper", app_dir/"Helpers/wtop-helper"
    cp "Info.plist", app_dir/"Info.plist"
    cp "Resources/me.abizer.wtop.helper.plist", app_dir/"Resources/"
    system "codesign", "--force", "--sign", "-", prefix/"wtop.app"
  end

  def post_install
    helper_dest = "/Library/PrivilegedHelperTools/me.abizer.wtop.helper"
    plist_dest = "/Library/LaunchDaemons/me.abizer.wtop.helper.plist"

    # Copy helper binary
    mkdir_p "/Library/PrivilegedHelperTools"
    cp libexec/"wtop-helper", helper_dest
    chmod 0755, helper_dest

    # Install LaunchDaemon plist (on-demand: only runs when wtop.app connects)
    cp etc/"wtop/me.abizer.wtop.helper.plist", plist_dest

    # Register with launchd (won't start until the app connects via XPC)
    system "launchctl", "bootout", "system/me.abizer.wtop.helper", 2 => "/dev/null" rescue nil
    system "launchctl", "bootstrap", "system", plist_dest

    # Symlink .app to ~/Applications for Spotlight
    apps_dir = File.expand_path("~/Applications")
    FileUtils.mkdir_p(apps_dir)
    FileUtils.rm_rf("#{apps_dir}/wtop.app")
    FileUtils.ln_sf("#{prefix}/wtop.app", "#{apps_dir}/wtop.app")
  end

  def caveats
    <<~EOS
      wtop is installed as both a CLI tool and a GUI app:

        CLI:  wtop
        GUI:  Search "wtop" in Spotlight/Raycast

      A privileged helper runs on-demand (only while wtop is open)
      to provide system process energy data. It auto-exits 30s after
      the app closes.

      To fully uninstall (remove the helper daemon):
        sudo launchctl bootout system/me.abizer.wtop.helper
        sudo rm -f /Library/PrivilegedHelperTools/me.abizer.wtop.helper
        sudo rm -f /Library/LaunchDaemons/me.abizer.wtop.helper.plist
        rm -f ~/Applications/wtop.app
    EOS
  end

  test do
    assert_predicate bin/"wtop", :executable?
    assert_predicate libexec/"wtop-helper", :executable?
  end
end
