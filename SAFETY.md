# Safety model

fd-standby moves your **staked validator identity** between two machines. The one thing that must
never happen is two machines voting with the same identity at the same time. This file explains
how the tooling prevents that, what it was tested against, and where the remaining risks are.

## Invariants

1. **Both nodes always start unstaked.** The Firedancer config of the primary and of every standby
   points `[paths] identity_key` at a junk key. The staked identity is only ever applied at runtime
   with `firedancer set-identity`. A crash, reboot or restart therefore always comes back unstaked.
2. **Switch order: old voter off, then new voter on.** `fd-standby-swap` switches the current voter
   to its junk key first, verifies with `get-identity` that it no longer reports the staked key,
   and only then switches the other node to the staked key.
3. **Re-check before every staked switch.** Immediately before running `set-identity <staked key>`
   on one node, the script asks the other node (`get-identity`) and refuses if it reports the staked
   identity.
4. **Vote history travels with the identity.** The new voter is switched with
   `--vote-history-file` containing the old voter's vote history, so it cannot vote on anything
   the old voter has already voted on.
5. **The staked keypair leaves the primary only for a swap** (`to-standby`), is verified on arrival
   by public key, and is shredded on the standby by `to-primary`, by `down`, by the watchdog, and by
   `fd-standby-swap shred-key`. The standby firewall only allows SSH from the primary.
6. **Never delete a voting standby.** `down` and the watchdog refuse to delete a server whose
   Firedancer reports the staked identity.

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
- **Do not edit the scripts while a run is in progress** (bash reads scripts incrementally).

## What happens when things fail

| Failure | Result |
|---|---|
| No qualified server in stock / delivery > 45 min / hardware check fails | next candidate; if none: abort, primary untouched |
| Standby does not catch up | abort before any swap; standby left for inspection (`fd-standby down`), watchdog deletes it after 6 h |
| Rehearsal on standby fails | abort before any swap |
| Swap to standby fails before the primary went to junk | abort, primary still votes, standby deleted |
| Swap fails after the primary went to junk | automatic rollback to the primary |
| Maintenance command fails / primary does not catch up | **standby keeps voting**, alert, nothing deleted — fix the primary, then `fd-standby-swap to-primary HOST` |
| Swap back fails | automatic rollback to the standby, alert, standby stays |

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
