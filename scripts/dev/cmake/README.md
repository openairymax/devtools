# CMake 辅助配置

`tools/scripts/dev/cmake/`

## 概述

`cmake/` 目录提供 AgentRT 构建期使用的 CMake 辅助模块：运行时检测（Sanitizers）、
`find_package` 打包配置、统一构建打印、Windows MSVC 兼容预包含头以及 sanitizer
环境下的 ctest 包装模板。均通过 `include()` / `configure_file()` 方式被各模块
`CMakeLists.txt` 引用，不单独执行。

> **版本**: v0.1.5

## 目录结构

```
cmake/
├── Sanitizers.cmake           # 运行时检测模块（SEC-05/06/08/09）：ASan/LSan/UBSan/TSan/栈保护/FORTIFY
├── AgentRTConfig.cmake.in     # find_package(AgentRT) 打包配置模板，生成 <build>/AgentRTConfig.cmake
├── agentrt_print.cmake        # 统一构建打印系统：airy_print_ok/info/warn/error/fatal/debug/section/status
├── windows_preinclude.h       # Windows MSVC 兼容性预包含头（WIN32_LEAN_AND_MEAN/NOMINMAX 等）
└── ctest_wrapper.sh.in        # ctest 包装模板：自动设置 ASAN/LSAN/UBSAN_OPTIONS 后运行 ctest
```

## 使用方式

### Sanitizers.cmake（运行时检测，SEC-05/06/08/09）

```cmake
include(scripts/dev/cmake/Sanitizers.cmake)
enable_agentrt_sanitizers(TARGET my_target SCOPE PRIVATE)
```

可用 CMake 选项（`cmake -D` 覆盖，默认均为 ON）：

```bash
cmake -DAGENTRT_ENABLE_ASAN=ON \
      -DAGENTRT_ENABLE_UBSAN=ON \
      -DAGENTRT_ENABLE_TSAN=OFF \
      -DAGENTRT_ENABLE_STACK_PROTECTOR=ON \
      -DAGENTRT_ENABLE_FORTIFY=ON ..
```

> TSan 与 ASan/LSan 互斥（TSan 开启时自动关闭 ASan/LSan）；MSVC 及非 GCC/Clang
> 编译器下 sanitizers 自动禁用并给出警告。

### AgentRTConfig.cmake.in（打包配置）

```cmake
# 下游项目使用（atoms 为 header-only INTERFACE 库）
find_package(AgentRT CONFIG REQUIRED)
target_link_libraries(my_target PRIVATE AgentRT::atoms)
```

### agentrt_print.cmake（统一构建打印）

```cmake
include(scripts/dev/cmake/agentrt_print.cmake)
airy_print_section("Building atoms")
airy_print_ok("atoms built")
airy_print_fatal("fatal error")   # 终止构建
```

- 输出格式 `[YYYY-MM-DD HH:MM:SS] [LEVEL] message`，与运行时日志系统对齐；
- 管道/文件重定向时自动禁用彩色，可用环境变量 `AGENTRT_BUILD_COLOR=1/0` 强制开关。

### windows_preinclude.h（MSVC 预包含头）

定义 `WIN32_LEAN_AND_MEAN`、`NOMINMAX`、`_WINSOCKAPI_` 等宏，预包含
`winsock2.h`/`windows.h`/`ws2tcpip.h`，提供 `ssize_t` 别名与
`__attribute__(x)` 空实现。在构建中通过 `/FI` 编译选项强制预包含。

### ctest_wrapper.sh.in（ctest 包装模板）

由 `configure_file()` 生成后可执行脚本，导出 `ASAN_OPTIONS`/`LSAN_OPTIONS`/
`UBSAN_OPTIONS` 后透传调用 `ctest "$@"`，用于 sanitizer 构建下的测试执行。

## 依赖

| 文件 | 核心依赖 | 说明 |
|------|---------|------|
| `Sanitizers.cmake` | CMake 3.20+, GCC/Clang | sanitizers 仅支持 GCC/Clang，MSVC 下自动禁用 |
| `AgentRTConfig.cmake.in` | CMake 3.20+ | 由 configure_package_config_file() 生成 |
| `agentrt_print.cmake` | CMake 3.20+ | 纯 CMake 实现 |
| `windows_preinclude.h` | MSVC 2019+ | 仅在 _MSC_VER 下生效 |
| `ctest_wrapper.sh.in` | Bash, ctest | 由 configure_file() 渲染后使用 |

---

© 2025-2026 SPHARX Ltd. All Rights Reserved.
