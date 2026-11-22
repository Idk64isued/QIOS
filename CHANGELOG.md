# Changelog

Light Touch for iOS (QIOS), newest first. Each update is named for its commit. "Added", "Fixed" and "Removed" say
what changed for someone using the app; the patch numbers are the emulator changes in `ios/patches/qemu-ios`.

## Update 73 — Let iOS Write It

Stacks on 72. App-side only plus the guest helper; builds from cache.

**Fixed**
- **lt-notify only ever posted the first of its three names.** It used `r9` as the loop counter, and on iOS `r9`
  is a *volatile* scratch register — Apple's ARM ABI departs from AAPCS here — so `notify_post` was entitled to
  destroy it, and did. The counter came back wrong after the first call and the loop ended. 72's log shows exactly
  one name going out where three were asked for, which means **the notification idea was never actually tested**:
  `com.apple.LaunchServices.applicationRegistered` never fired. The loop uses `r6` now, and the emulator's fake
  `notify_post` scribbles over `r9` the way a real one may, so this cannot pass in the test and fail on the device
  again — which is precisely what it did.

**Added**
- **The app list is handed back to iOS to write, the way it was before update 61.** Until 61 every install from
  iOS 4 up took the installation cache away and let MobileInstallation rebuild it from the app folders as the Home
  screen started — the jailbreak-era "delete the plist" fix. **It drew icons.** It was removed because of how it
  failed, not because it didn't work: the cache went, SpringBoard restarted, and nothing checked for thirty
  seconds. On a device where the rebuild never came, SpringBoard came up with no app list at all, fell over, was
  restarted by launchd and fell over again — a boot loop, with the old cache put back long after the Home screen
  was already looping.
  Nothing was wrong with the rebuild. What was wrong was the thirty seconds and having nothing to put back. Both
  are gone: by the time this runs the device already holds a complete, valid, hand-written app list with the app in
  it, so there is a known-good copy to restore; it is kept in memory, polled for twice a second instead of once
  every two, and restored after **six** seconds rather than thirty. Six seconds is less than one SpringBoard
  launch, so the worst case is a single restart rather than a loop, and the device ends up where it started —
  installed without an icon, rather than bricked.
  It runs once per app per boot, and only when SpringBoard has already read the hand-written list and declined to
  place the app, which on iOS 4 and 5 never happens because installd does the install there.

## Update 72 — Nobody Told Anybody

Stacks on 71. App-side only plus a new guest helper; builds from cache.

71 asked installd as mobile. It said no the same way:

```
installd: turned it down as root (-1); asking again as mobile, ...
installd: and turned it down as mobile too (-1)
```

So it isn't who's asking either. That's two hypotheses retired in one build, which is what they were for.

**Fixed**
- **Nothing was ever told the app existed.** I have been reading this line backwards for three updates:
  *"SpringBoard's icon layout does NOT mention Skype, so it read the app list and declined to place it."*
  It did not read the app list. **SpringBoard never reads that plist** — it asks `installd`, which keeps the
  list in memory. A cache this app rewrites behind installd's back is a cache installd has never read, so
  SpringBoard is answered out of a list that predates the install and quite correctly draws no icon. The files,
  the icons, the 57-key entry, the sequence bump: all correct, all invisible.
  installd ends a real install by posting a Darwin notification, and that is the *only* reason anything else
  re-reads. iOS 4 and 5 never needed it from us because there installd does the install itself and its own list
  is already right — which is exactly why this only ever showed up on 6. So the same notifications now go out by
  hand after the cache is written: `com.apple.mobile.application_installed`,
  `com.apple.LaunchServices.applicationRegistered` and `com.apple.mobile.installation_cache_changed`.

**Added**
- **`lt-notify`**, a fourth guest helper — an armv6 program that posts Darwin notifications through `notify_post`,
  built the same way `lt-install` is (dyld binds `dlopen` and `dlsym`, everything else is looked up) and checked
  the same way: five tests under the ARM emulator covering the names it posts and their order, a failing post, no
  names at all, and an iOS with no `notify_post`, which it reports rather than pretending.

## Update 71 — The Clue That Shook the World

Stacks on 70. Rebuilds the emulator (patch 0027 changes) and the guest helper.

The comparison that should have come first: **iOS 4 and 5 install fine, and only 6 refuses.**

```
iOS 4:  installd installed Fruit Ninja (com.Halfbrick.Fruit) ... in 2 s
iOS 5:  installd installed Twitter (com.atebits.Tweetie2) ... in 4 s
iOS 6:  installd: Twitter not installed, code -1
```

Same lt-install, same 8220-byte binary, same options dictionary, same staging path, same AppSync. Six updates of
suspects — argv, the marshalling, the path, AppSync, dyld's restriction marker — are all disproved at once by a
working case, because every one of them is identical on the two versions that work.

**Fixed**
- **The install now asks as mobile when root is refused.** The one thing that never varied is *who is asking*. The
  agent spawns lt-install as root; iTunes installs through installation_proxy as **mobile**, which is who owns the
  staged package and the container it goes into — and iOS 6 is the release that tightened installd. `lt-install`
  takes a uid as its second argument now and drops to it (setgid before setuid) before calling
  MobileInstallationInstall. Root is still tried first, so nothing that already works changes, and the log says
  which one installd accepted.
- **A framebuffer repair that made things worse now undoes itself** — and this is the dirt and the water in
  Where's My Water. 65 taught this host to put back attachments it had skipped for a framebuffer it took for the
  CA drawable. When that repair *doesn't* help, it used to leave the framebuffer withdrawn and broken anyway: a
  drawable renderbuffer has no storage of its own, which is exactly what makes it a drawable, so replaying its
  attachment gives `INCOMPLETE_ATTACHMENT` and **every draw into that framebuffer is thrown away**. The game
  renders its dirt and its fluids into offscreen targets and composites them, so they came out empty while the
  background art, drawn straight to the screen, looked perfect — `1200 offscreen draws` an interval and
  `drawable mean rgb = 0,0,0` in the log, which is a level you can play only if you know where the dirt is.
  Withdrawing the guess was itself a guess, and a one-way one — the very fault 65 was written to cure. It is
  reversible now: if the repair leaves the framebuffer incomplete, the guess goes back, and the log says so.

