#!/bin/bash
#
# Builds, packages and publishes the version set in scripts/build-app.sh.
#
#   scripts/release.sh             build, sign the update archive and create the GitHub release
#   scripts/release.sh --dry-run   build and sign into build/release without publishing
#
# Uploads a dmg for manual installs and a zip with its Ed25519 signature for the app's
# in-place updates (UpdateInstaller). The signing key lives outside the repository, at
# $AGENTBELL_UPDATE_KEY or ~/.agentbell/updater.key; see scripts/update-key.swift.

set -euo pipefail

DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

fail() { echo "error: $*" >&2; exit 1; }

VERSION="$(sed -n 's/^VERSION="\(.*\)"$/\1/p' scripts/build-app.sh)"
[ -n "$VERSION" ] || fail "no VERSION in scripts/build-app.sh"
TAG="v$VERSION"
KEY="${AGENTBELL_UPDATE_KEY:-$HOME/.agentbell/updater.key}"
OUT="$ROOT/build/release"
NAME="AgentBell-$VERSION-macOS-AppleSilicon"

[ -f "$KEY" ] || fail "update signing key not found at $KEY"
EMBEDDED="$(sed -n 's/.*publicKey = "\(.*\)"$/\1/p' Sources/BellCore/Updates/UpdateSignature.swift)"
[ "$(swift scripts/update-key.swift public "$KEY")" = "$EMBEDDED" ] \
  || fail "$KEY does not match UpdateSignature.publicKey; installed apps would reject this release"
grep -q "^## $VERSION " CHANGELOG.md || fail "CHANGELOG.md has no section for $VERSION"

if [ "$DRY_RUN" = 0 ]; then
  [ -z "$(git status --porcelain)" ] || fail "working tree is not clean"
  git fetch --quiet origin
  git merge-base --is-ancestor HEAD origin/main || fail "HEAD is not on origin/main; push first"
  ! gh release view "$TAG" >/dev/null 2>&1 || fail "release $TAG already exists"
fi

scripts/build-app.sh --no-launch
APP="$ROOT/build/AgentBell.app"
# An ad-hoc signature differs on every build, so users would have to grant terminal
# control and accessibility again after each update.
SIGNATURE_INFO="$(codesign -dv "$APP" 2>&1)"
[[ "$SIGNATURE_INFO" != *"Signature=adhoc"* ]] || fail "app is signed ad hoc; install a signing certificate"

echo "==> packaging into $OUT"
rm -rf "$OUT"
mkdir -p "$OUT/dmg"
ditto "$APP" "$OUT/dmg/AgentBell.app"
ln -s /Applications "$OUT/dmg/Applications"
hdiutil create -quiet -volname AgentBell -srcfolder "$OUT/dmg" -format UDZO "$OUT/$NAME.dmg"
rm -rf "$OUT/dmg"
ditto -c -k --keepParent "$APP" "$OUT/$NAME.zip"
swift scripts/update-key.swift sign "$KEY" "$OUT/$NAME.zip" > "$OUT/$NAME.zip.sig"

{
  awk -v heading="## $VERSION " '
    index($0, heading) == 1 { found = 1; next }
    found && /^## / { exit }
    found { print }
  ' CHANGELOG.md | sed '/./,$!d'
  cat <<NOTES

## 下载

| 文件 | 适用于 |
| --- | --- |
| \`$NAME.dmg\` | Apple 芯片（M1 及更新）的 Mac，macOS 14 或更新 |

暂不支持 Intel 芯片的 Mac。\`$NAME.zip\` 和 \`.sig\` 供应用内更新使用，不用手动下载。

## 安装

- 已装 1.2.1 或更新的版本：在「设置 › 关于」里点「下载并安装」，再点「重启完成更新」。
- 第一次安装或从更早的版本升级：双击打开 dmg，把 AgentBell 拖进「应用程序」文件夹，替换旧版本。这个版本没有经过 Apple 公证，第一次打开如果被拦，到「系统设置 › 隐私与安全性」里点「仍要打开」。
NOTES
} > "$OUT/notes.md"

ls -l "$OUT"

if [ "$DRY_RUN" = 1 ]; then
  echo "==> dry run: not publishing $TAG"
  exit 0
fi

echo "==> publishing $TAG"
gh release create "$TAG" --target "$(git rev-parse HEAD)" --title "AgentBell $VERSION" --notes-file "$OUT/notes.md" \
  "$OUT/$NAME.dmg" "$OUT/$NAME.zip" "$OUT/$NAME.zip.sig"
echo "==> done"
