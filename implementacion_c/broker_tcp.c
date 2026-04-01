/*
 * broker_tcp.c - Broker TCP para sistema de noticias deportivas (pub-sub)
 *
 * Descripcion:
 *   Actua como intermediario central. Recibe mensajes de publicadores
 *   y los redistribuye a los suscriptores interesados en cada tema (partido).
 *
 * Protocolo (mensajes delimitados por '\n'):
 *   Publisher  -> Broker:  "PUBLISH|tema|mensaje\n"
 *   Subscriber -> Broker:  "SUBSCRIBE|tema\n"
 *   Broker     -> Subscriber: "[tema] mensaje\n"
 *
 * Uso: ./broker_tcp <puerto>
 *   Ejemplo: ./broker_tcp 5555
 *
 * Funciones de sockets utilizadas:
 *   socket()   - Crea el socket TCP (AF_INET, SOCK_STREAM)
 *   bind()     - Asocia el socket a una direccion IP y puerto
 *   listen()   - Pone el socket en modo escucha para conexiones entrantes
 *   accept()   - Acepta una nueva conexion de un cliente
 *   recv()     - Recibe datos de un cliente conectado
 *   send()     - Envia datos a un cliente conectado
 *   close()    - Cierra un socket
 *   select()   - Multiplexa E/S para manejar multiples clientes simultaneamente
 *   setsockopt() - Configura opciones del socket (SO_REUSEADDR)
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <arpa/inet.h>
#include <sys/socket.h>
#include <sys/select.h>

#define MAX_CLIENTS   100
#define MAX_TOPICS    50
#define MAX_SUBS_PER_TOPIC 50
#define BUFFER_SIZE   1024
#define TOPIC_LEN     128

/* Estructura para almacenar suscripciones: cada tema tiene una lista de file descriptors */
typedef struct {
    char topic[TOPIC_LEN];
    int  subscribers[MAX_SUBS_PER_TOPIC];
    int  num_subs;
} TopicEntry;

static TopicEntry topics[MAX_TOPICS];
static int num_topics = 0;

/* Busca un tema existente o crea uno nuevo. Retorna el indice en el arreglo topics[] */
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

/* Suscribe un file descriptor a un tema */
static void subscribe(int fd, const char *topic) {
    int idx = find_or_create_topic(topic);
    if (idx < 0) return;

    /* Verificar si ya esta suscrito */
    for (int i = 0; i < topics[idx].num_subs; i++) {
        if (topics[idx].subscribers[i] == fd) return;
    }
    if (topics[idx].num_subs >= MAX_SUBS_PER_TOPIC) {
        fprintf(stderr, "[Broker] Limite de suscriptores para '%s'\n", topic);
        return;
    }
    topics[idx].subscribers[topics[idx].num_subs++] = fd;
    printf("[Broker] Cliente fd=%d suscrito a '%s'\n", fd, topic);
}

/* Publica un mensaje a todos los suscriptores de un tema */
static void publish(const char *topic, const char *message) {
    for (int i = 0; i < num_topics; i++) {
        if (strcmp(topics[i].topic, topic) == 0) {
            char buf[BUFFER_SIZE];
            int len = snprintf(buf, sizeof(buf), "[%s] %s\n", topic, message);
            printf("[Broker] Publicando en '%s': %s", topic, message);
            printf(" -> %d suscriptor(es)\n", topics[i].num_subs);
            for (int j = 0; j < topics[i].num_subs; j++) {
                /* send() envia los datos por el socket TCP al suscriptor */
                if (send(topics[i].subscribers[j], buf, len, 0) < 0) {
                    perror("[Broker] Error enviando a suscriptor");
                }
            }
            return;
        }
    }
    printf("[Broker] Tema '%s' sin suscriptores\n", topic);
}

/* Elimina un fd de todas las suscripciones (cuando se desconecta) */
static void remove_subscriber(int fd) {
    for (int i = 0; i < num_topics; i++) {
        for (int j = 0; j < topics[i].num_subs; j++) {
            if (topics[i].subscribers[j] == fd) {
                topics[i].subscribers[j] = topics[i].subscribers[--topics[i].num_subs];
                printf("[Broker] Cliente fd=%d removido de '%s'\n", fd, topics[i].topic);
                break;
            }
        }
    }
}

/* Procesa un mensaje completo recibido de un cliente */
static void process_message(int fd, char *msg) {
    /* Eliminar salto de linea */
    char *nl = strchr(msg, '\n');
    if (nl) *nl = '\0';
    char *cr = strchr(msg, '\r');
    if (cr) *cr = '\0';

    if (strncmp(msg, "SUBSCRIBE|", 10) == 0) {
        /* Formato: SUBSCRIBE|tema */
        char *topic = msg + 10;
        subscribe(fd, topic);
    } else if (strncmp(msg, "PUBLISH|", 8) == 0) {
        /* Formato: PUBLISH|tema|mensaje */
        char *topic = msg + 8;
        char *sep = strchr(topic, '|');
        if (sep) {
            *sep = '\0';
            char *message = sep + 1;
            publish(topic, message);
        }
    }
}

