; broker_udp.asm
; Broker UDP - recibe SUBSCRIBE y PUBLISH, reenvía a suscriptores
; Uso: ./broker_udp <puerto>
;
; nasm -f elf64 broker_udp.asm -o broker_udp.o
; gcc -no-pie broker_udp.o -o broker_udp

bits 64
default rel

extern printf, snprintf, socket, bind, recvfrom, sendto, close, setsockopt
extern atoi, htons, ntohs, inet_ntoa, memset, memcmp, strncmp, strncpy, strlen, strchr

AF_INET      equ 2
SOCK_DGRAM   equ 2
SOL_SOCKET   equ 1
SO_REUSEADDR equ 2
BUF_SIZE     equ 1024

; cada entrada de tema: 128 nombre + 50*16 subs + 4 num_subs + 4 pad = 936
TOPIC_NAME   equ 128
MAX_SUBS     equ 50
ENTRY_SIZE   equ 936
MAX_TOPICS   equ 50

section .data

uso         db "Uso: ./broker_udp <puerto>", 10, 0
e_sock      db "Error: socket()", 10, 0
e_bind      db "Error: bind()", 10, 0

fmt_start   db "Broker UDP escuchando en puerto %d...", 10, 0
fmt_sub     db "[Broker] Suscriptor %s:%d suscrito a '%s'", 10, 0
fmt_pub     db "[Broker] Publicando en '%s': %s -> %d suscriptor(es)", 10, 0
fmt_nosubs  db "[Broker] Tema '%s' sin suscriptores", 10, 0
fmt_unk     db "[Broker UDP] Mensaje desconocido", 10, 0
fmt_fwd     db "[%s] %s", 0

opt_one     dd 1

section .bss

sockfd      resd 1
svaddr      resb 16
from_addr   resb 16
from_len    resd 1
rbuf        resb BUF_SIZE
fwd_buf     resb BUF_SIZE
topics      resb MAX_TOPICS * ENTRY_SIZE
num_topics  resd 1

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
    lea rdi, [rel topics]
    xor esi, esi
    mov edx, MAX_TOPICS * ENTRY_SIZE
    call memset

    mov edi, AF_INET
    mov esi, SOCK_DGRAM
    xor edx, edx
    call socket
    cmp eax, -1
    je .err_sock
    movsxd r13, eax
    mov [rel sockfd], eax

    ; reusar puerto si se reinicia
    mov rdi, r13
    mov esi, SOL_SOCKET
    mov edx, SO_REUSEADDR
    lea rcx, [rel opt_one]
    mov r8d, 4
    call setsockopt

    lea rdi, [rel svaddr]
    xor esi, esi
    mov edx, 16
    call memset

    mov word [rel svaddr], AF_INET
    mov dword [rel svaddr+4], 0     ; INADDR_ANY
    mov edi, r12d
    call htons
    mov word [rel svaddr+2], ax

    mov rdi, r13
    lea rsi, [rel svaddr]
    mov edx, 16
    call bind
    cmp eax, -1
    je .err_bind

    lea rdi, [rel fmt_start]
    mov esi, r12d
    xor eax, eax
    call printf

.recibir:
    mov dword [rel from_len], 16

    mov rdi, r13
    lea rsi, [rel rbuf]
    mov edx, BUF_SIZE-1
    xor ecx, ecx
    lea r8, [rel from_addr]
    lea r9, [rel from_len]
    call recvfrom
    cmp rax, 0
    jl .recibir

    lea rbx, [rel rbuf]
    mov byte [rbx+rax], 0

    ; quitar \n si hay
    lea rdi, [rel rbuf]
    mov esi, 10
    call strchr
    test rax, rax
    jz .procesar
    mov byte [rax], 0

.procesar:
    lea rdi, [rel rbuf]
    call procesar_msg

    jmp .recibir

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

.fin:
    add rsp, 8
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret


; procesar_msg(rdi=msg)
; decide si es SUBSCRIBE o PUBLISH
procesar_msg:
    push rbp
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 8

    mov r12, rdi

    mov rdi, r12
    lea rsi, [rel .sub_str]
    mov edx, 10
    call strncmp
    test eax, eax
    jnz .ver_pub

    ; es SUBSCRIBE|tema
    mov r13, r12
    add r13, 10     ; saltar "SUBSCRIBE|"

    mov rdi, r13
    mov rsi, r13
    lea rsi, [rel from_addr]
    call hacer_sub
    jmp .listo

.ver_pub:
    mov rdi, r12
    lea rsi, [rel .pub_str]
    mov edx, 8
    call strncmp
    test eax, eax
    jnz .desconocido

    ; es PUBLISH|tema|msg
    mov r13, r12
    add r13, 8      ; saltar "PUBLISH|"

    ; buscar el segundo | para separar tema de mensaje
    mov rbx, r13
.buscar_pipe:
    cmp byte [rbx], 0
    je .desconocido
    cmp byte [rbx], '|'
    je .pipe_ok
    inc rbx
    jmp .buscar_pipe

.pipe_ok:
    mov byte [rbx], 0
    inc rbx             ; rbx = inicio del mensaje

    lea rdi, [rel fmt_pub]
    mov rsi, r13
    mov rdx, rbx
    xor eax, eax
    call printf

    mov rdi, r13
    mov rsi, rbx
    call hacer_pub
    jmp .listo

.desconocido:
    lea rdi, [rel fmt_unk]
    xor eax, eax
    call printf

.listo:
    add rsp, 8
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret

.sub_str: db "SUBSCRIBE|", 0
.pub_str: db "PUBLISH|", 0


; buscar_tema(rdi=nombre) -> rax = indice en topics, o -1 si lleno
buscar_tema:
    push rbx
    push r12
    push r13
    push r14
    sub rsp, 8

    mov r12, rdi
    xor r13d, r13d
    mov r14d, -1    ; primer slot libre

.loop:
    cmp r13d, MAX_TOPICS
    jge .crear

    lea rbx, [rel topics]
    imul rax, r13, ENTRY_SIZE
    add rbx, rax

    cmp byte [rbx], 0
    jne .comparar

    ; slot vacio, guardar como candidato
    cmp r14d, -1
    jne .siguiente
    mov r14d, r13d
    jmp .siguiente

.comparar:
    mov rdi, rbx
    mov rsi, r12
    mov edx, TOPIC_NAME
    call strncmp
    test eax, eax
    jnz .siguiente
    mov eax, r13d
    jmp .ret

.siguiente:
    inc r13d
    jmp .loop

.crear:
    cmp r14d, -1
    je .fallo

    lea rbx, [rel topics]
    imul rax, r14, ENTRY_SIZE
    add rbx, rax

    mov rdi, rbx
    mov rsi, r12
    mov edx, TOPIC_NAME-1
    call strncpy
    mov byte [rbx + TOPIC_NAME-1], 0
    mov dword [rbx + 928], 0

    mov eax, [rel num_topics]
    inc eax
    mov [rel num_topics], eax

    mov eax, r14d
    jmp .ret

.fallo:
    mov eax, -1

.ret:
    add rsp, 8
    pop r14
    pop r13
    pop r12
    pop rbx
    ret


; hacer_sub(rdi=tema, rsi=&from_addr)
hacer_sub:
    push rbx
    push r12
    push r13
    push r14
    sub rsp, 8

    mov r12, rdi    ; tema
    mov r13, rsi    ; sockaddr del suscriptor

    mov rdi, r12
    call buscar_tema
    cmp eax, -1
    je .listo

    movsxd rbx, eax
    lea r14, [rel topics]
    imul rax, rbx, ENTRY_SIZE
    add r14, rax    ; r14 = entrada del tema

    mov ecx, [r14 + 928]
    cmp ecx, MAX_SUBS
    jge .listo

    ; revisar si ya está suscrito
    xor r8d, r8d
.dup_check:
    cmp r8d, ecx
    jge .agregar

    lea rax, [r14 + 128]
    imul rdx, r8, 16
    add rax, rdx

    mov rdi, rax
    mov rsi, r13
    mov edx, 16
    call memcmp
    test eax, eax
    jz .listo   ; ya estaba

    inc r8d
    mov ecx, [r14 + 928]
    jmp .dup_check

.agregar:
    lea rbx, [r14 + 128]
    imul rax, rcx, 16
    add rbx, rax

    ; copiar 16 bytes del sockaddr_in
    mov rax, [r13]
    mov [rbx], rax
    mov rax, [r13+8]
    mov [rbx+8], rax

    mov ecx, [r14 + 928]
    inc ecx
    mov [r14 + 928], ecx

    ; log: IP y puerto del nuevo suscriptor
    mov edi, dword [r13+4]
    call inet_ntoa

    movzx edi, word [r13+2]
    push rax
    call ntohs
    movzx edx, ax
    pop rsi

    lea rdi, [rel fmt_sub]
    mov rcx, r12
    xor eax, eax
    call printf

.listo:
    add rsp, 8
    pop r14
    pop r13
    pop r12
    pop rbx
    ret


; hacer_pub(rdi=tema, rsi=mensaje)
hacer_pub:
    push rbp
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 8

    mov r12, rdi    ; tema
    mov r13, rsi    ; mensaje

    mov rdi, r12
    call buscar_tema
    cmp eax, -1
    je .listo

    movsxd rbx, eax
    lea r14, [rel topics]
    imul rax, rbx, ENTRY_SIZE
    add r14, rax

    ; armar "[tema] mensaje" en fwd_buf
    lea rdi, [rel fwd_buf]
    mov esi, BUF_SIZE
    lea rdx, [rel fmt_fwd]
    mov rcx, r12
    mov r8, r13
    xor eax, eax
    call snprintf
    movsxd r15, eax

    mov ecx, [r14 + 928]
    xor r13d, r13d  ; iterador

.enviar:
    cmp r13d, ecx
    jge .listo

    lea rax, [r14 + 128]
    imul rdx, r13, 16
    add rax, rdx

    movsxd rdi, dword [rel sockfd]
    lea rsi, [rel fwd_buf]
    mov rdx, r15
    xor ecx, ecx
    mov r8, rax
    mov r9d, 16
    call sendto

    inc r13d
    mov ecx, [r14 + 928]
    jmp .enviar

.listo:
    add rsp, 8
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret
