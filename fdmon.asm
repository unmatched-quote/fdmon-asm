; fdmon - x86_64 Linux file descriptor monitor
; Displays open fd counts per process, sorted by count
; Build: nasm -f elf64 fdmon.asm && ld -o fdmon fdmon.o

BITS 64

%define MAX_PROCS   512
%define MAX_SHOW    32
%define PROC_SZ     32      ; pid(8) + fds(8) + name(16)
%define OFF_PID     0
%define OFF_FDS     8
%define OFF_NAME    16
%define NAME_LEN    16
%define DBUF_SZ     8192

section .data
    path_proc:  db "/proc",0
    sfx_fd:     db "/fd",0
    sfx_comm:   db "/comm",0

    ; ANSI escape sequences
    a_clear:    db 27,"[2J",27,"[H",0
    a_home:     db 27,"[H",0
    a_hide:     db 27,"[?25l",0
    a_show:     db 27,"[?25h",0
    a_clreos:   db 27,"[J",0
    a_cyan:     db 27,"[36m",0
    a_yellow:   db 27,"[33m",0
    a_white:    db 27,"[37m",0
    a_reset:    db 27,"[0m",0
    a_bold:     db 27,"[1m",0
    a_dim:      db 27,"[2m",0

    ; Display strings
    s_title:    db "File Descriptor Monitor",10,0
    s_sep:      db "════════════════════════════════════════════════════",10,0
    s_lsep:     db "────────────────────────────────────────────────────",10,0
    s_hdr:      db "    PID     FDs  Command",0
    s_nl:       db 27,"[K",10,0
    s_quit:     db 27,"[K",10,"Press Ctrl+C to quit",27,"[K",10,0
    s_none:     db "No readable processes found!",27,"[K",10,0
    s_tot_a:    db "  Total: ",0
    s_tot_b:    db " fds across ",0
    s_tot_c:    db " processes",0
    s_2sp:      db "  ",0
    s_pad:      db "               "   ; 15 spaces (no null, used by write_n)

    ; Sleep: 1 second
    ts_1s:      dq 1, 0

    ; SIGINT handler struct
    sigact:     dq on_sigint, 0x04000000, sa_restore, 0

section .bss
    dbuf:       resb DBUF_SZ        ; getdents64 buffer
    pbuf:       resb 64             ; path builder scratch
    nbuf:       resb 32             ; number formatting scratch
    procs:      resb PROC_SZ * MAX_PROCS
    pcnt:       resq 1

section .text
    global _start

; ============================================
; SIGINT handler: restore cursor, exit
; ============================================
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

; ============================================
; Entry point
; ============================================
_start:
    ; Install SIGINT handler
    mov eax, 13
    mov edi, 2
    mov rsi, sigact
    xor edx, edx
    mov r10d, 8
    syscall

    mov rsi, a_hide
    call puts
    mov rsi, a_clear
    call puts

.loop:
    mov rsi, a_home
    call puts

    call scan_procs
    call sort_procs

    ; Title
    mov rsi, a_bold
    call puts
    mov rsi, a_cyan
    call puts
    mov rsi, s_title
    call puts
    mov rsi, a_reset
    call puts
    mov rsi, s_sep
    call puts

    call show_procs

    ; Quit hint
    mov rsi, a_dim
    call puts
    mov rsi, s_quit
    call puts
    mov rsi, a_reset
    call puts

    ; Erase rest of screen
    mov rsi, a_clreos
    call puts

    ; Sleep 1 second
    mov eax, 35
    mov rdi, ts_1s
    xor esi, esi
    syscall

    jmp .loop

; ============================================
; Scan all processes from /proc
; Phase 1: enumerate PIDs via getdents64
; Phase 2: count fds + read comm for each
; ============================================
scan_procs:
    push r12
    push r13
    push r14

    mov qword [pcnt], 0

    ; Open /proc
    mov eax, 2
    mov rdi, path_proc
    mov esi, 0x10000         ; O_RDONLY | O_DIRECTORY
    xor edx, edx
    syscall
    test eax, eax
    js .sc_done
    mov r12d, eax            ; r12 = /proc fd

    ; --- Phase 1: collect PIDs ---
.sc_dents:
    mov eax, 217             ; sys_getdents64
    mov edi, r12d
    mov rsi, dbuf
    mov edx, DBUF_SZ
    syscall
    cmp eax, 0
    jle .sc_close

    mov r13d, eax            ; bytes read
    xor r14d, r14d           ; offset into dbuf

