; publisher_udp.asm
; Publicador UDP - envia 95 eventos al broker sin conexion
; Uso: ./publisher_udp <ip> <puerto> <tema>
;
; nasm -f elf64 publisher_udp.asm -o publisher_udp.o
; gcc -no-pie publisher_udp.o -o publisher_udp

bits 64
default rel

extern printf, snprintf, socket, sendto, close
extern usleep, atoi, inet_addr, htons

AF_INET    equ 2
SOCK_DGRAM equ 2
BUF_SIZE   equ 1024

section .data

uso     db "Uso: ./publisher_udp <ip> <puerto> <tema>", 10, 0
e_sock  db "Error creando socket UDP", 10, 0
e_send  db "Error en sendto", 10, 0

fmt_pub  db "PUBLISH|%s|[%d/%d] %s", 0
fmt_log  db "[Pub %s] Evento %d/%d: %s", 10, 0
fmt_ini  db "=== Publisher UDP enviando al broker %s:%d ===", 10, 0
fmt_tema db "Tema: %s", 10, 0
fmt_fin  db 10, "[Publisher] Todos los eventos enviados.", 10, 0

ev1  db "Inicio del partido!", 0
ev2  db "Saque inicial de Equipo C", 0
ev3  db "Pase largo de Equipo C al minuto 1", 0
ev4  db "Equipo D recupera el balon al minuto 2", 0
ev5  db "Tiro de esquina para Equipo D al minuto 3", 0
ev6  db "Cabezazo desviado de Equipo D al minuto 3", 0
ev7  db "Saque de meta para Equipo C", 0
ev8  db "Gol de Equipo C al minuto 5 - Marcador 1-0", 0
ev9  db "Celebracion del goleador numero 9", 0
ev10 db "Reinicio del juego por Equipo D", 0
ev11 db "Falta de Equipo C al minuto 7", 0
ev12 db "Tiro libre para Equipo D al minuto 7", 0
ev13 db "Tiro libre desviado de Equipo D", 0
ev14 db "Tarjeta amarilla al numero 14 de Equipo D al minuto 9", 0
ev15 db "Pase filtrado de Equipo C al minuto 10", 0
ev16 db "Atajada del portero de Equipo D al minuto 10", 0
ev17 db "Saque de meta para Equipo D", 0
ev18 db "Contraataque de Equipo D al minuto 12", 0
ev19 db "Falta peligrosa al minuto 13 en area de Equipo C", 0
ev20 db "Tiro libre para Equipo D al minuto 13", 0
ev21 db "Barrera de Equipo C detiene el tiro", 0
ev22 db "Posesion de Equipo C al minuto 15", 0
ev23 db "Cambio de juego de Equipo C por la banda derecha", 0
ev24 db "Centro al area de Equipo D al minuto 17", 0
ev25 db "Despeje de Equipo D", 0
ev26 db "Tiro de esquina para Equipo C al minuto 18", 0
ev27 db "Cabezazo de Equipo C al palo al minuto 18", 0
ev28 db "Falta de Equipo D al minuto 20", 0
ev29 db "Tarjeta amarilla al numero 5 de Equipo C al minuto 20", 0
ev30 db "Cambio: jugador 8 entra por jugador 6 en Equipo D al minuto 22", 0
ev31 db "Pase largo de Equipo D al minuto 23", 0
ev32 db "Fuera de juego de Equipo D al minuto 23", 0
ev33 db "Saque de Equipo C al minuto 24", 0
ev34 db "Jugada individual de Equipo C al minuto 25", 0
ev35 db "Tiro al arco de Equipo C desviado al minuto 26", 0
ev36 db "Saque de meta para Equipo D", 0
ev37 db "Gol de Equipo D al minuto 28 - Empate 1-1", 0
ev38 db "Celebracion de Equipo D", 0
ev39 db "Reinicio del juego", 0
ev40 db "Falta tactica de Equipo C al minuto 30", 0
ev41 db "Tiro libre rapido de Equipo D", 0
ev42 db "Posesion de Equipo D al minuto 32", 0
ev43 db "Centro al area de Equipo C", 0
ev44 db "Atajada del portero de Equipo C al minuto 33", 0
ev45 db "Contraataque de Equipo C al minuto 35", 0
ev46 db "Pase al area de Equipo D", 0
ev47 db "Tiro de Equipo C desviado al minuto 36", 0
ev48 db "Saque de meta para Equipo D", 0
ev49 db "Ultimo minuto del primer tiempo", 0
ev50 db "Fin del primer tiempo - Marcador: 1-1", 0
ev51 db "Inicio del segundo tiempo", 0
ev52 db "Saque de Equipo D al minuto 46", 0
ev53 db "Presion alta de Equipo C al minuto 47", 0
ev54 db "Robo de balon de Equipo C al minuto 48", 0
ev55 db "Tiro al arco de Equipo C al minuto 48", 0
ev56 db "Atajada espectacular del portero de Equipo D", 0
ev57 db "Tiro de esquina para Equipo C al minuto 49", 0
ev58 db "Despeje de Equipo D al minuto 49", 0
ev59 db "Falta de Equipo D al minuto 51", 0
ev60 db "Tarjeta amarilla al numero 3 de Equipo D", 0
ev61 db "Tiro libre de Equipo C al minuto 52", 0
ev62 db "Tiro a la barrera", 0
ev63 db "Rebote controlado por Equipo D al minuto 52", 0
ev64 db "Cambio: jugador 11 entra por jugador 7 en Equipo C al minuto 53", 0
ev65 db "Penal para Equipo C al minuto 55", 0
ev66 db "Revision del VAR al minuto 55", 0
ev67 db "Penal confirmado para Equipo C", 0
ev68 db "Gol de penal de Equipo C al minuto 56 - Marcador 2-1", 0
ev69 db "Protesta de jugadores de Equipo D", 0
ev70 db "Tarjeta amarilla al numero 10 de Equipo D por protestar", 0
ev71 db "Reinicio del juego al minuto 57", 0
ev72 db "Presion de Equipo D buscando el empate", 0
ev73 db "Centro al area de Equipo C al minuto 59", 0
ev74 db "Despeje de Equipo C al minuto 59", 0
ev75 db "Tiro de esquina para Equipo D al minuto 60", 0
ev76 db "Cabezazo de Equipo D fuera al minuto 60", 0
ev77 db "Contraataque rapido de Equipo C al minuto 62", 0
ev78 db "Pase al hueco de Equipo C al minuto 63", 0
ev79 db "Tiro desviado de Equipo C al minuto 63", 0
ev80 db "Cambio: jugador 15 entra por jugador 4 en Equipo D al minuto 65", 0
ev81 db "Falta de Equipo C al minuto 66", 0
ev82 db "Tiro libre de Equipo D al minuto 67", 0
ev83 db "Tiro libre al travesano al minuto 67", 0
ev84 db "Rebote controlado por Equipo C", 0
ev85 db "Tarjeta roja al numero 2 de Equipo D al minuto 70", 0
ev86 db "Equipo D con 10 jugadores", 0
ev87 db "Tiro libre para Equipo C al minuto 71", 0
ev88 db "Tiro libre desviado de Equipo C", 0
ev89 db "Posesion de Equipo C controlando el partido", 0
ev90 db "Cambio: jugador 16 entra por jugador 9 en Equipo C al minuto 74", 0
ev91 db "Pase largo de Equipo D al minuto 75", 0
ev92 db "Fuera de juego de Equipo D", 0
ev93 db "Tiro al arco de Equipo C al minuto 77", 0
ev94 db "Gol de Equipo C al minuto 78 - Marcador 3-1", 0
ev95 db "Fin del partido - Resultado final: Equipo C 3 - Equipo D 1", 0

