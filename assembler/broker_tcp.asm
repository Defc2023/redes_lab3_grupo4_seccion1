; =============================================================================
; broker_tcp.asm — Broker TCP para el sistema de noticias deportivas
; =============================================================================
; Uso: ./broker_tcp <puerto>
;
; Descripcion:
;   Acepta conexiones TCP de publicadores y suscriptores.
;   Usa select() para multiplexar todos los fds sin hilos.
;   Protocolo entrante:
;     SUBSCRIBE|tema\n   → registra el fd como suscriptor del tema
;     PUBLISH|tema|msg\n → reenviar msg a todos los suscriptores del tema
;
; Compilacion:
;   nasm -f elf64 broker_tcp.asm -o broker_tcp.o
;   gcc -no-pie broker_tcp.o -o broker_tcp
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
extern listen
extern accept
extern recv
extern send
extern close
extern select
extern setsockopt
extern htons
extern memset
extern strlen
extern strncpy
extern strncmp
extern atoi

; ---------------------------------------------------------------------------
; Constantes de sockets
; ---------------------------------------------------------------------------
AF_INET       equ 2
SOCK_STREAM   equ 1
SOL_SOCKET    equ 1
SO_REUSEADDR  equ 2
BACKLOG       equ 10

SOCKADDR_IN_SIZE equ 16
BUF_SIZE         equ 1024

; ---------------------------------------------------------------------------
; Estructura de la tabla de temas (TopicEntry):
;   +0   nombre del tema   128 bytes  (cadena terminada en nulo)
;   +128 array de fds      200 bytes  (50 enteros de 32 bits)
;   +328 num_subs           4 bytes   (int32)
;   +332 relleno            4 bytes
;   Total: 336 bytes
; ---------------------------------------------------------------------------
TOPIC_NAME_LEN   equ 128
MAX_SUBS_PER_TOPIC equ 50
TOPIC_ENTRY_SIZE equ 336
MAX_TOPICS       equ 20
MAX_CLIENTS      equ 64   ; maximo de fds cliente simulados

; ---------------------------------------------------------------------------
; Datos de solo lectura
; ---------------------------------------------------------------------------
section .data

usage_msg    db  "Uso: ./broker_tcp <puerto>", 10, 0
err_socket   db  "Error: socket()", 10, 0
err_bind     db  "Error: bind()", 10, 0
err_listen   db  "Error: listen()", 10, 0
err_accept   db  "Error: accept()", 10, 0

msg_start    db  "Broker TCP escuchando en puerto %d...", 10, 0
msg_client   db  "[Broker] Nueva conexion: fd=%d", 10, 0
msg_closed   db  "[Broker] Conexion cerrada: fd=%d", 10, 0
msg_sub      db  "[Broker] SUBSCRIBE fd=%d tema='%s'", 10, 0
msg_pub      db  "[Broker] PUBLISH tema='%s' msg='%s'", 10, 0
msg_fwd      db  "[Broker] Reenviando a fd=%d", 10, 0
msg_unknown  db  "[Broker] Mensaje desconocido de fd=%d", 10, 0

; Separadores de protocolo
sep_pipe     db  "|", 0
sep_nl       db  10, 0

; Prefijo para mensaje reenviado al suscriptor: "[tema] mensaje\n"
fmt_forward  db  "[%s] %s", 10, 0

opt_one      dd  1          ; valor para setsockopt SO_REUSEADDR

; ---------------------------------------------------------------------------
; Datos no inicializados
; ---------------------------------------------------------------------------
section .bss

listen_fd    resd 1                         ; fd del socket de escucha
port_num     resd 1                         ; numero de puerto

server_addr  resb SOCKADDR_IN_SIZE          ; sockaddr_in del servidor
client_addr  resb SOCKADDR_IN_SIZE          ; sockaddr_in del cliente (accept)
client_len   resd 1                         ; longitud de client_addr

; fd_set para select() (128 bytes en Linux 64-bit)
master_set   resb 128
read_set     resb 128

