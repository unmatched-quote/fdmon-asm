; fdmon - x86_64 Linux file descriptor monitor
; Build: nasm -f elf64 fdmon.asm && ld -o fdmon fdmon.o

BITS 64

%define MAX_PROCS   512
%define MAX_SHOW    32
%define PROC_SZ     40
%define OFF_PID     0
%define OFF_FDS     8
%define OFF_MEM     16
%define OFF_NAME    24
%define NAME_LEN    16
%define DBUF_SZ     8192
%define OBUF_SZ     16384
%define TERMIOS_SZ  60

; ioctl commands
%define TCGETS      0x5401
%define TCSETS      0x5402
%define TIOCGWINSZ  0x5413

; termios offsets
%define LFLAG_OFF   12
%define VTIME_OFF   22
%define VMIN_OFF    23

; termios flags
%define ICANON      0x02
%define ECHO        0x08

section .data
    path_proc:   db "/proc",0
    p_file_max:  db "/proc/sys/fs/file-max",0
    p_file_nr:   db "/proc/sys/fs/file-nr",0
    p_nr_open:   db "/proc/sys/fs/nr_open",0

    a_clear:     db 27,"[2J",27,"[H",0
    a_home:      db 27,"[H",0
    a_hide:      db 27,"[?25l",0
    a_clreos:    db 27,"[J",0
    a_alt_on:    db 27,"[?1049h",0
    a_cleanup:   db 27,"[?25h",27,"[?1049l"
    CLEANUP_LEN  equ $ - a_cleanup
    a_bold:      db 27,"[1m",0
    a_bold_cyan: db 27,"[1;36m",0
    a_cyan:      db 27,"[36m",0
    a_yellow:    db 27,"[33m",0
    a_reset:     db 27,"[0m",0
    a_dim:       db 27,"[2m",0
    a_rev:       db 27,"[7m",0

    s_title:     db "File Descriptor Monitor",10,0
    s_sep:       db 27,"[K════════════════════════════════════════════════════════════",10,0
    s_lsep:      db 27,"[K────────────────────────────────────────────────────────────",10,0
    s_hdr:       db "    PID     FDs  Command",0
    s_hdr_mem:   db "    PID     FDs      Mem  Command",0
    s_nl:        db 27,"[K",10,0
    s_none:      db "No readable processes found!",27,"[K",10,0
    s_tot_a:     db "  Total: ",0
    s_tot_b:     db " fds across ",0
    s_tot_c:     db " processes",0
    s_2sp:       db "  ",0
    s_mb:        db "M",0
    s_sys:       db "  System Limits",27,"[K",10,0
    s_kern:      db "    Kernel handles    ",0
    s_of:        db " / ",0
    s_pproc:     db "    Per-process max   ",0

    ; Footer with key hints
    s_keys:      db 27,"[K",10,"  ",0
    s_k_fds:     db "[F]ds ",0
    s_k_pid:     db "[P]id ",0
    s_k_mem_on:  db "[M]em:on  ",0
    s_k_mem_off: db "[M]em:off ",0
    s_k_quit:    db "[Q]uit",0

    sigact:      dq on_sigint, 0x04000000, sa_restore, 0

section .bss
    obuf:       resb OBUF_SZ
    optr:       resq 1
    dbuf:       resb DBUF_SZ
    pbuf:       resb 64
    nbuf:       resb 32
    procs:      resb PROC_SZ * MAX_PROCS
    pcnt:       resq 1
    winsz:      resb 8
    maxdsp:     resd 1
    termios_o:  resb TERMIOS_SZ
    termios_r:  resb TERMIOS_SZ
    keybuf:     resb 1
    sort_mode:  resb 1          ; 0=fds desc, 1=pid asc
    show_mem:   resb 1          ; 0=off, 1=on

section .text
    global _start

on_sigint:
    ; Restore terminal settings
    mov eax, 16
    xor edi, edi
    mov esi, TCSETS
    mov rdx, termios_o
    syscall
    ; Show cursor, leave alt screen
    mov eax, 1
    mov edi, 1
    mov rsi, a_cleanup
    mov edx, CLEANUP_LEN
    syscall
    mov eax, 60
    xor edi, edi
    syscall

sa_restore:
    mov eax, 15
    syscall

_start:
    ; Install SIGINT handler
    mov eax, 13
    mov edi, 2
    mov rsi, sigact
    xor edx, edx
    mov r10d, 8
    syscall

    ; Save original terminal settings
    mov eax, 16
    xor edi, edi
    mov esi, TCGETS
    mov rdx, termios_o
    syscall

    ; Copy to raw and modify
    mov rsi, termios_o
    mov rdi, termios_r
    mov ecx, TERMIOS_SZ
    rep movsb

    ; Set raw mode: clear ICANON|ECHO, set VMIN=0, VTIME=10
    and dword [termios_r + LFLAG_OFF], ~(ICANON | ECHO)
    mov byte [termios_r + VMIN_OFF], 0
    mov byte [termios_r + VTIME_OFF], 10

    ; Apply raw mode
    mov eax, 16
    xor edi, edi
    mov esi, TCSETS
    mov rdx, termios_r
    syscall

    ; Initialize state
    mov byte [sort_mode], 0
    mov byte [show_mem], 0

    mov rax, obuf
    mov [optr], rax

    mov rsi, a_alt_on
    call emit
    mov rsi, a_hide
    call emit
    mov rsi, a_clear
    call emit
    call flush

