; =============================================================================
; publisher_tcp.asm — Publicador TCP para el sistema de noticias deportivas
; =============================================================================
; Uso: ./publisher_tcp <ip> <puerto> <tema>
;
; Descripcion:
;   Se conecta al broker TCP y publica 12 eventos de un partido de futbol
;   usando el protocolo:  PUBLISH|tema|mensaje\n
;
; Compilacion:
;   nasm -f elf64 publisher_tcp.asm -o publisher_tcp.o
;   gcc -no-pie publisher_tcp.o -o publisher_tcp
; =============================================================================

bits 64
default rel

; ---------------------------------------------------------------------------
; Funciones de libc / POSIX que usamos
; ---------------------------------------------------------------------------
extern printf
extern fprintf
extern snprintf
extern socket
extern connect
extern send
extern close
extern sleep
extern atoi
extern inet_addr
extern htons
extern stderr

; ---------------------------------------------------------------------------
; Constantes
; ---------------------------------------------------------------------------
AF_INET      equ 2
SOCK_STREAM  equ 1
IPPROTO_TCP  equ 6

SOCKADDR_IN_SIZE equ 16   ; sizeof(struct sockaddr_in)
BUF_SIZE         equ 256

; ---------------------------------------------------------------------------
; Datos de solo lectura
; ---------------------------------------------------------------------------
section .data

; Mensajes de uso / error
usage_msg   db  "Uso: ./publisher_tcp <ip> <puerto> <tema>", 10, 0
err_socket  db  "Error: no se pudo crear el socket TCP", 10, 0
err_connect db  "Error: no se pudo conectar al broker", 10, 0
err_send    db  "Error al enviar mensaje", 10, 0

; Formato del mensaje PUBLISH enviado al broker
fmt_publish db  "PUBLISH|%s|%s", 10, 0   ; PUBLISH|tema|mensaje\n

; Anuncio impreso antes de cada envio
fmt_sending db  "Enviando: %s", 0         ; el mensaje ya contiene \n

; 12 eventos de un partido de futbol
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

; Tabla de punteros a los 12 eventos (facilita el bucle)
events_table:
    dq event1, event2, event3, event4, event5, event6
    dq event7, event8, event9, event10, event11, event12

NUM_EVENTS equ 12

SLEEP_SECS equ 2   ; segundos entre eventos

; ---------------------------------------------------------------------------
; Datos no inicializados
; ---------------------------------------------------------------------------
section .bss

sock_fd     resd 1          ; descriptor del socket TCP
msg_buf     resb BUF_SIZE   ; buffer para el mensaje PUBLISH formateado

; Estructura sockaddr_in (16 bytes):
;   [0]  sin_family  2 bytes  (AF_INET = 2)
;   [2]  sin_port    2 bytes  (orden de red)
;   [4]  sin_addr    4 bytes  (orden de red)
;   [8]  sin_zero    8 bytes  (relleno, ceros)
server_addr resb SOCKADDR_IN_SIZE

; ---------------------------------------------------------------------------
; Codigo
; ---------------------------------------------------------------------------
section .text
global main

; ============================================================
; main(int argc, char **argv)
;   argc → rdi
;   argv → rsi
; ============================================================
main:
    ; Prologo — guardar registros callee-saved que usamos
    push    rbp
    push    rbx
    push    r12
    push    r13
    push    r14
    ; 5 pushes + dir. de retorno (1) = 6 x 8 = 48 bytes desde la entrada alineada.
    ; rsp debe estar alineado a 16 antes de cualquier CALL.
    ; Entrada: rsp ≡ 8 (mod 16) tras el push de dir. de retorno.
    ; Tras 5 pushes: rsp ≡ 8 + 5*8 = 48 ≡ 0 (mod 16). Correcto.
    sub     rsp, 8          ; mantener rsp alineado a 16 para las llamadas

    ; ---- Verificar cantidad de argumentos ----
    cmp     rdi, 4
    jge     .args_ok

    ; No hay suficientes args → imprimir uso y salir
    lea     rdi, [rel usage_msg]
    xor     eax, eax
    call    printf
    mov     eax, 1
    jmp     .exit

