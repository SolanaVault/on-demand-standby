# on-demand-standby

**Zero-downtime maintenance for a single Firedancer validator, with a standby you rent by the hour.**

Commands: `fd-standby`, `fd-standby-swap`. A community tool, not affiliated with Jump Crypto, the Firedancer project, Jito or any server provider.

You run one Firedancer validator. Before you take it down — an upgrade, a reboot, a disk swap,
anything — you run **`fd-standby failover`**:

1. it rents a bare-metal server by the hour (only server types that are **in stock right now** and **proven to work**),
2. sets it up automatically as a Firedancer node with a throwaway identity, using **your exact binary and config**,
3. waits until it has caught up with the cluster and rehearses an identity switch on it with throwaway keys,
4. moves your **staked identity** (with its fresh vote history) to it — the voting gap is ~4 s.

Now the standby votes and you do whatever you need on your primary. **What happens in between is
up to you; fd-standby does not touch your primary.** The only requirement: when you are done, the
primary's Firedancer is running again on its **junk** identity (which is what a restart does, see
Requirements) and has caught up. Then **`fd-standby failback`**:

5. checks that the primary is ready (or waits for it with `--wait`),
6. moves the staked identity back (~4 s), shreds the key copy on the standby and verifies that,
7. deletes the rented server and verifies it is gone.

A typical maintenance window costs **one to two euros** (one hour of a server).
No second validator machine is needed for planned maintenance.

```
$ fd-standby failover --yes
[10:14:12] creating cherry amd-threadripper-pro-7965wx in LT-Siauliai (~1.676/h)
[10:24:..] delivered in 10 min; firewall, disks, Firedancer set up; caught up
[10:27:51] standby: switch to STAKED with the primary's vote history     voting gap ~4.1 s
[10:28:..] FAILED OVER: standby votes. Do your work on this primary now ... then run: fd-standby failback

$ systemctl restart firedancer        # <- your maintenance: upgrade, reboot, whatever

$ fd-standby failback --wait
[10:41:19] primary ready
[10:41:50] primary: switch to STAKED                                      voting gap ~4.5 s
[10:42:28] standby key shredded (verified)
[10:42:37] server 1074252 deleted and gone (ran 28 min)
```

### Typical maintenance (your part, between failover and failback)

| Task | What you do | Notes |
|---|---|---|
| Firedancer upgrade | install the new binary, `systemctl restart firedancer` | the standby runs the *old* binary meanwhile (it was shipped at failover) |
| Config change | edit the TOML, restart Firedancer | keep `[paths] identity_key` = junk key |
| Reboot / kernel / BIOS | reboot | Firedancer must start again on its own (systemd) |
| Longer work | anything | the watchdog alerts after 3 h but never deletes a standby that votes |

Failback always returns to the machine `failover` was run on. Moving to a *new* primary server is not
automated yet (set up the new box, then `fd-standby-swap` from it — open an issue if you need this).