## Update 70 — Phone Home

Stacks on 69. App-side only; builds from cache.

69 asked the install one question and got a clear answer. `lt-install` wrote its path file, no `argv did not arrive`
line appeared, and installd still said `-1`. So argv was never the problem, and `-1` now means one thing only:
**installd was reached, and it refused.** Five updates of suspects are finally down to one fact.

**Added**
- **A call or a text, on a timer.** The modem could always ring on demand, which is a button. Now it can ring in
  thirty seconds, which is an alibi: set it going, put this phone down, and the 2007 one rings itself in your hand.
  Calls and texts both take a delay — now, 15s, 30s, 1m or 5m — and whichever is waiting shows a live countdown
  with a cancel, on whichever card you are looking at. It needed nothing new in the emulator: the baseband has had
  `incoming-call` and `incoming-sms` all along, so this is a timer in front of the buttons that were already there.
  The device still has to be on the network before it can ring, and it says so rather than pretending.

**Removed**
- **installd's job goes back the way the device shipped it.** Update 64 rewrote that job to point installd's stderr
  at a file so a refusal could say why. It never said anything — installd reports through ASL and not stderr, which
  three updates of empty log files established. What the edit *did* do was unload and reload a system daemon two
  seconds before asking it to install something (the guest's own syslog shows installd being SIGKILLed), and then
  leave it running from a job this app had rewritten. That was the last thing in the install path this app changed
  and did not control, and it is gone: the original is put back from the backup, the backup and the dead log file
  are deleted, and nothing rewrites that job again. Whether or not it was the reason installd said no, it had no
  business being there while we were trying to find out.

**Added**
- **installd's own words, out of ASL.** This is the one place its refusal reason has ever been, and the one place
  nobody has looked. `syslog` only exists on a jailbroken device, but the store itself is a plain file on every
  device — `/var/log/asl/<date>.asl`, plus the per-uid store that holds a root daemon's messages. The names are
  built from the date instead of listed, because listing needs a shell that stock iOS 6 hasn't got. A refusal now
  reports what ASL has for installd instead of reporting that an empty file was empty.

## Update 69 — Three Times The Width

Stacks on 68. Rebuilds the emulator (patch 0027) and the guest helper.

Two measurements, not two theories. Both came out of reading the paths end to end rather than trying the next idea.

**Fixed**
- **Every A4 device was rendering into a frame buffer a third of its panel's width.** The log has carried the whole
  thing all along, in two lines nothing reconciles: `[gles-angle] frame buffer on an IOSurface (320x480, 1280 bytes
  a row)` and `[gles] present target -> base=0x07b0f000 960x640`. 320x480 isn't a measurement of anything — it's
  the initialiser of the frame buffer's size, and the emulator corrected it from exactly one machine type, the iPod
  touch 2G. So the 3GS keeps 320x480 and is right by coincidence, and the iPhone 4, iPod touch 4G and iPad 1 —
  every board that runs iOS 6 — kept it and were wrong. **That the one setup you said works is iOS 3 on the 3GS is
  not a coincidence.**
  What that did to a frame, in order: the app asks its drawable how big it is, is told 320x480, and sizes its
  viewport to that — so it draws the whole scene into a quarter of the screen. Then the present crops to the same
  guess, `MIN(960, 320)` by `MIN(640, 480)`, and copies 320x480 of pixels into a 960x640 surface. Rendered
  correctly, presented into the corner. The log agrees frame by frame: `ok=1 failed=0`, nothing refused, nothing
  dropped — which is exactly why five rounds of looking for something that failed found nothing. **Nothing failed.**
  That is Need for Speed Shift's corner window; and a game that instead checks its framebuffer and finds 320x480
  attachments under its own 960x640 renderbuffer is the crash on open.
  The size now comes from three places that already knew it instead of from a default: the panel's size from the
  display's own console (every board has one, so no machine type is involved), the render target from the surface
  CoreAnimation is actually presenting into — the only place an iOS 6 app ever states it, and re-adopted when you
  rotate — and the IOSurface itself, which until now took a width and height and ignored them once it existed, so
  it could never grow.
- **`lt-install: -1` now means one thing.** It meant two: `MobileInstallationInstall` returns -1 for a refusal, and
  `lt-install` printed -1 for a missing argument as well. The app mapped -1 to "installd turned it down", so five
  updates were spent on installd, AppSync, dyld's restriction marker and the staging path for a failure that may
  never have reached installd at all — which would also explain the one-second refusal, the empty installd log, and
  why each of those three suspects came back innocent. A missing path is `-7` now, a null one `-8`, and the test
  suite asserts that neither can be mistaken for a refusal and that neither calls installd.

- **The boot-time repairs now survive a reboot, and say so when they can't run.** They used to get exactly one
  chance: the app waited up to five minutes for the guest's agent, ran the web-proxy fix and the GL front-end
  revert on the first answer, and then stopped watching for good. So a guest that rebooted — or a SpringBoard
  restart that took the agent with it — came back with preparation's dead web proxy and nothing left to put it
  right, and the internet went slow again with no way to tell why. And if the agent simply took longer than five
  minutes, the whole thing gave up **without a word**, which looks identical to an agent that is broken.
  The app keeps watching for the life of the session now, and says so if the five minutes pass. Both repairs read
  the guest's own files before changing anything, so a pass with nothing to do costs one read and stays quiet.
- **"A fresh agent said hello" is no longer mistaken for "a fresh boot."** That distinction didn't exist before,
  because the agent was only ever asked once. Now that it's asked repeatedly, clearing the once-per-boot markers on
  every reconnect would have made each install pay for a refusal twice over. The guest's `/tmp` settles it: a
  reboot empties it, so a marker's absence is a new boot and nothing else.

**Added**
- **The install no longer depends on argv arriving.** `lt-install` is the one guest helper dyld loads, and whether
  argv survives dyld's hand-off into a dynamically linked program with an `LC_UNIXTHREAD` entry is the single step
  in this path nobody had measured. Rather than measure it and come back, `lt-install` now takes the path from the
  command line when there is one and reads it from a file the app writes beside the .ipa when there isn't, printing
  `argv did not arrive: ...` when it falls back. The install works either way and the log says which way it went.
  `build.py --check` fails if the assembly and the app ever disagree about that file's name, since two places that
  must agree is how this class of bug starts.
- **Two silent black screens now say why.** Both returns in the panel present — a drawable that doesn't match the
  panel, and a board with no direct panel present — were reachable with nothing whatsoever in the log. They each
  explain themselves once now.

## Update 68 — Shaped Like Theirs

App-side only; builds from cache. Stacks on 67's staging change.

**Fixed**
- **The app-list entry is now shaped the way this iOS shapes its own.** Until now the app's entire `Info.plist` went
  into the entry: **47 keys against the 19 iOS writes**, carrying things no app list has any use for —
  `BuildMachineOSBuild`, `CFBundleSignature`, `CFBundleDocumentTypes`, `CFBundleDevelopmentRegion`.
  The app was always *listed* — reading the cache back found it every time — and the Home screen stayed empty even
  after `uicache` ran, which is the tool whose entire job is to make SpringBoard look again. An entry that is found
  and drawn by nothing is an entry SpringBoard is reading and rejecting.
  So the shape is no longer guessed. The install takes a template from an entry **iOS wrote itself on that device**
  — a User one if installd has ever placed an app, otherwise the richest System one — keeps the keys that template
  has, adds the handful SpringBoard needs to name and draw a third-party app (the `CFBundleIcons` family, which a
  System entry has no use for and a User one cannot do without), adds the four only an installer can know, and drops
  everything else. With no template at all nothing is dropped, because a guess at the shape is worse than the shape
  we already had.
  The log prints the template's full key list, so if this still isn't right the next attempt starts from the real
  thing rather than another inference.

**Added**
- **Whether SpringBoard actually placed the app.** `IconState.plist` is SpringBoard's own record of which icons sit
  on which page, and nothing else writes it. An app that reaches the installation cache and never reaches IconState
  is one SpringBoard read and declined to place — which is a completely different fault from one it never heard
  about, and the Home screen looks identical either way. The install now says which.

## Update 67 — The Wrong Doorstep

App-side only; builds from cache.

**Changed**
- **An .ipa now waits for installd in PublicStaging, where iOS's own installer expects packages**, instead of in a
  folder of ours under `/var/mobile/Media`. Same volume, same owner, and installd refused every single time.
  What made the path suspicious was 66's timing, not a theory: the refusal came **one second** after lt-install
  started, on a 21 MB package. Nothing unzips 21 MB in a second on an emulated A4 — installd was turning the file
  down *before looking inside it*, which is the shape of a path check, not a signature check. Every tool that has
  ever driven this API (ideviceinstaller, iTunes) stages into `PublicStaging` first.
- **And it asks twice.** installd is handed an absolute path here, but the API has always been driven through
  `installation_proxy`, which passes a path relative to `/var/mobile/Media` — `PublicStaging/foo.ipa`. A path check
  that only accepts the relative form would look exactly like what we have been seeing. A refusal costs about a
  second, so both spellings are tried and the log says which one installd took, rather than another round of
  picking one and hoping.
- The empty installd log is now explained rather than just reported: installd reports through ASL, not stderr, so a
  redirect that catches nothing rules out the redirect, not installd. That avenue is closed; the path is the live one.

**Known, from update 66's own evidence**
- The hand-written app-list entry carries **47 keys where iOS writes 19** — our whole `Info.plist` goes in, including
  `BuildMachineOSBuild` and `CFBundleSignature`, while `CodeInfoIdentifier`, `Entitlements` and
  `UIRequiredDeviceCapabilities` are absent. Left alone for now, because the app *is* listed and `uicache` now runs:
  if an icon appears and the app refuses to launch, those missing keys are the next suspect and this is the note
  that says so.

## Update 66 — Make It Say Why

App-side only: no emulator change, so this builds from cache.

**Added**
- **installd's own words, instead of its return code.** Three explanations for its refusal have now died on
  evidence — AppSync is baked in and named in its job (63), the dyld restriction marker that would drop that
  insertion isn't there (64), and the `.ipa` reaches the device intact. All that is left is `code -1`, which is
  `MobileInstallationInstall` saying no without saying why.
  installd isn't silent, though: it writes to its own stderr, and its launchd job sends that nowhere. That job is a
  plist the agent can read and write, so it is now pointed at a file before installd is asked for anything, and
  whatever it writes during a refusal is read back and put in the log beside the code. The job is backed up first,
  and if installd won't start with its log redirected the original is put straight back.
  This matters most on a device that is **not** jailbroken. There the hand-install fallback can place an app, list
  it, and still not get an icon drawn, because SpringBoard was never told — and `uicache`, which would tell it,
  comes from Cydia and so does not exist there. Making installd do the install is the only route on such a device,
  which makes knowing why it refuses the thing everything else waits on.
- **What iOS puts in an app's entry that ours doesn't.** The other half of "installs don't work": a hand-written
  entry gets the app listed (reading the cache back finds it) and still leaves the Home screen blank. Either
  SpringBoard isn't reading that file or it is reading it and rejecting what we wrote. The device already holds
  entries iOS wrote itself, so the install now compares the two and logs which keys are missing from ours. If a
  missing key is what SpringBoard is objecting to, that names it — and fixes the icon on a stock device without
  uicache at all.

## Update 65 — The Attachments It Threw Away

**Fixed**
- **The iOS 6 black screen: this host was throwing the games' framebuffer attachments away.** Update 64's forensics
  printed what was asked for beside what GL held, and on Minecraft it reads:

      asked: glFramebufferRenderbuffer(attach=0x8ce0 obj=1) on fb 1  [SKIPPED: this fb meant the drawable]
      asked: glFramebufferRenderbuffer(attach=0x8d00 obj=2) on fb 1  [SKIPPED: this fb meant the drawable]
      ... six of them, across two framebuffers ...
      GL holds: color0=NONE depth=NONE stencil=NONE

  Every attachment asked for, every one dropped, nothing attached to either framebuffer. Not the shim, not the
  dispatch table, not AppSync: the calls arrived here and this host discarded them.
  It discards them on purpose, when it decides a framebuffer "means the CA drawable" — a guess from a single
  signal, a colour renderbuffer that never passed through `glRenderbufferStorage`. The guess is often right. What
  made it fatal is that it was **unrecoverable**: the call was dropped and nothing remembered it had been made, so a
  framebuffer whose role was guessed wrong could never be put right again. Minecraft's colour renderbuffer doesn't
  look sized to this host, so every framebuffer it touched was emptied and every draw went nowhere — at full speed,
  with a perfectly healthy call stream, which is why this took so long to find.
  The skipped attachments are now kept per framebuffer and put back when the guess is withdrawn: when a framebuffer
  stops meaning the drawable, and from the incomplete-framebuffer check, where `MISSING_ATTACHMENT` on a framebuffer
  being drawn into is proof the guess was wrong — a real drawable presents frames rather than producing nothing.
  When the repair fires it says so, so a wrong guess is visible and fixed instead of silent and permanent.

**Changed**
- The `__RESTRICT` theory from update 64 is **also** ruled out: `installd: carries no dyld restriction marker`. The
  check did its job, changed nothing, and killed a third explanation cleanly. installd's refusal remains unexplained
  and now needs its actual error text rather than its return code.
- The log says when `uicache` isn't on the device (it comes with uikittools from Cydia), which is why a hand-installed
  app can be installed and listed and still not draw its icon until a restart. That is the remaining half of
  "installs don't work" on iOS 6.

## Update 64 — It Was Never AppSync

Update 63's two diagnostics both came back, and both overturned an assumption this project had been carrying.

**Fixed**
- **installd refuses apps because dyld is dropping AppSync, not because AppSync is missing.** 63 asked the device
  instead of assuming, and the answer was `libappsync.dylib present (134624 bytes), installd's job names it`. Both
  halves of the bake are correct; installd simply is not loading the library it is told to load.
  dyld drops every `DYLD_*` variable for a process it considers restricted, and an empty `__RESTRICT/__restrict`
  section in the executable is one of the things that makes it restricted — which is exactly what Apple put in
  installd. FirmwareKit already knows this and renames the marker, but preparation only calls that for iOS 8 and
  later, on the view that "older profiles are intact". On iOS 6 that does not hold.
  So the device's own installd is now checked, and if it carries the marker the same rename is applied in place
  through the agent: sixteen bytes, nothing moved, nothing resized, the original kept beside it as
  `installd.ltm-old`. installd is restarted and the install is tried through it once more before falling back to
  copying the app in by hand. No re-signing is needed because every prepared device boots with
  `cs_enforcement_disable=1`.
  If the marker turns out **not** to be there, nothing is changed and the log says so plainly — which rules the
  theory out rather than leaving it to be assumed for another four updates.
- The detection was checked against real 32-bit ARM Mach-O binaries (the guest helpers walk end to end) and against
  a synthetic installd carrying the marker: detected at the right offset, renamed by exactly sixteen bytes with the
  file's size unchanged, and re-read afterwards as already fixed so it is never done twice.

**Added**
- **Patch 0025: what the framebuffer was asked to hold, next to what it actually holds.** 63 established that every
  framebuffer call *does* reach the host on 6.1.3 — `glFramebufferTexture2D=yes`,
  `glFramebufferRenderbuffer=yes`, all of them — and that the framebuffer is still `MISSING_ATTACHMENT` when
  Minecraft draws into it. The guest is not losing the call to an unnamed dispatch slot, as updates 61 and 63 both
  supposed. The attachment is being asked for *here* and is attaching nothing, which makes it this host's bug.
  Several causes look identical from outside: an object name GL does not know, a renderbuffer with no storage, an
  attach aimed at a framebuffer that is not the bound one, and this host's own drawable aliasing, which
  deliberately skips the GL call when a framebuffer name means the CA drawable. So the last eight attachment
  changes are now kept unconditionally — with the framebuffer they were aimed at, and whether the aliasing skipped
  the call — and printed beside GL's own answer for colour, depth and stencil: the kind of object attached and its
  name, or `NONE`. One run separates every one of those cases.

## Update 63 — Which Side Is It On

**Added**
- **Patch 0024: the log now says whether the framebuffer attachment call ever reached the host.** Minecraft on 6.1.3
  draws correctly, at full speed, into a framebuffer with nothing attached to it — `MISSING_ATTACHMENT`, 1200 draws
  an interval, every one offscreen, a black screen with a perfectly healthy call stream behind it. Two updates have
  now been spent guessing which side of the bridge that gap is on.
  The guest-side diagnostic meant to answer it (patch 0022, from update 59) has **never once run**: it compiles into
  the GL front end, and this build installs that binary prebuilt from the Mac release rather than building it. So
  the one question that matters has never had evidence behind it, only inference — including mine, twice.
  This measures the same thing from the side this build does compile. Every GL call marks its wire id on the way
  into the host, and the incomplete-framebuffer report reads them back: it names the whole framebuffer family
  (`glGenFramebuffers`, `glBindFramebuffer`, `glFramebufferTexture2D`, `glFramebufferRenderbuffer`,
  `glRenderbufferStorage` and the rest) with yes or NO against each, and then says plainly whether an attachment
  call arrived and failed or never arrived at all.
  Those are different bugs. If it arrived, the fault is in this host's own framebuffer handling and is ours to fix
  directly. If it never arrived, its dispatch slot is one of the 605 the shim cannot name on iOS 6, and the fix is a
  per-firmware slot map — a much bigger job, and one worth knowing is necessary *before* starting it.

## Update 62 — Put That Back

**Fixed**
- **Update 61's GL front end is taken back out, and that is what was black-screening iOS 6.** 61 installed the front
  end from LightTouchMac v1.0-2026.11.16 into 6.x devices, on the theory that its decoder reads iOS 6's longer
  dispatch stubs. The device says otherwise: it named **311 of 914 slots where the old one named 309**. Two. The
  decoder that reads a MOVW-built offset followed by a register-offset load is in qemu-ios `db230fe8e8`'s source and
  is *not* in the binary that release ships, so swapping the file bought nothing.
  It was worse than nothing. OpenGLES lives in the dyld shared cache and preparation makes dyld prefer the copy on
  disk — but not for every process. One boot's log shows three processes running the old front end (name table
  `0xad3b3412`, 309 named) and three running the new one (`0xf31a2b68`, 311 named), against a host that speaks the
  first and warns that "the shim was built from another table": two sets of slot numbers resolved as though they
  were the same, which is a black screen waiting to happen, and on the non-jailbroken iOS 6 device it happened.
  Any device 61 changed has preparation's own front end put back automatically on its next boot, and the backup and
  the opt-out marker are cleared with it. Nothing is installed in its place.
  The genuine fix for iOS 6's dispatch table is the emulator move, because the decoder that matters is in the host.
