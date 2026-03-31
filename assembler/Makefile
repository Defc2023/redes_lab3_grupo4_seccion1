# =============================================================================
# Makefile — Sistema de noticias deportivas (implementacion en ensamblador)
# =============================================================================
# Compilar todo:   make
# Limpiar:         make clean
#
# Requiere:
#   nasm  (nasm -f elf64)
#   gcc   (enlazador con -no-pie para soporte de direccionamiento absoluto)
# =============================================================================

CC     = gcc
NASM   = nasm
CFLAGS = -no-pie
NFLAGS = -f elf64

TARGETS = broker_tcp publisher_tcp subscriber_tcp \
          broker_udp publisher_udp subscriber_udp

.PHONY: all clean

all: $(TARGETS)

# --- TCP ---
broker_tcp: broker_tcp.o
	$(CC) $(CFLAGS) broker_tcp.o -o broker_tcp

broker_tcp.o: broker_tcp.asm
	$(NASM) $(NFLAGS) broker_tcp.asm -o broker_tcp.o

publisher_tcp: publisher_tcp.o
	$(CC) $(CFLAGS) publisher_tcp.o -o publisher_tcp

publisher_tcp.o: publisher_tcp.asm
	$(NASM) $(NFLAGS) publisher_tcp.asm -o publisher_tcp.o

subscriber_tcp: subscriber_tcp.o
	$(CC) $(CFLAGS) subscriber_tcp.o -o subscriber_tcp

subscriber_tcp.o: subscriber_tcp.asm
	$(NASM) $(NFLAGS) subscriber_tcp.asm -o subscriber_tcp.o

# --- UDP ---
broker_udp: broker_udp.o
	$(CC) $(CFLAGS) broker_udp.o -o broker_udp

broker_udp.o: broker_udp.asm
	$(NASM) $(NFLAGS) broker_udp.asm -o broker_udp.o

publisher_udp: publisher_udp.o
	$(CC) $(CFLAGS) publisher_udp.o -o publisher_udp

publisher_udp.o: publisher_udp.asm
	$(NASM) $(NFLAGS) publisher_udp.asm -o publisher_udp.o

subscriber_udp: subscriber_udp.o
	$(CC) $(CFLAGS) subscriber_udp.o -o subscriber_udp

subscriber_udp.o: subscriber_udp.asm
	$(NASM) $(NFLAGS) subscriber_udp.asm -o subscriber_udp.o

clean:
	rm -f *.o $(TARGETS)
