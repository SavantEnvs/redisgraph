// libFuzzer harness: Cypher query text -> parse -> validate -> AST -> execution plan,
// against an empty in-memory graph, without the plan cache so every input is independent.
#include "rg_harness.h"

// keep fuzzed query text bounded the way an embedder would bound a single command
#define MAX_QUERY_LEN 4096

int LLVMFuzzerInitialize(int *argc, char ***argv) {
	(void)argc; (void)argv;
	rg_init();
	return 0;
}

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
	if(size == 0 || size > MAX_QUERY_LEN) return -1;

	char *query = malloc(size + 1);
	memcpy(query, data, size);
	query[size] = '\0';
	// a query is a C string in RedisGraph: reject embedded NULs, don't repair them
	if(strlen(query) != size) { free(query); return -1; }

	ExecutionPlan *plan = NULL;
	AST *ast = rg_compile(query, &plan);
	rg_end_query(ast, plan);

	free(query);
	return 0;
}
