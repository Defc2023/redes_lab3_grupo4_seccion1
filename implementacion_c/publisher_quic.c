/*
 * publisher_quic.c - Publicador hibrido QUIC para sistema de noticias deportivas
 *
 * Descripcion:
 *   Simula a un periodista deportivo que reporta eventos de un partido.
 *   Usa sockets UDP pero implementa confiabilidad tipo QUIC:
 *     1. ACKs: espera confirmacion del broker para cada mensaje.
 *     2. Retransmision: reenvia si no recibe ACK dentro del timeout.
 *     3. Orden: cada mensaje lleva un numero de secuencia incremental.
 *
 * Protocolo:
 *   Publisher -> Broker: "PUBLISH|seq|tema|mensaje"
 *   Broker -> Publisher: "ACK|seq"
 *
 * Uso: ./publisher_quic <ip_broker> <puerto_broker> <tema>
 *   Ejemplo: ./publisher_quic 127.0.0.1 5557 "EquipoE_vs_EquipoF"
 *
 * Funciones de sockets utilizadas:
 *   socket()    - Crea el socket UDP (AF_INET, SOCK_DGRAM)
 *   sendto()    - Envia un datagrama UDP al broker
 *   recvfrom()  - Recibe el ACK del broker
 *   select()    - Espera con timeout para detectar falta de ACK
 *   close()     - Cierra el socket
 *   inet_pton() - Convierte direccion IP de texto a formato binario
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <arpa/inet.h>
#include <sys/socket.h>
#include <sys/select.h>
#include <sys/time.h>

#define BUFFER_SIZE    1024
#define ACK_TIMEOUT_MS 500   /* Timeout en milisegundos para esperar ACK */
#define MAX_RETRIES    3     /* Maximo de reintentos si no llega ACK */

/* Mensajes deportivos predefinidos para simular un partido */
static const char *eventos[] = {
    "Inicio del partido!",
    "Gol de Equipo E al minuto 3 - Marcador 1-0",
    "Tarjeta amarilla al numero 10 de Equipo F",
    "Tiro libre peligroso para Equipo F al minuto 20",
    "Cambio: jugador 7 entra por jugador 3 en Equipo E",
    "Gol de Equipo F al minuto 30 - Empate 1-1",
    "Fin del primer tiempo",
    "Inicio del segundo tiempo",
    "Penal para Equipo E al minuto 52",
    "Gol de penal de Equipo E al minuto 53 - Marcador 2-1",
    "Tarjeta roja al numero 5 de Equipo F al minuto 75",
    "Fin del partido - Resultado final: Equipo E 2 - Equipo F 1"
};

#define NUM_EVENTOS (sizeof(eventos) / sizeof(eventos[0]))

/*
 * Envia un mensaje al broker y espera su ACK con retransmision.
 * Retorna 0 si el ACK fue recibido, -1 si fallo tras todos los reintentos.
 */
static int reliable_publish(int sockfd, const struct sockaddr_in *broker_addr,
                            const char *msg, int msg_len, int seq) {
    char ack_buf[BUFFER_SIZE];
    char expected_ack[64];
    snprintf(expected_ack, sizeof(expected_ack), "ACK|%d", seq);

    for (int attempt = 0; attempt < MAX_RETRIES; attempt++) {
        /* sendto() envia el datagrama UDP al broker */
        if (sendto(sockfd, msg, msg_len, 0,
                   (struct sockaddr *)broker_addr, sizeof(struct sockaddr_in)) < 0) {
            perror("sendto");
            return -1;
        }

        if (attempt > 0) {
            printf("[Pub QUIC] Retransmision #%d para seq=%d\n", attempt, seq);
        }

        /* select() con timeout para esperar el ACK del broker */
        fd_set readfds;
        FD_ZERO(&readfds);
        FD_SET(sockfd, &readfds);

        struct timeval tv;
        tv.tv_sec  = ACK_TIMEOUT_MS / 1000;
        tv.tv_usec = (ACK_TIMEOUT_MS % 1000) * 1000;

        int ready = select(sockfd + 1, &readfds, NULL, NULL, &tv);
        if (ready > 0) {
            struct sockaddr_in sender;
            socklen_t slen = sizeof(sender);
            int n = recvfrom(sockfd, ack_buf, sizeof(ack_buf) - 1, 0,
                             (struct sockaddr *)&sender, &slen);
            if (n > 0) {
                ack_buf[n] = '\0';
                if (strcmp(ack_buf, expected_ack) == 0) {
                    return 0; /* ACK recibido correctamente */
                }
            }
        }
        /* Timeout: no se recibio ACK, reintentar */
        printf("[Pub QUIC] Timeout esperando ACK para seq=%d\n", seq);
    }

    printf("[Pub QUIC] FALLO: sin ACK tras %d intentos para seq=%d\n",
           MAX_RETRIES, seq);
    return -1;
}

int main(int argc, char *argv[]) {
    if (argc != 4) {
        fprintf(stderr, "Uso: %s <ip_broker> <puerto> <tema>\n", argv[0]);
        fprintf(stderr, "Ejemplo: %s 127.0.0.1 5557 EquipoE_vs_EquipoF\n", argv[0]);
        exit(EXIT_FAILURE);
    }

    const char *broker_ip = argv[1];
    int port = atoi(argv[2]);
    const char *topic = argv[3];

    /* socket() crea un socket UDP (SOCK_DGRAM) en el dominio IPv4 (AF_INET).
     * Usamos UDP como transporte base, pero implementamos confiabilidad
     * a nivel de aplicacion (similar a QUIC sobre UDP). */
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

    printf("=== Publisher QUIC (hibrido) enviando al broker %s:%d ===\n",
           broker_ip, port);
    printf("Tema: %s\n", topic);
    printf("Confiabilidad: ACKs + Retransmision + Seq numbers\n");
    printf("Enviando %lu eventos...\n\n", (unsigned long)NUM_EVENTOS);

    int acked = 0, failed = 0;

    /* Enviar cada evento deportivo al broker con confiabilidad */
    for (int i = 0; i < (int)NUM_EVENTOS; i++) {
        int seq = i + 1; /* Numero de secuencia incremental */
        char buf[BUFFER_SIZE];
        /* Formato con numero de secuencia: PUBLISH|seq|tema|mensaje */
        int len = snprintf(buf, sizeof(buf), "PUBLISH|%d|%s|%s",
                           seq, topic, eventos[i]);

        printf("[Pub %s] Evento %d (seq=%d): %s\n", topic, i + 1, seq, eventos[i]);

        /* Envio confiable: espera ACK, reintenta si es necesario */
        int result = reliable_publish(sockfd, &broker_addr, buf, len, seq);
        if (result == 0) {
            printf("[Pub QUIC] ACK recibido para seq=%d\n\n", seq);
            acked++;
        } else {
            printf("[Pub QUIC] Mensaje seq=%d no confirmado\n\n", seq);
            failed++;
        }

        /* Pausa de 2 segundos entre mensajes para simular tiempo real */
        sleep(2);
    }

    printf("\n[Publisher QUIC] Resumen: %d/%lu mensajes confirmados, %d fallidos\n",
           acked, (unsigned long)NUM_EVENTOS, failed);

    /* close() cierra el socket UDP */
    close(sockfd);
    return 0;
}
