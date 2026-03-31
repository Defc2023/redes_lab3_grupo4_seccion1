; =============================================================================
; subscriber_tcp.asm — Suscriptor TCP para el sistema de noticias deportivas
; =============================================================================
; Uso: ./subscriber_tcp <ip> <puerto> <tema>
;
; Descripcion:
;   Se conecta al broker TCP, envia un mensaje SUBSCRIBE|tema\n, luego
;   queda en bucle llamando recv() e imprimiendo lo que el broker reenvie.
;
; Protocolo (saliente):  SUBSCRIBE|tema\n
; Protocolo (entrante):  [tema] mensaje\n
;
; Compilacion:
;   nasm -f elf64 subscriber_tcp.asm -o subscriber_tcp.o
;   gcc -no-pie subscriber_tcp.o -o subscriber_tcp
; =============================================================================

bits 64
default rel

; ---------------------------------------------------------------------------
; Funciones de libc / POSIX
; ---------------------------------------------------------------------------
extern printf
extern snprintf
extern socket
extern connect
extern send
extern recv
extern close
extern atoi
extern inet_addr
extern htons
extern write

; ---------------------------------------------------------------------------
; Constantes
; ---------------------------------------------------------------------------
AF_INET      equ 2
SOCK_STREAM  equ 1

SOCKADDR_IN_SIZE equ 16
BUF_SIZE         equ 512
STDOUT_FD        equ 1

; ---------------------------------------------------------------------------
; Datos de solo lectura
; ---------------------------------------------------------------------------
section .data

usage_msg   db  "Uso: ./subscriber_tcp <ip> <puerto> <tema>", 10, 0
err_socket  db  "Error: no se pudo crear el socket TCP", 10, 0
err_connect db  "Error: no se pudo conectar al broker", 10, 0
err_sub     db  "Error al enviar SUBSCRIBE", 10, 0

; Formato del mensaje de suscripcion enviado al broker (una sola vez)
fmt_sub     db  "SUBSCRIBE|%s", 10, 0   ; SUBSCRIBE|tema\n

; Formato del prefijo impreso antes de cada mensaje entrante
fmt_recv    db  "Recibido: %s", 0        ; el broker ya incluye \n

; ---------------------------------------------------------------------------
; Datos no inicializados
; ---------------------------------------------------------------------------
section .bss

sock_fd     resd 1
sub_buf     resb BUF_SIZE    ; buffer para el mensaje SUBSCRIBE
recv_buf    resb BUF_SIZE    ; buffer para los datos entrantes
server_addr resb SOCKADDR_IN_SIZE

; ---------------------------------------------------------------------------
; Codigo
; ---------------------------------------------------------------------------
section .text
global main

main:
    ; Prologo
    push    rbp
    push    rbx
    push    r12
    push    r13
    push    r14
    ; 5 pushes → rsp ≡ 0 (mod 16). Se necesita sub adicional.
    sub     rsp, 8      ; mantener alineacion a 16 bytes

    ; ---- Verificar argumentos ----
    cmp     rdi, 4
    jge     .args_ok
    lea     rdi, [rel usage_msg]
    xor     eax, eax
    call    printf
    mov     eax, 1
    jmp     .exit

