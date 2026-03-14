; ============================================================
; calc.asm - 纯汇编四则运算 Demo（Windows x64）
; ============================================================
; 功能：控制台输入两数及运算类型，输出和/差/积/商
; 实现：syscall 直接调用内核，无 C 库、无 Windows API
; 平台：Windows x86-64
; 编译：nasm -f win64 calc.asm -o calc.obj
; 链接：gcc calc.obj -nostdlib -e main -o calc.exe
; 注意：syscall 号随 Windows 版本变化，当前为 Win10/11
;
; 程序结构：
;   main          - 主流程：获取句柄 → 读入 → 解析 → 运算 → 格式化 → 输出
;   get_std_handles - 从 PEB 获取 stdin/stdout 句柄
;   syscall_write/read - NtWriteFile/NtReadFile 封装
;   parse_fixed_point - 字符串→定点数（支持 -+.0-9）
;   format_fixed_point - 定点数→字符串（去尾随零）
;   null_terminate_read_buf - 将 CR/LF 截断为 null
;   report_div_zero_error - 除零错误处理
; ============================================================

bits 64
default rel

; ============ 常量定义 ============
; SCALE: 定点数缩放因子，实际值 = 存储整数/SCALE
; 例：3.14 存为 3140000，支持 6 位小数精度
%define SCALE 1000000

; Windows NT 内核 syscall 号（Win10 1507 及以后、Win11 通用）
%define SYS_NtReadFile         0x006   ; 从文件/控制台读取
%define SYS_NtWriteFile        0x008   ; 向文件/控制台写入
%define SYS_NtTerminateProcess 0x02c   ; 终止进程

; PEB（进程环境块）结构偏移，用于获取标准句柄
%define PEB_ProcessParameters  0x20   ; PEB 中 ProcessParameters 指针偏移
%define PP_StandardInput       0x40   ; ProcessParameters 中标准输入句柄偏移
%define PP_StandardOutput      0x48   ; ProcessParameters 中标准输出句柄偏移

; ============ 只读数据段 ============
section .data
    ; 用户输入提示（支持整数、小数、负数）
    prompt1    db "Enter first number (int or decimal, negative ok): ", 0
    prompt1_len equ $-prompt1
    prompt2    db "Enter second number (int or decimal, negative ok): ", 0
    prompt2_len equ $-prompt2
    prompt_op  db "Operation (1=add 2=sub 3=mul 4=div): ", 0
    prompt_op_len equ $-prompt_op
    ; 结果输出前缀与换行符
    result_msg db "Result: ", 0
    result_msg_len equ $-result_msg
    result_nl  db 10, 0
    result_nl_len equ $-result_nl
    ; 除零错误提示
    err_div_zero    db "Error: division by zero", 10, 0
    err_div_zero_len equ $-err_div_zero

; ============ 未初始化数据段（BSS）============
section .bss
    hStdin     resq 1         ; 标准输入句柄（从 PEB 获取）
    hStdout    resq 1         ; 标准输出句柄（从 PEB 获取）
    io_status  resq 2         ; IO_STATUS_BLOCK：NtReadFile/NtWriteFile 的状态返回
    bytes_read resq 1         ; 实际读取的字节数
    buf1       resb 32        ; 第一个数的输入缓冲区
    buf2       resb 32        ; 第二个数的输入缓冲区
    buf_op     resb 8         ; 运算选择输入（1/2/3/4）
    out_buf    resb 32        ; 格式化结果的输出缓冲区

; ============ 代码段 ============
section .text
    global main               ; 程序入口，由链接器 -e main 指定

; ---------------------------------------------------------------
; get_std_handles: 从 PEB 获取标准输入/输出句柄
; 说明：不调用任何 API，直接读取进程环境块中的句柄
;       GS 段基址指向 TEB，TEB+0x60 为 PEB 指针
; ---------------------------------------------------------------
get_std_handles:
    ; 读取 PEB 指针（x64 下 TEB 在 gs:[0]，PEB 在 TEB+0x60）
    mov rax, [gs:0x60]
    ; 读取 ProcessParameters（RTL_USER_PROCESS_PARAMETERS 结构）
    mov rax, [rax + PEB_ProcessParameters]
    ; 读取 StandardInput 句柄并保存
    mov rcx, [rax + PP_StandardInput]
    mov [hStdin], rcx
    ; 读取 StandardOutput 句柄并保存
    mov rcx, [rax + PP_StandardOutput]
    mov [hStdout], rcx
    ret

; ---------------------------------------------------------------
; syscall_write: 通过 syscall 调用 NtWriteFile 输出到控制台
; 输入：RCX=句柄, RDX=缓冲区指针, R8=字节数
; 说明：Windows syscall 约定：第1参用 R10（非 RCX），第2-4参用 RDX/R8/R9
;       第5参及以后在栈上 [rsp+0x28] 起
; ---------------------------------------------------------------
syscall_write:
    sub rsp, 0x58             ; 分配栈空间：shadow 0x28 + 5 个参数
    ; 保存 buf 和 len（因 RDX/R8 将被清零用于可选参数）
    mov [rsp+0x30], rdx
    mov [rsp+0x38], r8
    ; 设置 NtWriteFile 参数：R10=FileHandle, RDX=Event(0), R8=ApcRoutine(0), R9=ApcContext(0)
    mov r10, rcx
    xor edx, edx
    xor r8d, r8d
    xor r9d, r9d
    ; 栈参数：IoStatusBlock, Buffer, Length, ByteOffset(NULL), Key(NULL)
    lea rax, [io_status]
    mov [rsp+0x28], rax
    mov rdx, [rsp+0x30]
    mov [rsp+0x30], rdx
    mov r8, [rsp+0x38]
    mov [rsp+0x38], r8
    mov qword [rsp+0x40], 0
    mov qword [rsp+0x48], 0
    mov eax, SYS_NtWriteFile
    syscall                   ; 触发内核调用
    add rsp, 0x58
    ret

; ---------------------------------------------------------------
; syscall_read: 通过 syscall 调用 NtReadFile 从控制台读取
; 输入：RCX=句柄, RDX=缓冲区指针, R8=最大读取字节数
; 输出：RAX=实际读取的字节数（从 IO_STATUS_BLOCK.Information 取）
; ---------------------------------------------------------------
syscall_read:
    sub rsp, 0x58
    mov [rsp+0x30], rdx
    mov [rsp+0x38], r8
    mov r10, rcx
    xor edx, edx
    xor r8d, r8d
    xor r9d, r9d
    lea rax, [io_status]
    mov [rsp+0x28], rax
    mov rdx, [rsp+0x30]
    mov [rsp+0x30], rdx
    mov r8, [rsp+0x38]
    mov [rsp+0x38], r8
    mov qword [rsp+0x40], 0
    mov qword [rsp+0x48], 0
    mov eax, SYS_NtReadFile
    syscall
    ; io_status+8 为 Information 字段，存放实际传输字节数
    mov rax, [io_status+8]
    add rsp, 0x58
    ret

; ---------------------------------------------------------------
; parse_fixed_point: 字符串→定点数（纯整数运算，无浮点指令）
; ---------------------------------------------------------------
; 输入：RCX = 字符串指针（如 "3.14"、"-2"、".5"）
; 输出：RAX = 定点数（值×SCALE，如 3.14→3140000）
;
; 算法步骤：
;   1. 跳过前导空格/制表符
;   2. 解析正负号（- 或 +），默认为正
;   3. 整数部分：result = result*10 + (char-'0')，遇非数字停止
;   4. 若有 '.'：解析小数部分（最多6位），不足位补0
;   5. 合并：整数×SCALE + 小数
;   6. 乘符号
; ---------------------------------------------------------------
parse_fixed_point:
    push rbx                 ; 保存被调用者保存寄存器
    push rsi
    sub rsp, 32               ; 栈对齐
    mov rsi, rcx              ; RSI=字符串指针
    xor rax, rax              ; RAX=结果累加器，初值 0
    mov rbx, 1                ; RBX=符号，1 为正，-1 为负
; 跳过前导空格和制表符
.parse_skip_spaces:
    movzx ecx, byte [rsi]
    cmp cl, ' '
    je .parse_skip_inc
    cmp cl, 9                 ; Tab
    je .parse_skip_inc
    jmp .parse_check_sign
.parse_skip_inc:
    inc rsi
    jmp .parse_skip_spaces
; 检查正负号
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
; 解析整数部分：result = result * 10 + (char - '0')
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
; 检查是否有小数点
.parse_frac_check:
    cmp cl, '.'
    jne .parse_scale_only     ; 无小数点，整数部分×SCALE 即可
    inc rsi
    xor r8, r8                ; R8=小数部分累加
    xor r9, r9                ; R9=小数位数计数
; 解析小数部分（最多 6 位）
.parse_frac_loop:
    movzx ecx, byte [rsi]
    cmp cl, '0'
    jb .parse_frac_pad
    cmp cl, '9'
    ja .parse_frac_pad
    cmp r9, 6
    jge .parse_frac_loop_inc  ; 超过 6 位则跳过
    imul r8, 10
    sub cl, '0'
    add r8, rcx
    inc r9
.parse_frac_loop_inc:
    inc rsi
    jmp .parse_frac_loop
; 将小数部分补齐到 6 位（如 "3.14" 的 14 补齐为 140000）
.parse_frac_pad:
    mov rcx, 6
    sub rcx, r9               ; 需补齐的位数
