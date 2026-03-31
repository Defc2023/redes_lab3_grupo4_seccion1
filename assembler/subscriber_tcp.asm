; subscriber_tcp.asm
; Suscriptor TCP - se conecta al broker y recibe mensajes del tema
; Uso: ./subscriber_tcp <ip> <puerto> <tema>
;
; nasm -f elf64 subscriber_tcp.asm -o subscriber_tcp.o
; gcc -no-pie subscriber_tcp.o -o subscriber_tcp

bits 64
default rel

extern printf, snprintf, socket, connect, send, recv, close
extern atoi, inet_addr, htons, write

AF_INET     equ 2
SOCK_STREAM equ 1
BUF_SIZE    equ 512

section .data

uso     db "Uso: ./subscriber_tcp <ip> <puerto> <tema>", 10, 0
e_sock  db "Error creando socket", 10, 0
e_conn  db "Error conectando al broker", 10, 0
e_sub   db "Error enviando SUBSCRIBE", 10, 0

; mensaje de suscripcion que se manda una sola vez
fmt_sub db "SUBSCRIBE|%s", 10, 0

section .bss

sockfd   resd 1
sub_buf  resb BUF_SIZE
rbuf     resb BUF_SIZE
svaddr   resb 16

section .text
global main

main:
    push rbp
    push rbx
    push r12
    push r13
    push r14
    sub rsp, 8   ; 5 pushes + ret = rsp%16=0, sub 8 para alinear antes de calls

    cmp rdi, 4
    jge .ok
    lea rdi, [rel uso]
    xor eax, eax
    call printf
    mov eax, 1
    jmp .fin

.ok:
    mov rbx, rsi
    mov r12, [rbx+8]    ; IP
    mov rdi, [rbx+16]
    xor eax, eax
    call atoi
    movsx r13, eax      ; puerto
    mov r14, [rbx+24]   ; tema

    mov edi, AF_INET
    mov esi, SOCK_STREAM
    xor edx, edx
    call socket
    cmp eax, -1
    je .err_sock
    mov [rel sockfd], eax
    movsxd rbp, eax

    ; preparar sockaddr_in
    lea rdi, [rel svaddr]
    xor eax, eax
    mov ecx, 2
    rep stosq

    mov word [rel svaddr], AF_INET
    mov edi, r13d
    call htons
    mov word [rel svaddr+2], ax
    mov rdi, r12
    call inet_addr
    mov dword [rel svaddr+4], eax

    mov rdi, rbp
    lea rsi, [rel svaddr]
    mov edx, 16
    call connect
    cmp eax, -1
    je .err_conn

    ; mandar SUBSCRIBE|tema al broker (solo una vez)
    lea rdi, [rel sub_buf]
    mov esi, BUF_SIZE
    lea rdx, [rel fmt_sub]
    mov rcx, r14
    xor eax, eax
    call snprintf

    mov rdi, rbp
    lea rsi, [rel sub_buf]
    movsxd rdx, eax
    xor ecx, ecx
    call send
    cmp rax, -1
    je .err_sub

    ; recibir mensajes indefinidamente
.recibir:
    mov rdi, rbp
    lea rsi, [rel rbuf]
    mov edx, BUF_SIZE-1
    xor ecx, ecx
    call recv
    cmp rax, 0
    jle .desconectado

    ; terminar string y escribir en stdout
    lea rbx, [rel rbuf]
    mov byte [rbx+rax], 0
    mov rdi, 1          ; stdout
    lea rsi, [rel rbuf]
    mov rdx, rax
    call write

    jmp .recibir

.desconectado:
    ; el broker cerro la conexion
    lea rdi, [rel rbuf]
    mov byte [rdi],    'B'
    mov byte [rdi+1],  'r'
    mov byte [rdi+2],  'o'
    mov byte [rdi+3],  'k'
    mov byte [rdi+4],  'e'
    mov byte [rdi+5],  'r'
    mov byte [rdi+6],  ' '
    mov byte [rdi+7],  'd'
    mov byte [rdi+8],  'e'
    mov byte [rdi+9],  's'
    mov byte [rdi+10], 'c'
    mov byte [rdi+11], 'o'
    mov byte [rdi+12], 'n'
    mov byte [rdi+13], 'e'
    mov byte [rdi+14], 'c'
    mov byte [rdi+15], 't'
    mov byte [rdi+16], 'a'
    mov byte [rdi+17], 'd'
    mov byte [rdi+18], 'o'
    mov byte [rdi+19], '.'
    mov byte [rdi+20], 10
    mov byte [rdi+21], 0
    xor eax, eax
    call printf
    mov rdi, rbp
    call close
    xor eax, eax
    jmp .fin

.err_sock:
    lea rdi, [rel e_sock]
    xor eax, eax
    call printf
    mov eax, 1
    jmp .fin

.err_conn:
    lea rdi, [rel e_conn]
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
    pop r14
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret
