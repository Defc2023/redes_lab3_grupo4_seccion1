; broker_tcp.asm
; Broker TCP pub/sub para noticias deportivas
; Uso: ./broker_tcp <puerto>
;
; Mantiene una tabla de temas con sus suscriptores (fds).
; Usa select() para manejar multiples clientes sin threads.
; Protocolo:
;   SUBSCRIBE|tema\n  -> registra fd como suscriptor
;   PUBLISH|tema|msg\n -> reenviar a todos los suscriptores del tema
;
; nasm -f elf64 broker_tcp.asm -o broker_tcp.o
; gcc -no-pie broker_tcp.o -o broker_tcp

bits 64
default rel

extern printf, snprintf, socket, bind, listen, accept
extern recv, send, close, select, setsockopt
extern htons, memset, strlen, strncpy, strncmp, atoi

AF_INET      equ 2
SOCK_STREAM  equ 1
SOL_SOCKET   equ 1
SO_REUSEADDR equ 2
BACKLOG      equ 10

BUF_SIZE equ 1024

; layout de cada entrada en la tabla de temas:
;   +0   nombre (128 bytes)
;   +128 array de fds suscriptores (50 * 4 = 200 bytes)
;   +328 cantidad de suscriptores (int32)
;   +332 padding (4 bytes)
;   total: 336 bytes
TNAME_LEN  equ 128
MAX_SUBS   equ 50
T_ENTRY    equ 336
MAX_TOPICS equ 20

section .data

uso      db "Uso: ./broker_tcp <puerto>", 10, 0
e_sock   db "Error: socket()", 10, 0
e_bind   db "Error: bind()", 10, 0
e_listen db "Error: listen()", 10, 0

msg_ini  db "Broker TCP escuchando en puerto %d...", 10, 0
msg_new  db "[Broker] Nueva conexion: fd=%d", 10, 0
msg_bye  db "[Broker] Conexion cerrada: fd=%d", 10, 0
msg_sub  db "[Broker] SUBSCRIBE fd=%d tema='%s'", 10, 0
msg_pub  db "[Broker] PUBLISH tema='%s' msg='%s'", 10, 0
msg_fwd  db "[Broker] Reenviando a fd=%d", 10, 0
msg_unk  db "[Broker] Mensaje desconocido de fd=%d", 10, 0

fmt_fwd  db "[%s] %s", 10, 0   ; lo que recibe el suscriptor

opt_one  dd 1

section .bss

lfd       resd 1        ; fd del socket que escucha
svaddr    resb 16
claddr    resb 16
cllen     resd 1

; fd_set en Linux = 128 bytes (un bit por fd, hasta 1024 fds)
mset      resb 128      ; master set
rset      resb 128      ; copia para cada llamada a select

maxfd     resd 1

rbuf      resb BUF_SIZE
fwdbuf    resb BUF_SIZE

; tabla de temas
ttable    resb MAX_TOPICS * T_ENTRY
ntopics   resd 1

section .text
global main

main:
    push rbp
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 8

    cmp rdi, 2
    jge .ok
    lea rdi, [rel uso]
    xor eax, eax
    call printf
    mov eax, 1
    jmp .fin

.ok:
    mov rbx, rsi
    mov rdi, [rbx+8]
    xor eax, eax
    call atoi
    mov r12d, eax   ; puerto

    ; limpiar tabla de temas
    lea rdi, [rel ttable]
    xor esi, esi
    mov edx, MAX_TOPICS * T_ENTRY
    call memset

    ; crear socket
    mov edi, AF_INET
    mov esi, SOCK_STREAM
    xor edx, edx
    call socket
    cmp eax, -1
    je .err_sock
    mov [rel lfd], eax
    movsxd r13, eax

    ; SO_REUSEADDR para no esperar TIME_WAIT al reiniciar
    mov rdi, r13
    mov esi, SOL_SOCKET
    mov edx, SO_REUSEADDR
    lea rcx, [rel opt_one]
    mov r8d, 4
    call setsockopt

    ; bind
    lea rdi, [rel svaddr]
    xor esi, esi
    mov edx, 16
    call memset

    mov word [rel svaddr], AF_INET
    mov edi, r12d
    call htons
    mov word [rel svaddr+2], ax

    mov rdi, r13
    lea rsi, [rel svaddr]
    mov edx, 16
    call bind
    cmp eax, -1
    je .err_bind

    mov rdi, r13
    mov esi, BACKLOG
    call listen
    cmp eax, -1
    je .err_listen

    lea rdi, [rel msg_ini]
    mov esi, r12d
    xor eax, eax
    call printf

    ; inicializar fd_set con el fd de escucha
    lea rdi, [rel mset]
    xor esi, esi
    mov edx, 128
    call memset

    lea rsi, [rel mset]
    mov edi, r13d
    call .fdset_set

    mov [rel maxfd], r13d