.parse_frac_pad_loop:
    test rcx, rcx
    jz .parse_frac_done
    imul r8, 10
    dec rcx
    jmp .parse_frac_pad_loop
; 合并：整数部分×SCALE + 小数部分
.parse_frac_done:
    imul rax, SCALE
    add rax, r8
    jmp .parse_apply_sign
; 无小数部分：整数×SCALE
.parse_scale_only:
    imul rax, SCALE
; 应用符号
.parse_apply_sign:
    imul rax, rbx
    add rsp, 32
    pop rsi
    pop rbx
    ret

; ---------------------------------------------------------------
; format_fixed_point: 定点数→字符串（纯整数运算）
; ---------------------------------------------------------------
; 输入：RCX=定点数, RDX=输出缓冲区
; 输出：RAX=字符串长度（不含 null）
;
; 算法步骤：
;   1. 负数：先输出 '-'，再取绝对值处理
;   2. 分离：int_part=value/SCALE, frac_part=value%SCALE
;   3. 整数转串：反复 div 10 取余入栈，再出栈正序输出
;   4. 若有小数：输出 '.'，用除数 100000→10000→...→1 逐位取商
;   5. 去除尾随零：从末尾向前将 '0' 替为 null（6.140000→6.14）
;   6. 若小数全0：不输出小数点
; ---------------------------------------------------------------
format_fixed_point:
    push rbx
    push rsi
    push rdi
    push r12
    sub rsp, 48
    mov rbx, rcx              ; RBX=待格式化值
    mov rdi, rdx              ; RDI=输出指针
    mov r11, rdx              ; R11=缓冲区起始地址（用于计算长度）
    xor r8, r8                ; R8=负数标志
; 处理负数：取绝对值，输出时加 '-'
    test rbx, rbx
    jns .fmt_positive
    mov r8, 1
    neg rbx
.fmt_positive:
; 分离整数部分和小数部分：value / SCALE, value % SCALE
    mov rax, rbx
    cqo                       ; 符号扩展 RAX 到 RDX:RAX
    mov rcx, SCALE
    test rcx, rcx              ; 检查除数是否为 0
    jz report_div_zero_error
    idiv rcx
    mov r9, rax               ; R9=整数部分
    mov r10, rdx              ; R10=小数部分（余数）
    test r8, r8
    jz .fmt_int_start
    mov byte [rdi], '-'
    inc rdi
; 整数部分转字符串（逆序除 10 取余，入栈后正序输出）；除数 10 为常量，不会为 0
.fmt_int_start:
    mov rax, r9
    test rax, rax
    jnz .fmt_int_digits
    mov byte [rdi], '0'       ; 整数部分为 0
    inc rdi
    jmp .fmt_dot
.fmt_int_digits:
    xor r12, r12              ; R12=数字个数
.fmt_int_digits_loop:
    xor rdx, rdx
    mov rcx, 10
    div rcx                   ; RAX=商, RDX=余数（0-9）
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
; 小数部分
.fmt_dot:
    test r10, r10
    jz .fmt_whole_only        ; 小数部分为 0，不输出小数点
    mov byte [rdi], '.'
    inc rdi
    mov rcx, 100000            ; 除数从 100000 开始，逐位取小数
    mov r12, 6                 ; 6 位小数
.fmt_frac_loop:
    mov rax, r10
    xor rdx, rdx
    div rcx                   ; 当前位 = frac_part / divisor
    add al, '0'
    mov byte [rdi], al
    inc rdi
    mov rax, r10
    xor rdx, rdx
    div rcx
    mov r10, rdx              ; 余数作为下一轮的小数部分
    mov rax, rcx
    xor rdx, rdx
    mov rcx, 10
    div rcx
    mov rcx, rax              ; divisor /= 10
    dec r12
    jnz .fmt_frac_loop
; 去除尾随零：从末尾向前遍历，将尾部的 '0' 替换为 null（如 6.140000 -> 6.14）
    mov r12, rdi
.fmt_trim_loop:
    dec r12
    cmp r12, r11
    jbe .fmt_done_trim
    movzx eax, byte [r12]
    cmp al, '.'
    je .fmt_remove_dot        ; 全为 0，如 6.000000 -> 6
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
    mov byte [r12], 0         ; 移除小数点，仅保留整数
    mov rdi, r12
.fmt_whole_only:
    mov byte [rdi], 0         ; 字符串结束符
    mov rax, rdi
    sub rax, r11
    dec rax                   ; 长度不含 null
    add rsp, 48
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret

; ---------------------------------------------------------------
; null_terminate_read_buf: 将 ReadFile 读取的 CR(0x0d)/LF(0x0a) 替换为 null
; 输入：RCX=缓冲区指针, RDX=读取的字节数
; 说明：控制台输入通常以 CRLF 结尾，需截断以便字符串解析
; ---------------------------------------------------------------
null_terminate_read_buf:
    xor r8, r8                ; R8=当前字节索引