max_fd       resd 1                         ; fd maximo conocido

recv_buf     resb BUF_SIZE                  ; buffer de recepcion
fwd_buf      resb BUF_SIZE                  ; buffer para mensaje reenviado

; Tabla de temas: MAX_TOPICS entradas de TOPIC_ENTRY_SIZE cada una
topic_table  resb MAX_TOPICS * TOPIC_ENTRY_SIZE

num_topics   resd 1                         ; numero de temas activos

; ---------------------------------------------------------------------------
; Codigo
; ---------------------------------------------------------------------------
section .text
global main

; ============================================================
; main(int argc, char **argv)
; ============================================================
main:
    push    rbp
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    ; 6 pushes → rsp ≡ 8+6*8 = 56 ≡ 8 (mod 16). Necesitamos sub rsp,8.
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
    mov     rbx, rsi            ; rbx = argv
    mov     rdi, [rbx + 8]      ; argv[1] = cadena de puerto
    xor     eax, eax
    call    atoi
    mov     [rel port_num], eax
    mov     r12d, eax           ; r12d = puerto

    ; ---- Inicializar tabla de temas a cero ----
    lea     rdi, [rel topic_table]
    xor     esi, esi
    mov     edx, MAX_TOPICS * TOPIC_ENTRY_SIZE
    call    memset

    ; -------------------------------------------------------
    ; 1. Crear socket TCP de escucha
    ; -------------------------------------------------------
    mov     edi, AF_INET
    mov     esi, SOCK_STREAM
    xor     edx, edx
    call    socket
    cmp     eax, -1
    je      .err_socket
    mov     [rel listen_fd], eax
    movsxd  r13, eax            ; r13 = listen_fd

    ; Opcion SO_REUSEADDR para reutilizar el puerto rapidamente
    mov     rdi, r13
    mov     esi, SOL_SOCKET
    mov     edx, SO_REUSEADDR
    lea     rcx, [rel opt_one]
    mov     r8d, 4
    call    setsockopt

    ; -------------------------------------------------------
    ; 2. Construir sockaddr_in y hacer bind
    ; -------------------------------------------------------
    lea     rdi, [rel server_addr]
    xor     esi, esi
    mov     edx, SOCKADDR_IN_SIZE
    call    memset

    mov     word [rel server_addr], AF_INET

    mov     edi, r12d
    call    htons
    mov     word [rel server_addr + 2], ax

    ; INADDR_ANY = 0 (ya esta en cero tras memset)

    mov     rdi, r13
    lea     rsi, [rel server_addr]
    mov     edx, SOCKADDR_IN_SIZE
    call    bind
    cmp     eax, -1
    je      .err_bind

    ; -------------------------------------------------------
    ; 3. Escuchar conexiones entrantes
    ; -------------------------------------------------------
    mov     rdi, r13
    mov     esi, BACKLOG
    call    listen
    cmp     eax, -1
    je      .err_listen

    ; Anunciar que el broker esta listo
    lea     rdi, [rel msg_start]
    mov     esi, r12d
    xor     eax, eax
    call    printf

    ; -------------------------------------------------------
    ; 4. Inicializar fd_set maestro con el fd de escucha
    ; -------------------------------------------------------
    ; Poner master_set a cero
    lea     rdi, [rel master_set]
    xor     esi, esi
    mov     edx, 128
    call    memset

    ; FD_SET(listen_fd, &master_set)
    lea     rsi, [rel master_set]
    mov     edi, r13d
    call    fdset_set

    mov     [rel max_fd], r13d  ; max_fd = listen_fd

    ; -------------------------------------------------------
    ; 5. Bucle principal de select()
    ; -------------------------------------------------------
