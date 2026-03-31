# Laboratorio 3 - Redes y Servicios de Comunicaciones

Sistema pub-sub de noticias deportivas implementado con tres protocolos de transporte: TCP, UDP y QUIC hibrido.

## Integrantes Grupo 4
- Sofia Arias Zuluaga (202310260)
- David Elias Forero Cobos (202310499)
- Sara Garcia Agudelo (202320378)

## Estructura del proyecto

```
redes_lab3/
├── implC/                          # Implementaciones en C
│   ├── broker_tcp.c
│   ├── publisher_tcp.c
│   ├── subscriber_tcp.c
│   ├── broker_udp.c
│   ├── publisher_udp.c
│   ├── subscriber_udp.c
│   ├── broker_quic.c
│   ├── publisher_quic.c
│   ├── subscriber_quic.c
│   ├── tcp_pubsub.pcap
│   ├── udp_pubsub.pcap
│   └── quic_pubsub.pcap
├── assembler/                      # Bono: implementacion en NASM x86-64
│   ├── broker_tcp.asm
│   ├── publisher_tcp.asm
│   ├── subscriber_tcp.asm
│   ├── broker_udp.asm
│   ├── publisher_udp.asm
│   ├── subscriber_udp.asm
│   └── Makefile
├── redes_lab3_enunciado.pdf
├── redes_lab3_grupo4_informe.pdf
└── README.md
```

## Compilacion

Desde la carpeta `implC/`:

```bash
# TCP
gcc -o broker_tcp broker_tcp.c
gcc -o publisher_tcp publisher_tcp.c
gcc -o subscriber_tcp subscriber_tcp.c

# UDP
gcc -o broker_udp broker_udp.c
gcc -o publisher_udp publisher_udp.c
gcc -o subscriber_udp subscriber_udp.c

# QUIC hibrido
gcc -o broker_quic broker_quic.c
gcc -o publisher_quic publisher_quic.c
gcc -o subscriber_quic subscriber_quic.c
```

## Descripcion de los archivos

### TCP (`broker_tcp.c`, `publisher_tcp.c`, `subscriber_tcp.c`)

Implementacion orientada a conexion usando sockets TCP. El broker usa `select()` para manejar multiples conexiones simultaneas sin hilos.

- **broker_tcp.c**: Intermediario central que escucha en un puerto, acepta conexiones de publishers y subscribers, y reenvía mensajes segun el tema suscrito. Usa `select()` para multiplexar las conexiones y mantiene un arreglo de file descriptors activos. Funciones principales: `socket()`, `bind()`, `listen()`, `accept()`, `recv()`, `send()`, `select()`.

- **publisher_tcp.c**: Se conecta al broker por TCP y envia 12 eventos deportivos predefinidos de un partido. Cada mensaje tiene formato `PUBLISH|tema|mensaje`. Usa `socket()`, `connect()`, `send()`.

- **subscriber_tcp.c**: Se conecta al broker, envia una solicitud `SUBSCRIBE|tema` y queda escuchando mensajes con `recv()`. Soporta suscripcion a multiples temas.

**Resultado**: TCP entrego el 100% de los mensajes sin perdida, gracias a los ACKs y retransmisiones automaticas del protocolo.

### UDP (`broker_udp.c`, `publisher_udp.c`, `subscriber_udp.c`)

Implementacion sin conexion usando datagramas UDP. Cada mensaje es un datagrama independiente.

- **broker_udp.c**: Recibe datagramas con `recvfrom()` y mantiene una tabla interna de suscriptores (direccion IP + puerto) por tema. Al recibir un `PUBLISH`, reenvia el mensaje con `sendto()` a todos los suscriptores registrados en ese tema. No necesita `select()` ni multiples sockets porque todo pasa por un unico socket UDP.

- **publisher_udp.c**: Envia 105 eventos deportivos al broker como datagramas UDP, con intervalos de 5ms entre mensajes para generar rafagas rapidas. Cada mensaje incluye un numero de secuencia `[N/105]` para poder identificar perdidas en el receptor. Usa `socket()`, `sendto()`.

- **subscriber_udp.c**: Envia solicitud de suscripcion al broker y queda en un bucle infinito esperando datagramas con `recvfrom()`. Configura un buffer de recepcion de 8KB (`SO_RCVBUF`) y tiene un delay de 20ms por mensaje para simular procesamiento real. Esto hace que cuando llegan muchos datagramas rapido, el buffer se llena y el sistema operativo descarta los que no caben.

**Resultado**: Se observo perdida de paquetes real (32-33%). El suscriptor 1 recibio 142 de 210 mensajes y el suscriptor 2 recibio 70 de 105.

### QUIC hibrido (`broker_quic.c`, `publisher_quic.c`, `subscriber_quic.c`)

Implementacion que usa sockets UDP pero agrega confiabilidad a nivel de aplicacion, similar a como funciona QUIC (el protocolo detras de HTTP/3).

- **broker_quic.c**: Funciona sobre un socket UDP pero implementa ACKs y retransmision. Cuando reenvia un mensaje a un suscriptor, espera un `ACK|seq` de confirmacion. Si no llega en 500ms, retransmite hasta 3 veces. Tambien asigna numeros de secuencia a cada mensaje para garantizar el orden.

- **publisher_quic.c**: Similar al publicador UDP pero cada mensaje lleva un numero de secuencia. Envia al broker y espera confirmacion. Usa `select()` con timeout para detectar si el ACK llego o si debe reenviar.

- **subscriber_quic.c**: Recibe mensajes numerados del broker y responde con un ACK por cada uno (`ACK|N`). Esto le permite al broker saber que el mensaje llego y no necesita retransmitirlo.

