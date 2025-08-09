// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice 512-bit mulDiv utilities (subset of Uniswap's FullMath)
library FullMath {
    /// @notice Calculates floor(a×b÷denominator) with full precision.
    /// @dev Reverts if denominator == 0 or result overflows 256 bits.
    function mulDiv(uint256 a, uint256 b, uint256 denominator) internal pure returns (uint256 result) {
        unchecked {
            uint256 prod0; // Least significant 256 bits
            uint256 prod1; // Most significant 256 bits
            assembly {
                let mm := mulmod(a, b, not(0))
                prod0 := mul(a, b)
                prod1 := sub(sub(mm, prod0), lt(mm, prod0))
            }
            if (prod1 == 0) {
                require(denominator > 0, "div/0");
                assembly {
                    result := div(prod0, denominator)
                }
                return result;
            }
            require(denominator > prod1, "overflow");

            // Make division exact by subtracting the remainder from [prod1 prod0]
            uint256 remainder;
            assembly {
                remainder := mulmod(a, b, denominator)
                prod1 := sub(prod1, gt(remainder, prod0))
                prod0 := sub(prod0, remainder)
            }

            // Factor powers of two out of denominator and compute largest power of two divisor of denominator.
            uint256 twos = denominator & (~denominator + 1);
            assembly {
                denominator := div(denominator, twos)
                prod0 := div(prod0, twos)
                twos := add(div(sub(0, twos), twos), 1)
            }
            prod0 |= prod1 * twos;

            // Invert denominator mod 2^256 and multiply by prod0
            uint256 inv = (3 * denominator) ^ 2;
            inv *= 2 - denominator * inv; // inverse mod 2^8
            inv *= 2 - denominator * inv; // 2^16
            inv *= 2 - denominator * inv; // 2^32
            inv *= 2 - denominator * inv; // 2^64
            inv *= 2 - denominator * inv; // 2^128
            inv *= 2 - denominator * inv; // 2^256

            result = prod0 * inv;
            return result;
        }
    }

    /// @notice ceil(a×b÷denominator) with full precision.
    function mulDivRoundingUp(uint256 a, uint256 b, uint256 denominator) internal pure returns (uint256 result) {
        result = mulDiv(a, b, denominator);
        unchecked {
            if (mulmod(a, b, denominator) > 0) {
                require(result < type(uint256).max, "ru overflow");
                result++;
            }
        }
    }
}