.sc_walk:
    cmp r14d, r13d
    jge .sc_dents

    ; d_name at offset 19 in linux_dirent64
    lea rdi, [dbuf + r14 + 19]
    call is_pid
    test eax, eax
    jz .sc_next

    cmp qword [pcnt], MAX_PROCS
    jge .sc_next

    ; Parse PID number from d_name
    lea rsi, [dbuf + r14 + 19]
    call parse_num
    mov rcx, [pcnt]
    shl rcx, 5
    mov [procs + rcx + OFF_PID], rax
    inc qword [pcnt]

.sc_next:
    movzx eax, word [dbuf + r14 + 16]  ; d_reclen
    add r14d, eax
    jmp .sc_walk

.sc_close:
    mov eax, 3
    mov edi, r12d
    syscall

    ; --- Phase 2: fill fd counts and names ---
    xor r12d, r12d           ; index

.sc_fill:
    cmp r12, [pcnt]
    jge .sc_done

    mov rax, r12
    shl rax, 5
    lea r14, [procs + rax]

    ; Count open fds
    mov rdi, [r14 + OFF_PID]
    call count_fds
    test rax, rax
    js .sc_remove
    mov [r14 + OFF_FDS], rax

    ; Read process name
    mov rdi, [r14 + OFF_PID]
    lea rsi, [r14 + OFF_NAME]
    call read_comm

    inc r12
    jmp .sc_fill

.sc_remove:
    ; Swap with last entry, retry current index
    dec qword [pcnt]
    mov rcx, [pcnt]
    shl rcx, 5
    mov rax, [procs + rcx + OFF_PID]
    mov [r14 + OFF_PID], rax
    jmp .sc_fill

.sc_done:
    pop r14
    pop r13
    pop r12
    ret

; ============================================
; Count fds in /proc/pid/fd
; rdi = pid, returns rax = count or -1
; ============================================
count_fds:
    push r12
    push r13

    mov rsi, sfx_fd
    call build_path

    ; Open /proc/pid/fd
    mov eax, 2
    mov rdi, pbuf
    mov esi, 0x10000         ; O_RDONLY | O_DIRECTORY
    xor edx, edx
    syscall
    test eax, eax
    js .cf_err
    mov r12d, eax            ; directory fd
    xor r13d, r13d           ; fd count = 0

.cf_dents:
    mov eax, 217
    mov edi, r12d
    mov rsi, dbuf
    mov edx, DBUF_SZ
    syscall
    cmp eax, 0
    jle .cf_close

    mov r8d, eax             ; bytes read
    xor ecx, ecx

.cf_walk:
    cmp ecx, r8d
    jge .cf_dents

    ; Count entries with numeric d_name (skip . and ..)
    cmp byte [dbuf + rcx + 19], '0'
    jb .cf_skip
    cmp byte [dbuf + rcx + 19], '9'
    ja .cf_skip
    inc r13d

.cf_skip:
    movzx edx, word [dbuf + rcx + 16]
    add ecx, edx
    jmp .cf_walk

.cf_close:
    mov eax, 3
    mov edi, r12d
    syscall
    mov eax, r13d
    pop r13
    pop r12
    ret

.cf_err:
    mov rax, -1
    pop r13
    pop r12
    ret

; ============================================
; Read /proc/pid/comm into name buffer
; rdi = pid, rsi = dest buffer (NAME_LEN bytes)
; ============================================
read_comm:
    push r12
    push r13
    mov r12, rsi             ; save dest

    mov rsi, sfx_comm
    call build_path

    mov eax, 2
    mov rdi, pbuf
    xor esi, esi
    xor edx, edx
    syscall
    test eax, eax
    js .rc_fail
    mov r13d, eax            ; file fd

    xor eax, eax
    mov edi, r13d
    mov rsi, r12
    mov edx, NAME_LEN - 1
    syscall
    push rax

    mov eax, 3
    mov edi, r13d
    syscall

    pop rax
    test eax, eax
    jle .rc_fail

    ; Null-terminate, strip trailing newline
    mov ecx, eax
    cmp byte [r12 + rcx - 1], 10
    jne .rc_term
    dec ecx
.rc_term:
    mov byte [r12 + rcx], 0
    pop r13
    pop r12
    ret

.rc_fail:
    mov byte [r12], '?'
    mov byte [r12 + 1], 0
    pop r13
    pop r12
    ret

