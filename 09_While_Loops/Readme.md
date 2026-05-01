# 第 9 部分：`while` 循环

在这一部分的旅程中，我们要给语言加入 `while` 循环。
从某种意义上说，`while` 循环非常像一个没有 `else` 子句的 `if` 语句，
只不过它会总是跳回循环顶部重新判断条件。

所以，像这样：

```
  while (condition is true) {
    statements;
  }
```

应该被翻译成：

```
Lstart: evaluate condition
	jump to Lend if condition false
	statements
	jump to Lstart
Lend:
```

这意味着，我们可以直接借用此前处理 `if` 语句时使用过的扫描、解析和代码生成结构，
只需要做一些小修改，就能让它们也支持 `while`。

下面来看看具体怎么做到。

## 新 token

我们需要一个新的 token：`T_WHILE`，
对应新的关键字 `while`。
对 `defs.h` 和 `scan.c` 的修改都很直观，
这里就不展开了。

## 解析 `while` 语法

`while` 循环的 BNF 语法如下：

```
// while_statement: 'while' '(' true_false_expression ')' compound_statement  ;
```

于是我们需要在 `stmt.c` 中写一个函数来解析它。
代码如下；和解析 `if` 语句相比，它相当简单：

```c
// Parse a WHILE statement
// and return its AST
struct ASTnode *while_statement(void) {
  struct ASTnode *condAST, *bodyAST;

  // Ensure we have 'while' '('
  match(T_WHILE, "while");
  lparen();

  // Parse the following expression
  // and the ')' following. Ensure
  // the tree's operation is a comparison.
  condAST = binexpr(0);
  if (condAST->op < A_EQ || condAST->op > A_GE)
    fatal("Bad comparison operator");
  rparen();

  // Get the AST for the compound statement
  bodyAST = compound_statement();

  // Build and return the AST for this statement
  return (mkastnode(A_WHILE, condAST, NULL, bodyAST, 0));
}
```

我们需要一个新的 AST 节点类型 `A_WHILE`，
它已经加入 `defs.h` 中。
这个节点有一个左子树，用来求值循环条件；
还有一个右子树，用来保存作为 `while` 主体的复合语句。

## 通用代码生成

我们需要创建开始标签和结束标签，
求值条件，并插入适当的跳转：
条件不成立时跳出循环，循环体执行完后跳回顶部。
这部分代码依然比生成 `if` 语句简单得多。
在 `gen.c` 中：

```c
// Generate the code for a WHILE statement
// and an optional ELSE clause
static int genWHILE(struct ASTnode *n) {
  int Lstart, Lend;

  // Generate the start and end labels
  // and output the start label
  Lstart = label();
  Lend = label();
  cglabel(Lstart);

  // Generate the condition code followed
  // by a jump to the end label.
  // We cheat by sending the Lfalse label as a register.
  genAST(n->left, Lend, n->op);
  genfreeregs();

  // Generate the compound statement for the body
  genAST(n->right, NOREG, n->op);
  genfreeregs();

  // Finally output the jump back to the condition,
  // and the end label
  cgjump(Lstart);
  cglabel(Lend);
  return (NOREG);
}
```

有一件事我必须处理：
比较运算符的父 AST 节点现在除了可能是 `A_IF` 以外，
也可能是 `A_WHILE`。
因此在 `genAST()` 中，
处理比较运算符的代码现在变成了：

```c
    case A_EQ:
    case A_NE:
    case A_LT:
    case A_GT:
    case A_LE:
    case A_GE:
      // If the parent AST node is an A_IF or A_WHILE, generate 
      // a compare followed by a jump. Otherwise, compare registers 
      // and set one to 1 or 0 based on the comparison.
      if (parentASTop == A_IF || parentASTop == A_WHILE)
        return (cgcompare_and_jump(n->op, leftreg, rightreg, reg));
      else
        return (cgcompare_and_set(n->op, leftreg, rightreg));
```

而这基本上就是实现 `while` 循环所需的全部内容了。

## 测试语言的新能力

我把所有输入文件都移到了 `tests/` 目录里。
现在如果执行 `make test`，
它会进入这个目录，编译每个输入文件，
并把输出与已知正确结果进行比较：

```
cc -o comp1 -g cg.c decl.c expr.c gen.c main.c misc.c scan.c stmt.c
      sym.c tree.c
(cd tests; chmod +x runtests; ./runtests)
input01: OK
input02: OK
input03: OK
input04: OK
input05: OK
input06: OK
```

你也可以执行 `make test6`。
这会编译 `tests/input06` 文件：

```c
{ int i;
  i=1;
  while (i <= 10) {
    print i;
    i= i + 1;
  }
}
```

它会打印 1 到 10：

```
cc -o comp1 -g cg.c decl.c expr.c gen.c main.c misc.c scan.c
      stmt.c sym.c tree.c
./comp1 tests/input06
cc -o out out.s
./out
1
2
3
4
5
6
7
8
9
10
```

下面是编译后生成的汇编输出：

```
	.comm	i,8,8
	movq	$1, %r8
	movq	%r8, i(%rip)		# i= 1
L1:
	movq	i(%rip), %r8
	movq	$10, %r9
	cmpq	%r9, %r8		# Is i <= 10?
	jg	L2			# Greater than, jump to L2
	movq	i(%rip), %r8
	movq	%r8, %rdi		# Print out i
	call	printint
	movq	i(%rip), %r8
	movq	$1, %r9
	addq	%r8, %r9		# Add 1 to i
	movq	%r9, i(%rip)
	jmp	L1			# and loop back
L2:
```


## 总结与下一步

有了前面 `if` 语句的实现经验之后，
`while` 循环就很容易加进来了，
因为它们共享了大量相似结构。

我觉得我们现在其实已经拥有了一门
[图灵完备（Turing-complete）](https://en.wikipedia.org/wiki/Turing_completeness) 的语言：

  + 无限量的存储，也就是无限数量的变量
  + 基于存储值做决策的能力，也就是 `if` 语句
  + 改变执行方向的能力，也就是 `while` 循环

所以我们现在就可以停手，任务完成了！当然不是。
我们的最终目标仍然是让这个编译器能够编译自己。

在编译器编写之旅的下一部分中，我们会给语言加入 `for` 循环。 [下一步](../10_For_Loops/Readme.md)
