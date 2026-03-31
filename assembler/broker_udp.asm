; =============================================================================
; broker_udp.asm — Broker UDP para el sistema de noticias deportivas
; =============================================================================
; Uso: ./broker_udp <puerto>
;
; Descripcion:
;   Escucha en un puerto UDP. Procesa dos tipos de mensajes:
;     SUBSCRIBE|tema   → guarda la direccion del remitente como suscriptor
;     PUBLISH|tema|msg → reenviar msg a todos los suscriptores del tema
;
;   A diferencia del broker TCP, no hay conexiones persistentes.
;   La identidad del suscriptor es su sockaddr_in (IP + puerto efimero).
;
; Compilacion:
;   nasm -f elf64 broker_udp.asm -o broker_udp.o
;   gcc -no-pie broker_udp.o -o broker_udp
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
extern recvfrom
extern sendto
extern close
extern atoi
extern htons
extern memset
extern memcmp
extern strncmp
extern strncpy
extern strlen

; ---------------------------------------------------------------------------
; Constantes
; ---------------------------------------------------------------------------
AF_INET    equ 2
SOCK_DGRAM equ 2
INADDR_ANY equ 0

SOCKADDR_IN_SIZE equ 16
BUF_SIZE         equ 1024

; ---------------------------------------------------------------------------
; Estructura de la tabla de temas UDP (UdpTopicEntry):
;   +0    nombre del tema     128 bytes
;   +128  array de sockaddr_in de suscriptores  50 * 16 = 800 bytes
;   +928  num_subs            4 bytes
;   +932  relleno             4 bytes
;   Total: 936 bytes
; ---------------------------------------------------------------------------
TOPIC_NAME_LEN     equ 128
MAX_SUBS_PER_TOPIC equ 50
UDP_TOPIC_ENTRY_SIZE equ 936
MAX_TOPICS           equ 20

; ---------------------------------------------------------------------------
; Datos de solo lectura
; ---------------------------------------------------------------------------
section .data

usage_msg    db  "Uso: ./broker_udp <puerto>", 10, 0
err_socket   db  "Error: socket()", 10, 0
err_bind     db  "Error: bind()", 10, 0

msg_start    db  "Broker UDP escuchando en puerto %d...", 10, 0
msg_sub      db  "[Broker UDP] SUBSCRIBE tema='%s'", 10, 0
msg_pub      db  "[Broker UDP] PUBLISH tema='%s' msg='%s'", 10, 0
msg_fwd      db  "[Broker UDP] Reenviando a suscriptor #%d", 10, 0
msg_unknown  db  "[Broker UDP] Mensaje desconocido", 10, 0

; Formato del mensaje reenviado al suscriptor
fmt_forward  db  "[%s] %s", 0    ; sin \n — el broker UDP no agrega salto de linea

; ---------------------------------------------------------------------------
; Datos no inicializados
; ---------------------------------------------------------------------------
section .bss

sock_fd      resd 1
port_num     resd 1

server_addr  resb SOCKADDR_IN_SIZE   ; direccion local del broker
sender_addr  resb SOCKADDR_IN_SIZE   ; direccion del remitente actual
sender_len   resd 1

recv_buf     resb BUF_SIZE           ; buffer de recepcion
fwd_buf      resb BUF_SIZE           ; buffer para mensaje reenviado

; Tabla de temas UDP
topic_table  resb MAX_TOPICS * UDP_TOPIC_ENTRY_SIZE
num_topics   resd 1

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
    cmp     rdi, 2
    jge     .args_ok
    lea     rdi, [rel usage_msg]
    xor     eax, eax
    call    printf
    mov     eax, 1
    jmp     .exit

