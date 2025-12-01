# VeriSphere Core – Release Notes

## Version MVP-0.1 – "Staking Foundations"
Date: 2025-02

This is the first structured release of the `verisphere/core` repository.

### Added
- VSPToken.sol (clean ERC20 with Authority-gated mint/burn)
- Authority.sol (owner, minters, burners)
- PostRegistry.sol (atomic posts, immutable claims)
- StakeEngine.sol (queue-based staking, stakeLots, position-weighting)
- Full deployment scripts:
  - DeployVSP.s.sol
  - DeployPostRegistry.s.sol
  - DeployStakeEngine.s.sol

### Economic Model
- Finalized staking formulas based on:
  - Post size factor: `P = clamp((T / S) ^ alpha)`
  - Harmonic positional weighting
  - Sign-based alignment with VS
  - Daily epoch compounding (linear)
- Incorporated into Appendix A and B of claim-spec-evm-abi.md

### Documentation
- Rewritten README.md
- Added claim-spec-evm-abi.md
- Added SECURITY.md
- Added CONTRIBUTING.md

### Deployments (Fuji Testnet)
- VSPToken: 0xa8319c13dbA8f4b8d3609910549BF5e9A055c207
- Authority: 0xdcc4AC5b091C0E779CE106c1Ba384aB5C56143c5
- PostRegistry: 0x873233a9Ba4880AB84f3e7107aF891c696077619
- StakeEngine: 0xB745D10D7DFBdF7F99BBBCAf6574BC75d3b247e1

### Notes
- All contracts verified on Sourcify
- Idle decay removed from MVP
- No upgradeable proxies
- Ready for backend integration
