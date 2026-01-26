; fdmon - x86_64 Linux file descriptor monitor
; Displays open fd counts per process, sorted descending
; Build: nasm -f elf64 fdmon.asm && ld -o fdmon fdmon.o

BITS 64

%define MAX_PROCS   512
%define MAX_SHOW    32
%define PROC_SZ     32
%define OFF_PID     0
%define OFF_FDS     8
%define OFF_NAME    16
%define NAME_LEN    16
%define DBUF_SZ     8192
%define OBUF_SZ     16384

section .data
    path_proc:   db "/proc",0
    p_file_max:  db "/proc/sys/fs/file-max",0
    p_file_nr:   db "/proc/sys/fs/file-nr",0
    p_nr_open:   db "/proc/sys/fs/nr_open",0

    a_clear:     db 27,"[2J",27,"[H",0
    a_home:      db 27,"[H",0
    a_hide:      db 27,"[?25l",0
    a_show:      db 27,"[?25h",0
    a_clreos:    db 27,"[J",0
    a_bold:      db 27,"[1m",0
    a_bold_cyan: db 27,"[1;36m",0
    a_cyan:      db 27,"[36m",0
    a_yellow:    db 27,"[33m",0
    a_reset:     db 27,"[0m",0
    a_dim:       db 27,"[2m",0

    s_title:     db "File Descriptor Monitor",10,0
    s_sep:       db 27,"[K════════════════════════════════════════════════════",10,0
    s_lsep:      db 27,"[K────────────────────────────────────────────────────",10,0
    s_hdr:       db "    PID     FDs  Command",0
    s_nl:        db 27,"[K",10,0
    s_quit:      db 27,"[K",10,"Press Ctrl+C to quit",27,"[K",10,0
    s_none:      db "No readable processes found!",27,"[K",10,0
    s_tot_a:     db "  Total: ",0
    s_tot_b:     db " fds across ",0
    s_tot_c:     db " processes",0
    s_2sp:       db "  ",0
    s_sys:       db "  System Limits",27,"[K",10,0
    s_kern:      db "    Kernel handles    ",0
    s_of:        db " / ",0
    s_pproc:     db "    Per-process max   ",0

    ts_1s:       dq 1, 0
    sigact:      dq on_sigint, 0x04000000, sa_restore, 0

section .bss
    obuf:   resb OBUF_SZ
    optr:   resq 1
    dbuf:   resb DBUF_SZ
    pbuf:   resb 64
    nbuf:   resb 32
    procs:  resb PROC_SZ * MAX_PROCS
    pcnt:   resq 1

section .text
    global _start

; ── Signal handler ──────────────────────────────
on_sigint:
    mov eax, 1
    mov edi, 1
    mov rsi, a_show
    mov edx, 6
    syscall
    mov eax, 60
    xor edi, edi
    syscall

sa_restore:
    mov eax, 15
    syscall

; ── Entry point ─────────────────────────────────
_start:
    mov eax, 13
    mov edi, 2
    mov rsi, sigact
    xor edx, edx
    mov r10d, 8
    syscall

    mov rax, obuf
    mov [optr], rax

    mov rsi, a_hide
    call emit
    mov rsi, a_clear
    call emit
    call flush

.loop:
    mov rax, obuf
    mov [optr], rax

    mov rsi, a_home
    call emit

    call scan_procs
    call sort_procs

    mov rsi, a_bold_cyan
    call emit
    mov rsi, s_title
    call emit
    mov rsi, a_reset
    call emit
    mov rsi, s_sep
    call emit

    call show_procs
    call show_sysinfo

    mov rsi, a_dim
    call emit
    mov rsi, s_quit
    call emit
    mov rsi, a_reset
    call emit
    mov rsi, a_clreos
    call emit

    call flush

    mov eax, 35
    mov rdi, ts_1s
    xor esi, esi
    syscall
    jmp .loop

; ── Scan all processes ──────────────────────────
scan_procs:
    push r12
    push r13
    push r14

    mov qword [pcnt], 0

    mov eax, 2
    mov rdi, path_proc
    mov esi, 0x10000
    xor edx, edx
    syscall
    test eax, eax
    js .done
    mov r12d, eax

