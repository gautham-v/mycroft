#!/bin/zsh
# Install the post-commit hook that rebuilds and reinstalls the Mac app (scripts/install-mac.sh).
ROOT=${0:A:h:h}
HOOK=$(git -C $ROOT rev-parse --git-common-dir)/hooks/post-commit
cat > $HOOK <<'HOOK'
#!/bin/zsh
# Rebuild and reinstall /Applications/OpenDispatch.app after commits on main that touch the app.
[[ $(git rev-parse --abbrev-ref HEAD) == main ]] || exit 0
git diff-tree --no-commit-id --name-only -r HEAD | grep -qE '^(App|Core)/' || exit 0
nohup "$(git rev-parse --show-toplevel)/scripts/install-mac.sh" >/dev/null 2>&1 &
HOOK
chmod +x $HOOK
echo "installed $HOOK"