- **The Legacy Store's dark mode is readable.** Two places set their text to black outside the pattern the rest of
  the conversion matched — the chart rows' app names among them — so on a dark page the thing you were trying to
  read was the one thing still black. Both are fixed, and the dimmer greys were raised: every text colour in dark
  now clears 4.5:1 against what it sits on, most of them comfortably.
- **An app's icon is taken from its biggest file, not its first.** The copy to `Icon.png` walked the names in
  `CFBundleIcons` in order and took the first that existed, and that list runs smallest first — so Minecraft PE's
  29-point icon became the Home screen icon and got scaled up to 57, which looks exactly like the bug it is. The
  largest declared file wins now, and on a Retina device the `@2x` name prefers the `@2x` files.

**Added**
- **`uicache` is run after a hand install where the device has it.** On iOS 6 an entry written into the installation
  cache by hand gets the app listed — reading the cache back finds it, and 61's log said so — and still leaves the
  Home screen with no icon, because SpringBoard builds its icon list from its own record rather than from that file.
  `uicache` is the jailbreak tool that rebuilds exactly that record. It only exists on a jailbroken device, so it is
  used where it is there and skipped quietly where it isn't. This is why an install could say it worked and the app
  never appear.
- **When installd turns an app down, the log now says whether AppSync is actually on the device** — whether
  `libappsync.dylib` is on the system volume and whether installd's job names it in `DYLD_INSERT_LIBRARIES`. Every
  refusal so far has been blamed on AppSync without anyone checking, and both halves are files the agent can read.
  If they are both right, AppSync is innocent and the next update can stop chasing it.

