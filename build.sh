#!/bin/sh -ex

export SOURCE_DATE_EPOCH=$(git log -1 --format=%ct)

WASI_VER=32
WASI_SDK=wasi-sdk-${WASI_VER}.0-x86_64-linux
WASI_SDK_URL=https://github.com/WebAssembly/wasi-sdk/releases/download/wasi-sdk-${WASI_VER}/${WASI_SDK}.tar.gz
if ! [ -d ${WASI_SDK} ]; then curl -L ${WASI_SDK_URL} | tar xzf -; fi
WASI_SDK_PATH=$(pwd)/${WASI_SDK}

# Firebox Phase 1.2 override: if FIREBOX_SYSROOT is set, link the LLVM
# binary itself against our patched wasix-libc instead of stock wasi-libc.
# This is what gives the rebuilt clang fork/exec/proc_spawn semantics so
# the driver can subprocess cc1 + wasm-ld at runtime inside Firebox.
#
# Note: only the LLVM binary's own linkage changes (WASI_CFLAGS_LLVM +
# WASI_LDFLAGS_LLVM). The compiler-rt / wasi-libc / libcxx runtime
# artifacts installed into wasi-prefix/ still build against upstream
# wasi-sdk until Phase 1.2c layers EH/PIC variants on top.
if [ -n "${FIREBOX_SYSROOT:-}" ]; then
    WASI_TARGET="${FIREBOX_TARGET:-wasm32-wasi-threads}"
    # Default target triple the BUILT clang driver will emit when invoked
    # without -target. wasi-sdk-32's pthread toolchain uses the deprecated
    # "wasm32-wasi-threads" internally for its own library layout; the
    # modern equivalent is "wasm32-wasip1-threads" and is what we want the
    # rebuilt clang to default to. Decouple these: build-time library
    # resolution uses WASI_TARGET (wasm32-wasi-threads); the driver's
    # emitted default triple uses FIREBOX_DEFAULT_TRIPLE.
    FIREBOX_DEFAULT_TRIPLE="${FIREBOX_DEFAULT_TRIPLE:-wasm32-wasip1-threads}"
    # wasi-sdk-pthread.cmake (selected below when FIREBOX_SYSROOT is set)
    # already provides:
    #   - triple = wasm32-wasi-threads
    #   - CMAKE_C_COMPILER_TARGET / CXX / ASM
    #   - -pthread in C/CXX flags
    #   - -Wl,--import-memory -Wl,--export-memory in linker flags
    #
    # We add: atomics + bulk-memory + mutable-globals features (required
    # by our sysroot; pthread toolchain doesn't pass them), --shared-memory
    # for the memory segment config, and -L for wasi-sdk's libc++/libc++abi
    # (our sysroot only has libc — libcxx comes from wasi-sdk's prebuilt in
    # Phase 1.2a; Phase 1.2c will replace with a libcxx built against our
    # sysroot + EH).
    # C++ headers: use wasi-sdk's prebuilt threads-variant c++/v1 tree via
    # -isystem (-I would come after sysroot auto-discovery which finds
    # nothing in our sysroot and gives up).
    FIREBOX_WASI_CFLAGS_LLVM="-matomics -mbulk-memory -mmutable-globals -mthread-model posix -isystem ${WASI_SDK_PATH}/share/wasi-sysroot/include/wasm32-wasi-threads/c++/v1"
    # Library search order matters: our sysroot MUST come first so that
    # -lc resolves to our wasix-libc (which has __wasi_init_signals,
    # __wasi_proc_exit2 etc.) before clang's auto-search reaches wasi-sdk.
    FIREBOX_WASI_LDFLAGS_LLVM="-L${FIREBOX_SYSROOT}/lib/${WASI_TARGET} -Wl,--shared-memory,--max-memory=4294967296 -L${WASI_SDK_PATH}/share/wasi-sysroot/lib/wasm32-wasi-threads"
    # #119 Phase 1.2c: force retention of wasix-libc's subprocess wrappers
    # so LTO's whole-program DCE can't prune the __wasi_proc_spawn2 /
    # __wasi_proc_fork / __wasi_proc_exec2 imports out of the driver.
    #
    # Context: YoWASP's upstream design tests the built driver only with
    # "clang --version", which never reaches llvm::sys::ExecuteAndWait —
    # so Thin-LTO DCEs the entire posix_spawn call graph along with the
    # wasix imports. In-sandbox self-hosting REQUIRES the driver to
    # subprocess cc1 and wasm-ld, which needs those imports live.
    #
    # The fix is surgical: --undefined=<sym> forces the linker to treat
    # <sym> as referenced from the root, which anchors its call graph
    # against LTO DCE and pulls the needed .o from libc.a. We pin the
    # POSIX-level wrappers (posix_spawn, fork, execve, execvp, waitpid)
    # AND the low-level wasix-libc imports (__wasi_proc_spawn2,
    # __wasi_proc_fork, __wasi_proc_exec2, __wasi_proc_join) so both
    # layers are retained regardless of which one the driver ends up
    # calling after Thin-LTO's cross-module inlining.
    FIREBOX_WASI_LDFLAGS_LLVM="${FIREBOX_WASI_LDFLAGS_LLVM} \
-Wl,--undefined=posix_spawn \
-Wl,--undefined=fork \
-Wl,--undefined=execve \
-Wl,--undefined=execvp \
-Wl,--undefined=waitpid \
-Wl,--undefined=__wasi_proc_spawn2 \
-Wl,--undefined=__wasi_proc_fork \
-Wl,--undefined=__wasi_proc_exec2 \
-Wl,--undefined=__wasi_proc_join"
else
    WASI_TARGET="wasm32-wasip1"
    FIREBOX_DEFAULT_TRIPLE="wasm32-wasip1"
    FIREBOX_WASI_CFLAGS_LLVM=""
    FIREBOX_WASI_LDFLAGS_LLVM=""