.dents:
    mov eax, 217
    mov edi, r12d
    mov rsi, dbuf
    mov edx, DBUF_SZ
    syscall
    cmp eax, 0
    jle .close

    mov r13d, eax
    xor r14d, r14d

.walk:
    cmp r14d, r13d
    jge .dents

    lea rdi, [dbuf + r14 + 19]
    call try_parse_pid
    jc .next

    cmp qword [pcnt], MAX_PROCS
    jge .next

    mov rcx, [pcnt]
    shl rcx, 5
    mov [procs + rcx + OFF_PID], rax
    inc qword [pcnt]

.next:
    movzx eax, word [dbuf + r14 + 16]
    add r14d, eax
    jmp .walk

.close:
    mov eax, 3
    mov edi, r12d
    syscall

    xor r12d, r12d

.fill:
    cmp r12, [pcnt]
    jge .done

    mov rax, r12
    shl rax, 5
    lea r14, [procs + rax]

    mov rdi, [r14 + OFF_PID]
    mov rsi, r14
    call probe_proc
    test rax, rax
    js .remove

    inc r12
    jmp .fill

.remove:
    dec qword [pcnt]
    mov rcx, [pcnt]
    shl rcx, 5
    mov rax, [procs + rcx + OFF_PID]
    mov [r14 + OFF_PID], rax
    jmp .fill

.done:
    pop r14
    pop r13
    pop r12
    ret

; ── Probe one process: count fds + read name ────
; rdi = pid, rsi = proc entry pointer
; Returns rax = fd count or negative on error
probe_proc:
    push r12
    push r13
    push r14
    push r15

    mov r13, rsi

    ; Build "/proc/PID" in pbuf
    mov dword [pbuf], '/pro'
    mov word [pbuf+4], 'c/'
    lea rcx, [pbuf + 6]

    mov rax, rdi
    lea r15, [nbuf + 20]
    mov byte [r15], 0
    mov r8d, 10
.dig:
    xor edx, edx
    div r8
    add dl, '0'
    dec r15
    mov [r15], dl
    test rax, rax
    jnz .dig

.cpyd:
    mov al, [r15]
    test al, al
    jz .pfx
    mov [rcx], al
    inc rcx
    inc r15
    jmp .cpyd

.pfx:
    mov r14, rcx            ; save suffix position

    ; Append "/fd" and open
    mov dword [r14], '/fd'
    mov eax, 2
    mov rdi, pbuf
    mov esi, 0x10000
    xor edx, edx
    syscall
    test eax, eax
    js .err
    mov r12d, eax
    xor r15d, r15d

.fd_dents:
    mov eax, 217
    mov edi, r12d
    mov rsi, dbuf
    mov edx, DBUF_SZ
    syscall
    cmp eax, 0
    jle .fd_close

    mov r8d, eax
    xor ecx, ecx

.fd_walk:
    cmp ecx, r8d
    jge .fd_dents
    cmp byte [dbuf + rcx + 19], '0'
    jb .fd_skip
    cmp byte [dbuf + rcx + 19], '9'
    ja .fd_skip
    inc r15d
.fd_skip:
    movzx edx, word [dbuf + rcx + 16]
    add ecx, edx
    jmp .fd_walk

.fd_close:
    mov eax, 3
    mov edi, r12d
    syscall
    mov [r13 + OFF_FDS], r15

    ; Overwrite suffix with "/comm" and read name
    mov dword [r14], '/com'
    mov word [r14+4], 'm'

    mov eax, 2
    mov rdi, pbuf
    xor esi, esi
    xor edx, edx
    syscall
    test eax, eax
    js .no_name
    mov r12d, eax

    xor eax, eax
    mov edi, r12d
    lea rsi, [r13 + OFF_NAME]
    mov edx, NAME_LEN - 1
    syscall
    push rax

    mov eax, 3
    mov edi, r12d
    syscall

    pop rax
    test eax, eax
    jle .no_name

    mov ecx, eax
    cmp byte [r13 + rcx + OFF_NAME - 1], 10
    jne .term
    dec ecx
.term:
    mov byte [r13 + rcx + OFF_NAME], 0

    mov rax, [r13 + OFF_FDS]
    pop r15
    pop r14
    pop r13
    pop r12
    ret

