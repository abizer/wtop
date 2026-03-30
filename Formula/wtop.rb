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
    # Install the LaunchDaemon for the privileged helper
    helper_dest = "/Library/PrivilegedHelperTools/me.abizer.wtop.helper"
    plist_dest = "/Library/LaunchDaemons/me.abizer.wtop.helper.plist"

    # Copy helper binary
    cp libexec/"wtop-helper", helper_dest
    chmod 0755, helper_dest

    # Write LaunchDaemon plist (can't symlink — launchd requires owned files)
    plist_content = {
      "Label" => "me.abizer.wtop.helper",
      "Program" => helper_dest,
      "MachServices" => { "me.abizer.wtop.helper" => true },
      "RunAtLoad" => true,
      "KeepAlive" => true,
    }
    File.write(plist_dest, plist_content.to_plist) rescue nil

    # Load the daemon
    system "launchctl", "bootout", "system/me.abizer.wtop.helper", 2 => "/dev/null" rescue nil
    system "launchctl", "bootstrap", "system", plist_dest rescue nil

    # Symlink .app to ~/Applications for Spotlight
    ohai "Linking wtop.app to ~/Applications..."
    apps_dir = File.expand_path("~/Applications")
    FileUtils.mkdir_p(apps_dir)
    FileUtils.rm_rf("#{apps_dir}/wtop.app")
    FileUtils.ln_sf("#{prefix}/wtop.app", "#{apps_dir}/wtop.app")
  end

  def caveats
    <<~EOS
      wtop is installed as both a CLI tool and a GUI app:

        CLI:  wtop (or sudo wtop for full data)
        GUI:  Search "wtop" in Spotlight/Raycast

      The privileged helper daemon has been installed to enable
      full system process energy monitoring. To check its status:

        sudo launchctl list me.abizer.wtop.helper
    EOS
  end

  service do
    name macos: "me.abizer.wtop.helper"
  end

  test do
    assert_predicate bin/"wtop", :executable?
    assert_predicate libexec/"wtop-helper", :executable?
  end
end
