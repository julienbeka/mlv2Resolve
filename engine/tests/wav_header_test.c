/* SPDX-License-Identifier: GPL-3.0-or-later
 * Check the real virtual WAV producer against RIFF chunk boundaries, including
 * sliced header reads. No FUSE mount or user footage is needed.
 */
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "../mlvfs/wav.c"

/* The virtual producer uses the normal seek abstraction for the AUDF fixture. */
uint32_t file_set_pos(FILE *stream, uint64_t offset, int whence) {
    return fseeko(stream, (off_t)offset, whence);
}

static int failures;
#define CHECK(test, message) do { if (!(test)) { \
    fprintf(stderr, "FAIL: %s\n", message); failures++; } } while (0)

static uint32_t le32(const uint8_t *p) {
    return (uint32_t)p[0] | (uint32_t)p[1] << 8 |
           (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
}

static void check_wav(size_t pcm_size) {
    const size_t size = sizeof(struct wav_header) + pcm_size;
    uint8_t *bytes = malloc(size);
    uint8_t pcm[32];
    for (size_t i = 0; i < sizeof(pcm); i++) pcm[i] = (uint8_t)(i + 1);
    assert(bytes && pcm_size <= sizeof(pcm));

    FILE *chunk = tmpfile();
    assert(chunk);
    mlv_audf_hdr_t audf = {0};
    memcpy(audf.blockType, "AUDF", 4);
    audf.blockSize = sizeof(audf) + pcm_size;
    assert(fwrite(&audf, sizeof(audf), 1, chunk) == 1);
    assert(fwrite(pcm, 1, pcm_size, chunk) == pcm_size);
    fflush(chunk);
    FILE *chunks[] = {chunk};

    uint8_t index_bytes[sizeof(mlv_xref_hdr_t) + sizeof(mlv_xref_t)] = {0};
    mlv_xref_hdr_t *index = (mlv_xref_hdr_t *)index_bytes;
    index->entryCount = 1;
    mlv_xref_t *xref = (mlv_xref_t *)(index_bytes + sizeof(*index));
    xref->frameType = MLV_FRAME_AUDF;
    mlv_file_hdr_t file = {0};
    file.sourceFpsNom = 25;
    file.sourceFpsDenom = 1;
    mlv_wavi_hdr_t wavi = {0};
    wavi.channels = 2;
    wavi.samplingRate = 48000;
    wavi.bitsPerSample = 16;
    wavi.bytesPerSecond = 192000;
    mlv_rtci_hdr_t rtci = {0};
    mlv_idnt_hdr_t idnt = {0};

    CHECK(wav_get_data_direct(chunks, index, &file, &wavi, &rtci, &idnt,
                             size, bytes, 0, size) == size, "whole WAV read length");
    CHECK(memcmp(bytes, "RIFF", 4) == 0 && memcmp(bytes + 8, "WAVE", 4) == 0,
          "RIFF/WAVE signature");
    CHECK(le32(bytes + 4) == size - 8, "RIFF size must equal file size minus eight");

    size_t offset = 12;
    int found_data = 0;
    while (offset + 8 <= size) {
        uint32_t length = le32(bytes + offset + 4);
        if (memcmp(bytes + offset, "data", 4) == 0) {
            found_data = 1;
            CHECK(length == pcm_size, "data size must match available PCM bytes");
            CHECK(offset + 8 + length == size, "data chunk ends exactly at EOF");
            CHECK(memcmp(bytes + offset + 8, pcm, pcm_size) == 0, "PCM is unchanged");
            /* Reading either size field independently must give the same value. */
            uint8_t field[4];
            wav_get_data_direct(chunks, index, &file, &wavi, &rtci, &idnt,
                                size, field, (off_t)offset + 4, sizeof(field));
            CHECK(le32(field) == pcm_size, "sliced data size read is consistent");
            break;
        }
        offset += 8 + length + (length & 1);
    }
    CHECK(found_data, "data chunk is reachable by a RIFF reader");
    uint8_t field[4];
    wav_get_data_direct(chunks, index, &file, &wavi, &rtci, &idnt,
                        size, field, 4, sizeof(field));
    CHECK(le32(field) == size - 8, "sliced RIFF size read is consistent");
    fclose(chunk);
    free(bytes);
}

int main(void) {
    check_wav(32);
    check_wav(0);
    if (failures) return 1;
    puts("PASS: WAV sizes, RIFF boundaries, sliced reads and unchanged PCM");
    return 0;
}
