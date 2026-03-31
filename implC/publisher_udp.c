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

/* Mensajes deportivos predefinidos para simular un partido con alta frecuencia.
 * Se incluyen muchos eventos para generar rafagas de datagramas,
 * simulando un escenario realista de actualizaciones en tiempo real. */
static const char *eventos[] = {
    "Inicio del partido!",
    "Saque inicial de Equipo C",
    "Pase largo de Equipo C al minuto 1",
    "Equipo D recupera el balon al minuto 2",
    "Tiro de esquina para Equipo D al minuto 3",
    "Cabezazo desviado de Equipo D al minuto 3",
    "Saque de meta para Equipo C",
    "Gol de Equipo C al minuto 5 - Marcador 1-0",
    "Celebracion del goleador numero 9",
    "Reinicio del juego por Equipo D",
    "Falta de Equipo C al minuto 7",
    "Tiro libre para Equipo D al minuto 7",
    "Tiro libre desviado de Equipo D",
    "Tarjeta amarilla al numero 14 de Equipo D al minuto 9",
    "Pase filtrado de Equipo C al minuto 10",
    "Atajada del portero de Equipo D al minuto 10",
    "Saque de meta para Equipo D",
    "Contraataque de Equipo D al minuto 12",
    "Falta peligrosa al minuto 13 en area de Equipo C",
    "Tiro libre para Equipo D al minuto 13",
    "Barrera de Equipo C detiene el tiro",
    "Posesion de Equipo C al minuto 15",
    "Cambio de juego de Equipo C por la banda derecha",
    "Centro al area de Equipo D al minuto 17",
    "Despeje de Equipo D",
    "Tiro de esquina para Equipo C al minuto 18",
    "Cabezazo de Equipo C al palo al minuto 18",
    "Falta de Equipo D al minuto 20",
    "Tarjeta amarilla al numero 5 de Equipo C al minuto 20",
    "Cambio: jugador 8 entra por jugador 6 en Equipo D al minuto 22",
    "Pase largo de Equipo D al minuto 23",
    "Fuera de juego de Equipo D al minuto 23",
    "Saque de Equipo C al minuto 24",
    "Jugada individual de Equipo C al minuto 25",
    "Tiro al arco de Equipo C desviado al minuto 26",
    "Saque de meta para Equipo D",
    "Gol de Equipo D al minuto 28 - Empate 1-1",
    "Celebracion de Equipo D",
    "Reinicio del juego",
    "Falta tactica de Equipo C al minuto 30",
    "Tiro libre rapido de Equipo D",
    "Posesion de Equipo D al minuto 32",
    "Centro al area de Equipo C",
    "Atajada del portero de Equipo C al minuto 33",
    "Contraataque de Equipo C al minuto 35",
    "Pase al area de Equipo D",
    "Tiro de Equipo C desviado al minuto 36",
    "Saque de meta para Equipo D",
    "Ultimo minuto del primer tiempo",
    "Fin del primer tiempo - Marcador: 1-1",
    "Inicio del segundo tiempo",
    "Saque de Equipo D al minuto 46",
    "Presion alta de Equipo C al minuto 47",
    "Robo de balon de Equipo C al minuto 48",
    "Tiro al arco de Equipo C al minuto 48",
    "Atajada espectacular del portero de Equipo D",
    "Tiro de esquina para Equipo C al minuto 49",
    "Despeje de Equipo D al minuto 49",
    "Falta de Equipo D al minuto 51",
    "Tarjeta amarilla al numero 3 de Equipo D",
    "Tiro libre de Equipo C al minuto 52",
    "Tiro a la barrera",
    "Rebote controlado por Equipo D al minuto 52",
    "Cambio: jugador 11 entra por jugador 7 en Equipo C al minuto 53",
    "Penal para Equipo C al minuto 55",
    "Revision del VAR al minuto 55",
    "Penal confirmado para Equipo C",
    "Gol de penal de Equipo C al minuto 56 - Marcador 2-1",
    "Protesta de jugadores de Equipo D",
    "Tarjeta amarilla al numero 10 de Equipo D por protestar",
    "Reinicio del juego al minuto 57",
    "Presion de Equipo D buscando el empate",
    "Centro al area de Equipo C al minuto 59",
    "Despeje de Equipo C al minuto 59",
    "Tiro de esquina para Equipo D al minuto 60",
    "Cabezazo de Equipo D fuera al minuto 60",
    "Contraataque rapido de Equipo C al minuto 62",
    "Pase al hueco de Equipo C al minuto 63",
    "Tiro desviado de Equipo C al minuto 63",
    "Cambio: jugador 15 entra por jugador 4 en Equipo D al minuto 65",
    "Falta de Equipo C al minuto 66",
    "Tiro libre de Equipo D al minuto 67",
    "Tiro libre al travesano al minuto 67",
    "Rebote controlado por Equipo C",
    "Tarjeta roja al numero 2 de Equipo D al minuto 70",
    "Equipo D con 10 jugadores",
    "Tiro libre para Equipo C al minuto 71",
    "Tiro libre desviado de Equipo C",
    "Posesion de Equipo C controlando el partido",
    "Cambio: jugador 16 entra por jugador 9 en Equipo C al minuto 74",
    "Pase largo de Equipo D al minuto 75",
    "Fuera de juego de Equipo D",
    "Tiro al arco de Equipo C al minuto 77",
    "Atajada de Equipo D",
    "Tiro de esquina para Equipo C al minuto 78",
    "Gol de Equipo C al minuto 78 - Marcador 3-1",
    "Equipo D desmoralizado",
    "Minuto 80 - Equipo C controla el partido",
    "Falta de Equipo D al minuto 82",
    "Tarjeta amarilla al numero 8 de Equipo D",
    "Tiempo agregado: 4 minutos",
    "Minuto 90 - Ultimos minutos del partido",
    "Pase de Equipo D al minuto 91",
    "Tiro de Equipo D al minuto 92 - Fuera",
    "Fin del partido - Resultado final: Equipo C 3 - Equipo D 1"
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

    /* Enviar cada evento deportivo al broker como datagrama UDP.
     * Se envian en rafagas rapidas con pausas minimas para simular
     * un flujo intenso de actualizaciones en tiempo real, como ocurre
     * en sistemas reales de noticias deportivas con multiples fuentes. */
    for (int i = 0; i < (int)NUM_EVENTOS; i++) {
        char buf[BUFFER_SIZE];
        /* Formato del mensaje: PUBLISH|tema|seq:mensaje
         * Se incluye numero de secuencia para identificar perdidas */
        int len = snprintf(buf, sizeof(buf), "PUBLISH|%s|[%d/%lu] %s",
                           topic, i + 1, (unsigned long)NUM_EVENTOS, eventos[i]);

        /* sendto() envia el datagrama UDP al broker sin necesidad de conexion.
         * A diferencia de send() en TCP, aqui se especifica la direccion destino
         * en cada envio. No hay garantia de entrega. */
        if (sendto(sockfd, buf, len, 0,
                   (struct sockaddr *)&broker_addr, sizeof(broker_addr)) < 0) {
            perror("sendto");
            break;
        }

        printf("[Pub %s] Evento %d/%lu: %s\n", topic, i + 1,
               (unsigned long)NUM_EVENTOS, eventos[i]);

        /* Pausa minima entre mensajes (5ms) para generar rafagas rapidas.
         * Esto simula un escenario realista donde multiples eventos
         * ocurren casi simultaneamente (jugadas rapidas, corners, etc.) */
        usleep(5000);
    }

    printf("\n[Publisher] Todos los eventos enviados.\n");

    /* close() cierra el socket UDP (libera recursos del sistema) */
    close(sockfd);
    return 0;
}
