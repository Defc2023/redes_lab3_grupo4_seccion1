; =============================================================================
; publisher_udp.asm — Publicador UDP para el sistema de noticias deportivas
; =============================================================================
; Uso: ./publisher_udp <ip> <puerto> <tema>
;
; Descripcion:
;   Envia 12 eventos deportivos al broker mediante datagramas UDP.
;   No establece conexion; cada mensaje es un datagrama independiente.
;   Protocolo: PUBLISH|tema|mensaje
;
; Compilacion:
;   nasm -f elf64 publisher_udp.asm -o publisher_udp.o
;   gcc -no-pie publisher_udp.o -o publisher_udp
; =============================================================================

bits 64
default rel

; ---------------------------------------------------------------------------
; Funciones de libc / POSIX
; ---------------------------------------------------------------------------
extern printf
extern snprintf
extern socket
extern sendto
extern close
extern sleep
extern atoi
extern inet_addr
extern htons

; ---------------------------------------------------------------------------
; Constantes
; ---------------------------------------------------------------------------
AF_INET    equ 2
SOCK_DGRAM equ 2          ; socket UDP (sin conexion)

SOCKADDR_IN_SIZE equ 16
BUF_SIZE         equ 256

; ---------------------------------------------------------------------------
; Datos de solo lectura
; ---------------------------------------------------------------------------
section .data

usage_msg   db  "Uso: ./publisher_udp <ip> <puerto> <tema>", 10, 0
err_socket  db  "Error: no se pudo crear el socket UDP", 10, 0
err_send    db  "Error al enviar datagrama", 10, 0

; Formato del mensaje PUBLISH enviado al broker
fmt_publish db  "PUBLISH|%s|%s", 0   ; sin \n (UDP no lo necesita)

; Anuncio antes de cada envio
fmt_sending db  "[UDP Pub] Enviando evento %d: %s", 10, 0

; 12 eventos deportivos
event1  db  "Partido iniciado: Real Madrid vs Barcelona", 0
event2  db  "Gol! Real Madrid 1-0 Barcelona (min 12)", 0
event3  db  "Tarjeta amarilla para jugador #5 de Barcelona (min 18)", 0
event4  db  "Gol! Real Madrid 2-0 Barcelona (min 27)", 0
event5  db  "Gol! Barcelona 2-1 Real Madrid (min 34)", 0
event6  db  "Medio tiempo: Real Madrid 2-1 Barcelona", 0
event7  db  "Segunda mitad iniciada", 0
event8  db  "Gol! Barcelona 2-2 Real Madrid (min 58)", 0
event9  db  "Tarjeta roja para jugador #3 de Real Madrid (min 67)", 0
event10 db  "Gol! Barcelona 2-3 Real Madrid (min 74)", 0
event11 db  "Tiempo de descuento: 4 minutos", 0
event12 db  "Partido terminado: Barcelona 2-3 Real Madrid", 0

; Tabla de punteros a los eventos
events_table:
    dq event1, event2, event3, event4, event5, event6
    dq event7, event8, event9, event10, event11, event12

NUM_EVENTS equ 12
SLEEP_SECS equ 2

; ---------------------------------------------------------------------------
; Datos no inicializados
; ---------------------------------------------------------------------------
section .bss

sock_fd      resd 1
msg_buf      resb BUF_SIZE
broker_addr  resb SOCKADDR_IN_SIZE

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
    ; 6 pushes → rsp ≡ 8 (mod 16) → necesita sub rsp,8
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

    mov     r12, [rbx + 8]      ; r12 = argv[1] = IP
    mov     rdi, [rbx + 16]     ; argv[2] = puerto
    xor     eax, eax
    call    atoi
    movsx   r13, eax            ; r13 = puerto
    mov     r14, [rbx + 24]     ; r14 = argv[3] = tema

    ; -------------------------------------------------------
    ; 1. Crear socket UDP
    ;    socket(AF_INET, SOCK_DGRAM, 0)
    ;    UDP no requiere conexion; cada llamada sendto es independiente.
    ; -------------------------------------------------------
    mov     edi, AF_INET
    mov     esi, SOCK_DGRAM
    xor     edx, edx
    call    socket
    cmp     eax, -1
    je      .err_socket
    movsxd  rbp, eax            ; rbp = sock_fd

    ; -------------------------------------------------------
    ; 2. Construir sockaddr_in del broker
    ; -------------------------------------------------------
    lea     rdi, [rel broker_addr]
    xor     eax, eax
    mov     ecx, SOCKADDR_IN_SIZE / 8
    rep     stosq

    mov     word [rel broker_addr], AF_INET

    mov     edi, r13d
    call    htons
    mov     word [rel broker_addr + 2], ax

    mov     rdi, r12
    call    inet_addr
    mov     dword [rel broker_addr + 4], eax

    ; -------------------------------------------------------
    ; 3. Bucle de publicacion — enviar 12 eventos
    ; -------------------------------------------------------
    xor     r15d, r15d          ; r15d = contador (0..11)

.send_loop:
    cmp     r15d, NUM_EVENTS
    jge     .done_sending

    ; Obtener puntero al evento actual
    lea     rax, [rel events_table]
    mov     r8, [rax + r15 * 8]    ; r8 = eventos_tabla[r15]

    ; Construir "PUBLISH|tema|evento" en msg_buf
    ; snprintf(msg_buf, BUF_SIZE, fmt_publish, tema, evento)
    lea     rdi, [rel msg_buf]
    mov     esi, BUF_SIZE
    lea     rdx, [rel fmt_publish]
    mov     rcx, r14               ; tema
    ; r8 ya tiene el evento
    xor     eax, eax
    call    snprintf
    movsxd  r13, eax               ; r13 = longitud del mensaje

    ; Anunciar el envio
    lea     rdi, [rel fmt_sending]
    mov     esi, r15d
    inc     esi                    ; mostrar 1..12
    lea     rdx, [rel msg_buf]
    xor     eax, eax
    call    printf

    ; sendto(sockfd, msg_buf, longitud, 0, &broker_addr, sizeof(broker_addr))
    ; UDP: cada llamada envia un datagrama independiente.
    mov     rdi, rbp               ; sockfd
    lea     rsi, [rel msg_buf]     ; buffer
    mov     rdx, r13               ; longitud
    xor     ecx, ecx               ; flags = 0
    lea     r8, [rel broker_addr]  ; direccion destino
    mov     r9d, SOCKADDR_IN_SIZE  ; tamano de la direccion
    call    sendto
    cmp     rax, -1
    je      .err_send

    ; Pausa entre eventos
    mov     edi, SLEEP_SECS
    call    sleep

    inc     r15d
    jmp     .send_loop

.done_sending:
    mov     rdi, rbp
    call    close
    xor     eax, eax
    jmp     .exit

.err_socket:
    lea     rdi, [rel err_socket]
    xor     eax, eax
    call    printf
    mov     eax, 1
    jmp     .exit

.err_send:
    lea     rdi, [rel err_send]
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
