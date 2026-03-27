/*
 * subscriber_quic.c - Suscriptor hibrido QUIC para sistema de noticias deportivas
 *
 * Descripcion:
 *   Simula a un hincha que sigue partidos en vivo usando UDP con confiabilidad.
 *   Implementa caracteristicas tipo QUIC:
 *     1. ACKs: envia confirmacion al broker por cada mensaje recibido.
 *     2. Orden: verifica numeros de secuencia para detectar mensajes
 *        fuera de orden o perdidos.
 *
 * Protocolo:
 *   Subscriber -> Broker: "SUBSCRIBE|tema"
 *   Broker -> Subscriber: "MSG|seq|[tema] mensaje"
 *   Subscriber -> Broker: "ACK|seq"
 *
 * Uso: ./subscriber_quic <ip_broker> <puerto_broker> <tema1> [tema2] ...
 *   Ejemplo: ./subscriber_quic 127.0.0.1 5557 EquipoE_vs_EquipoF
 *
 * Funciones de sockets utilizadas:
 *   socket()    - Crea el socket UDP (AF_INET, SOCK_DGRAM)
 *   sendto()    - Envia suscripcion y ACKs al broker
 *   recvfrom()  - Recibe mensajes del broker
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
        fprintf(stderr, "Ejemplo: %s 127.0.0.1 5557 EquipoE_vs_EquipoF\n", argv[0]);
        exit(EXIT_FAILURE);
    }

    const char *broker_ip = argv[1];
    int port = atoi(argv[2]);

    /* socket() crea un socket UDP (SOCK_DGRAM) en el dominio IPv4 (AF_INET).
     * Usamos UDP como transporte base pero participamos en el protocolo
     * de confiabilidad enviando ACKs al broker. */
    int sockfd = socket(AF_INET, SOCK_DGRAM, 0);
    if (sockfd < 0) {
        perror("socket");
        exit(EXIT_FAILURE);
    }

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

    printf("=== Subscriber QUIC (hibrido) conectado al broker %s:%d ===\n",
           broker_ip, port);
    printf("Confiabilidad: ACKs + verificacion de orden (seq numbers)\n\n");

    /* Enviar solicitudes de suscripcion a cada tema */
    for (int i = 3; i < argc; i++) {
        char buf[BUFFER_SIZE];
        int len = snprintf(buf, sizeof(buf), "SUBSCRIBE|%s", argv[i]);

        /* sendto() envia la solicitud de suscripcion como datagrama UDP */
        if (sendto(sockfd, buf, len, 0,
                   (struct sockaddr *)&broker_addr, sizeof(broker_addr)) < 0) {
            perror("sendto");
            close(sockfd);
            exit(EXIT_FAILURE);
        }
        printf("[Sub QUIC] Solicitud de suscripcion enviada: %s\n", argv[i]);
    }

    printf("\nEsperando actualizaciones en vivo...\n\n");

    char buffer[BUFFER_SIZE];
    int msg_count = 0;
    int expected_seq = 1;  /* Proximo numero de secuencia esperado */
    int out_of_order = 0;  /* Contador de mensajes fuera de orden */
    int duplicates = 0;    /* Contador de duplicados (retransmisiones) */

    /* Bucle principal: recibir mensajes y enviar ACKs */
    while (1) {
        struct sockaddr_in sender_addr;
        socklen_t addrlen = sizeof(sender_addr);

        /* recvfrom() recibe un datagrama UDP del broker */
        int n = recvfrom(sockfd, buffer, sizeof(buffer) - 1, 0,
                         (struct sockaddr *)&sender_addr, &addrlen);
        if (n < 0) {
            perror("recvfrom");
            continue;
        }

        buffer[n] = '\0';

        /* Verificar que es un mensaje con formato MSG|seq|contenido */
        if (strncmp(buffer, "MSG|", 4) == 0) {
            char *seq_str = buffer + 4;
            char *sep = strchr(seq_str, '|');
            if (sep) {
                *sep = '\0';
                int seq = atoi(seq_str);
                char *content = sep + 1;

                /* Enviar ACK al broker para confirmar recepcion */
                char ack[64];
                int ack_len = snprintf(ack, sizeof(ack), "ACK|%d", seq);
                sendto(sockfd, ack, ack_len, 0,
                       (struct sockaddr *)&sender_addr, sizeof(sender_addr));

                /* Verificar orden de secuencia */
                if (seq < expected_seq) {
                    /* Mensaje duplicado (retransmision), ya lo procesamos */
                    duplicates++;
                    printf("  [DUP] seq=%d (ya recibido) %s\n", seq, content);
                    continue;
                }

                if (seq > expected_seq) {
                    /* Mensaje fuera de orden o hubo perdida */
                    out_of_order++;
                    printf("  [FUERA DE ORDEN] Esperado seq=%d, recibido seq=%d\n",
                           expected_seq, seq);
                }

                msg_count++;
                printf("  #%d (seq=%d) %s\n", msg_count, seq, content);
                expected_seq = seq + 1;
            }
        }
    }

    printf("\n[Sub QUIC] Resumen: %d mensajes, %d fuera de orden, %d duplicados\n",
           msg_count, out_of_order, duplicates);

    /* close() cierra el socket UDP */
    close(sockfd);
    return 0;
}
