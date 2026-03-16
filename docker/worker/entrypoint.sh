#!/bin/sh
set -eu

# Trust all directories — bind-mounted repos are owned by the host user, not root
git config --global --add safe.directory '*'
su -s /bin/sh symphony -c "git config --global --add safe.directory '*'"

# Git credential helper — reads GH token from the bind-mounted secrets file
CREDENTIAL_HELPER='!f() { test "$1" = get || exit 0; printf "username=x-access-token\n"; printf "password="; cat /run/symphony/secrets/gh-token; printf "\n"; }; f'
git config --global credential.helper "$CREDENTIAL_HELPER"
git config --global credential.useHttpPath true
su -s /bin/sh symphony -c "
  git config --global credential.helper '$CREDENTIAL_HELPER'
  git config --global credential.useHttpPath true
"

# Authorized key can be injected via env var or bind-mounted file
if [ -n "${SYMPHONY_SSH_AUTHORIZED_KEY:-}" ]; then
  printf '%s\n' "$SYMPHONY_SSH_AUTHORIZED_KEY" > /home/symphony/.ssh/authorized_keys
  chmod 600 /home/symphony/.ssh/authorized_keys
  chown symphony:symphony /home/symphony/.ssh/authorized_keys
elif [ -s /run/symphony/ssh/authorized_key.pub ]; then
  install -m 600 -o symphony -g symphony /run/symphony/ssh/authorized_key.pub /home/symphony/.ssh/authorized_keys
else
  echo "No authorized key provided (SYMPHONY_SSH_AUTHORIZED_KEY env var or /run/symphony/ssh/authorized_key.pub)" >&2
  exit 1
fi

exec /usr/sbin/sshd -D -e
