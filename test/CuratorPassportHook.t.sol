// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {SlippageCheck} from "@uniswap/v4-periphery/src/libraries/SlippageCheck.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {Position} from "@uniswap/v4-core/src/libraries/Position.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";

import {CuratorPassportHook} from "../src/CuratorPassportHook.sol";
import {CuratorPassportFixture} from "./utils/CuratorPassportFixture.sol";
import {EasyPosm} from "./utils/libraries/EasyPosm.sol";

contract CuratorPassportHookTest is CuratorPassportFixture {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;

    function test_positiveAndRepeatedAdditions() public {
        uint256 tokenId = _mint(key, INITIAL_LIQUIDITY, "");
        assertEq(hook.liquidityAdditions(poolId), 1);
        assertEq(hook.liquidityRemovals(poolId), 0);
        assertEq(_liquidity(poolId, tokenId), INITIAL_LIQUIDITY);

        positionManager.increaseLiquidity(tokenId, 1e18, type(uint128).max, type(uint128).max, block.timestamp, "");
        assertEq(hook.liquidityAdditions(poolId), 2);
        assertEq(hook.liquidityRemovals(poolId), 0);
        assertEq(_liquidity(poolId, tokenId), INITIAL_LIQUIDITY + 1e18);
    }

    function test_partialRepeatedAndFullRemovals() public {
        uint256 tokenId = _mint(key, INITIAL_LIQUIDITY, "");
        positionManager.decreaseLiquidity(tokenId, 1e18, 0, 0, address(this), block.timestamp, "");
        assertEq(hook.liquidityRemovals(poolId), 1);
        assertEq(_liquidity(poolId, tokenId), INITIAL_LIQUIDITY - 1e18);

        positionManager.decreaseLiquidity(tokenId, INITIAL_LIQUIDITY - 1e18, 0, 0, address(this), block.timestamp, "");
        assertEq(hook.liquidityRemovals(poolId), 2);
        assertEq(hook.liquidityAdditions(poolId), 1);
        assertEq(_liquidity(poolId, tokenId), 0);
    }

    function test_zeroDeltaIsNotRemovalOrEvidenceOfFees() public {
        uint256 tokenId = _mint(key, INITIAL_LIQUIDITY, "");
        BalanceDelta delta = positionManager.collect(tokenId, 0, 0, address(this), block.timestamp, "");
        // There were no swaps/donations: this zero-delta operation collected no fees.
        assertEq(delta.amount0(), 0);
        assertEq(delta.amount1(), 0);
        assertEq(_liquidity(poolId, tokenId), INITIAL_LIQUIDITY);
        assertEq(hook.liquidityAdditions(poolId), 1);
        assertEq(hook.liquidityRemovals(poolId), 0);
    }

    function test_eventsClassifyOperationsAndReportPositionManager() public {
        vm.recordLogs();
        uint256 tokenId = _mint(key, INITIAL_LIQUIDITY, abi.encode(address(0xBEEF)));
        _assertObservation(vm.getRecordedLogs(), poolId, address(positionManager), 0);

        vm.recordLogs();
        positionManager.decreaseLiquidity(tokenId, 1, 0, 0, address(this), block.timestamp, hex"ff");
        _assertObservation(vm.getRecordedLogs(), poolId, address(positionManager), 1);

        vm.recordLogs();
        positionManager.collect(tokenId, 0, 0, address(this), block.timestamp, "untrusted");
        _assertObservation(vm.getRecordedLogs(), poolId, address(positionManager), 2);
    }

    function test_repeatedZeroDeltaHasSeparateCounter() public {
        uint256 tokenId = _mint(key, INITIAL_LIQUIDITY, "");
        positionManager.collect(tokenId, 0, 0, address(this), block.timestamp, "");
        positionManager.collect(tokenId, 0, 0, address(this), block.timestamp, "");
        assertEq(hook.zeroDeltaModifications(poolId), 2);
        assertEq(hook.liquidityAdditions(poolId), 1);
        assertEq(hook.liquidityRemovals(poolId), 0);
        assertEq(_liquidity(poolId, tokenId), INITIAL_LIQUIDITY);
    }

    function test_unauthorizedCallbacksRevert() public {
        ModifyLiquidityParams memory params = ModifyLiquidityParams(LOWER, UPPER, 1, bytes32(0));
        address[2] memory callers = [address(0xBAD), address(positionManager)];
        for (uint256 i; i < callers.length; ++i) {
            vm.expectRevert(BaseHook.NotPoolManager.selector);
            vm.prank(callers[i]);
            hook.beforeAddLiquidity(callers[i], key, params, "");
            params.liquidityDelta = -1;
            vm.expectRevert(BaseHook.NotPoolManager.selector);
            vm.prank(callers[i]);
            hook.beforeRemoveLiquidity(callers[i], key, params, "");
            params.liquidityDelta = 0;
            vm.expectRevert(BaseHook.NotPoolManager.selector);
            vm.prank(callers[i]);
            hook.beforeRemoveLiquidity(callers[i], key, params, abi.encode(address(this)));
            params.liquidityDelta = 1;
        }
        assertEq(hook.liquidityAdditions(poolId), 0);
        assertEq(hook.liquidityRemovals(poolId), 0);
        assertEq(hook.zeroDeltaModifications(poolId), 0);
    }

    function test_create2DeploymentValidatesExactPermissionBits() public {
        (address expected, bytes32 salt) =
            HookMiner.find(address(this), FLAGS, type(CuratorPassportHook).creationCode, abi.encode(poolManager));
        CuratorPassportHook deployed = new CuratorPassportHook{salt: salt}(poolManager);
        assertEq(address(deployed), expected);
        assertEq(uint160(address(deployed)) & Hooks.ALL_HOOK_MASK, FLAGS);
        assertEq(address(deployed.poolManager()), address(poolManager));
        Hooks.Permissions memory expectedPermissions;
        expectedPermissions.beforeAddLiquidity = true;
        expectedPermissions.beforeRemoveLiquidity = true;
        assertEq(abi.encode(deployed.getHookPermissions()), abi.encode(expectedPermissions));

        // Test constructor validation itself, not merely the mining helper.
        (address badAddress, bytes32 badSalt) = HookMiner.find(
            address(this),
            FLAGS | Hooks.BEFORE_SWAP_FLAG,
            type(CuratorPassportHook).creationCode,
            abi.encode(poolManager)
        );
        vm.expectRevert(abi.encodeWithSelector(Hooks.HookAddressNotValid.selector, badAddress));
        new CuratorPassportHook{salt: badSalt}(poolManager);
    }

    function test_failedSlippageRollsBackEarlierAdditionCallback() public {
        uint256 nextId = positionManager.nextTokenId();
        ModifyLiquidityParams memory params =
            ModifyLiquidityParams(LOWER, UPPER, int256(uint256(INITIAL_LIQUIDITY)), bytes32(nextId));
        vm.expectCall(
            address(hook), abi.encodeCall(IHooks.beforeAddLiquidity, (address(positionManager), key, params, bytes("")))
        );
        vm.expectPartialRevert(SlippageCheck.MaximumAmountExceeded.selector);
        this.mintWithZeroSlippage();
        assertEq(hook.liquidityAdditions(poolId), 0);
        assertEq(hook.liquidityRemovals(poolId), 0);
        assertEq(hook.zeroDeltaModifications(poolId), 0);
        assertEq(_liquidity(poolId, nextId), 0);
        assertEq(positionManager.nextTokenId(), nextId);
    }

    function mintWithZeroSlippage() external {
        require(msg.sender == address(this), "self only");
        positionManager.mint(key, LOWER, UPPER, INITIAL_LIQUIDITY, 0, 0, address(this), block.timestamp, "");
    }

    error DeliberateOuterRevert();

    function executeThenRevert(uint256 tokenId) external {
        require(msg.sender == address(this), "self only");
        positionManager.increaseLiquidity(tokenId, 1e18, type(uint128).max, type(uint128).max, block.timestamp, "");
        positionManager.decreaseLiquidity(tokenId, 1e18, 0, 0, address(this), block.timestamp, "");
        positionManager.collect(tokenId, 0, 0, address(this), block.timestamp, "");
        // Prove that all three counters changed before the enclosing call reverts.
        assertEq(hook.liquidityAdditions(poolId), 2);
        assertEq(hook.liquidityRemovals(poolId), 1);
        assertEq(hook.zeroDeltaModifications(poolId), 1);
        revert DeliberateOuterRevert();
    }

    function test_outerRevertRollsBackAllEarlierOperations() public {
        uint256 tokenId = _mint(key, INITIAL_LIQUIDITY, "");
        vm.expectRevert(DeliberateOuterRevert.selector);
        this.executeThenRevert(tokenId);
        assertEq(hook.liquidityAdditions(poolId), 1);
        assertEq(hook.liquidityRemovals(poolId), 0);
        assertEq(hook.zeroDeltaModifications(poolId), 0);
        assertEq(_liquidity(poolId, tokenId), INITIAL_LIQUIDITY);
    }

    function test_interleavedPoolsRemainIndependent() public {
        PoolKey memory second = _secondPool();
        PoolId secondId = second.toId();
        assertNotEq(PoolId.unwrap(secondId), PoolId.unwrap(poolId));
        uint256 firstToken = _mint(key, INITIAL_LIQUIDITY, "");
        assertEq(hook.liquidityAdditions(secondId), 0);
        vm.recordLogs();
        uint256 secondToken = _mint(second, INITIAL_LIQUIDITY, "");
        _assertObservation(vm.getRecordedLogs(), secondId, address(positionManager), 0);

        positionManager.decreaseLiquidity(firstToken, 1e18, 0, 0, address(this), block.timestamp, "");
        assertEq(hook.liquidityRemovals(secondId), 0);
        positionManager.collect(secondToken, 0, 0, address(this), block.timestamp, "");
        assertEq(hook.zeroDeltaModifications(poolId), 0);
        positionManager.increaseLiquidity(secondToken, 1e18, type(uint128).max, type(uint128).max, block.timestamp, "");
        positionManager.collect(firstToken, 0, 0, address(this), block.timestamp, "");

        assertEq(hook.liquidityAdditions(poolId), 1);
        assertEq(hook.liquidityRemovals(poolId), 1);
        assertEq(hook.zeroDeltaModifications(poolId), 1);
        assertEq(hook.liquidityAdditions(secondId), 2);
        assertEq(hook.liquidityRemovals(secondId), 0);
        assertEq(hook.zeroDeltaModifications(secondId), 1);
        assertEq(_liquidity(poolId, firstToken), INITIAL_LIQUIDITY - 1e18);
        assertEq(_liquidity(secondId, secondToken), INITIAL_LIQUIDITY + 1e18);
    }

    function test_routerCallerIsReportedWithoutTrustingHookData() public {
        PoolModifyLiquidityTest router = new PoolModifyLiquidityTest(poolManager);
        IERC20(Currency.unwrap(key.currency0)).approve(address(router), type(uint256).max);
        IERC20(Currency.unwrap(key.currency1)).approve(address(router), type(uint256).max);
        ModifyLiquidityParams memory params =
            ModifyLiquidityParams(LOWER, UPPER, int256(uint256(INITIAL_LIQUIDITY)), bytes32(0));
        bytes memory forgedIdentity = abi.encode(address(0xBEEF), "verified curator", uint256(1));
        vm.recordLogs();
        router.modifyLiquidity(key, params, forgedIdentity);
        _assertObservation(vm.getRecordedLogs(), poolId, address(router), 0);
        params.liquidityDelta = 0;
        vm.recordLogs();
        router.modifyLiquidity(key, params, hex"ff");
        _assertObservation(vm.getRecordedLogs(), poolId, address(router), 2);
        params.liquidityDelta = -int256(uint256(INITIAL_LIQUIDITY));
        vm.recordLogs();
        router.modifyLiquidity(key, params, forgedIdentity);
        _assertObservation(vm.getRecordedLogs(), poolId, address(router), 1);
        assertEq(hook.liquidityAdditions(poolId), 1);
        assertEq(hook.liquidityRemovals(poolId), 1);
        assertEq(hook.zeroDeltaModifications(poolId), 1);
    }

    function test_oneUnitLiquidityBoundary() public {
        uint256 tokenId = _mint(key, 1, "");
        assertEq(_liquidity(poolId, tokenId), 1);
        positionManager.decreaseLiquidity(tokenId, 1, 0, 0, address(this), block.timestamp, "");
        assertEq(_liquidity(poolId, tokenId), 0);
        assertEq(hook.liquidityAdditions(poolId), 1);
        assertEq(hook.liquidityRemovals(poolId), 1);
    }

    function removeForBoundaryTest(uint256 tokenId, uint256 amount) external {
        require(msg.sender == address(this), "self only");
        positionManager.decreaseLiquidity(tokenId, amount, 0, 0, address(this), block.timestamp, "");
    }

    function test_excessiveRemovalRollsBackCallback() public {
        uint256 tokenId = _mint(key, INITIAL_LIQUIDITY, "");
        ModifyLiquidityParams memory params =
            ModifyLiquidityParams(LOWER, UPPER, -int256(uint256(INITIAL_LIQUIDITY) + 1), bytes32(tokenId));
        vm.expectCall(
            address(hook),
            abi.encodeCall(IHooks.beforeRemoveLiquidity, (address(positionManager), key, params, bytes("")))
        );
        vm.expectRevert(SafeCast.SafeCastOverflow.selector);
        this.removeForBoundaryTest(tokenId, INITIAL_LIQUIDITY + 1);
        assertEq(hook.liquidityRemovals(poolId), 0);
        assertEq(hook.liquidityAdditions(poolId), 1);
        assertEq(_liquidity(poolId, tokenId), INITIAL_LIQUIDITY);
    }

    function test_zeroDeltaOnEmptyPositionRevertsWithoutRecord() public {
        uint256 tokenId = _mint(key, 1, "");
        positionManager.decreaseLiquidity(tokenId, 1, 0, 0, address(this), block.timestamp, "");
        vm.expectRevert(Position.CannotUpdateEmptyPosition.selector);
        this.removeForBoundaryTest(tokenId, 0);
        assertEq(hook.liquidityAdditions(poolId), 1);
        assertEq(hook.liquidityRemovals(poolId), 1);
        assertEq(hook.zeroDeltaModifications(poolId), 0);
    }

    function test_zeroDeltaWithAccruedFeesStillHasNeutralClassification() public {
        uint256 tokenId = _mint(key, INITIAL_LIQUIDITY, "");
        swapRouter.swapExactTokensForTokens({
            amountIn: 1e16,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: key,
            hookData: "",
            receiver: address(this),
            deadline: block.timestamp
        });
        vm.recordLogs();
        BalanceDelta received = positionManager.collect(tokenId, 0, 0, address(this), block.timestamp, "");
        _assertObservation(vm.getRecordedLogs(), poolId, address(positionManager), 2);
        assertGt(received.amount0(), 0, "fixture must actually accrue fees");
        assertEq(hook.liquidityAdditions(poolId), 1);
        assertEq(hook.liquidityRemovals(poolId), 0);
        assertEq(hook.zeroDeltaModifications(poolId), 1);
        assertEq(_liquidity(poolId, tokenId), INITIAL_LIQUIDITY);
    }

    receive() external payable {}

    function test_nativeCurrencyPoolUsesSameObservationRules() public {
        PoolKey memory nativeKey = key;
        nativeKey.currency0 = Currency.wrap(address(0));
        PoolId nativeId = nativeKey.toId();
        poolManager.initialize(nativeKey, 1 << 96);
        vm.deal(address(this), 2 ether);
        vm.recordLogs();
        (uint256 tokenId,) = positionManager.mint(
            nativeKey, LOWER, UPPER, INITIAL_LIQUIDITY, 1 ether, 1 ether, address(this), block.timestamp, ""
        );
        _assertObservation(vm.getRecordedLogs(), nativeId, address(positionManager), 0);
        positionManager.collect(tokenId, 0, 0, address(this), block.timestamp, "");
        positionManager.decreaseLiquidity(tokenId, INITIAL_LIQUIDITY, 0, 0, address(this), block.timestamp, "");
        assertEq(hook.liquidityAdditions(nativeId), 1);
        assertEq(hook.liquidityRemovals(nativeId), 1);
        assertEq(hook.zeroDeltaModifications(nativeId), 1);
        assertEq(_liquidity(nativeId, tokenId), 0);
        assertEq(hook.liquidityAdditions(poolId), 0);
    }

    function testFuzz_liquidityLifecycleAndUntrustedData(uint96 rawLiquidity, uint96 rawRemoval, bytes memory data)
        public
    {
        uint128 liquidity = uint128(bound(uint256(rawLiquidity), 1, 1e24));
        uint128 removal = uint128(bound(uint256(rawRemoval), 1, liquidity));
        vm.recordLogs();
        uint256 tokenId = _mint(key, liquidity, data);
        _assertObservation(vm.getRecordedLogs(), poolId, address(positionManager), 0);
        positionManager.collect(tokenId, 0, 0, address(this), block.timestamp, data);
        vm.recordLogs();
        positionManager.decreaseLiquidity(tokenId, removal, 0, 0, address(this), block.timestamp, data);
        _assertObservation(vm.getRecordedLogs(), poolId, address(positionManager), 1);
        assertEq(_liquidity(poolId, tokenId), liquidity - removal);
        if (removal < liquidity) {
            positionManager.decreaseLiquidity(tokenId, liquidity - removal, 0, 0, address(this), block.timestamp, data);
        }
        assertEq(_liquidity(poolId, tokenId), 0);
        assertEq(hook.liquidityAdditions(poolId), 1);
        assertEq(hook.liquidityRemovals(poolId), removal == liquidity ? 1 : 2);
        assertEq(hook.zeroDeltaModifications(poolId), 1);
    }

    function testFuzz_unauthorizedCallerCannotMutate(address caller, bytes memory data) public {
        vm.assume(caller != address(poolManager));
        ModifyLiquidityParams memory params = ModifyLiquidityParams(LOWER, UPPER, 1, bytes32(0));
        vm.expectRevert(BaseHook.NotPoolManager.selector);
        vm.prank(caller);
        hook.beforeAddLiquidity(caller, key, params, data);
        params.liquidityDelta = -1;
        vm.expectRevert(BaseHook.NotPoolManager.selector);
        vm.prank(caller);
        hook.beforeRemoveLiquidity(caller, key, params, data);
        assertEq(hook.liquidityAdditions(poolId), 0);
        assertEq(hook.liquidityRemovals(poolId), 0);
        assertEq(hook.zeroDeltaModifications(poolId), 0);
    }
}
