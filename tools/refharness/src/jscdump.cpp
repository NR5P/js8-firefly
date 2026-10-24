#include "jsc.h"
#include <cstdio>
#include <cstring>
#include <cstdint>
#include <cassert>
static void u8(FILE*f,uint32_t v){assert(v<256);fputc(v,f);}
static void u32(FILE*f,uint32_t v){fwrite(&v,4,1,f);}
int main(int argc,char**argv){
  FILE*f=fopen(argv[1],"wb");
  fwrite("JSC1",4,1,f); u32(f,JSC::size); u32(f,JSC::size); u32(f,JSC::prefixSize);
  for(uint32_t i=0;i<JSC::size;i++){auto&t=JSC::map[i];size_t n=strlen(t.str);u8(f,n);u8(f,t.size);u32(f,t.index);fwrite(t.str,1,n,f);}
  for(uint32_t i=0;i<JSC::size;i++){auto&t=JSC::list[i];size_t n=strlen(t.str);u8(f,n);u8(f,t.size);u32(f,t.index);fwrite(t.str,1,n,f);}
  for(uint32_t i=0;i<JSC::prefixSize;i++){auto&t=JSC::prefix[i];size_t n=strlen(t.str);u8(f,n);u32(f,t.size);u32(f,t.index);fwrite(t.str,1,n,f);}
  fclose(f);
  int bad=0; for(uint32_t i=0;i<JSC::size;i++){ if(JSC::map[i].index!=(int)i) bad++; if((int)strlen(JSC::map[i].str)!=JSC::map[i].size) bad+=0; }
  printf("map index mismatches: %d\n",bad);
  int sm=0; for(uint32_t i=0;i<JSC::size;i++) if((int)strlen(JSC::map[i].str)!=JSC::map[i].size) sm++;
  printf("map size!=strlen: %d\n",sm);
}
