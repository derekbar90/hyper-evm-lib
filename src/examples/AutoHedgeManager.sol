// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * AutoHedgeManager
 * ----------------
 * Users opt-in (delegate) to hedging for a given Steer vault.
 * Steer/keeper submits the vault's Uniswap v3 ranges (sqrt prices + liquidity).
 * Contract computes token0 delta and rebalances a Hyperliquid perp position to target:
 *      targetSz = - (token0_delta) * participation_fraction  (converted to perp sz decimals)
 * Funds: simple USDC deposit -> bridge to Core -> move to perp margin (optional, but provided).
 */
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {CoreWriterLib} from "@hyper-evm-lib/src/CoreWriterLib.sol";
import {PrecompileLib} from "@hyper-evm-lib/src/PrecompileLib.sol";
import {HLConstants} from "@hyper-evm-lib/src/common/HLConstants.sol";
import {HLConversions} from "@hyper-evm-lib/src/common/HLConversions.sol";

import {UniV3DeltaMath} from "../autohedge/UniV3DeltaMath.sol";

contract AutoHedgeManager is Ownable {
    using CoreWriterLib for *;

    // --- constants / config ---
    uint64 public constant USDC_TOKEN_ID = 0;

    struct VaultConfig {
        // Base/quote for price discovery on HyperEVM (must be registered in TokenRegistry)
        address token0OnHL; // e.g., uETH (base)
        address quoteOnHL; // e.g., USDC (quote), usually aligned with USDC_TOKEN_ID
        uint32 perpIndex; // Hyperliquid perp asset id, e.g. ETH-PERP index
        uint8 token0WeiDecimals; // decimals for token0 on HL core (for size conversion)
        // Participation
        uint16 participationBps; // optional override; 0 => use enabledUsers/totalUsers
        uint32 slippageBps; // default slippage bps for IOC orders
        bool exists;
    }

    // Ranges per vault (in storage)
    mapping(address => UniV3DeltaMath.Range[]) internal _ranges;

    // Vault metadata
    mapping(address => VaultConfig) public vaultConfig;

    // Participation (opt-in) accounting
    mapping(address => uint256) public totalUsers; // per vault: denominator (can be LP supply buckets if you want)
    mapping(address => uint256) public enabledUsers; // per vault: number enabled
    mapping(address => mapping(address => bool)) public isUserEnabled; // vault => user => bool

    // Last target hedge size we aimed for (perp sz units, signed)
    mapping(address => int64) public lastTargetSz;

    // Roles
    address public rebalancer; // allowed to push new ranges + trigger rebalances
    address public keeper; // allowed to trigger rebalances

    // --- events ---
    event VaultConfigured(
        address indexed vault,
        address token0,
        address quote,
        uint32 perpIndex,
        uint16 participationBps,
        uint32 slippageBps
    );
    event UserOptIn(address indexed vault, address indexed user);
    event UserOptOut(address indexed vault, address indexed user);
    event TotalsUpdated(address indexed vault, uint256 totalUsers, uint256 enabledUsers, uint16 effectiveBps);
    event RangesUpdated(address indexed vault, uint256 nRanges, uint160 sqrtPX96, uint256 token0Delta);
    event Rebalanced(
        address indexed vault,
        int64 targetSz,
        int64 currentSz,
        int64 deltaSz,
        bool isBuy,
        uint64 limitPx,
        uint64 szPlaced,
        uint8 tif
    );

    // --- modifiers ---
    modifier onlyRebalancer() {
        require(msg.sender == rebalancer || msg.sender == owner(), "not rebalancer");
        _;
    }

    modifier onlyKeeper() {
        require(msg.sender == keeper || msg.sender == rebalancer || msg.sender == owner(), "not keeper");
        _;
    }

    constructor(address _owner) Ownable(_owner) {}

    // -------------------------------------------------
    // Admin / roles
    // -------------------------------------------------
    function setRebalancer(address who) external onlyOwner {
        rebalancer = who;
    }

    function setKeeper(address who) external onlyOwner {
        keeper = who;
    }

    /// @notice Configure a vault mapping to a Hyperliquid perp + spot pair
    function configureVault(
        address vault,
        address token0OnHL,
        address quoteOnHL,
        uint32 perpIndex,
        uint16 participationBps, // set 0 to compute from opt-ins
        uint32 slippageBps // default IOC slippage on orders
    ) external onlyOwner {
        // pull decimals from HL precompile, ensures token is registered
        PrecompileLib.TokenInfo memory t0 = PrecompileLib.tokenInfo(token0OnHL);

        VaultConfig storage cfg = vaultConfig[vault];
        cfg.token0OnHL = token0OnHL;
        cfg.quoteOnHL = quoteOnHL;
        cfg.perpIndex = perpIndex;
        cfg.token0WeiDecimals = t0.weiDecimals;
        cfg.participationBps = participationBps;
        cfg.slippageBps = slippageBps;
        cfg.exists = true;

        emit VaultConfigured(vault, token0OnHL, quoteOnHL, perpIndex, participationBps, slippageBps);
    }

    function setParticipationBps(address vault, uint16 bps) external onlyOwner {
        require(vaultConfig[vault].exists, "vault !exists");
        vaultConfig[vault].participationBps = bps;
        emit TotalsUpdated(vault, totalUsers[vault], enabledUsers[vault], effectiveParticipationBps(vault));
    }

    function setTotals(address vault, uint256 newTotalUsers) external onlyOwner {
        require(vaultConfig[vault].exists, "vault !exists");
        totalUsers[vault] = newTotalUsers;
        emit TotalsUpdated(vault, newTotalUsers, enabledUsers[vault], effectiveParticipationBps(vault));
    }

    // -------------------------------------------------
    // User delegation (opt-in / opt-out)
    // -------------------------------------------------
    function optIn(address vault) external {
        require(vaultConfig[vault].exists, "vault !exists");
        if (!isUserEnabled[vault][msg.sender]) {
            isUserEnabled[vault][msg.sender] = true;
            enabledUsers[vault] += 1;
            emit UserOptIn(vault, msg.sender);
            emit TotalsUpdated(vault, totalUsers[vault], enabledUsers[vault], effectiveParticipationBps(vault));
        }
    }

    function optOut(address vault) external {
        require(vaultConfig[vault].exists, "vault !exists");
        if (isUserEnabled[vault][msg.sender]) {
            isUserEnabled[vault][msg.sender] = false;
            enabledUsers[vault] -= 1;
            emit UserOptOut(vault, msg.sender);
            emit TotalsUpdated(vault, totalUsers[vault], enabledUsers[vault], effectiveParticipationBps(vault));
        }
    }

    function effectiveParticipationBps(address vault) public view returns (uint16 bps) {
        VaultConfig memory cfg = vaultConfig[vault];
        if (cfg.participationBps > 0) {
            return cfg.participationBps;
        }
        // fallback: proportional to #enabled users (avoid div-by-zero)
        uint256 tot = totalUsers[vault];
        if (tot == 0) return 0;
        uint256 eff = enabledUsers[vault] * 10000 / tot;
        if (eff > 10000) eff = 10000;
        return uint16(eff);
    }

    // -------------------------------------------------
    // Range intake + rebalance
    // -------------------------------------------------

    /// @notice Replace all stored ranges for a vault and immediately hedge to target.
    /// @param vault the Steer vault id (arbitrary address key)
    /// @param newRanges array of Uniswap v3 ranges
    /// @param sqrtPX96 current sqrt price (Q64.96) for the pool (token0 quoted in token1)
    /// @param overrideSlippageBps set 0 to use cfg.slippageBps
    function updateRangesAndRebalance(
        address vault,
        UniV3DeltaMath.Range[] calldata newRanges,
        uint160 sqrtPX96,
        uint32 overrideSlippageBps
    ) external onlyRebalancer {
        require(vaultConfig[vault].exists, "vault !exists");

        // replace ranges
        delete _ranges[vault];
        for (uint256 i = 0; i < newRanges.length; ++i) {
            _ranges[vault].push(newRanges[i]);
        }

        // compute LP token0 exposure
        uint256 token0Delta = UniV3DeltaMath.sumAmount0(newRanges, sqrtPX96);
        emit RangesUpdated(vault, newRanges.length, sqrtPX96, token0Delta);

        // hedge to target
        _rebalanceToTarget(vault, token0Delta, overrideSlippageBps);
    }

    /// @notice Re-hedge a vault using its LAST stored ranges and a fresh sqrt price.
    function rebalanceWithPrice(address vault, uint160 sqrtPX96, uint32 overrideSlippageBps) external onlyKeeper {
        require(vaultConfig[vault].exists, "vault !exists");
        UniV3DeltaMath.Range[] storage ranges = _ranges[vault];
        require(ranges.length > 0, "no ranges");

        // copy to memory for math
        UniV3DeltaMath.Range[] memory m = new UniV3DeltaMath.Range[](ranges.length);
        for (uint256 i = 0; i < ranges.length; ++i) {
            m[i] = ranges[i];
        }

        uint256 token0Delta = UniV3DeltaMath.sumAmount0(m, sqrtPX96);
        emit RangesUpdated(vault, m.length, sqrtPX96, token0Delta);

        _rebalanceToTarget(vault, token0Delta, overrideSlippageBps);
    }

    /// @dev core hedge logic: compute target perp size and place IOC order to move there
    function _rebalanceToTarget(
        address vault,
        uint256 token0Delta, // in token0 minimal units
        uint32 overrideSlippageBps
    ) internal {
        VaultConfig memory cfg = vaultConfig[vault];
        uint16 partBps = effectiveParticipationBps(vault);
        if (partBps == 0) {
            // nothing to do (no participants)
            return;
        }

        // Convert token0 units -> perp sz units
        PrecompileLib.PerpAssetInfo memory ainfo = PrecompileLib.perpAssetInfo(cfg.perpIndex);
        uint8 szDecimals = ainfo.szDecimals;

        // scale: perpSz = token0Delta * 10^szDecimals / 10^token0WeiDecimals
        uint256 scaled = token0Delta;
        if (szDecimals >= cfg.token0WeiDecimals) {
            scaled = token0Delta * (10 ** (szDecimals - cfg.token0WeiDecimals));
        } else {
            scaled = token0Delta / (10 ** (cfg.token0WeiDecimals - szDecimals));
        }

        // apply participation fraction: targetSz = -scaled * partBps / 1e4
        int256 targetSzSigned = -int256(scaled * partBps / 10000);

        // current perp position size (signed)
        PrecompileLib.Position memory pos = PrecompileLib.position(address(this), uint16(cfg.perpIndex));
        int256 currentSz = int256(pos.szi);

        int256 deltaSz = targetSzSigned - currentSz;
        if (deltaSz == 0) {
            lastTargetSz[vault] = int64(targetSzSigned);
            emit Rebalanced(vault, int64(targetSzSigned), int64(currentSz), 0, false, 0, 0, 0);
            return;
        }

        bool isBuy = deltaSz > 0;
        uint64 sz = uint64(deltaSz > 0 ? uint256(deltaSz) : uint256(-deltaSz));

        // price: use perp markPx with IOC slippage bump
        uint64 px = PrecompileLib.markPx(cfg.perpIndex);
        uint32 slip = overrideSlippageBps > 0 ? overrideSlippageBps : cfg.slippageBps;
        uint64 limitPx = _withSlippage(px, slip, isBuy);

        // place IOC order
        CoreWriterLib.placeLimitOrder(
            cfg.perpIndex,
            isBuy,
            limitPx,
            sz,
            false, // reduceOnly
            HLConstants.LIMIT_ORDER_TIF_IOC,
            _cloid(vault, targetSzSigned, sz)
        );

        lastTargetSz[vault] = int64(targetSzSigned);
        emit Rebalanced(
            vault,
            int64(targetSzSigned),
            int64(currentSz),
            int64(deltaSz),
            isBuy,
            limitPx,
            sz,
            HLConstants.LIMIT_ORDER_TIF_IOC
        );
    }

    function _withSlippage(uint64 px, uint32 bps, bool up) internal pure returns (uint64) {
        if (bps == 0) return px;
        uint256 num = uint256(px) * (up ? (10000 + bps) : (10000 - bps));
        return uint64(num / 10000);
    }

    function _cloid(address vault, int256 targetSz, uint64 sz) internal view returns (uint128) {
        // cheap-ish unique client order id
        return uint128(uint256(keccak256(abi.encodePacked(block.number, vault, targetSz, sz, address(this)))));
    }

    // -------------------------------------------------
    // Margin ops (optional helpers)
    // -------------------------------------------------

    /// @notice Deposit EVM USDC to this contract, bridge to Core, and move to perp margin.
    /// @dev Caller must approve this contract to spend `evmAmount` on the EVM USDC token.
    function depositPerpMarginUSDC(address usdcEvmToken, uint256 evmAmount) external {
        require(evmAmount > 0, "zero");
        IERC20(usdcEvmToken).transferFrom(msg.sender, address(this), evmAmount);

        // Bridge to Core
        CoreWriterLib.bridgeToCore(usdcEvmToken, evmAmount);

        // Convert to Core and then Perp units
        uint64 tokenIndex = PrecompileLib.getTokenIndex(usdcEvmToken);
        uint64 coreAmount = HLConversions.convertEvmToCoreAmount(tokenIndex, evmAmount);
        uint64 perpAmount = HLConversions.convertUSDC_CoreToPerp(coreAmount);

        // Move to perp account
        CoreWriterLib.transferUsdClass(perpAmount, true);
    }

    /// @notice Move USDC from perp back to EVM (best-effort; assumes sufficient withdrawable).
    /// @param coreAmount amount in Core USDC units to withdraw to EVM.
    /// @dev For non-HYPE tokens, ensure the contract holds some HYPE on core for transfer gas.
    function withdrawUSDCToEvm(uint64 coreAmount, address usdcEvmToken) external onlyOwner {
        // Move from perp to spot (Core)
        uint64 perpAmount = HLConversions.convertUSDC_CoreToPerp(coreAmount);
        CoreWriterLib.transferUsdClass(perpAmount, false);

        // Bridge to EVM using EVM amount (convert Core->EVM)
        uint64 tokenIndex = PrecompileLib.getTokenIndex(usdcEvmToken);
        uint256 evmAmount = HLConversions.convertCoreToEvmAmount(tokenIndex, coreAmount);
        CoreWriterLib.bridgeToEvm(usdcEvmToken, evmAmount);
    }

    // -------------------------------------------------
    // Views
    // -------------------------------------------------
    function getRanges(address vault) external view returns (UniV3DeltaMath.Range[] memory out) {
        UniV3DeltaMath.Range[] storage s = _ranges[vault];
        out = new UniV3DeltaMath.Range[](s.length);
        for (uint256 i = 0; i < s.length; ++i) {
            out[i] = s[i];
        }
    }
}
