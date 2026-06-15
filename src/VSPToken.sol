// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/metatx/ERC2771ContextUpgradeable.sol";
import "./authority/Authority.sol";
import "./interfaces/IVSPToken.sol";
// patch_bundle10_5_part2a_timecap: time-based supply cap math (UD60x18 fixed point)
import {UD60x18, ud} from "@prb/math/src/UD60x18.sol";

/// @title VSPToken — Verisphere ERC-20 with permit, ERC-2771, and UUPS upgradeability
contract VSPToken is
    Initializable,
    ERC20Upgradeable,
    ERC20PermitUpgradeable,
    UUPSUpgradeable,
    ERC2771ContextUpgradeable,
    IVSPToken
{
    Authority public authority;

    // patch_bundle10_5_part2a_timecap + patch_bundle10_5_part2a_stakeengine_exempt:
    // time-based supply growth cap (replaces the Part 1 per-call +
    // total constants). The cap is:
    //     maxAllowedSupply(t) = INCEPTION_SUPPLY * GROWTH_BASE ^ years
    //     years = (block.timestamp - INCEPTION_TIMESTAMP) / SECONDS_PER_YEAR
    // Bounds *cumulative* inflation per unit time, so a compromised
    // capped-minter is bounded by (rate x detection_window) regardless
    // of how many calls it fires.
    //
    // STAKE_ENGINE_ADDRESS is EXEMPT from the cap: it mints staker
    // gains in response to honest protocol activity, and bounding
    // those would break withdrawals when supply approaches the curve.
    // The exemption is per-address by _msgSender() (forwarder-aware).
    // To change which contract is exempt (e.g. StakeEngine ever
    // migrates to a new proxy), deploy a new VSPToken impl + UUPS
    // upgrade — exemption is a per-deploy decision, not governance-
    // toggleable. Pass address(0) to disable the exemption.
    //
    // All four are immutable constructor args: continuous across UUPS
    // upgrades (pass the SAME values on every future impl deploy).

    /// @notice Unix timestamp treated as protocol inception (year 0 of
    ///         the cap curve). Set to the original proxy deploy time.
    uint256 public immutable INCEPTION_TIMESTAMP;

    /// @notice Supply allowed at year 0 (the day-0 cap). In wei.
    uint256 public immutable INCEPTION_SUPPLY;

    /// @notice Annual growth multiplier in UD60x18 (e.g. 10e18 = 10x/yr).
    ///         The cap multiplies by this factor each elapsed year.
    uint256 public immutable GROWTH_BASE_PER_YEAR;

    /// @notice Address exempt from the time-window cap. Set to the
    ///         StakeEngine proxy so staker gain-mints proceed even
    ///         when capped minters are bound. address(0) disables
    ///         the exemption entirely (every minter is capped).
    address public immutable STAKE_ENGINE_ADDRESS;

    /// @notice Seconds per year used by the cap curve (365 * 86400).
    uint256 public constant SECONDS_PER_YEAR = 365 * 86400;

    /// @dev Reverted by onlyMinter when caller lacks the minter role.
    error NotMinter();
    /// @dev Reverted by onlyBurner when caller lacks the burner role.
    error NotBurner();
    /// @dev Reverted by onlyGovernance when caller is not Authority.owner().
    error NotGovernance();
    /// @dev Reverted by mint() when executing the mint would push
    ///      totalSupply() above the time-based cap. patch_bundle10_5_part2a_timecap
    error MintExceedsTimeWindowCap(uint256 totalSupplyAfter, uint256 maxAllowedNow);

    /// @notice Emitted on every successful mint. Makes cap utilization
    ///         legible from chain logs (worker shaving, monitoring).
    /// patch_bundle10_5_part2a_timecap
    event MintExecuted(address indexed to, uint256 amount, uint256 totalSupplyAfter, uint256 maxAllowedNow);

    /// @custom:oz-upgrades-unsafe-allow constructor
    /// patch_bundle10_5_part2a_timecap + patch_bundle10_5_part2a_stakeengine_exempt: immutables set
    /// here; identical across future impls. inceptionSupply_ in wei;
    /// growthBasePerYear_ in UD60x18; stakeEngine_ is exempt from the
    /// cap (pass address(0) to make every minter capped, e.g. for
    /// testing or token-only deploys).
    constructor(
        address trustedForwarder_,
        uint256 inceptionTimestamp_,
        uint256 inceptionSupply_,
        uint256 growthBasePerYear_,
        address stakeEngine_
    ) ERC2771ContextUpgradeable(trustedForwarder_) {
        INCEPTION_TIMESTAMP = inceptionTimestamp_;
        INCEPTION_SUPPLY = inceptionSupply_;
        GROWTH_BASE_PER_YEAR = growthBasePerYear_;
        STAKE_ENGINE_ADDRESS = stakeEngine_;
        _disableInitializers();
    }

    function initialize(address authority_) external initializer {
        __ERC20_init("Verisphere", "VSP");
        __ERC20Permit_init("Verisphere");
        authority = Authority(authority_);
    }

    modifier onlyMinter() {
        if (!authority.isMinter(_msgSender())) {
            revert NotMinter();
        }
        _;
    }

    modifier onlyBurner() {
        if (!authority.isBurner(_msgSender())) {
            revert NotBurner();
        }
        _;
    }

    modifier onlyGovernance() {
        if (authority.owner() != _msgSender()) {
            revert NotGovernance();
        }
        _;
    }

    /// @notice The maximum total supply permitted at the current block
    ///         timestamp under the time-based growth cap. Workers read
    ///         this to size (and shave) mints. patch_bundle10_5_part2a_timecap
    /// @return maxAllowed total-supply ceiling right now, in wei.
    function maxAllowedSupply() public view returns (uint256) {
        uint256 ts = block.timestamp;
        if (ts <= INCEPTION_TIMESTAMP) {
            return INCEPTION_SUPPLY;
        }
        uint256 elapsed = ts - INCEPTION_TIMESTAMP;
        // yearsElapsed as UD60x18 fraction = elapsed / SECONDS_PER_YEAR
        UD60x18 yearsElapsed = ud(elapsed * 1e18 / SECONDS_PER_YEAR);
        // multiplier = GROWTH_BASE_PER_YEAR ^ yearsElapsed (both UD60x18)
        UD60x18 multiplier = ud(GROWTH_BASE_PER_YEAR).pow(yearsElapsed);
        // maxAllowed = INCEPTION_SUPPLY (wei) * multiplier (UD60x18) / 1e18
        return (INCEPTION_SUPPLY * multiplier.unwrap()) / 1e18;
    }

    function mint(address to, uint256 amount) external onlyMinter {
        // patch_bundle10_5_part2a_timecap + patch_bundle10_5_part2a_stakeengine_exempt: time-based
        // cap is the single mint bound for capped minters.
        // STAKE_ENGINE_ADDRESS is exempt — it mints in response to
        // honest staker activity, and bounding those mints would break
        // withdrawals when supply approaches the curve.
        // _msgSender() (not msg.sender) so meta-tx routing of engine
        // calls resolves to STAKE_ENGINE_ADDRESS, not the forwarder.
        uint256 supplyAfter = totalSupply() + amount;
        uint256 maxAllowed = maxAllowedSupply();
        if (_msgSender() != STAKE_ENGINE_ADDRESS) {
            if (supplyAfter > maxAllowed) {
                revert MintExceedsTimeWindowCap(supplyAfter, maxAllowed);
            }
        }
        _mint(to, amount);
        emit MintExecuted(to, amount, supplyAfter, maxAllowed);
    }

    function burn(uint256 amount) external onlyBurner {
        _burn(_msgSender(), amount);
    }

    function burnFrom(address from, uint256 amount) external onlyBurner {
        _spendAllowance(from, _msgSender(), amount);
        _burn(from, amount);
    }

    function _authorizeUpgrade(address) internal override onlyGovernance {}

    function _msgSender() internal view override(ContextUpgradeable, ERC2771ContextUpgradeable) returns (address) {
        return ERC2771ContextUpgradeable._msgSender();
    }

    function _msgData() internal view override(ContextUpgradeable, ERC2771ContextUpgradeable) returns (bytes calldata) {
        return ERC2771ContextUpgradeable._msgData();
    }

    function _contextSuffixLength()
        internal
        view
        override(ContextUpgradeable, ERC2771ContextUpgradeable)
        returns (uint256)
    {
        return ERC2771ContextUpgradeable._contextSuffixLength();
    }

    uint256[500] private __gap;
}