**Resultado**: 0% de perdida con solo 74 paquetes totales (vs 150 de TCP y 528 de UDP) y 5,046 bytes (vs 12,342 de TCP).

## Ejecucion

Cada protocolo necesita 1 broker, 2 publishers y 2 subscribers (uno suscrito a 2 temas). Ejemplo para UDP:

```bash
# Terminal 1 - Broker
./broker_udp 5556

# Terminal 2 - Subscriber 1 (2 temas)
./subscriber_udp 127.0.0.1 5556 EquipoA_vs_EquipoB EquipoC_vs_EquipoD

# Terminal 3 - Subscriber 2 (1 tema)
./subscriber_udp 127.0.0.1 5556 EquipoC_vs_EquipoD

# Terminal 4 - Publisher 1
./publisher_udp 127.0.0.1 5556 EquipoA_vs_EquipoB

# Terminal 5 - Publisher 2
./publisher_udp 127.0.0.1 5556 EquipoC_vs_EquipoD
```

Para TCP y QUIC es igual pero con los ejecutables correspondientes y los puertos 5555 (TCP) y 5557 (QUIC).

Los subscribers se detienen con `Ctrl+C` una vez que ambos publishers terminan de enviar.

## Bono: Implementacion en Ensamblador x86-64

Los mismos 6 componentes TCP y UDP estan reimplementados en NASM (ensamblador x86-64) dentro de la carpeta `assembler/`. QUIC no fue reescrito en ASM ya que el enunciado lo permite.

### Estructura

```
assembler/
├── broker_tcp.asm
├── publisher_tcp.asm
├── subscriber_tcp.asm
├── broker_udp.asm
├── publisher_udp.asm
├── subscriber_udp.asm
└── Makefile
```

### Librerias usadas

Los archivos ASM **no usan ninguna libreria externa especial**. Solo llaman funciones de la libreria estandar de C (libc) mediante `extern`, exactamente igual que lo haria un programa en C compilado con gcc. La siguiente tabla lista todas las funciones usadas y donde se usan:

| Funcion | Header de origen | Usada en |
|---|---|---|
| `printf`, `snprintf` | `<stdio.h>` | todos los archivos (mensajes en pantalla) |
| `socket`, `bind`, `listen`, `accept` | `<sys/socket.h>` | brokers TCP y UDP |
| `connect`, `send`, `recv` | `<sys/socket.h>` | publisher/subscriber TCP |
| `sendto`, `recvfrom` | `<sys/socket.h>` | publisher/subscriber/broker UDP |
| `setsockopt` | `<sys/socket.h>` | broker UDP (SO_REUSEADDR) |
| `select` | `<sys/select.h>` | broker TCP (multiplexado sin hilos) |
| `close` | `<unistd.h>` | todos los archivos |
| `write` | `<unistd.h>` | subscriber TCP (escribe a stdout) |
| `sleep`, `usleep` | `<unistd.h>` | publisher TCP (2s) y UDP (5ms) entre eventos |
| `htons`, `ntohs` | `<arpa/inet.h>` | todos (convertir orden de bytes de red) |
| `inet_addr`, `inet_ntoa` | `<arpa/inet.h>` | brokers (IP texto ↔ binario) |
| `atoi` | `<stdlib.h>` | todos (convertir puerto de argv a entero) |
| `memset`, `memcmp` | `<string.h>` | brokers (inicializar y comparar sockaddr_in) |
| `strncmp`, `strncpy`, `strlen`, `strchr` | `<string.h>` | brokers (parsear mensajes SUBSCRIBE/PUBLISH) |

> Todos estos simbolos son resueltos en tiempo de enlace por gcc con la libc del sistema. No se necesita instalar nada adicional.

### Compilacion (Linux x86-64)

Requiere `nasm` y `gcc`. En macOS con chip Apple Silicon se usa Docker:

```bash
# instalar nasm en Linux/Docker
apt-get install nasm

# compilar todo
cd assembler/
make

# o individualmente
nasm -f elf64 broker_tcp.asm -o broker_tcp.o
gcc -no-pie broker_tcp.o -o broker_tcp
```

### Ejecucion

Identica a la version en C. Ejemplo TCP:

```bash
# Terminal 1
./broker_tcp 5555

# Terminal 2
./subscriber_tcp 127.0.0.1 5555 futbol

# Terminal 3
./publisher_tcp 127.0.0.1 5555 futbol
```

### Detalles de implementacion

- **Convencion de llamada**: System V AMD64 ABI. Argumentos en `rdi`, `rsi`, `rdx`, `rcx`, `r8`, `r9`. Retorno en `rax`. Registros callee-saved: `rbx`, `rbp`, `r12`–`r15`.
- **Alineacion de pila**: cada funcion ajusta `rsp` para garantizar alineacion a 16 bytes antes de cualquier `call`, como exige la ABI.
- **fd_set manual**: el broker TCP implementa `FD_SET`, `FD_CLR` e `FD_ISSET` directamente con operaciones de bits sobre los 128 bytes de la estructura, sin macros de libc.
- **Tabla de temas TCP**: cada entrada ocupa 336 bytes (128 nombre + 200 array de fds + 4 contador + 4 padding).
- **Tabla de temas UDP**: cada entrada ocupa 936 bytes (128 nombre + 800 array de sockaddr_in + 4 contador + 4 padding).

## Capturas Wireshark

Las capturas `.pcap` se tomaron en la interfaz loopback (`lo0`) con el filtro `udp port 5556` (UDP/QUIC) o `tcp port 5555` (TCP). Se pueden abrir con Wireshark para ver los paquetes individuales y comparar el comportamiento de cada protocolo.
