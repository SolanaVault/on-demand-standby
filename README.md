# on-demand-standby

**Zero-downtime maintenance for a single Solana validator, Agave or Firedancer, with a standby you rent by the hour.**

Commands: `ods` (**o**n-**d**emand **s**tandby) and `ods-swap`. A community tool, not affiliated
with Anza, Jump Crypto, the Firedancer project, Jito or any server provider.

You run one validator. Before you take it down (an upgrade, a reboot, a disk swap, anything) you run
**`ods failover`**:

1. it rents a bare-metal server by the hour (only server types that are **in stock right now** and
   **proven to work** with your client),
2. sets it up automatically as a node of **your client, with your exact binary and configuration**
   (Agave: your `agave-validator` build and running command line; Firedancer: your binary and TOML),
   on a throwaway identity,
3. waits until it has caught up with the cluster and rehearses an identity switch on it with
   throwaway keys,
4. moves your **staked identity**, with its fresh vote history, to it.

Now the standby votes and you do whatever you need on your primary. **What happens in between is
up to you; ods does not touch your primary.** The only requirement: when you are done, the
primary's validator is running again on its **junk** identity (which is what a restart does, see
[Requirements](#requirements)) and has caught up. Then **`ods failback`**:

5. checks that the primary is ready (or waits for it with `--wait`),
6. moves the staked identity back, shreds the key copy on the standby and verifies that,
7. deletes the rented server and verifies it is gone.

A typical maintenance window costs **one to two euros** (one hour of a server). No second validator
machine is needed for planned maintenance.

**Voting gap per swap** (measured on mainnet, Nov 2026):

| Client (primary and standby) | Gap | Measured how |
|---|---|---|
| Agave (Jito-Agave 4.4.0) | 0.6–1.1 s | votor log lines of both validators |
| Firedancer (FireBAM v26.10.8) | 2.8–3.3 s | wall clock from "old voter to junk" to "new voter staked" |

Example (Firedancer primary, a real run; some lines left out):

```
$ ods failover --yes
[10:54:58] creating cherry amd-threadripper-pro-7965wx in LT-Siauliai (~1.676/h)
[11:05:29] delivered in 10 min: 88.216.197.107
[11:05:31] firewall loaded (SSH only from 5.199.170.91); waiting for confirmation
[11:05:36] endpoints: jito: region frankfurt (29.5 ms; ... measured: frankfurt=29 amsterdam=36 ...)
...
[11:29:34] 3/5 primary: switch to junk (voting stops)
[11:29:35] 4/5 fresh vote history -> standby, standby -> STAKED
  voting gap ~3.3 s
[11:30:31] FAILED OVER: standby 88.216.197.107 (...) votes with <staked pubkey>.

$ systemctl restart firedancer        # <- your maintenance: upgrade, reboot, whatever

$ ods failback --wait
[11:37:09] primary ready
[11:37:38] 4/4 primary: switch to STAKED
  voting gap ~2.8 s
  OK standby key shredded (verified)
[11:38:30] server 1075173 deleted (http 204) and gone
```

### Your part, between failover and failback

| Task | Agave primary | Firedancer primary |
|---|---|---|
| Client upgrade | install the new build, restart the validator | install the new binary, restart Firedancer |
| Config change | edit the command line / service file, restart | edit the TOML, restart |
| Reboot / kernel / BIOS | reboot | reboot |
| Longer work | anything; the watchdog alerts after 3 h but never deletes a standby that votes | same |

In every case the validator must come back on its own (systemd) and on its **junk** identity:
Agave with `--identity` pointing at the junk key, Firedancer with `[paths] identity_key` = junk key.
The standby keeps running the *old* build meanwhile (it was shipped at failover).

Failback always returns to the machine `failover` was run on. Moving to a *new* primary server is
not automated yet (set up the new box, then `ods-swap` from it; open an issue if you need this).

## Status

**Early but real.** Both clients have been run against mainnet under Alpenglow with real staked
swaps, each on one validator so far:

| Primary → standby | Status |
|---|---|
| Agave → Agave (Jito-Agave 4.4.0) | **Proven**: failover, primary restart, failback with the staked key |
| Firedancer → Firedancer (FireBAM v26.10.8) | **Proven**: several full maintenance runs with the staked key |
| Agave → Firedancer | Works in principle; the vote history crosses clients. Agave → Firedancer has been used on mainnet, **Firedancer → Agave has not** (failback). Prove it on testnet first |
| Firedancer → Agave | Not supported |
| Frankendancer, either side | Not supported |

Read [SAFETY.md](SAFETY.md) before using it on a staked validator.

## Qualified servers

Only qualified types are rented. Server types are qualified **per standby client**, because the
clients need different hardware and setups: each one was **actually tested** with `ods qualify`
(or a full real maintenance run): delivered, set up automatically, caught up, swap rehearsal with
throwaway keys, timed cold restart, deleted. Same plan = same hardware, so a plan proven in one
region is allowed in every region where the provider offers it.

<!-- QUALIFIED-TABLE:BEGIN -->
| Provider | Plan | CPU | RAM | Disks | €/h | Regions | Firedancer standby | Agave standby |
|---|---|---|---|---|---|---|---|---|
| cherry | `amd-epyc-9275f` | AMD EPYC 9275F (24c/48t, 4.10 GHz) | 384 GB | 2x NVMe 1TB + 2x NVMe 2TB | 1.50 | DE-Frankfurt, LT-Siauliai, NL-Amsterdam | qualified 2026-11-24 in LT-Siauliai: delivered 14 min, cold restart 157 s; 2026-11-24 real failover/failback (LT): delivered 13 min, caught up 153 s, gaps 4.0 s / 4.4 s | not qualified |
| cherry | `amd-threadripper-pro-7965wx` | AMD Threadripper PRO 7965WX (24c/48t, 4.20 GHz) | 512 GB | 2x NVMe 1TB + 2x NVMe 4TB | 1.68 | DE-Frankfurt, LT-Siauliai, NL-Amsterdam, SE-Stockholm | qualified 2026-11-23 (LT): delivered 10-12 min, cold restart 137 s, 4 real staked swaps + 1 full maintenance; 2026-11-25 full maintenance (ods): delivered 10 min, gaps 3.3 s / 2.8 s | qualified 2026-11-25 in LT-Siauliai, cold restart 352s |
| cherry | `amd-threadripper-pro-7975wx` | AMD Threadripper PRO 7975WX (32c/64t, 4.00 GHz) | 768 GB | 2x NVMe 1TB + 2x NVMe 4TB | 2.14 | DE-Frankfurt, LT-Siauliai, NL-Amsterdam, SE-Stockholm | qualified 2026-11-24 in DE-Frankfurt: delivered 11 min, cold restart 286 s | qualified 2026-11-25 in DE-Frankfurt, cold restart 312s |
| cherry | `amd-epyc-9575F` | AMD EPYC 9575F (64c/128t, 3.30 GHz) | 384 GB | 2x NVMe 1TB + 2x NVMe 3TB | 2.31 | DE-Frankfurt, LT-Siauliai, NL-Amsterdam, SE-Stockholm | qualified 2026-11-24 in LT-Siauliai: delivered 13 min, cold restart 140 s (128 threads) | qualified 2026-11-25 in DE-Frankfurt, cold restart 190s |
<!-- QUALIFIED-TABLE:END -->

"Cold restart" = the standby's validator restarted with no local snapshot until caught up, snapshot
from [snappie.sh](https://snappie.sh). Delivery times are what Cherry needed for that order (Cherry
quotes 15–30 minutes for in-stock standard plans). The table is generated from
[config/candidates.conf](config/candidates.conf) (Firedancer) and
[config/candidates-agave.conf](config/candidates-agave.conf) (Agave) by `tools/render-qualified.py`.

Types listed as `no` there are eligible on paper but not yet tested. **The community is very
welcome to add qualified types**: run `ods qualify` and open a pull request with the evidence line
(see [CONTRIBUTING.md](CONTRIBUTING.md)). The more types are qualified, the more likely one is in
stock when you need it.

## Providers

| Provider | Status |
|---|---|
| [Cherry Servers](https://www.cherryservers.com) | **Working.** Hourly billing, API with live per-region stock. All qualified types above. |
| [Vultr](https://www.vultr.com) bare metal | **Implemented, untested.** New Vultr accounts have a monthly-fee limit below the price of one bare-metal server, and Vultr declined to raise it for an account without history with them. The API calls were verified up to that refusal. If you have an established Vultr account, please qualify a plan and send a PR. |

Adding a provider = one file `lib/provider-NAME.sh` implementing six functions
(`_enabled`, `_stock`, `_create`, `_state`, `_destroy`, `_list_tagged`; see
[lib/provider-cherry.sh](lib/provider-cherry.sh)). PRs for other hourly bare-metal providers are welcome.

## Requirements

**Both clients:**
- The validator **starts on a junk (unstaked) identity**. The staked keypair lives in a separate
  root-only file (`PRIMARY_STAKED_KEY`) and is applied at runtime with `set-identity`. This is what
  makes every restart safe: a node always comes back unstaked. Consequence: after a restart
  *outside* ods you switch to the staked key yourself.
- Your service manager restarts the validator on failure: after your maintenance it must come back
  by itself for `failback`.
- `python3` ≥ 3.11, `curl`, `ssh`, `tar`; an API token of a supported provider.
- `ods doctor` checks all of this and changes nothing.

**Agave primary** (`PRIMARY_CLIENT=agave` and the `AGAVE_*` settings in `ods.conf`). Developed
against Jito-Agave v4.4.0; every subcommand and flag used was checked against that binary's `--help`
and source.
- `--identity` points at a junk keypair (a symlink to one is fine, but nothing may ever point it at
  the staked key). The staked key is given to the validator over the admin socket, on stdin
  (`authorized-voter add`, then `set-identity`). Agave does not vote on a junk identity (votor
  "hot spare"). `ods doctor` checks what the running process's `--identity` points to now.
- The validator writes a readable `--log` file: a swap confirms in it that votor really stopped
  voting as the old identity before the vote history is copied.
- **Admin socket**: ods runs as root but calls `agave-validator --ledger <AGAVE_LEDGER> ...` as the
  owner of `<ledger>/admin.rpc` (the agave CLI cannot use the socket as root).
- **Local RPC** (`AGAVE_RPC_URL`, default `http://127.0.0.1:8899`): caught-up check (finalized slot).
- **Safe window**: `wait-for-restart-window --min-idle-time AGAVE_MIN_IDLE_MIN` (minutes; it also
  requires delinquent stake ≤ 5 % and a healthy node).
- **Vote history**: Agave reads `<ledger>/vote_history-<pubkey>.bin` (there is no
  `--vote-history-file`). The incoming file is installed there (the previous one is kept as
  `….bin.ods-replaced`) and `set-identity` is called without `--do-not-require-vote-history`, so
  Agave refuses the switch, and changes nothing, if it cannot load it; the swap then restores the
  previous voter automatically.

**Firedancer primary** (`PRIMARY_CLIENT=firedancer`, the default). Full Firedancer, not
Frankendancer; tested with FireBAM v26.10.8 on Ubuntu 26.04.
- `[paths] identity_key` in your TOML points to the junk key.
- ods talks to it with `firedancer get-identity / set-identity / wait` using your config file; it
  does not care how you run it (systemd, script, ...). The vote history is handed over with
  `set-identity --vote-history-file`.

**Standby (rented):** chosen and verified automatically: enough threads and RAM for the client
(Firedancer: ≥ 48 threads, ≥ 240 GiB; Agave: ≥ 360 GiB by default, `STANDBY_MIN_RAM_GIB`), the CPU
features your binary needs, ≥ 900 GB + 500 GB free disk, Ubuntu with glibc ≥ 2.38. The OS disks are
never touched; data disks are found by "whole disk, no partitions, no signature, not mounted".
Plans with only two disks (< 2 TB each) are ordered with a 50 GB OS partition
(`CHERRY_OS_PARTITION_GB`); the setup then *adds* one data partition in the unallocated space
behind the existing partitions (GPT only, table backed up first) and never modifies existing ones.
**This 2-disk path is experimental**: no 2-disk plan has been qualified with it yet.

## Quick start

```bash
git clone https://github.com/SolanaVault/on-demand-standby /opt/src/ods && cd /opt/src/ods
sudo ./install.sh                     # code -> /opt/ods, config skeleton, SSH key, watchdog timer
sudo $EDITOR /etc/ods/ods.conf        # PRIMARY_CLIENT=agave|firedancer and its settings
echo '<cherry api token>' | sudo tee /etc/ods/cherry-api-token >/dev/null; sudo chmod 600 /etc/ods/cherry-api-token
sudo ods doctor                # checks everything, changes nothing, spends nothing
sudo ods stock                 # qualified types in stock right now, cheapest first
sudo ods failover              # the real thing (asks once, before renting; run it in tmux/screen)
#   ... your maintenance on the primary ...
sudo ods failback --wait       # waits until the primary is caught up, moves back, deletes the standby
```

Other commands: `status`, `up`, `down`, `qualify PROVIDER PLAN REGION`, `qualify-queue`,
`watchdog`, and `ods-swap {status|to-standby|to-primary|rehearse} HOST [--dry-run]`.

## How it works

- **Bundle.** Every run ships what the primary runs *now*, so upgrades carry over automatically:
  - Agave: your `agave-validator` + `solana-keygen`, and a standby command line derived from your
    *running* validator. Identity/vote-account keypairs, all paths, public addresses, port range,
    `--no-snapshot-fetch` and multicast shred receivers (DoubleZero) are removed; the standby
    layout, a junk `--identity` and `--vote-account <VOTE_PUBKEY>` are added. `ods doctor` prints
    the result. Anything it cannot place (another path flag, this host's IP) stops the bundle: list
    it in `STANDBY_AGAVE_DROP_ARGS`, add replacements with `STANDBY_AGAVE_EXTRA_ARGS`. Programs that
    run next to the validator against its ledger (e.g. Harmonic's `harmonic-scheduler`) are found
    automatically and run on the standby too, same binary and arguments
    (`STANDBY_AGAVE_COMPANIONS`). File capabilities (`setcap`) are copied.
  - Firedancer: your binary, and a standby TOML derived from yours (throwaway identity, standby
    paths, socket network provider, multicast destinations such as DoubleZero dropped).
- **Standby setup** (`standby/standby-init.sh`): hardware check → firewall first (SSH only from
  the primary; automatic rollback unless a new login works) → data disks by discovery, labelled
  and mounted by label → client, sysctl, CPU governor, units → start, wait until caught up. If
  systemd gives up on the validator while it catches up (e.g. a snapshot source stalls), ods
  restarts it up to `CATCHUP_RESTARTS` times. On an Agave standby every node operation runs through
  `ods-node`, which uses the same code (`lib/primary-agave.sh`) as the primary.
- **Swap** (`bin/ods-swap`): wait for a safe window → old voter to junk → copy its vote history →
  new voter `set-identity` with that history and the staked key. Before every staked switch the
  other node must positively report its junk identity. One multiplexed SSH connection per swap.
  Everything client-specific lives in `lib/primary-*.sh` (this machine) and `lib/standby-*.sh`
  (the rented one).
- **Watchdog** (systemd timer): alerts on standbys older than 3 h, deletes unstaked ones older
  than 6 h, never deletes one that is voting.

## The standby mirrors the primary

Whatever block-building setup the primary runs, the standby runs the same, on both clients:
Jito block engine, Jito BAM, Harmonic (Salsa / Samba), other shred relays, or none of them.
Nothing is added and nothing is removed (except multicast destinations such as DoubleZero,
`STANDBY_DROP_MULTICAST`).

Only the *region* changes, and it is **never configured: it is always measured from the box
itself**. During setup the standby pings every region of every provider the primary uses and
re-points that provider's endpoints (block engine, BAM, remote TPU, shred receiver) to the closest
one, all from the same region. Scheme, port and path stay as configured. `ods doctor` runs the same
measurement on the primary and warns when the primary's own config does not use the closest region.
The list of endpoints per region is `config/regional-endpoints.conf` (sources and dates inside; add
providers or regions there). A host under a known provider domain that is not in that list is kept
and reported by `doctor`/`bundle`. Global endpoints (`mainnet.block-engine.jito.wtf`,
`mainnet.bam.jito.wtf`) are left alone. Services that whitelist validator identities (BAM,
Harmonic) see the standby's junk identity until the swap; after the swap the standby connects with
your staked identity like the primary did.

## Snapshots

**Agave standby:** before the first start it downloads the newest full + incremental snapshot from
the servers in `STANDBY_SNAPSHOT_SOURCES` (default: snappie.sh's gossip identity; its current RPC
address is looked up in gossip when the bundle is built) and from `STANDBY_SNAPSHOT_URLS`. If your
command line uses `--known-validator`, the sources are added as known validators, so a later
self-fetch may use them too. No source answers: the validator fetches its own as configured.

**Firedancer standby:** downloads a fresh snapshot on every start from the sources in your TOML,
which the standby inherits (we use [snappie.sh](https://snappie.sh) as the only trusted source:
`[snapshots.sources.gossip] allow_any = false`, `allow_list = ["snappie..."]`), with a raised TCP
receive window (`standby/60-ods-tcp-rmem.conf`).

**Known effect of a single snapshot source:** snappie publishes a new full snapshot every 25,000
slots (~1.5 h), and its incrementals always build on the newest one. If that rollover happens while
a node downloads the previous full snapshot, no matching incremental exists anymore and the start
fails; the next start downloads the new full snapshot and works. A stalled download has the same
effect. A second trusted source reduces it.

## Costs (Cherry, Nov 2026)

1.26–2.31 €/h for qualified types; a maintenance run uses about one hour. `MAX_PRICE_PER_HOUR` caps
what may be rented. A forgotten server is deleted by the watchdog after 6 h (if unstaked).

## Privacy note

The standby runs a config derived from your primary's Agave command line (and its companion
programs' command lines) or Firedancer TOML. Anything in there (RPC or snapshot URLs with tokens,
BAM/relayer settings) is copied to the rented server for the duration of the run. Keep secrets out
of them.

## Not covered

- **Unplanned crashes.** Renting and syncing a standby takes 20 minutes or more; a crashed primary
  restarts faster on its own (systemd). ods is for planned maintenance.
- **Hardware loss of the primary.** Use the same tooling to build a replacement, but that is a
  manual decision.
- **Frankendancer**, and an Agave standby for a Firedancer primary.

## License

Apache-2.0, see [LICENSE](LICENSE).