## Update 61 — Cydia Oh My Cydia

**Fixed**
- **The internet works properly.** Every prepared device is baked with a proxy auto-config that sends its web traffic
  to `PROXY 10.0.2.100:3128; DIRECT` — on the Mac that is a real helper process running beside the emulator, and this
  app, which runs the emulator as a library inside itself, has never had one. Nothing answered that address, so
  CFNetwork tried it first on *every single connection*, waited out the connect timeout, and only then fell back to
  going direct, with nothing remembered between attempts. That is the whole of "it says it's connected but everything
  times out": Cydia taking minutes to list a repository and then timing out on an install, the store spinning, a web
  page taking a minute. The traffic was never broken — it was queued behind a dead proxy. Light Touch now rewrites
  that PAC to go straight out, on every boot, on devices old and new. The original is kept, and Tweaks ▸ Put Back the
  Web Proxy restores it for anyone running a proxy of their own. (This does not give the device modern encryption: a
  site needing TLS 1.2 and a recent root still won't load. Cydia's repositories are plain HTTP and are fine.)
- **iOS 6 installs apps again, and stops boot-looping afterwards.** From iOS 4 up the installer took the app list
  away and let MobileInstallation rebuild it from the app folders as the Home screen restarted — the jailbreak-era
  "delete the plist" trick. The order was fatal: the list went, SpringBoard was restarted, and only *then* did the
  install wait half a minute to see whether a rebuild had happened. On iOS 6 it doesn't ("No rebuilt app list after
  30 seconds" in the log), so SpringBoard came up with no app list at all, fell over, was restarted by launchd, and
  fell over again. Putting the old list back thirty seconds later was far too late. The entry is now written before
  the restart and the list is never taken away, so there is no window in which the device has none. The icons were
  never the list's doing anyway — copying the app's icon to `Icon.png` and `Icon@2x.png`, the names every one of
  these iOS versions actually looks for, is what fixed those, and that runs either way.
