# The installed disk layout (spike for N-301, 2026-11-16)

Question: what disk layout does the installer in the nisse image produce today, and how do we make our layout the default
through the installer's own product configuration?

Short answer: **today it produces LVM with ext4, not btrfs.** The installer chooses its configuration (a "profile") from the
os-release `ID`, and nisse's `ID=nisse` matches no profile. One file, `/etc/anaconda/profile.d/nisse.conf`, shipped by an
RPM, fixes that, and it is also where the subvolume layout is declared.

## Evidence

How it was checked (nothing was installed to a real disk):

- The built ISO (`out/nisse-live.iso`) was mounted in the build VM; its root is an erofs image. From it: `anaconda-core`
  44.30-2.fc44, `anaconda-live` 44.30-2.fc44, `python3-blivet` 3.13.2, `libblockdev-btrfs` 3.4.0, `btrfs-progs` 6.19.1,
  `nisse-release` 44-6. The Anaconda files and Python source below were read from that mounted image.
- `tools/spike/autopart_dryrun.py` loads Anaconda's configuration the way `/usr/sbin/anaconda` does, then runs Anaconda's own
  `AutomaticPartitioningTask` against a sparse loop-backed 60 GiB disk and prints what it plans. The plan is only scheduled
  in blivet's device tree; nothing is written. Same `anaconda-core` version as the image (44.30-2), installed in the build VM.
  Four things the real installer gets from D-Bus services are replaced by fixed values: disk-initialization settings
  (clear all), the bootloader steps, the hostname and the disk selection. The target is UEFI (what the VM and real hardware
  use).

What the files and code say:

1. `/etc/anaconda/anaconda.conf` in the image: `default_scheme = LVM`, `btrfs_compression =` (empty),
   `file_system_type =` (blivet's default), `default_partitioning` is `/ (min 1 GiB, max 70 GiB)` and
   `/home (min 500 MiB, free 50 GiB)`. btrfs is not the installer's own default; it comes from the Fedora profiles.
2. `/etc/anaconda/profile.d/fedora.conf` sets `[Storage] default_scheme = BTRFS` and `btrfs_compression = zstd:1`.
   `fedora-kde.conf` inherits it (`base_profile = fedora`). Both are detected with `os_id = fedora` (and `variant_id = kde`).
3. `/usr/sbin/anaconda` (line 182) calls `conf.set_from_detected_profile(get_os_release_value("ID"), get_os_release_value("VARIANT_ID"))`.
   `ProfileLoader.detect_profile` matches on exactly the pair (ID, VARIANT_ID), then on (ID, ""). **`ID_LIKE` is not consulted**
   (the only `ID_LIKE` reader is the kickstart version check). nisse's os-release has `ID=nisse`, `ID_LIKE="fedora"` and no
   `VARIANT_ID`, so nothing matches. Anaconda logs: "Unable to find any suitable configuration files for the detected
   os-release values. No profile configuration will be used."
4. The profile can also be forced with `inst.profile=ID` on the kernel command line (`argument_parsing.py`, `--profile`).

What the planner produces (`autopart_dryrun.py`, UEFI, 60 GiB disk):

    --id nisse        (what the image does today: no profile)
        default_scheme 2 (LVM), no compression
        partition 1  efi   /boot/efi  600 MiB
        partition 2  ext4  /boot      2 GiB
        partition 3  lvmpv            57.41 GiB  -> VG "anaconda": LV root ext4 (38.58 GiB), LV home ext4 (18.83 GiB)

    --profile fedora-kde   (a shipped Fedora profile forced on)
        default_scheme 1 (BTRFS), zstd:1
        partition 1  efi   /boot/efi  600 MiB
        partition 2  ext4  /boot      2 GiB
        partition 3  btrfs            57.41 GiB  -> volume "anaconda": subvolume root (/), subvolume home (/home)

    --id nisse with the candidate /etc/anaconda/profile.d/nisse.conf (packaging/rpm/nisse-installer/nisse.conf)
        default_scheme 1 (BTRFS), zstd:1
        partition 1  efi   /boot/efi  600 MiB
        partition 2  ext4  /boot      2 GiB
        partition 3  btrfs            57.41 GiB  -> volume "anaconda" with subvolumes
            root       /                      opts=subvol=root
            home       /home                  opts=subvol=home
            var_log    /var/log               opts=subvol=var_log
            var_cache  /var/cache             opts=subvol=var_cache
        (the first run also had a placeholder /var/lib/nisse-models subvolume; N-302 dropped it and the run was repeated: exactly
        the four above)

A note on the dry run: the build VM is itself btrfs (its own subvolumes are root, home, var, boot), and blivet counts those
names as taken, so the script forgets them; without that the names came out as `root00` and `home00`. A real target disk
has none of them. Final names are confirmed on an installed disk in N-304.

## Mechanism

`/etc/anaconda/profile.d/nisse.conf`, one small file, shipped in an RPM (a new `nisse-installer` package, or inside
`nisse-release`; N-304 chose a new `nisse-installer` package). The candidate (`packaging/rpm/nisse-installer/nisse.conf`, verified above):

    [Profile]
    profile_id = nisse
    base_profile = fedora
    [Profile Detection]
    os_id = nisse
    [Storage]
    default_scheme = BTRFS
    btrfs_compression = zstd:1
    default_partitioning =
        /                (min 1 GiB, max 70 GiB)
        /home            (min 500 MiB, free 50 GiB)
        /var/log         (btrfs)
        /var/cache       (btrfs)

What each part does, from the code (`modules/storage/partitioning/automatic/utils.py`):

- `os_id = nisse` makes the installer pick our profile. `base_profile = fedora` inherits Fedora's settings first (btrfs, zstd:1,
  the Fedora bootloader directory and so on), then ours override.
