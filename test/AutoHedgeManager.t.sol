// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {AutoHedgeManager} from "../src/examples/AutoHedgeManager.sol";
import {UniV3DeltaMath} from "../src/autohedge/UniV3DeltaMath.sol";
import {PrecompileLib} from "../src/PrecompileLib.sol";
import {HLConstants} from "../src/common/HLConstants.sol";
import {ITokenRegistry} from "../src/interfaces/ITokenRegistry.sol";

contract AutoHedgeManagerTest is Test {
    AutoHedgeManager manager;
    address constant vault = address(0xdead);
    address constant token0 = address(0x123);
    address constant quote = address(0x456);
    uint32 constant perpIndex = 1;

    uint256 constant Q96 = 2**96;

    function setUp() public {
        manager = new AutoHedgeManager(address(this));
        manager.setRebalancer(address(this));

        // Mock token registry lookup
        address registry = 0x0b51d1A9098cf8a72C325003F44C194D41d7A85B;
        vm.mockCall(
            registry,
            abi.encodeWithSelector(ITokenRegistry.getTokenIndex.selector, token0),
            abi.encode(uint32(1))
        );

        // Mock token info precompile
        PrecompileLib.TokenInfo memory ti;
        ti.name = "uTKN";
        ti.spots = new uint64[](1);
        ti.spots[0] = 0;
        ti.deployerTradingFeeShare = 0;
        ti.deployer = address(0);
        ti.evmContract = token0;
        ti.szDecimals = 6;
        ti.weiDecimals = 6;
        ti.evmExtraWeiDecimals = 0;
        vm.mockCall(
            HLConstants.TOKEN_INFO_PRECOMPILE_ADDRESS,
            abi.encode(uint64(1)),
            abi.encode(ti)
        );

        // Mock perp asset info
        PrecompileLib.PerpAssetInfo memory pinfo;
        pinfo.coin = "TKN";
        pinfo.marginTableId = 0;
        pinfo.szDecimals = 6;
        pinfo.maxLeverage = 50;
        pinfo.onlyIsolated = false;
        vm.mockCall(
            HLConstants.PERP_ASSET_INFO_PRECOMPILE_ADDRESS,
            abi.encode(perpIndex),
            abi.encode(pinfo)
        );

        // Mock position precompile
        PrecompileLib.Position memory pos;
        pos.szi = 0;
        pos.entryNtl = 0;
        pos.isolatedRawUsd = 0;
        pos.leverage = 0;
        pos.isIsolated = false;
        vm.mockCall(
            HLConstants.POSITION_PRECOMPILE_ADDRESS,
            abi.encode(address(manager), perpIndex),
            abi.encode(pos)
        );

        // Mock mark price
        vm.mockCall(
            HLConstants.MARK_PX_PRECOMPILE_ADDRESS,
            abi.encode(perpIndex),
            abi.encode(uint64(2000))
        );

        // Mock CoreWriter sendRawAction
        vm.mockCall(
            address(0x3333333333333333333333333333333333333333),
            bytes("") ,
            abi.encode()
        );

        manager.configureVault(vault, token0, quote, perpIndex, 10000, 50);
    }

    function test_updateRangesAndRebalance_setsTarget() public {
        UniV3DeltaMath.Range[] memory ranges = new UniV3DeltaMath.Range[](1);
        ranges[0] = UniV3DeltaMath.Range({
            sqrtPaX96: uint160(Q96),
            sqrtPbX96: uint160(Q96 * 2),
            liquidity: 1e6
        });
        uint160 sqrtP = uint160(Q96 * 3 / 2);

        vm.expectCall(address(0x3333333333333333333333333333333333333333), bytes(""));

        manager.updateRangesAndRebalance(vault, ranges, sqrtP, 0);

        assertEq(manager.lastTargetSz(vault), -166667);
    }

    function test_optInAndOut() public {
        assertEq(manager.enabledUsers(vault), 0);

        manager.optIn(vault);
        assertEq(manager.enabledUsers(vault), 1);
        assertTrue(manager.isUserEnabled(vault, address(this)));

        manager.optOut(vault);
        assertEq(manager.enabledUsers(vault), 0);
        assertFalse(manager.isUserEnabled(vault, address(this)));
    }

    function test_rebalanceWithParticipationFraction() public {
        manager.setParticipationBps(vault, 0);
        manager.setTotals(vault, 10);
        for (uint256 i = 0; i < 5; i++) {
            address user = address(uint160(i + 1));
            vm.prank(user);
            manager.optIn(vault);
        }

        UniV3DeltaMath.Range[] memory ranges = new UniV3DeltaMath.Range[](1);
        ranges[0] = UniV3DeltaMath.Range({
            sqrtPaX96: uint160(Q96),
            sqrtPbX96: uint160(Q96 * 2),
            liquidity: 1e6
        });
        uint160 sqrtP = uint160(Q96 * 3 / 2);

        vm.expectCall(address(0x3333333333333333333333333333333333333333), bytes(""));
        manager.updateRangesAndRebalance(vault, ranges, sqrtP, 0);

        assertEq(manager.lastTargetSz(vault), -83333);
    }

    function test_rebalanceWithPrice_updatesTarget() public {
        UniV3DeltaMath.Range[] memory ranges = new UniV3DeltaMath.Range[](1);
        ranges[0] = UniV3DeltaMath.Range({
            sqrtPaX96: uint160(Q96),
            sqrtPbX96: uint160(Q96 * 2),
            liquidity: 1e6
        });
        uint160 sqrtP = uint160(Q96 * 3 / 2);

        vm.expectCall(address(0x3333333333333333333333333333333333333333), bytes(""));
        manager.updateRangesAndRebalance(vault, ranges, sqrtP, 0);

        // pretend hedge was executed
        PrecompileLib.Position memory pos;
        pos.szi = -166667;
        vm.mockCall(
            HLConstants.POSITION_PRECOMPILE_ADDRESS,
            abi.encode(address(manager), perpIndex),
            abi.encode(pos)
        );

        uint160 newSqrtP = uint160(Q96 * 3);
        vm.expectCall(address(0x3333333333333333333333333333333333333333), bytes(""));
        manager.rebalanceWithPrice(vault, newSqrtP, 0);

        assertEq(manager.lastTargetSz(vault), 0);
    }

    function test_noRebalanceWhenNoParticipants() public {
        manager.setParticipationBps(vault, 0);

        UniV3DeltaMath.Range[] memory ranges = new UniV3DeltaMath.Range[](1);
        ranges[0] = UniV3DeltaMath.Range({
            sqrtPaX96: uint160(Q96),
            sqrtPbX96: uint160(Q96 * 2),
            liquidity: 1e6
        });
        uint160 sqrtP = uint160(Q96 * 3 / 2);

        vm.expectCall(address(0x3333333333333333333333333333333333333333), bytes(""), 0);
        manager.updateRangesAndRebalance(vault, ranges, sqrtP, 0);

        assertEq(manager.lastTargetSz(vault), 0);
    }
}
