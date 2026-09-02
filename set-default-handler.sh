#!/bin/bash
# Makes MacRAR the default application for .zip, .7z and .rar system-wide.
# Usage:
#   ./set-default-handler.sh              # zip, 7z, rar
#   ./set-default-handler.sh --with-tar   # additionally tar, tgz, gz, bz2, tbz2, tbz
#
# Uses the supported NSWorkspace API via an inline Swift script — no extra tools needed.
set -e
cd "$(dirname "$0")"

# find the app: prefer /Applications, fall back to the bundle next to this script
if [ -d "/Applications/MacRAR.app" ]; then
    APP="/Applications/MacRAR.app"
elif [ -d "$PWD/MacRAR.app" ]; then
    APP="$PWD/MacRAR.app"
else
    echo "MacRAR.app not found — run ./build-app.sh first (or move the app to /Applications)."
    exit 1
fi

# make sure LaunchServices knows about the bundle before assigning it
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP" 2>/dev/null || true

TMP="$(mktemp -t macrar-default).swift"
trap 'rm -f "$TMP"' EXIT
cat > "$TMP" <<'EOF'
import AppKit
import UniformTypeIdentifiers

let args = CommandLine.arguments
let appURL = URL(fileURLWithPath: args[1])
var exts = ["zip", "7z", "rar"]
if args.contains("--with-tar") { exts += ["tar", "tgz", "gz", "bz2", "tbz2", "tbz"] }

let group = DispatchGroup()
for ext in exts {
    guard let ut = UTType(filenameExtension: ext) else { print("\(ext): unknown type"); continue }
    group.enter()
    NSWorkspace.shared.setDefaultApplication(at: appURL, toOpen: ut) { error in
        print("\(ext): " + (error == nil ? "ok" : "failed — \(error!.localizedDescription)"))
        group.leave()
    }
}
_ = group.wait(timeout: .now() + 15)
EOF

swift "$TMP" "$APP" "$@"
echo "Done. Archives will now open in MacRAR by double-click."