.nt_loop:
    cmp r8, rdx
    jge .nt_add_null
    movzx eax, byte [rcx + r8]
    cmp al, 0x0d              ; 回车符
    je .nt_replace
    cmp al, 0x0a              ; 换行符
    je .nt_replace
    inc r8
    jmp .nt_loop
.nt_replace:
    mov byte [rcx + r8], 0    ; 在 CR/LF 处截断
    ret
.nt_add_null:
    mov byte [rcx + rdx], 0   ; 无 CR/LF 时在末尾加 null
    ret

; ---------------------------------------------------------------
; report_div_zero_error: 输出除零错误并退出（退出码 1）
; 说明：在除法前检查除数为 0 时调用
; ---------------------------------------------------------------
report_div_zero_error:
    mov rcx, [hStdout]
    lea rdx, [err_div_zero]
    mov r8d, err_div_zero_len
    call syscall_write
    mov r10, -1
    mov edx, 1                 ; 退出码 1 表示错误
    mov eax, SYS_NtTerminateProcess
    syscall

; ---------------------------------------------------------------
; main: 主程序入口
; 流程：获取句柄 → 提示并读取两数 → 解析 → 定点数相加 → 格式化 → 输出 → 退出
; 全程使用 syscall，无 C 库、无 Windows API
; ---------------------------------------------------------------
main:
    sub rsp, 40               ; 栈对齐（Windows x64 要求 16 字节对齐）
    call get_std_handles      ; 从 PEB 获取 stdin/stdout 句柄

    ; ---- 读取第一个数 ----
    mov rcx, [hStdout]
    lea rdx, [prompt1]
    mov r8d, prompt1_len
    call syscall_write
    mov rcx, [hStdin]
    lea rdx, [buf1]
    mov r8d, 31
    call syscall_read
    mov [bytes_read], rax
    lea rcx, [buf1]
    mov rdx, [bytes_read]
    call null_terminate_read_buf

    ; ---- 读取第二个数 ----
    mov rcx, [hStdout]
    lea rdx, [prompt2]
    mov r8d, prompt2_len
    call syscall_write
    mov rcx, [hStdin]
    lea rdx, [buf2]
    mov r8d, 31
    call syscall_read
    mov [bytes_read], rax
    lea rcx, [buf2]
    mov rdx, [bytes_read]
    call null_terminate_read_buf

    ; ---- 读取运算选择 ----
    mov rcx, [hStdout]
    lea rdx, [prompt_op]
    mov r8d, prompt_op_len
    call syscall_write
    mov rcx, [hStdin]
    lea rdx, [buf_op]
    mov r8d, 7
    call syscall_read
    lea rcx, [buf_op]
    mov rdx, rax
    call null_terminate_read_buf

    ; ---- 解析为定点数 ----
    lea rcx, [buf1]
    call parse_fixed_point
    mov r12, rax              ; R12=第一个数
    lea rcx, [buf2]
    call parse_fixed_point
    mov r13, rax              ; R13=第二个数

    ; ---- 四则运算：定点数公式 ----
    ; 加：a + b
    ; 减：a - b
    ; 乘：(a*b)/SCALE（两个定点数相乘需除 SCALE 还原）
    ; 除：(a*SCALE)/b（若 b=0 则报告错误）
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
    imul r13                  ; RDX:RAX = a*b
    mov rcx, SCALE
    idiv rcx                  ; (a*b)/SCALE
    mov r12, rax
    jmp .op_done
.op_div:
    test r13, r13
    jz report_div_zero_error
    mov rax, r12
    mov rcx, SCALE
    imul rcx                  ; RDX:RAX = a*SCALE
    idiv r13                  ; (a*SCALE)/b
    mov r12, rax
.op_done:

    ; ---- 格式化为字符串 ----
    mov rcx, r12
    lea rdx, [out_buf]
    call format_fixed_point
    mov r14, rax              ; R14=输出字符串长度

    ; ---- 输出结果 ----
    mov rcx, [hStdout]
    lea rdx, [result_msg]
    mov r8d, result_msg_len
    call syscall_write
    mov rcx, [hStdout]
    lea rdx, [out_buf]
    mov r8d, r14d
    call syscall_write
    mov rcx, [hStdout]
    lea rdx, [result_nl]
    mov r8d, result_nl_len
    call syscall_write

    ; ---- 退出进程 ----
    ; NtTerminateProcess(ProcessHandle=-1 表示当前进程, ExitStatus=0)
    mov r10, -1
    xor edx, edx
    mov eax, SYS_NtTerminateProcess
    syscall

    add rsp, 40
    ret
