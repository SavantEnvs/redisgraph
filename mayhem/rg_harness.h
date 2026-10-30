// Shared setup for the fuzz harness and the known-answer probe: run RedisGraph's
// query front end (parse -> validate -> AST -> plan) outside redis-server.
#ifndef RG_HARNESS_H
#define RG_HARNESS_H

#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>

#include "src/ast/ast.h"
#include "src/ast/ast_validations.h"
#include "src/query_ctx.h"
#include "src/errors/errors.h"
#include "src/util/arr.h"
#include "src/util/rmalloc.h"
#include "src/arithmetic/funcs.h"
#include "src/procedures/procedure.h"
#include "src/graph/graphcontext.h"
#include "src/queries_log/queries_log.h"
#include "src/execution_plan/execution_plan.h"

static GraphContext *g_gc;

static GraphContext *rg_fake_graph_context(void) {
	GraphContext *gc = (GraphContext *)calloc(1, sizeof(GraphContext));

	gc->g                = Graph_New(16, 16);
	gc->ref_count        = 1;
	gc->index_count      = 0;
	gc->graph_name       = strdup("G");
	gc->attributes       = raxNew();
	gc->string_mapping   = (char **)array_new(char *, 64);
	gc->node_schemas     = (Schema **)array_new(Schema *, GRAPH_DEFAULT_LABEL_CAP);
	gc->relation_schemas = (Schema **)array_new(Schema *, GRAPH_DEFAULT_RELATION_TYPE_CAP);
	gc->queries_log      = QueriesLog_New();

	pthread_rwlock_init(&gc->_attribute_rwlock, NULL);
	return gc;
}

static void rg_init(void) {
	Alloc_Reset();  // module allocators -> malloc family (no redis-server here)

	if(!QueryCtx_Init()) abort();
	if(!ErrorCtx_Init()) abort();
	if(!AST_ValidationsMappingInit()) abort();

	if(GrB_init(GrB_NONBLOCKING) != GrB_SUCCESS) abort();
	GxB_Global_Option_set(GxB_FORMAT, GxB_BY_ROW);

	Proc_Register();
	AR_RegisterFuncs();

	g_gc = rg_fake_graph_context();
}

// Compile one query as ExecutionCtx_FromQuery does, minus the plan cache.
// Returns the AST (NULL if the query was rejected); *plan is set for plain queries.
// The caller owns both and ends the query with rg_end_query().
static AST *rg_compile(const char *query, ExecutionPlan **plan) {
	*plan = NULL;
	const char *q_str = NULL;

	// QueryCtx_Free releases the thread-local context, so re-attach the graph every query
	QueryCtx *ctx = QueryCtx_GetQueryCtx();
	QueryCtx_SetGraphCtx(g_gc);

	cypher_parse_result_t *params = parse_params(query, &q_str);
	if(params == NULL) return NULL;

	if(strlen(q_str) == 0) {
		parse_result_free(params);
		return NULL;
	}

	ctx->query_data.query_no_params = q_str;

	cypher_parse_result_t *parsed = parse_query(q_str);
	if(ErrorCtx_EncounteredError() || parsed == NULL) {
		parse_result_free(parsed);
		parse_result_free(params);
		return NULL;
	}

	AST *ast = AST_Build(parsed);
	AST_SetParamsParseResult(ast, params);

	if(cypher_astnode_type(ast->root) == CYPHER_AST_QUERY) {
		*plan = ExecutionPlan_FromTLS_AST();
	}
	return ast;
}

static void rg_end_query(AST *ast, ExecutionPlan *plan) {
	if(plan != NULL) ExecutionPlan_Free(plan);
	if(ast != NULL) AST_Free(ast);
	ErrorCtx_Clear();
	QueryCtx_Free();
}

#endif