; bucle principal: select -> revisar fds activos
.sel:
    ; copiar mset a rset
    lea rdi, [rel rset]
    lea rsi, [rel mset]
    mov ecx, 16
    rep movsq

    mov eax, [rel maxfd]
    inc eax
    movsxd rdi, eax
    lea rsi, [rel rset]
    xor edx, edx
    xor ecx, ecx
    xor r8d, r8d
    call select
    cmp eax, -1
    jl .sel

    xor r14d, r14d   ; fd iterador

.scan:
    mov eax, [rel maxfd]
    cmp r14d, eax
    jg .sel

    lea rsi, [rel rset]
    mov edi, r14d
    call .fdset_isset
    test eax, eax
    jz .next

    cmp r14d, r13d
    je .new_conn

    ; cliente existente -> leer
    movsxd rdi, r14d
    lea rsi, [rel rbuf]
    mov edx, BUF_SIZE-1
    xor ecx, ecx
    call recv
    cmp rax, 0
    jle .desconectado

    lea rbx, [rel rbuf]
    mov byte [rbx+rax], 0

    movsxd rdi, r14d
    lea rsi, [rel rbuf]
    call .procesar
    jmp .next

.desconectado:
    lea rdi, [rel msg_bye]
    mov esi, r14d
    xor eax, eax
    call printf

    movsxd rdi, r14d
    call .quitar_fd

    lea rsi, [rel mset]
    mov edi, r14d
    call .fdset_clr

    movsxd rdi, r14d
    call close
    jmp .next

.new_conn:
    mov dword [rel cllen], 16
    mov rdi, r13
    lea rsi, [rel claddr]
    lea rdx, [rel cllen]
    call accept
    cmp eax, -1
    je .next
    movsxd rbx, eax

    lea rdi, [rel msg_new]
    mov esi, ebx
    xor eax, eax
    call printf

    lea rsi, [rel mset]
    mov edi, ebx
    call .fdset_set

    mov eax, [rel maxfd]
    cmp ebx, eax
    jle .next
    mov [rel maxfd], ebx

.next:
    inc r14d
    jmp .scan

.err_sock:
    lea rdi, [rel e_sock]
    xor eax, eax
    call printf
    mov eax, 1
    jmp .fin

.err_bind:
    lea rdi, [rel e_bind]
    xor eax, eax
    call printf
    mov rdi, r13
    call close
    mov eax, 1
    jmp .fin

.err_listen:
    lea rdi, [rel e_listen]
    xor eax, eax
    call printf
    mov rdi, r13
    call close
    mov eax, 1

.fin:
    add rsp, 8
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret

; procesar(rdi=fd, rsi=msg)
; parsea SUBSCRIBE o PUBLISH y actua
.procesar:
    push rbp
    push rbx
    push r12
    push r13
    push r14
    sub rsp, 8

    mov r12d, edi
    mov r13, rsi

    ; SUBSCRIBE|tema ?
    mov rdi, r13
    lea rsi, [rel .str_sub]
    mov edx, 10
    call strncmp
    test eax, eax
    jnz .check_pub

    mov r14, r13
    add r14, 10   ; apuntar al tema

    ; quitar \n si tiene
    mov rdi, r14
    call strlen
    test rax, rax
    jz .hacer_sub
    lea rbx, [r14+rax-1]
    cmp byte [rbx], 10
    jne .hacer_sub
    mov byte [rbx], 0