.select_loop:
    ; Copiar master_set → read_set
    lea     rdi, [rel read_set]
    lea     rsi, [rel master_set]
    mov     ecx, 16             ; 128 bytes / 8 = 16 qwords
    rep     movsq

    ; select(max_fd+1, &read_set, NULL, NULL, NULL)
    mov     eax, [rel max_fd]
    inc     eax
    movsxd  rdi, eax
    lea     rsi, [rel read_set]
    xor     edx, edx
    xor     ecx, ecx
    xor     r8d, r8d
    call    select
    cmp     eax, -1
    jl      .select_loop        ; error transitorio, reintentar

    ; Recorrer todos los fds posibles (0..max_fd)
    xor     r14d, r14d          ; r14d = fd iterador

.fd_scan_loop:
    mov     eax, [rel max_fd]
    cmp     r14d, eax
    jg      .select_loop        ; fin del recorrido → volver a select

    ; FD_ISSET(r14d, &read_set)?
    lea     rsi, [rel read_set]
    mov     edi, r14d
    call    fdset_isset
    test    eax, eax
    jz      .next_fd

    ; ¿Es el fd de escucha? → nueva conexion
    cmp     r14d, r13d
    je      .new_connection

    ; ¿Es un cliente existente? → leer datos
    mov     r15d, r14d          ; r15d = fd del cliente
    jmp     .read_client

.next_fd:
    inc     r14d
    jmp     .fd_scan_loop

; --- Nueva conexion entrante ---
.new_connection:
    mov     dword [rel client_len], SOCKADDR_IN_SIZE
    mov     rdi, r13
    lea     rsi, [rel client_addr]
    lea     rdx, [rel client_len]
    call    accept
    cmp     eax, -1
    je      .next_fd

    movsxd  rbx, eax            ; rbx = nuevo fd cliente

    ; Anunciar nueva conexion
    lea     rdi, [rel msg_client]
    mov     esi, ebx
    xor     eax, eax
    call    printf

    ; FD_SET(nuevo_fd, &master_set)
    lea     rsi, [rel master_set]
    mov     edi, ebx
    call    fdset_set

    ; Actualizar max_fd si es necesario
    mov     eax, [rel max_fd]
    cmp     ebx, eax
    jle     .next_fd
    mov     [rel max_fd], ebx
    jmp     .next_fd

; --- Leer datos de un cliente ---
.read_client:
    movsxd  rdi, r15d
    lea     rsi, [rel recv_buf]
    mov     edx, BUF_SIZE - 1
    xor     ecx, ecx
    call    recv
    cmp     rax, 0
    jle     .client_disconnected

    ; Terminar la cadena en nulo
    lea     rbx, [rel recv_buf]
    mov     byte [rbx + rax], 0

    ; Procesar el mensaje recibido
    movsxd  rdi, r15d           ; fd del cliente
    lea     rsi, [rel recv_buf] ; puntero al mensaje
    call    process_message
    jmp     .next_fd

; --- Cliente desconectado ---
.client_disconnected:
    ; Anunciar desconexion
    lea     rdi, [rel msg_closed]
    mov     esi, r15d
    xor     eax, eax
    call    printf

    ; Eliminar fd de todos los temas
    movsxd  rdi, r15d
    call    remove_fd_from_topics

    ; FD_CLR(fd, &master_set)
    lea     rsi, [rel master_set]
    mov     edi, r15d
    call    fdset_clr

    ; Cerrar socket
    movsxd  rdi, r15d
    call    close
    jmp     .next_fd

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
    jmp     .exit

.err_listen:
    lea     rdi, [rel err_listen]
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
; process_message(rdi=fd, rsi=msg_ptr)
;   Analiza el mensaje y despacha a subscribe_fd o publish_msg.
;   Formato SUBSCRIBE: "SUBSCRIBE|tema\n"
;   Formato PUBLISH:   "PUBLISH|tema|mensaje\n"
; =============================================================================
process_message:
    push    rbp
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 8

    mov     r12d, edi           ; r12d = fd del cliente
    mov     r13, rsi            ; r13 = puntero al mensaje

    ; ¿Comienza con "SUBSCRIBE|"?
    lea     rdi, [rel r13]
    mov     rdi, r13
    lea     rsi, [rel .str_subscribe]
    mov     edx, 10             ; longitud de "SUBSCRIBE|"
    call    strncmp
    test    eax, eax
    jnz     .check_publish

    ; Extraer tema: puntero justo despues de "SUBSCRIBE|"
    mov     r14, r13
    add     r14, 10             ; r14 = inicio del tema

    ; Eliminar el \n final si existe
    mov     rdi, r14
    call    strlen
    test    rax, rax
    jz      .pm_done
    lea     rbx, [r14 + rax - 1]
    cmp     byte [rbx], 10
    jne     .do_subscribe
    mov     byte [rbx], 0      ; reemplazar \n por nulo

