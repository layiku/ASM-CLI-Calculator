; ============================================================
; calc_32.asm - 纯汇编四则运算 Demo（Windows x86 32 位）
; ============================================================
; 功能：控制台输入两数及运算类型，输出和/差/积/商
; 实现：int 0x2e 软中断调用内核（32 位 Windows 无 syscall 指令）
; 平台：Windows x86 32 位
; 编译：nasm -f win32 calc_32.asm -o calc_32.obj
; 链接：gcc -m32 calc_32.obj -nostdlib -e _main -o calc_32.exe
;
; 与 calc.asm 差异：
;   - 入口 _main（cdecl），FS 段指向 TEB，PEB 在 fs:[0x30]
;   - int 0x2e: EAX=syscall号, EDX=参数块指针（栈上）
;   - ProcessParameters 偏移不同（0x10/0x18/0x1c）
; ============================================================

bits 32

; ============ 常量定义 ============
%define SCALE 1000000

; Windows NT 32 位系统调用号（Win10 22H2，随版本变化）
%define SYS_NtReadFile         0x008e
%define SYS_NtWriteFile        0x0007
%define SYS_NtTerminateProcess 0x0024

; 32 位 PEB 结构：FS 指向 TEB，fs:[0x30]=PEB
%define PEB_ProcessParameters  0x10   ; PEB+0x10 = ProcessParameters 指针
%define PP_StandardInput       0x18   ; StandardInput 句柄偏移
%define PP_StandardOutput      0x1c   ; StandardOutput 句柄偏移

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
    hStdin     resd 1         ; 标准输入句柄（从 PEB 获取）
    hStdout    resd 1         ; 标准输出句柄
    io_status  resd 2         ; IO_STATUS_BLOCK（NtReadFile/NtWriteFile 状态）
    bytes_read resd 1         ; 实际读取的字节数
    buf1       resb 32        ; 第一个数输入缓冲区
    buf2       resb 32        ; 第二个数输入缓冲区
    buf_op     resb 8         ; 运算选择输入（1/2/3/4）
    out_buf    resb 32        ; 格式化结果输出缓冲区

; ============ 代码段 ============
section .text
    global _main

; ---------------------------------------------------------------
; get_std_handles: 从 PEB 获取标准句柄（32 位：FS 段，PEB 在 fs:[0x30]）
; ---------------------------------------------------------------
get_std_handles:
    push ebx
    ; PEB = fs:[0x30]
    mov eax, [fs:0x30]
    ; ProcessParameters = [PEB + 0x10]
    mov eax, [eax + PEB_ProcessParameters]
    ; StandardInput, StandardOutput
    mov ecx, [eax + PP_StandardInput]
    mov [hStdin], ecx
    mov ecx, [eax + PP_StandardOutput]
    mov [hStdout], ecx
    pop ebx
    ret

; ---------------------------------------------------------------
; syscall_write: int 0x2e 调用 NtWriteFile
; 参数：handle, buf, len（通过栈传递，cdecl 风格）
; ---------------------------------------------------------------
syscall_write:
    push ebp
    mov ebp, esp
    push ebx
    ; 参数：handle=[ebp+8], buf=[ebp+12], len=[ebp+16]
    ; int 0x2e: EAX=syscall号, EDX=参数块指针（栈上）
    ; NtWriteFile 参数顺序：FileHandle, Event, ApcRoutine, ApcContext,
    ;   IoStatusBlock, Buffer, Length, ByteOffset, Key
    push dword 0              ; Key
    push dword 0              ; ByteOffset
    push dword [ebp+16]       ; Length
    push dword [ebp+12]       ; Buffer
    push dword io_status      ; IoStatusBlock
    push dword 0              ; ApcContext
    push dword 0              ; ApcRoutine
    push dword 0              ; Event
    push dword [ebp+8]        ; FileHandle
    mov eax, SYS_NtWriteFile
    mov edx, esp
    int 0x2e
    add esp, 36
    pop ebx
    pop ebp
    ret

; ---------------------------------------------------------------
; syscall_read: int 0x2e 调用 NtReadFile
; 返回：EAX=实际读取字节数
; ---------------------------------------------------------------
syscall_read:
    push ebp
    mov ebp, esp
    push ebx
    push dword 0
    push dword 0
    push dword [ebp+16]
    push dword [ebp+12]
    push dword io_status
    push dword 0
    push dword 0
    push dword 0
    push dword [ebp+8]
    mov eax, SYS_NtReadFile
    mov edx, esp
    int 0x2e
    add esp, 36
    mov eax, [io_status+4]    ; Information 字段
    pop ebx
    pop ebp
    ret

