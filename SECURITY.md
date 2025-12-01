# Security Policy

## Supported Versions
The VeriSphere protocol is under active development. Only the latest commit on
the `main` branch is considered supported.

Security fixes will be applied immediately upon discovery.

## Reporting a Vulnerability
If you discover a vulnerability in any VeriSphere smart contract, script,
repository, or deployment process:

1. Do **not** create a GitHub issue.
2. Instead, email:

   security@verisphere.co

3. Include:
   - A clear description of the issue
   - Steps to reproduce (if applicable)
   - Contract addresses or code locations
   - Whether the vulnerability is theoretical or exploitable
   - Your public wallet address (for possible bounty eligibility)

We will acknowledge reports within 48 hours.

## Smart Contract Security Expectations
The core contracts follow these principles:

- Minimal trusted roles
- No upgradeable proxies in MVP
- Deterministic authorization via Authority.sol
- No unbounded loops over user data
- No external calls inside state-mutating logic except VSP token transfer calls

Formal verification and third-party audits are planned before mainnet launch.

## Bounty Program
VeriSphere will reward security disclosures that materially improve protocol
safety.

Qualifying classes include:
- Critical loss of funds
- Unauthorized mint/burn
- Post or stake manipulation
- Incorrect access control on any contract
- Economic attacks that bypass intended staking dynamics

Thank you for helping secure VeriSphere.