fi

WASI_CFLAGS="--sysroot ${WASI_SDK_PATH}/share/wasi-sysroot -mcpu=lime1"
WASI_LDFLAGS="--sysroot ${WASI_SDK_PATH}/share/wasi-sysroot"
if [ -n "${FIREBOX_SYSROOT:-}" ]; then
    WASI_CFLAGS_LLVM="${FIREBOX_WASI_CFLAGS_LLVM}"
    WASI_LDFLAGS_LLVM="${FIREBOX_WASI_LDFLAGS_LLVM}"
else
    WASI_CFLAGS_LLVM="${WASI_CFLAGS}"
    WASI_LDFLAGS_LLVM="${WASI_LDFLAGS}"
fi
# LLVM has some (unreachable in our configuration) calls to mmap.
WASI_CFLAGS_LLVM="${WASI_CFLAGS_LLVM} -D_WASI_EMULATED_MMAN"
WASI_LDFLAGS_LLVM="${WASI_LDFLAGS_LLVM} -lwasi-emulated-mman"
# Depending on the code being compiled, both Clang and LLD can consume unbounded amounts of memory.
WASI_LDFLAGS_LLVM="${WASI_LDFLAGS_LLVM} -Wl,--max-memory=4294967296"
# Compiling C++ code requires a lot of stack space and can overflow and corrupt the heap.
# (For example, `#include <iostream>` alone does it in a build with the default stack size.)
WASI_LDFLAGS_LLVM="${WASI_LDFLAGS_LLVM} -Wl,-z,stack-size=8388608,--stack-first"
# Some of the host APIs that are statically required by LLVM (notably threading) are dynamically
# never used. An LTO build removes imports of these APIs, simplifying deployment.
WASI_CFLAGS_LLVM="${WASI_CFLAGS_LLVM} -flto"
WASI_LDFLAGS_LLVM="${WASI_LDFLAGS_LLVM} -flto -Wl,--strip-all"

