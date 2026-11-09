# iOS I4 package verifier

This directory documents the static package audit for the private I4 iOS
candidate. It checks a single arm64 `Runner.app` against the `i4-agent-images`
manifest contract, including the fixed school-reader hashes, source revision,
notification and diagnostic-export wiring, and the native image-picker channel.
The base bundle identifier is `cn.ustcassistant.ios.private`; installation uses
the existing Sideloadly identity and is intended to replace the installed app
in place.

## Use on Windows

Use Conda `basic310` to run the synthetic-only verifier suite and to inspect a
candidate IPA. Give each audit a new report path:

```powershell
& 'E:\conda\envs\basic310\python.exe' tools/ios-i4/test_verify_package.py
& 'E:\conda\envs\basic310\python.exe' tools/ios-i4/verify_package.py --ipa '<candidate.ipa>' --expected-revision '<40-character-source-SHA>' --report '<new-report.json>'
```

The suite creates only synthetic archive contents. The package command reads
the IPA and the checked-in school-reader sources; it does not contact a school,
read browser authentication data, or access signing credentials. Reports omit
local file paths and identify Apple signature validity as `not-verified`.

## Audit boundary

The static audit checks the manifest fields, matching `I1SourceRevision` through
`I4SourceRevision` plus the Dart AOT revision, fixed source scripts, the single
device Runner and required frameworks, and the absence of Widget/App Group,
audio, model, private-key, provisioning-profile, ATS override, background-mode,
remote-notification, and known I2/I3/I4 fixture or loopback-test markers. It
rejects common persistent-data asset formats (`.db`, `.sqlite`, `.sqlite3`,
WAL/SHM sidecars, `.jsonl`, `.ics`, `.csv`, and `.tsv`). It also requires the
native image channel and `pickImages` strings, the existing notification and
system-document export markers, the I4 `photosui-imageio-v1` declaration, and
two stable Agent UI `ValueKey` strings in the Dart AOT (`agent-composer` and
`agent-current-approval-open`).

These path and format gates do not prove that arbitrary text or other files
contain no private content. The candidate build is assembled from the
controlled Git source and fixed resources; the build workflow separately
checks which resources it packages and excludes generated and private data.

Marker presence demonstrates that the native strings are in the compiled
Runner and that the fixed Agent UI keys are in the Dart AOT; it does not prove
that those features run correctly. This check
does not validate an Apple signature, a cloud build, installation, the target
phone, real photo selection, notification delivery, or user experience. Those
remain separate evidence.
