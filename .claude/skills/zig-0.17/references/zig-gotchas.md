# Zig Gotchas (found in production code, checked on 0.17.0)

Traps that compile cleanly and look idiomatic, each found in real code and confirmed against
the std source or by measurement. Most produce no error at all: the program runs and is
wrong, slow, or leaks. They were found on 0.16.0; each entry says whether 0.17.0 still has it.

## New in 0.17.0

### The build configuration is cached on inputs it cannot see
`zig build` caches what `build.zig` configured and skips the configurer when the key — `-D`
and CLI options, target, the `build.zig` sources, declared dependencies — is unchanged. A
`build.zig` that scans a directory (a module list), reads a file or reads an environment
variable keeps building the old graph after that input changes. Measured on 0.17.0 with a
`build.zig` that counted the entries of a directory and read an env var into `b.addOptions()`:
a file added to the directory and the variable changed from `one` to `two` were both ignored,
silently; `--cache-poison=disallowed` did not catch it because the configurer never ran.

```zig
// Directory and file inputs: declare them.
b.dependOnDirectoryContents(b.path("modules"));    // entries added/removed/renamed; not recursive
b.dependOnFileContents(b.path("modules.zon"));
// Environment: no declaration exists. Prefer a -D option; otherwise
const level = b.graph.environ_map.get("MY_LEVEL");
b.graph.poisonCache(); // configuration now reruns on every zig build
```

`b.findProgram` poisons the cache itself; `b.findProgramLazy` does not. One stale run can be
forced with `zig build --cache-poison=poisoned`.

### `zig build` lost flags scripts use
Measured ("unrecognized argument"): `--global-cache-dir` (use `ZIG_GLOBAL_CACHE_DIR`),
`--zig-lib-dir` (now `--zig-lib=`, first argument only), `--build-runner`, `--verbose-llvm-bc`.
`b.cache_root` and `b.graph.global_cache_root` are gone, so configure code can no longer put a
cache path into a string; a step can still take `std.Build.LazyPath.cache_root`. `--release=ReleaseSafe` fails (`--release=safe`), while `-Doptimize=ReleaseSafe`
and `-OReleaseSafe` still work — keep the old spellings in scripts that must also run on 0.16.

### Silent behaviour changes
- **`@bitCast` of arrays and vectors** now reinterprets logical bits, element 0 first: on a
  big-endian target an array-to-integer cast gives a different value than in 0.16. Little-endian
  results are unchanged. (A cast of an `extern struct` stopped compiling, so it cannot go
  silently wrong.)
- **`@hasDecl` is `false` for a non-`pub` declaration**, also from inside the same file. A
  `comptime` feature probe written as `@hasDecl(Self, "helper")` on a private helper flips to
  `false` and silently takes the fallback path.
- **`std.mem.containsAtLeastScalar(T, list, element, minimum)`** swapped its last two
  parameters. With `u8`/`usize`-compatible integers an old call still compiles and answers a
  different question.
- **`std.testing.allocator` never reuses memory** (a fresh `SafeAllocator` per test).
  Use-after-free turns into a segfault or a panic much more often — good — but a test that
  allocates and frees in a long loop grows its RSS with the total it allocated, not its peak.
  Writes after free are checked in every mode; allocation stack traces exist only in Debug.

### Tooling
- **ZLS does not work with 0.17.0** (the build runner it hooked into is gone). Editor
  diagnostics stay empty or stale; compile to see errors.
- **The first `zig build` after installing 0.17 compiles the maker** (measured twice:
  108 s and 115 s, Zig 0.17.0, x86_64 Linux, 8-core machine; once per toolchain and global cache). A fresh CI runner pays it on every job unless
  the global cache (`~/.cache/zig`) is cached.
- **Cache manifests in `.zig-cache/h/` are binary.** A script that parsed them as text (a
  coverage or cache-inspection tool) breaks; `zig cache-cat <path>` prints one as ZON.
- **LLVM 22.** Code generation changed: redo constant-time checks of the binary (valgrind
  taint, objdump) and benchmark baselines. Loop vectorization is still disabled, as in 0.16.
