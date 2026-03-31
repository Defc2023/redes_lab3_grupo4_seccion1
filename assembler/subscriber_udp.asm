; subscriber_udp.asm
; Suscriptor UDP - manda SUBSCRIBE y espera datagramas del broker
; Uso: ./subscriber_udp <ip> <puerto> <tema>
;
; nasm -f elf64 subscriber_udp.asm -o subscriber_udp.o
; gcc -no-pie subscriber_udp.o -o subscriber_udp

bits 64
default rel

extern printf, snprintf, socket, bind, sendto, recvfrom, close
extern atoi, inet_addr, htons, memset

AF_INET    equ 2
SOCK_DGRAM equ 2
BUF_SIZE   equ 1024

section .data

uso     db "Uso: ./subscriber_udp <ip> <puerto> <tema>", 10, 0
e_sock  db "Error creando socket UDP", 10, 0
e_bind  db "Error en bind()", 10, 0
e_sub   db "Error enviando SUBSCRIBE", 10, 0

fmt_sub  db "SUBSCRIBE|%s", 0
fmt_ok   db "[Sub UDP] Suscripcion enviada: %s", 10, 0
fmt_ini  db "=== Suscriptor UDP en puerto %d, tema: %s ===", 10, 0
fmt_wait db "Esperando actualizaciones...", 10, 0
fmt_msg  db "  #%d %s", 10, 0

section .bss

sockfd      resd 1
sub_buf     resb BUF_SIZE
rbuf        resb BUF_SIZE
braddr      resb 16   ; direccion del broker
laddr       resb 16   ; direccion local para bind
from_addr   resb 16   ; de donde vino el datagrama
from_len    resd 1
contador    resd 1

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

    cmp rdi, 4
    jge .ok
    lea rdi, [rel uso]
    xor eax, eax
    call printf
    mov eax, 1
    jmp .fin

.ok:
    mov rbx, rsi
    mov r12, [rbx+8]    ; IP del broker
    mov rdi, [rbx+16]
    xor eax, eax
    call atoi
    movsx r13, eax      ; puerto
    mov r14, [rbx+24]   ; tema

    mov edi, AF_INET
    mov esi, SOCK_DGRAM
    xor edx, edx
    call socket
    cmp eax, -1
    je .err_sock
    movsxd rbp, eax

    ; bind en puerto efimero para que el broker sepa donde responder
    lea rdi, [rel laddr]
    xor esi, esi
    mov edx, 16
    call memset

    mov word [rel laddr], AF_INET
    ; puerto 0 = el kernel asigna uno libre
    mov word [rel laddr+2], 0
    mov dword [rel laddr+4], 0   ; INADDR_ANY

    mov rdi, rbp
    lea rsi, [rel laddr]
    mov edx, 16
    call bind
    cmp eax, -1
    je .err_bind

    ; armar sockaddr_in del broker
    lea rdi, [rel braddr]
    xor esi, esi
    mov edx, 16
    call memset

    mov word [rel braddr], AF_INET
    mov edi, r13d
    call htons
    mov word [rel braddr+2], ax
    mov rdi, r12
    call inet_addr
    mov dword [rel braddr+4], eax

    ; enviar SUBSCRIBE|tema al broker
    lea rdi, [rel sub_buf]
    mov esi, BUF_SIZE
    lea rdx, [rel fmt_sub]
    mov rcx, r14
    xor eax, eax
    call snprintf
    movsxd r15, eax

    mov rdi, rbp
    lea rsi, [rel sub_buf]
    mov rdx, r15
    xor ecx, ecx
    lea r8, [rel braddr]
    mov r9d, 16
    call sendto
    cmp rax, -1
    je .err_sub

    lea rdi, [rel fmt_ok]
    mov rsi, r14
    xor eax, eax
    call printf

    lea rdi, [rel fmt_ini]
    mov esi, r13d
    mov rdx, r14
    xor eax, eax
    call printf

    lea rdi, [rel fmt_wait]
    xor eax, eax
    call printf

    mov dword [rel contador], 0

    ; bucle: recibir datagramas del broker
.recibir:
    mov dword [rel from_len], 16

    mov rdi, rbp
    lea rsi, [rel rbuf]
    mov edx, BUF_SIZE-1
    xor ecx, ecx
    lea r8, [rel from_addr]
    lea r9, [rel from_len]
    call recvfrom
    cmp rax, 0
    jl .recibir   ; error transitorio, ignorar

    lea rbx, [rel rbuf]
    mov byte [rbx+rax], 0

    mov eax, [rel contador]
    inc eax
    mov [rel contador], eax

    lea rdi, [rel fmt_msg]
    mov esi, eax
    lea rdx, [rel rbuf]
    xor eax, eax
    call printf

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
    mov rdi, rbp
    call close
    mov eax, 1
    jmp .fin

.err_sub:
    lea rdi, [rel e_sub]
    xor eax, eax
    call printf
    mov rdi, rbp
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
