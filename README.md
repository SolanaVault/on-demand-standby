# on-demand-standby

**Zero-downtime maintenance for a single Firedancer validator, with a standby you rent by the hour.**

Commands: `fd-standby`, `fd-standby-swap`. A community tool, not affiliated with Jump Crypto, the Firedancer project, Jito or any server provider.

You run one Firedancer validator. When you need to restart or upgrade it, `fd-standby maintain`:

1. rents a bare-metal server by the hour (only server types that are **in stock right now** and **proven to work**),
2. sets it up automatically as a Firedancer node with a throwaway identity, using **your exact binary and config**,
3. waits until it has caught up with the cluster,
4. rehearses an identity switch on it with throwaway keys,
5. moves your **staked identity** (with its vote history) to it — the voting gap is ~3.5 s,
6. runs your maintenance command on the primary (default: restart Firedancer) and waits until the primary has caught up,
7. moves the staked identity back (~3.8 s) and shreds the key copy on the standby,
8. deletes the rented server.

A typical run takes 25–35 minutes and costs **one to two euros** (one hour of a server).
No second validator machine is needed for planned maintenance.

```
$ fd-standby maintain --yes
[06:44:34] creating cherry amd-threadripper-pro-7965wx in LT-Siauliai (~1.676/h)
[06:56:..] delivered in 12 min
[06:57:40] firedancer started            (disks, firewall, identity: discovered and set up automatically)
[07:00:43] standby: switch to STAKED      switch took 3.4 s
[07:01:24] running on primary: systemctl restart firedancer
[07:07:17] primary caught up after 5 min
[07:07:45] primary: switch to STAKED      switch took 3.8 s
[07:08:22] server 1074140 is gone (ran 23 min)
[07:08:22] MAINTAIN done
```

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
| cherry | `amd-epyc-9275f` | AMD EPYC 9275F (24c/48t, 4.10 GHz) | 384 GB | 2x NVMe 1TB + 2x NVMe 2TB | 1.50 | DE-Frankfurt, LT-Siauliai, NL-Amsterdam | qualified 2026-11-24 in LT-Siauliai, cold restart 157s |
| cherry | `amd-threadripper-pro-7965wx` | AMD Threadripper PRO 7965WX (24c/48t, 4.20 GHz) | 512 GB | 2x NVMe 1TB + 2x NVMe 4TB | 1.68 | DE-Frankfurt, LT-Siauliai, NL-Amsterdam, SE-Stockholm | qualified 2026-11-23 (LT): delivered 10-12 min, cold restart 137 s, 4 real staked swaps + 1 full maintenance |
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
- Firedancer (full Firedancer, not Frankendancer) run by systemd. Tested with FireBAM v26.10.8 on Ubuntu 26.04.
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
sudo fd-standby maintain              # the real thing (asks before moving the staked identity)
sudo fd-standby maintain -- /usr/local/bin/my-upgrade-script   # custom maintenance command
```

Other commands: `up`, `status`, `down`, `qualify PROVIDER PLAN REGION`, `qualify-queue`,
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
