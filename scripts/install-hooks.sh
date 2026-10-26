#!/bin/zsh
# Install the hooks that rebuild and reinstall the Mac app (scripts/install-mac.sh): post-commit for
# commits on main, post-merge for merges and pulls into main (including fast-forwards). Also a
# commit-msg hook that keeps AI attribution out of commits.
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

# commit-msg: no AI attribution in this repo. Drops Co-Authored-By trailers for Claude or Anthropic and
# refuses a commit authored as Claude.
cat > $HOOKS/commit-msg <<'HOOK'
#!/bin/zsh
if git var GIT_AUTHOR_IDENT | grep -qiE 'anthropic\.com|^claude '; then
  echo "commit-msg: the author is Claude; commit as the repo's own git user" >&2
  exit 1
fi
sed -i '' -E '/^[Cc]o-[Aa]uthored-[Bb]y:.*([Cc]laude|[Aa]nthropic)/d' "$1"
HOOK
chmod +x $HOOKS/commit-msg
echo "installed $HOOKS/commit-msg"