> **Status: early but real.** Developed and run against mainnet with FireBAM (Jito's Firedancer fork)
> v26.10.8 under Alpenglow. Every server type listed as qualified below was actually rented,
> set up, caught up and swapped. Read [SAFETY.md](SAFETY.md) before using it on a staked validator.

## Qualified servers

Only these types are used by default. Each one was **actually tested** with `fd-standby qualify`
(or a full real maintenance run): delivered, set up automatically, caught up, swap rehearsal with
throwaway keys, timed cold restart, deleted. Same plan = same hardware, so a plan proven in one
region is allowed in every region where the provider offers it.

<!-- QUALIFIED-TABLE:BEGIN -->
| Provider | Plan | CPU | RAM | Disks | €/h | Regions | Evidence |
|---|---|---|---|---|---|---|---|
| cherry | `amd-epyc-9275f` | AMD EPYC 9275F (24c/48t, 4.10 GHz) | 384 GB | 2x NVMe 1TB + 2x NVMe 2TB | 1.50 | DE-Frankfurt, LT-Siauliai, NL-Amsterdam | qualified 2026-11-24 in LT-Siauliai: delivered 14 min, cold restart 157 s |
| cherry | `amd-threadripper-pro-7965wx` | AMD Threadripper PRO 7965WX (24c/48t, 4.20 GHz) | 512 GB | 2x NVMe 1TB + 2x NVMe 4TB | 1.68 | DE-Frankfurt, LT-Siauliai, NL-Amsterdam, SE-Stockholm | qualified 2026-11-23 (LT): delivered 10-12 min, cold restart 137 s, 4 real staked swaps + 1 full maintenance |
| cherry | `amd-threadripper-pro-7975wx` | AMD Threadripper PRO 7975WX (32c/64t, 4.00 GHz) | 768 GB | 2x NVMe 1TB + 2x NVMe 4TB | 2.14 | DE-Frankfurt, LT-Siauliai, NL-Amsterdam, SE-Stockholm | qualified 2026-11-24 in DE-Frankfurt: delivered 11 min, cold restart 286 s |
| cherry | `amd-epyc-9575F` | AMD EPYC 9575F (64c/128t, 3.30 GHz) | 384 GB | 2x NVMe 1TB + 2x NVMe 3TB | 2.31 | DE-Frankfurt, LT-Siauliai, NL-Amsterdam, SE-Stockholm | qualified 2026-11-24 in LT-Siauliai: delivered 13 min, cold restart 140 s (128 threads) |
<!-- QUALIFIED-TABLE:END -->

"Cold restart" = Firedancer restarted with no local snapshot until caught up, snapshot from
[snappie.sh](https://snappie.sh) (Amsterdam). Delivery times are what Cherry needed for that order
(Cherry quotes 15–30 minutes for in-stock standard plans).

More types are listed as `no` in [config/candidates.conf](config/candidates.conf): eligible on
paper, not yet tested. **The community is very welcome to add qualified types** — run
`fd-standby qualify`, and open a pull request with the evidence line (see
[CONTRIBUTING.md](CONTRIBUTING.md)). The more types are qualified, the more likely one is in stock
when you need it.

## Providers

| Provider | Status |
|---|---|
| [Cherry Servers](https://www.cherryservers.com) | **Working.** Hourly billing, API with live per-region stock. All qualified types above. |
| [Vultr](https://www.vultr.com) bare metal | **Implemented, untested.** New Vultr accounts have a monthly-fee limit below the price of one bare-metal server, and Vultr declined to raise it for an account without history with them. The API calls were verified up to that refusal. If you have an established Vultr account, please qualify a plan and send a PR. |

Adding a provider = one file `lib/provider-NAME.sh` implementing six functions
(`_enabled`, `_stock`, `_create`, `_state`, `_destroy`, `_list_tagged`; see
[lib/provider-cherry.sh](lib/provider-cherry.sh)). PRs for other hourly bare-metal providers are welcome.

## Requirements

**Primary (your validator):**
- Firedancer (full Firedancer, not Frankendancer). Tested with FireBAM v26.10.8 on Ubuntu 26.04.
  fd-standby does not care how you run it (systemd, script, ...); it talks to it with
  `firedancer get-identity / set-identity / wait` using your config file. Let your service manager
  restart Firedancer on failure: after a restart it must come back by itself for `failback`.
- Your Firedancer config's `[paths] identity_key` points to a **junk (unstaked) key**. The staked
  key lives in a separate root-only file and is applied with `set-identity`. This is what makes
  every restart safe: a node always starts unstaked.
- `python3` ≥ 3.11, `curl`, `ssh`, `tar`; an API token of a supported provider.

**Standby (rented):** chosen and verified automatically: ≥48 threads, ≥240 GiB RAM, the CPU
features your binary needs, ≥900 GB + 500 GB free disk, Ubuntu with glibc ≥ 2.38. The OS disks are
never touched; data disks are found by "whole disk, no partitions, no signature, not mounted".
Plans with only two disks (< 2 TB each) are ordered with a 50 GB OS partition
(`CHERRY_OS_PARTITION_GB`); the setup then *adds* one data partition in the unallocated space
behind the existing partitions (GPT only, table backed up first) and never modifies existing ones.

## Quick start

```bash
git clone https://github.com/SolanaVault/on-demand-standby /opt/src/fd-standby && cd /opt/src/fd-standby
sudo ./install.sh                     # code -> /opt/fd-standby, config skeleton, SSH key, watchdog timer
sudo $EDITOR /etc/fd-standby/fd-standby.conf
echo '<cherry api token>' | sudo tee /etc/fd-standby/cherry-api-token >/dev/null; sudo chmod 600 /etc/fd-standby/cherry-api-token
sudo fd-standby doctor                # checks everything, changes nothing, spends nothing
sudo fd-standby stock                 # qualified types in stock right now, cheapest first
sudo fd-standby failover              # the real thing (asks before moving the staked identity)
#   ... your maintenance on the primary ...
sudo fd-standby failback --wait       # waits until the primary is caught up, moves back, deletes the standby
```

Other commands: `status`, `up`, `down`, `qualify PROVIDER PLAN REGION`, `qualify-queue`,
`watchdog`, and `fd-standby-swap {status|to-standby|to-primary|rehearse} HOST [--dry-run]`.

## How it works

- **Bundle.** Every run ships the primary's *current* Firedancer binary and a standby config
  derived from the primary's *current* config (throwaway identity, standby paths, socket network
  provider, multicast destinations such as DoubleZero dropped). Upgrades on the primary carry over
  automatically.
- **Standby setup** (`standby/standby-init.sh`): hardware check → firewall first (SSH only from
  the primary; automatic rollback unless a new login works) → data disks by discovery, labelled
  and mounted by label → Firedancer, sysctl, CPU governor, units → start, wait until caught up.
- **Swap** (`bin/fd-standby-swap`): `firedancer wait` for a safe window → old voter to junk →
  copy its vote history → new voter `set-identity --vote-history-file` with the staked key. Before
  every staked switch the other node must report a non-staked identity.
- **Watchdog** (systemd timer): alerts on standbys older than 3 h, deletes unstaked ones older
  than 6 h, never deletes one that is voting.

## Snapshots

**Known effect of a single snapshot source:** snappie publishes a new full snapshot every 25,000
slots (~1.5 h), and its incrementals always build on the newest one. If that rollover happens while
a node is downloading the previous full snapshot, no matching incremental exists anymore and
Firedancer gives up after `wait_for_peers_timeout_seconds` (30 s) — the next start downloads the
new full snapshot and works. We hit this once (a restart took 12.6 instead of ~6 minutes). A second
trusted source in `allow_list` reduces it.

The standby downloads a fresh snapshot on every start. We use
[snappie.sh](https://snappie.sh) as the only trusted source
(`[snapshots.sources.gossip] allow_any = false`, `allow_list = ["snappie..."]` in the primary
config, which the standby inherits) and raise the TCP receive window
(`standby/60-fd-tcp-rmem.conf`). Cold restart to caught up: 2–3 minutes on the qualified types.

## Costs (Cherry, Nov 2026)

1.26–2.31 €/h for qualified types; a maintenance run uses one hour. `MAX_PRICE_PER_HOUR` caps
what may be rented. A forgotten server is deleted by the watchdog after 6 h (if unstaked).

## Privacy note

The standby runs a config derived from your primary's Firedancer config. Anything in that file
(RPC or snapshot URLs with tokens, BAM/relayer settings) is copied to the rented server for the
duration of the run. Keep secrets out of the Firedancer TOML.

## Not covered

- **Unplanned crashes.** Renting and syncing a standby takes ~20 minutes; a crashed primary
  restarts faster on its own (systemd). fd-standby is for planned maintenance.
- **Hardware loss of the primary.** Use the same tooling to build a replacement, but that is a
  manual decision.
- **Agave / Frankendancer** primaries (the swap logic relies on Firedancer's `set-identity`,
  `get-identity`, `wait` and its vote-history file handling).

## License

Apache-2.0, see [LICENSE](LICENSE).