.no_name:
    mov byte [r13 + OFF_NAME], '?'
    mov byte [r13 + OFF_NAME + 1], 0
    mov rax, [r13 + OFF_FDS]
    pop r15
    pop r14
    pop r13
    pop r12
    ret

.err:
    mov rax, -1
    pop r15
    pop r14
    pop r13
    pop r12
    ret

; ── Parse PID string: validate + convert ────────
; rdi = string pointer
; Returns: rax = parsed PID (CF clear), or CF set on failure
try_parse_pid:
    xor eax, eax
    cmp byte [rdi], 0
    je .fail
.lp:
    movzx edx, byte [rdi]
    test dl, dl
    jz .ok
    sub dl, '0'
    cmp dl, 9
    ja .fail
    lea rax, [rax + rax*4]
    add rax, rax
    add rax, rdx
    inc rdi
    jmp .lp
.ok:
    clc
    ret
.fail:
    stc
    ret

; ── Insertion sort by fd count descending ───────
sort_procs:
    push r12
    push r13
    push r14

    cmp qword [pcnt], 1
    jle .done

    mov r12, 1

.outer:
    cmp r12, [pcnt]
    jge .done

    ; Save procs[i] to stack
    mov rax, r12
    shl rax, 5
    lea rsi, [procs + rax]
    sub rsp, 32
    mov rdi, rsp
    mov ecx, 4
    rep movsq

    mov r13, [rsp + OFF_FDS]
    mov r14, r12
    dec r14

.inner:
    cmp r14, 0
    jl .insert

    mov rax, r14
    shl rax, 5
    cmp [procs + rax + OFF_FDS], r13
    jge .insert

    ; Shift procs[j] -> procs[j+1]
    lea rsi, [procs + rax]
    lea rdi, [procs + rax + PROC_SZ]
    mov ecx, 4
    rep movsq

    dec r14
    jmp .inner

.insert:
    lea rax, [r14 + 1]
    shl rax, 5
    lea rdi, [procs + rax]
    mov rsi, rsp
    mov ecx, 4
    rep movsq
    add rsp, 32

    inc r12
    jmp .outer

.done:
    pop r14
    pop r13
    pop r12
    ret

; ── Display process table ───────────────────────
show_procs:
    push r12
    push r13
    push r14
    push rbx

    cmp qword [pcnt], 0
    je .none

    mov rsi, a_bold
    call emit
    mov rsi, s_hdr
    call emit
    mov rsi, a_reset
    call emit
    mov rsi, s_nl
    call emit
    mov rsi, s_lsep
    call emit

    mov r12, [pcnt]
    cmp r12, MAX_SHOW
    jle .cntok
    mov r12d, MAX_SHOW
.cntok:
    xor r13d, r13d
    xor ebx, ebx

.row:
    cmp r13, r12
    jge .rest

    mov rax, r13
    shl rax, 5
    lea r14, [procs + rax]
    add rbx, [r14 + OFF_FDS]

    mov rsi, a_yellow
    call emit
    mov rdi, [r14 + OFF_PID]
    mov esi, 7
    call emit_rpad

    mov rsi, a_cyan
    call emit
    mov rdi, [r14 + OFF_FDS]
    mov esi, 7
    call emit_rpad

    mov rsi, a_reset
    call emit
    mov rsi, a_dim
    call emit
    mov rsi, s_2sp
    call emit
    lea rsi, [r14 + OFF_NAME]
    call emit
    mov rsi, a_reset
    call emit
    mov rsi, s_nl
    call emit

    inc r13
    jmp .row

.rest:
    cmp r13, [pcnt]
    jge .totals
    mov rax, r13
    shl rax, 5
    add rbx, [procs + rax + OFF_FDS]
    inc r13
    jmp .rest

.totals:
    mov rsi, s_lsep
    call emit
    mov rsi, a_dim
    call emit
    mov rsi, s_tot_a
    call emit
    mov rdi, rbx
    call emit_num
    mov rsi, s_tot_b
    call emit
    mov rdi, [pcnt]
    call emit_num
    mov rsi, s_tot_c
    call emit
    mov rsi, a_reset
    call emit
    mov rsi, s_nl
    call emit
    jmp .end

.none:
    mov rsi, s_none
    call emit

.end:
    pop rbx
    pop r14
    pop r13
    pop r12
    ret

