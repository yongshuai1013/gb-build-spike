# KitKat parts-only build probe (branch `kitkat-parts`)

Question: can the load-bearing native modules of the gate-guest route be
built from Android **4.4.4_r2** (KitKat final) on a free GitHub Actions
runner using a **partial sync** (shallow clone, minimal project set)
instead of a full tree — and what do disk and time actually cost?

This branch lives in gb-build-spike on purpose (user decision 2026-11-12:
no separate spike repo). `main` is untouched; every file of this probe is
under `kitkat/` plus `.github/workflows/kitkat-parts.yml`, and the
workflow only triggers on pushes to `kitkat-parts`.

## Target modules (the load-bearing set)

| module | home | why it is load-bearing |
|---|---|---|
| libc | bionic/libc | everything links it; gate patches live here |
| linker | bionic/linker | loads every guest binary |
| init | system/core/init | guest PID 1; first gate milestone |
| servicemanager | frameworks/native/cmds/servicemanager | binder registry; first binder parking test |
| libcutils | system/core/libcutils | property/socket plumbing under all of the above |
| libutils | frameworks/native/libs/utils | RefBase/looper base of libbinder |
| libbinder | frameworks/native/libs/binder | the binder client/server library itself |

## Partial-sync project set (each entry justified)

| project (path) | pulled in by |
|---|---|
| build | the build system itself (core/target/tools); prerequisite of everything |
| bionic | libc, linker |
| system/core | init, libcutils, plus in-project deps liblog, fs_mgr, libmincrypt, libcorkscrew |
| frameworks/native | servicemanager, libbinder, libutils |
| system/extras | init → fs_mgr → libext4_utils (ext4_utils lives in system/extras) |
| external/libselinux | init and servicemanager SELinux checks |

Correction log: round 1 assumed libselinux would pull in external/pcre
(upstream libselinux uses pcre for label matching). The 4.4.4_r2
manifest contains no external/pcre project at all (`repo sync`:
"project external/pcre not found") — the Android fork of libselinux
does not use pcre. Row removed; if a later link error names pcre
symbols, this gets revisited with that evidence.
| prebuilts/gcc/linux-x86/arm/arm-linux-androideabi-4.7 | target userspace compiler named by build/core combo config |
| prebuilts/gcc/linux-x86/arm/arm-eabi-4.7 | kernel toolchain the combo config references at parse time |

If the build system turns out to hard-require a tree-level dependency
beyond this set, that is reported as a finding (with the exact dependency
named) — the set is never quietly widened into a full sync.

## Environment

Era container **Ubuntu 12.04 + OpenJDK 6**, reusing the Gingerbread
probe's Docker recipe (`scripts/in-container.sh` of the GB line) almost
verbatim: same old-releases apt redirect, same mandatory apt groups
(toolchain + 32-bit runtime/dev libs for the prebuilt compilers).
12.04 is KitKat's own documented build platform (JDK 6 generation,
GNU make 3.81), so — unlike the GB tree — no host compiler shims are
applied on the first round; if the host build proves to need them, that
lands as a recorded fix round. Sync runs on the modern host; the
container only builds and never touches the network for source.

Version: `android-4.4.4_r2`. Product: `aosp_arm-eng`. Sync is shallow
(`repo init --depth=1`, `repo sync -c`) of the projects above only.
Round 1 runs **cold** (no actions/cache) so the sync cost is measured
honestly.

## Pre-registered verdict criteria

- **Success**: every target module above is produced, each verified as
  an ARM ELF with `file`/`readelf -h`, and disk peak + phase timings
  (sync / container setup / make) are measured numbers in the report.
- **Partial success**: per-module pass/fail table, each failure
  classified as missing-project dependency / toolchain / disk / time.
- **Discipline**: five rounds without progress on the same problem →
  stop and report (same rule as the GB full-tree probe). Disk is
  sampled every 30 s throughout; if free space drops under ~1.2 GB the
  job stops itself and reports instead of being hard-killed.

The report (per-module table, disk peak, timings, environment) is the
`kitkat-parts-report` artifact of the `kitkat-parts-build` workflow.