.hacer_sub:
    lea rdi, [rel msg_sub]
    mov esi, r12d
    mov rdx, r14
    xor eax, eax
    call printf

    movsxd rdi, r12d
    mov rsi, r14
    call .suscribir
    jmp .proc_fin

.check_pub:
    ; PUBLISH|tema|mensaje ?
    mov rdi, r13
    lea rsi, [rel .str_pub]
    mov edx, 8
    call strncmp
    test eax, eax
    jnz .desconocido

    mov r14, r13
    add r14, 8   ; tema empieza aqui

    ; buscar el | que separa tema de mensaje
    mov rbx, r14
.buscar_pipe:
    cmp byte [rbx], 0
    je .desconocido
    cmp byte [rbx], '|'
    je .pipe_ok
    inc rbx
    jmp .buscar_pipe

.pipe_ok:
    mov byte [rbx], 0
    inc rbx   ; rbx = inicio del mensaje

    ; quitar \n del mensaje
    mov rdi, rbx
    call strlen
    test rax, rax
    jz .hacer_pub
    lea r15, [rbx+rax-1]
    cmp byte [r15], 10
    jne .hacer_pub
    mov byte [r15], 0

.hacer_pub:
    lea rdi, [rel msg_pub]
    mov rsi, r14
    mov rdx, rbx
    xor eax, eax
    call printf

    mov rdi, r14
    mov rsi, rbx
    call .publicar
    jmp .proc_fin

.desconocido:
    lea rdi, [rel msg_unk]
    mov esi, r12d
    xor eax, eax
    call printf

.proc_fin:
    add rsp, 8
    pop r14
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret

.str_sub: db "SUBSCRIBE|", 0
.str_pub: db "PUBLISH|", 0

; buscar_o_crear_tema(rdi=nombre) -> rax=indice o -1
.buscar_tema:
    push rbx
    push r12
    push r13
    push r14
    sub rsp, 8

    mov r12, rdi
    xor r13d, r13d
    mov r14d, -1

.bt_loop:
    cmp r13d, MAX_TOPICS
    jge .bt_crear

    lea rbx, [rel ttable]
    imul rax, r13, T_ENTRY
    add rbx, rax

    cmp byte [rbx], 0
    jne .bt_cmp

    cmp r14d, -1
    jne .bt_sig
    mov r14d, r13d
    jmp .bt_sig

.bt_cmp:
    mov rdi, rbx
    mov rsi, r12
    mov edx, TNAME_LEN
    call strncmp
    test eax, eax
    jnz .bt_sig
    mov eax, r13d
    jmp .bt_ret

.bt_sig:
    inc r13d
    jmp .bt_loop

.bt_crear:
    cmp r14d, -1
    je .bt_fallo

    lea rbx, [rel ttable]
    imul rax, r14, T_ENTRY
    add rbx, rax

    mov rdi, rbx
    mov rsi, r12
    mov edx, TNAME_LEN-1
    call strncpy
    mov byte [rbx+TNAME_LEN-1], 0
    mov dword [rbx+328], 0

    mov eax, [rel ntopics]
    inc eax
    mov [rel ntopics], eax

    mov eax, r14d
    jmp .bt_ret

.bt_fallo:
    mov eax, -1

.bt_ret:
    add rsp, 8
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; suscribir(rdi=fd, rsi=tema)
.suscribir:
    push rbx
    push r12
    push r13
    sub rsp, 8

    movsxd r12, edi
    mov r13, rsi

    mov rdi, r13
    call .buscar_tema
    cmp eax, -1
    je .sub_fin

    movsxd rbx, eax
    lea rdi, [rel ttable]
    imul rax, rbx, T_ENTRY
    add rdi, rax

    mov ecx, [rdi+328]
    cmp ecx, MAX_SUBS
    jge .sub_fin

    ; verificar que no este ya suscrito
    xor r8d, r8d
