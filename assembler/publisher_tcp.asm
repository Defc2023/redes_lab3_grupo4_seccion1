; publisher_tcp.asm
; Publicador TCP - envia 12 eventos de un partido al broker
; Uso: ./publisher_tcp <ip> <puerto> <tema>
;
; nasm -f elf64 publisher_tcp.asm -o publisher_tcp.o
; gcc -no-pie publisher_tcp.o -o publisher_tcp

bits 64
default rel

extern printf, snprintf, socket, connect, send, close, sleep
extern atoi, inet_addr, htons

AF_INET     equ 2
SOCK_STREAM equ 1
BUF_SIZE    equ 256

section .data

uso     db "Uso: ./publisher_tcp <ip> <puerto> <tema>", 10, 0
e_sock  db "Error creando socket", 10, 0
e_conn  db "Error conectando al broker", 10, 0
e_send  db "Error enviando mensaje", 10, 0

; formato del mensaje que va al broker
fmt_pub  db "PUBLISH|%s|%s", 10, 0
fmt_log  db "Enviando: %s", 0

; eventos del partido
ev1  db "Partido iniciado: Real Madrid vs Barcelona", 0
ev2  db "Gol! Real Madrid 1-0 Barcelona (min 12)", 0
ev3  db "Tarjeta amarilla para jugador #5 de Barcelona (min 18)", 0
ev4  db "Gol! Real Madrid 2-0 Barcelona (min 27)", 0
ev5  db "Gol! Barcelona 2-1 Real Madrid (min 34)", 0
ev6  db "Medio tiempo: Real Madrid 2-1 Barcelona", 0
ev7  db "Segunda mitad iniciada", 0
ev8  db "Gol! Barcelona 2-2 Real Madrid (min 58)", 0
ev9  db "Tarjeta roja para jugador #3 de Real Madrid (min 67)", 0
ev10 db "Gol! Barcelona 2-3 Real Madrid (min 74)", 0
ev11 db "Tiempo de descuento: 4 minutos", 0
ev12 db "Partido terminado: Barcelona 2-3 Real Madrid", 0

eventos:
    dq ev1, ev2, ev3, ev4, ev5, ev6
    dq ev7, ev8, ev9, ev10, ev11, ev12

NUM_EV equ 12

section .bss

sockfd   resd 1
buf      resb BUF_SIZE
svaddr   resb 16   ; sockaddr_in

section .text
global main

main:
    push rbp
    push rbx
    push r12
    push r13
    push r14
    push r15
    ; 6 pushes desde entrada (rsp%16=8), queda rsp%16=8 -> necesito alinear
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
    mov r12, [rbx+8]    ; IP
    mov rdi, [rbx+16]   ; puerto string
    xor eax, eax
    call atoi
    movsx r13, eax      ; puerto int
    mov r14, [rbx+24]   ; tema

    ; crear socket TCP
    mov edi, AF_INET
    mov esi, SOCK_STREAM
    xor edx, edx
    call socket
    cmp eax, -1
    je .err_sock
    mov [rel sockfd], eax
    movsxd rbp, eax

    ; llenar sockaddr_in
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

    ; conectar
    mov rdi, rbp
    lea rsi, [rel svaddr]
    mov edx, 16
    call connect
    cmp eax, -1
    je .err_conn

    ; enviar los 12 eventos
    xor r15d, r15d

.loop:
    cmp r15d, NUM_EV
    jge .listo

    lea rax, [rel eventos]
    mov r8, [rax + r15*8]   ; evento actual

    ; armar el mensaje PUBLISH|tema|evento
    lea rdi, [rel buf]
    mov esi, BUF_SIZE
    lea rdx, [rel fmt_pub]
    mov rcx, r14            ; tema
    ; r8 ya tiene el evento
    xor eax, eax
    call snprintf
    movsxd r13, eax

    lea rdi, [rel fmt_log]
    lea rsi, [rel buf]
    xor eax, eax
    call printf

    mov rdi, rbp
    lea rsi, [rel buf]
    mov rdx, r13
    xor ecx, ecx
    call send
    cmp rax, -1
    je .err_send

    mov edi, 2   ; esperar 2 segundos entre eventos
    call sleep

    inc r15d
    jmp .loop

.listo:
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

.err_send:
    lea rdi, [rel e_send]
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
