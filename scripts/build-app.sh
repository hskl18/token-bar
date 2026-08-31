#!/bin/zsh

set -euo pipefail

project_root="${0:A:h:h}"
app_path="$project_root/build/Token Bar.app"
contents_path="$app_path/Contents"
binary_path="$project_root/.build/release/TokenBar"

cd "$project_root"
swift build -c release

if [[ -e "$app_path" ]]; then
  /usr/bin/find "$app_path" -depth -delete
fi
/bin/mkdir -p "$contents_path/MacOS" "$contents_path/Resources"
/bin/cp "$binary_path" "$contents_path/MacOS/TokenBar"
/bin/cp "$project_root/Resources/Info.plist" "$contents_path/Info.plist"
/bin/cp "$project_root/Resources/TokenBarMark.svg" "$contents_path/Resources/TokenBarMark.svg"
/bin/cp "$project_root/Resources/TokenBar.icns" "$contents_path/Resources/TokenBar.icns"
/bin/cp "$project_root/Resources/ClaudeCodeMark.svg" "$contents_path/Resources/ClaudeCodeMark.svg"
/bin/cp "$project_root/Resources/CodexMark.svg" "$contents_path/Resources/CodexMark.svg"
/usr/bin/codesign --force --deep --sign - "$app_path"

echo "$app_path"
