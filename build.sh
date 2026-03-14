#!/bin/bash
# ============================================================
# Linux build script - NASM calc Demo
# ============================================================
# Supports: 64-bit, 32-bit, 16-bit (DOS)
# Requires: NASM + ld or gcc
# Output: calc_linux, calc_linux_32, calc_dos.com
# ============================================================
# 64-bit: ./calc_linux
# 32-bit: ./calc_linux_32 (requires i386 or multilib)
# 16-bit: dosbox calc_dos.com (runs in DOSBox)
# ============================================================

set -e

BUILD_64=1
BUILD_32=1
BUILD_16=1

# ---- 64-bit ----
if [ "$BUILD_64" = 1 ]; then
    echo "Building 64-bit calc_linux ..."
    nasm -f elf64 calc_linux.asm -o calc_linux.o
    if ld -e _start -o calc_linux calc_linux.o 2>/dev/null; then
        :
    elif gcc -nostdlib -e _start -o calc_linux calc_linux.o 2>/dev/null; then
        echo "  Linked with gcc."
    else
        echo "[ERROR] 64-bit linking failed."
        exit 1
    fi
fi

# ---- 32-bit ----
if [ "$BUILD_32" = 1 ] && [ -f calc_linux_32.asm ]; then
    echo "Building 32-bit calc_linux_32 ..."
    nasm -f elf32 calc_linux_32.asm -o calc_linux_32.o
    if ld -m elf_i386 -e _start -o calc_linux_32 calc_linux_32.o 2>/dev/null; then
        :
    elif gcc -m32 -nostdlib -e _start -o calc_linux_32 calc_linux_32.o 2>/dev/null; then
        echo "  Linked with gcc -m32."
    else
        echo "[WARN] 32-bit linking failed (need: ld -m elf_i386 or gcc -m32)."
    fi
fi

# ---- 16-bit (DOS) ----
if [ "$BUILD_16" = 1 ] && [ -f calc_dos.asm ]; then
    echo "Building 16-bit calc_dos.com (for DOSBox) ..."
    nasm -f bin calc_dos.asm -o calc_dos.com
fi

echo ""
echo "Build complete!"
[ -f calc_linux     ] && echo "  64-bit: ./calc_linux"
[ -f calc_linux_32  ] && echo "  32-bit: ./calc_linux_32"
[ -f calc_dos.com   ] && echo "  16-bit: dosbox calc_dos.com"
