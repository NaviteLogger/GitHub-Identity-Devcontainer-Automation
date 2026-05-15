#!/usr/bin/env bash
# Idempotent setup so `gh` and `git` (via gh credential helper) authenticate
# from /workspace/.env on every shell. Safe to re-run.
# Prerequisite: GITHUB_TOKEN in /workspace/.env before first run 
set -euo pipefail

ENV_FILE="/workspace/.env"
SHELL_RCS=("$HOME/.zshrc" "$HOME/.bashrc")
SNIPPET_MARKER="# >>> gh-auth-from-workspace-env >>>"

snippet() {
  cat <<'EOF'
# >>> gh-auth-from-workspace-env >>>
# Export GH_TOKEN from /workspace/.env so `gh` and git (via the gh credential
# helper) authenticate as the active token instead of falling through to stale
# stored creds. Managed by .devcontainer/setup-gh-auth.sh — do not edit by hand.
if [ -r /workspace/.env ]; then
  _GH_TOKEN_FROM_ENV=$(awk -F= '/^GITHUB_TOKEN=/ { sub(/^GITHUB_TOKEN=/, ""); print; exit }' /workspace/.env)
  if [ -n "$_GH_TOKEN_FROM_ENV" ]; then
    export GH_TOKEN="$_GH_TOKEN_FROM_ENV"
    export GITHUB_TOKEN="$_GH_TOKEN_FROM_ENV"
  fi
  unset _GH_TOKEN_FROM_ENV
fi
# <<< gh-auth-from-workspace-env <<<
EOF
}

for rc in "${SHELL_RCS[@]}"; do
  [ -f "$rc" ] || touch "$rc"
  if ! grep -qF "$SNIPPET_MARKER" "$rc"; then
    printf "\n%s\n" "$(snippet)" >> "$rc"
    echo "added GH_TOKEN export snippet to $rc"
  else
    echo "GH_TOKEN export snippet already present in $rc — skip"
  fi
done

# Wire `gh` as git credential helper for github.com + derive git user.name and
# user.email from the token holder. Idempotent — safe to re-run.
if [ -r "$ENV_FILE" ]; then
  TOKEN=$(awk -F= '/^GITHUB_TOKEN=/ { sub(/^GITHUB_TOKEN=/, ""); print; exit }' "$ENV_FILE")
  if [ -n "${TOKEN:-}" ]; then
    GH_TOKEN="$TOKEN" gh auth setup-git
    echo "gh auth setup-git done"

    # Resolve identity from the token holder.
    GH_LOGIN=$(GH_TOKEN="$TOKEN" gh api user --jq '.login' 2>/dev/null || true)
    GH_NAME=$(GH_TOKEN="$TOKEN" gh api user --jq '.name // .login' 2>/dev/null || true)
    GH_ID=$(GH_TOKEN="$TOKEN" gh api user --jq '.id' 2>/dev/null || true)

    # Prefer the primary verified email; fall back to GitHub's noreply form.
    GH_EMAIL=$(GH_TOKEN="$TOKEN" gh api user/emails \
      --jq 'map(select(.primary and .verified)) | .[0].email // empty' 2>/dev/null || true)
    if [ -z "${GH_EMAIL:-}" ] && [ -n "${GH_ID:-}" ] && [ -n "${GH_LOGIN:-}" ]; then
      GH_EMAIL="${GH_ID}+${GH_LOGIN}@users.noreply.github.com"
    fi

    if [ -n "${GH_NAME:-}" ]; then
      git config --global user.name "$GH_NAME"
      echo "git user.name  = $GH_NAME"
    fi
    if [ -n "${GH_EMAIL:-}" ]; then
      git config --global user.email "$GH_EMAIL"
      echo "git user.email = $GH_EMAIL"
    fi
  else
    echo "no GITHUB_TOKEN in $ENV_FILE — skip gh auth setup-git + identity (rerun after pasting token)"
  fi
else
  echo "$ENV_FILE missing — skip gh auth setup-git + identity (rerun after creating .env)"
fi