.args_ok:
    mov     rbx, rsi
    mov     rdi, [rbx + 8]      ; argv[1] = puerto
    xor     eax, eax
    call    atoi
    mov     [rel port_num], eax
    mov     r12d, eax           ; r12d = puerto

    ; Inicializar tabla de temas a cero
    lea     rdi, [rel topic_table]
    xor     esi, esi
    mov     edx, MAX_TOPICS * UDP_TOPIC_ENTRY_SIZE
    call    memset

    ; -------------------------------------------------------
    ; 1. Crear socket UDP
    ; -------------------------------------------------------
    mov     edi, AF_INET
    mov     esi, SOCK_DGRAM
    xor     edx, edx
    call    socket
    cmp     eax, -1
    je      .err_socket
    movsxd  r13, eax            ; r13 = sock_fd
    mov     [rel sock_fd], eax  ; guardar en memoria para udp_publish

    ; -------------------------------------------------------
    ; 2. Bind al puerto local
    ; -------------------------------------------------------
    lea     rdi, [rel server_addr]
    xor     esi, esi
    mov     edx, SOCKADDR_IN_SIZE
    call    memset

    mov     word  [rel server_addr], AF_INET
    mov     dword [rel server_addr + 4], INADDR_ANY

    mov     edi, r12d
    call    htons
    mov     word [rel server_addr + 2], ax

    mov     rdi, r13
    lea     rsi, [rel server_addr]
    mov     edx, SOCKADDR_IN_SIZE
    call    bind
    cmp     eax, -1
    je      .err_bind

    ; Anunciar que el broker esta listo
    lea     rdi, [rel msg_start]
    mov     esi, r12d
    xor     eax, eax
    call    printf

    ; -------------------------------------------------------
    ; 3. Bucle principal: recibir datagramas y procesarlos
    ; -------------------------------------------------------
.recv_loop:
    mov     dword [rel sender_len], SOCKADDR_IN_SIZE

    ; recvfrom(sockfd, recv_buf, BUF_SIZE-1, 0, &sender_addr, &sender_len)
    mov     rdi, r13
    lea     rsi, [rel recv_buf]
    mov     edx, BUF_SIZE - 1
    xor     ecx, ecx
    lea     r8,  [rel sender_addr]
    lea     r9,  [rel sender_len]
    call    recvfrom
    cmp     rax, 0
    jl      .recv_loop          ; error transitorio

    ; Terminar en nulo
    lea     rbx, [rel recv_buf]
    mov     byte [rbx + rax], 0

    ; Procesar el mensaje
    lea     rdi, [rel recv_buf]
    call    process_udp_message

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
    mov     rdi, r13
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

; =============================================================================
; process_udp_message(rdi=msg_ptr)
;   Analiza el mensaje y llama a udp_subscribe o udp_publish.
; =============================================================================
process_udp_message:
    push    rbp
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 8

    mov     r12, rdi            ; r12 = puntero al mensaje

    ; ¿Comienza con "SUBSCRIBE|"?
    mov     rdi, r12
    lea     rsi, [rel .str_subscribe]
    mov     edx, 10
    call    strncmp
    test    eax, eax
    jnz     .check_pub

    ; Extraer tema
    mov     r13, r12
    add     r13, 10             ; r13 = inicio del tema

    ; Eliminar \n si existe
    mov     rdi, r13
    call    strlen
    test    rax, rax
    jz      .do_sub
    lea     rbx, [r13 + rax - 1]
    cmp     byte [rbx], 10
    jne     .do_sub
    mov     byte [rbx], 0

.do_sub:
    ; Imprimir log
    lea     rdi, [rel msg_sub]
    mov     rsi, r13
    xor     eax, eax
    call    printf

    ; Registrar suscripcion con la direccion del remitente
    mov     rdi, r13
    lea     rsi, [rel sender_addr]
    call    udp_subscribe
    jmp     .pum_done

.check_pub:
    ; ¿Comienza con "PUBLISH|"?
    mov     rdi, r12
    lea     rsi, [rel .str_publish]
    mov     edx, 8
    call    strncmp
    test    eax, eax
    jnz     .unknown

    ; Extraer tema
    mov     r13, r12
    add     r13, 8              ; r13 = inicio del tema

    ; Buscar el segundo '|' para separar tema de mensaje
    mov     rbx, r13
