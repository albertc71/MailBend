# Loaded only by the reviewed hosted LLDB command, never during local review.
import lldb
import os

root = os.environ["PACING_DIAG_DIR"]
mode = os.environ["PACING_DIAG_MODE"]
debugger = lldb.debugger
debugger.SetAsync(False)

def write(name, text, cap=1600):
    raw = text.encode("utf-8", "replace")
    with open(os.path.join(root, name), "wb") as output:
        output.write(raw[:cap])
        if len(raw) > cap:
            output.write(b"\nTRUNCATED\n")

def command(text):
    result = lldb.SBCommandReturnObject()
    debugger.GetCommandInterpreter().HandleCommand(text, result)
    if not result.Succeeded():
        raise RuntimeError("setting failed: " + text + ": " + str(result.GetError())[:200])

for setting in [
    "target.load-script-from-symbol-file false",
    "symbols.enable-external-lookup false",
    "target.disable-aslr false",
    "target.detach-on-error false",
]:
    command("settings set " + setting)
version = lldb.SBDebugger.GetVersionString()
if not version.startswith("lldb version 18.1.3"):
    raise RuntimeError("unsupported debugger version: " + version[:160])

def launch_info():
    info = lldb.SBLaunchInfo(["-j1", "-c", "bendtt.c", "bendtt.lean"])
    info.SetLaunchFlags(lldb.eLaunchFlagDebug)
    info.SetShell("")
    info.SetShellExpandArguments(False)
    info.SetDetachOnError(False)
    info.SetWorkingDirectory(root)
    controlled = dict(os.environ)
    home = controlled["HOME"]
    required = {
        "HOME": home,
        "ELAN_HOME": home + "/.elan",
        "BENDTT": "",
        "ELAN_TOOLCHAIN": "leanprover/lean4:v4.34.0",
        "ELAN_AUTO_INSTALL": "0",
        "BEND_NO_TELEMETRY": "1",
        "DEBUGINFOD_URLS": "",
    }
    if not home or home == "/" or any(controlled.get(key) != value for key, value in required.items()):
        raise RuntimeError("unexpected controlled compiler environment")
    info.SetEnvironmentEntries([key + "=" + value for key, value in controlled.items()], False)
    supplied = {}
    for index in range(info.GetNumEnvironmentEntries()):
        entry = info.GetEnvironmentEntryAtIndex(index)
        key, value = entry.split("=", 1)
        if key in supplied:
            raise RuntimeError("duplicate compiler environment key")
        supplied[key] = value
    if supplied != controlled or any(supplied.get(key) != value for key, value in required.items()):
        raise RuntimeError("compiler environment binding mismatch")
    if info.GetLaunchFlags() != lldb.eLaunchFlagDebug:
        raise RuntimeError("unsafe launch flags")
    if info.GetShell() not in (None, "") or info.GetShellExpandArguments():
        raise RuntimeError("unexpected shell")
    return info

info = launch_info()
if mode == "capability":
    for cls, names in [
        (lldb.SBTarget, ["Launch"]),
        (lldb.SBProcess, ["GetState", "GetSelectedThread", "GetThreadAtIndex", "Kill"]),
        (lldb.SBThread, ["GetStopReason", "GetStopReasonDataAtIndex", "GetFrameAtIndex"]),
        (lldb.SBFrame, ["GetPC", "GetFunctionName", "GetModule"]),
    ]:
        for name in names:
            if not hasattr(cls, name):
                raise RuntimeError("missing API " + name)
    write("capability", "CAPABILITY_OK\n" + version, 512)
else:
    if mode != "compiler":
        raise RuntimeError("invalid diagnostic mode")
    process = None
    def trace(thread, cap):
        lines = ["THREAD=" + str(thread.GetThreadID())]
        for index in range(20):
            frame = thread.GetFrameAtIndex(index)
            if not frame.IsValid():
                break
            function = str(frame.GetFunctionName() or "?")[:160]
            module = str(frame.GetModule().GetFileSpec().GetFilename() or "?")[:80]
            lines.append(str(index) + " PC=" + hex(frame.GetPC()) + " " + module + " " + function)
        text = "\n".join(lines) + "\n"
        raw = text.encode("utf-8", "replace")
        return raw[:cap] + (b"\nTRUNCATED\n" if len(raw) > cap else b"")
    try:
        target = debugger.CreateTarget(os.environ["PACING_LEAN"])
        if not target.IsValid():
            raise RuntimeError("target creation failed")
        error = lldb.SBError()
        process = target.Launch(info, error)
        state = process.GetState() if process.IsValid() else lldb.eStateInvalid
        prefix = "LAUNCH_ERROR=" + str(error.GetCString() or "none")[:240] + " STATE=" + str(state) + "\n"
        write("outcome", prefix)
        if error.Fail() or not process.IsValid():
            write("outcome", prefix + "INFERIOR=launch-failure\n")
        elif state == lldb.eStateExited:
            write("outcome", prefix + "INFERIOR=exited CODE=" + str(process.GetExitStatus()) + " DESCRIPTION=" + str(process.GetExitDescription() or "")[:240] + "\n")
        elif state in (lldb.eStateStopped, lldb.eStateCrashed):
            selected = process.GetSelectedThread()
            if not selected.IsValid():
                raise RuntimeError("no selected stopping thread")
            reason = selected.GetStopReason()
            signal = selected.GetStopReasonDataAtIndex(0) if reason == lldb.eStopReasonSignal and selected.GetStopReasonDataCount() else "none"
            write("outcome", prefix + "INFERIOR=stopped REASON=" + str(reason) + " SIGNAL=" + str(signal) + " DESCRIPTION=" + str(selected.GetStopDescription(256) or "")[:256] + "\n")
            with open(os.path.join(root, "selected"), "wb") as output:
                output.write(trace(selected, 8000))
            remaining = 7
            with open(os.path.join(root, "others"), "wb") as output:
                for index in range(process.GetNumThreads()):
                    if remaining == 0:
                        break
                    thread = process.GetThreadAtIndex(index)
                    if thread.IsValid() and thread.GetThreadID() != selected.GetThreadID():
                        output.write(trace(thread, 480))
                        remaining -= 1
        else:
            write("outcome", prefix + "INFERIOR=unexpected-state\n")
    except Exception as error:
        write("observer-error", "OBSERVER_ERROR=" + str(error)[:500] + "\n", 512)
    finally:
        if process is not None and process.IsValid() and process.GetState() not in (lldb.eStateExited, lldb.eStateDetached, lldb.eStateInvalid):
            result = process.Kill()
            write("cleanup", "OWNED_KILL=" + str(result.GetCString() or "success")[:240] + "\n", 256)
        else:
            write("cleanup", "OWNED_KILL=not-needed\n", 256)
    write("finished", "OBSERVER_FINISHED\n", 64)
