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
3. It runs the properties check again. Since the system was clean before,
   every warning now is a change made during this dpkg run.
4. If every warned file belongs to a package from step 2 that verified
   cleanly, it runs `rkhunter --propupd`. Otherwise it changes nothing.

Files are matched after resolving symlinks, so an alternatives switch such
as `/usr/bin/awk` now pointing at gawk counts as gawk's file. Files from
newly installed packages are recorded too.

The update is a full `--propupd` on purpose. rkhunter's per-file form,
`--propupd FILE`, also adds every new watched file that isn't in its
database yet, without any check, so a file dropped elsewhere during the
run would slip in.

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

- Each apt run gets one rkhunter properties check, plus a second one when
  packages were installed. On a small VPS each took about 23 seconds.
- `dpkg --verify` checks against the MD5 sums in `/var/lib/dpkg/info`.
  An attacker with root could rewrite those too. The check before dpkg
  runs makes this harder, since tampering has to happen during the dpkg
  run itself.
- A file changed between the second check and the `--propupd` would be
  accepted. That window is a few seconds.
- Files of removed packages aren't handled, so they still show in the
  daily report.

## Tests

`tests/run` uses podman or docker to run these scenarios in Debian 12
containers, once with rkhunter's default config and once with
`PKGMGR=DPKG`. It exits non-zero if any fail.

1. A clean perl upgrade is accepted, and only `/usr/bin/perl` changes in
   the baseline.
2. A file tampered with before the upgrade blocks any update.
3. Installing gawk, which switches the `/usr/bin/awk` alternative, is
   accepted.
4. Installing wget, which adds a watched file, is accepted.
5. A package file that fails `dpkg --verify` is not accepted.
6. A file dropped outside any package during a dpkg run is not accepted.

## License

GPL-3.0. See [LICENSE](LICENSE).

[rkhunter]: https://rkhunter.sourceforge.net/
[yum-plugin-rkhunter]: https://github.com/sjinks/yum-plugin-rkhunter