; ---------------------------------------------------------------
; parse_fixed_point: 将字符串解析为定点数（纯整数运算）
; 输入：ECX=字符串指针（如 "3.14"、"-2"、"0.5"）
; 输出：EAX=定点数（值 × 1000000）
; ---------------------------------------------------------------
parse_fixed_point:
    push ebp
    mov ebp, esp
    push ebx
    push esi
    push edi
    mov esi, ecx
    xor eax, eax
    mov ebx, 1                ; 符号：1 为正，-1 为负
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
; 整数部分：result = result * 10 + (char - '0')
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
; 检查是否有小数点
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
; 将小数部分补齐到 6 位
.parse_frac_pad:
    push ecx                  ; 保存小数位数
    mov ecx, 6
    pop eax
    sub ecx, eax              ; 需补齐的位数
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
; 无小数点：整数 × SCALE
.parse_scale_only:
    imul eax, SCALE
; 应用符号
.parse_apply_sign:
    imul eax, ebx
    pop edi
    pop esi
    pop ebx
    pop ebp
    ret

; ---------------------------------------------------------------
; format_fixed_point: 将定点数格式化为字符串（纯整数运算）
; 输入：ECX=定点数, EDX=输出缓冲区
; 输出：EAX=字符串长度（不含 null）
; 算法：分离整数/小数部分，整数除 10 逆序入栈再输出，小数逐位取商
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
    mov [ebp-4], edx         ; 保存缓冲区起始地址
    xor ecx, ecx             ; 负数标志
    test ebx, ebx
    jns .fmt_pos
    mov ecx, 1
    neg ebx
; 分离整数部分和小数部分：value / SCALE, value % SCALE
.fmt_pos:
    mov eax, ebx
    cdq
    mov esi, [scale_val]
    test esi, esi             ; 检查除数是否为 0
    jz report_div_zero_error
    idiv esi
    mov [ebp-8], eax         ; int_part（整数部分）
    mov [ebp-12], edx        ; frac_part（小数部分，余数）
    test ecx, ecx
    jz .fmt_int
    mov byte [edi], '-'
    inc edi
; 整数部分转字符串（逆序除 10 入栈）
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
; 小数部分：6 位，除数从 100000 递减到 1（依次取各位数字）
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
; null_terminate_read_buf: 将 NtReadFile 读取的 CR(0x0d)/LF(0x0a) 替换为 0
; 输入：ECX=缓冲区指针, EDX=读取的字节数
; 说明：控制台输入以 CRLF 结尾，需截断以便字符串解析
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
; report_div_zero_error: 输出除零错误并退出（退出码 1）
; ---------------------------------------------------------------
report_div_zero_error:
    push dword err_div_zero_len
    push dword err_div_zero
    push dword [hStdout]
    call syscall_write
    add esp, 12
    push dword 1              ; 退出码 1 表示错误
    push dword -1
    mov eax, SYS_NtTerminateProcess
    mov edx, esp
    int 0x2e

; ---------------------------------------------------------------
; _main: 主程序入口（32 位 cdecl 调用约定）
; 流程：get_std_handles → 输出提示 → NtReadFile 读入 → null 截断
;       → parse_fixed_point 解析 → 相加 → format_fixed_point 格式化
;       → NtWriteFile 输出结果 → NtTerminateProcess 退出
; ---------------------------------------------------------------
_main:
    push ebp
    mov ebp, esp
    sub esp, 16
    call get_std_handles
    push dword prompt1_len
    push dword prompt1
    push dword [hStdout]
    call syscall_write
    add esp, 12
    push dword 31
    push dword buf1
    push dword [hStdin]
    call syscall_read
    add esp, 12
    mov [bytes_read], eax
    mov ecx, buf1
    mov edx, [bytes_read]
    call null_terminate_read_buf
    push dword prompt2_len
    push dword prompt2
    push dword [hStdout]
    call syscall_write
    add esp, 12
    push dword 31
    push dword buf2
    push dword [hStdin]
    call syscall_read
    add esp, 12
    mov [bytes_read], eax
    mov ecx, buf2
    mov edx, [bytes_read]
    call null_terminate_read_buf
    push dword prompt_op_len
    push dword prompt_op
    push dword [hStdout]
    call syscall_write
    add esp, 12
    push dword 7
    push dword buf_op
    push dword [hStdin]
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
    mov [ebp-8], eax
    push dword result_msg_len
    push dword result_msg
    push dword [hStdout]
    call syscall_write
    add esp, 12
    push dword [ebp-8]
    push dword out_buf
    push dword [hStdout]
    call syscall_write
    add esp, 12
    push dword result_nl_len
    push dword result_nl
    push dword [hStdout]
    call syscall_write
    add esp, 12
    push dword 0
    push dword -1
    mov eax, SYS_NtTerminateProcess
    mov edx, esp
    int 0x2e
    add esp, 8
    add esp, 16
    pop ebp
    ret
