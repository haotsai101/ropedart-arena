# Deploying Dartrope Arena to iOS and Android

Everything is scripted; the only manual parts are the store accounts and
records that need you (payment, identity, legal forms).

| Command | Result |
|---|---|
| `scripts/tools/export_ios.sh` | Xcode project → `export/ios/RopeDartArena.xcodeproj` |
| `scripts/tools/export_ios.sh device` | development-signed `.ipa`, installed on the plugged-in iPhone |
| `scripts/tools/export_ios.sh testflight` | App Store build uploaded to App Store Connect / TestFlight |
| `scripts/tools/export_android.sh` | debug APK → `export/android/RopeDartArena.apk` |
| `scripts/tools/export_android.sh install` | same, then installed + launched on the USB-connected phone |
| `scripts/tools/export_android.sh play` | upload-key-signed App Bundle → `export/android/RopeDartArena.aab` |

Every commit runs the first and fourth automatically (post-commit hook,
`scripts/tools/install-git-hooks.sh` installs it; opt out per commit with
`SKIP_IOS_EXPORT=1` / `SKIP_ANDROID_EXPORT=1`).

App identity: **Dartrope Arena**, bundle id / package `com.ropedartarena.game`,
landscape only, icon from `assets/icon/` (rendered from `art/mascot/mascot.blend`).

## Versions

`VERSION` holds the marketing version (`0.1.0`) — bump it by hand per release.
The build number is the git commit count, so every build is higher than the
last (both stores require that). Both are stamped into the build by
`scripts/tools/app_version.sh`; `export_presets.cfg` itself is left untouched.

Online play also requires every player to run the **same commit**
(`scripts/game_version.gd`, checked by the server when joining a room) — ship
iOS and Android from the same commit.

## Secrets (back these up)

* `~/.ropedart-arena/upload.keystore` + `upload-keystore.txt` — the Google Play
  **upload key** and its password. Put both in a password manager. If lost
  after you've enrolled in Play App Signing, Google support can reset the
  upload key; before your first upload you can simply generate a new one.
* `.godot/export_credentials.cfg` (git-ignored) — where Godot keeps the
  keystore path/password for the "Android Play" preset.
* Never commit either. `export_presets.cfg` is committed and holds no secrets.

## Test on your own devices (no paid accounts needed)

### iPhone
1. Xcode → Settings → Accounts → sign in with your Apple ID (a free Apple ID
   works; it currently shows invalid credentials and must be re-entered).
2. Plug the iPhone in, tap **Trust**, and turn on Settings → Privacy &
   Security → **Developer Mode** (the phone restarts).
3. `scripts/tools/export_ios.sh device`

With a free Apple ID the install expires after 7 days (re-run the command).
If your team id isn't `5H964M87S4`, run with `IOS_TEAM_ID=<yours>` and update
`application/app_store_team_id` in `export_presets.cfg`.

### Android phone
1. Settings → About phone → tap **Build number** 7× → Developer options →
   enable **USB debugging**; plug in and accept the prompt.
2. `scripts/tools/export_android.sh install`

## Store beta — TestFlight (iOS)

1. **Enroll** in the Apple Developer Program ($99/year,
   developer.apple.com/programs). If this gives you a new team id, update
   `application/app_store_team_id` in `export_presets.cfg` and the default
   `TEAM_ID` in `scripts/tools/export_ios.sh`.
2. **App record**: App Store Connect → Apps → **+** → New App → iOS, name
   "Dartrope Arena" (or another free name), bundle id `com.ropedartarena.game`
   (register it under Certificates, Identifiers & Profiles → Identifiers if
   it isn't offered), any SKU.
3. **API key** (lets the script sign and upload without Xcode prompts): App
   Store Connect → Users and Access → Integrations → App Store Connect API →
   generate a key with *App Manager* access, download the `.p8` (once!), then
   ```
   export ASC_KEY_ID=XXXXXXXXXX ASC_ISSUER_ID=xxxxxxxx-... ASC_KEY_PATH=~/.ropedart-arena/AuthKey_XXXXXXXXXX.p8
   scripts/tools/export_ios.sh testflight
   ```
4. In App Store Connect → TestFlight, wait for processing (~10–30 min), add
   yourself/testers to an internal group. The build already declares it only
   uses exempt (standard HTTPS/WSS) encryption, so there's no export
   compliance question.
5. Before *external* testers: fill in Test Information and the App Privacy
   section (the game sends a chosen username and gameplay traffic to the
   multiplayer server; it does not collect personal data otherwise).

## Store beta — Google Play internal testing (Android)

1. **Developer account**: play.google.com/console ($25 once). Identity
   verification can take a few days.
2. **Create app**: name "Dartrope Arena", game, free.
3. `scripts/tools/export_android.sh play` and upload
   `export/android/RopeDartArena.aab` under Testing → **Internal testing** →
   Create new release. On this first upload accept **Play App Signing**
   (Google holds the app signing key; our keystore is only the upload key).
4. Add tester emails to the internal testing list and share the opt-in link.
5. Play requires these App content forms before testing goes live: privacy
   policy URL, data safety, content rating questionnaire, target audience, ads
   (none). Note: new *personal* developer accounts must currently also run a
   closed test with a minimum number of testers for two weeks before they can
   publish to production — internal testing is not affected.

## Troubleshooting

* **"Cannot export project with preset … due to configuration errors"** —
  iOS/Android need `rendering/textures/vram_compression/import_etc2_astc=true`
  (set in `project.godot`). The editor's Export dialog names the exact problem.
* **Export templates must match the editor version** (4.7.2). In September the
  4.7.2 folder held Android templates from the 4.7 .NET build; they were
  replaced with the official 4.7.2 ones (old copies kept in
  `~/Library/Application Support/Godot/export_templates/4.7.2.stable/_mismatched_4.7_mono_backup/`).
  After changing templates, delete the project's `android/` folder.
* **xcodebuild: "No Accounts" / "No profiles for com.ropedartarena.game"** —
  sign in to Xcode (step 1 above) or pass an App Store Connect API key.
* **Android emulator: "Can't create buffer … VkResult error -8"** — the
  emulator's software Vulkan can't run Godot's Vulkan renderer. Test on a real
  phone (or temporarily set `rendering/renderer/rendering_method.mobile` to
  `gl_compatibility`, which runs fine on the emulator — don't commit that).
* **`INSTALL_FAILED_VERSION_DOWNGRADE`** — a build with a lower build number is
  already installed; `adb uninstall com.ropedartarena.game` first.