.find_pipe:
    cmp     byte [rbx], 0
    je      .unknown
    cmp     byte [rbx], '|'
    je      .pipe_found
    inc     rbx
    jmp     .find_pipe

.pipe_found:
    mov     byte [rbx], 0      ; terminar tema
    inc     rbx                ; rbx = inicio del mensaje

    ; Eliminar \n final del mensaje si existe
    mov     rdi, rbx
    call    strlen
    test    rax, rax
    jz      .do_pub
    lea     r14, [rbx + rax - 1]
    cmp     byte [r14], 10
    jne     .do_pub
    mov     byte [r14], 0

.do_pub:
    ; Imprimir log
    lea     rdi, [rel msg_pub]
    mov     rsi, r13
    mov     rdx, rbx
    xor     eax, eax
    call    printf

    ; Publicar el mensaje a los suscriptores del tema
    mov     rdi, r13            ; tema
    mov     rsi, rbx            ; mensaje
    call    udp_publish
    jmp     .pum_done

.unknown:
    lea     rdi, [rel msg_unknown]
    xor     eax, eax
    call    printf

.pum_done:
    add     rsp, 8
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    pop     rbp
    ret

.str_subscribe: db "SUBSCRIBE|", 0
.str_publish:   db "PUBLISH|", 0

; =============================================================================
; udp_find_or_create_topic(rdi=topic_ptr) → rax = indice o -1
; =============================================================================
udp_find_or_create_topic:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8

    mov     r12, rdi            ; r12 = nombre del tema
    xor     r13d, r13d          ; r13d = iterador
    mov     r14d, -1            ; r14d = primer slot libre

.ufoct_loop:
    cmp     r13d, MAX_TOPICS
    jge     .ufoct_create

    ; Calcular puntero a entry[r13]
    lea     rbx, [rel topic_table]
    imul    rax, r13, UDP_TOPIC_ENTRY_SIZE
    add     rbx, rax

    ; ¿Slot vacio?
    cmp     byte [rbx], 0
    jne     .ufoct_check

    cmp     r14d, -1
    jne     .ufoct_next
    mov     r14d, r13d
    jmp     .ufoct_next

.ufoct_check:
    mov     rdi, rbx
    mov     rsi, r12
    mov     edx, TOPIC_NAME_LEN
    call    strncmp
    test    eax, eax
    jnz     .ufoct_next

    mov     eax, r13d           ; encontrado
    jmp     .ufoct_ret

.ufoct_next:
    inc     r13d
    jmp     .ufoct_loop

.ufoct_create:
    cmp     r14d, -1
    je      .ufoct_fail

    ; Crear en el slot libre
    lea     rbx, [rel topic_table]
    imul    rax, r14, UDP_TOPIC_ENTRY_SIZE
    add     rbx, rax

    mov     rdi, rbx
    mov     rsi, r12
    mov     edx, TOPIC_NAME_LEN - 1
    call    strncpy
    mov     byte [rbx + TOPIC_NAME_LEN - 1], 0
    mov     dword [rbx + 928], 0    ; num_subs = 0

    mov     eax, [rel num_topics]
    inc     eax
    mov     [rel num_topics], eax

    mov     eax, r14d
    jmp     .ufoct_ret

.ufoct_fail:
    mov     eax, -1

.ufoct_ret:
    add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; =============================================================================
; udp_subscribe(rdi=topic_ptr, rsi=sender_sockaddr_ptr)
;   Registra la direccion del remitente como suscriptor del tema.
; =============================================================================
udp_subscribe:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8

    mov     r12, rdi            ; r12 = nombre del tema
    mov     r13, rsi            ; r13 = puntero a sockaddr_in del remitente

    ; Encontrar o crear el tema
    mov     rdi, r12
    call    udp_find_or_create_topic
    cmp     eax, -1
    je      .usub_done

    movsxd  rbx, eax

    ; Calcular puntero a la entrada
    lea     r14, [rel topic_table]
    imul    rax, rbx, UDP_TOPIC_ENTRY_SIZE
    add     r14, rax            ; r14 = &topic_table[idx]

    ; Obtener num_subs
    mov     ecx, [r14 + 928]
    cmp     ecx, MAX_SUBS_PER_TOPIC
    jge     .usub_done

    ; Verificar si ya esta registrado (comparar sockaddr_in completo)
    xor     r8d, r8d
