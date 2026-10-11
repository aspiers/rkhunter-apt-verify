#!/bin/sh
# Exercise rkhunter-apt-verify inside a throwaway Debian 12 container.
# Set PKGMGR to also test rkhunter's package-manager mode, e.g. PKGMGR=DPKG.
set -u
export DEBIAN_FRONTEND=noninteractive
DAT=/var/lib/rkhunter/db/rkhunter.dat
STATE_DIR=/run/rkhunter-apt-verify
failures=0

apt_q() { apt-get -qq -o Dpkg::Use-Pty=0 "$@" 2>&1 | grep rkhunter-apt-verify; }
stack() { echo "perl=$1 perl-base=$1 perl-modules-5.36=$1 libperl5.36=$1"; }

# Files rkhunter currently warns about, space-separated.
warnings() {
    l=$(mktemp)
    rkhunter --check --sk --nocolors --rwo --enable properties --logfile "$l" >/dev/null 2>&1
    sed -n 's/^\[[0-9:]*\]  *\(\/[^ ]*\)  *\[ Warning \]$/\1/p' "$l" | sort -u | paste -sd' '
    rm -f "$l"
}

expect() {
    got=$(warnings)
    if [ "$got" = "$2" ]; then
        echo "PASS: $1"
    else
        echo "FAIL: $1: expected warnings [$2], got [$got]"
        failures=$((failures + 1))
    fi
}

# Simulate a dpkg run that installed $1, then let the hook's post step
# judge whatever else the caller changed in the meantime.
fake_dpkg_run() {
    mkdir -p "$STATE_DIR"
    echo "clean $(stat -c %s /var/log/dpkg.log)" >"$STATE_DIR/state"
    echo "$(date '+%F %T') status installed $1:$(dpkg --print-architecture) x" >>/var/log/dpkg.log
}

reset_baseline() { rkhunter --propupd --nolog >/dev/null; }

echo "== setup (PKGMGR=${PKGMGR:-unset})"
apt-get -qq update >/dev/null
apt-get -qq install --no-install-recommends rkhunter >/dev/null 2>&1
[ -n "${PKGMGR:-}" ] && echo "PKGMGR=$PKGMGR" >>/etc/rkhunter.conf.local
install -m 755 /hook/rkhunter-apt-verify /usr/local/sbin/
install -m 644 /hook/95rkhunter-apt-verify /etc/apt/apt.conf.d/
OLD=$(apt-cache madison perl-base | awk -F'|' '/bookworm\/main/ {gsub(/ /,"",$2); print $2; exit}')
NEW=$(apt-cache madison perl-base | awk -F'|' '/security/ {gsub(/ /,"",$2); print $2; exit}')
echo "perl-base old=$OLD new=$NEW"
# shellcheck disable=SC2046
apt_q install --allow-downgrades $(stack "$OLD")
reset_baseline
expect "baseline is clean" ""

echo "== clean upgrade is accepted"
cp "$DAT" /root/dat.before
# shellcheck disable=SC2046
apt_q install $(stack "$NEW")
expect "no warnings after upgrade" ""
changed=$(diff /root/dat.before "$DAT" | sed -n 's/^> File:[0-9]*:\([^:]*\):.*/\1/p' | paste -sd' ')
if [ "$changed" = /usr/bin/perl ]; then
    echo "PASS: only /usr/bin/perl changed in the baseline"
else
    echo "FAIL: baseline entries changed: [$changed]"
    failures=$((failures + 1))
fi

echo "== tampering before the upgrade blocks the update"
# shellcheck disable=SC2046
apt_q install --allow-downgrades $(stack "$OLD")
reset_baseline
cp -p /usr/bin/whoami /root/whoami.orig
printf 'x' >>/usr/bin/whoami
# shellcheck disable=SC2046
apt_q install $(stack "$NEW")
expect "upgrade and tampering both still reported" "/usr/bin/perl /usr/bin/whoami"
cp -p /root/whoami.orig /usr/bin/whoami
reset_baseline

echo "== alternatives symlink switched by a new package"
apt_q install --no-install-recommends gawk
expect "awk now pointing at gawk is accepted" ""

echo "== newly installed package adds watched files"
apt_q install --no-install-recommends wget
expect "new /usr/bin/wget is accepted" ""

echo "== package file failing dpkg --verify"
reset_baseline
fake_dpkg_run perl-base
cp -p /usr/bin/perl /root/perl.orig
printf 'x' >>/usr/bin/perl
/usr/local/sbin/rkhunter-apt-verify post
expect "modified perl still reported" "/usr/bin/perl"
cp -p /root/perl.orig /usr/bin/perl

echo "== file dropped during a dpkg run"
reset_baseline
fake_dpkg_run perl-base
printf '#!/bin/sh\n' >/usr/local/bin/curl
chmod 755 /usr/local/bin/curl
/usr/local/sbin/rkhunter-apt-verify post
expect "unpackaged new file still reported" "/usr/local/bin/curl"

echo "== $failures failure(s)"
[ "$failures" -eq 0 ]