.do_subscribe:
    ; Imprimir log
    lea     rdi, [rel msg_sub]
    mov     esi, r12d
    mov     rdx, r14
    xor     eax, eax
    call    printf

    ; Registrar suscripcion
    movsxd  rdi, r12d
    mov     rsi, r14
    call    subscribe_fd
    jmp     .pm_done

.check_publish:
    ; ¿Comienza con "PUBLISH|"?
    mov     rdi, r13
    lea     rsi, [rel .str_publish]
    mov     edx, 8              ; longitud de "PUBLISH|"
    call    strncmp
    test    eax, eax
    jnz     .pm_unknown

    ; Extraer tema: puntero justo despues de "PUBLISH|"
    mov     r14, r13
    add     r14, 8              ; r14 = inicio del tema

    ; Encontrar el segundo '|' para separar tema de mensaje
    mov     rdi, r14
    xor     esi, esi
    call    strlen
    ; buscar '|' en r14
    mov     rcx, rax
    mov     rbx, r14
.find_pipe:
    test    rcx, rcx
    jz      .pm_unknown
    cmp     byte [rbx], '|'
    je      .pipe_found
    inc     rbx
    dec     rcx
    jmp     .find_pipe

.pipe_found:
    mov     byte [rbx], 0      ; terminar tema en nulo
    inc     rbx                ; rbx = inicio del mensaje

    ; Eliminar \n final del mensaje
    mov     rdi, rbx
    call    strlen
    test    rax, rax
    jz      .do_publish
    lea     r15, [rbx + rax - 1]
    cmp     byte [r15], 10
    jne     .do_publish
    mov     byte [r15], 0

.do_publish:
    ; Imprimir log
    lea     rdi, [rel msg_pub]
    mov     rsi, r14
    mov     rdx, rbx
    xor     eax, eax
    call    printf

    ; Publicar el mensaje a los suscriptores
    mov     rdi, r14            ; puntero al tema
    mov     rsi, rbx            ; puntero al mensaje
    call    publish_msg
    jmp     .pm_done

.pm_unknown:
    lea     rdi, [rel msg_unknown]
    mov     esi, r12d
    xor     eax, eax
    call    printf

.pm_done:
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
; find_or_create_topic(rdi=topic_ptr) → rax = indice (0..MAX_TOPICS-1) o -1
;   Busca el tema en topic_table; si no existe lo crea.
; =============================================================================
find_or_create_topic:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 8

    mov     r12, rdi            ; r12 = puntero al tema buscado
    xor     r13d, r13d          ; r13d = indice iterador
    mov     r14d, -1            ; r14d = primer slot libre (-1 = ninguno)

.foct_loop:
    mov     eax, [rel num_topics]
    cmp     r13d, MAX_TOPICS
    jge     .foct_no_space

    ; Calcular puntero a entry[r13]
    lea     rbx, [rel topic_table]
    imul    rax, r13, TOPIC_ENTRY_SIZE
    add     rbx, rax            ; rbx = &topic_table[r13]

    ; ¿Slot vacio? (primer byte del nombre == 0)
    cmp     byte [rbx], 0
    jne     .foct_check_name

    ; Guardar primer slot libre
    cmp     r14d, -1
    jne     .foct_next
    mov     r14d, r13d
    jmp     .foct_next