- `default_scheme = BTRFS` is the scheme `autopart` uses. This also covers the kickstart `autopart` command without
  `--type` (the answer-file route N-303 will use): `PartitioningRequest` starts from `conf.storage.default_scheme`, and
  `autopart --type` only overrides it when given.
- Under BTRFS every `default_partitioning` mount point becomes its own subvolume of the one btrfs volume, named from the mount
  point (`/` is `root`, other `/` become `_`: `/var/log` is `var_log`). The `(btrfs)` attribute makes an entry exist only in the
  BTRFS scheme. Sizes and `free` are ignored on btrfs (the code says "required space isn't relevant on btrfs"); all subvolumes
  share the one volume.
- Other ways that also work but are worse: `/etc/anaconda/conf.d/*.conf` (its README says it is for overrides, debugging and
  one-time uses) and `inst.profile=nisse` (needs a kernel argument in every boot entry). The profile is the documented path.

## Proposed layout (for N-302 to approve)

    partition  /boot/efi  600 MiB  vfat   (platform default; not ours to change)
    partition  /boot      2 GiB    ext4   (platform default, see risk 1)
    btrfs volume, zstd:1:
        root       /                 snapshotted by snapper (the system)
        home       /home             excluded: user data and projects
        var_log    /var/log          excluded: logs must survive a rollback (the audit trail and the journal)
        var_cache  /var/cache        excluded: rebuildable, large, churns

Subvolumes are siblings at the top of the volume, not nested in `root`, so a snapshot of `root` does not contain them (a btrfs
snapshot does not recurse into other subvolumes). That is what "snapshots cover the system only" in the design needs.
`snapper create-config /` makes its own nested `.snapshots` subvolume after install; it is not an installer matter.

The model store: the design says model stores live in an excluded subvolume, but no backend in the image defines a store path
yet (nothing in the repo names one). `/var/lib/nisse-models` above is a placeholder that proves the mechanism handles any
path; N-302 should either pick the real path or leave the model store inside `/home` until one exists.

