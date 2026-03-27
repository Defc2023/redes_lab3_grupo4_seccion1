/*
 * subscriber_tcp.c - Suscriptor TCP para sistema de noticias deportivas
 *
 * Descripcion:
 *   Simula a un hincha que sigue uno o varios partidos en vivo.
 *   Se conecta al broker TCP, se suscribe a uno o mas temas (partidos)
 *   y recibe las actualizaciones en tiempo real.
 *
 * Protocolo: Envia "SUBSCRIBE|tema\n" al broker para cada tema.
 *            Recibe "[tema] mensaje\n" del broker.
 *
 * Uso: ./subscriber_tcp <ip_broker> <puerto_broker> <tema1> [tema2] ...
 *   Ejemplo: ./subscriber_tcp 127.0.0.1 5555 EquipoA_vs_EquipoB EquipoC_vs_EquipoD
 *
 * Funciones de sockets utilizadas:
 *   socket()  - Crea el socket TCP (AF_INET, SOCK_STREAM)
 *   connect() - Establece conexion TCP con el broker (three-way handshake)
 *   send()    - Envia la solicitud de suscripcion al broker
 *   recv()    - Recibe mensajes del broker
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

int main(int argc, char *argv[]) {
    if (argc < 4) {
        fprintf(stderr, "Uso: %s <ip_broker> <puerto> <tema1> [tema2] ...\n", argv[0]);
        fprintf(stderr, "Ejemplo: %s 127.0.0.1 5555 EquipoA_vs_EquipoB\n", argv[0]);
        exit(EXIT_FAILURE);
    }

    const char *broker_ip = argv[1];
    int port = atoi(argv[2]);

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

    /* inet_pton() convierte la IP de texto a formato binario de red */
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

    printf("=== Subscriber TCP conectado al broker %s:%d ===\n", broker_ip, port);

    /* Suscribirse a cada tema proporcionado como argumento */
    for (int i = 3; i < argc; i++) {
        char buf[BUFFER_SIZE];
        /* Formato: SUBSCRIBE|tema\n */
        int len = snprintf(buf, sizeof(buf), "SUBSCRIBE|%s\n", argv[i]);

        /* send() envia la solicitud de suscripcion por TCP */
        if (send(sockfd, buf, len, 0) < 0) {
            perror("send");
            close(sockfd);
            exit(EXIT_FAILURE);
        }
        printf("[Sub] Suscrito a: %s\n", argv[i]);
    }

    printf("\nEsperando actualizaciones en vivo...\n\n");

    /* Bucle principal: recibir y mostrar mensajes del broker */
    char buffer[BUFFER_SIZE];
    int msg_count = 0;

    while (1) {
        /* recv() recibe datos del broker a traves de la conexion TCP */
        int n = recv(sockfd, buffer, sizeof(buffer) - 1, 0);
        if (n <= 0) {
            if (n == 0)
                printf("\n[Sub] Broker desconectado.\n");
            else
                perror("recv");
            break;
        }

        buffer[n] = '\0';

        /* Mostrar cada linea recibida con un contador */
        char *line = strtok(buffer, "\n");
        while (line != NULL) {
            msg_count++;
            printf("  #%d %s\n", msg_count, line);
            line = strtok(NULL, "\n");
        }
    }

    printf("[Sub] Total de mensajes recibidos: %d\n", msg_count);

    /* close() cierra la conexion TCP */
    close(sockfd);
    return 0;
}