- **Copying anything is several times faster** — songs, photos, an app bundle. The guest's agent sleeps a quarter of
  a second whenever it looks for work and finds none. Sending one 252 KiB chunk, waiting for its reply and only then
  sending the next meant its queue was empty every time it looked, so each chunk cost its own transfer *plus* most of
  that sleep: about a megabyte a second, whatever the link underneath could do. A few chunks are now kept queued
  ahead, so it never sleeps in the middle of a file. The log no longer carries a line per chunk either.
- An install that installd turns down no longer copies the whole `.ipa` in first on every later app that session —
  that upload was half the time a big install took, spent on a refusal that cannot change within a boot. The log also
  prints what installd actually said now, instead of guessing "no AppSync" at every kind of failure.
- **This phone's volume buttons are this phone's again.** Sending them to the device was novel and then just in the
  way: you couldn't turn the sound down while a device was open, and the device threw its own volume overlay up over
  whatever was running. It is now Settings ▸ Volume buttons, off by default.

**Changed**
- **The graphics front end inside iOS 6 devices is replaced with the one from LightTouchMac v1.0-2026.11.16**, and
  patch 0023 teaches this emulator to speak to it. The older one can't read iOS 6's longer dispatch stubs: of 6.1.3's
  914 entry points it named 309 and left 605 unknown, so calls as basic as the framebuffer and viewport ones went
  nowhere. That is why games drew into the wrong place or not at all — Need for Speed Shift in a small box in the
  corner, Shrek Kart and Monkey Ball sideways over garbage, FIFA and Goat Z falling over on launch, Minecraft black.
  The new one reads them all. It goes in automatically on 6.x and later; 1.x–5.x devices are untouched. The old file
  is kept, and Tweaks ▸ Put Back the Old GL restores it (and opts that device out) if anything draws worse.
- **Settings is readable.** Every switch used to carry a full paragraph under it — twenty-odd of them, so the page was
  a wall of grey text you had to read through to find the line you came for. Each row now shows its name and a few
  words; the full explanation is behind the ⓘ beside it. The ones most people never touch — the boot log, the debug
  port, the USB bridge, the translation cache — start collapsed under Advanced.
- **The Legacy Store has a dark mode**, on its own switch (the moon in its top bar), independent of this phone's
  appearance. Same bar glosses, borders and pinstripes, different material; the light side is unchanged to the hex
  digit.
