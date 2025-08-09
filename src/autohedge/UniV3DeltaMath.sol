// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./FullMath.sol";

/// @notice Minimal Uniswap v3 delta helpers (token0 only)
library UniV3DeltaMath {
    using FullMath for uint256;

    struct Range {
        uint160 sqrtPaX96; // lower sqrt price in Q64.96
        uint160 sqrtPbX96; // upper sqrt price in Q64.96
        uint128 liquidity; // Uniswap v3 liquidity units
    }

    error InvalidRange();

    /// @notice amount0 for liquidity across [sqrtA, sqrtB]
    function _amount0ForLiquidity(uint160 sqrtAX96, uint160 sqrtBX96, uint128 liquidity)
        private
        pure
        returns (uint256 amount0)
    {
        if (sqrtAX96 >= sqrtBX96) revert InvalidRange();
        // amount0 = L * (sqrtB - sqrtA) / (sqrtB * sqrtA) * 2^96
        // Implemented as: (liquidity << 96) * (sqrtB - sqrtA) / (sqrtB * sqrtA)
        uint256 numerator = (uint256(liquidity) << 96) * (sqrtBX96 - sqrtAX96);
        uint256 denominator = uint256(sqrtBX96) * uint256(sqrtAX96);
        amount0 = FullMath.mulDivRoundingUp(numerator, 1, denominator);
    }

    /// @notice token0 inventory (delta) of a single v3 range at sqrtP.
    /// Returns amount0 > 0 when holding token0.
    function amount0InRange(Range memory r, uint160 sqrtPX96) internal pure returns (uint256 amount0) {
        if (sqrtPX96 <= r.sqrtPaX96) {
            // Fully token0
            return _amount0ForLiquidity(r.sqrtPaX96, r.sqrtPbX96, r.liquidity);
        } else if (sqrtPX96 >= r.sqrtPbX96) {
            // Fully token1
            return 0;
        } else {
            // Partially invested: [sqrtP, sqrtB]
            return _amount0ForLiquidity(sqrtPX96, r.sqrtPbX96, r.liquidity);
        }
    }

    /// @notice Sum token0 across many ranges
    function sumAmount0(Range[] memory ranges, uint160 sqrtPX96) internal pure returns (uint256 total0) {
        uint256 n = ranges.length;
        for (uint256 i = 0; i < n; ++i) {
            total0 += amount0InRange(ranges[i], sqrtPX96);
        }
    }
}