.loop:
    mov rax, obuf
    mov [optr], rax

    ; Query terminal height
    mov eax, 16
    mov edi, 1
    mov esi, TIOCGWINSZ
    lea rdx, [winsz]
    syscall
    movzx eax, word [winsz]
    sub eax, 14
    jg .got_rows
    mov eax, 1
.got_rows:
    cmp eax, MAX_SHOW
    jle .rows_ok
    mov eax, MAX_SHOW
.rows_ok:
    mov [maxdsp], eax

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
    call show_keys

    mov rsi, a_clreos
    call emit

    call flush

    ; Read keyboard with 1s timeout (VTIME=10)
    xor eax, eax
    xor edi, edi
    mov rsi, keybuf
    mov edx, 1
    syscall

    test eax, eax
    jle .loop

    ; Handle keypress
    movzx eax, byte [keybuf]

    ; 'q' or 'Q' - quit
    cmp al, 'q'
    je .quit
    cmp al, 'Q'
    je .quit

    ; 'f' or 'F' - sort by FDs
    cmp al, 'f'
    je .sort_fds
    cmp al, 'F'
    je .sort_fds

    ; 'p' or 'P' - sort by PID
    cmp al, 'p'
    je .sort_pid
    cmp al, 'P'
    je .sort_pid

    ; 'm' or 'M' - toggle memory column
    cmp al, 'm'
    je .toggle_mem
    cmp al, 'M'
    je .toggle_mem

    jmp .loop

.sort_fds:
    mov byte [sort_mode], 0
    jmp .loop

.sort_pid:
    mov byte [sort_mode], 1
    jmp .loop

.toggle_mem:
    xor byte [show_mem], 1
    jmp .loop

.quit:
    ; Restore terminal
    mov eax, 16
    xor edi, edi
    mov esi, TCSETS
    mov rdx, termios_o
    syscall
    ; Cleanup display
    mov eax, 1
    mov edi, 1
    mov rsi, a_cleanup
    mov edx, CLEANUP_LEN
    syscall
    ; Exit
    mov eax, 60
    xor edi, edi
    syscall

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
    imul rcx, rcx, PROC_SZ
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

    imul rax, r12, PROC_SZ
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
    imul rcx, rcx, PROC_SZ
    mov rax, [procs + rcx + OFF_PID]
    mov [r14 + OFF_PID], rax
    jmp .fill

.done:
    pop r14
    pop r13
    pop r12
    ret

; Probe one process: count fds, read name, read memory
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
    mov r14, rcx

    ; --- Count FDs ---
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

    ; --- Read /comm ---
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
    jmp .read_mem

.no_name:
    mov byte [r13 + OFF_NAME], '?'
    mov byte [r13 + OFF_NAME + 1], 0

.read_mem:
    ; --- Read /statm for RSS ---
    mov qword [r13 + OFF_MEM], 0

    mov dword [r14], '/sta'
    mov word [r14+4], 'tm'
    mov byte [r14+6], 0

    mov eax, 2
    mov rdi, pbuf
    xor esi, esi
    xor edx, edx
    syscall
    test eax, eax
    js .done_ok
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
    jle .done_ok

    ; Parse statm: skip first number, parse second (RSS in pages)
    mov byte [pbuf + rax], 0
    lea rdi, [pbuf]

    ; Skip first number (size)
.skip1:
    movzx eax, byte [rdi]
    cmp al, ' '
    je .skip1_done
    cmp al, 9
    je .skip1_done
    test al, al
    jz .done_ok
    inc rdi
    jmp .skip1
.skip1_done:
    ; Skip whitespace
.skip_ws:
    movzx eax, byte [rdi]
    cmp al, ' '
    je .skip_ws_next
    cmp al, 9
    je .skip_ws_next
    jmp .parse_rss
.skip_ws_next:
    inc rdi
    jmp .skip_ws

.parse_rss:
    xor eax, eax
.rss_loop:
    movzx edx, byte [rdi]
    sub dl, '0'
    cmp dl, 9
    ja .rss_done
    lea rax, [rax + rax*4]
    add rax, rax
    add rax, rdx
    inc rdi
    jmp .rss_loop
.rss_done:
    ; RSS is in pages, convert to bytes (page = 4096)
    shl rax, 12
    mov [r13 + OFF_MEM], rax

.done_ok:
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

sort_procs:
    push r12
    push r13
    push r14
    push r15

    cmp qword [pcnt], 1
    jle .done

    ; r15 = sort_mode (0=fds desc, 1=pid asc)
    movzx r15d, byte [sort_mode]

    mov r12, 1