.check_dup:
    cmp     r8d, ecx
    jge     .add_sub_udp

    ; Calcular puntero al sockaddr_in en la tabla
    lea     rax, [r14 + 128]
    imul    rdx, r8, SOCKADDR_IN_SIZE
    add     rax, rdx

    mov     rdi, rax
    mov     rsi, r13
    mov     edx, SOCKADDR_IN_SIZE
    call    memcmp
    test    eax, eax
    jz      .usub_done          ; ya registrado

    inc     r8d
    mov     ecx, [r14 + 928]
    jmp     .check_dup

.add_sub_udp:
    ; Copiar sockaddr_in al array (16 bytes = 2 qwords)
    ; Calcular destino: &topic_table[idx].subs[num_subs]
    lea     rbx, [r14 + 128]
    imul    rax, rcx, SOCKADDR_IN_SIZE
    add     rbx, rax                ; rbx = destino

    ; Copiar 16 bytes desde sender_addr (r13) a destino (rbx)
    mov     rax, [r13]
    mov     [rbx], rax
    mov     rax, [r13 + 8]
    mov     [rbx + 8], rax

    mov     ecx, [r14 + 928]
    inc     ecx
    mov     [r14 + 928], ecx

.usub_done:
    add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; =============================================================================
; udp_publish(rdi=topic_ptr, rsi=msg_ptr)
;   Reenviar "[tema] mensaje" a todos los suscriptores UDP del tema.
; =============================================================================
udp_publish:
    push    rbp
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 8

    mov     r12, rdi            ; r12 = tema
    mov     r13, rsi            ; r13 = mensaje

    ; Buscar tema
    mov     rdi, r12
    call    udp_find_or_create_topic
    cmp     eax, -1
    je      .upub_done

    movsxd  rbx, eax

    lea     r14, [rel topic_table]
    imul    rax, rbx, UDP_TOPIC_ENTRY_SIZE
    add     r14, rax            ; r14 = &topic_table[idx]

    ; Construir mensaje reenviado en fwd_buf
    lea     rdi, [rel fwd_buf]
    mov     esi, BUF_SIZE
    lea     rdx, [rel fmt_forward]
    mov     rcx, r12
    mov     r8,  r13
    xor     eax, eax
    call    snprintf
    movsxd  r15, eax            ; r15 = longitud del mensaje reenviado

    ; Recorrer suscriptores y enviar con sendto
    mov     ecx, [r14 + 928]    ; num_subs
    xor     r13d, r13d          ; r13d = iterador

.upub_loop:
    cmp     r13d, ecx
    jge     .upub_done

    ; Imprimir log
    push    rcx
    lea     rdi, [rel msg_fwd]
    mov     esi, r13d
    xor     eax, eax
    call    printf
    pop     rcx

    ; Calcular puntero al sockaddr_in del suscriptor
    lea     rax, [r14 + 128]
    imul    rdx, r13, SOCKADDR_IN_SIZE
    add     rax, rdx            ; rax = &subs[r13d]

    ; sendto(sock_fd, fwd_buf, len, 0, &sub_addr, sizeof(sub_addr))
    movsxd  rdi, dword [rel sock_fd]
    lea     rsi, [rel fwd_buf]
    mov     rdx, r15
    xor     ecx, ecx
    mov     r8,  rax
    mov     r9d, SOCKADDR_IN_SIZE
    call    sendto

    inc     r13d
    mov     ecx, [r14 + 928]
    jmp     .upub_loop

.upub_done:
    add     rsp, 8
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    pop     rbp
    ret