int main(int argc, char *argv[]) {
    if (argc != 2) {
        fprintf(stderr, "Uso: %s <puerto>\n", argv[0]);
        exit(EXIT_FAILURE);
    }

    int port = atoi(argv[1]);

    /* socket() crea un socket TCP (SOCK_STREAM) en el dominio IPv4 (AF_INET) */
    int server_fd = socket(AF_INET, SOCK_STREAM, 0);
    if (server_fd < 0) {
        perror("socket");
        exit(EXIT_FAILURE);
    }

    /* setsockopt() con SO_REUSEADDR permite reutilizar el puerto inmediatamente */
    int opt = 1;
    setsockopt(server_fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));

    /* Estructura sockaddr_in define la direccion del servidor */
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family      = AF_INET;       /* Familia IPv4 */
    addr.sin_addr.s_addr = INADDR_ANY;    /* Escuchar en todas las interfaces */
    addr.sin_port        = htons(port);   /* Puerto en network byte order */

    /* bind() asocia el socket al puerto y direccion especificados */
    if (bind(server_fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        perror("bind");
        close(server_fd);
        exit(EXIT_FAILURE);
    }

    /* listen() pone el socket en modo pasivo, esperando conexiones entrantes */
    if (listen(server_fd, 10) < 0) {
        perror("listen");
        close(server_fd);
        exit(EXIT_FAILURE);
    }

    printf("=== Broker TCP escuchando en puerto %d ===\n", port);

    /* Arreglo de clientes conectados y sus buffers parciales */
    int    clients[MAX_CLIENTS];
    char   client_buf[MAX_CLIENTS][BUFFER_SIZE];
    int    client_buf_len[MAX_CLIENTS];
    int    num_clients = 0;

    memset(client_buf_len, 0, sizeof(client_buf_len));

    while (1) {
        /* select() permite monitorear multiples file descriptors simultaneamente */
        fd_set readfds;
        FD_ZERO(&readfds);
        FD_SET(server_fd, &readfds);
        int maxfd = server_fd;

        for (int i = 0; i < num_clients; i++) {
            FD_SET(clients[i], &readfds);
            if (clients[i] > maxfd) maxfd = clients[i];
        }

        /* select() bloquea hasta que haya actividad en algun socket */
        int activity = select(maxfd + 1, &readfds, NULL, NULL, NULL);
        if (activity < 0) {
            perror("select");
            break;
        }

        /* Verificar si hay una nueva conexion entrante */
        if (FD_ISSET(server_fd, &readfds)) {
            struct sockaddr_in client_addr;
            socklen_t addrlen = sizeof(client_addr);

            /* accept() acepta la conexion entrante y retorna un nuevo socket */
            int new_fd = accept(server_fd, (struct sockaddr *)&client_addr, &addrlen);
            if (new_fd >= 0) {
                if (num_clients < MAX_CLIENTS) {
                    clients[num_clients] = new_fd;
                    client_buf_len[num_clients] = 0;
                    num_clients++;
                    printf("[Broker] Nueva conexion: fd=%d desde %s:%d\n",
                           new_fd,
                           inet_ntoa(client_addr.sin_addr),
                           ntohs(client_addr.sin_port));
                } else {
                    fprintf(stderr, "[Broker] Limite de clientes alcanzado\n");
                    close(new_fd);
                }
            }
        }

        /* Revisar datos de cada cliente conectado */
        for (int i = 0; i < num_clients; i++) {
            if (FD_ISSET(clients[i], &readfds)) {
                int space = BUFFER_SIZE - 1 - client_buf_len[i];

                /* recv() recibe datos del socket TCP del cliente */
                int n = recv(clients[i], client_buf[i] + client_buf_len[i], space, 0);
                if (n <= 0) {
                    /* Cliente desconectado */
                    printf("[Broker] Cliente fd=%d desconectado\n", clients[i]);
                    remove_subscriber(clients[i]);
                    close(clients[i]);
                    clients[i] = clients[num_clients - 1];
                    memcpy(client_buf[i], client_buf[num_clients - 1], BUFFER_SIZE);
                    client_buf_len[i] = client_buf_len[num_clients - 1];
                    num_clients--;
                    i--;
                    continue;
                }

                client_buf_len[i] += n;
                client_buf[i][client_buf_len[i]] = '\0';

                /* Procesar mensajes completos (delimitados por '\n') */
                char *start = client_buf[i];
                char *nl;
                while ((nl = strchr(start, '\n')) != NULL) {
                    *nl = '\0';
                    process_message(clients[i], start);
                    start = nl + 1;
                }

                /* Mover datos restantes al inicio del buffer */
                int remaining = client_buf_len[i] - (start - client_buf[i]);
                if (remaining > 0) {
                    memmove(client_buf[i], start, remaining);
                }
                client_buf_len[i] = remaining;
            }
        }
    }

    close(server_fd);
    return 0;
}
