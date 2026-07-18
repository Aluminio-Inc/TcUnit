"""A1 abort probe: deterministic, positively-gated abort of the ABORT campaign.

Sequence (all over ADS, target 192.168.225.2.1.1:851):
  1. Preconditions: NumberOfInitializedTestSuites == 1, AllTestSuitesFinished == False.
  2. POSITIVE window signal: poll until CurrentTestNameBeingCalled == 'Test_AbortWindow'
     (the abort test's body context is active), then settle a few seconds with the
     wait in progress. AllTestSuitesFinished == False alone is NOT sufficient
     (review finding 2026-07-17: an early raw write short-circuits the runner
     before any observable test evidence exists).
  3. Write GVL_TcUnit.TcUnitRunner.AbortRunningTestSuites := True.
  4. Postcondition: AllTestSuitesFinished latches True promptly.
  5. Restart the PLC runtime (STOP -> RUN) so Base's FB_exit drain flushes the
     ring buffer: aborted runs never reach the normal TESTS FINISHED flush
     trigger, so the TEST RUN ABORTED trace would otherwise sit unflushed.

Exit 0 on success; nonzero with a reason otherwise.
"""

import sys
import time

import pyads

AMS = "192.168.225.2.1.1"
PORT = 851
# Runtime symbol paths carry no library namespace: globals surface as GVL.<var>
PREFIX = "GVL_TcUnit."

SYM_SUITES = PREFIX + "NumberOfInitializedTestSuites"
SYM_CURRENT = PREFIX + "CurrentTestNameBeingCalled"
SYM_FINISHED = PREFIX + "TcUnitRunner.AllTestSuitesFinished"
SYM_ABORT = PREFIX + "TcUnitRunner.AbortRunningTestSuites"


def fail(msg: str) -> None:
    print(f"FAIL  {msg}")
    sys.exit(1)


def main() -> None:
    plc = pyads.Connection(AMS, PORT)
    plc.open()
    try:
        # Right after a deploy the runtime is up before its symbol server is ready;
        # retry first contact for up to 30 s (observed ADS error 1808 otherwise).
        deadline = time.monotonic() + 30.0
        while True:
            try:
                suites = plc.read_by_name(SYM_SUITES, pyads.PLCTYPE_UINT)
                break
            except pyads.ADSError as exc:
                if time.monotonic() >= deadline:
                    fail(f"symbol server not ready within 30 s: {exc}")
                time.sleep(1.0)
        print(f"precondition: NumberOfInitializedTestSuites={suites}")
        if suites != 1:
            fail(f"expected exactly 1 registered suite, got {suites} (isolation broken)")

        if plc.read_by_name(SYM_FINISHED, pyads.PLCTYPE_BOOL):
            fail("AllTestSuitesFinished already True before the abort window (stale run?)")

        print("waiting for positive window signal (CurrentTestNameBeingCalled == 'Test_AbortWindow')...")
        deadline = time.monotonic() + 60.0
        while time.monotonic() < deadline:
            current = plc.read_by_name(SYM_CURRENT, pyads.PLCTYPE_STRING)
            if current == "Test_AbortWindow":
                break
            time.sleep(0.2)
        else:
            fail("Test_AbortWindow never became the current test within 60 s")
        print("window signal observed: Test_AbortWindow is executing")

        print("settling 5 s with the condition wait in progress...")
        time.sleep(5.0)
        if plc.read_by_name(SYM_FINISHED, pyads.PLCTYPE_BOOL):
            fail("run finished during settle - abort window lost")

        print("writing AbortRunningTestSuites := TRUE")
        plc.write_by_name(SYM_ABORT, True, pyads.PLCTYPE_BOOL)

        deadline = time.monotonic() + 10.0
        latched = False
        while time.monotonic() < deadline:
            if plc.read_by_name(SYM_FINISHED, pyads.PLCTYPE_BOOL):
                latched = True
                break
            time.sleep(0.1)
        if not latched:
            fail("AllTestSuitesFinished did not latch within 10 s of the abort write")
        print("postcondition: AllTestSuitesFinished=True (abort honored)")

        # Trace-content evidence is asserted by the campaign runner from the
        # flushed jsonl (the ABORT selection forces SAVEENTRYTHRESHOLD=1 so
        # every entry flushes immediately). The ring itself drains within one
        # LogTask scan and clears its slots - not race-readable post-hoc.
    finally:
        plc.close()

    print("A1 PROBE PASSED")
    sys.exit(0)


if __name__ == "__main__":
    main()
