ASM = nasm
LD = ld

ASMFLAGS = -f elf64 -g -F dwarf
LDFLAGS =

TARGET = fdmon
SRC = fdmon.asm
OBJ = fdmon.o

.PHONY: all clean run

all: $(TARGET)

$(TARGET): $(OBJ)
	$(LD) $(LDFLAGS) -o $@ $<

$(OBJ): $(SRC)
	$(ASM) $(ASMFLAGS) -o $@ $<

clean:
	rm -f $(OBJ) $(TARGET)

run: $(TARGET)
	./$(TARGET)