cat >Toolchain-WASI.cmake <<END
include(${WASI_SDK_PATH}/share/cmake/wasi-sdk-p1.cmake)
set(CMAKE_C_FLAGS "${WASI_CFLAGS}")
set(CMAKE_CXX_FLAGS "${WASI_CFLAGS}")
set(CMAKE_EXE_LINKER_FLAGS "${WASI_LDFLAGS}")
END
if [ -n "${FIREBOX_SYSROOT:-}" ]; then
    # Use wasi-sdk's pthread toolchain — it already sets the right triple
    # (wasm32-wasi-threads), CMAKE_C_COMPILER_TARGET, --import-memory,
    # --export-memory, and -pthread. We override CMAKE_SYSROOT to point
    # at our patched wasix-libc sysroot.
    #
    # BUG WORKAROUND: wasi-sdk-pthread.cmake (unlike wasi-sdk-p1.cmake)
    # does NOT append the cmake dir to CMAKE_MODULE_PATH, which means
    # Platform/WASI.cmake (which sets WASI=1) never loads. Downstream,
    # LLVM's HandleLLVMOptions.cmake fails with "Unable to determine
    # platform" because elseif(WASI) evaluates false. Fix by prepending
    # the wasi-sdk cmake dir to CMAKE_MODULE_PATH ourselves.
    cat >Toolchain-WASI-LLVM.cmake <<END
list(APPEND CMAKE_MODULE_PATH "${WASI_SDK_PATH}/share/cmake")
include(${WASI_SDK_PATH}/share/cmake/wasi-sdk-pthread.cmake)
set(CMAKE_SYSROOT "${FIREBOX_SYSROOT}")
set(CMAKE_C_FLAGS "${WASI_CFLAGS_LLVM}")
set(CMAKE_CXX_FLAGS "${WASI_CFLAGS_LLVM}")
set(CMAKE_EXE_LINKER_FLAGS "${WASI_LDFLAGS_LLVM}")
END
else
    cat >Toolchain-WASI-LLVM.cmake <<END
include(${WASI_SDK_PATH}/share/cmake/wasi-sdk-p1.cmake)
set(CMAKE_C_FLAGS "${WASI_CFLAGS_LLVM}")
set(CMAKE_CXX_FLAGS "${WASI_CFLAGS_LLVM}")
set(CMAKE_EXE_LINKER_FLAGS "${WASI_LDFLAGS_LLVM}")
END
fi

# The clang binary built as `Debug` doesn't pass Wasm validation.
# (This has cost me a hour of my life.)

LLVM_VERSION_MAJOR=$(cmake -P Get-LLVM-Version.cmake 2>&1)

if ! [ -f llvm-tblgen-build/bin/llvm-tblgen -a -f llvm-tblgen-build/bin/clang-tblgen ]; then
  mkdir -p llvm-tblgen-build
  cmake -B llvm-tblgen-build -S llvm-src/llvm \
    -DLLVM_CCACHE_BUILD=ON \
    -DCMAKE_BUILD_TYPE=MinSizeRel \
    -DLLVM_BUILD_RUNTIME=OFF \
    -DLLVM_BUILD_TOOLS=OFF \
    -DLLVM_INCLUDE_UTILS=OFF \
    -DLLVM_INCLUDE_RUNTIMES=OFF \
    -DLLVM_INCLUDE_EXAMPLES=OFF \
    -DLLVM_INCLUDE_TESTS=OFF \
    -DLLVM_INCLUDE_BENCHMARKS=OFF \
    -DLLVM_INCLUDE_DOCS=OFF \
    -DLLVM_TARGETS_TO_BUILD=WebAssembly \
    -DLLVM_DEFAULT_TARGET_TRIPLE=${WASI_TARGET} \
    -DLLVM_ENABLE_PROJECTS="clang" \
    -DCLANG_BUILD_EXAMPLES=OFF \
    -DCLANG_BUILD_TOOLS=OFF \
    -DCLANG_INCLUDE_TESTS=OFF
  cmake --build llvm-tblgen-build --target llvm-tblgen --target clang-tblgen
