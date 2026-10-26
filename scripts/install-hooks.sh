#!/bin/zsh
# Install the hooks that rebuild and reinstall the Mac app (scripts/install-mac.sh): post-commit for
# commits on main, post-merge for merges and pulls into main (including fast-forwards).
ROOT=${0:A:h:h}
HOOKS=$(git -C $ROOT rev-parse --git-common-dir)/hooks
write_hook() {
  cat > $HOOKS/$1 <<HOOK
#!/bin/zsh
# Rebuild and reinstall /Applications/OpenDispatch.app when main gets changes under App/ or Core/.
[[ \$(git rev-parse --abbrev-ref HEAD) == main ]] || exit 0
git diff --name-only $2 HEAD | grep -qE '^(App|Core)/' || exit 0
nohup "\$(git rev-parse --show-toplevel)/scripts/install-mac.sh" >/dev/null 2>&1 &
HOOK
  chmod +x $HOOKS/$1
  echo "installed $HOOKS/$1"
}
write_hook post-commit 'HEAD~1'
write_hook post-merge ORIG_HEAD
