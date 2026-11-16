#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
if [[ "$(uname -s)" != Darwin ]]; then
  print -u2 'Codex Controller currently supports macOS only.'
  exit 1
fi
if ! /usr/bin/xcode-select -p >/dev/null 2>&1; then
  print -u2 'Install Apple command-line tools first: xcode-select --install'
  exit 1
fi
/usr/bin/python3 --version >/dev/null
zsh build.sh
TARGET="${CODEX_CONTROLLER_INSTALL_DIR:-$HOME/Applications}"
mkdir -p "$TARGET"
/usr/bin/ditto 'dist/Codex Controller.app' "$TARGET/Codex Controller.app"
/usr/bin/codesign --force --sign - "$TARGET/Codex Controller.app"
print "Installed: $TARGET/Codex Controller.app"
if [[ "${1:-}" != --no-open ]]; then
  /usr/bin/open "$TARGET/Codex Controller.app"
fi
