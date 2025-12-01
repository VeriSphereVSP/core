# Contributing to VeriSphere Core

Thank you for your interest in contributing!

This document describes how to contribute code, documentation, or ideas to the
`verisphere/core` repository.

## Development Setup

### 1. Install Foundry
curl -L https://foundry.paradigm.xyz | bash
foundryup

shell
Copy code

### 2. Install Dependencies
forge install OpenZeppelin/openzeppelin-contracts --no-git

shell
Copy code

### 3. Build
forge build

shell
Copy code

### 4. Run Tests
forge test -vv

markdown
Copy code

## Code Style
- Solidity ^0.8.20 and above
- ASCII-only source
- No inline assembly unless required
- Follow Foundry recommended patterns
- Avoid unnecessary inheritance
- Keep state changes minimal and explicit

## Branching Model
- `main` is always deployable
- Create feature branches from `main`
- PRs must:
  - Pass all tests
  - Add new tests for new features
  - Include documentation changes if applicable

## Commit Message Format
type(scope): short description

markdown
Copy code

Examples:
- `feat(stake-engine): add queue-based position weighting`
- `fix(token): correct role check in burnFrom`
- `docs: update staking formulas`

## Pull Request Checklist
- [ ] All tests pass
- [ ] New logic has test coverage
- [ ] Includes comments where needed
- [ ] Gas usage is reasonable
- [ ] No secrets or private keys committed
- [ ] Matches claim-spec-evm-abi.md

## Security
Never include:
- private keys  
- .env files  
- broadcast JSON with secrets  

See `SECURITY.md` for vulnerability disclosure practices.

## License
MIT License applies to all contributions.
