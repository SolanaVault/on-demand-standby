# Security policy

ods moves a staked validator identity between machines. A bug can cost votes or, in the worst
case, cause a validator to vote twice. Please report anything that could lead to that, or to a
staked keypair leaving the primary in an unexpected way, **privately**:

- use GitHub's **"Report a vulnerability"** button on the Security tab of this repository
  (private advisory), and
- do not open a public issue or pull request for it before a fix is available.

Please include the ods version (`git describe --tags`), your validator client and version, and
the relevant part of `/var/lib/ods/swap.log` (it never contains key material).

The safety model and its invariants are described in [SAFETY.md](SAFETY.md).
