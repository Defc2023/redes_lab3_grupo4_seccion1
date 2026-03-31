; =============================================================================
; subscriber_udp.asm — Suscriptor UDP para el sistema de noticias deportivas
; =============================================================================
; Uso: ./subscriber_udp <ip> <puerto> <tema>
;
; Descripcion:
;   Envia una solicitud SUBSCRIBE|tema al broker por UDP,
;   luego se queda en bucle recibiendo datagramas con recvfrom().
;   Cada datagrama es independiente; no hay garantia de orden ni entrega.
;
; Protocolo (saliente): SUBSCRIBE|tema
; Protocolo (entrante): [tema] mensaje
;
; Compilacion:
;   nasm -f elf64 subscriber_udp.asm -o subscriber_udp.o
;   gcc -no-pie subscriber_udp.o -o subscriber_udp
; =============================================================================

bits 64
default rel

; ---------------------------------------------------------------------------
; Funciones de libc / POSIX
; ---------------------------------------------------------------------------
extern printf
extern snprintf
extern socket
extern bind
extern sendto
extern recvfrom
extern close
extern atoi
extern inet_addr
extern htons
extern memset

; ---------------------------------------------------------------------------
; Constantes
; ---------------------------------------------------------------------------
AF_INET    equ 2
SOCK_DGRAM equ 2

SOCKADDR_IN_SIZE equ 16
BUF_SIZE         equ 1024
INADDR_ANY       equ 0

; ---------------------------------------------------------------------------
; Datos de solo lectura
; ---------------------------------------------------------------------------
section .data

usage_msg    db  "Uso: ./subscriber_udp <ip> <puerto> <tema>", 10, 0
err_socket   db  "Error: no se pudo crear el socket UDP", 10, 0
err_bind     db  "Error: bind() fallo", 10, 0
err_sub      db  "Error al enviar SUBSCRIBE", 10, 0

fmt_start    db  "=== Suscriptor UDP en puerto %d, tema: %s ===", 10, 0
fmt_sub_sent db  "[Sub UDP] Suscripcion enviada: %s", 10, 0
fmt_waiting  db  "Esperando actualizaciones...", 10, 0
fmt_recv     db  "  #%d %s", 10, 0

fmt_sub_msg  db  "SUBSCRIBE|%s", 0   ; mensaje de suscripcion sin \n (UDP)

; ---------------------------------------------------------------------------
; Datos no inicializados
; ---------------------------------------------------------------------------
section .bss

sock_fd      resd 1
sub_buf      resb BUF_SIZE    ; buffer para mensaje SUBSCRIBE
recv_buf     resb BUF_SIZE    ; buffer para mensajes entrantes
broker_addr  resb SOCKADDR_IN_SIZE   ; direccion del broker
local_addr   resb SOCKADDR_IN_SIZE   ; direccion local para bind
sender_addr  resb SOCKADDR_IN_SIZE   ; direccion del remitente (recvfrom)
sender_len   resd 1                  ; longitud del remitente

msg_count    resd 1                  ; contador de mensajes recibidos

; ---------------------------------------------------------------------------
; Codigo
; ---------------------------------------------------------------------------
section .text
global main

main:
    push    rbp
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    ; 6 pushes → rsp ≡ 8 (mod 16) → sub rsp,8
    sub     rsp, 8

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

    mov     r12, [rbx + 8]      ; r12 = argv[1] = IP del broker
    mov     rdi, [rbx + 16]     ; argv[2] = puerto
    xor     eax, eax
    call    atoi
    movsx   r13, eax            ; r13 = puerto
    mov     r14, [rbx + 24]     ; r14 = argv[3] = tema

    ; -------------------------------------------------------
    ; 1. Crear socket UDP
    ; -------------------------------------------------------
    mov     edi, AF_INET
    mov     esi, SOCK_DGRAM
    xor     edx, edx
    call    socket
    cmp     eax, -1
    je      .err_socket
    movsxd  rbp, eax            ; rbp = sock_fd

    ; -------------------------------------------------------
    ; 2. Bind en puerto efimero local para recibir datagramas de vuelta
    ;    El broker necesita saber desde que direccion llegamos para
    ;    enviar los mensajes de vuelta al suscriptor.
    ;    bind(sockfd, {AF_INET, 0, INADDR_ANY}, 16)
    ;    Puerto 0 → el kernel asigna un puerto libre automaticamente.
    ; -------------------------------------------------------
    lea     rdi, [rel local_addr]
    xor     esi, esi
    mov     edx, SOCKADDR_IN_SIZE
    call    memset

    mov     word  [rel local_addr], AF_INET
    mov     word  [rel local_addr + 2], 0      ; puerto 0 = asignacion automatica
    mov     dword [rel local_addr + 4], INADDR_ANY

    mov     rdi, rbp
    lea     rsi, [rel local_addr]
    mov     edx, SOCKADDR_IN_SIZE
    call    bind
    cmp     eax, -1
    je      .err_bind

    ; -------------------------------------------------------
    ; 3. Construir sockaddr_in del broker
    ; -------------------------------------------------------
    lea     rdi, [rel broker_addr]
    xor     esi, esi
    mov     edx, SOCKADDR_IN_SIZE
    call    memset

    mov     word [rel broker_addr], AF_INET

    mov     edi, r13d
    call    htons
    mov     word [rel broker_addr + 2], ax

    mov     rdi, r12
    call    inet_addr
    mov     dword [rel broker_addr + 4], eax

    ; -------------------------------------------------------
    ; 4. Enviar solicitud de suscripcion SUBSCRIBE|tema
    ;    sendto(sockfd, sub_buf, len, 0, &broker_addr, sizeof(broker_addr))
    ; -------------------------------------------------------
    lea     rdi, [rel sub_buf]
    mov     esi, BUF_SIZE
    lea     rdx, [rel fmt_sub_msg]
    mov     rcx, r14
    xor     eax, eax
    call    snprintf
    movsxd  r15, eax            ; r15 = longitud del mensaje

    mov     rdi, rbp
    lea     rsi, [rel sub_buf]
    mov     rdx, r15
    xor     ecx, ecx
    lea     r8, [rel broker_addr]
    mov     r9d, SOCKADDR_IN_SIZE
    call    sendto
    cmp     rax, -1
    je      .err_sub

    ; Imprimir confirmacion
    lea     rdi, [rel fmt_sub_sent]
    mov     rsi, r14
    xor     eax, eax
    call    printf

    ; Imprimir encabezado de espera
    lea     rdi, [rel fmt_start]
    mov     esi, r13d
    mov     rdx, r14
    xor     eax, eax
    call    printf

    lea     rdi, [rel fmt_waiting]
    xor     eax, eax
    call    printf

    ; Inicializar contador de mensajes
    mov     dword [rel msg_count], 0

    ; -------------------------------------------------------
    ; 5. Bucle de recepcion de datagramas
    ;    recvfrom(sockfd, buf, size, 0, &sender_addr, &sender_len)
    ;    Cada llamada bloquea hasta recibir un datagrama.
    ; -------------------------------------------------------
.recv_loop:
    mov     dword [rel sender_len], SOCKADDR_IN_SIZE

    mov     rdi, rbp
    lea     rsi, [rel recv_buf]
    mov     edx, BUF_SIZE - 1
    xor     ecx, ecx                   ; flags = 0
    lea     r8,  [rel sender_addr]
    lea     r9,  [rel sender_len]
    call    recvfrom
    cmp     rax, 0
    jl      .recv_loop                 ; error transitorio, continuar

    ; Terminar en nulo
    lea     rbx, [rel recv_buf]
    mov     byte [rbx + rax], 0

    ; Incrementar y obtener numero de mensaje
    mov     eax, [rel msg_count]
    inc     eax
    mov     [rel msg_count], eax

    ; Imprimir: "  #N mensaje"
    lea     rdi, [rel fmt_recv]
    mov     esi, eax
    lea     rdx, [rel recv_buf]
    xor     eax, eax
    call    printf

    jmp     .recv_loop

; --- Manejadores de error ---
.err_socket:
    lea     rdi, [rel err_socket]
    xor     eax, eax
    call    printf
    mov     eax, 1
    jmp     .exit

.err_bind:
    lea     rdi, [rel err_bind]
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
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    pop     rbp
    ret
