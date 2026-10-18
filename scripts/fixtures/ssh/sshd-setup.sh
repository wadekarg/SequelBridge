#!/bin/sh
# sshd-setup.sh — the SSH server for the SSH tunnel tests, run inside an Alpine
# container by scripts/run-all-tests.sh. Two sshd instances share one user:
#   2222  today's defaults;
#   2223  an old server: one RSA host key offered only as ssh-rsa (SHA-1 signatures),
#         and only ssh-rsa accepted for user keys, as OpenSSH 7.1 and older behave.
#         Current macOS ssh refuses that server unless ssh-rsa is allowed again.
# The test key's public half arrives in $TEST_PUBKEY; logins are key-only. Host keys
# come from /hostkeys when mounted, so they stay the same across re-provisioning and
# the client's known_hosts entry stays valid (the tunnel trusts hosts the way ssh does).
set -e
apk add --no-cache openssh-server >/dev/null
if [ -d /hostkeys ]; then
  cp /hostkeys/ssh_host_* /etc/ssh/ && chmod 600 /etc/ssh/ssh_host_*_key
else
  ssh-keygen -A >/dev/null
fi
adduser -D -s /bin/sh tunneluser
echo 'tunneluser:*' | chpasswd -e            # unlocked for key logins, no password exists
install -d -m 700 -o tunneluser -g tunneluser /home/tunneluser/.ssh
printf '%s\n' "$TEST_PUBKEY" > /home/tunneluser/.ssh/authorized_keys
chown tunneluser:tunneluser /home/tunneluser/.ssh/authorized_keys
chmod 600 /home/tunneluser/.ssh/authorized_keys

common='PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
AllowTcpForwarding yes
PidFile none'
printf '%s\nPort 2222\nHostKey /etc/ssh/ssh_host_ed25519_key\nHostKey /etc/ssh/ssh_host_rsa_key\n' \
  "$common" > /etc/ssh/sshd_modern
printf '%s\nPort 2223\nHostKey /etc/ssh/ssh_host_rsa_key\nHostKeyAlgorithms ssh-rsa\nPubkeyAcceptedAlgorithms ssh-rsa\n' \
  "$common" > /etc/ssh/sshd_legacy
/usr/sbin/sshd -t -f /etc/ssh/sshd_modern && /usr/sbin/sshd -t -f /etc/ssh/sshd_legacy
/usr/sbin/sshd -f /etc/ssh/sshd_legacy
exec /usr/sbin/sshd -D -e -f /etc/ssh/sshd_modern
