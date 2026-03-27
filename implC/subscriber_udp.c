/*
 * subscriber_udp.c - Suscriptor UDP para sistema de noticias deportivas
 *
 * Descripcion:
 *   Simula a un hincha que sigue partidos en vivo usando UDP.
 *   Envia solicitudes de suscripcion al broker y recibe actualizaciones
 *   como datagramas independientes. No hay conexion persistente.
 *
 * Protocolo: Envia "SUBSCRIBE|tema" al broker via UDP.
 *            Recibe "[tema] mensaje" del broker.
 *
 * Uso: ./subscriber_udp <ip_broker> <puerto_broker> <tema1> [tema2] ...
 *   Ejemplo: ./subscriber_udp 127.0.0.1 5556 EquipoC_vs_EquipoD
 *
 * Funciones de sockets utilizadas:
 *   socket()    - Crea el socket UDP (AF_INET, SOCK_DGRAM)
 *   sendto()    - Envia solicitud de suscripcion al broker
 *   recvfrom()  - Recibe datagramas del broker (mensajes de noticias)
 *   close()     - Cierra el socket
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
        fprintf(stderr, "Ejemplo: %s 127.0.0.1 5556 EquipoC_vs_EquipoD\n", argv[0]);
        exit(EXIT_FAILURE);
    }

    const char *broker_ip = argv[1];
    int port = atoi(argv[2]);

    /* socket() crea un socket UDP (SOCK_DGRAM) en el dominio IPv4 (AF_INET)
     * UDP no requiere conexion previa para enviar/recibir datos */
    int sockfd = socket(AF_INET, SOCK_DGRAM, 0);
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

    printf("=== Subscriber UDP conectado al broker %s:%d ===\n", broker_ip, port);

    /* Enviar solicitudes de suscripcion a cada tema */
    for (int i = 3; i < argc; i++) {
        char buf[BUFFER_SIZE];
        /* Formato: SUBSCRIBE|tema */
        int len = snprintf(buf, sizeof(buf), "SUBSCRIBE|%s", argv[i]);

        /* sendto() envia la solicitud de suscripcion como datagrama UDP.
         * No hay garantia de que el broker reciba esta solicitud. */
        if (sendto(sockfd, buf, len, 0,
                   (struct sockaddr *)&broker_addr, sizeof(broker_addr)) < 0) {
            perror("sendto");
            close(sockfd);
            exit(EXIT_FAILURE);
        }
        printf("[Sub] Solicitud de suscripcion enviada: %s\n", argv[i]);
    }

    printf("\nEsperando actualizaciones en vivo...\n\n");

    /* Bucle principal: recibir datagramas del broker */
    char buffer[BUFFER_SIZE];
    int msg_count = 0;

    while (1) {
        struct sockaddr_in sender_addr;
        socklen_t addrlen = sizeof(sender_addr);

        /* recvfrom() recibe un datagrama UDP del broker.
         * Cada datagrama es independiente; no hay garantia de orden ni entrega.
         * Si un paquete se pierde en la red, recvfrom() simplemente no lo recibe. */
        int n = recvfrom(sockfd, buffer, sizeof(buffer) - 1, 0,
                         (struct sockaddr *)&sender_addr, &addrlen);
        if (n < 0) {
            perror("recvfrom");
            continue;
        }

        buffer[n] = '\0';
        msg_count++;
        printf("  #%d %s\n", msg_count, buffer);
    }

    printf("[Sub] Total de mensajes recibidos: %d\n", msg_count);

    /* close() cierra el socket UDP */
    close(sockfd);
    return 0;
}
