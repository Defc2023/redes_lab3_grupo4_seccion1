/*
 * broker_quic.c - Broker hibrido QUIC para sistema de noticias deportivas (pub-sub)
 *
 * Descripcion:
 *   Actua como intermediario central usando sockets UDP pero implementando
 *   caracteristicas de confiabilidad inspiradas en QUIC:
 *     1. ACKs: cada mensaje genera una confirmacion de recepcion.
 *     2. Retransmision: si no llega un ACK en un tiempo definido, se reenvia.
 *     3. Orden: los mensajes incluyen numeros de secuencia.
 *
 * Protocolo (mensajes en datagramas UDP con confiabilidad):
 *   Publisher  -> Broker:     "PUBLISH|seq|tema|mensaje"
 *   Broker     -> Publisher:  "ACK|seq"
 *   Subscriber -> Broker:     "SUBSCRIBE|tema"
 *   Broker     -> Subscriber: "MSG|seq|[tema] mensaje"
 *   Subscriber -> Broker:     "ACK|seq"
 *
 * Uso: ./broker_quic <puerto>
 *   Ejemplo: ./broker_quic 5557
 *
 * Funciones de sockets utilizadas:
 *   socket()     - Crea el socket UDP (AF_INET, SOCK_DGRAM)
 *   bind()       - Asocia el socket a una direccion IP y puerto
 *   recvfrom()   - Recibe un datagrama y la direccion del remitente
 *   sendto()     - Envia un datagrama a una direccion especifica
 *   select()     - Espera actividad con timeout para detectar falta de ACKs
 *   close()      - Cierra el socket
 *   setsockopt() - Configura opciones del socket (SO_REUSEADDR)
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <arpa/inet.h>
#include <sys/socket.h>
#include <sys/select.h>
#include <sys/time.h>
#include <errno.h>

#define MAX_TOPICS         50
#define MAX_SUBS_PER_TOPIC 50
#define BUFFER_SIZE        1024
#define TOPIC_LEN          128
#define ACK_TIMEOUT_MS     500   /* Timeout en milisegundos para esperar ACK */
#define MAX_RETRIES        3     /* Maximo de reintentos antes de descartar */

/* Estructura para almacenar la direccion de un suscriptor UDP */
typedef struct {
    struct sockaddr_in addr;
    int next_seq;  /* Proximo numero de secuencia para este suscriptor */
} SubscriberAddr;

/* Estructura para almacenar suscripciones por tema */
typedef struct {
    char           topic[TOPIC_LEN];
    SubscriberAddr subscribers[MAX_SUBS_PER_TOPIC];
    int            num_subs;
} TopicEntry;

static TopicEntry topics[MAX_TOPICS];
static int num_topics = 0;

/* Busca un tema existente o crea uno nuevo */
static int find_or_create_topic(const char *topic) {
    for (int i = 0; i < num_topics; i++) {
        if (strcmp(topics[i].topic, topic) == 0)
            return i;
    }
    if (num_topics >= MAX_TOPICS) {
        fprintf(stderr, "[Broker QUIC] Limite de temas alcanzado\n");
        return -1;
    }
    strncpy(topics[num_topics].topic, topic, TOPIC_LEN - 1);
    topics[num_topics].topic[TOPIC_LEN - 1] = '\0';
    topics[num_topics].num_subs = 0;
    return num_topics++;
}

/* Compara dos direcciones sockaddr_in (IP + puerto) */
static int addr_equal(const struct sockaddr_in *a, const struct sockaddr_in *b) {
    return (a->sin_addr.s_addr == b->sin_addr.s_addr) &&
           (a->sin_port == b->sin_port);
}

/* Registra un suscriptor para un tema */
static void subscribe(const struct sockaddr_in *sub_addr, const char *topic) {
    int idx = find_or_create_topic(topic);
    if (idx < 0) return;

    /* Verificar si ya esta suscrito */
    for (int i = 0; i < topics[idx].num_subs; i++) {
        if (addr_equal(&topics[idx].subscribers[i].addr, sub_addr))
            return;
    }
    if (topics[idx].num_subs >= MAX_SUBS_PER_TOPIC) {
        fprintf(stderr, "[Broker QUIC] Limite de suscriptores para '%s'\n", topic);
        return;
    }
    topics[idx].subscribers[topics[idx].num_subs].addr = *sub_addr;
    topics[idx].subscribers[topics[idx].num_subs].next_seq = 1;
    topics[idx].num_subs++;
    printf("[Broker QUIC] Suscriptor %s:%d suscrito a '%s'\n",
           inet_ntoa(sub_addr->sin_addr), ntohs(sub_addr->sin_port), topic);
}

/*
 * Envia un mensaje a un suscriptor con retransmision confiable.
 * Espera un ACK con el numero de secuencia correcto.
 * Reintenta hasta MAX_RETRIES veces si no recibe ACK.
 */
static int reliable_send(int sockfd, const char *msg, int msg_len,
                         const struct sockaddr_in *dest, int seq) {
    char ack_buf[BUFFER_SIZE];
    char expected_ack[64];
    int ack_len = snprintf(expected_ack, sizeof(expected_ack), "ACK|%d", seq);

    for (int attempt = 0; attempt < MAX_RETRIES; attempt++) {
        /* sendto() envia el datagrama UDP al suscriptor */
        if (sendto(sockfd, msg, msg_len, 0,
                   (struct sockaddr *)dest, sizeof(struct sockaddr_in)) < 0) {
            perror("[Broker QUIC] Error sendto");
            return -1;
        }

        if (attempt > 0) {
            printf("[Broker QUIC] Retransmision #%d para seq=%d a %s:%d\n",
                   attempt, seq,
                   inet_ntoa(dest->sin_addr), ntohs(dest->sin_port));
        }

        /* select() con timeout para esperar el ACK del suscriptor */
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
                /* Verificar que el ACK corresponde al seq esperado */
                if (strcmp(ack_buf, expected_ack) == 0 &&
                    addr_equal(&sender, dest)) {
                    return 0; /* ACK recibido correctamente */
                }
                /* Si recibimos otro mensaje (SUBSCRIBE, PUBLISH), lo ignoramos
                 * en este contexto simplificado. En QUIC real se procesaria. */
            }
        }
        /* Timeout: no se recibio ACK, reintentar */
    }

    printf("[Broker QUIC] Sin ACK tras %d intentos para seq=%d a %s:%d\n",
           MAX_RETRIES, seq,
           inet_ntoa(dest->sin_addr), ntohs(dest->sin_port));
    return -1;
}

