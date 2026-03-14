; ============================================================
; calc_linux_32.asm - 纯汇编四则运算 Demo（Linux i386）
; ============================================================
; 功能：控制台输入两数及运算类型，输出和/差/积/商
; 实现：int 0x80 系统调用（Linux i386 传统方式），无 C 库
; 平台：Linux x86 32 位
; 编译：nasm -f elf32 calc_linux_32.asm -o calc_linux_32.o
; 链接：ld -m elf_i386 -e _start -o calc_linux_32 calc_linux_32.o
;
; 与 calc_linux.asm 逻辑相同，差异：
;   - 使用 int 0x80 而非 syscall
;   - 参数：EAX=调用号, EBX/ECX/EDX=第1/2/3 参
;   - read=3, write=4, exit=1
;   - syscall_write/read 用 cdecl 栈传参
; ============================================================

bits 32

; ============ 常量定义 ============
%define SCALE 1000000

; Linux i386 系统调用号（unistd_32.h）
%define SYS_read  3    ; read(fd, buf, count)
%define SYS_write 4    ; write(fd, buf, count)
%define SYS_exit  1    ; _exit(status)

%define STDIN_FD  0
%define STDOUT_FD 1

; ============ 只读数据段 ============
section .data
    prompt1    db "Enter first number (int or decimal, negative ok): ", 0
    prompt1_len equ $-prompt1
    prompt2    db "Enter second number (int or decimal, negative ok): ", 0
    prompt2_len equ $-prompt2
    prompt_op  db "Operation (1=add 2=sub 3=mul 4=div): ", 0
    prompt_op_len equ $-prompt_op
    result_msg db "Result: ", 0
    result_msg_len equ $-result_msg
    result_nl  db 10, 0
    result_nl_len equ $-result_nl
    err_div_zero    db "Error: division by zero", 10, 0
    err_div_zero_len equ $-err_div_zero
    scale_val   dd 1000000

; ============ 未初始化数据段 ============
section .bss
    bytes_read resd 1
    buf1       resb 32
    buf2       resb 32
    buf_op     resb 8
    out_buf    resb 32

; ============ 代码段 ============
section .text
    global _start

; ---------------------------------------------------------------
; syscall_write: Linux write(fd, buf, len) - cdecl: (fd, buf, len)
; ---------------------------------------------------------------
syscall_write:
    push ebp
    mov ebp, esp
    mov ebx, [ebp+8]
    mov ecx, [ebp+12]
    mov edx, [ebp+16]
    mov eax, SYS_write
    int 0x80
    pop ebp
    ret

; ---------------------------------------------------------------
; syscall_read: Linux read(fd, buf, len) - 返回 EAX=实际读取字节数
; ---------------------------------------------------------------
syscall_read:
    push ebp
    mov ebp, esp
    mov ebx, [ebp+8]
    mov ecx, [ebp+12]
    mov edx, [ebp+16]
    mov eax, SYS_read
    int 0x80
    pop ebp
    ret

; ---------------------------------------------------------------
; parse_fixed_point: 将字符串解析为定点数
; 输入：ECX=字符串指针  输出：EAX=定点数
; ---------------------------------------------------------------
parse_fixed_point:
    push ebp
    mov ebp, esp
    push ebx
    push esi
    push edi
    mov esi, ecx
    xor eax, eax
    mov ebx, 1
.parse_skip_spaces:
    movzx ecx, byte [esi]
    cmp cl, ' '
    je .parse_skip_inc
    cmp cl, 9
    je .parse_skip_inc
    jmp .parse_check_sign
.parse_skip_inc:
    inc esi
    jmp .parse_skip_spaces
.parse_check_sign:
    cmp cl, '-'
    jne .parse_check_plus
    mov ebx, -1
    inc esi
    jmp .parse_int_part
.parse_check_plus:
    cmp cl, '+'
    jne .parse_int_part
    inc esi
.parse_int_part:
    movzx ecx, byte [esi]
    cmp cl, '0'
    jb .parse_frac_check
    cmp cl, '9'
    ja .parse_frac_check
    imul eax, 10
    sub cl, '0'
    add eax, ecx
    inc esi
    jmp .parse_int_part
.parse_frac_check:
    cmp cl, '.'
    jne .parse_scale_only
    inc esi
    xor edi, edi
    xor ecx, ecx
.parse_frac_loop:
    movzx edx, byte [esi]
    cmp dl, '0'
    jb .parse_frac_pad
    cmp dl, '9'
    ja .parse_frac_pad
    cmp ecx, 6
    jge .parse_frac_loop_inc
    imul edi, 10
    sub dl, '0'
    add edi, edx
    inc ecx
.parse_frac_loop_inc:
    inc esi
    jmp .parse_frac_loop
.parse_frac_pad:
    push ecx
    mov ecx, 6
    pop eax
    sub ecx, eax
.parse_frac_pad_loop:
    test ecx, ecx
    jz .parse_frac_done
    imul edi, 10
    dec ecx
    jmp .parse_frac_pad_loop
.parse_frac_done:
    imul eax, SCALE
    add eax, edi
    jmp .parse_apply_sign
.parse_scale_only:
    imul eax, SCALE
.parse_apply_sign:
    imul eax, ebx
    pop edi
    pop esi
    pop ebx
    pop ebp
    ret

; ---------------------------------------------------------------
; format_fixed_point: 将定点数格式化为字符串
; 输入：ECX=定点数, EDX=输出缓冲区  输出：EAX=字符串长度
; ---------------------------------------------------------------
format_fixed_point:
    push ebp
    mov ebp, esp
    sub esp, 16
    push ebx
    push esi
    push edi
    mov ebx, ecx
    mov edi, edx
    mov [ebp-4], edx
    xor ecx, ecx
    test ebx, ebx
    jns .fmt_pos
    mov ecx, 1
    neg ebx
