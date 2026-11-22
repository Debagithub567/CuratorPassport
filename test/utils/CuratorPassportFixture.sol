// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {CuratorPassportHook} from "../../src/CuratorPassportHook.sol";
import {BaseTest} from "./BaseTest.sol";
import {EasyPosm} from "./libraries/EasyPosm.sol";

/// @dev Uses existing Hookmate infrastructure artifacts; all operations execute real v4 code.
abstract contract CuratorPassportFixture is BaseTest {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint160 internal constant FLAGS = Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG;
    uint128 internal constant INITIAL_LIQUIDITY = 100e18;
    int24 internal constant LOWER = -120;
    int24 internal constant UPPER = 120;

    CuratorPassportHook internal hook;
    PoolKey internal key;
    PoolId internal poolId;

    function setUp() public virtual {
        deployArtifactsAndLabel();
        (key.currency0, key.currency1) = deployCurrencyPair();
        address hookAddress = address(uint160(0x4444 << 144) | FLAGS);
        deployCodeTo("CuratorPassportHook.sol:CuratorPassportHook", abi.encode(poolManager), hookAddress);
        hook = CuratorPassportHook(hookAddress);
        key.fee = 3000;
        key.tickSpacing = 60;
        key.hooks = IHooks(hookAddress);
        poolId = key.toId();
        poolManager.initialize(key, 1 << 96);
    }

    function _mint(PoolKey memory poolKey, uint128 liquidity, bytes memory hookData)
        internal
        returns (uint256 tokenId)
    {
        (tokenId,) = positionManager.mint(
            poolKey,
            LOWER,
            UPPER,
            liquidity,
            type(uint128).max,
            type(uint128).max,
            address(this),
            block.timestamp,
            hookData
        );
    }

    function _liquidity(PoolId id, uint256 tokenId) internal view returns (uint128) {
        (uint128 liquidity,,) =
            poolManager.getPositionInfo(id, address(positionManager), LOWER, UPPER, bytes32(tokenId));
        return liquidity;
    }

    function _secondPool() internal returns (PoolKey memory second) {
        second = key;
        second.fee = 500;
        poolManager.initialize(second, 1 << 96);
    }

    function _assertObservation(Vm.Log[] memory logs, PoolId id, address executionCaller, uint8 operation)
        internal
        view
    {
        uint256 observations;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(hook)) continue;
            ++observations;
            assertEq(logs[i].topics.length, 3);
            assertEq(logs[i].topics[0], keccak256("LiquidityObserved(bytes32,address,uint8)"));
            assertEq(logs[i].topics[1], PoolId.unwrap(id));
            assertEq(logs[i].topics[2], bytes32(uint256(uint160(executionCaller))));
            assertEq(abi.decode(logs[i].data, (uint8)), operation);
        }
        assertEq(observations, 1, "exactly one observation per operation");
    }
}