- **The Setup Assistant is full screen under the iOS 6 interface.** It was always drawn as iOS 6's, but it arrived as
  a modern sheet — a rounded card stopping short of the top with the Home screen behind it — which was the one thing
  giving it away. The glass interface still gets a sheet.
- Settings ▸ Location now says what it can and can't do: only the iPhone 3GS has a GPS receiver the modem answers, so
  on every other board there is nothing for iOS to ask and Location Services finds nothing however it is set.
- **Updates are called by their names where the work happens.** The build reads this file's newest heading and puts
  it at the top of the run's summary in Actions, so a run says "Update 61 — Cydia Oh My Cydia" rather than only a
  number, and stamps it into the app so the first line of every log carries it too (`build 1.0-abc1234 (63), Update
  61 — Cydia Oh My Cydia`). A run started by hand, which has no commit to be named after, says so and names the
  branch. Name an update in its commit message and the Actions list reads as the changelog does.

## Update 60 — (not yet named)

**Changed**
- iOS 4 and up install apps the way the Mac app and iTunes do: through the device's own installer, installd. Every
  earlier fix wrote the app in by hand — its folders, its files, its entry in the app list (or the list rebuilt from
  disk) — and on iOS 4 and 5 the icon stayed blank through all of them, with the icon files present, readable and
  uncached and the app list written by iOS itself. Upstream's own documentation says it never does any of that: "User
  applications are installed after boot by native MobileInstallation", with AppSync baked into installd at
  preparation so unsigned apps are accepted — which every iOS 4-capable device here already has (its recipe's
  `appsync: true`); nothing had ever asked installd to do anything. Now the .ipa is copied in and a new guest helper,
  `lt-install`, calls `MobileInstallationInstall`, the call jailbreak-era `ipainstaller` made. installd unpacks,
  places and registers the app and tells SpringBoard, which draws the icon as it does any other app's — no respring.
  If installd won't take an app, the log says why (`lt-install: N`) and the install falls back to the old path, so
  nothing that installed before stops installing. iPhone OS 1 to 3 keep the old path, which always worked there.
  - `lt-install` is the first guest helper that dyld loads (it needs CoreFoundation and MobileInstallation). It is
    laid out by hand like the others, and its test plays dyld under the ARM emulator: binds its symbols from the
    opcodes the way dyld does, fakes the three libraries, and checks the call, its arguments and the result line.

**Merged**
- LightTouchMac as of today (upstream 668b1fe1, from 2f170060 of Nov 5): 247 files, mostly the Mac app and the iPhone
  5 (iOS 10.3.4, which this app doesn't offer: preparing one needs the Mac). On the phone it brings
  the iPhone 5's device art and FirmwareKit's newer preparation code; nothing in this app's own behaviour changes.
  Checked before shipping: no public API the app uses was removed or changed (two gained a defaulted parameter), the
  HostRuntime patch and the FirmwareKit iOS patch still apply, and every check passes on the merged tree.
- **The iOS emulator keeps its own pin** (`ios/qemu-ios.json`, still 1ad1c781). Upstream moved the Mac's emulator to
  db230fe8e8, and 9 of the 22 iOS emulator patches no longer apply there; following it would have broken the build.
  Moving it — which would also bring upstream's faster TCG engine work — is its own job: rebase those 9, then move
  the pin and the Mac files release together.
- The Prepare device workflow (the Mac preparer on a GitHub runner) builds its guest tools from the iOS emulator's pin
  too. Upstream's newer emulator speaks a different GL name table (0xf31a2b68 against this emulator's 0xad3b3412), so a
  device prepared with it would have carried a graphics library this app's emulator doesn't match. Not run since the
  merge: if `scripts/vendor` refuses the older pin, that workflow fails at its Vendor step and says so.
- The build's caches are now keyed on the nine dependencies the iOS build actually uses, not the Mac app's whole list,
  so a merge that only adds a Mac package (this one added TelemetryDeck) doesn't rebuild ANGLE and the emulator. The
  change of key itself costs one full rebuild, this once.

## Update 59 — (not yet named)

**Fixed**
- The blank white icon on iOS 4, with the guesswork finally cut out of it. Update 58's diagnostics ruled out every
  cause the last four updates aimed at: the bundle declares `Icon.png`, both `Icon.png` and `Icon@2x.png` are in
  the guest at full size, and the device has no SpringBoard icon cache that could have gone stale — and a
  period-correct build of the app drew the blank tile anyway. An icon that is present, readable and uncached and
  still doesn't draw is not an icon problem: it is an app iOS never properly registered, which is exactly what
  iOS 5 and 6 turned out to be doing. The hand-written app-list entry is enough to get a name onto the Home screen
  and not enough to get an icon drawn. So iOS 4 now registers the way 5 and 6 do: the app list is taken away and
  MobileInstallation rebuilds it from the apps on disk, in the shape iOS wants. If the rebuild doesn't come, the
  old list goes back with the entry written by hand, as before, so a device is never left without its apps.

**Added**
- Names the GL entry points the dispatch table loses on iOS 6 and 7, where OpenGLES gives the bridge no names to
  read and it has to recognise each call by decoding its code — 309 of 914 against all 905 on iOS 5, and every one
  it misses is a call it refuses. Each failure is now counted by reason and named, and the calls that build a
  render target are checked by name, since one of those missing is enough on its own to explain Minecraft's black
  screen (patch 0022).

## Update 58 — Family Fun

**Added**
- What's New: the changelog is in the app now, on the main menu, and it opens by itself once after an update, so
  a new build says what it changed instead of landing silently.

**Fixed**
- The blank white icon on iOS 4 and 5, and for a reason the last four updates all missed: it was never the icon
  cache. The apps that came through with real icons are old ones that ship `Icon.png`; the ones that stayed blank
  are modern builds whose icon is declared under `CFBundleIcons` (iOS 5 and up), named for an asset catalog, or
  kept only inside `Assets.car` — which no iOS this old can read at all. SpringBoard went looking for `Icon.png`,
  found nothing, and drew the blank tile. Every app now gets an icon under that classic name: the one the bundle
  declares if it is there as a file, else the largest icon-looking image left loose in the bundle, else the
  artwork the App Store wrapped the .ipa in. A bundle that already has `Icon.png` keeps its own.