eventos:
    dq ev1,  ev2,  ev3,  ev4,  ev5,  ev6,  ev7,  ev8,  ev9,  ev10
    dq ev11, ev12, ev13, ev14, ev15, ev16, ev17, ev18, ev19, ev20
    dq ev21, ev22, ev23, ev24, ev25, ev26, ev27, ev28, ev29, ev30
    dq ev31, ev32, ev33, ev34, ev35, ev36, ev37, ev38, ev39, ev40
    dq ev41, ev42, ev43, ev44, ev45, ev46, ev47, ev48, ev49, ev50
    dq ev51, ev52, ev53, ev54, ev55, ev56, ev57, ev58, ev59, ev60
    dq ev61, ev62, ev63, ev64, ev65, ev66, ev67, ev68, ev69, ev70
    dq ev71, ev72, ev73, ev74, ev75, ev76, ev77, ev78, ev79, ev80
    dq ev81, ev82, ev83, ev84, ev85, ev86, ev87, ev88, ev89, ev90
    dq ev91, ev92, ev93, ev94, ev95

NUM_EV equ 95

section .bss

sockfd   resd 1
buf      resb BUF_SIZE
braddr   resb 16   ; sockaddr_in del broker

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
    mov r12, [rbx+8]    ; IP
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

    ; armar sockaddr_in del broker
    lea rdi, [rel braddr]
    xor eax, eax
    mov ecx, 2
    rep stosq

    mov word [rel braddr], AF_INET
    mov edi, r13d
    call htons
    mov word [rel braddr+2], ax
    mov rdi, r12
    call inet_addr
    mov dword [rel braddr+4], eax

    ; cabecera
    lea rdi, [rel fmt_ini]
    mov rsi, r12
    mov edx, r13d
    xor eax, eax
    call printf

    lea rdi, [rel fmt_tema]
    mov rsi, r14
    xor eax, eax
    call printf

    xor r15d, r15d

.loop:
    cmp r15d, NUM_EV
    jge .listo

    lea rax, [rel eventos]
    mov r8, [rax + r15*8]   ; puntero al evento

    ; armar "PUBLISH|tema|[i/total] evento"
    ; snprintf necesita 5 args: buf, size, fmt, tema, seq, total, evento
    ; en x86-64: rdi, rsi, rdx, rcx, r8, r9, [rsp]
    lea rdi, [rel buf]
    mov esi, BUF_SIZE
    lea rdx, [rel fmt_pub]
    mov rcx, r14        ; tema
    push r8             ; evento al stack (7mo arg)
    mov r8d, r15d
    inc r8d             ; seq = i+1
    mov r9d, NUM_EV     ; total
    xor eax, eax
    call snprintf
    add rsp, 8
    movsxd r13, eax

    ; log en pantalla
    lea rax, [rel eventos]
    mov r8, [rax + r15*8]
    lea rdi, [rel fmt_log]
    mov rsi, r14
    mov edx, r15d
    inc edx
    mov ecx, NUM_EV
    xor eax, eax
    call printf

    ; enviar datagrama al broker
    mov rdi, rbp
    lea rsi, [rel buf]
    mov rdx, r13
    xor ecx, ecx
    lea r8, [rel braddr]
    mov r9d, 16
    call sendto
    cmp rax, -1
    je .err_send

    mov edi, 5000   ; 5ms entre eventos
    call usleep

    inc r15d
    jmp .loop

.listo:
    lea rdi, [rel fmt_fin]
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