/* Publica un mensaje a todos los suscriptores de un tema con confiabilidad */
static void publish(int sockfd, const char *topic, const char *message) {
    for (int i = 0; i < num_topics; i++) {
        if (strcmp(topics[i].topic, topic) == 0) {
            printf("[Broker QUIC] Publicando en '%s': %s", topic, message);
            printf(" -> %d suscriptor(es)\n", topics[i].num_subs);

            for (int j = 0; j < topics[i].num_subs; j++) {
                int seq = topics[i].subscribers[j].next_seq++;
                char buf[BUFFER_SIZE];
                /* Formato con numero de secuencia: MSG|seq|[tema] mensaje */
                int len = snprintf(buf, sizeof(buf), "MSG|%d|[%s] %s",
                                   seq, topic, message);

                int result = reliable_send(sockfd, buf, len,
                                           &topics[i].subscribers[j].addr, seq);
                if (result == 0) {
                    printf("[Broker QUIC] ACK recibido de %s:%d para seq=%d\n",
                           inet_ntoa(topics[i].subscribers[j].addr.sin_addr),
                           ntohs(topics[i].subscribers[j].addr.sin_port), seq);
                }
            }
            return;
        }
    }
    printf("[Broker QUIC] Tema '%s' sin suscriptores\n", topic);
}

int main(int argc, char *argv[]) {
    if (argc != 2) {
        fprintf(stderr, "Uso: %s <puerto>\n", argv[0]);
        exit(EXIT_FAILURE);
    }

    int port = atoi(argv[1]);

    /* socket() crea un socket UDP (SOCK_DGRAM) en el dominio IPv4 (AF_INET).
     * Aunque usamos UDP, implementamos confiabilidad a nivel de aplicacion
     * de forma similar a como lo hace el protocolo QUIC. */
    int sockfd = socket(AF_INET, SOCK_DGRAM, 0);
    if (sockfd < 0) {
        perror("socket");
        exit(EXIT_FAILURE);
    }

    /* setsockopt() con SO_REUSEADDR permite reutilizar el puerto */
    int opt = 1;
    setsockopt(sockfd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family      = AF_INET;
    addr.sin_addr.s_addr = INADDR_ANY;
    addr.sin_port        = htons(port);

    /* bind() asocia el socket UDP al puerto especificado */
    if (bind(sockfd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        perror("bind");
        close(sockfd);
        exit(EXIT_FAILURE);
    }

    printf("=== Broker QUIC (hibrido) escuchando en puerto %d ===\n", port);
    printf("    Confiabilidad: ACKs + Retransmision + Orden (seq numbers)\n\n");

    char buffer[BUFFER_SIZE];

    while (1) {
        struct sockaddr_in sender_addr;
        socklen_t addrlen = sizeof(sender_addr);

        /* recvfrom() recibe un datagrama UDP y captura la direccion del remitente */
        int n = recvfrom(sockfd, buffer, sizeof(buffer) - 1, 0,
                         (struct sockaddr *)&sender_addr, &addrlen);
        if (n < 0) {
            perror("recvfrom");
            continue;
        }

        buffer[n] = '\0';

        /* Eliminar salto de linea si existe */
        char *nl = strchr(buffer, '\n');
        if (nl) *nl = '\0';

        if (strncmp(buffer, "SUBSCRIBE|", 10) == 0) {
            /* Formato: SUBSCRIBE|tema */
            char *topic = buffer + 10;
            subscribe(&sender_addr, topic);

        } else if (strncmp(buffer, "PUBLISH|", 8) == 0) {
            /* Formato: PUBLISH|seq|tema|mensaje */
            char *seq_str = buffer + 8;
            char *sep1 = strchr(seq_str, '|');
            if (sep1) {
                *sep1 = '\0';
                int pub_seq = atoi(seq_str);
                char *topic = sep1 + 1;
                char *sep2 = strchr(topic, '|');
                if (sep2) {
                    *sep2 = '\0';
                    char *message = sep2 + 1;

                    printf("[Broker QUIC] Recibido PUBLISH seq=%d de %s:%d\n",
                           pub_seq,
                           inet_ntoa(sender_addr.sin_addr),
                           ntohs(sender_addr.sin_port));

                    /* Enviar ACK al publicador para confirmar recepcion */
                    char ack[64];
                    int ack_len = snprintf(ack, sizeof(ack), "ACK|%d", pub_seq);
                    sendto(sockfd, ack, ack_len, 0,
                           (struct sockaddr *)&sender_addr, sizeof(sender_addr));
                    printf("[Broker QUIC] ACK enviado al publisher para seq=%d\n",
                           pub_seq);

                    /* Distribuir a suscriptores con confiabilidad */
                    publish(sockfd, topic, message);
                }
            }
        }
        /* Los ACK de suscriptores se procesan dentro de reliable_send() */
    }

    close(sockfd);
    return 0;
}