.args_ok:
    mov     rbx, rsi            ; rbx = argv

    mov     r12, [rbx + 8]      ; r12 = argv[1] = cadena IP
    mov     rdi, [rbx + 16]     ; argv[2] = cadena de puerto
    xor     eax, eax
    call    atoi
    movsx   r13, eax            ; r13 = puerto (int)
    mov     r14, [rbx + 24]     ; r14 = argv[3] = tema

    ; -------------------------------------------------------
    ; 1. Crear socket TCP
    ;    socket(AF_INET, SOCK_STREAM, 0)
    ;    Abre un flujo de bytes fiable, ordenado y full-duplex.
    ; -------------------------------------------------------
    mov     edi, AF_INET
    mov     esi, SOCK_STREAM
    xor     edx, edx
    call    socket
    cmp     eax, -1
    je      .err_socket
    mov     [rel sock_fd], eax
    movsxd  rbp, eax            ; rbp = fd (64 bits)

    ; -------------------------------------------------------
    ; 2. Construir sockaddr_in para el broker
    ; -------------------------------------------------------
    lea     rdi, [rel server_addr]
    xor     eax, eax
    mov     ecx, SOCKADDR_IN_SIZE / 8
    rep     stosq

    mov     word  [rel server_addr], AF_INET

    mov     edi, r13d
    call    htons
    mov     word [rel server_addr + 2], ax

    mov     rdi, r12
    call    inet_addr
    mov     dword [rel server_addr + 4], eax

    ; -------------------------------------------------------
    ; 3. Conectar al broker
    ;    connect(sockfd, addr, addrlen)
    ;    Realiza el handshake TCP; tras esto el flujo esta abierto.
    ; -------------------------------------------------------
    mov     rdi, rbp
    lea     rsi, [rel server_addr]
    mov     edx, SOCKADDR_IN_SIZE
    call    connect
    cmp     eax, -1
    je      .err_connect

    ; -------------------------------------------------------
    ; 4. Enviar mensaje SUBSCRIBE (una sola vez)
    ;    Formato: "SUBSCRIBE|tema\n"
    ;    El broker registrara nuestro fd para este tema.
    ; -------------------------------------------------------
    lea     rdi, [rel sub_buf]
    mov     esi, BUF_SIZE
    lea     rdx, [rel fmt_sub]
    mov     rcx, r14            ; tema
    xor     eax, eax
    call    snprintf
    ; rax = longitud de la cadena de suscripcion

    ; send(sockfd, sub_buf, longitud, 0)
    mov     rdi, rbp
    lea     rsi, [rel sub_buf]
    movsxd  rdx, eax
    xor     ecx, ecx
    call    send
    cmp     rax, -1
    je      .err_sub

    ; -------------------------------------------------------
    ; 5. Bucle de recepcion — bloquear en recv() e imprimir todo
    ;    recv(sockfd, buf, BUF_SIZE-1, 0)
    ;    Retorna bytes recibidos; 0 significa que el broker cerro.
    ; -------------------------------------------------------
.recv_loop:
    mov     rdi, rbp
    lea     rsi, [rel recv_buf]
    mov     edx, BUF_SIZE - 1
    xor     ecx, ecx            ; flags = 0
    call    recv
    cmp     rax, 0
    jle     .broker_closed      ; 0=cierre limpio, <0=error

    ; Terminar en nulo para poder usar funciones de cadena
    lea     rbx, [rel recv_buf]
    mov     byte [rbx + rax], 0

    ; Imprimir datos recibidos en stdout
    ; write(STDOUT_FD, recv_buf, nbytes) — raw, preserva el formato del broker
    mov     rdi, STDOUT_FD
    lea     rsi, [rel recv_buf]
    mov     rdx, rax
    call    write

    jmp     .recv_loop

.broker_closed:
    lea     rdi, [rel recv_buf] ; reutilizar buffer para el mensaje
    ; Imprimir aviso de desconexion inline
    mov     byte [rdi],    'B'
    mov     byte [rdi+1],  'r'
    mov     byte [rdi+2],  'o'
    mov     byte [rdi+3],  'k'
    mov     byte [rdi+4],  'e'
    mov     byte [rdi+5],  'r'
    mov     byte [rdi+6],  ' '
    mov     byte [rdi+7],  'd'
    mov     byte [rdi+8],  'e'
    mov     byte [rdi+9],  's'
    mov     byte [rdi+10], 'c'
    mov     byte [rdi+11], 'o'
    mov     byte [rdi+12], 'n'
    mov     byte [rdi+13], 'e'
    mov     byte [rdi+14], 'c'
    mov     byte [rdi+15], 't'
    mov     byte [rdi+16], 'a'
    mov     byte [rdi+17], 'd'
    mov     byte [rdi+18], 'o'
    mov     byte [rdi+19], '.'
    mov     byte [rdi+20], 10
    mov     byte [rdi+21], 0
    xor     eax, eax
    call    printf

    ; close(sockfd)
    mov     rdi, rbp
    call    close
    xor     eax, eax
    jmp     .exit

; --- Manejadores de error ---
.err_socket:
    lea     rdi, [rel err_socket]
    xor     eax, eax
    call    printf
    mov     eax, 1
    jmp     .exit

.err_connect:
    lea     rdi, [rel err_connect]
    xor     eax, eax
    call    printf
    mov     rdi, rbp
    call    close
    mov     eax, 1
    jmp     .exit

.err_sub:
    lea     rdi, [rel err_sub]
    xor     eax, eax
    call    printf
    mov     rdi, rbp
    call    close
    mov     eax, 1

.exit:
    add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    pop     rbp
    ret
