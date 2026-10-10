# rkhunter-apt-verify

An apt hook for Debian and Ubuntu that stops [rkhunter] warning about
files changed by package upgrades, without trusting changes it can't
account for.

## The problem

rkhunter records properties of system binaries (hash, size, inode,
modification time) and warns when they change. Every package upgrade
changes them, so after each security update the daily report says
something like:

```
Warning: The file properties have changed:
         File: /usr/bin/perl
         Current inode: 37084    Stored inode: 35321
```

Debian's rkhunter package offers `APT_AUTOGEN="yes"` in
`/etc/default/rkhunter`, which runs a full `rkhunter --propupd` after every
dpkg run. That accepts everything on disk into the baseline, including any
tampering that happened since the last check. Debian's own README.Debian
warns about this.

Setting `PKGMGR=DPKG` in `rkhunter.conf` doesn't help either. dpkg only
supplies the file hash, so rkhunter still compares inode, size and
modification time against its own database and still warns.

## What this does

Around each dpkg run, apt calls `rkhunter-apt-verify`:

1. **Before dpkg** it runs rkhunter's file-properties check. If anything
   warns, it remembers that and later does nothing.
2. **After dpkg** it finds the packages dpkg installed during the run (from
   `/var/log/dpkg.log`) and runs `dpkg --verify` on each. Conffiles are
   ignored, since local edits to them are normal.
3. For packages that verify cleanly, it runs `rkhunter --propupd` on just
   the files rkhunter tracks from those packages.

Anything it refuses is logged to syslog with the tag `rkhunter-apt-verify`
and left for rkhunter's normal daily report. A failure never blocks apt.

The idea of gating the update on a check before the transaction comes from
[yum-plugin-rkhunter], which does the same for yum and dnf.

## Install

```sh
sudo install -m 755 rkhunter-apt-verify /usr/local/sbin/
sudo install -m 644 95rkhunter-apt-verify /etc/apt/apt.conf.d/
```

Leave `APT_AUTOGEN` unset or `false`, otherwise Debian's hook will update
the whole baseline anyway.

Check it ran after the next upgrade:

```sh
journalctl -t rkhunter-apt-verify
```

To uninstall, delete the two files.

## Limits

- Each apt run gets one extra rkhunter properties check. On a small VPS
  this took 23 seconds.
- `dpkg --verify` checks against the MD5 sums in `/var/lib/dpkg/info`.
  An attacker with root could rewrite those too. The check before dpkg
  runs makes this harder, since tampering has to happen during the dpkg
  run itself.
- New files that rkhunter starts tracking, and files of removed packages,
  aren't handled. They still show in the daily report.

## Tests

`tests/run` uses podman or docker to run three scenarios in a Debian 12
container, by downgrading and upgrading perl:

1. A clean upgrade is accepted, and only `/usr/bin/perl` changes in the
   baseline.
2. A file tampered with before the upgrade blocks any update.
3. A file that fails `dpkg --verify` after the upgrade is not accepted.

## License

GPL-3.0. See [LICENSE](LICENSE).

[rkhunter]: https://rkhunter.sourceforge.net/
[yum-plugin-rkhunter]: https://github.com/sjinks/yum-plugin-rkhunter