.outer:
    cmp r12, [pcnt]
    jge .done

    ; Save procs[i] to stack
    imul rax, r12, PROC_SZ
    lea rsi, [procs + rax]
    sub rsp, PROC_SZ
    mov rdi, rsp
    mov ecx, 5
    rep movsq

    ; Key value for comparison
    test r15d, r15d
    jnz .key_pid
    mov r13, [rsp + OFF_FDS]
    jmp .key_done
.key_pid:
    mov r13, [rsp + OFF_PID]
.key_done:

    mov r14, r12
    dec r14

.inner:
    cmp r14, 0
    jl .insert

    imul rax, r14, PROC_SZ

    ; Compare based on sort mode
    test r15d, r15d
    jnz .cmp_pid

    ; Sort by FDs descending
    cmp [procs + rax + OFF_FDS], r13
    jge .insert
    jmp .shift

.cmp_pid:
    ; Sort by PID ascending
    cmp [procs + rax + OFF_PID], r13
    jle .insert

.shift:
    lea rsi, [procs + rax]
    lea rdi, [procs + rax + PROC_SZ]
    mov ecx, 5
    rep movsq

    dec r14
    jmp .inner

.insert:
    lea rax, [r14 + 1]
    imul rax, rax, PROC_SZ
    lea rdi, [procs + rax]
    mov rsi, rsp
    mov ecx, 5
    rep movsq
    add rsp, PROC_SZ

    inc r12
    jmp .outer

.done:
    pop r15
    pop r14
    pop r13
    pop r12
    ret

show_procs:
    push r12
    push r13
    push r14
    push r15
    push rbx

    movzx r15d, byte [show_mem]

    cmp qword [pcnt], 0
    je .none

    ; Header
    mov rsi, a_bold
    call emit
    test r15d, r15d
    jz .hdr_no_mem
    mov rsi, s_hdr_mem
    jmp .hdr_emit
.hdr_no_mem:
    mov rsi, s_hdr
.hdr_emit:
    call emit
    mov rsi, a_reset
    call emit
    mov rsi, s_nl
    call emit
    mov rsi, s_lsep
    call emit

    mov r12, [pcnt]
    mov eax, [maxdsp]
    cmp r12, rax
    jle .cntok
    mov r12d, eax
.cntok:
    xor r13d, r13d
    xor ebx, ebx

.row:
    cmp r13, r12
    jge .rest

    imul rax, r13, PROC_SZ
    lea r14, [procs + rax]
    add rbx, [r14 + OFF_FDS]

    ; PID (yellow)
    mov rsi, a_yellow
    call emit
    mov rdi, [r14 + OFF_PID]
    mov esi, 7
    call emit_rpad

    ; FDs (cyan)
    mov rsi, a_cyan
    call emit
    mov rdi, [r14 + OFF_FDS]
    mov esi, 7
    call emit_rpad

    ; Memory column (if enabled)
    test r15d, r15d
    jz .no_mem_col

    mov rsi, a_cyan
    call emit
    mov rax, [r14 + OFF_MEM]
    shr rax, 20             ; bytes to MB
    mov rdi, rax
    mov esi, 7
    call emit_rpad
    mov rsi, s_mb
    call emit

.no_mem_col:
    ; Command name (dim)
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
    imul rax, r13, PROC_SZ
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
    pop r15
    pop r14
    pop r13
    pop r12
    ret

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

show_keys:
    mov rsi, s_keys
    call emit
    mov rsi, a_dim
    call emit

    ; Show sort mode - highlight active
    cmp byte [sort_mode], 0
    jne .pid_sort
    mov rsi, a_rev
    call emit
    mov rsi, s_k_fds
    call emit
    mov rsi, a_reset
    call emit
    mov rsi, a_dim
    call emit
    mov rsi, s_k_pid
    call emit
    jmp .show_mem_key
.pid_sort:
    mov rsi, s_k_fds
    call emit
    mov rsi, a_rev
    call emit
    mov rsi, s_k_pid
    call emit
    mov rsi, a_reset
    call emit
    mov rsi, a_dim
    call emit

.show_mem_key:
    cmp byte [show_mem], 0
    jne .mem_on
    mov rsi, s_k_mem_off
    call emit
    jmp .show_quit
.mem_on:
    mov rsi, a_rev
    call emit
    mov rsi, s_k_mem_on
    call emit
    mov rsi, a_reset
    call emit
    mov rsi, a_dim
    call emit

.show_quit:
    mov rsi, s_k_quit
    call emit
    mov rsi, a_reset
    call emit
    mov rsi, s_nl
    call emit
    ret

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

emit_n:
    mov rdi, [optr]
    mov ecx, edx
    rep movsb
    mov [optr], rdi
    ret

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

emit_num:
    call fmt_num
    jmp emit

emit_rpad:
    mov r9d, esi
    call fmt_num
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