.foct_check_name:
    ; Comparar nombre del tema
    mov     rdi, rbx
    mov     rsi, r12
    mov     edx, TOPIC_NAME_LEN
    call    strncmp
    test    eax, eax
    jnz     .foct_next

    ; Encontrado: retornar indice
    mov     eax, r13d
    jmp     .foct_ret

.foct_next:
    inc     r13d
    jmp     .foct_loop

.foct_no_space:
    ; No se encontro; crear en el primer slot libre
    cmp     r14d, -1
    je      .foct_fail

    ; Copiar nombre del tema al slot libre
    lea     rbx, [rel topic_table]
    imul    rax, r14, TOPIC_ENTRY_SIZE
    add     rbx, rax            ; rbx = &topic_table[r14d]

    mov     rdi, rbx
    mov     rsi, r12
    mov     edx, TOPIC_NAME_LEN - 1
    call    strncpy
    mov     byte [rbx + TOPIC_NAME_LEN - 1], 0

    ; Inicializar num_subs a 0
    mov     dword [rbx + 328], 0

    ; Incrementar contador de temas activos
    mov     eax, [rel num_topics]
    inc     eax
    mov     [rel num_topics], eax

    mov     eax, r14d
    jmp     .foct_ret

.foct_fail:
    mov     eax, -1

.foct_ret:
    add     rsp, 8
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; =============================================================================
; subscribe_fd(rdi=fd, rsi=topic_ptr)
;   Registra fd como suscriptor del tema dado.
; =============================================================================
subscribe_fd:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 8

    movsxd  r12, edi            ; r12 = fd
    mov     r13, rsi            ; r13 = puntero al tema

    ; Encontrar o crear el tema
    mov     rdi, r13
    call    find_or_create_topic
    cmp     eax, -1
    je      .sfd_done

    movsxd  rbx, eax            ; rbx = indice del tema

    ; Calcular puntero a la entrada del tema
    lea     rdi, [rel topic_table]
    imul    rax, rbx, TOPIC_ENTRY_SIZE
    add     rdi, rax            ; rdi = &topic_table[idx]

    ; Obtener num_subs actual
    mov     ecx, [rdi + 328]
    cmp     ecx, MAX_SUBS_PER_TOPIC
    jge     .sfd_done

    ; Evitar duplicados: recorrer array de fds
    xor     r8d, r8d
.check_dup:
    cmp     r8d, ecx
    jge     .add_sub
    mov     eax, [rdi + 128 + r8 * 4]
    cmp     eax, r12d
    je      .sfd_done           ; ya suscrito
    inc     r8d
    jmp     .check_dup

.add_sub:
    ; Agregar fd al array
    movsxd  r8, ecx
    mov     [rdi + 128 + r8 * 4], r12d
    inc     ecx
    mov     [rdi + 328], ecx

.sfd_done:
    add     rsp, 8
    pop     r13
    pop     r12
    pop     rbx
    ret

; =============================================================================
; publish_msg(rdi=topic_ptr, rsi=msg_ptr)
;   Reenviar "[tema] mensaje\n" a todos los suscriptores del tema.
; =============================================================================
publish_msg:
    push    rbp
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 8

    mov     r12, rdi            ; r12 = puntero al tema
    mov     r13, rsi            ; r13 = puntero al mensaje

    ; Buscar tema (no crear si no existe)
    mov     rdi, r12
    call    find_or_create_topic
    cmp     eax, -1
    je      .pm2_done

    movsxd  rbx, eax

    ; Calcular puntero a la entrada del tema
    lea     r14, [rel topic_table]
    imul    rax, rbx, TOPIC_ENTRY_SIZE
    add     r14, rax            ; r14 = &topic_table[idx]

    ; Construir mensaje reenviado en fwd_buf: "[tema] mensaje\n"
    lea     rdi, [rel fwd_buf]
    mov     esi, BUF_SIZE
    lea     rdx, [rel fmt_forward]
    mov     rcx, r12            ; tema
    mov     r8, r13             ; mensaje
    xor     eax, eax
    call    snprintf
    movsxd  r15, eax            ; r15 = longitud del mensaje reenviado

    ; Recorrer array de suscriptores y enviar a cada uno
    mov     ecx, [r14 + 328]    ; num_subs
    xor     r13d, r13d          ; r13d = iterador

