"""Temporarily seed specific defects, require assertion failures, restore every file.

Run only in an idle checkout: this intentionally rewrites local source while testing.
No Git operations, dependencies, network calls or persistent mutants are used.
"""

import os
from pathlib import Path
import subprocess
from tempfile import TemporaryDirectory


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "src/CuratorPassportHook.sol"
TEST = ROOT / "test/CuratorPassportHook.t.sol"


def replace_once(text, before, after):
    assert text.count(before) == 1, f"mutation anchor changed: {before}"
    return text.replace(before, after, 1)


def main():
    original = SOURCE.read_text()
    original_test = TEST.read_text()
    mutations = [
        ("A: double addition", SOURCE,
         original.replace("liquidityAdditions[poolId]++;", "liquidityAdditions[poolId] += 2;"),
         "test_positiveAndRepeatedAdditions"),
        ("B: double removal", SOURCE,
         original.replace("liquidityRemovals[poolId]++;", "liquidityRemovals[poolId] += 2;"),
         "test_partialRepeatedAndFullRemovals"),
        ("C: misclassify zero delta", SOURCE,
         original.replace("params.liquidityDelta == 0", "params.liquidityDelta != 0"),
         "test_zeroDeltaIsNotRemovalOrEvidenceOfFees"),
        ("D: wrong event category", SOURCE,
         original.replace("sender, LiquidityOperation.Addition", "sender, LiquidityOperation.Removal"),
         "test_eventsClassifyOperationsAndReportPositionManager"),
        ("E: omit enclosing revert (test harness mutation)", TEST,
         replace_once(original_test, "revert DeliberateOuterRevert();", "return;"),
         "test_outerRevertRollsBackAllEarlierOperations"),
        ("F: collapse pool keys", SOURCE,
         original.replace("PoolId poolId = key.toId();", "PoolId poolId = PoolId.wrap(bytes32(0));"),
         "test_interleavedPoolsRemainIndependent"),
        ("G: bypass addition authorization", SOURCE,
         replace_once(original, "    function getHookPermissions()", """    function beforeAddLiquidity(
        address sender, PoolKey calldata key, ModifyLiquidityParams calldata params, bytes calldata data
    ) external override returns (bytes4) {
        return _beforeAddLiquidity(sender, key, params, data);
    }

    function getHookPermissions()"""), "test_unauthorizedCallbacksRevert"),
        ("G: permission/address disagreement", SOURCE,
         original.replace("beforeAddLiquidity: true", "beforeAddLiquidity: false"),
         "test_create2DeploymentValidatesExactPermissionBits"),
        ("H: trust claimed identity from hookData", SOURCE,
         original.replace("ModifyLiquidityParams calldata, bytes calldata)",
                          "ModifyLiquidityParams calldata, bytes calldata hookData)")
         .replace("sender, LiquidityOperation.Addition", "abi.decode(hookData, (address)), LiquidityOperation.Addition"),
         "test_routerCallerIsReportedWithoutTrustingHookData"),
        ("Invariant: double zero-delta count", SOURCE,
         original.replace("zeroDeltaModifications[poolId]++;", "zeroDeltaModifications[poolId] += 2;"),
         "invariant_countersAndLiquidityMatchCommittedOperations"),
    ]
    scratch = TemporaryDirectory(prefix="curator-passport-mutations-")
    env = dict(os.environ, FOUNDRY_INVARIANT_RUNS="16", FOUNDRY_INVARIANT_DEPTH="32",
               FOUNDRY_INVARIANT_FAIL_ON_REVERT="true",
               FOUNDRY_INVARIANT_FAILURE_PERSIST_DIR=scratch.name,
               FOUNDRY_FUZZ_FAILURE_PERSIST_DIR=scratch.name)
    try:
        for name, path, mutant, test in mutations:
            before = original if path == SOURCE else original_test
            assert mutant != before, f"inactive mutation: {name}"
            suite = "CuratorPassportHookInvariantTest" if test.startswith("invariant_") else "CuratorPassportHookTest"
            command = ["forge", "test", "--match-contract", suite, "--match-test", test, "-vv"]
            path.write_text(mutant)
            try:
                red = subprocess.run(command, cwd=ROOT, env=env, text=True, capture_output=True)
                failures = [line for line in red.stdout.splitlines() if "[FAIL" in line]
                assert red.returncode != 0 and failures and "Compiler run failed" not in red.stdout, red.stdout + red.stderr
                print(f"DETECTED {name}: {failures[0]}", flush=True)
            finally:
                path.write_text(before)
            green = subprocess.run(command, cwd=ROOT, env=env, text=True, capture_output=True)
            assert green.returncode == 0, green.stdout + green.stderr
            print(f"RESTORED GREEN: {' '.join(command)}", flush=True)
    finally:
        SOURCE.write_text(original)
        TEST.write_text(original_test)
        scratch.cleanup()
    print(f"PASS: all {len(mutations)} defects detected; restored targets pass.")


if __name__ == "__main__":
    main()
