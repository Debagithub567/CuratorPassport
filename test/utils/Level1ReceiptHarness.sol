// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {V4PoolManagerDeployer} from "hookmate/artifacts/V4PoolManager.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {CuratorPassportHook} from "../../src/CuratorPassportHook.sol";

/// @dev Local receipt-test infrastructure only. No cheatcodes, live networks or user funds.
contract Level1ReceiptHarness is IUnlockCallback {
    using CurrencySettler for Currency;
    using PoolIdLibrary for PoolKey;

    IPoolManager public immutable manager;
    CuratorPassportHook public immutable hook;
    PoolKey internal key;

    error DeliberateRollback(uint256 countInsideRevertedCall);

    constructor() {
        manager = IPoolManager(V4PoolManagerDeployer.deploy(address(this)));
        (, bytes32 salt) = HookMiner.find(
            address(this),
            Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG,
            type(CuratorPassportHook).creationCode,
            abi.encode(manager)
        );
        hook = new CuratorPassportHook{salt: salt}(manager);
        MockERC20 first = new MockERC20("First", "ONE", 18);
        MockERC20 second = new MockERC20("Second", "TWO", 18);
        first.mint(address(this), 1e24);
        second.mint(address(this), 1e24);
        if (address(first) > address(second)) (first, second) = (second, first);
        key = PoolKey(Currency.wrap(address(first)), Currency.wrap(address(second)), 3000, 60, IHooks(hook));
        manager.initialize(key, 1 << 96);
    }

    function additions() external view returns (uint256) {
        return hook.liquidityAdditions(key.toId());
    }

    function modify(bool failAfterCallback) external {
        manager.unlock(abi.encode(failAfterCallback));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "manager only");
        (BalanceDelta delta,) = manager.modifyLiquidity(key, ModifyLiquidityParams(-120, 120, 1e18, bytes32(0)), "");
        if (abi.decode(data, (bool))) revert DeliberateRollback(hook.liquidityAdditions(key.toId()));
        if (delta.amount0() < 0) {
            key.currency0.settle(manager, address(this), uint256(-int256(delta.amount0())), false);
        }
        if (delta.amount1() < 0) {
            key.currency1.settle(manager, address(this), uint256(-int256(delta.amount1())), false);
        }
        return "";
    }
}
