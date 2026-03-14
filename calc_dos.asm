; ============================================================
; calc_dos.asm - 纯汇编四则运算 Demo（DOS 16 位）
; ============================================================
; 功能：控制台输入两数及运算类型，输出和/差/积/商
; 实现：int 21h DOS 中断，无浮点指令，无 C 库
; 平台：DOS 实模式 16 位（COM 格式，单段≤64KB）
; 编译：nasm -f bin calc_dos.asm -o calc_dos.com
; 运行：DOS、DOSBox、FreeDOS 中执行 calc_dos.com
;
; 程序结构：
;   _start - 主流程（与 Windows/Linux 版相同逻辑）
;   int 21h AH=09 输出字符串（以 $ 结尾）
;   int 21h AH=0Ah 带缓冲输入（DX=缓冲区，结构见数据区注释）
;   parse_fixed / format_fixed - 16 位版，SCALE=1000（3 位小数）
;   数据与代码同段（COM 单段模型）
; ============================================================

org 0x100                   ; COM 加载于 CS:0100，前 256 字节为 PSP
bits 16

; ============ 常量定义 ============
%define SCALE 1000          ; 16 位限制：3 位小数，最大约 65.535
%define DOS_PRINT_STR  0x09  ; int 21h AH=09：输出 DS:DX 指向的以 $ 结尾字符串
%define DOS_READ_BUF   0x0a  ; int 21h AH=0Ah：带缓冲键盘输入，DX=缓冲区
%define DOS_EXIT       0x4c  ; int 21h AH=4Ch：终止，AL=返回码

; ============ 代码与数据同段（COM 单段模型）============
section .text
_start:
    ; ---- 输出提示并读取第一个数 ----
    mov dx, prompt1
    mov ah, DOS_PRINT_STR
    int 0x21
    mov dx, buf1
    mov ah, DOS_READ_BUF
    int 0x21

    ; ---- 输出提示并读取第二个数 ----
    mov dx, prompt2
    mov ah, DOS_PRINT_STR
    int 0x21
    mov dx, buf2
    mov ah, DOS_READ_BUF
    int 0x21

    ; ---- 输出提示并读取运算选择 ----
    mov dx, prompt_op
    mov ah, DOS_PRINT_STR
    int 0x21
    mov dx, buf_op
    mov ah, DOS_READ_BUF
    int 0x21

    ; ---- 解析为定点数 ----
    mov si, buf1 + 2
    call parse_fixed
    mov [num1], ax
    mov si, buf2 + 2
    call parse_fixed
    mov [num2], ax

    ; ---- 根据运算类型计算（1=加 2=减 3=乘 4=除）----
    mov si, buf_op + 2
    lodsb
    cmp al, '2'
    je .op_sub
    cmp al, '3'
    je .op_mul
    cmp al, '4'
    je .op_div
.op_add:
    mov ax, [num1]
    add ax, [num2]
    mov [result], ax
    jmp .op_done
.op_sub:
    mov ax, [num1]
    sub ax, [num2]
    mov [result], ax
    jmp .op_done
.op_mul:
    mov ax, [num1]
    imul word [num2]         ; DX:AX = a * b
    mov bx, SCALE
    idiv bx                  ; (a*b)/SCALE
    mov [result], ax
    jmp .op_done
.op_div:
    mov bx, [num2]
    test bx, bx
    jz report_div_zero_error
    mov ax, [num1]
    mov cx, SCALE
    imul cx                  ; DX:AX = num1 * SCALE
    idiv bx                  ; (a*SCALE) / b
    mov [result], ax
.op_done:

    ; ---- 输出 "Result: " 及格式化结果 ----
    mov dx, result_msg
    mov ah, DOS_PRINT_STR
    int 0x21
    mov ax, [result]
    mov di, out_buf
    call format_fixed
    mov dx, out_buf
    mov ah, DOS_PRINT_STR
    int 0x21

    ; ---- 输出换行并退出 ----
    mov dx, result_nl
    mov ah, DOS_PRINT_STR
    int 0x21
    mov ah, DOS_EXIT
    xor al, al
    int 0x21

; ---------------------------------------------------------------
; parse_fixed: 字符串→定点数（16 位版）
; ---------------------------------------------------------------
; 输入：SI=字符串指针（buf+2 跳过 AH=0Ah 缓冲区的头两字节）
; 输出：AX=定点数（值×SCALE，因 16 位仅支持 3 位小数）
; 算法：同 64 位版，使用 BX/CX/DX/BP 等 16 位寄存器
; ---------------------------------------------------------------
parse_fixed:
    xor bx, bx                ; BX=结果累加器
    mov cx, 1                 ; CX=符号（1 或 -1）
.parse_skip:
    lodsb
    cmp al, ' '
    je .parse_skip
    cmp al, 9
    je .parse_skip
    cmp al, '-'
    jne .parse_plus
    mov cx, -1
    lodsb
    jmp .parse_int
.parse_plus:
    cmp al, '+'
    jne .parse_int
    lodsb
; 整数部分：result = result * 10 + (char - '0')
.parse_int:
    cmp al, '0'
    jb .parse_frac_chk
    cmp al, '9'
    ja .parse_frac_chk
    sub al, '0'
    xor ah, ah
    push ax
    mov ax, bx
    mov bx, 10
    mul bx
    pop bx
    add ax, bx
    mov bx, ax
    lodsb
    jmp .parse_int