.fmt_pos:
    mov eax, ebx
    cdq
    mov esi, [scale_val]
    test esi, esi
    jz report_div_zero_error
    idiv esi
    mov [ebp-8], eax
    mov [ebp-12], edx
    test ecx, ecx
    jz .fmt_int
    mov byte [edi], '-'
    inc edi
.fmt_int:
    mov eax, [ebp-8]
    test eax, eax
    jnz .fmt_digits
    mov byte [edi], '0'
    inc edi
    jmp .fmt_dot
.fmt_digits:
    xor ecx, ecx
.fmt_dig_loop:
    xor edx, edx
    mov eax, [ebp-8]
    mov ebx, 10
    div ebx
    mov [ebp-8], eax
    add dl, '0'
    push edx
    inc ecx
    mov eax, [ebp-8]
    test eax, eax
    jnz .fmt_dig_loop
.fmt_out:
    test ecx, ecx
    jz .fmt_dot
    pop edx
    mov byte [edi], dl
    inc edi
    dec ecx
    jmp .fmt_out
.fmt_dot:
    mov eax, [ebp-12]
    test eax, eax
    jz .fmt_end
    mov byte [edi], '.'
    inc edi
    mov esi, 100000
    mov ecx, 6
.fmt_frac:
    mov eax, [ebp-12]
    xor edx, edx
    div esi
    add al, '0'
    mov byte [edi], al
    inc edi
    mov eax, [ebp-12]
    xor edx, edx
    div esi
    mov [ebp-12], edx
    mov eax, esi
    xor edx, edx
    mov ebx, 10
    div ebx
    mov esi, eax
    dec ecx
    jnz .fmt_frac
.fmt_end:
    mov byte [edi], 0
    mov eax, edi
    sub eax, [ebp-4]
    dec eax
    pop edi
    pop esi
    pop ebx
    add esp, 16
    pop ebp
    ret

; ---------------------------------------------------------------
; null_terminate_read_buf
; ---------------------------------------------------------------
null_terminate_read_buf:
    push ebx
    xor ebx, ebx
.nt_loop:
    cmp ebx, edx
    jge .nt_add_null
    movzx eax, byte [ecx + ebx]
    cmp al, 0x0d
    je .nt_replace
    cmp al, 0x0a
    je .nt_replace
    inc ebx
    jmp .nt_loop
.nt_replace:
    mov byte [ecx + ebx], 0
    pop ebx
    ret
.nt_add_null:
    mov byte [ecx + edx], 0
    pop ebx
    ret

; ---------------------------------------------------------------
; report_div_zero_error
; ---------------------------------------------------------------
report_div_zero_error:
    push dword err_div_zero_len
    push dword err_div_zero
    push dword STDOUT_FD
    call syscall_write
    add esp, 12
    mov eax, SYS_exit
    mov ebx, 1
    int 0x80

; ---------------------------------------------------------------
; _start: 程序入口
; ---------------------------------------------------------------
_start:
    push ebp
    mov ebp, esp
    sub esp, 16

    push dword prompt1_len
    push dword prompt1
    push dword STDOUT_FD
    call syscall_write
    add esp, 12
    push dword 31
    push dword buf1
    push dword STDIN_FD
    call syscall_read
    add esp, 12
    mov [bytes_read], eax
    mov ecx, buf1
    mov edx, [bytes_read]
    call null_terminate_read_buf

    push dword prompt2_len
    push dword prompt2
    push dword STDOUT_FD
    call syscall_write
    add esp, 12
    push dword 31
    push dword buf2
    push dword STDIN_FD
    call syscall_read
    add esp, 12
    mov [bytes_read], eax
    mov ecx, buf2
    mov edx, [bytes_read]
    call null_terminate_read_buf

    push dword prompt_op_len
    push dword prompt_op
    push dword STDOUT_FD
    call syscall_write
    add esp, 12
    push dword 7
    push dword buf_op
    push dword STDIN_FD
    call syscall_read
    add esp, 12
    mov ecx, buf_op
    mov edx, eax
    call null_terminate_read_buf

    mov ecx, buf1
    call parse_fixed_point
    mov [ebp-4], eax
    mov ecx, buf2
    call parse_fixed_point
    mov [ebp-8], eax

    movzx eax, byte [buf_op]
    cmp al, '1'
    je .op_add
    cmp al, '2'
    je .op_sub
    cmp al, '3'
    je .op_mul
    cmp al, '4'
    je .op_div
.op_add:
    mov eax, [ebp-4]
    add eax, [ebp-8]
    mov [ebp-4], eax
    jmp .op_done
.op_sub:
    mov eax, [ebp-4]
    sub eax, [ebp-8]
    mov [ebp-4], eax
    jmp .op_done
.op_mul:
    mov eax, [ebp-4]
    imul dword [ebp-8]
    idiv dword [scale_val]
    mov [ebp-4], eax
    jmp .op_done
.op_div:
    mov ecx, [ebp-8]
    test ecx, ecx
    jz report_div_zero_error
    mov eax, [ebp-4]
    imul dword [scale_val]
    idiv ecx
    mov [ebp-4], eax
.op_done:
    mov ecx, [ebp-4]
    mov edx, out_buf
    call format_fixed_point
    mov [ebp-12], eax

    push dword result_msg_len
    push dword result_msg
    push dword STDOUT_FD
    call syscall_write
    add esp, 12
    push dword [ebp-12]
    push dword out_buf
    push dword STDOUT_FD
    call syscall_write
    add esp, 12
    push dword result_nl_len
    push dword result_nl
    push dword STDOUT_FD
    call syscall_write
    add esp, 12

    mov eax, SYS_exit
    xor ebx, ebx
    int 0x80
