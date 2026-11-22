// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager, ModifyLiquidityParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";

contract CuratorPassportHook is BaseHook {
    using PoolIdLibrary for PoolKey;

    mapping(PoolId => uint256) public liquidityAdditions;
    mapping(PoolId => uint256) public liquidityRemovals;

    event LiquidityObserved(
        bytes32 indexed poolId,
        address indexed executionCaller,
        bool isAddition
    );

    constructor(IPoolManager _poolManager)
        BaseHook(_poolManager)
    {}

    function getHookPermissions()
        public
        pure
        override
        returns (Hooks.Permissions memory)
    {
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

    function _beforeAddLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata,
        bytes calldata
    ) internal override returns (bytes4) {
        PoolId poolId = key.toId();

        liquidityAdditions[poolId]++;

        emit LiquidityObserved(
            PoolId.unwrap(poolId),
            sender,
            true
        );

        return BaseHook.beforeAddLiquidity.selector;
    }

    function _beforeRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata,
        bytes calldata
    ) internal override returns (bytes4) {
        PoolId poolId = key.toId();

        liquidityRemovals[poolId]++;

        emit LiquidityObserved(
            PoolId.unwrap(poolId),
            sender,
            false
        );

        return BaseHook.beforeRemoveLiquidity.selector;
    }
}
