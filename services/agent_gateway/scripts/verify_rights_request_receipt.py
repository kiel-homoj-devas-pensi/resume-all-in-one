"""Run under the configured service identity; no network and no data mutation."""

import argparse
import json
from pathlib import Path

from agent_gateway.pnvs_runtime import loadPnvsRuntimeSettings
from agent_gateway.rights_request_receipt import verifyReceipt


def main() -> int:
    parser = argparse.ArgumentParser(description="核验邮件中的账号归属回执，不执行用户请求")
    parser.add_argument("--protected-runtime", type=Path, required=True)
    parser.add_argument("--receipt-file", type=Path, required=True)
    args = parser.parse_args()
    try:
        if not args.receipt_file.is_file() or args.receipt_file.stat().st_size > 4096:
            raise ValueError()
        receipt = args.receipt_file.read_text(encoding="utf-8").strip()
        runtime = loadPnvsRuntimeSettings(args.protected_runtime)
        claims = verifyReceipt(runtime.otpSecret, receipt)
    except Exception:
        print(json.dumps({"status": "invalid_expired_or_unavailable"}))
        return 1
    # Account ID is for the authorised operator only, never a public support log.
    print(json.dumps({"status": "verified", **claims}, ensure_ascii=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