fi

mkdir -p llvm-build
cmake -B llvm-build -S llvm-src/llvm \
  -DCMAKE_TOOLCHAIN_FILE=../Toolchain-WASI-LLVM.cmake \
  -DLLVM_CCACHE_BUILD=ON \
  -DLLVM_NATIVE_TOOL_DIR=$(pwd)/llvm-tblgen-build/bin \
  -DCMAKE_BUILD_TYPE=MinSizeRel \
  -DLLVM_ENABLE_ASSERTIONS=ON \
  -DLLVM_BUILD_SHARED_LIBS=OFF \
  -DLLVM_ENABLE_PIC=OFF \
  -DLLVM_BUILD_STATIC=ON \
  -DLLVM_ENABLE_THREADS=OFF \
  -DLLVM_BUILD_RUNTIME=OFF \
  -DLLVM_BUILD_TOOLS=OFF \
  -DLLVM_INCLUDE_UTILS=OFF \
  -DLLVM_BUILD_UTILS=OFF \
  -DLLVM_INCLUDE_RUNTIMES=OFF \
  -DLLVM_INCLUDE_EXAMPLES=OFF \
  -DLLVM_INCLUDE_TESTS=OFF \
  -DLLVM_INCLUDE_BENCHMARKS=OFF \
  -DLLVM_INCLUDE_DOCS=OFF \
  -DLLVM_TARGETS_TO_BUILD=WebAssembly \
  -DLLVM_DEFAULT_TARGET_TRIPLE=${FIREBOX_DEFAULT_TRIPLE} \
  -DLLVM_TOOL_BUGPOINT_BUILD=OFF \
  -DLLVM_TOOL_BUGPOINT_PASSES_BUILD=OFF \
  -DLLVM_TOOL_DSYMUTIL_BUILD=OFF \
  -DLLVM_TOOL_DXIL_DIS_BUILD=OFF \
  -DLLVM_TOOL_GOLD_BUILD=OFF \
  -DLLVM_TOOL_LLC_BUILD=OFF \
  -DLLVM_TOOL_LLI_BUILD=OFF \
  -DLLVM_TOOL_LLVM_AR_BUILD=ON \
  -DLLVM_TOOL_LLVM_AS_BUILD=OFF \
  -DLLVM_TOOL_LLVM_AS_FUZZER_BUILD=OFF \
  -DLLVM_TOOL_LLVM_BCANALYZER_BUILD=OFF \
  -DLLVM_TOOL_LLVM_CAT_BUILD=OFF \
  -DLLVM_TOOL_LLVM_CFI_VERIFY_BUILD=OFF \
  -DLLVM_TOOL_LLVM_CONFIG_BUILD=OFF \
  -DLLVM_TOOL_LLVM_COV_BUILD=OFF \
  -DLLVM_TOOL_LLVM_CVTRES_BUILD=OFF \
  -DLLVM_TOOL_LLVM_CXXDUMP_BUILD=OFF \
  -DLLVM_TOOL_LLVM_CXXFILT_BUILD=ON \
  -DLLVM_TOOL_LLVM_CXXMAP_BUILD=OFF \
  -DLLVM_TOOL_LLVM_C_TEST_BUILD=OFF \
  -DLLVM_TOOL_LLVM_DEBUGINFOD_BUILD=OFF \
  -DLLVM_TOOL_LLVM_DEBUGINFOD_FIND_BUILD=OFF \
  -DLLVM_TOOL_LLVM_DEBUGINFO_ANALYZER_BUILD=OFF \
  -DLLVM_TOOL_LLVM_DIFF_BUILD=OFF \
  -DLLVM_TOOL_LLVM_DIS_BUILD=OFF \
  -DLLVM_TOOL_LLVM_DIS_FUZZER_BUILD=OFF \
  -DLLVM_TOOL_LLVM_DLANG_DEMANGLE_FUZZER_BUILD=OFF \
  -DLLVM_TOOL_LLVM_DRIVER_BUILD=ON \
  -DLLVM_TOOL_LLVM_DWARFDUMP_BUILD=ON \
  -DLLVM_TOOL_LLVM_DWARFUTIL_BUILD=OFF \
  -DLLVM_TOOL_LLVM_DWP_BUILD=OFF \
  -DLLVM_TOOL_LLVM_EXEGESIS_BUILD=OFF \
  -DLLVM_TOOL_LLVM_EXTRACT_BUILD=OFF \
  -DLLVM_TOOL_LLVM_GSYMUTIL_BUILD=OFF \
  -DLLVM_TOOL_LLVM_IFS_BUILD=OFF \
  -DLLVM_TOOL_LLVM_ISEL_FUZZER_BUILD=OFF \
  -DLLVM_TOOL_LLVM_ITANIUM_DEMANGLE_FUZZER_BUILD=OFF \
  -DLLVM_TOOL_LLVM_JITLINK_BUILD=OFF \
  -DLLVM_TOOL_LLVM_JITLISTENER_BUILD=OFF \
  -DLLVM_TOOL_LLVM_LIBTOOL_DARWIN_BUILD=OFF \
  -DLLVM_TOOL_LLVM_LINK_BUILD=OFF \
  -DLLVM_TOOL_LLVM_LIPO_BUILD=OFF \
  -DLLVM_TOOL_LLVM_LTO2_BUILD=OFF \
  -DLLVM_TOOL_LLVM_LTO_BUILD=OFF \
  -DLLVM_TOOL_LLVM_MCA_BUILD=OFF \
  -DLLVM_TOOL_LLVM_MC_ASSEMBLE_FUZZER_BUILD=OFF \
  -DLLVM_TOOL_LLVM_MC_BUILD=OFF \
  -DLLVM_TOOL_LLVM_MC_DISASSEMBLE_FUZZER_BUILD=OFF \
  -DLLVM_TOOL_LLVM_MICROSOFT_DEMANGLE_FUZZER_BUILD=OFF \
  -DLLVM_TOOL_LLVM_ML_BUILD=OFF \
  -DLLVM_TOOL_LLVM_MODEXTRACT_BUILD=OFF \
  -DLLVM_TOOL_LLVM_MT_BUILD=OFF \
  -DLLVM_TOOL_LLVM_NM_BUILD=ON \
  -DLLVM_TOOL_LLVM_OBJCOPY_BUILD=ON \
  -DLLVM_TOOL_LLVM_OBJDUMP_BUILD=ON \
  -DLLVM_TOOL_LLVM_OPT_FUZZER_BUILD=OFF \
  -DLLVM_TOOL_LLVM_OPT_REPORT_BUILD=OFF \
  -DLLVM_TOOL_LLVM_PDBUTIL_BUILD=OFF \
  -DLLVM_TOOL_LLVM_PROFDATA_BUILD=OFF \
  -DLLVM_TOOL_LLVM_PROFGEN_BUILD=OFF \
  -DLLVM_TOOL_LLVM_RC_BUILD=OFF \
  -DLLVM_TOOL_LLVM_READOBJ_BUILD=ON \
  -DLLVM_TOOL_LLVM_READTAPI_BUILD=OFF \
  -DLLVM_TOOL_LLVM_REDUCE_BUILD=OFF \
  -DLLVM_TOOL_LLVM_REMARKUTIL_BUILD=OFF \
  -DLLVM_TOOL_LLVM_RTDYLD_BUILD=OFF \
  -DLLVM_TOOL_LLVM_RUST_DEMANGLE_FUZZER_BUILD=OFF \
  -DLLVM_TOOL_LLVM_SHLIB_BUILD=OFF \
  -DLLVM_TOOL_LLVM_SIM_BUILD=OFF \
  -DLLVM_TOOL_LLVM_SIZE_BUILD=ON \
  -DLLVM_TOOL_LLVM_SPECIAL_CASE_LIST_FUZZER_BUILD=OFF \
  -DLLVM_TOOL_LLVM_SPLIT_BUILD=OFF \
  -DLLVM_TOOL_LLVM_STRESS_BUILD=OFF \
  -DLLVM_TOOL_LLVM_STRINGS_BUILD=OFF \
  -DLLVM_TOOL_LLVM_SYMBOLIZER_BUILD=ON \
  -DLLVM_TOOL_LLVM_TLI_CHECKER_BUILD=OFF \
  -DLLVM_TOOL_LLVM_UNDNAME_BUILD=OFF \
  -DLLVM_TOOL_LLVM_XRAY_BUILD=OFF \
  -DLLVM_TOOL_LLVM_YAML_NUMERIC_PARSER_FUZZER_BUILD=OFF \
  -DLLVM_TOOL_LLVM_YAML_PARSER_FUZZER_BUILD=OFF \
  -DLLVM_TOOL_LTO_BUILD=OFF \
  -DLLVM_TOOL_OBJ2YAML_BUILD=OFF \
  -DLLVM_TOOL_OPT_BUILD=OFF \
  -DLLVM_TOOL_OPT_VIEWER_BUILD=OFF \
  -DLLVM_TOOL_REDUCE_CHUNK_LIST_BUILD=OFF \
  -DLLVM_TOOL_REMARKS_SHLIB_BUILD=OFF \
  -DLLVM_TOOL_SANCOV_BUILD=OFF \
  -DLLVM_TOOL_SANSTATS_BUILD=OFF \
  -DLLVM_TOOL_SPIRV_TOOLS_BUILD=OFF \
  -DLLVM_TOOL_VERIFY_USELISTORDER_BUILD=OFF \
  -DLLVM_TOOL_VFABI_DEMANGLE_FUZZER_BUILD=OFF \
  -DLLVM_TOOL_XCODE_TOOLCHAIN_BUILD=OFF \
  -DLLVM_TOOL_YAML2OBJ_BUILD=OFF \
  -DLLVM_ENABLE_PROJECTS="clang;lld" \
  -DCLANG_ENABLE_ARCMT=OFF \
  -DCLANG_ENABLE_STATIC_ANALYZER=OFF \
  -DCLANG_INCLUDE_TESTS=OFF \
  -DCLANG_BUILD_TOOLS=OFF \
  -DCLANG_TOOL_CLANG_SCAN_DEPS_BUILD=OFF \
  -DCLANG_TOOL_CLANG_INSTALLAPI_BUILD=OFF \
  -DCLANG_BUILD_EXAMPLES=OFF \
  -DCLANG_INCLUDE_DOCS=OFF \
  -DCLANG_LINKS_TO_CREATE="clang;clang++" \
  -DLLD_BUILD_TOOLS=OFF \
  -DCMAKE_INSTALL_PREFIX=llvm-prefix \
  -DDEFAULT_SYSROOT=/usr \
  -DCLANG_RESOURCE_DIR=/usr