- Importing a batch of photos or songs no longer sits on one item looking stuck. Each item was copying the
  importer tool into the device all over again and deleting it afterwards — an upload and two round trips per
  item, on top of the item itself. The tool goes over once per boot now, and the copy shows its percentage, so a
  slow item reads as busy rather than frozen.
- Location says something useful when it can't start. Inside LiveContainer, iOS grants location to LiveContainer
  itself, so a missing permission there came back as a flat "not allowed" that read like a refusal in this app's
  own settings. The log now names the app the permission actually belongs to, and tells a refusal apart from a
  LiveContainer build that has no location at all.

**Known, not fixed here**
- Minecraft draws nothing on iOS 6, and the log is now specific about why: it draws into a framebuffer with no
  attachment (`0x8CD7`), so every draw is thrown away and the screen stays black. The likely cause is the gap
  already on the list — on iOS 6 the GL bridge can name only 309 of 914 entry points, against all 905 on iOS 5,
  so the call that attaches the render target is probably one of the 605 it cannot name and drops. Naming
  iOS 6's table is its own piece of work, and it is next.

## Update 57 — (not yet named)

**Fixed**
- Two fingers now reach the emulated device, so pinch to zoom, rotate and two-finger scroll work. The app has
  always tracked a second finger and sent it; the emulator dropped everything but the first, and every gesture
  arrived in the guest as a one-finger drag (patch 0021).

**Added**
- The install log now says what icon the app's Info.plist declares, which of those files actually reached the
  guest, and which of SpringBoard's icon caches were really there to clear. The blank icon on iOS 4 and 5 has
  survived three fixes aimed at the cache; these three lines say whether the cache was ever the problem.

## Update 56 — (not yet named)

**Added**
- The log's first lines now name the build that wrote it (`build 1.0-<commit> (<run number>)`), stamped in by CI.
  Update 55's graphics fix was investigated as if it had never shipped, on the strength of a log that turned out to
  predate the install; a log can no longer be mistaken for one from a different build.

**Fixed**
- iOS 5: the white icon came back on the next install, after update 55's icon-cache fix had worked once. Two causes,
  both fixed here. SpringBoard keeps the same icon cache in memory that it keeps in those files, so deleting the
  files while it was running bought nothing — it wrote its copy straight back. The caches are now deleted with
  SpringBoard held down (`launchctl unload`, delete, `load`), so the Home screen that comes back has nothing cached
  and draws every icon from the app bundles. If it can't hold SpringBoard down it says so and clears them anyway,
  the way it used to.
- Reinstalling an app made a second copy of it instead of replacing it: the install looked for the app's existing
  container under a key (`Container`) that the lists iOS 5 and 6 write themselves don't always carry, so it minted
  a new container and left two bundles with the same bundle ID on disk. It now takes the container from the entry's
  `Path` as well, and a reinstall lands where the app already lives, documents and settings included.
  - A device that already has a duplicate from before this fix keeps it: the app list points at one of the two
    bundles and the other is invisible junk. Recreating that device is the clean way out.

## Update 55 — (not yet named)

**Fixed**
- iOS 4 and 5: installed apps still showed a blank white icon after update 54 (iOS 6, whose apps had never been
  drawn, came through with real icons — the tell). SpringBoard keeps the icons it has drawn in cache files, and on
  a Retina device (the iPhone 4) those are the @2x files; the install deleted only the non-Retina names, so an
  icon once drawn blank stayed blank through every reinstall. All the names go now. Reinstall an app (any app —
  the Home screen redraws every icon) to get the real icons back.
- A white box with a stuck badge from installs made before update 52 (the old "Waiting…" placeholder, tagged by
  bundle ID) is now taken down when that app is installed again.
- An icon drawn as a solid black box, and apps whose graphics came out black or wrong on iOS 5 and 6: those draw
  through four graphics calls (vertex array objects) the emulator refused — the log said "the guest will render
  wrong", and it did. The emulator carries them now (patch 0020).

## Update 54 — (not yet named)

**Fixed**
- iOS 5 and 6: an installed app came up with a blank white icon (iOS 5) or never reached the Home screen at all
  (iOS 6), even though it was on the device and in the Apps list. These versions don't accept an app-list entry
  this app writes, however exactly it is shaped — update 53's sequence numbers, placeholders and cache clearing
  made no difference. Now, on 5 and 6, the install deletes the app list instead and lets iOS rebuild it from the
  apps on disk as the Home screen restarts, so iOS writes every entry itself. The install then waits and checks
  the rebuilt list names the app (the log says how it went); if no list reappears within half a minute, the old
  one is put back with the entry added the old way, so the device is never left without its apps. Apps already
  installed on an iOS 5 or 6 device are picked up by the same rebuild on the next install.
- iPhone OS 2 to iOS 4 installs are unchanged.

## Update 53

