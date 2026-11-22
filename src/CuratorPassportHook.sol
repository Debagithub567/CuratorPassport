// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager, ModifyLiquidityParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @notice Observes liquidity modifications only for v4 pools configured with this hook.
/// @dev Counts callbacks, not unique transactions or financial results. Before-callback
///      state and logs survive only when the enclosing execution commits successfully.
contract CuratorPassportHook is BaseHook {
    using PoolIdLibrary for PoolKey;

    enum LiquidityOperation {
        Addition,
        Removal,
        ZeroDelta
    }

    mapping(PoolId => uint256) public liquidityAdditions;
    mapping(PoolId => uint256) public liquidityRemovals;
    mapping(PoolId => uint256) public zeroDeltaModifications;

    /// @dev executionCaller is the immediate PoolManager caller, often a PositionManager
    ///      or router. It does not identify a curator. ZeroDelta does not prove fee collection.
    event LiquidityObserved(bytes32 indexed poolId, address indexed executionCaller, LiquidityOperation operation);

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: true,
            afterRemoveLiquidity: false,
            beforeSwap: false,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function _beforeAddLiquidity(address sender, PoolKey calldata key, ModifyLiquidityParams calldata, bytes calldata)
        internal
        override
        returns (bytes4)
    {
        PoolId poolId = key.toId();

        liquidityAdditions[poolId]++;

        emit LiquidityObserved(PoolId.unwrap(poolId), sender, LiquidityOperation.Addition);

        return BaseHook.beforeAddLiquidity.selector;
    }

    function _beforeRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        bytes calldata
    ) internal override returns (bytes4) {
        PoolId poolId = key.toId();

        // v4 routes both negative and zero liquidity deltas to this callback.
        LiquidityOperation operation;
        if (params.liquidityDelta == 0) {
            zeroDeltaModifications[poolId]++;
            operation = LiquidityOperation.ZeroDelta;
        } else {
            liquidityRemovals[poolId]++;
            operation = LiquidityOperation.Removal;
        }

        emit LiquidityObserved(PoolId.unwrap(poolId), sender, operation);

        return BaseHook.beforeRemoveLiquidity.selector;
    }
}