- **Known 0.17.0 regressions** (release notes): response files in `std.Build.Step.Run`
  (#36444, a casualty of the configurer/maker split), `std.debug.simple_panic` does not
  compile (#36986), weak symbols of Zig's libc cannot reliably be overridden, soft-float
  compiler-rt on x86 (#37006), SPIR-V (#37050).
- **`std.Io.Uring` has no networking** (`netListenIp`, `netAccept`, `netConnectIp` return
  `…Unavailable`) and there is no epoll backend; network servers stay on `std.Io.Threaded`.
- **`ArrayList` gained `pointer_stability`** (a `std.debug.SafetyLock`). A field-by-field
  literal stops compiling; `.empty` and `initBuffer` are unaffected. `lockPointers()` /
  `unlockPointers()` make any growth while a pointer into the list is held trip an assertion
  in safe builds.

## Language

### `a, b = .{ b, a }` is not a swap

Still true in 0.17.0.

Result-location semantics build the tuple straight into the destinations: `a` is assigned
`b` first, then `b` reads the already-overwritten `a`. Both end up equal.

```zig
// WRONG: both become the old value of b
a, b = .{ b, a };

// CORRECT: plain temporary, stays in registers
const tmp = a;
a = b;
b = tmp;
```

`std.mem.swap(T, &a, &b)` is correct, but on hot locals it forces them to memory; a
measured case reassembled two `u32` locals byte by byte (+16 % instructions in a
compressor inner loop). Only a byte-exact golden test told the "speedup" apart from the bug.

### A generic struct that never names its parameter is one type

Still true in 0.17.0.

A type's identity is its declaration site plus the comptime values it captures. If the
returned struct never references the parameter, every instantiation is the same type and
its container-level `var`s are shared.

```zig
// WRONG: Store(a) == Store(b); `doc` is shared by every config
fn Store(comptime config: Config) type {
    return struct {
        var doc: ?[]const u8 = null;
    };
}

// CORRECT: capture the parameter inside the struct
fn Store(comptime config: Config) type {
    return struct {
        const for_config = config;
        var doc: ?[]const u8 = null;
    };
}

test "one type per config" {
    try std.testing.expect(Store(.{ .id = 1 }) != Store(.{ .id = 2 }));
}
```

### `@intFromFloat` out of range is illegal behaviour

Still true in 0.17.0 (safe modes panic: "integer part of floating point value out of bounds").

Not wrapping, not saturating: a panic in safe modes, an arbitrary value in ReleaseFast.
`std.fmt.parseFloat(f64, "1e999999")` succeeds and returns `inf`, so any parser that turns
a JSON number into an integer this way can be crashed by a 14-byte document such as
`{"t":1e999999}`.

```zig
fn toI64(f: f64) ?i64 {
    if (!std.math.isFinite(f)) return null;
    if (f >= @as(f64, @floatFromInt(std.math.maxInt(i64)))) return null;
    if (f <= @as(f64, @floatFromInt(std.math.minInt(i64)))) return null;
    return @intFromFloat(f);
}
```

Pair the guard with a test that an in-range float still converts, or the fix can silently
disable the feature.

### A failed `try` in a union literal has already written the tag

Still true in 0.17.0. Result-location semantics write the destination's tag before the payload
expression runs; when `try` returns, the destination is left with the new tag and an undefined
payload.

```zig
// WRONG: on error, `o.*` is `.b` with garbage, not the old value
o.* = .{ .b = try fail() };

// CORRECT: evaluate first, then assign
const v = try fail();
o.* = .{ .b = v };
```

## std.debug

### `getSymbols` with a stack-tracing allocator deadlocks

Measured on 0.16.0 and 0.17.0: `std.debug.SelfInfo.getSymbols` takes the debug-info lock
exclusively and then allocates. If the allocator records a stack trace per allocation — a
`SafeAllocator` in Debug, which is what `init.gpa` and `std.testing.allocator` are — that
allocation unwinds the stack, which needs the same lock: the process hangs on a futex. Pass
`std.debug.getDebugInfoAllocator()` (what std itself uses) for both the symbol list and the
text arena.

## std.Io

### Cancellation is erased at the `Io.Reader` boundary

Still true in 0.17.0 (`Io.Reader.Error` is unchanged).

`std.Io.Reader.Error` is `{ ReadFailed, EndOfStream }`. Cancelling a future blocked in a
socket read works (measured: returns in under 1 ms), but code holding a `*std.Io.Reader`
only sees `error.ReadFailed`. The real cause, `error.Canceled`, is in the concrete
reader's `err` field.

```zig
const byte = reader.interface.takeByte() catch |e| switch (e) {
    error.ReadFailed => return reader.err orelse error.ReadFailed, // Canceled lives here
    else => |other| return other,
};
```

A protocol module that must tell cancel from I/O failure has to take the concrete reader,
or its caller has to inspect `.err` after `ReadFailed`. Do not flatten errors into
`ReadFailed` at module boundaries.

### `std.Io.fiber.contextSwitch` miscompiles when inlined

Still true in 0.17.0 (the function is byte-identical).

Its inline asm lists `rsi` (aarch64: `x1`) as output, input and clobber. clang rejects the
same shape in C; Zig passes it to LLVM, and under register pressure the asm is entered with
a stale `rsi`, crashing at address `0xaa` in ReleaseSafe. Whether it bites depends on the
surrounding code, so a small test program does not reproduce it. Tracked upstream as
Codeberg ziglang/zig issue 35724.

Code that drives fibers directly: use a `noinline` copy of `contextSwitch` whose clobber list
omits the input register, with a comment naming the issue so it can be removed once a release
fixes it.

## Testing and fuzzing

### Fuzz corpus entries lose their first four bytes

Still true in 0.17.0 (`Smith` decodes input the same way; the fuzzer did not change).

`std.testing.Smith.slice` reads a 4-byte little-endian length from the input before the
bytes. A raw seed passed as `.corpus = &.{"GET / HTTP/1.1..."}` loses its first four bytes
to that length, so the seed never reaches the code it was written for.

- Prefix every seed with its length (a small helper that builds the encoded entry).
- Call `slice` first in the harness.
- Add a test that decodes each seed through `Smith{ .in = entry }` and asserts it reaches
  the intended branch.

`zig build test --fuzz` exits 0 even when it found a crash, shows no progress and does not
report a hang (found on 0.16; the 0.17.0 release notes: "no changes were made to the
fuzzer"). Never take a verdict from its exit code: drive the same harness from a deterministic
seed loop in an ordinary test binary, with a timeout per input.

The fuzzer explores raw bytes poorly; give harnesses a structured half built from
`smith.value(T)` and friends. See [std.testing](std-testing.md).

### Two backends: self-hosted for the edit loop, LLVM for test runs

Still true in 0.17.0. The timings below are from 0.16.0. New in 0.17: `-fincremental --watch`
makes the self-hosted edit loop near-instant (measured 14 ms and 6 ms per edit of a 10-line
program, Zig 0.17.0, x86_64 Linux, 8-core machine), while an LLVM build gains nothing from it (a full 2–3 s
rebuild per edit).

A Debug build for x86_64 Linux uses the self-hosted backend; every Release mode, and Debug on
most other targets, uses LLVM. `builtin.zig_backend` says which one built the code
(`.stage2_x86_64` or `.stage2_llvm`). The self-hosted backend compiles much faster and emits
much slower code, so it pays off only while the code is being edited.

Measured on Zig 0.16.0, x86_64 Linux, eight modules of one library (0.5 k to 30 k lines):
rebuild after an edit (without `-fincremental` the whole test binary is recompiled) plus the
test run, in seconds, best of two runs on a shared 8-core machine; "over N" is a run stopped
at that limit.

| module | self-hosted Debug | LLVM Debug | ReleaseSafe | ReleaseFast |
|---|---|---|---|---|
| CRC-32C (0.5 k lines) | 1.9 + 0.3 | 4.7 + 0.5 | 22.2 + 0.1 | 22.6 + 0.1 |
| JSON5 parser | 0.9 + 0.5 | 4.1 + 0.6 | 22.9 + 0.3 | 23.9 + 0.3 |
| secp256k1 | 4.1 + 25.6 | 8.4 + 7.8 | 29.1 + 4.2 | 30.2 + 4.2 |
| MLS | 2.0 + 61.2 | 8.1 + 29.7 | 47.0 + 6.1 | 54.0 + 4.0 |
| SSH | 2.1 + 42.2 | 11.3 + 42.2 | 68.7 + 16.8 | 57.1 + 17.0 |
| zstd (30 k lines) | 9 + over 600 | 53 + over 600 | 200 + over 180 | 146 + 132 |

- Self-hosted compiles 2 to 6 times faster than LLVM Debug, but its code runs 2 to 3 times
  slower: for compute-bound tests the edit-and-test loop is slower than with LLVM Debug.
- Release modes carry a floor of about 20 s even for a 500-line module (LLVM optimizes std
  and the test runner too). LLVM Debug builds 3.5 to 6 times faster than ReleaseSafe.
- A suite that does not finish in Debug within minutes needs an optimized mode for every run.

Which build for what:

- **Editing** ("does it compile", a quick test while typing): the default Debug build.
- **Running tests while iterating**: Debug with LLVM. Same safety checks, faster code.
- **Before a release**: ReleaseSafe (the mode most programs ship in) and ReleaseFast. Only an
  optimized build shows bugs that depend on inlining (`@frameAddress()`, `@returnAddress()`),
  wrong inline-asm constraints (register allocation differs), code relying on an `assert`
  that ReleaseFast compiles out, and reads of `undefined`, which Debug and ReleaseSafe fill
  with `0xaa`.
- **valgrind, timing, constant-time checks, fuzzing throughput, benchmarks**: ReleaseSafe or
  ReleaseFast. Under valgrind a self-hosted build produced tens of thousands of
  `DWARF2 reader` warnings and wrong line numbers for most frames.

`zig build` has no switch for the backend; it is set per compile step. `zig test`,
`zig build-exe` and `zig run` take `-fllvm` / `-fno-llvm`. In `build.zig`, one option,
passed to every `addTest`, `addExecutable`, `addLibrary` and `addObject`:

```zig
// Self-hosted backend only on request, for the edit loop.
const selfhosted = b.option(bool, "selfhosted", "Use the self-hosted backend (edit loop only)") orelse false;
const use_llvm: ?bool = if (selfhosted) null else true;

const tests = b.addTest(.{ .root_module = mod, .use_llvm = use_llvm });
```

`use_llvm = true` changes nothing in Release modes, which use LLVM already.

## Performance

### `std.HashMap` never rehashes away its tombstones

Still true in 0.17.0.

`remove` leaves a tombstone and increments `available`; growth is triggered only by
`available`. A long-lived map with a remove-one-insert-one pattern (a cache under misses)
never rebuilds, tombstones accumulate until no free slot is left, and every lookup of an
absent key walks the whole table. Measured: 697 k instructions per lookup at 1 024 entries,
30 k after the fix.

```zig
// Count removals yourself and rebuild periodically.
if (self.removed_since_rehash >= self.map.capacity() / 4) {
    self.map.rehash(ctx); // managed maps: self.map.rehash()
    self.removed_since_rehash = 0;
}
```

### `memcmp` and `secureZero` are byte loops

0.17.0 vectorized `compiler_rt.memset` (byte-wise only in ReleaseSmall), so the 0.16 trap
"without libc, `@memset` is about 18x slower than glibc" is gone. Still byte loops:
`compiler_rt`'s `memcmp`/`bcmp`, and `std.crypto.secureZero`, which is a `@memset` over volatile memory. For a large scrub on a hot
path, zero with volatile vector stores:

```zig
// Zero a 32-byte-aligned buffer whose length is a multiple of 32.
const V = @Vector(32, u8);
const words: [*]volatile V = @ptrCast(@alignCast(buf.ptr));
for (0..buf.len / 32) |k| words[k] = @splat(0);
```

### `?Big = null` and `.{}` memset the whole value

Still true in 0.17.0 (ReleaseFast, LLVM 22). Assigning `null` to an optional of a large struct,
or initializing a struct with `.{}` whose large array field defaults to `undefined`, emits a
`memset` over the whole value — 8 KiB for an 8 KiB buffer, on every call. On a hot path keep
the large buffer out of the optional (a separate `has_value` flag) and initialize only the
small fields.

## Security

### `std.crypto.ff` and `select` are not constant-time in ReleaseFast

Still true in 0.17.0 (measured with valgrind memcheck taint on ReleaseFast builds): the window
selection in `ff.Modulus.pow` and the final-subtraction check in `montgomeryMul` branch on
secret data, and LLVM 22 turns a hand-written `f64` mask select into a branch. Do not assume
`std.crypto.ff` (RSA-style big-number arithmetic) is constant-time; verify the binary, not the
source.

### `Certificate.verify` does not check that the issuer is a CA

Still true in 0.17.0: `std.crypto.Certificate.Parsed.verify` checks name chaining, validity
dates and the signature, but not basicConstraints, so a leaf certificate can sign another
certificate. Code that builds its own chain check must reject an issuer without `CA:TRUE`.

### `std.crypto` leaves key schedules on the stack

Found on 0.16.0; not re-measured on 0.17.0 (the AES code did not change in a way that would
scrub it).

After a TLS 1.3 handshake, the AES round keys (176-byte `AesEncryptCtx`, round key 0 is
the raw key) were found at about ten places on the dead stack below the caller.
`secureZero` on your own structs only clears the copies you own; it cannot reach frames
inside `std.crypto.aead.*`. "The key does not outlive the connection" is only true if the
stack itself is scrubbed (for example `MADV_DONTNEED` on a fiber stack before reuse). A
pooled OS thread keeps whatever was last written there.

## Build system

### `build.zig.zon` facts

Checked on 0.16.0. In 0.17.0 fetched packages are also copied into `zig-pkg/` in the project
(add it to `.gitignore`).

- `.fingerprint`: the upper 32 bits are the CRC-32 of the package name; the lower 32 are
  an arbitrary id.
- Unknown fields are ignored, at top level and inside dependency entries. A field ignored
  today can collide with a real one tomorrow, so prefix tool-specific fields
  (`.mytool_upstream`, not `.upstream`).
- A dependency URL must carry an explicit ref and the entry must have a `.hash`; a floating
  branch is rejected. Updates only arrive through a deliberate `zig fetch --save`.
- `zig build --fork=/path/to/checkout` overrides a package throughout the dependency tree
  without editing the manifest, which is safer than temporarily switching the pin to `.path`.

### The self-hosted x86_64 backend cannot encode what the target CPU lacks

Still true in 0.17.0 (same `InvalidInstruction` for `pclmulqdq`, `crc32q`, `aesenc`).

A path chosen at run time by a CPUID check (`pclmulqdq`, the SSE4.2 `crc32`, AES-NI, `pshufb`
in inline asm) is compiled for every x86_64 target. LLVM assembles it for any CPU model; the
self-hosted backend encodes only instructions the target CPU model has. A Debug build for a
baseline target (`-Dtarget=x86_64-linux`, `-Dcpu=baseline`, or a CPU model without the
feature) fails with

```
error(x86_64_encoder): no encoding found for: none pclmulqdq xmm xmm imm8s none
error: emit MIR failed: InvalidInstruction (Zig compiler bug)
```

Builds for the native CPU and all LLVM builds pass, so the failure reaches only consumers who
build Debug for a generic target. Compile the path only where the backend can emit it, and
fall back to the portable code elsewhere. A test of that path must check the comptime
condition first: `return error.SkipZigTest` is a run-time return, so a test that skips only
on a run-time CPU check still compiles the asm.

```zig
const std = @import("std");
const builtin = @import("builtin");

/// The hardware path can be compiled at all: LLVM always, the self-hosted backend only when
/// the target CPU model has the instruction.
const pclmul_emittable = builtin.target.cpu.arch == .x86_64 and
    (builtin.zig_backend != .stage2_x86_64 or
        std.Target.x86.featureSetHas(builtin.target.cpu.features, .pclmul));

fn cpuHasPclmul() bool {
    if (builtin.target.cpu.arch != .x86_64) return false;
    var eax: u32 = undefined;
    var ebx: u32 = undefined;
    var ecx: u32 = undefined;
    var edx: u32 = undefined;
    asm volatile ("cpuid"
        : [_] "={eax}" (eax),
          [_] "={ebx}" (ebx),
          [_] "={ecx}" (ecx),
          [_] "={edx}" (edx),
        : [_] "{eax}" (@as(u32, 1)),
          [_] "{ecx}" (@as(u32, 0)),
    );
    return (ecx >> 1) & 1 == 1; // CPUID.01H:ECX.PCLMULQDQ[bit 1]
}

fn clmulLow(a: @Vector(2, u64), b: @Vector(2, u64)) @Vector(2, u64) {
    return asm ("pclmulqdq $0x00, %[b], %[a]"
        : [a] "=x" (-> @Vector(2, u64)),
        : [_] "0" (a),
          [b] "x" (b),
    );
}

test "the carry-less multiply path" {
    // `pclmul_emittable` first: comptime-false, it keeps `clmulLow` out of builds that cannot
    // compile it. `cpuHasPclmul()` alone is a run-time check.
    if (!pclmul_emittable or !cpuHasPclmul()) return error.SkipZigTest;
    const r = clmulLow(.{ 3, 0 }, .{ 5, 0 });
    try std.testing.expectEqual(@as(u64, 15), r[0]); // (x + 1)(x^2 + 1) = x^3 + x^2 + x + 1
}
```

The same applies to every other gate on such a path: the dispatcher, `available()`-style
queries and test helpers all test the comptime condition before the run-time one.

### Fixed in 0.17.0

- Deleting `.zig-cache/o` no longer wedges `zig build`: the configurer reruns.
- `std.testing.allocator` leaks fail the test in ReleaseFast too (0.16 passed them silently).
- `std.process.getUserInfo(io, name)` compiles and works.