**Tried** (kept, but didn't cure it — see update 54)
- iOS 6: apps never showed on the Home screen. This update bumped the app list's change counter the way iOS's
  installer does; iOS 6 still didn't show them.
- iOS 5: installed apps showed a blank white icon. This update skipped the "Waiting…" placeholder on iOS 4 and
  later and cleared the Home screen's icon caches before restarting it, as uicache does; the icons stayed blank.

**Fixed**
- Sound out of step with the screen: the player used to slow itself down (86–92% speed in the logs) whenever the
  emulator fell behind, so the sound drifted behind the picture. It now stays in sync, with a moment of silence when
  the emulator can't keep up. **Smooth sound** (Settings) brings the old behavior back.

## Update 52

**Faster**
- Device setup runs on JIT all the way through. Only the first emulator a launch started could use JIT (the
  debugger blesses fast code once, then leaves), so the keybag and first-start boots of a setup, and the device
  you started after it, ran on the interpreter: iOS 5 on the iPhone 4 spent most of an hour in "Starting iOS". Now
  the app has the debugger bless one buffer when it opens, and every boot of that launch uses it (patch 0019).
- No more 15-minute stall at "Booting the restore ramdisk": that boot was waiting on a debugger iOS had paused in
  the background.

**Fixed**
- iOS 4: an installed app's icon came up blank. The "Waiting…" placeholder is now taken down before the Home
  screen restarts, instead of after it.
- Cool down automatically made iOS 4 laggy: a phone running an emulator reports "serious" heat within seconds, so
  it ran at 30 frames a second the whole time. It now waits for "critical" and cools until the phone is back to fair.

## Revolutionary (update 51)

**Added**
- iOS 4 opens text fields with the on-screen keyboard again (see Fixed). A keyboard connected to the phone still
  becomes the device's own USB keyboard from its first key, and is unplugged when it disconnects.
- **Cool down automatically** (Settings, on by default): when the phone gets hot, the device's screen drops to 30
  frames a second until it cools, then goes back to 60, without a restart (patch 0018).
- iOS 5 is ready to try on the iPhone 4, iPhone 3GS, iPod touch 3G and 4G and the iPad (all marked experimental).

**Fixed**
- iOS 4: no on-screen keyboard. The device booted with a USB keyboard plugged in, and iOS 4 hides its own keyboard
  while one is connected. Saved states from before this update are skipped once (they include that keyboard).
- iOS 4: a flash of solid green as an app opened. An empty video buffer was shown before anything was in it
  (patch 0018).
- Screen recording crashed the app on Retina devices (iPhone 4): frames queued up faster than the encoder took them
  until iOS ran out of memory, and a failed encoder brought the app down. Now at most two frames wait, and a failure
  says so instead of crashing.
- A saved state from before a device had its NOR is thrown away instead of restoring a blank one.
- Preparation boots (the keybag and seal boots) show their console in Console › Device while they run, and the
  log keeps their last lines, so a setup that stalls on "Booting the restore ramdisk" can be diagnosed.

**Faster and cooler**
- The A4 devices' screen no longer allocates a whole frame (2.4 MB on Retina) every time it refreshes (patch 0018).

## Keybag fix 2 (update 50)

**Fixed**
- iPhone 3GS microphone: recording read silence, because the port the device records through answered every read
  with zeros. It now carries this phone's microphone (patch 0017).
- A device's save from before it had its NOR could put a blank NOR back (the iPhone 4 boot loop after Keybag fix).

## Keybag fix (update 49)

**Fixed**
- **iOS 4 boots on the iPhone 4.** The device's NOR, which holds the encryption keys iOS 4's data protection made
  when the device was prepared, was never given to the emulator; iOS 4 couldn't load its keybag ("FATAL KEYBAG
  ERROR") and rebooted forever. Every device with a NOR now gets its own writable copy, as the Mac app does.

**Removed**
- The Springboard home screen. The iOS 6 list is the default; a phone that was set to Springboard switches to it.

## Colors Everywhere fix (update 48)

**Fixed**
- A build error in the Springboard banner.

## Colors Everywhere (update 47)

**Added**
- Home screen choice (Settings › Home Screen): the original list drawn as iOS 6's grouped tables (pinstripes, ON/OFF
  switches, glossy bars), or the original glass look. The iOS 6 look comes in light and dark.
- Add Device as a Setup Assistant: slide to set up, choose a device, choose its software, name it, watch it being
  set up, "Welcome to your iPod touch". iOS 6 style or glass style, to match the home screen.
- Version badges in the version lists, with a red BETA n or gold GM tag on developer seeds.
- The Legacy Store's **Downloads** tab: what is downloading, waiting and done; downloads keep going after the store
  closes; apps can be downloaded with no device running and installed later; Install Again without downloading.
- Console: the device's serial console (with Settings › Boot › Kernel console) and Light Touch's log, live.
- GPS: the iPhone 3GS's location follows this phone (Settings › Location).
- Console button on the glass home screen; a forced-on microphone switch (in the … menu) for testing.

**Faster**
- App installs: the whole app goes over as one archive and unpacks in the device (`lt-unpack`). Angry Birds: about
  3 minutes before, 17 seconds after.
- The NAND read cache (patch 0015): the iPhone 4's boot was spending most of its time waiting on storage.
- ANGLE renders into an IOSurface (patch 0016): no `glReadPixels` per frame.

## Tilt and sleep, Prep fix, Hotfix

**Fixed**
- Tilt direction (roll), smoother tilt and compass; the sleep overlay no longer shows before a device has booted.
- On-device firmware preparation built again (a Swift compiler crash in the FirmwareKit patch).
- Sharp pixels in Seamless view, the 3D model's sleep animation being cut off.

## Everything Changes. Again.

**Added**
- 3D devices (View › 3D), the startup chime, Cool mode, sharp pixels.
- Tilt on every board (patch 0012).

**Faster and cooler**
- Jump-cache generations (patch 0013), memory handed back after preparation boots (patch 0014), a Metal presenter.

## Peeled off

**Added**
- Orientation: the picture inside the device's screen follows the front app (or how the device is held), touches
  turned to match; ANGLE packaged as a framework (patch 0011).

## Faster Than oranges

**Added**
- Graphics renderers: ANGLE (Metal, the default), iPhone GL, Classic (patches 0009, 0010); the microphone
  (patch 0007).

## Update 35, Update 34

**Fixed**
- Freezes under heavy storage writes (the VIC watch, patch 0008); preparation boots in-process (`OneShotRunner`).
- Music and photo import, the install path.

## Hello Again (update 33)

**Added**
- The app's icon and logo. Music import, photos and videos into the device, screen recording, tweaks (Apple's hidden
  switches), the install placeholder icon, the microphone.
- Newer devices prepared on the phone (iPhone 3GS, iPod touch 3G and 4G, iPhone 4, iPad).
- Settings: Wi-Fi, hardware keyboard keys, debug port.

## Update 32 and earlier (updates 13–32)

- **32**: installing apps without a jailbreak (`lt-mkdirs`, the guest agent), closing the app safely, graphics on an
  iOS host, texture fixes (patch 0005).
- **30–31**: the build checks (`precheck.py`, `check-all.sh`) that catch mistakes before CI does.
- **29**: original-iPhone firmware advice, shutting a device down, sound.
- **27–28**: what the device is told and reports (battery, charger, vibration, motion).
- **24–26**: carrier, calls and messages; the USB bridge; fixes for blank screens and phones that wedge after boot.
- **17–22**: the USB stack (AFC, lockdown, install proxy), the startup tone, diagnostics, boot fixes.
- **13–15**: Add Device (ready-made iPod touch, firmware from the catalog, your own IPSW), the app icon, preparation.
