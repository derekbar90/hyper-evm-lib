// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {FullMath} from "../src/autohedge/FullMath.sol";

contract FullMathTest is Test {
    function test_mulDiv() public {
        uint256 result = FullMath.mulDiv(4, 5, 2);
        assertEq(result, 10);
    }

    function test_mulDivRoundingUp() public {
        uint256 result = FullMath.mulDivRoundingUp(5, 5, 2);
        assertEq(result, 13);
    }

    function test_mulDiv_largeNumbers() public {
        uint256 a = 1 << 200;
        uint256 b = 1 << 200;
        uint256 d = 1 << 150;
        uint256 result = FullMath.mulDiv(a, b, d);
        assertEq(result, 1 << 250);
    }
}
