// Link glue for running RedisGraph outside redis-server.
// 1. siphash(): src/util/dict.c expects it from RediSearch's dict.c, which pulls half of RediSearch.
//    Compile RediSearch's own siphash implementation instead.
// 2. RediSearch_* C-API symbols: in the real module they are resolved at load time through
//    RedisModule_GetApi (REDISEARCH_API_EXTERN). The fuzzers never load an index module, so the
//    function pointers stay NULL exactly as they do in a module that has not called RediSearch_Initialize().
#include "deps/RediSearch/src/redisearch_api.h"

#pragma GCC visibility push(default)
#include "deps/RediSearch/src/util/siphash.c.inc"
#pragma GCC visibility pop

REDISEARCH_API_INIT_SYMBOLS()

// RediSearch C-API entry points that RedisGraph calls but RediSearch's RS_XAPIFUNC list omits
// (RedisGraph links RediSearch statically in the real module).
#define RG_UNLISTED_RS_SYMBOL(s) __typeof__(RediSearch_##s) RediSearch_##s = NULL;
RG_UNLISTED_RS_SYMBOL(CreateEmptyNode)
RG_UNLISTED_RS_SYMBOL(CreateGeoNode)
RG_UNLISTED_RS_SYMBOL(DocumentAddFieldGeo)
RG_UNLISTED_RS_SYMBOL(FreeDocument)
RG_UNLISTED_RS_SYMBOL(IndexOptionsSetStopwords)
RG_UNLISTED_RS_SYMBOL(TagFieldSetCaseSensitive)

// Called only from the redis server shutdown/flush event handlers.
void RediSearch_CleanupModule(void) {}