; ── Display system fd limits ────────────────────
show_sysinfo:
    push r12
    push r13
    push r14

    mov rdi, p_file_nr
    call read_proc_int
    test rax, rax
    js .end
    mov r12, rax

    mov rdi, p_file_max
    call read_proc_int
    test rax, rax
    js .end
    mov r13, rax

    mov rdi, p_nr_open
    call read_proc_int
    test rax, rax
    js .end
    mov r14, rax

    mov rsi, s_lsep
    call emit
    mov rsi, a_dim
    call emit
    mov rsi, s_sys
    call emit

    mov rsi, s_kern
    call emit
    mov rsi, a_cyan
    call emit
    mov rdi, r12
    call emit_num
    mov rsi, a_dim
    call emit
    mov rsi, s_of
    call emit
    mov rsi, a_cyan
    call emit
    mov rdi, r13
    call emit_num
    mov rsi, a_reset
    call emit
    mov rsi, s_nl
    call emit

    mov rsi, a_dim
    call emit
    mov rsi, s_pproc
    call emit
    mov rsi, a_cyan
    call emit
    mov rdi, r14
    call emit_num
    mov rsi, a_reset
    call emit
    mov rsi, s_nl
    call emit

.end:
    pop r14
    pop r13
    pop r12
    ret

; ── Read first integer from a /proc file ────────
; rdi = path, returns rax = value or -1
read_proc_int:
    push r12

    mov eax, 2
    xor esi, esi
    xor edx, edx
    syscall
    test eax, eax
    js .err
    mov r12d, eax

    xor eax, eax
    mov edi, r12d
    mov rsi, pbuf
    mov edx, 63
    syscall
    push rax

    mov eax, 3
    mov edi, r12d
    syscall

    pop rax
    test eax, eax
    jle .err

    mov byte [pbuf + rax], 0
    lea rdi, [pbuf]
    xor eax, eax
.lp:
    movzx edx, byte [rdi]
    sub dl, '0'
    cmp dl, 9
    ja .ret
    lea rax, [rax + rax*4]
    add rax, rax
    add rax, rdx
    inc rdi
    jmp .lp
.ret:
    pop r12
    ret
.err:
    mov rax, -1
    pop r12
    ret

; ── Output buffering ────────────────────────────

; emit: append null-terminated string at rsi to obuf
emit:
    mov rdi, [optr]
.lp:
    lodsb
    test al, al
    jz .done
    stosb
    jmp .lp
.done:
    mov [optr], rdi
    ret

; emit_n: append edx bytes from rsi to obuf
emit_n:
    mov rdi, [optr]
    mov ecx, edx
    rep movsb
    mov [optr], rdi
    ret

; fmt_num: format unsigned rdi into nbuf
; Returns rsi = pointer to start of digits (null-terminated)
fmt_num:
    mov rax, rdi
    lea r8, [nbuf + 30]
    mov byte [r8], 0

    test rax, rax
    jnz .conv
    dec r8
    mov byte [r8], '0'
    jmp .done
.conv:
    mov ecx, 10
.lp:
    xor edx, edx
    div rcx
    add dl, '0'
    dec r8
    mov [r8], dl
    test rax, rax
    jnz .lp
.done:
    mov rsi, r8
    ret

; emit_num: format rdi and emit
emit_num:
    call fmt_num
    jmp emit

; emit_rpad: emit rdi right-aligned in esi-char field
emit_rpad:
    mov r9d, esi
    call fmt_num
    ; rsi = digit string, count its length
    mov rdi, rsi
    xor ecx, ecx
.cnt:
    cmp byte [rdi + rcx], 0
    je .pad
    inc ecx
    jmp .cnt
.pad:
    mov edx, r9d
    sub edx, ecx
    jle .out
    mov rdi, [optr]
    mov al, ' '
.sp:
    stosb
    dec edx
    jnz .sp
    mov [optr], rdi
.out:
    jmp emit

; flush: write obuf to stdout, reset pointer
flush:
    mov rsi, obuf
    mov rdx, [optr]
    sub rdx, rsi
    jle .skip
    mov eax, 1
    mov edi, 1
    syscall
.skip:
    mov rax, obuf
    mov [optr], rax
    ret
