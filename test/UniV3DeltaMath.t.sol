// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {UniV3DeltaMath} from "../src/autohedge/UniV3DeltaMath.sol";

contract UniV3DeltaMathTest is Test {
    uint256 constant Q96 = 2**96;

    function callAmount0(UniV3DeltaMath.Range memory r, uint160 sqrtP) external pure returns (uint256) {
        return UniV3DeltaMath.amount0InRange(r, sqrtP);
    }

    function test_amount0InRange_partial() public {
        UniV3DeltaMath.Range memory r = UniV3DeltaMath.Range({
            sqrtPaX96: uint160(Q96),
            sqrtPbX96: uint160(Q96 * 2),
            liquidity: 1e6
        });
        uint160 sqrtP = uint160(Q96 * 3 / 2);
        uint256 amt = UniV3DeltaMath.amount0InRange(r, sqrtP);
        assertEq(amt, 166667);
    }

    function test_amount0InRange_fullyToken0() public {
        UniV3DeltaMath.Range memory r = UniV3DeltaMath.Range({
            sqrtPaX96: uint160(Q96),
            sqrtPbX96: uint160(Q96 * 2),
            liquidity: 1e6
        });
        uint160 sqrtP = uint160(Q96 / 2);
        uint256 amt = UniV3DeltaMath.amount0InRange(r, sqrtP);
        assertEq(amt, 500000);
    }

    function test_amount0InRange_fullyToken1() public {
        UniV3DeltaMath.Range memory r = UniV3DeltaMath.Range({
            sqrtPaX96: uint160(Q96),
            sqrtPbX96: uint160(Q96 * 2),
            liquidity: 1e6
        });
        uint160 sqrtP = uint160(Q96 * 3);
        uint256 amt = UniV3DeltaMath.amount0InRange(r, sqrtP);
        assertEq(amt, 0);
    }

    function test_amount0InRange_invalidRangeReverts() public {
        UniV3DeltaMath.Range memory r = UniV3DeltaMath.Range({
            sqrtPaX96: uint160(Q96 * 2),
            sqrtPbX96: uint160(Q96),
            liquidity: 1e6
        });
        uint160 sqrtP = uint160(Q96 / 2);
        vm.expectRevert(UniV3DeltaMath.InvalidRange.selector);
        this.callAmount0(r, sqrtP);
    }

    function test_sumAmount0_twoRanges() public {
        UniV3DeltaMath.Range[] memory ranges = new UniV3DeltaMath.Range[](2);
        ranges[0] = UniV3DeltaMath.Range({sqrtPaX96: uint160(Q96), sqrtPbX96: uint160(Q96 * 2), liquidity: 1e6});
        ranges[1] = UniV3DeltaMath.Range({sqrtPaX96: uint160(Q96), sqrtPbX96: uint160(Q96 * 2), liquidity: 2e6});

        uint160 sqrtP = uint160(Q96 * 3 / 2);
        uint256 total = UniV3DeltaMath.sumAmount0(ranges, sqrtP);
        assertEq(total, 500001);
    }
}