; ============================================
; Build path: "/proc/{pid}{suffix}" -> pbuf
; rdi = pid (int), rsi = suffix (e.g. "/fd\0")
; ============================================
build_path:
    push rbx
    push rcx
    push r8
    mov rbx, rsi             ; save suffix

    ; Write "/proc/" prefix
    lea rcx, [pbuf]
    mov dword [rcx], '/pro'
    mov word [rcx+4], 'c/'
    add rcx, 6

    ; Convert PID to digits backwards in nbuf, then copy forward
    mov rax, rdi
    lea r8, [nbuf + 20]
    mov byte [r8], 0

.bp_dig:
    dec r8
    xor edx, edx
    mov rdi, 10
    div rdi
    add dl, '0'
    mov [r8], dl
    test rax, rax
    jnz .bp_dig

    ; Copy digits to pbuf
.bp_cpyd:
    mov al, [r8]
    test al, al
    jz .bp_sfx
    mov [rcx], al
    inc rcx
    inc r8
    jmp .bp_cpyd

    ; Append suffix
.bp_sfx:
    mov al, [rbx]
    mov [rcx], al
    test al, al
    jz .bp_end
    inc rbx
    inc rcx
    jmp .bp_sfx

.bp_end:
    pop r8
    pop rcx
    pop rbx
    ret

; ============================================
; Check if null-terminated string is all digits
; rdi = string, returns eax = 1 if pid, 0 if not
; ============================================
is_pid:
    cmp byte [rdi], 0
    je .ip_no
    mov rcx, rdi
.ip_lp:
    movzx eax, byte [rcx]
    test al, al
    jz .ip_yes
    sub al, '0'
    cmp al, 9
    ja .ip_no
    inc rcx
    jmp .ip_lp
.ip_yes:
    mov eax, 1
    ret
.ip_no:
    xor eax, eax
    ret

; ============================================
; Insertion sort by fd_count descending
; ============================================
sort_procs:
    push r12
    push r13
    push r14

    cmp qword [pcnt], 1
    jle .so_done

    mov r12, 1               ; i = 1

.so_outer:
    cmp r12, [pcnt]
    jge .so_done

    ; Save procs[i] (32 bytes) to stack
    mov rax, r12
    shl rax, 5
    lea rsi, [procs + rax]
    sub rsp, 32
    mov rax, [rsi]
    mov [rsp], rax
    mov rax, [rsi + 8]
    mov [rsp + 8], rax
    mov rax, [rsi + 16]
    mov [rsp + 16], rax
    mov rax, [rsi + 24]
    mov [rsp + 24], rax

    mov r13, [rsp + OFF_FDS] ; key fd_count

    ; j = i - 1
    mov r14, r12
    dec r14

.so_inner:
    cmp r14, 0
    jl .so_insert

    mov rax, r14
    shl rax, 5

    ; If procs[j].fds >= key, stop
    cmp [procs + rax + OFF_FDS], r13
    jge .so_insert

    ; Shift procs[j] -> procs[j+1]
    lea rsi, [procs + rax]
    lea rdi, [rsi + PROC_SZ]
    mov rcx, [rsi]
    mov [rdi], rcx
    mov rcx, [rsi + 8]
    mov [rdi + 8], rcx
    mov rcx, [rsi + 16]
    mov [rdi + 16], rcx
    mov rcx, [rsi + 24]
    mov [rdi + 24], rcx

    dec r14
    jmp .so_inner

.so_insert:
    ; Place saved key at procs[j+1]
    lea rax, [r14 + 1]
    shl rax, 5
    lea rdi, [procs + rax]
    mov rcx, [rsp]
    mov [rdi], rcx
    mov rcx, [rsp + 8]
    mov [rdi + 8], rcx
    mov rcx, [rsp + 16]
    mov [rdi + 16], rcx
    mov rcx, [rsp + 24]
    mov [rdi + 24], rcx
    add rsp, 32

    inc r12
    jmp .so_outer

.so_done:
    pop r14
    pop r13
    pop r12
    ret

; ============================================
; Display process table
; ============================================
show_procs:
    push r12
    push r13
    push r14
    push rbx

    cmp qword [pcnt], 0
    je .sh_none

    ; Header
    mov rsi, a_bold
    call puts
    mov rsi, s_hdr
    call puts
    mov rsi, a_reset
    call puts
    mov rsi, s_nl
    call puts
    mov rsi, s_lsep
    call puts

    ; Display count = min(pcnt, MAX_SHOW)
    mov r12, [pcnt]
    cmp r12, MAX_SHOW
    jle .sh_cntok
    mov r12d, MAX_SHOW
