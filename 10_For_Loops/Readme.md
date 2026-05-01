# 第 10 部分：`for` 循环

在编译器编写之旅的这一部分中，我要加入 `for` 循环。
不过在实现上有一个小麻烦，
我想先把它讲清楚，再进入具体的解决过程。

## `for` 循环的语法

我默认你已经熟悉 `for` 循环的语法。
例如下面这个例子：

```c
  for (i=0; i < MAX; i++)
    printf("%d\n", i);
```

在我们的语言里，我准备使用如下 BNF 语法：

```
 for_statement: 'for' '(' preop_statement ';'
                          true_false_expression ';'
                          postop_statement ')' compound_statement  ;

 preop_statement:  statement  ;        (for now)
 postop_statement: statement  ;        (for now)
```

`preop_statement` 会在循环开始前执行。
以后我们还得精确限制这里到底允许哪些动作
（例如，不能出现 `if` 语句）。
然后求值 `true_false_expression`。
如果条件为真，就执行 `compound_statement`。
执行完主体后，再执行 `postop_statement`，
随后跳回去重新判断 `true_false_expression`。

## 这个小麻烦

这个麻烦在于：
`postop_statement` 在解析时出现在 `compound_statement` 之前，
但我们生成代码时，却必须把 `postop_statement` 的代码放在
`compound_statement` 之后。

解决这个问题的方法有很多。
我以前写过一个编译器，当时的做法是先把 `compound_statement`
对应的汇编代码放进一个临时缓冲区里，
等 `postop_statement` 的代码生成完之后，再把缓冲区“回放”出来。
在 SubC 编译器中，Nils 则巧妙地利用标签和跳转，
把代码执行顺序“穿”成了正确的流向。

但我们这里是构建 AST。
那就让 AST 来帮我们把汇编代码生成顺序搞对。

## 该构造什么样的 AST？

你可能已经注意到了，`for` 循环有四个结构组成部分：

1. `preop_statement`
2. `true_false_expression`
3. `postop_statement`
4. `compound_statement`

我实在不想再一次修改 AST 节点结构，
把它扩展成四个孩子。
不过我们完全可以把 `for` 循环看作一个增强版的 `while` 循环：

```
   preop_statement;
   while ( true_false_expression ) {
     compound_statement;
     postop_statement;
   }
```

那我们能不能用现有节点类型，
构造出一棵能反映这个结构的 AST？可以：

```
         A_GLUE
        /     \
   preop     A_WHILE
             /    \
        decision  A_GLUE
                  /    \
            compound  postop
```

你可以手动按“自顶向下、从左到右”的顺序遍历这棵树，
就会发现生成出来的汇编代码顺序正好是正确的。
我们必须把 `compound_statement` 和 `postop_statement`
粘成一棵子树，
这样当 `while` 循环退出时，
才能一次性越过它们两个。

这也意味着，我们只需要新增一个 `T_FOR` token，
却不需要新增 AST 节点类型。
因此，对编译器的改动只涉及扫描和解析。

## token 与扫描

这里新增了关键字 `for`，
以及对应的 token `T_FOR`。
没有什么大变化。

## 解析语句

不过我们确实需要对解析器做一点结构性调整。
因为在 `for` 语法里，
我只希望 `preop_statement` 和 `postop_statement`
各自只是一条语句。

目前我们有一个 `compound_statement()`，
它会一直循环，直到遇到右花括号 `}` 才停下。
我们需要把这部分逻辑拆出来，
让 `compound_statement()` 改为调用 `single_statement()`
来获取单条语句。

但这里还有另一个麻烦。
看看现有 `assignment_statement()` 对赋值语句的解析：
解析器必须在语句结尾找到一个分号。

这对复合语句来说没问题，
但对 `for` 循环却不合适。
否则我就不得不写出这样的东西：

```c
  for (i=1 ; i < 10 ; i= i + 1; )
```

因为每一个赋值语句*都必须*以分号结束。

我们真正需要的是：
单语句解析器本身*不要*去消费分号，
而把是否读取分号的决定交给复合语句解析器。
并且有些语句之间需要分号（例如连续赋值语句），
有些则不需要（例如连续出现的 `if` 语句）。

把这些背景都解释完之后，再来看新的单语句和复合语句解析代码：

