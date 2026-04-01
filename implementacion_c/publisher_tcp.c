/*
 * publisher_tcp.c - Publicador TCP para sistema de noticias deportivas
 *
 * Descripcion:
 *   Simula a un periodista deportivo que reporta eventos de un partido en vivo.
 *   Se conecta al broker TCP y envia mensajes sobre un tema (partido).
 *   Envia automaticamente 10 eventos deportivos predefinidos.
 *
 * Protocolo: Envia "PUBLISH|tema|mensaje\n" al broker.
 *
 * Uso: ./publisher_tcp <ip_broker> <puerto_broker> <tema>
 *   Ejemplo: ./publisher_tcp 127.0.0.1 5555 "EquipoA_vs_EquipoB"
 *
 * Funciones de sockets utilizadas:
 *   socket()  - Crea el socket TCP (AF_INET, SOCK_STREAM)
 *   connect() - Establece conexion TCP con el broker (three-way handshake)
 *   send()    - Envia datos al broker a traves de la conexion TCP
 *   close()   - Cierra el socket
 *   inet_pton() - Convierte direccion IP de texto a formato binario
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <arpa/inet.h>
#include <sys/socket.h>

#define BUFFER_SIZE 1024

/* Mensajes deportivos predefinidos para simular un partido */
static const char *eventos[] = {
    "Inicio del partido!",
    "Gol de Equipo A al minuto 12",
    "Tarjeta amarilla al numero 7 de Equipo B",
    "Tiro de esquina para Equipo A al minuto 18",
    "Cambio: jugador 11 entra por jugador 9 en Equipo B",
    "Gol de Equipo B al minuto 35 - Empate 1-1",
    "Fin del primer tiempo",
    "Inicio del segundo tiempo",
    "Gol de Equipo A al minuto 58 - Marcador 2-1",
    "Tarjeta roja al numero 3 de Equipo B al minuto 65",
    "Gol de Equipo A al minuto 78 - Marcador 3-1",
    "Fin del partido - Resultado final: Equipo A 3 - Equipo B 1"
};

#define NUM_EVENTOS (sizeof(eventos) / sizeof(eventos[0]))

int main(int argc, char *argv[]) {
    if (argc != 4) {
        fprintf(stderr, "Uso: %s <ip_broker> <puerto> <tema>\n", argv[0]);
        fprintf(stderr, "Ejemplo: %s 127.0.0.1 5555 EquipoA_vs_EquipoB\n", argv[0]);
        exit(EXIT_FAILURE);
    }

    const char *broker_ip = argv[1];
    int port = atoi(argv[2]);
    const char *topic = argv[3];

    /* socket() crea un socket TCP (SOCK_STREAM) en el dominio IPv4 (AF_INET) */
    int sockfd = socket(AF_INET, SOCK_STREAM, 0);
    if (sockfd < 0) {
        perror("socket");
        exit(EXIT_FAILURE);
    }

    /* Configurar la direccion del broker */
    struct sockaddr_in broker_addr;
    memset(&broker_addr, 0, sizeof(broker_addr));
    broker_addr.sin_family = AF_INET;
    broker_addr.sin_port   = htons(port);

    /* inet_pton() convierte la IP de texto ("127.0.0.1") a formato binario de red */
    if (inet_pton(AF_INET, broker_ip, &broker_addr.sin_addr) <= 0) {
        perror("inet_pton");
        close(sockfd);
        exit(EXIT_FAILURE);
    }

    /* connect() inicia el three-way handshake TCP con el broker */
    if (connect(sockfd, (struct sockaddr *)&broker_addr, sizeof(broker_addr)) < 0) {
        perror("connect");
        close(sockfd);
        exit(EXIT_FAILURE);
    }

    printf("=== Publisher TCP conectado al broker %s:%d ===\n", broker_ip, port);
    printf("Tema: %s\n", topic);
    printf("Enviando %lu eventos...\n\n", (unsigned long)NUM_EVENTOS);

    /* Enviar cada evento deportivo al broker */
    for (int i = 0; i < (int)NUM_EVENTOS; i++) {
        char buf[BUFFER_SIZE];
        /* Formato del mensaje: PUBLISH|tema|mensaje\n */
        int len = snprintf(buf, sizeof(buf), "PUBLISH|%s|%s\n", topic, eventos[i]);

        /* send() envia el mensaje completo por el socket TCP */
        if (send(sockfd, buf, len, 0) < 0) {
            perror("send");
            break;
        }

        printf("[Pub %s] Evento %d: %s\n", topic, i + 1, eventos[i]);

        /* Pausa de 2 segundos entre mensajes para simular tiempo real */
        sleep(2);
    }

    printf("\n[Publisher] Todos los eventos enviados. Cerrando conexion.\n");

    /* close() cierra la conexion TCP (envia FIN al broker) */
    close(sockfd);
    return 0;
}