.sub_dup:
    cmp r8d, ecx
    jge .sub_add
    mov eax, [rdi+128+r8*4]
    cmp eax, r12d
    je .sub_fin
    inc r8d
    jmp .sub_dup

.sub_add:
    movsxd r8, ecx
    mov [rdi+128+r8*4], r12d
    inc ecx
    mov [rdi+328], ecx

.sub_fin:
    add rsp, 8
    pop r13
    pop r12
    pop rbx
    ret

; publicar(rdi=tema, rsi=msg)
.publicar:
    push rbp
    push rbx
    push r12
    push r13
    push r14
    sub rsp, 8

    mov r12, rdi
    mov r13, rsi

    mov rdi, r12
    call .buscar_tema
    cmp eax, -1
    je .pub_fin

    movsxd rbx, eax
    lea r14, [rel ttable]
    imul rax, rbx, T_ENTRY
    add r14, rax

    ; armar "[tema] mensaje\n" en fwdbuf
    lea rdi, [rel fwdbuf]
    mov esi, BUF_SIZE
    lea rdx, [rel fmt_fwd]
    mov rcx, r12
    mov r8, r13
    xor eax, eax
    call snprintf
    movsxd rbp, eax

    mov ecx, [r14+328]
    xor r13d, r13d

.pub_loop:
    cmp r13d, ecx
    jge .pub_fin

    movsxd rdi, dword [r14+128+r13*4]

    push rdi
    push rcx
    lea rdi, [rel msg_fwd]
    mov esi, dword [r14+128+r13*4]
    xor eax, eax
    call printf
    pop rcx
    pop rdi

    lea rsi, [rel fwdbuf]
    mov rdx, rbp
    xor ecx, ecx
    call send

    inc r13d
    mov ecx, [r14+328]
    jmp .pub_loop

.pub_fin:
    add rsp, 8
    pop r14
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret

; quitar_fd(rdi=fd) - sacar el fd de todos los temas
.quitar_fd:
    push rbx
    push r12
    push r13
    sub rsp, 8

    movsxd r12, edi
    xor r13d, r13d

.qfd_loop:
    cmp r13d, MAX_TOPICS
    jge .qfd_fin

    lea rbx, [rel ttable]
    imul rax, r13, T_ENTRY
    add rbx, rax

    cmp byte [rbx], 0
    je .qfd_next

    mov ecx, [rbx+328]
    xor r8d, r8d
.qfd_scan:
    cmp r8d, ecx
    jge .qfd_next
    mov eax, [rbx+128+r8*4]
    cmp eax, r12d
    je .qfd_remove
    inc r8d
    jmp .qfd_scan

.qfd_remove:
    dec ecx
    mov eax, [rbx+128+rcx*4]
    mov [rbx+128+r8*4], eax
    mov [rbx+328], ecx

.qfd_next:
    inc r13d
    jmp .qfd_loop

.qfd_fin:
    add rsp, 8
    pop r13
    pop r12
    pop rbx
    ret

; helpers para fd_set (operar bit a bit sobre los 128 bytes)
; FD_SET(edi=fd, rsi=set)
.fdset_set:
    mov eax, edi
    mov ecx, edi
    shr eax, 6
    and ecx, 63
    mov rdx, 1
    shl rdx, cl
    or qword [rsi+rax*8], rdx
    ret

; FD_CLR(edi=fd, rsi=set)
.fdset_clr:
    mov eax, edi
    mov ecx, edi
    shr eax, 6
    and ecx, 63
    mov rdx, 1
    shl rdx, cl
    not rdx
    and qword [rsi+rax*8], rdx
    ret

; FD_ISSET(edi=fd, rsi=set) -> rax
.fdset_isset:
    mov eax, edi
    mov ecx, edi
    shr eax, 6
    and ecx, 63
    mov rdx, 1
    shl rdx, cl
    test qword [rsi+rax*8], rdx
    setnz al
    movzx rax, al
    ret
