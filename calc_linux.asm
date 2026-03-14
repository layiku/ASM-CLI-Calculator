; ============================================================
; calc_linux.asm - 纯汇编四则运算 Demo（Linux x64）
; ============================================================
; 功能：控制台输入两数及运算类型，输出和/差/积/商
; 实现：Linux syscall（read/write/exit），无 C 库
; 平台：Linux x86-64
; 编译：nasm -f elf64 calc_linux.asm -o calc_linux.o
; 链接：ld -e _start calc_linux.o -o calc_linux
;
; 程序结构：与 calc.asm 逻辑相同，仅 I/O 不同
;   _start - 入口（无 libc，自行处理）
;   syscall_write/read - write(1,buf,len) / read(0,buf,len)
;   parse_fixed_point / format_fixed_point - 同上
;   stdin=0, stdout=1 固定，无需从环境获取
; ============================================================

bits 64
default rel

; ============ 常量定义 ============
%define SCALE 1000000

; Linux x86-64 系统调用号（unistd_64.h）
%define SYS_read  0    ; ssize_t read(int fd, void *buf, size_t count)
%define SYS_write 1    ; ssize_t write(int fd, const void *buf, size_t count)
%define SYS_exit  60   ; void _exit(int status)

; 标准流文件描述符（固定值）
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

; ============ 未初始化数据段 ============
section .bss
    bytes_read resq 1
    buf1       resb 32
    buf2       resb 32
    buf_op     resb 8
    out_buf    resb 32

; ============ 代码段 ============
section .text
    global _start

; ---------------------------------------------------------------
; syscall_write: Linux write(fd, buf, len)
; 输入：RDI=fd, RSI=buf, RDX=len
; ---------------------------------------------------------------
syscall_write:
    mov rax, SYS_write
    syscall
    ret

; ---------------------------------------------------------------
; syscall_read: Linux read(fd, buf, len)
; 输入：RDI=fd, RSI=buf, RDX=len
; 输出：RAX=实际读取字节数
; ---------------------------------------------------------------
syscall_read:
    mov rax, SYS_read
    syscall
    ret

; ---------------------------------------------------------------
; parse_fixed_point: 将字符串解析为定点数
; 输入：RDI=字符串指针（Linux 第1参）
; 输出：RAX=定点数
; ---------------------------------------------------------------
parse_fixed_point:
    mov rcx, rdi              ; 适配调用约定，RCX=字符串指针
    push rbx
    push rsi
    sub rsp, 32
    mov rsi, rcx
    xor rax, rax
    mov rbx, 1
.parse_skip_spaces:
    movzx ecx, byte [rsi]
    cmp cl, ' '
    je .parse_skip_inc
    cmp cl, 9
    je .parse_skip_inc
    jmp .parse_check_sign
.parse_skip_inc:
    inc rsi
    jmp .parse_skip_spaces
.parse_check_sign:
    cmp cl, '-'
    jne .parse_check_plus
    mov rbx, -1
    inc rsi
    jmp .parse_int_part
.parse_check_plus:
    cmp cl, '+'
    jne .parse_int_part
    inc rsi
.parse_int_part:
    movzx ecx, byte [rsi]
    cmp cl, '0'
    jb .parse_frac_check
    cmp cl, '9'
    ja .parse_frac_check
    imul rax, 10
    sub cl, '0'
    add rax, rcx
    inc rsi
    jmp .parse_int_part
.parse_frac_check:
    cmp cl, '.'
    jne .parse_scale_only
    inc rsi
    xor r8, r8
    xor r9, r9
.parse_frac_loop:
    movzx ecx, byte [rsi]
    cmp cl, '0'
    jb .parse_frac_pad
    cmp cl, '9'
    ja .parse_frac_pad
    cmp r9, 6
    jge .parse_frac_loop_inc
    imul r8, 10
    sub cl, '0'
    add r8, rcx
    inc r9
.parse_frac_loop_inc:
    inc rsi
    jmp .parse_frac_loop
.parse_frac_pad:
    mov rcx, 6
    sub rcx, r9
.parse_frac_pad_loop:
    test rcx, rcx
    jz .parse_frac_done
    imul r8, 10
    dec rcx
    jmp .parse_frac_pad_loop
.parse_frac_done:
    imul rax, SCALE
    add rax, r8
    jmp .parse_apply_sign
.parse_scale_only:
    imul rax, SCALE
.parse_apply_sign:
    imul rax, rbx
    add rsp, 32
    pop rsi
    pop rbx
    ret

; ---------------------------------------------------------------
; format_fixed_point: 将定点数格式化为字符串
; 输入：RDI=定点数, RSI=输出缓冲区（Linux 调用约定）
; 输出：RAX=字符串长度
; ---------------------------------------------------------------
format_fixed_point:
    mov rcx, rdi
    mov rdx, rsi
    push rbx
    push rdi
    push rsi
    push r12
    sub rsp, 48
    mov rbx, rcx
    mov rdi, rdx
    mov r11, rdx
    xor r8, r8
    test rbx, rbx
    jns .fmt_positive
    mov r8, 1
    neg rbx
.fmt_positive:
    mov rax, rbx
    cqo
    mov rcx, SCALE
    test rcx, rcx
    jz report_div_zero_error
    idiv rcx
    mov r9, rax
    mov r10, rdx
    test r8, r8
    jz .fmt_int_start
    mov byte [rdi], '-'
    inc rdi
.fmt_int_start:
    mov rax, r9
    test rax, rax
    jnz .fmt_int_digits
    mov byte [rdi], '0'
    inc rdi
    jmp .fmt_dot
