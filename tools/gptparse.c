/* gptparse - minimal GPT reader for the webflash installer.
 * Reads a buffer containing LBA0..LBA33 of an image (17408 bytes:
 * MBR + primary GPT header + partition entries), prints each partition as:
 *   <index> <name> <first_lba> <last_lba>
 * Partition names are printed as ASCII (UTF-16LE truncated, NUL stops).
 * usage: gptparse <file>  (exit 1 if no valid GPT header at offset 512)
 */
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <stdlib.h>

static uint64_t rd64(const unsigned char *p){ uint64_t v=0; for(int i=7;i>=0;i--) v=(v<<8)|p[i]; return v; }
static uint32_t rd32(const unsigned char *p){ return (uint32_t)p[0] | ((uint32_t)p[1]<<8) | ((uint32_t)p[2]<<16) | ((uint32_t)p[3]<<24); }

int main(int argc, char **argv){
    if(argc!=2){ fprintf(stderr,"usage: gptparse <lba0-33 buffer file>\n"); return 2; }
    FILE *f=fopen(argv[1],"rb");
    if(!f){ perror("open"); return 2; }
    static unsigned char buf[34*512];
    size_t n=fread(buf,1,sizeof buf,f);
    fclose(f);
    if(n < 34*512){ fprintf(stderr,"short read: %zu\n", n); return 2; }
    if(memcmp(buf+512,"EFI PART",8)!=0){ fprintf(stderr,"no GPT header at LBA1\n"); return 1; }
    uint64_t ent_lba = rd64(buf+512+72);
    uint32_t ent_num = rd32(buf+512+80);
    uint32_t ent_size= rd32(buf+512+84);
    if(ent_size<128 || ent_num>128 || ent_lba<2 || ent_lba>33){ fprintf(stderr,"unsupported GPT geometry\n"); return 1; }
    for(uint32_t i=0;i<ent_num;i++){
        const unsigned char *e = buf + ent_lba*512 + i*ent_size;
        uint64_t first=rd64(e+32), last=rd64(e+40);
        if(first==0 && last==0) continue; /* unused entry */
        char name[37]; int j;
        for(j=0;j<36;j++){ unsigned c=e[56+j*2]; if(!c) break; name[j]=(char)(c<128?c:'?'); }
        name[j]=0;
        printf("%u %s %llu %llu\n", i, name,
               (unsigned long long)first, (unsigned long long)last);
    }
    return 0;
}