.args_ok:
    ; Guardar argv en rbx (callee-saved); argc ya no se necesita
    mov     rbx, rsi        ; rbx = argv

    ; argv[1] = cadena IP
    mov     r12, [rbx + 8]  ; r12 = argv[1]  (IP)
    ; argv[2] = cadena de puerto → convertir a entero
    mov     rdi, [rbx + 16] ; argv[2]
    xor     eax, eax
    call    atoi
    movsx   r13, eax        ; r13 = puerto (int)
    ; argv[3] = cadena del tema
    mov     r14, [rbx + 24] ; r14 = argv[3]  (tema)

    ; -------------------------------------------------------
    ; 1. Crear socket TCP
    ;    socket(AF_INET, SOCK_STREAM, 0)
    ;    → devuelve descriptor de archivo o -1 en error
    ; -------------------------------------------------------
    mov     edi, AF_INET    ; familia de direcciones: IPv4
    mov     esi, SOCK_STREAM; tipo: fiable, orientado a conexion
    xor     edx, edx        ; protocolo: 0 (el kernel elige TCP)
    call    socket
    cmp     eax, -1
    je      .err_socket

    ; Guardar fd para uso posterior
    mov     [rel sock_fd], eax
    movsxd  rbp, eax        ; rbp = sock_fd (64 bits para argumentos de syscall)

    ; -------------------------------------------------------
    ; 2. Rellenar sockaddr_in del servidor
    ;    sin_family = AF_INET
    ;    sin_port   = htons(puerto)
    ;    sin_addr   = inet_addr(cadena_ip)
    ; -------------------------------------------------------

    ; Poner la estructura a cero primero
    lea     rdi, [rel server_addr]
    xor     eax, eax
    mov     ecx, SOCKADDR_IN_SIZE / 8
    rep     stosq

    ; sin_family = AF_INET (2), almacenado como little-endian de 16 bits
    mov     word [rel server_addr], AF_INET

    ; htons(puerto) — convierte el puerto a orden de red (big-endian)
    mov     edi, r13d
    call    htons
    mov     word [rel server_addr + 2], ax   ; sin_port

    ; inet_addr(cadena_ip) — convierte decimal punteada a 32 bits en orden de red
    mov     rdi, r12
    call    inet_addr
    mov     dword [rel server_addr + 4], eax ; sin_addr

    ; -------------------------------------------------------
    ; 3. Conectar al broker
    ;    connect(sockfd, (struct sockaddr*)&server_addr, sizeof(server_addr))
    ;    Realiza el three-way handshake TCP con el broker.
    ; -------------------------------------------------------
    mov     rdi, rbp                    ; sockfd
    lea     rsi, [rel server_addr]      ; puntero a sockaddr_in
    mov     edx, SOCKADDR_IN_SIZE       ; longitud de la direccion
    call    connect
    cmp     eax, -1
    je      .err_connect

    ; -------------------------------------------------------
    ; 4. Bucle de publicacion — enviar 12 eventos con 2 segundos de pausa
    ; -------------------------------------------------------
    xor     r15d, r15d       ; r15 = contador del bucle (0..11)

.send_loop:
    cmp     r15d, NUM_EVENTS
    jge     .done_sending

    ; Obtener puntero al evento actual
    lea     rax, [rel events_table]
    mov     r8, [rax + r15 * 8]     ; r8 = events_table[r15] (evento)

    ; Construir "PUBLISH|tema|evento\n" en msg_buf
    ; snprintf(buf, size, fmt, tema, evento)
    ;   rdi = buf, rsi = size, rdx = fmt, rcx = tema, r8 = evento
    lea     rdi, [rel msg_buf]      ; buffer destino
    mov     esi, BUF_SIZE           ; maximo de bytes
    lea     rdx, [rel fmt_publish]  ; cadena de formato
    mov     rcx, r14                ; rcx = tema
    ; r8 ya tiene el puntero al evento
    xor     eax, eax                ; sin argumentos XMM (variadic)
    call    snprintf
    ; rax = numero de caracteres escritos (sin nulo)

    ; Imprimir lo que vamos a enviar
    lea     rdi, [rel fmt_sending]
    lea     rsi, [rel msg_buf]
    xor     eax, eax
    call    printf

    ; send(sockfd, msg_buf, longitud_msg, 0)
    ; Envia el mensaje formateado por la conexion TCP.
    mov     rdi, rbp                ; sockfd
    lea     rsi, [rel msg_buf]      ; buffer a enviar
    movsxd  rdx, eax                ; longitud devuelta por snprintf
    xor     ecx, ecx                ; flags = 0
    call    send
    cmp     rax, -1
    je      .err_send

    ; sleep(2) — esperar antes del siguiente evento
    mov     edi, SLEEP_SECS
    call    sleep

    inc     r15d
    jmp     .send_loop

.done_sending:
    ; -------------------------------------------------------
    ; 5. Cerrar socket
    ;    close(sockfd) — cierre ordenado TCP (handshake FIN)
    ; -------------------------------------------------------
    mov     rdi, rbp
    call    close

    xor     eax, eax        ; retornar 0
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
    ; Cerrar el socket creado antes del fallo
    mov     rdi, rbp
    call    close
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
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    pop     rbp
    ret