# The "all" target still contains far too much stuff, even given all the options above, so build
# only Clang/LLD, explicitly. For the same reason using the "install" target is infeasible.
# I spent a while trying and it leads nowhere.
cmake --build llvm-build --target llvm-driver
cmake --build llvm-build --target clang-resource-headers

# Install the headers manually.
# Install the headers also manually.
mkdir -p wasi-prefix/usr/
rm -rf wasi-prefix/usr/include
cp -v -r llvm-build/usr/include wasi-prefix/usr/

# Options below heavily based on wasi-sdk.
mkdir -p compiler-rt-build
cmake -B compiler-rt-build -S llvm-src/compiler-rt \
  -DCMAKE_TOOLCHAIN_FILE=../Toolchain-WASI.cmake \
  -DCOMPILER_RT_BAREMETAL_BUILD=ON \
  -DCOMPILER_RT_BUILD_XRAY=OFF \
  -DCOMPILER_RT_INCLUDE_TESTS=OFF \
  -DCOMPILER_RT_HAS_FPIC_FLAG=OFF \
  -DCOMPILER_RT_ENABLE_IOS=OFF \
  -DCOMPILER_RT_DEFAULT_TARGET_ONLY=ON \
  -DLLVM_ENABLE_PER_TARGET_RUNTIME_DIR=ON \
  -DCMAKE_INSTALL_PREFIX=wasi-prefix/usr
