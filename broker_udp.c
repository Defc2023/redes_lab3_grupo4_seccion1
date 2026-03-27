/*
 * broker_udp.c - Broker UDP para sistema de noticias deportivas (pub-sub)
 *
 * Descripcion:
 *   Actua como intermediario central usando datagramas UDP.
 *   Recibe mensajes de publicadores y los redistribuye a suscriptores.
 *   No hay conexion persistente: cada mensaje es un datagrama independiente.
 *
 * Protocolo (mensajes en datagramas UDP):
 *   Publisher  -> Broker:  "PUBLISH|tema|mensaje"
 *   Subscriber -> Broker:  "SUBSCRIBE|tema"
 *   Broker     -> Subscriber: "[tema] mensaje"
 *
 * Uso: ./broker_udp <puerto>
 *   Ejemplo: ./broker_udp 5556
 *
 * Funciones de sockets utilizadas:
 *   socket()    - Crea el socket UDP (AF_INET, SOCK_DGRAM)
 *   bind()      - Asocia el socket a una direccion IP y puerto
 *   recvfrom()  - Recibe un datagrama y la direccion del remitente
 *   sendto()    - Envia un datagrama a una direccion especifica
 *   close()     - Cierra el socket
 *   setsockopt() - Configura opciones del socket (SO_REUSEADDR)
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <arpa/inet.h>
#include <sys/socket.h>

#define MAX_TOPICS         50
#define MAX_SUBS_PER_TOPIC 50
#define BUFFER_SIZE        1024
#define TOPIC_LEN          128

/* Estructura para almacenar la direccion de un suscriptor UDP */
typedef struct {
    struct sockaddr_in addr;
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
        fprintf(stderr, "[Broker] Limite de temas alcanzado\n");
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

/* Registra un suscriptor UDP para un tema */
static void subscribe(const struct sockaddr_in *sub_addr, const char *topic) {
    int idx = find_or_create_topic(topic);
    if (idx < 0) return;

    /* Verificar si ya esta suscrito */
    for (int i = 0; i < topics[idx].num_subs; i++) {
        if (addr_equal(&topics[idx].subscribers[i].addr, sub_addr))
            return;
    }
    if (topics[idx].num_subs >= MAX_SUBS_PER_TOPIC) {
        fprintf(stderr, "[Broker] Limite de suscriptores para '%s'\n", topic);
        return;
    }
    topics[idx].subscribers[topics[idx].num_subs].addr = *sub_addr;
    topics[idx].num_subs++;
    printf("[Broker] Suscriptor %s:%d suscrito a '%s'\n",
           inet_ntoa(sub_addr->sin_addr), ntohs(sub_addr->sin_port), topic);
}

/* Publica un mensaje a todos los suscriptores UDP de un tema */
static void publish(int sockfd, const char *topic, const char *message) {
    for (int i = 0; i < num_topics; i++) {
        if (strcmp(topics[i].topic, topic) == 0) {
            char buf[BUFFER_SIZE];
            int len = snprintf(buf, sizeof(buf), "[%s] %s", topic, message);
            printf("[Broker] Publicando en '%s': %s", topic, message);
            printf(" -> %d suscriptor(es)\n", topics[i].num_subs);
            for (int j = 0; j < topics[i].num_subs; j++) {
                /* sendto() envia el datagrama UDP al suscriptor */
                if (sendto(sockfd, buf, len, 0,
                           (struct sockaddr *)&topics[i].subscribers[j].addr,
                           sizeof(struct sockaddr_in)) < 0) {
                    perror("[Broker] Error sendto");
                }
            }
            return;
        }
    }
    printf("[Broker] Tema '%s' sin suscriptores\n", topic);
}

int main(int argc, char *argv[]) {
    if (argc != 2) {
        fprintf(stderr, "Uso: %s <puerto>\n", argv[0]);
        exit(EXIT_FAILURE);
    }

    int port = atoi(argv[1]);

    /* socket() crea un socket UDP (SOCK_DGRAM) en el dominio IPv4 (AF_INET)
     * A diferencia de TCP, UDP no es orientado a conexion */
    int sockfd = socket(AF_INET, SOCK_DGRAM, 0);
    if (sockfd < 0) {
        perror("socket");
        exit(EXIT_FAILURE);
    }

    /* setsockopt() con SO_REUSEADDR permite reutilizar el puerto */
    int opt = 1;
    setsockopt(sockfd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));

    /* Estructura sockaddr_in define la direccion del servidor */
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family      = AF_INET;       /* Familia IPv4 */
    addr.sin_addr.s_addr = INADDR_ANY;    /* Escuchar en todas las interfaces */
    addr.sin_port        = htons(port);   /* Puerto en network byte order */

    /* bind() asocia el socket UDP al puerto especificado */
    if (bind(sockfd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        perror("bind");
        close(sockfd);
        exit(EXIT_FAILURE);
    }

    printf("=== Broker UDP escuchando en puerto %d ===\n", port);

    char buffer[BUFFER_SIZE];

    while (1) {
        struct sockaddr_in sender_addr;
        socklen_t addrlen = sizeof(sender_addr);

        /* recvfrom() recibe un datagrama UDP y captura la direccion del remitente.
         * A diferencia de recv() en TCP, aqui no hay conexion previa */
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
            /* Formato: PUBLISH|tema|mensaje */
            char *topic = buffer + 8;
            char *sep = strchr(topic, '|');
            if (sep) {
                *sep = '\0';
                char *message = sep + 1;
                publish(sockfd, topic, message);
            }
        }
    }

    close(sockfd);
    return 0;
}
