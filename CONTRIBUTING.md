# Contributing

## Qualify a new server type

The most useful contribution: prove that another server type works, so that more types can be
used when one is out of stock.

1. Make sure the type is in `config/candidates.conf` (or add a row with `no`). It must be a
   standard, immediately deployable plan with ≥48 threads, ≥256 GB RAM and NVMe.
2. Run, on your primary:
   ```bash
   fd-standby qualify PROVIDER PLAN REGION
   ```
   This rents one server for about 30 minutes (one billed hour), sets it up, catches up, rehearses
   a swap **with throwaway keys only**, times a cold restart, and deletes the server. Your staked
   identity is never moved.
3. Open a pull request that changes the row to `yes` and includes the line appended to
   `/var/lib/fd-standby/qualifications.log`, for example:
   ```
   2026-11-24 cherry amd-epyc-9275f LT-Siauliai cold_restart_s=157 hw=48|377|1.7T ...
   ```
   plus your Firedancer version (`firedancer --version`).

Please do not mark a type `yes` without having run it. If a type fails (hardware check, catch-up,
rehearsal), a PR that records the failure (as a comment on the row) is just as welcome.

## Add a provider

Create `lib/provider-NAME.sh` implementing the six functions documented at the top of
`lib/provider-cherry.sh`, add NAME to `PROVIDERS` in `bin/fd-standby`, add config keys to
`config/fd-standby.conf.example`, and qualify at least one plan with it. Requirements:
hourly billing, an API for create / status / delete, per-region stock visible before ordering,
and deletion that stops billing.

## Code changes

- `shellcheck -x -S warning bin/* lib/*.sh standby/*.sh install.sh` must be clean.
- Anything that touches the staked key, `set-identity` or vote history needs a description of how
  you tested it, and must keep every invariant in [SAFETY.md](SAFETY.md).
- No secrets, account ids, IP addresses or hostnames in commits.