cmake --build compiler-rt-build --target install

# There are many false positives with `check-symbols`, and the upstream eventually
# moved to not check it by default too.
mkdir -p wasi-libc-build
cmake -B wasi-libc-build -S wasi-libc-src \
  -DCMAKE_TOOLCHAIN_FILE=../Toolchain-WASI.cmake \
  -DCMAKE_C_COMPILER_LAUNCHER=ccache \
  -DCMAKE_CXX_COMPILER_LAUNCHER=ccache \
  -DTARGET_TRIPLE=${WASI_TARGET} \
  -DBUILTINS_LIB=$(pwd)/wasi-prefix/usr/lib/wasm32-unknown-wasip1/libclang_rt.builtins.a \
  -DCMAKE_INSTALL_PREFIX=wasi-prefix/usr
cmake --build wasi-libc-build --target install

# Options below heavily based on wasi-sdk.
mkdir -p libcxx-build
cmake -B libcxx-build -S llvm-src/runtimes \
  -DCMAKE_TOOLCHAIN_FILE=../Toolchain-WASI.cmake \
  -DLLVM_ENABLE_RUNTIMES:STRING="libcxx;libcxxabi" \
  -DLIBCXX_ENABLE_THREADS:BOOL=ON \
  -DLIBCXX_BUILD_EXTERNAL_THREAD_LIBRARY:BOOL=ON \
  -DLIBCXX_ENABLE_SHARED:BOOL=OFF \
  -DLIBCXX_ENABLE_EXCEPTIONS:BOOL=OFF \
  -DLIBCXX_ENABLE_FILESYSTEM:BOOL=ON \
  -DLIBCXX_ENABLE_EXPERIMENTAL_LIBRARY:BOOL=OFF \
  -DLIBCXX_ENABLE_ABI_LINKER_SCRIPT:BOOL=OFF \
  -DLIBCXX_CXX_ABI=libcxxabi \
  -DLIBCXX_CXX_ABI_INCLUDE_PATHS=$(pwd)/llvm-src/libcxxabi/include \
  -DLIBCXX_HAS_MUSL_LIBC:BOOL=ON \
  -DLIBCXX_ABI_VERSION=2 \
  -DLIBCXXABI_ENABLE_THREADS:BOOL=ON \
  -DLIBCXXABI_BUILD_EXTERNAL_THREAD_LIBRARY:BOOL=ON \
  -DLIBCXXABI_ENABLE_PIC:BOOL=OFF \
  -DLIBCXXABI_ENABLE_SHARED:BOOL=OFF \
  -DLIBCXXABI_ENABLE_EXCEPTIONS:BOOL=OFF \
  -DLIBCXXABI_USE_LLVM_UNWINDER:BOOL=OFF \
  -DLIBCXXABI_SILENT_TERMINATE:BOOL=ON \
  -DLIBCXX_LIBDIR_SUFFIX=/${WASI_TARGET} \
  -DLIBCXXABI_LIBDIR_SUFFIX=/${WASI_TARGET} \
  -DCMAKE_INSTALL_PREFIX=wasi-prefix/usr
cmake --build libcxx-build --target install
