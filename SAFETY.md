# Safety model

fd-standby moves your **staked validator identity** between two machines. The one thing that must
never happen is two machines voting with the same identity at the same time. This file explains
how the tooling prevents that, what it was tested against, and where the remaining risks are.

## Invariants

1. **Both nodes always start unstaked.** The Firedancer config of the primary and of every standby
   points `[paths] identity_key` at a junk key. The staked identity is only ever applied at runtime
   with `firedancer set-identity`. A crash, reboot or restart therefore always comes back unstaked.
2. **Act only on positive knowledge.** A node's identity is classified as *staked*, *junk* (its
   own known junk public key), *other* or *unknown*. Unknown (SSH failure, CLI error, empty output)
   never counts as "not staked": the script stops and alerts with the actual state instead.
3. **Switch order: old voter off, then new voter on.** `fd-standby-swap` switches the current voter
   to its junk key first, verifies with `get-identity` that it no longer reports the staked key,
   and only then switches the other node to the staked key.
4. **Re-check before every staked switch, verify after it.** Immediately before
   `set-identity <staked key>` on one node, the other node must *positively* report its junk key.
   After every switch the node must report the expected identity; otherwise the script restores
   what it safely can and exits 3 with the actual state.
5. **Vote history travels with the identity, and it must be fresh.** The new voter is switched
   with `--vote-history-file` containing the `.bak` that the old voter wrote *during this switch*
   (mtime check), so it cannot vote on anything the old voter already voted on.
6. **The staked keypair leaves the primary only for a swap**, only after the standby firewall is
   verified active, is stored on the standby in **tmpfs** (`/run/fd-standby`, never on disk), is
   verified by public key, and is shredded (and the removal verified) by `to-primary`, by an EXIT
   trap on any failed `to-standby`, by `down` and by `shred-key`.
7. **Never delete a server that might vote.** `down` and the watchdog delete only if this primary
   positively runs the staked identity, or the standby positively reports a non-staked identity.
   Unknown = refuse and alert.
8. **One operation at a time.** All mutating commands share a lock; the watchdog skips while it is
   held; `qualify` refuses while a standby exists.
9. **Retry only what changed nothing.** `fd-standby-swap` exits 20 for "refused, nothing changed"
   (safe to retry) and 21 for "identities changed, swap incomplete" (never retried automatically).
   All questions are asked before the first identity change; Ctrl-C/SIGHUP afterwards reports the
   actual state instead of exiting silently.
10. **No late switches.** Every `set-identity` runs under `timeout -s KILL`. Before an automatic
    restore, the other node must have no `set-identity` process left, the same Firedancer process
    as before the switch (no restart = no votes of its own), and report its junk key on three
    reads over ~10 s. SSH uses keepalives, so a silently dead link fails within ~15 s.

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
  with the other node's slot as fallback, and the two nodes must be within 10 slots of each other.
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
- **Do not edit the scripts while a run is in progress** (bash reads scripts incrementally).

## What happens when things fail

| Failure | Result |
|---|---|
| No qualified server in stock / delivery > 45 min / hardware check fails | next candidate; if none: abort, primary untouched |
| Standby does not catch up | abort before any swap; standby left for inspection (`fd-standby down`), watchdog deletes it after 6 h |
| Rehearsal on standby fails | abort before any swap |
| Swap to standby fails before the primary went to junk | abort, primary still votes, standby deleted |
| Swap fails after the primary went to junk | automatic restore of the primary **only** if all restore conditions hold (invariant 10); otherwise alert "NOBODY IS VOTING" with the actual state |
| Maintenance command fails / primary does not catch up | **standby keeps voting**, alert, nothing deleted — fix the primary, then `fd-standby-swap to-primary HOST` |
| Swap back fails | automatic restore of the standby under the same conditions, alert, standby stays |
| No fresh vote-history file after the switch | no automatic restore (history unclear), alert with actual state |

Typical voting gap per switch measured on mainnet: 3.4–3.8 s (script overhead included), plus
`firedancer wait` beforehand so no own leader slot is close.

## Residual risks (read these)

- The staked key is copied to a rented machine for the duration of the maintenance (minutes). It
  is root-only there, the firewall admits SSH only from your primary, and it is shredded
  afterwards — but the provider has physical access to that machine. If that is unacceptable for
  you, do not use this tool.
- The safety checks use SSH and `get-identity`. If the network between primary and standby fails
  in the middle of a swap, the script stops; it never guesses. Check both nodes manually
  (`fd-standby-swap status HOST`) before doing anything else.
- Tested against FireBAM v26.10.8 (Alpenglow). Firedancer's `set-identity` / vote-history
  behaviour may change between versions — run `fd-standby-swap rehearse` and a dry run
  (`--dry-run`) after every Firedancer upgrade.
- This is unaudited software written for one operator's validator. Review it.
