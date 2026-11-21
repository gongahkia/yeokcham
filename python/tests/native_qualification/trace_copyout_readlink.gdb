# Scratch instrumentation for the verified historical x86-64 binary only.
set pagination off
set confirm off
set startup-with-shell off
set disable-randomization off
starti
python
import gdb

frame = gdb.parse_and_eval("(char *) &yeokcham_scan_readlink_at")
prior = None

def register(name):
    return int(gdb.parse_and_eval("$" + name))

def sample(address, length):
    return bytes(gdb.selected_inferior().read_memory(address, length))

class Before(gdb.Breakpoint):
    def stop(self):
        global prior
        size = register("rdi")
        pointer = register("rsi")
        prior = size, pointer, sample(pointer, size)
        return False

class After(gdb.Breakpoint):
    def stop(self):
        size, source, kernel = prior
        result = register("rax")
        rooted = int.from_bytes(sample(register("rsp") + 24, 8), 'little')
        expected = sample(rooted, size)
        observed = sample(result, size)
        forwarding = source != rooted and observed[:8] == rooted.to_bytes(8, "little")
        gdb.write(f"M20-READLINK kernel={kernel.hex()} returned={observed.hex()} "
                  f"rooted={expected.hex()} moved={source != rooted} "
                  f"forwarding_prefix={forwarding}\n")
        return False

Before(f"*{int(frame) + 0x10e:#x}", internal=True)
After(f"*{int(frame) + 0x113:#x}", internal=True)
end
continue