; 检查小数部分
.parse_frac_chk:
    cmp al, '.'
    jne .parse_scale
    xor dx, dx                ; DX=小数部分累加
    xor bp, bp                ; BP=小数位数
    lodsb
; 解析小数部分（最多 3 位）
.parse_frac:
    cmp al, '0'
    jb .parse_frac_done
    cmp al, '9'
    ja .parse_frac_done
    cmp bp, 3
    jge .parse_frac_skip
    sub al, '0'
    xor ah, ah
    push ax
    mov ax, dx
    mov dx, 10
    mul dx
    pop cx
    add ax, cx
    mov dx, ax
    inc bp
.parse_frac_skip:
    lodsb
    jmp .parse_frac
; 将小数部分补齐到 3 位（如 "3.14" -> 140）
.parse_frac_done:
    mov ax, 3
    sub ax, bp
    mov bp, ax
.parse_pad:
    test bp, bp
    jz .parse_merge
    mov ax, dx
    mov dx, 10
    mul dx
    mov dx, ax
    dec bp
    jmp .parse_pad
; 合并：int_part × SCALE + frac_part
.parse_merge:
    mov ax, bx
    mov bx, SCALE
    mul bx
    add ax, dx
    jmp .parse_sign
; 无小数部分
.parse_scale:
    mov ax, bx
    mov bx, SCALE
    mul bx
; 应用符号
.parse_sign:
    imul cx
    ret

; ---------------------------------------------------------------
; format_fixed: 定点数→字符串（DOS 格式）
; ---------------------------------------------------------------
; 输入：AX=定点数, DI=输出缓冲区
; 输出：字符串写入 DI，以 '$' 结尾（int 21h AH=09 要求）
; 算法：整数除 10 入栈再出栈；小数用除数 100/10/1 取 3 位
; ---------------------------------------------------------------
format_fixed:
    push di
    xor cx, cx
    test ax, ax
    jns .fmt_pos
    mov byte [di], '-'
    inc di
    neg ax
.fmt_pos:
    mov bx, SCALE
    test bx, bx               ; 检查除数是否为 0
    jz report_div_zero_error
    xor dx, dx
    div bx
    mov bp, ax                ; BP=整数部分
    mov bx, dx                ; BX=小数部分（余数）
    mov ax, bp
    test ax, ax
    jnz .fmt_digits
    mov byte [di], '0'
    inc di
    jmp .fmt_dot
; 整数部分转字符串（逆序除 10 入栈，再正序输出）
.fmt_digits:
    xor cx, cx
.fmt_dig_loop:
    xor dx, dx
    mov ax, bp
    mov bp, 10
    div bp
    mov bp, ax
    add dl, '0'
    push dx
    inc cx
    test bp, bp
    jnz .fmt_dig_loop
.fmt_out:
    test cx, cx
    jz .fmt_dot
    pop dx
    mov [di], dl
    inc di
    dec cx
    jmp .fmt_out
; 小数部分：逐位输出（除数 100, 10, 1）
.fmt_dot:
    test bx, bx
    jz .fmt_end
    mov byte [di], '.'
    inc di
    ; 3 位小数：依次用 100、10、1 取各位
    mov ax, bx
    xor dx, dx
    mov cx, 100
    div cx
    add al, '0'
    mov [di], al
    inc di
    mov ax, dx
    xor dx, dx
    mov cx, 10
    div cx
    add al, '0'
    mov [di], al
    inc di
    add dl, '0'
    mov [di], dl
    inc di
.fmt_end:
    mov byte [di], '$'       ; DOS 字符串以 '$' 结尾
    pop di
    ret

; ---------------------------------------------------------------
; report_div_zero_error: 输出除零错误并退出（退出码 1）
; ---------------------------------------------------------------
report_div_zero_error:
    mov dx, err_div_zero
    mov ah, DOS_PRINT_STR
    int 0x21
    mov ah, DOS_EXIT
    mov al, 1
    int 0x21

; ============ 数据区（与代码同段，COM 单段模型）============
prompt1    db "Enter first number (int or decimal, negative ok): $"
prompt2    db "Enter second number (int or decimal, negative ok): $"
prompt_op  db "Operation (1=add 2=sub 3=mul 4=div): $"
result_msg db "Result: $"
result_nl  db 13, 10, '$'    ; CR+LF 换行
err_div_zero db "Error: division by zero", 13, 10, '$'

; int 21h AH=0Ah 带缓冲输入：DX 指向缓冲区
; 缓冲区结构：byte 0=最大长度, byte 1=实际读取（DOS 填充）, byte 2+=用户输入
buf1       db 20, 0           ; 最多 20 字符（含回车）
           times 22 db 0
buf2       db 20, 0
           times 22 db 0
buf_op     db 8, 0
           times 10 db 0

num1       dw 0               ; 第一个数（定点格式）
num2       dw 0               ; 第二个数（定点格式）
result     dw 0               ; 两数之和（定点格式）
out_buf    times 32 db 0      ; 格式化输出缓冲区
