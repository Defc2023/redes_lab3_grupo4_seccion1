/*
 * publisher_udp.c - Publicador UDP para sistema de noticias deportivas
 *
 * Descripcion:
 *   Simula a un periodista deportivo que reporta eventos de un partido.
 *   Envia datagramas UDP al broker con los eventos del partido.
 *   No hay conexion persistente: cada mensaje es un datagrama independiente.
 *
 * Protocolo: Envia "PUBLISH|tema|mensaje" al broker via UDP.
 *
 * Uso: ./publisher_udp <ip_broker> <puerto_broker> <tema>
 *   Ejemplo: ./publisher_udp 127.0.0.1 5556 "EquipoA_vs_EquipoB"
 *
 * Funciones de sockets utilizadas:
 *   socket()    - Crea el socket UDP (AF_INET, SOCK_DGRAM)
 *   sendto()    - Envia un datagrama UDP al broker (sin conexion previa)
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

/* Mensajes deportivos predefinidos para simular un partido */
static const char *eventos[] = {
    "Inicio del partido!",
    "Gol de Equipo C al minuto 5",
    "Tarjeta amarilla al numero 14 de Equipo D",
    "Falta peligrosa al minuto 15 en area de Equipo C",
    "Cambio: jugador 8 entra por jugador 6 en Equipo D",
    "Gol de Equipo D al minuto 28 - Empate 1-1",
    "Fin del primer tiempo",
    "Inicio del segundo tiempo",
    "Penal para Equipo C al minuto 55",
    "Gol de penal de Equipo C al minuto 56 - Marcador 2-1",
    "Tarjeta roja al numero 2 de Equipo D al minuto 70",
    "Fin del partido - Resultado final: Equipo C 2 - Equipo D 1"
};

#define NUM_EVENTOS (sizeof(eventos) / sizeof(eventos[0]))

int main(int argc, char *argv[]) {
    if (argc != 4) {
        fprintf(stderr, "Uso: %s <ip_broker> <puerto> <tema>\n", argv[0]);
        fprintf(stderr, "Ejemplo: %s 127.0.0.1 5556 EquipoC_vs_EquipoD\n", argv[0]);
        exit(EXIT_FAILURE);
    }

    const char *broker_ip = argv[1];
    int port = atoi(argv[2]);
    const char *topic = argv[3];

    /* socket() crea un socket UDP (SOCK_DGRAM) en el dominio IPv4 (AF_INET)
     * No se necesita connect() ya que UDP es sin conexion */
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

    printf("=== Publisher UDP enviando al broker %s:%d ===\n", broker_ip, port);
    printf("Tema: %s\n", topic);
    printf("Enviando %lu eventos...\n\n", (unsigned long)NUM_EVENTOS);

    /* Enviar cada evento deportivo al broker como datagrama UDP */
    for (int i = 0; i < (int)NUM_EVENTOS; i++) {
        char buf[BUFFER_SIZE];
        /* Formato del mensaje: PUBLISH|tema|mensaje */
        int len = snprintf(buf, sizeof(buf), "PUBLISH|%s|%s", topic, eventos[i]);

        /* sendto() envia el datagrama UDP al broker sin necesidad de conexion.
         * A diferencia de send() en TCP, aqui se especifica la direccion destino
         * en cada envio. No hay garantia de entrega. */
        if (sendto(sockfd, buf, len, 0,
                   (struct sockaddr *)&broker_addr, sizeof(broker_addr)) < 0) {
            perror("sendto");
            break;
        }

        printf("[Pub %s] Evento %d: %s\n", topic, i + 1, eventos[i]);

        /* Pausa de 2 segundos entre mensajes para simular tiempo real */
        sleep(2);
    }

    printf("\n[Publisher] Todos los eventos enviados.\n");

    /* close() cierra el socket UDP (libera recursos del sistema) */
    close(sockfd);
    return 0;
}
