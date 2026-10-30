// Known-answer probe for mayhem/test.sh: drives RedisGraph's query front end on fixed
// queries and prints what it computed. test.sh asserts the exact output.
#include <stdio.h>
#include "rg_harness.h"
#include "src/arithmetic/arithmetic_expression.h"
#include "src/arithmetic/arithmetic_expression_construct.h"
#include "src/execution_plan/ops/op.h"

static void print_return_value(const char *query) {
	ExecutionPlan *plan;
	AST *ast = rg_compile(query, &plan);
	if(ast == NULL) { printf("rejected\n"); rg_end_query(ast, plan); return; }

	const cypher_astnode_t *ret = cypher_ast_query_get_clause(ast->root, 0);
	const cypher_astnode_t *proj = cypher_ast_return_get_projection(ret, 0);
	AR_ExpNode *exp = AR_EXP_FromASTNode(cypher_ast_projection_get_expression(proj));
	SIValue v = AR_EXP_Evaluate(exp, NULL);

	char *buf = NULL;
	size_t cap = 0, len = 0;
	SIValue_ToString(v, &buf, &cap, &len);
	printf("value %s\n", buf);

	free(buf);
	SIValue_Free(v);
	AR_EXP_Free(exp);
	rg_end_query(ast, plan);
}

static void print_plan_chain(const char *query) {
	ExecutionPlan *plan;
	AST *ast = rg_compile(query, &plan);
	if(plan == NULL) { printf("rejected\n"); rg_end_query(ast, plan); return; }

	printf("plan");
	for(OpBase *op = plan->root; op != NULL; op = op->childCount ? op->children[0] : NULL) {
		printf(" %s", op->name);
	}
	printf("\n");
	rg_end_query(ast, plan);
}

int main(void) {
	rg_init();

	print_return_value("RETURN toUpper('abc') + '-' + toString(6 * 7)");
	print_return_value("RETURN size([1, 2, 3]) + 10 ^ 2");
	print_plan_chain("MATCH (n:Person) WHERE n.age > 3 RETURN n.name ORDER BY n.name LIMIT 5");
	print_plan_chain("UNWIND range(1, 3) AS i RETURN i");
	print_plan_chain("MATCH (n RETURN n");
	return 0;
}
