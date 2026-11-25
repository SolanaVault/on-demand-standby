# Safety model

ods moves your **staked validator identity** between two machines. The one thing that must
never happen is two machines voting with the same identity at the same time. This file explains
how the tooling prevents that, what it was tested against, and where the remaining risks are.

## Invariants

1. **Both nodes always start unstaked.** The Firedancer config of the primary and of every standby
   points `[paths] identity_key` at a junk key. The staked identity is only ever applied at runtime
   with `firedancer set-identity`. A crash, reboot or restart therefore always comes back unstaked.
2. **Act only on positive knowledge.** A node's identity is classified as *staked*, *junk* (its
   own known junk public key), *other* or *unknown*. Unknown (SSH failure, CLI error, empty output)
   never counts as "not staked": the script stops and alerts with the actual state instead.
3. **Switch order: old voter off, then new voter on.** `ods-swap` switches the current voter
   to its junk key first, verifies with `get-identity` that it no longer reports the staked key,
   and only then switches the other node to the staked key.
4. **Re-check before every staked switch, verify after it.** Immediately before
   `set-identity <staked key>` on one node, the other node must *positively* report its junk key.
   After every switch the node must report the expected identity; otherwise the script restores
   what it safely can and exits 21 with the actual state.
5. **Vote history travels with the identity, and it must be fresh.** The new voter is switched
   with `--vote-history-file` containing the `.bak` that the old voter wrote *during this switch*
   (mtime check), so it cannot vote on anything the old voter already voted on.
6. **The staked keypair leaves the primary only for a swap**, only after the standby firewall is
   verified active, is stored on the standby in **tmpfs** (`/run/ods`, never on disk), is
   verified by public key, and is shredded (and the removal verified) by `to-primary`, by an EXIT
   trap on any failed `to-standby`, by `down` and by `shred-key`.
7. **Never delete a server that might vote, or that holds the freshest vote history.** `down`
   and the watchdog delete only if this primary positively runs the staked identity, or the
   standby positively reports a non-staked identity. The standby of a running failover is kept
   until this primary votes again, even if it reports junk (it may have crashed; its disk holds
   the newest vote history). Unknown = refuse and alert. `down --force` overrides this.
8. **One operation at a time.** All mutating commands share a lock; the watchdog skips while it is
   held; `qualify` refuses while a standby exists.
9. **Retry only what changed nothing.** `ods-swap` exits 20 for "refused, nothing changed"
   (safe to retry) and 21 for "identities changed, swap incomplete" (never retried automatically).
   All questions are asked before the first identity change. From the first identity change until
   the swap is committed or rolled back, SIGINT/SIGHUP/SIGTERM are **ignored** (also by the
   `ssh`/`set-identity` children), so a Ctrl-C or a dropped SSH session cannot stop a swap
   halfway; the log keeps being written to `/var/lib/ods/swap.log`. Still: run
   `failover`/`failback` in `tmux`/`screen` or with `systemd-run`.
10. **No late switches.** Every `set-identity` runs under `timeout -s KILL`. An automatic restore
    happens only if the failed staked switch *exited cleanly* (a killed / timed-out / SSH-broken
    `set-identity` might still complete inside Firedancer, so then nothing is restored), the other
    node has no `set-identity` process left, runs the same, known Firedancer process as before the
    switch (no restart = no votes of its own), and reports its junk key on three reads over ~10 s.
    SSH uses keepalives, so a silently dead link fails within ~15 s.
11. **A swap succeeds only when votes are seen on chain.** After the switch the vote account must be
    `current` with an advancing `lastVote` within ~60 s; otherwise it alerts and exits 21, and
    `failover` does not tell you to take the primary down.
12. **Both nodes staked is detected and alerted** by `status`, `failback` and the watchdog (e.g. the
    primary was restarted with the staked key in its config during maintenance).

## Agave nodes (`PRIMARY_CLIENT=agave`, `STANDBY_CLIENT=agave`): how the invariants hold

Checked against Jito-Agave v4.4.0 (`--help` and source, `validator/src/admin_rpc_service.rs`,
`votor/src/event_handler.rs`, `votor/src/voting_utils.rs`). The rows apply to an Agave primary and
to an Agave standby alike: on the standby the same code runs through `ods-node`
(`lib/primary-agave.sh`), driven over SSH. The standby's start command is the primary's with a
junk `--identity` (generated on the standby) and `--vote-account <pubkey>`.

