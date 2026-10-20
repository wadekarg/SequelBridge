#!/bin/sh
# sshd-setup.sh — the SSH server for the SSH tunnel tests, run inside an Alpine
# container by scripts/run-all-tests.sh. Two sshd instances share one user:
#   2222  today's defaults;
#   2223  an old server: one RSA host key offered only as ssh-rsa (SHA-1 signatures),
#         and only ssh-rsa accepted for user keys, as OpenSSH 7.1 and older behave.
#         Current macOS ssh refuses that server unless ssh-rsa is allowed again.
# The test keys' public halves arrive in $TEST_PUBKEY (one has a passphrase, for the
# login prompts); tunneluser logs in with a key only. pwuser logs in with a password,
# on the 2222 server only, for the app's SSH login prompts. otpuser logs in with a
# one-time code alone, on the 2223 server only (the PAM build of sshd, the only one that
# reads /etc/pam.d/sshd), from google-authenticator's PAM module: TOTP on the fixed test
# secret JBSWY3DPEHPK3PXP, as an authenticator app shows it. Host keys
# come from /hostkeys when mounted, so they stay the same across re-provisioning and
# the client's known_hosts entry stays valid (the tunnel trusts hosts the way ssh does).
set -e
apk add --no-cache openssh-server openssh-server-pam google-authenticator >/dev/null
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
adduser -D -s /bin/sh pwuser
echo 'pwuser:sbssh123' | chpasswd               # the password-login account
install -d -m 700 -o pwuser -g pwuser /home/pwuser/.ssh   # and the passphrase key, to skip
printf '%s\n' "$TEST_PHRASE_PUBKEY" > /home/pwuser/.ssh/authorized_keys
chown pwuser:pwuser /home/pwuser/.ssh/authorized_keys && chmod 600 /home/pwuser/.ssh/authorized_keys
adduser -D -s /bin/sh otpuser
echo 'otpuser:*' | chpasswd -e                 # no password: the code is the only way in
printf 'JBSWY3DPEHPK3PXP\n" TOTP_AUTH\n' > /home/otpuser/.google_authenticator
chown otpuser:otpuser /home/otpuser/.google_authenticator && chmod 400 /home/otpuser/.google_authenticator
printf 'auth required pam_google_authenticator.so\naccount required pam_permit.so\nsession required pam_permit.so\npassword required pam_deny.so\n' \
  > /etc/pam.d/sshd

common='PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
AllowTcpForwarding yes
PidFile none'
printf '%s\nPort 2222\nHostKey /etc/ssh/ssh_host_ed25519_key\nHostKey /etc/ssh/ssh_host_rsa_key\nMatch User pwuser\n  PasswordAuthentication yes\n' \
  "$common" > /etc/ssh/sshd_modern
printf '%s\nPort 2223\nHostKey /etc/ssh/ssh_host_rsa_key\nHostKeyAlgorithms ssh-rsa\nPubkeyAcceptedAlgorithms ssh-rsa\nUsePAM yes\nMatch User otpuser\n  KbdInteractiveAuthentication yes\n  AuthenticationMethods keyboard-interactive\n' \
  "$common" > /etc/ssh/sshd_legacy
/usr/sbin/sshd -t -f /etc/ssh/sshd_modern && /usr/sbin/sshd.pam -t -f /etc/ssh/sshd_legacy
/usr/sbin/sshd.pam -f /etc/ssh/sshd_legacy
exec /usr/sbin/sshd -D -e -f /etc/ssh/sshd_modern
