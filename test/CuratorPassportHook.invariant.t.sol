// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {CuratorPassportFixture} from "./utils/CuratorPassportFixture.sol";
import {EasyPosm} from "./utils/libraries/EasyPosm.sol";

interface IObservationDriver {
    function applyOperation(uint8 pool, uint8 operation, uint128 amount) external;
}

/// @dev Independent ghost model advances only after a real operation succeeds.
contract ObservationHandler is Test {
    IObservationDriver internal immutable driver;
    uint256[2] public additions = [uint256(1), uint256(1)];
    uint256[2] public removals;
    uint256[2] public zeroDeltas;
    uint128[2] public liquidity = [uint128(100e18), uint128(100e18)];

    constructor(IObservationDriver driver_) {
        driver = driver_;
    }

    function step(uint8 poolSeed, uint8 operationSeed, uint96 rawAmount) external {
        uint8 pool = poolSeed % 2;
        uint8 operation = operationSeed % 4;
        // Keep a live position so a zero delta remains a valid operation.
        if (operation == 1 && liquidity[pool] == 1) operation = 2;
        uint128 amount = uint128(uint256(rawAmount) % 1e18 + 1);
        if (operation == 1) amount = uint128(uint256(rawAmount) % (liquidity[pool] - 1) + 1);
        driver.applyOperation(pool, operation, amount);
        if (operation == 0) {
            additions[pool]++;
            liquidity[pool] += amount;
        } else if (operation == 1) {
            removals[pool]++;
            liquidity[pool] -= amount;
        } else if (operation == 2) {
            zeroDeltas[pool]++;
        }
        // Operation 3 executes a callback then reverts: the model must not advance.
    }
}

contract CuratorPassportHookInvariantTest is CuratorPassportFixture, IObservationDriver {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;

    PoolId[2] internal ids;
    uint256[2] internal tokens;
    ObservationHandler internal handler;

    function setUp() public override {
        super.setUp();
        PoolKey memory second = _secondPool();
        ids = [poolId, second.toId()];
        tokens = [_mint(key, INITIAL_LIQUIDITY, ""), _mint(second, INITIAL_LIQUIDITY, "")];
        handler = new ObservationHandler(IObservationDriver(address(this)));
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = ObservationHandler.step.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    error DeliberateRollback();

    function addThenRevert(uint256 tokenId) external {
        require(msg.sender == address(this), "self only");
        positionManager.increaseLiquidity(tokenId, 1, type(uint128).max, type(uint128).max, block.timestamp, "");
        revert DeliberateRollback();
    }

    function applyOperation(uint8 pool, uint8 operation, uint128 amount) external {
        require(msg.sender == address(handler), "handler only");
        uint256 tokenId = tokens[pool];
        if (operation == 0) {
            positionManager.increaseLiquidity(
                tokenId, amount, type(uint128).max, type(uint128).max, block.timestamp, ""
            );
        } else if (operation == 1) {
            positionManager.decreaseLiquidity(tokenId, amount, 0, 0, address(this), block.timestamp, "");
        } else if (operation == 2) {
            positionManager.collect(tokenId, 0, 0, address(this), block.timestamp, "");
        } else {
            try this.addThenRevert(tokenId) {
                fail("rollback operation unexpectedly succeeded");
            } catch (bytes memory reason) {
                assertEq(reason, abi.encodeWithSelector(DeliberateRollback.selector));
            }
        }
    }

    function invariant_countersAndLiquidityMatchCommittedOperations() public view {
        for (uint256 i; i < 2; ++i) {
            assertEq(hook.liquidityAdditions(ids[i]), handler.additions(i));
            assertEq(hook.liquidityRemovals(ids[i]), handler.removals(i));
            assertEq(hook.zeroDeltaModifications(ids[i]), handler.zeroDeltas(i));
            assertEq(_liquidity(ids[i], tokens[i]), handler.liquidity(i));
        }
    }
}
