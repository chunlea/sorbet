# Sorbet Performance Optimization Guide

This document outlines strategies to reduce memory usage and improve speed in Sorbet.

## Table of Contents
1. [Command-Line Optimizations (No Code Changes)](#1-command-line-optimizations-no-code-changes)
2. [Memory Optimizations](#2-memory-optimizations)
3. [Speed Optimizations](#3-speed-optimizations)
4. [Code-Level Optimizations](#4-code-level-optimizations)
5. [Architecture Optimizations](#5-architecture-optimizations)

---

## 1. Command-Line Optimizations (No Code Changes)

### 1.1 Enable Disk Caching
```bash
sorbet --cache-dir=/path/to/cache .
```
The cache stores parsed ASTs and GlobalState, avoiding re-parsing on subsequent runs. Default max size is 4GB.

### 1.2 Adjust Thread Count
```bash
sorbet --threads=N .
```
By default, Sorbet auto-detects threads. For memory-constrained systems, reduce thread count:
- Fewer threads = less peak memory usage
- More threads = faster on multi-core systems with sufficient RAM

### 1.3 Pre-allocate Symbol Tables
For large codebases, pre-allocating tables avoids repeated resizing:
```bash
sorbet \
  --reserve-class-table-capacity=16384 \
  --reserve-method-table-capacity=65536 \
  --reserve-field-table-capacity=8192 \
  --reserve-type-parameter-table-capacity=512 \
  --reserve-type-member-table-capacity=8192 \
  --reserve-utf8-name-table-capacity=32768 \
  --reserve-constant-name-table-capacity=8192 \
  --reserve-unique-name-table-capacity=8192 \
  .
```

### 1.4 LSP Mode Tuning
```bash
# Limit files on fast path (default: 50)
# Lower = less memory per incremental check
# Higher = more changes can be processed incrementally

# Error cap (default: 1000)
# Reduces memory for error storage and improves editor performance
```

---

## 2. Memory Optimizations

### 2.1 InlinedVector Size Tuning
**File:** `common/common.h`

Current inline sizes may not be optimal for all use cases:

| Structure | Current Size | Recommendation |
|-----------|-------------|----------------|
| `InlinedVector<ExpressionPtr, 4>` | 4 | Profile your codebase |
| `InlinedVector<ClassOrModuleRef, 4>` | 4 | Consider 2 for small classes |
| `InlinedVector<TypeMemberRef, 4>` | 4 | Consider 2 for most code |

**Impact:** Reducing inline sizes trades stack allocation for heap allocation. For rarely-exceeded sizes, smaller inline allocation saves memory.

### 2.2 TypePtr Memory Layout
**File:** `core/TypePtr.h`

TypePtr uses 8 bytes with tagged pointer storage. Common types are inlined:
- ClassType, AliasType, SelfType: Inlined (no heap allocation)
- OrType, AndType, ShapeType, TupleType: Heap allocated

**Optimization:** The inlining threshold could be increased for medium-sized types.

### 2.3 GlobalState Table Pre-sizing
**File:** `core/GlobalState.h`

Current payload maximums:
```cpp
PAYLOAD_MAX_UTF8_NAME_COUNT = 16384
PAYLOAD_MAX_CONSTANT_NAME_COUNT = 4096
PAYLOAD_MAX_UNIQUE_NAME_COUNT = 4096
PAYLOAD_MAX_CLASS_AND_MODULE_COUNT = 8192
PAYLOAD_MAX_METHOD_COUNT = 32768
PAYLOAD_MAX_FIELD_COUNT = 4096
```

**Optimization:** If your codebase is smaller, reduce these to save memory on startup.

### 2.4 String Interning Page Size
**File:** `common/StableStringStorage.h`

Default page size is 4096 bytes. For codebases with many unique strings, larger pages reduce allocation overhead. For smaller codebases, smaller pages waste less memory.

### 2.5 Intentional AST Leaking
**File:** `main/pipeline/pipeline.h:104`

For batch mode on large codebases:
```cpp
void typecheck(..., bool intentionallyLeakASTs = false);
```
Setting `intentionallyLeakASTs = true` skips AST cleanup, providing significant speedup at the cost of memory not being freed until process exit.

### 2.6 Name Hash Table Load Factor
**File:** `core/GlobalState.h`

The NameHash uses linear probing with power-of-2 sizing. Consider:
- Increasing table size to reduce probe chains
- Using Robin Hood hashing for better cache behavior

---

## 3. Speed Optimizations

### 3.1 Parallel Indexing Configuration
**File:** `common/concurrency/WorkerPoolImpl.h`

Current settings:
```cpp
BLOCK_SIZE = 2           // Queue block size
MAX_SUBQUEUE_SIZE = 16   // Max elements per sub-queue
BLOCK_INTERVAL = 20ms    // Wake interval
```

**Optimization for throughput:** Increase `BLOCK_SIZE` to 4 or 8 for larger batches.
**Optimization for latency:** Keep `BLOCK_INTERVAL` low (20ms is good).

### 3.2 Cache Streaming Threshold
**File:** `main/cache/cache.cc:140`

```cpp
if (processedByThread > 100) {
    resultq->push(move(threadResult), processedByThread);
}
```

**Optimization:** Tune this threshold based on file sizes:
- Larger files: Lower threshold (50)
- Smaller files: Higher threshold (200)

### 3.3 Fast Path File Limit
**File:** `main/options/options.h:247`

```cpp
uint32_t lspMaxFilesOnFastPath = 50;
```

**Optimization:**
- Increase for more incremental coverage
- Decrease for faster individual checks

### 3.4 Method Dealiasing
**File:** `core/Symbols.h:160`

```cpp
// TODO(dmitry) perf: most calls to this method could be eliminated as part of perf work.
MethodRef dealiasMethod(const GlobalState &gs, int depthLimit = 42) const;
```

This is a known hotspot. Consider:
- Caching dealiased methods
- Reducing depth limit when possible
- Pre-computing during resolution

### 3.5 Type Subtyping Caching
**File:** `core/types/subtyping.cc`

Subtype checks are performed frequently. Consider:
- Caching common subtype relationships
- Using bloom filters for quick negative checks
- Memoizing recursive subtype computations

### 3.6 Incremental Resolver
**File:** `resolver/resolver.cc`

The resolver can be incremental for certain changes. Ensure your edits trigger fast path:
- Method body changes: Fast path
- Signature changes: May trigger slow path
- Class hierarchy changes: Slow path

---

## 4. Code-Level Optimizations

### 4.1 Reduce Dynamic Allocations in Hot Paths

**Pattern to avoid:**
```cpp
std::vector<T> result;
for (...) {
    result.push_back(item);  // May reallocate
}
```

**Better pattern:**
```cpp
InlinedVector<T, N> result;
result.reserve(expectedSize);  // Pre-allocate if known
for (...) {
    result.push_back(item);
}
```

### 4.2 Use string_view Instead of string
Already widely used, but ensure consistency:
```cpp
// Good
void process(std::string_view name);

// Avoid
void process(const std::string& name);
```

### 4.3 Move Semantics
Ensure move semantics are used for expensive objects:
```cpp
// Good
return std::move(largeVector);

// Let compiler decide for NRVO
LargeObject result;
// ... build result
return result;  // NRVO applies
```

### 4.4 Avoid Unnecessary Type Copies
```cpp
// Avoid
TypePtr copy = someType;  // Increments refcount

// Prefer references when not storing
const TypePtr& ref = someType;
```

---

## 5. Architecture Optimizations

### 5.1 Lazy Type Instantiation
Defer complex type operations until needed:
- Don't instantiate generic types until required
- Cache instantiated types per-context

### 5.2 Symbol Table Sharding
For very large codebases, consider sharding:
- Partition symbols by namespace/package
- Load shards on demand
- Merge for cross-shard operations

### 5.3 Incremental File Hashing
**File:** `core/hashing/hashing.h`

Use incremental hashing for large files:
- Hash file chunks
- Update hash incrementally on edits

### 5.4 Memory-Mapped File I/O
For reading large source files:
- Use mmap for file content
- Lazy parsing of file sections

### 5.5 Compile-Time Optimizations

Build Sorbet with:
```bash
# Release mode with full optimizations
bazel build //main:sorbet --config=release

# Link-time optimization (if supported)
bazel build //main:sorbet --config=release --config=lto
```

---

## 6. Profiling and Monitoring

### 6.1 Enable Counters
```bash
sorbet --counters .
```

### 6.2 Timer Traces
Sorbet has built-in timing via `Timer` class. Enable web traces:
```bash
sorbet --web-trace-file=trace.json .
```
View in Chrome's `chrome://tracing`.

### 6.3 Key Metrics to Monitor
- `cache.committed` / `cache.aborted`
- `lsp.updates.slowpath` / `lsp.updates.fastpath`
- `types.input.files.kvstore.write`

---

## 7. Quick Wins Summary

| Optimization | Impact | Effort | Type |
|-------------|--------|--------|------|
| Enable caching (`--cache-dir`) | High | None | Speed |
| Reduce thread count | Medium | None | Memory |
| Pre-allocate tables | Medium | None | Both |
| Use `intentionallyLeakASTs` | High | Low | Speed |
| Tune InlinedVector sizes | Medium | Medium | Memory |
| Cache method dealiasing | High | High | Speed |
| Profile-guided tuning | High | Medium | Both |

---

## 8. Codebase-Specific Tuning

Run Sorbet with `--counters` to identify bottlenecks specific to your codebase, then focus optimization efforts on:

1. **High symbol counts:** Increase table pre-allocation
2. **Many type checks:** Focus on subtyping optimization
3. **Large files:** Tune cache streaming threshold
4. **Frequent edits (LSP):** Optimize fast path coverage
5. **Deep inheritance:** Cache linearization results