## Decision (N-302, Bert, 2026-11-16)

Recorded through three questions, each answered as the first recommended option except the third.

1. **Subvolumes:** `root` (snapshotted), `home`, `var_log`, `var_cache` (all three excluded from snapshots, so they survive a
   rollback). No model-store subvolume yet: the model store lives in `home` until a backend defines a path, then a new
   decision adds one. The `default_partitioning` of the shipped profile is exactly: `/`, `/home`, `/var/log (btrfs)`,
   `/var/cache (btrfs)`.
2. **Frequency: events only.** Snapshots are taken before and after each AI action batch (N-306) and each package update or
   safe-apply (N-305, N-308), and no timed (hourly or daily) snapshots. Snapper's timeline is switched off.
3. **Retention: 20 pairs, 14 days, 5 GiB cap.** Keep at most 20 pre/post pairs, delete anything older than 14 days, and clean
   up early when snapshots use more than 5 GiB. To verify in N-305, not assumed here: snapper's own space limit is a
   fraction of the filesystem (`SPACE_LIMIT`) and needs btrfs quotas, so how a fixed 5 GiB is expressed (or whether a
   fraction of a typical disk stands in for it) is that task's spike. The open risks above stay open.

## Open risks (carried to N-302 and N-304, nothing here is solved)

1. **`/boot` is a separate ext4 partition and is not in any snapshot.** Anaconda's platform always adds it (`platform.py`
   `_boot_partition`, 2 GiB). A snapper rollback of `root` restores the old `/usr/lib/modules` but leaves the newer kernel
   and initramfs in `/boot`; the safe-apply rollback in the design must be tested against exactly that case (N-307 boot into a snapshot, N-308 and N-310
   safe-apply and watchdog rollback), and it may need `/boot` handled at install time (for example kernel files kept in `root`, or a post-rollback
   boot-entry fix). Not verified either way; this is a spike finding, not a conclusion.
2. **`snapper` is not in the image** (`rpm -q snapper` is empty in the ISO root). It is in the Fedora 44 repository
   (`snapper-0.13.0-3.fc44`, also `btrfs-assistant`). Adding it is N-305.
3. **Bootloader directory.** `base_profile = fedora` keeps `efi_dir = fedora`. Fedora's signed shim and grub are installed under
   `EFI/fedora` by their packages, so keep it unless a later task proves otherwise (Secure Boot depends on it).
4. **Base profile choice.** `fedora` gives btrfs and zstd only. `fedora-kde` would also set the KDE environment and hide the
   user, password and date-time spokes. Which of those nisse wants is an N-304 detail.
5. **The dry run is not an install.** Real subvolume names, mount options (`subvol=root`, `compress=zstd:1`), fstab and
   a bootable result are what N-303 (unattended install harness) and N-304 (implement) prove on an installed disk. The VM
   has `python3-blivet` 3.14.2 while the image has 3.13.2 (same Anaconda 44.30-2); a version difference in naming or planning
   would be caught there.
6. **Everything shares one volume**, with no quota per subvolume. A runaway model download in an excluded subvolume can fill
   the disk that snapshots live on. A quota or a free-space guard is a rollback-block design question, not an installer one.

## Reproduce

    bash tools/build/vm.sh sync
    bash tools/build/vm.sh ssh 'sudo dnf install -y --setopt=install_weak_deps=False anaconda-core libblockdev-btrfs libblockdev-lvm libblockdev-dm'
    bash tools/build/vm.sh ssh 'cd ~/nisse && sudo python3 tools/spike/autopart_dryrun.py --id nisse'
    bash tools/build/vm.sh ssh 'cd ~/nisse && sudo cp packaging/rpm/nisse-installer/nisse.conf /etc/anaconda/profile.d/nisse.conf &&
        sudo python3 tools/spike/autopart_dryrun.py --id nisse; sudo rm /etc/anaconda/profile.d/nisse.conf'