.sh_cntok:
    xor r13d, r13d           ; display index
    xor ebx, ebx             ; total fds accumulator

.sh_row:
    cmp r13, r12
    jge .sh_rest

    mov rax, r13
    shl rax, 5
    lea r14, [procs + rax]

    add rbx, [r14 + OFF_FDS]

    ; PID (yellow, right-aligned 7 chars)
    mov rsi, a_yellow
    call puts
    mov rdi, [r14 + OFF_PID]
    mov esi, 7
    call put_rpad
    mov rsi, a_reset
    call puts

    ; FDs (cyan, right-aligned 7 chars)
    mov rsi, a_cyan
    call puts
    mov rdi, [r14 + OFF_FDS]
    mov esi, 7
    call put_rpad
    mov rsi, a_reset
    call puts

    ; "  " + command name
    mov rsi, s_2sp
    call puts
    lea rsi, [r14 + OFF_NAME]
    call puts
    mov rsi, s_nl
    call puts

    inc r13
    jmp .sh_row

.sh_rest:
    ; Accumulate fds for processes not displayed
    cmp r13, [pcnt]
    jge .sh_totals
    mov rax, r13
    shl rax, 5
    add rbx, [procs + rax + OFF_FDS]
    inc r13
    jmp .sh_rest

.sh_totals:
    mov rsi, s_lsep
    call puts

    mov rsi, a_dim
    call puts
    mov rsi, s_tot_a
    call puts
    mov rdi, rbx
    call put_num
    mov rsi, s_tot_b
    call puts
    mov rdi, [pcnt]
    call put_num
    mov rsi, s_tot_c
    call puts
    mov rsi, a_reset
    call puts
    mov rsi, s_nl
    call puts
    jmp .sh_end

.sh_none:
    mov rsi, s_none
    call puts

.sh_end:
    pop rbx
    pop r14
    pop r13
    pop r12
    ret

; ============================================
; Parse unsigned decimal at [rsi] into rax
; ============================================
parse_num:
    xor eax, eax
.pn_lp:
    movzx edx, byte [rsi]
    sub dl, '0'
    cmp dl, 9
    ja .pn_r
    imul rax, 10
    add rax, rdx
    inc rsi
    jmp .pn_lp
.pn_r:
    ret

; ============================================
; Print null-terminated string at rsi
; ============================================
puts:
    push rax
    push rcx
    push rdx
    push rdi
    mov rdi, rsi
    xor ecx, ecx
.ps_l:
    cmp byte [rdi + rcx], 0
    je .ps_w
    inc ecx
    jmp .ps_l
.ps_w:
    mov eax, 1
    mov edx, ecx
    mov edi, 1
    syscall
    pop rdi
    pop rdx
    pop rcx
    pop rax
    ret

; ============================================
; Write rdx bytes from rsi to stdout
; ============================================
write_n:
    push rax
    push rcx
    push rdx
    push rdi
    mov eax, 1
    mov edi, 1
    syscall
    pop rdi
    pop rdx
    pop rcx
    pop rax
    ret

; ============================================
; Print unsigned integer in rdi
; ============================================
put_num:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    mov rax, rdi
    lea rcx, [nbuf + 30]
    mov byte [rcx], 0

    test rax, rax
    jnz .nu_conv
    dec rcx
    mov byte [rcx], '0'
    jmp .nu_print

.nu_conv:
    mov ebx, 10
.nu_loop:
    test rax, rax
    jz .nu_print
    xor edx, edx
    div rbx
    add dl, '0'
    dec rcx
    mov [rcx], dl
    jmp .nu_loop

.nu_print:
    mov rsi, rcx
    call puts
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; ============================================
; Print rdi right-aligned in esi-char field
; ============================================
put_rpad:
    push rax
    push rcx
    push rdx
    push rdi
    push rsi

    mov r8d, esi             ; field width
    mov rax, rdi

    ; Count digits
    xor ecx, ecx
    test rax, rax
    jnz .rp_cnt
    inc ecx
    jmp .rp_pad

.rp_cnt:
    mov r9d, 10
.rp_cnt_lp:
    test rax, rax
    jz .rp_pad
    xor edx, edx
    div r9
    inc ecx
    jmp .rp_cnt_lp

.rp_pad:
    mov edx, r8d
    sub edx, ecx
    jle .rp_num
    mov rsi, s_pad
    call write_n

.rp_num:
    pop rsi
    pop rdi
    call put_num
    pop rdx
    pop rcx
    pop rax
    ret
