# Hosted-only transport observation, never verifier acceptance.
import os
from pathlib import Path
import subprocess
import sys

binary, input_path, output_path = sys.argv[1:]
env = dict(os.environ)
env["LEAN_STACK_SIZE_KB"] = "4194304"
code = None
phase = "initial-report"

def outcome():
    if code is None:
        return "KERNEL_OUTCOME=unknown"
    if code < 0:
        return "KERNEL_SIGNAL=" + str(-code)
    return "KERNEL_EXIT=" + str(code)

try:
    print("KERNEL_OBSERVATION_BEGIN: one child; new Python transport; diagnostic only", flush=True)
    phase = "capture-open"
    with open(output_path, "xb") as output:
        phase = "launch-and-wait"
        result = subprocess.run([binary, input_path], stdin=subprocess.DEVNULL,
                                stdout=output, stderr=subprocess.STDOUT,
                                env=env, check=False)
        code = result.returncode
        phase = "capture-close"
    phase = "outcome-report"
    print(outcome(), flush=True)
    phase = "capture-stat"
    size = Path(output_path).stat().st_size
    phase = "size-report"
    print("KERNEL_OUTPUT_BYTES=" + str(size), flush=True)
    print("KERNEL_OUTPUT_TAIL_LIMIT=6000; earlier bytes may be omitted", flush=True)
    phase = "capture-reopen"
    with open(output_path, "rb") as output:
        phase = "capture-seek"
        output.seek(max(0, size - 6000))
        phase = "capture-read"
        data = output.read(6000)
        phase = "capture-read-close"
    phase = "tail-write"
    sys.stdout.buffer.write(data)
    sys.stdout.buffer.write(b"\n")
    sys.stdout.flush()
    phase = "final-report"
    print("DIAGNOSTIC_ONLY: ordinary --verdict acceptance still required separately", flush=True)
except OSError as exc:
    # Preserve a known returncode even when later capture/reporting fails.
    # If stderr also fails, reporting is best effort; exit remains nonzero.
    report = "OBSERVATION_ERROR phase=" + phase + " errno=" + str(exc.errno) + " " + outcome() + "\n"
    try:
        os.write(2, report.encode("ascii"))
    except OSError:
        pass
    raise SystemExit(1)
raise SystemExit(0 if code == 0 else 1)