.fmt_int_digits:
    xor r12, r12
.fmt_int_digits_loop:
    xor rdx, rdx
    mov rcx, 10
    div rcx
    add dl, '0'
    push rdx
    inc r12
    test rax, rax
    jnz .fmt_int_digits_loop
.fmt_int_output:
    test r12, r12
    jz .fmt_dot
    pop rdx
    mov byte [rdi], dl
    inc rdi
    dec r12
    jmp .fmt_int_output
.fmt_dot:
    test r10, r10
    jz .fmt_whole_only
    mov byte [rdi], '.'
    inc rdi
    mov rcx, 100000
    mov r12, 6
.fmt_frac_loop:
    mov rax, r10
    xor rdx, rdx
    div rcx
    add al, '0'
    mov byte [rdi], al
    inc rdi
    mov rax, r10
    xor rdx, rdx
    div rcx
    mov r10, rdx
    mov rax, rcx
    xor rdx, rdx
    mov rcx, 10
    div rcx
    mov rcx, rax
    dec r12
    jnz .fmt_frac_loop
    mov r12, rdi
.fmt_trim_loop:
    dec r12
    cmp r12, r11
    jbe .fmt_done_trim
    movzx eax, byte [r12]
    cmp al, '.'
    je .fmt_remove_dot
    cmp al, '0'
    jne .fmt_done_trim
    mov byte [r12], 0
    mov rdi, r12
    jmp .fmt_trim_loop
.fmt_done_trim:
    inc r12
    mov byte [r12], 0
    mov rdi, r12
    jmp .fmt_whole_only
.fmt_remove_dot:
    mov byte [r12], 0
    mov rdi, r12
.fmt_whole_only:
    mov byte [rdi], 0
    mov rax, rdi
    sub rax, r11
    dec rax
    add rsp, 48
    pop r12
    pop rsi
    pop rdi
    pop rbx
    ret

; ---------------------------------------------------------------
; null_terminate_read_buf: 将 CR/LF 替换为 null
; ---------------------------------------------------------------
null_terminate_read_buf:
    xor r8, r8
.nt_loop:
    cmp r8, rdx
    jge .nt_add_null
    movzx eax, byte [rcx + r8]
    cmp al, 0x0d
    je .nt_replace
    cmp al, 0x0a
    je .nt_replace
    inc r8
    jmp .nt_loop
.nt_replace:
    mov byte [rcx + r8], 0
    ret
.nt_add_null:
    mov byte [rcx + rdx], 0
    ret

; ---------------------------------------------------------------
; report_div_zero_error: 输出错误并退出
; ---------------------------------------------------------------
report_div_zero_error:
    mov rdi, STDOUT_FD
    lea rsi, [err_div_zero]
    mov rdx, err_div_zero_len
    call syscall_write
    mov rax, SYS_exit
    mov rdi, 1
    syscall

; ---------------------------------------------------------------
; _start: 程序入口（Linux 无 _start 需自行处理）
; ---------------------------------------------------------------
_start:
    ; ---- 读取第一个数 ----
    mov rdi, STDOUT_FD
    lea rsi, [prompt1]
    mov rdx, prompt1_len
    call syscall_write
    mov rdi, STDIN_FD
    lea rsi, [buf1]
    mov rdx, 31
    call syscall_read
    mov [bytes_read], rax
    lea rcx, [buf1]
    mov rdx, [bytes_read]
    call null_terminate_read_buf

    ; ---- 读取第二个数 ----
    mov rdi, STDOUT_FD
    lea rsi, [prompt2]
    mov rdx, prompt2_len
    call syscall_write
    mov rdi, STDIN_FD
    lea rsi, [buf2]
    mov rdx, 31
    call syscall_read
    mov [bytes_read], rax
    lea rcx, [buf2]
    mov rdx, [bytes_read]
    call null_terminate_read_buf

    ; ---- 读取运算选择 ----
    mov rdi, STDOUT_FD
    lea rsi, [prompt_op]
    mov rdx, prompt_op_len
    call syscall_write
    mov rdi, STDIN_FD
    lea rsi, [buf_op]
    mov rdx, 7
    call syscall_read
    lea rcx, [buf_op]
    mov rdx, rax
    call null_terminate_read_buf

    ; ---- 解析并计算 ----
    lea rdi, [buf1]
    call parse_fixed_point
    mov r12, rax
    lea rdi, [buf2]
    call parse_fixed_point
    mov r13, rax

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
    add r12, r13
    jmp .op_done
.op_sub:
    sub r12, r13
    jmp .op_done
.op_mul:
    mov rax, r12
    imul r13
    mov rcx, SCALE
    idiv rcx
    mov r12, rax
    jmp .op_done
.op_div:
    test r13, r13
    jz report_div_zero_error
    mov rax, r12
    mov rcx, SCALE
    imul rcx
    idiv r13
    mov r12, rax
.op_done:

    ; ---- 格式化并输出 ----
    mov rdi, r12
    lea rsi, [out_buf]
    call format_fixed_point
    mov r14, rax

    mov rdi, STDOUT_FD
    lea rsi, [result_msg]
    mov rdx, result_msg_len
    call syscall_write
    mov rdi, STDOUT_FD
    lea rsi, [out_buf]
    mov rdx, r14
    call syscall_write
    mov rdi, STDOUT_FD
    lea rsi, [result_nl]
    mov rdx, result_nl_len
    call syscall_write

    ; ---- 退出 ----
    mov rax, SYS_exit
    xor rdi, rdi
    syscall
