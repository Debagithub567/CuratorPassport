"""Check committed logs on an ephemeral localhost Anvil chain; standard library only."""

import json
from pathlib import Path
import socket
import subprocess
import time
from urllib.request import Request, urlopen


def cast(*args):
    return subprocess.check_output(["cast", *args], text=True).strip()


def main():
    root = Path(__file__).resolve().parents[1]
    artifact = root / "out/Level1ReceiptHarness.sol/Level1ReceiptHarness.json"
    bytecode = json.loads(artifact.read_text())["bytecode"]["object"]
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        port = listener.getsockname()[1]
    node = subprocess.Popen(
        ["anvil", "--host", "127.0.0.1", "--port", str(port), "--silent",
         "--gas-limit", "1000000000", "--disable-code-size-limit"],
        stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True,
    )

    def rpc(method, params):
        body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
        request = Request(f"http://127.0.0.1:{port}", body, {"Content-Type": "application/json"})
        with urlopen(request, timeout=60) as response:
            result = json.load(response)
        if "error" in result:
            raise RuntimeError(f"{method}: {result['error']}")
        return result["result"]

    def receipt(tx):
        for _ in range(100):
            result = rpc("eth_getTransactionReceipt", [tx])
            if result is not None:
                return result
            time.sleep(0.05)
        raise RuntimeError("receipt timeout")

    try:
        for _ in range(100):
            if node.poll() is not None:
                raise RuntimeError(f"Anvil exited: {node.stderr.read()}")
            try:
                accounts = rpc("eth_accounts", [])
                break
            except OSError:
                time.sleep(0.05)
        else:
            raise RuntimeError("Anvil startup timeout")

        def send(data, to=None):
            tx = {"from": accounts[0], "data": data, "gas": hex(900_000_000)}
            if to is not None:
                tx["to"] = to
            tx_hash = rpc("eth_sendTransaction", [tx])
            return tx_hash, receipt(tx_hash)

        _, deployed = send(bytecode)
        assert int(deployed["status"], 16) == 1, "harness deployment reverted"
        harness = deployed["contractAddress"]
        hook = "0x" + rpc("eth_call", [{"to": harness, "data": cast("sig", "hook()")}, "latest"])[-40:]
        topic = cast("keccak", "LiquidityObserved(bytes32,address,uint8)")

        def count():
            return int(rpc("eth_call", [{"to": harness, "data": cast("sig", "additions()")}, "latest"]), 16)

        def observations(result):
            return [log for log in result["logs"] if log["address"].lower() == hook.lower()]

        success_data = cast("sig", "modify(bool)") + "0" * 64
        fail_data = cast("sig", "modify(bool)") + "0" * 63 + "1"
        _, success = send(success_data, harness)
        assert int(success["status"], 16) == 1
        logs = observations(success)
        assert len(logs) == 1 and logs[0]["topics"][0] == topic
        assert logs[0]["topics"][2].lower() == "0x" + harness[2:].lower().zfill(64)
        assert int(logs[0]["data"], 16) == 0 and count() == 1

        failed_hash, failed = send(fail_data, harness)
        assert int(failed["status"], 16) == 0
        assert failed["logs"] == [], "reverted transaction retained committed logs"
        assert count() == 1, "reverted callback retained its counter increment"
        trace = rpc("debug_traceTransaction", [failed_hash, {"tracer": "callTracer"}])
        expected_revert = cast("sig", "DeliberateRollback(uint256)") + format(2, "064x")
        assert trace["output"].lower() == expected_revert.lower(), "callback did not increment before rollback"

        def calls(frame):
            yield frame
            for child in frame.get("calls", []):
                yield from calls(child)

        assert any(frame.get("to", "").lower() == hook.lower() for frame in calls(trace))
        _, following = send(success_data, harness)
        assert int(following["status"], 16) == 1 and count() == 2
        assert len(observations(following)) == 1
        print("PASS: successful receipts emit observations; reverted receipt has zero logs;")
        print("callback count reached 2 inside reverted execution, remained 1 after rollback,")
        print("then advanced to 2 on the next committed operation.")
        print("Transaction gas:", {"first_add": int(success["gasUsed"], 16),
                                   "reverted_add": int(failed["gasUsed"], 16),
                                   "following_add": int(following["gasUsed"], 16)})
    finally:
        node.terminate()
        try:
            node.wait(timeout=5)
        except subprocess.TimeoutExpired:
            node.kill()
            node.wait(timeout=5)
        node.stderr.close()


if __name__ == "__main__":
    main()
