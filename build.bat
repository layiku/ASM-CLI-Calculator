@echo off
REM ============================================================
REM 构建脚本 - NASM 四则运算 Demo
REM ============================================================
REM 支持：64 位 Windows、32 位 Windows、DOS（加减乘除）
REM 需要：NASM（汇编器）+ MinGW-w64（gcc，用于 Windows 链接）
REM 输出：calc.exe、calc_32.exe、calc_dos.com
REM 说明：64/32 位需 gcc 链接生成 PE；DOS 版 nasm -f bin 生成纯二进制 COM
REM ============================================================

echo Building 64-bit calc.exe ...
nasm -f win64 calc.asm -o calc.obj
if errorlevel 1 (
    echo [ERROR] NASM 64-bit assembly failed.
    exit /b 1
)
gcc calc.obj -nostdlib -e main -o calc.exe
REM -nostdlib: 不链接 C 运行时
REM -e main: 指定入口点为 main
if errorlevel 1 (
    echo [ERROR] 64-bit linking failed.
    exit /b 1
)

echo Building DOS calc_dos.com ...
REM -f bin: 生成纯二进制（COM 格式），无 PE 头
nasm -f bin calc_dos.asm -o calc_dos.com
if errorlevel 1 (
    echo [ERROR] NASM DOS assembly failed.
    exit /b 1
)

echo Building 32-bit calc_32.exe ...
nasm -f win32 calc_32.asm -o calc_32.obj
REM -f win32: 生成 32 位 Windows COFF 目标文件
if errorlevel 1 (
    echo [ERROR] NASM 32-bit assembly failed.
    exit /b 1
)
gcc calc_32.obj -nostdlib -e _main -m32 -o calc_32.exe
REM -m32: 32 位模式  -e _main: 32 位下入口为 _main
if errorlevel 1 (
    echo [ERROR] 32-bit linking failed.
    exit /b 1
)

echo.
echo Build successful!
echo   calc.exe    - 64 位 Windows (syscall)
echo   calc_32.exe - 32 位 Windows (int 0x2e)
echo   calc_dos.com - DOS (int 21h，需 DOSBox 运行)