.fwd_loop:
    cmp     r13d, ecx
    jge     .pm2_done

    movsxd  rdi, dword [r14 + 128 + r13 * 4]   ; fd del suscriptor

    ; Imprimir log
    push    rdi
    push    rcx
    lea     rdi, [rel msg_fwd]
    mov     esi, dword [r14 + 128 + r13 * 4]
    xor     eax, eax
    call    printf
    pop     rcx
    pop     rdi

    lea     rsi, [rel fwd_buf]
    mov     rdx, r15
    xor     ecx, ecx
    call    send

    inc     r13d
    mov     ecx, [r14 + 328]    ; recargar num_subs (podria cambiar)
    jmp     .fwd_loop

.pm2_done:
    add     rsp, 8
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    pop     rbp
    ret

; =============================================================================
; remove_fd_from_topics(rdi=fd)
;   Eliminar fd del array de suscriptores en todos los temas.
; =============================================================================
remove_fd_from_topics:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8

    movsxd  r12, edi            ; r12 = fd a eliminar
    xor     r13d, r13d          ; r13d = indice de tema

.rft_topic_loop:
    cmp     r13d, MAX_TOPICS
    jge     .rft_done

    ; Calcular puntero a la entrada del tema
    lea     rbx, [rel topic_table]
    imul    rax, r13, TOPIC_ENTRY_SIZE
    add     rbx, rax

    ; ¿Tema vacio? → saltar
    cmp     byte [rbx], 0
    je      .rft_next_topic

    ; Buscar fd en el array de suscriptores
    mov     ecx, [rbx + 328]    ; num_subs
    xor     r14d, r14d

.rft_sub_loop:
    cmp     r14d, ecx
    jge     .rft_next_topic
    mov     eax, [rbx + 128 + r14 * 4]
    cmp     eax, r12d
    je      .rft_remove
    inc     r14d
    jmp     .rft_sub_loop

.rft_remove:
    ; Mover el ultimo fd a esta posicion y decrementar num_subs
    dec     ecx
    mov     eax, [rbx + 128 + rcx * 4]
    mov     [rbx + 128 + r14 * 4], eax
    mov     [rbx + 328], ecx

.rft_next_topic:
    inc     r13d
    jmp     .rft_topic_loop

.rft_done:
    add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; =============================================================================
; fdset_set(edi=fd, rsi=fdset_ptr)
;   Implementacion de FD_SET en ensamblador.
;   fd_set en Linux 64-bit = 128 bytes = array de 16 qwords de 64 bits.
; =============================================================================
fdset_set:
    mov     eax, edi
    mov     ecx, edi
    shr     eax, 6              ; indice de palabra: fd / 64
    and     ecx, 63             ; desplazamiento de bit: fd % 64
    mov     rdx, 1
    shl     rdx, cl             ; mascara = 1 << bit_offset
    or      qword [rsi + rax*8], rdx
    ret

; =============================================================================
; fdset_clr(edi=fd, rsi=fdset_ptr)
;   Implementacion de FD_CLR en ensamblador.
; =============================================================================
fdset_clr:
    mov     eax, edi
    mov     ecx, edi
    shr     eax, 6
    and     ecx, 63
    mov     rdx, 1
    shl     rdx, cl
    not     rdx
    and     qword [rsi + rax*8], rdx
    ret

; =============================================================================
; fdset_isset(edi=fd, rsi=fdset_ptr) → rax (1=activo, 0=inactivo)
;   Implementacion de FD_ISSET en ensamblador.
; =============================================================================
fdset_isset:
    mov     eax, edi
    mov     ecx, edi
    shr     eax, 6
    and     ecx, 63
    mov     rdx, 1
    shl     rdx, cl
    test    qword [rsi + rax*8], rdx
    setnz   al
    movzx   rax, al
    ret
