#!/bin/sh
# Exercise rkhunter-apt-verify inside a throwaway Debian 12 container.
set -u
export DEBIAN_FRONTEND=noninteractive
apt_q() { apt-get -qq -o Dpkg::Use-Pty=0 "$@" >/dev/null; }
warnings() {
    l=$(mktemp)
    rkhunter --check --sk --nocolors --rwo --enable properties --logfile "$l" >/dev/null 2>&1
    echo "check exit $? / warning files: $(grep -A1 'Warning: The file properties have changed' "$l" | sed -n 's/.*File: //p' | paste -sd' ')"
}
stack() { echo "perl=$1 perl-base=$1 perl-modules-5.36=$1 libperl5.36=$1"; }

echo "== setup"
apt_q update
apt_q install --no-install-recommends rkhunter
install -m 755 /hook/rkhunter-apt-verify /usr/local/sbin/
install -m 644 /hook/95rkhunter-apt-verify /etc/apt/apt.conf.d/
OLD=$(apt-cache madison perl-base | awk -F'|' '/bookworm\/main/ {gsub(/ /,"",$2); print $2; exit}')
NEW=$(apt-cache madison perl-base | awk -F'|' '/security/ {gsub(/ /,"",$2); print $2; exit}')
echo "old=$OLD new=$NEW installed=$(dpkg-query -W -f '${Version}' perl-base)"
# shellcheck disable=SC2046
apt_q install --allow-downgrades $(stack "$OLD")
rkhunter --propupd --nolog >/dev/null
echo "baseline: $(warnings)"

echo "== A: clean upgrade is accepted"
cp /var/lib/rkhunter/db/rkhunter.dat /root/dat.before
# shellcheck disable=SC2046
apt-get -qq -o Dpkg::Use-Pty=0 install $(stack "$NEW") 2>&1 | grep rkhunter-apt-verify
echo "after upgrade: $(warnings)"
echo "dat lines changed: $(diff /root/dat.before /var/lib/rkhunter/db/rkhunter.dat | grep '^>' | cut -d: -f3 | paste -sd' ')"

echo "== B: earlier tampering blocks the update"
# shellcheck disable=SC2046
apt_q install --allow-downgrades $(stack "$OLD")
rkhunter --propupd --nolog >/dev/null
cp -p /usr/bin/whoami /root/whoami.orig
printf 'x' >>/usr/bin/whoami
# shellcheck disable=SC2046
apt-get -qq -o Dpkg::Use-Pty=0 install $(stack "$NEW") 2>&1 | grep rkhunter-apt-verify
echo "after upgrade: $(warnings)"
cp -p /root/whoami.orig /usr/bin/whoami

echo "== C: a file that fails dpkg --verify is not accepted"
rkhunter --propupd --nolog >/dev/null
mkdir -p /run/rkhunter-apt-verify
echo "clean $(stat -c %s /var/log/dpkg.log)" >/run/rkhunter-apt-verify/state
echo "$(date '+%F %T') status installed perl-base:$(dpkg --print-architecture) $NEW" >>/var/log/dpkg.log
printf 'x' >>/usr/bin/perl
/usr/local/sbin/rkhunter-apt-verify post
echo "after post: $(warnings)"
