/*
 * los-tv-gpt — напечатать разделы GPT-диска: имя, первый LBA, число секторов.
 *
 * Нужен установщику проприетарных компонентов, чтобы находить разделы
 * ROOT-A (ChromeOS) и super (google_apis) по ИМЕНИ, а не по жёстко
 * закреплённым смещениям. Если Google поменяет раскладку образа, скрипт
 * продолжит работать; старые смещения остаются запасным вариантом.
 *
 * Формат вывода (по строке на раздел), смещение и размер в БАЙТАХ:
 *   <имя> <offset_bytes> <size_bytes>
 *
 * Поддерживаются диски с логическим сектором 512 и 4096 байт.
 */

#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

namespace {

uint32_t Le32(const uint8_t* p) {
    return static_cast<uint32_t>(p[0]) | (static_cast<uint32_t>(p[1]) << 8) |
           (static_cast<uint32_t>(p[2]) << 16) | (static_cast<uint32_t>(p[3]) << 24);
}

uint64_t Le64(const uint8_t* p) {
    uint64_t v = 0;
    for (int i = 7; i >= 0; i--) {
        v = (v << 8) | p[i];
    }
    return v;
}

// Прочитать заголовок GPT; вернуть размер сектора или 0.
int ReadHeader(int fd, uint8_t* hdr, uint64_t* entries_lba, uint32_t* num,
               uint32_t* esize) {
    static const uint64_t kSectors[] = {512, 4096};
    for (uint64_t sector : kSectors) {
        if (pread(fd, hdr, 512, static_cast<off_t>(sector)) != 512) continue;
        if (memcmp(hdr, "EFI PART", 8) != 0) continue;
        *entries_lba = Le64(hdr + 72);
        *num = Le32(hdr + 80);
        *esize = Le32(hdr + 84);
        if (*num == 0 || *esize < 128 || *esize > 4096) continue;
        return static_cast<int>(sector);
    }
    return 0;
}

void PrintName(const uint8_t* p) {
    // UTF-16LE, 72 байта; печатаем ASCII, остальное — '?'.
    char buf[37];
    int n = 0;
    for (int i = 0; i < 36; i++) {
        uint32_t c = static_cast<uint32_t>(p[2 * i]) |
                     (static_cast<uint32_t>(p[2 * i + 1]) << 8);
        if (c == 0) break;
        buf[n++] = (c >= 32 && c <= 126) ? static_cast<char>(c) : '?';
    }
    buf[n] = '\0';
    fputs(buf[0] ? buf : "-", stdout);
}

}  // namespace

int main(int argc, char** argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: los-tv-gpt <image>\n");
        return 2;
    }

    int fd = open(argv[1], O_RDONLY);
    if (fd < 0) {
        perror("open");
        return 1;
    }

    uint8_t hdr[512];
    uint64_t entries_lba = 0;
    uint32_t num = 0, esize = 0;
    int sector = ReadHeader(fd, hdr, &entries_lba, &num, &esize);
    if (sector == 0) {
        fprintf(stderr, "los-tv-gpt: GPT не найден в %s\n", argv[1]);
        close(fd);
        return 1;
    }

    // Не читаем больше 64 КиБ таблицы (достаточно для 128 записей по 128 байт
    // и с запасом для нестандартных размеров).
    uint64_t bytes = static_cast<uint64_t>(num) * esize;
    if (bytes > 65536) bytes = 65536;

    uint8_t table[65536];
    if (pread(fd, table, static_cast<size_t>(bytes),
              static_cast<off_t>(entries_lba * sector)) !=
        static_cast<ssize_t>(bytes)) {
        fprintf(stderr, "los-tv-gpt: не удалось прочитать таблицу\n");
        close(fd);
        return 1;
    }

    for (uint32_t i = 0; i < num; i++) {
        const uint8_t* e = table + static_cast<uint64_t>(i) * esize;
        if (static_cast<uint64_t>(i + 1) * esize > bytes) break;

        bool used = false;
        for (int b = 0; b < 16; b++) {
            if (e[b] != 0) {
                used = true;
                break;
            }
        }
        if (!used) continue;

        uint64_t first = Le64(e + 32);
        uint64_t last = Le64(e + 40);
        if (last < first) continue;

        // Печатаем сразу байтовые смещение и размер: shell в recovery
        // считает в 32 битах, и 4 ГиБ переполняются в 0.
        PrintName(e + 56);
        printf(" %llu %llu\n",
               static_cast<unsigned long long>(first * static_cast<uint64_t>(sector)),
               static_cast<unsigned long long>((last - first + 1) *
                                               static_cast<uint64_t>(sector)));
    }

    close(fd);
    return 0;
}