| Invariant | Firedancer primary | Agave primary |
|---|---|---|
| 1 start unstaked | `[paths] identity_key` = junk | `--identity <junk>` in the start command. The staked key is added at runtime only (`authorized-voter add`, then `set-identity`, both from stdin). A junk identity never votes: votor returns "HotSpare" when the identity is not the vote account's node. Runtime authorized voters are lost on restart. `to-standby` and `failover` **refuse** unless the running process was started with the junk `--identity` (pubkey compared), so a restart during maintenance cannot vote. After a hand-back (or a refusal) the standby drops the staked key from its authorized voters (`authorized-voter remove-all`, only while it positively runs junk); its units set `LimitCORE=0` |
| 2 positive identity | `firedancer get-identity` | `agave-validator contact-info --output json` over the admin socket (no RPC); exit ≠ 0, bad JSON or no valid `id` = unknown |
| 5 fresh vote history | `.bak` mtime ≥ switch start | Agave writes `vote_history-<pk>.bin` **in place**, and votor applies `set-identity` **asynchronously** (the admin call returns before votor stops voting as the old key). Fresh = written ≤ `AGAVE_VH_SLACK_S` (30 s) before the switch start **and** votor has **logged** that it left the staked identity at/after the switch start (`set-identity: from <STAKED> to …`, written by `handle_set_identity` after it swapped its signing key: positive proof that no vote of the staked key follows, so the validator needs a readable `--log` file) (votor stores the history only on that same event-loop thread, atomically via `.bin.new` + rename, so after the line no write to the staked file can follow: `voting_utils.rs` `insert_vote_and_create_bls_message`, `event_handler.rs` `handle_set_identity`, Jito-Agave 4.4.0). An extra "unchanged for N s" wait is optional (`AGAVE_VH_QUIET_S`, default 0). The file is copied privately and must be unchanged (inode, size, mtime) across that copy, else the swap stops without a restore |
| 5 hand-back | `--vote-history-file` | no such flag: the file is installed atomically as `<ledger>/vote_history-<pk>.bin` (old one kept as `.ods-replaced`) before `set-identity`. We never pass `--do-not-require-vote-history`, so Agave refuses the switch before changing anything if the file is missing or does not parse |
| 10 no late switch | `timeout -s KILL`, `pgrep` in-flight, PID unchanged | the same: client under `timeout -s KILL`; in-flight = `--ledger L set-identity\|authorized-voter` processes; PID = the process listening on `L/admin.rpc` (standby: the unit's MainPID). A killed/timed-out client may still have delivered the request → no automatic restore. **Exceptions** (nothing was changed, so the previous voter is restored automatically, both directions): Agave answers "Unable to load vote history file" (that check runs before the switch), or the switch failed before `set-identity` was called (pubkey unreadable, history file could not be installed) |
| safe window | `firedancer wait` | `wait-for-restart-window --min-idle-time N --skip-new-snapshot-check` (minutes; also delinquent stake ≤ 5 %, health) |
| caught up | `replay_reset_slot` (finalized) | local RPC `getSlot` commitment finalized |
| 11 votes on chain | vote account `lastVote` advances | unchanged. Before every swap the vote account (`VOTE_PUBKEY`) must list `STAKED_PUBKEY` as its node: with a wrong one Agave would accept the staked identity without the vote-history check and never vote |

Agave's CLI cannot use the admin socket as root (it fails with EACCES), so ods runs it as the
socket's owner (`setpriv`). The keypair is still opened by root and passed on stdin.

**Tested so far:** the read-only functions against a live Jito-Agave v4.4.0 mainnet node; the
complete swap logic (`to-standby`, `to-primary`, `rehearse`, refusal on either side, a hung
`set-identity`) against two simulated Agave nodes whose voter, like votor, applies `set-identity`
1 s late (and 8 s late: the swap waits for votor's log line, gap ~13 s): no double votes, every new
voter continued from the old voter's last vote, gaps 4.3–6 s.
**Real staked swaps (2026-11-25, Jito-Agave 4.4.0, primary and standby ~190 ms apart):**
failover/failback with the staked key, plus a primary restart (config change) while the standby
voted: votor gaps 0.64 s (failover) and 1.09 s (failback), taken from both validators' votor log
lines, after the timing work (one multiplexed SSH connection, the remote steps merged into one call
each way, the log path resolved before the switch, no fixed quiet wait). Before it: ~13.6 s / ~24 s.

With an Agave primary and a *Firedancer* standby, the vote history crosses clients: Agave →
Firedancer has been used on mainnet, Firedancer → Agave has not. Prove it on testnet first.

## Lessons that are built in (each one was a real failure)

- **Firedancer renames the vote-history file when switching away from an identity.** After
  `set-identity` away from X, `vote_history-X.bin` becomes `vote_history-X.bin.bak`
  (`fd_votor_tile.c`, FireBAM v26.10.8). An early version copied `….bin`, did not find it, and left
  **nobody voting for 45 s** before a manual fix. The script now copies the `.bak` and has an
  **automatic rollback**: if anything fails after the old voter went to junk (vote-history copy,
  the new node's switch), the old voter is switched back to the staked key with its own vote
  history — after checking that the other node is not staked.
- **"Caught up" must not depend on one public RPC.** Rate-limited RPC answers once produced a
  negative lag that passed the check. Lag is now the best of 5 samples against a list of RPCs,
  with no fallback (no answer = refuse), and the two nodes must be within 10 slots of each other.
  Note: `replay_reset_slot` tracks the *finalized* slot, normally 5–20 slots behind the RPC tip.
- **Commands in a `while read` loop must not read stdin** (`ssh` does). This silently skipped
  candidates. All loops read from a dedicated file descriptor and remote calls get `</dev/null`.
- **Never move or delete Firedancer's vote-history files.** On every identity switch votor renames
  its "spare" file (the `.bak` of the identity it last left) *by name*; if it is missing,
  `renameat2` fails with `FD_LOG_ERR` and the validator dies. The tool only reads and copies them.
- **The firewall must be confirmed right after it loads.** An earlier version started a 3-minute
  "rollback unless confirmed" timer and only confirmed after the whole setup — on a slow setup the
  rollback would have removed the firewall for good. Firewall is now its own stage, confirmed by a
  new SSH login immediately, and verified again before the staked key is sent.
- **Providers reuse IP addresses.** A new server can get the IP of an earlier one, and SSH then
  (correctly) refuses the changed host key. For every newly created server the old known-hosts
  entry for its IP is removed before the first connection; the new key is pinned for the rest of the
  run and checked on every later connection (trust on first use per server).
- **`pkill -f PATTERN` inside `ssh host "..."` kills its own shell**, whose command line contains
  PATTERN. The "no set-identity still running" check therefore always failed, which silently
  disabled every automatic restore (found in review 3). Patterns now start with `[s]` so they
  cannot match themselves.
- **Do not edit the scripts while a run is in progress** (bash reads scripts incrementally).

## What happens when things fail

| Failure | Result |
|---|---|
| No qualified server in stock / delivery > 45 min / hardware check fails | next candidate; if none: abort, primary untouched |
| Standby does not catch up | abort before any swap; standby left for inspection (`ods down`), watchdog deletes it after 6 h |
| Rehearsal on standby fails | abort before any swap |
| Swap to standby fails before the primary went to junk | abort, primary still votes, standby deleted |
| Swap fails after the primary went to junk | automatic restore of the primary **only** if all restore conditions hold (invariant 10); otherwise alert "NOBODY IS VOTING" with the actual state |
| Primary not ready at failback (not junk / not caught up / not answering) | **standby keeps voting**, failback refuses and says why; `--wait` waits up to `CATCHUP_MAX_S` and alerts if the standby stops voting meanwhile |
| Failback swap fails | automatic restore of the standby under the same conditions, alert, standby stays |
| No fresh vote-history file after the switch | no automatic restore (history unclear), alert with actual state |
| Staked switch killed / timed out / SSH broke during it | no automatic restore (it may still complete), alert with actual state |
| Switch verified but no votes seen on chain within ~60 s | alert, exit 21; `failover` does not report success |
| Standby crashes during maintenance (comes back on junk) | nobody votes; watchdog alerts "NEITHER ... staked"; the standby is **not** deleted. Recover manually, see below |
| Primary comes back **staked** while the standby votes | alert "BOTH NODES STAKED" with the command to switch the primary to junk |

Typical voting gap per switch measured on mainnet: 3.4–4.5 s (script overhead included), plus
`firedancer wait` beforehand so no own leader slot is close.

## Manual recovery: the standby crashed while it was voting

The standby restarts on its junk key (invariant 1), so nobody votes. Its disk holds the newest
vote history (`vote_history-<STAKED>.bin` in its ledger directory). On the primary, once its
Firedancer runs on junk and has caught up:

```bash
ods-swap status <standby-ip>          # both must report junk
scp root@<standby-ip>:<ledger dir>/vote_history-<STAKED>.bin /tmp/vh.bin   # newest history
chown firedancer: /tmp/vh.bin
firedancer set-identity --config <your.toml> --vote-history-file /tmp/vh.bin <staked keypair>
ods down                               # now allowed: this primary is staked
```

Agave primary (no `--vote-history-file`; the file is loaded from the ledger directory):

```bash
ods-swap status <standby-ip>          # both must report junk
scp root@<standby-ip>:/mnt/ods-ledger/agave/vote_history-<STAKED>.bin /tmp/vh.bin
L=<your --ledger>; cp $L/vote_history-<STAKED>.bin $L/vote_history-<STAKED>.bin.old 2>/dev/null
install -o <ledger owner> -m 644 /tmp/vh.bin $L/vote_history-<STAKED>.bin
agave-validator --ledger $L authorized-voter add < <staked keypair>   # as the ledger owner
agave-validator --ledger $L set-identity < <staked keypair>
ods down
```

If the standby is unreachable, its vote history is lost: wait until the slots it may have voted on
are finalized (a few minutes) before switching the primary to the staked key with its own history.

## Residual risks (read these)

- The staked key is copied to a rented machine for the duration of the maintenance (minutes). It
  is root-only there, the firewall admits SSH only from your primary, and it is shredded
  afterwards — but the provider has physical access to that machine. If that is unacceptable for
  you, do not use this tool.
- The safety checks use SSH and `get-identity`. If the network between primary and standby fails
  in the middle of a swap, the script stops; it never guesses. Check both nodes manually
  (`ods-swap status HOST`) before doing anything else.
- Tested against FireBAM v26.10.8 (Alpenglow); the Agave adapters against Jito-Agave v4.4.0
  (read-only functions on a live mainnet node, switch logic in a two-node simulation only).
- An Agave standby inherits your start command. Settings that only make sense on your primary's
  hardware (e.g. `--experimental-poh-pinned-cpu-core`) carry over unless you drop/replace them
  (`STANDBY_AGAVE_DROP_ARGS` / `STANDBY_AGAVE_EXTRA_ARGS`). Regional endpoints (Jito, BAM,
  Harmonic, shred relays) are re-pointed to the standby's closest region only when they are in
  `config/regional-endpoints.conf`; any other host is kept as on the primary (with a warning).
  Re-pointing never changes WHICH services the standby uses, and none of them takes part in the
  vote/identity safety (the standby's junk identity is not whitelisted at Jito BAM / Harmonic;
  that is expected until the staked key is switched in). Firedancer's `set-identity` / vote-history
  behaviour may change between versions — run `ods-swap rehearse` and a dry run
  (`--dry-run`) after every Firedancer upgrade.
- SSH host keys are trusted on first use per rented server (`StrictHostKeyChecking=accept-new`, a
  separate known_hosts file per server). A machine-in-the-middle at the provider during the first
  connection is not detected.
- If this primary's outgoing public IP changes during maintenance (multi-homed host, routing
  change), the standby firewall locks it out and failback fails with an SSH error. List extra
  source IPs in `STANDBY_EXTRA_SSH_SOURCES`; the provider's web console still works.
- Upgrading Firedancer on the primary during maintenance hands the *old* binary's vote history to
  the new one at failback. This worked with FireBAM v26.10.x; check the release notes for
  vote-history format changes before a major upgrade.
- This is unaudited software written for one operator's validator. Review it.