```c
// Parse a single statement
// and return its AST
static struct ASTnode *single_statement(void) {
  switch (Token.token) {
    case T_PRINT:
      return (print_statement());
    case T_INT:
      var_declaration();
      return (NULL);		// No AST generated here
    case T_IDENT:
      return (assignment_statement());
    case T_IF:
      return (if_statement());
    case T_WHILE:
      return (while_statement());
    case T_FOR:
      return (for_statement());
    default:
      fatald("Syntax error, token", Token.token);
  }
}

// Parse a compound statement
// and return its AST
struct ASTnode *compound_statement(void) {
  struct ASTnode *left = NULL;
  struct ASTnode *tree;

  // Require a left curly bracket
  lbrace();

  while (1) {
    // Parse a single statement
    tree = single_statement();

    // Some statements must be followed by a semicolon
    if (tree != NULL &&
	(tree->op == A_PRINT || tree->op == A_ASSIGN))
      semi();

    // For each new tree, either save it in left
    // if left is empty, or glue the left and the
    // new tree together
    if (tree != NULL) {
      if (left == NULL)
	left = tree;
      else
	left = mkastnode(A_GLUE, left, NULL, tree, 0);
    }
    // When we hit a right curly bracket,
    // skip past it and return the AST
    if (Token.token == T_RBRACE) {
      rbrace();
      return (left);
    }
  }
}
```

我也顺手把 `print_statement()` 和
`assignment_statement()` 里对 `semi()` 的调用删掉了。

## 解析 `for` 循环

有了前面那套 BNF 语法之后，
解析 `for` 循环就相当直接了。
而且，因为我们已经知道自己想要的 AST 形状，
构建这棵树的代码也很直接。代码如下：

```c
// Parse a FOR statement
// and return its AST
static struct ASTnode *for_statement(void) {
  struct ASTnode *condAST, *bodyAST;
  struct ASTnode *preopAST, *postopAST;
  struct ASTnode *tree;

  // Ensure we have 'for' '('
  match(T_FOR, "for");
  lparen();

  // Get the pre_op statement and the ';'
  preopAST= single_statement();
  semi();

  // Get the condition and the ';'
  condAST = binexpr(0);
  if (condAST->op < A_EQ || condAST->op > A_GE)
    fatal("Bad comparison operator");
  semi();

  // Get the post_op statement and the ')'
  postopAST= single_statement();
  rparen();

  // Get the compound statement which is the body
  bodyAST = compound_statement();

  // For now, all four sub-trees have to be non-NULL.
  // Later on, we'll change the semantics for when some are missing

  // Glue the compound statement and the postop tree
  tree= mkastnode(A_GLUE, bodyAST, NULL, postopAST, 0);

  // Make a WHILE loop with the condition and this new body
  tree= mkastnode(A_WHILE, condAST, NULL, tree, 0);

  // And glue the preop tree to the A_WHILE tree
  return(mkastnode(A_GLUE, preopAST, NULL, tree, 0));
}
```

## 生成汇编代码

其实我们只是“合成”出了一棵内部含有 `while` 循环、
并且带着若干 `A_GLUE` 子树的 AST。
因此，编译器在代码生成这一侧完全不需要做改动。

## 试一试

`tests/input07` 文件里有下面这个程序：

```c
{
  int i;
  for (i= 1; i <= 10; i= i + 1) {
    print i;
  }
}
```

执行 `make test7` 后，会得到下面的输出：

```
cc -o comp1 -g cg.c decl.c expr.c gen.c main.c misc.c scan.c
    stmt.c sym.c tree.c
./comp1 tests/input07
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

下面是相关的汇编输出：

```
	.comm	i,8,8
	movq	$1, %r8
	movq	%r8, i(%rip)		# i = 1
L1:
	movq	i(%rip), %r8
	movq	$10, %r9
	cmpq	%r9, %r8		# Is i < 10?
	jg	L2			# i >= 10, jump to L2
	movq	i(%rip), %r8
	movq	%r8, %rdi
	call	printint		# print i
	movq	i(%rip), %r8
	movq	$1, %r9
	addq	%r8, %r9		# i = i + 1
	movq	%r9, i(%rip)
	jmp	L1			# Jump to top of loop
L2:
```

## 总结与下一步

现在我们的语言已经有了数量还算不错的控制结构：
`if` 语句、`while` 循环和 `for` 循环。
接下来的问题是：下一步该啃什么？
可选项实在太多了：

 + 类型
 + 局部与全局
 + 函数
 + 数组与指针
 + 结构体与联合体
 + `auto`、`static` 之类

我决定先看函数。
所以，在编译器编写之旅的下一部分中，
我们会开始为语言加入函数支持的第一阶段。 [下一步](../11_Functions_pt1/Readme.md)
