# 第 2 部分：语法解析（Parsing）简介

在编译器编写之旅的这一部分里，我会介绍解析器（parser）的基础知识。
正如我在第一部分提到的，解析器的工作是识别输入中的语法和结构元素，
并确保它们符合这门语言的 *grammar*（语法）。

我们已经能够扫描出若干语言元素，也就是 token：

 + 四个基本数学运算符：`*`、`/`、`+` 和 `-`
 + 由一个或多个数字 `0` .. `9` 组成的十进制整数

现在，让我们为解析器将要识别的这门语言定义一套语法。

## BNF：Backus-Naur Form

如果你开始接触计算机语言，
迟早会遇到 [BNF](https://en.wikipedia.org/wiki/Backus%E2%80%93Naur_form)。
这里我只介绍足够表达我们目标语法所需的那一小部分 BNF 语法。

我们需要一套语法，用来表达只包含整数的数学表达式。
下面就是它的 BNF 描述：

```
expression: number
          | expression '*' expression
          | expression '/' expression
          | expression '+' expression
          | expression '-' expression
          ;

number:  T_INTLIT
         ;
```

竖线表示语法中的不同分支选择，所以上面的定义表示：

  + 一个表达式可以只是一个数字，或者
  + 一个表达式可以是两个表达式，中间由 `*` token 分隔，或者
  + 一个表达式可以是两个表达式，中间由 `/` token 分隔，或者
  + 一个表达式可以是两个表达式，中间由 `+` token 分隔，或者
  + 一个表达式可以是两个表达式，中间由 `-` token 分隔
  + 一个数字永远是一个 `T_INTLIT` token

很显然，这个语法的 BNF 定义是*递归*的：
一个表达式的定义中引用了其他表达式。
不过这个递归是有“落地”方式的：
当表达式最终变成一个数字时，它总是一个 `T_INTLIT` token，
于是递归就在这里结束。

在 BNF 里，`expression` 和 `number` 被称为*非终结符（non-terminal）*，
因为它们由语法规则生成。
而 `T_INTLIT` 是*终结符（terminal）*，
因为它并不是由某条语法规则再定义出来的，
而是语言里已经识别好的 token。
同样，那四个数学运算符 token 也是终结符。
 
## 递归下降解析（Recursive Descent Parsing）

既然我们的语法是递归的，那么递归地解析它就很自然。
我们需要做的，是先读入一个 token，然后*向前看（look ahead）*
下一个 token。根据下一个 token 是什么，
就能决定接下来该走哪条解析路径。
这可能要求我们递归调用一个已经调用过的函数。

在我们的例子里，任意表达式的第一个 token 都会是一个数字，
后面可能跟着数学运算符。
在那之后，可能只是单个数字，
也可能是一个全新表达式的开始。
那么该怎样递归地解析它呢？

我们可以写出下面这样的伪代码：

```
function expression() {
  Scan and check the first token is a number. Error if it's not
  Get the next token
  If we have reached the end of the input, return, i.e. base case

  Otherwise, call expression()
}
```

让我们把这个函数运行在输入 `2 + 3 - 5 T_EOF` 上，
其中 `T_EOF` 是表示输入结束的 token。
我会给每一次 `expression()` 调用编号。

```
expression0:
  Scan in the 2, it's a number
  Get next token, +, which isn't T_EOF
  Call expression()

    expression1:
      Scan in the 3, it's a number
      Get next token, -, which isn't T_EOF
      Call expression()

        expression2:
          Scan in the 5, it's a number
          Get next token, T_EOF, so return from expression2

      return from expression1
  return from expression0
```

可以看到，这个函数确实能够递归地解析输入
`2 + 3 - 5 T_EOF`。

当然，我们目前还没有对输入做任何实际处理，
但那本来也不是解析器的职责。
解析器的工作是*识别*输入，并在出现语法错误时发出警告。
真正去做输入的*语义分析（semantic analysis）*、
也就是理解并执行其含义的，是别的组件。

> 后面你会看到，这句话并不完全准确。
  在很多情况下，把语法分析和语义分析交织在一起反而更合理。

## 抽象语法树（Abstract Syntax Tree）

为了做语义分析，我们需要一些代码，
要么解释已经识别出的输入，
要么把它翻译成另一种格式，比如汇编代码。
在旅程的这一部分中，我们会先为输入构建一个解释器（interpreter）。
但在那之前，我们要先把输入转换成一棵
[抽象语法树（abstract syntax tree）](https://en.wikipedia.org/wiki/Abstract_syntax_tree)，
也就是 AST。

我非常推荐你先读一下这篇关于 AST 的简短说明：

 + [Leveling Up One’s Parsing Game With ASTs](https://medium.com/basecs/leveling-up-ones-parsing-game-with-asts-d7a6fc2400ff)
   ，作者 Vaidehi Joshi

这篇文章写得很好，非常有助于理解 AST 的目的和结构。
不用担心，你看完回来我还在这里。

我们要构建的 AST 中，每个节点的结构定义在 `defs.h` 里：

```c
// AST node types
enum {
  A_ADD, A_SUBTRACT, A_MULTIPLY, A_DIVIDE, A_INTLIT
};

// Abstract Syntax Tree structure
struct ASTnode {
  int op;                               // "Operation" to be performed on this tree
  struct ASTnode *left;                 // Left and right child trees
  struct ASTnode *right;
  int intvalue;                         // For A_INTLIT, the integer value
};
```

有些 AST 节点，比如 `op` 值为 `A_ADD` 和 `A_SUBTRACT` 的节点，
拥有两个子 AST，分别由 `left` 和 `right` 指向。
稍后我们会把左右子树的值取出来，再做加法或减法。

另外，`op` 值为 `A_INTLIT` 的 AST 节点表示一个整数值。
它没有子树，只有 `intvalue` 字段中的那个值。

## 构建 AST 节点与树

`tree.c` 里的代码负责构建 AST。
其中最通用的函数 `mkastnode()` 接收 AST 节点四个字段的值，
分配一个新节点，填入这些字段，再返回节点指针：

```c
// Build and return a generic AST node
struct ASTnode *mkastnode(int op, struct ASTnode *left,
                          struct ASTnode *right, int intvalue) {
  struct ASTnode *n;

  // Malloc a new ASTnode
  n = (struct ASTnode *) malloc(sizeof(struct ASTnode));
  if (n == NULL) {
    fprintf(stderr, "Unable to malloc in mkastnode()\n");
    exit(1);
  }
  // Copy in the field values and return it
  n->op = op;
  n->left = left;
  n->right = right;
  n->intvalue = intvalue;
  return (n);
}
```

有了它，我们就能再写一些更具体的辅助函数：
一个用来创建叶子 AST 节点（即没有子节点的节点），
另一个用来创建只有单个子节点的 AST 节点：

```c
// Make an AST leaf node
struct ASTnode *mkastleaf(int op, int intvalue) {
  return (mkastnode(op, NULL, NULL, intvalue));
}

// Make a unary AST node: only one child
struct ASTnode *mkastunary(int op, struct ASTnode *left, int intvalue) {
  return (mkastnode(op, left, NULL, intvalue));
}
```

## AST 的用途

我们会用 AST 来保存识别出的每个表达式，
这样稍后就可以递归遍历它，从而计算表达式的最终值。
这里我们还必须处理数学运算符的优先级。下面看一个例子。

考虑表达式 `2 * 3 + 4 * 5`。
乘法的优先级高于加法，因此我们希望先把乘法两边的操作数“绑定”在一起，
在做加法之前先完成这些乘法运算。

如果我们生成的 AST 长成下面这样：

```
          +
         / \
        /   \
       /     \
      *       *
     / \     / \
    2   3   4   5
```

那么在遍历这棵树时，我们会先计算 `2*3`，再计算 `4*5`。
得到这两个结果之后，再把它们传回树根执行加法。

## 一个天真的表达式解析器

现在，我们本来可以直接复用扫描器里的 token 值作为 AST 节点操作类型，
但我更希望把 token 和 AST 节点这两个概念区分开。
因此一开始，我会写一个函数，把 token 值映射成 AST 节点操作值。
这个函数以及解析器的其余部分都位于 `expr.c` 中：

```c
// Convert a token into an AST operation.
int arithop(int tok) {
  switch (tok) {
    case T_PLUS:
      return (A_ADD);
    case T_MINUS:
      return (A_SUBTRACT);
    case T_STAR:
      return (A_MULTIPLY);
    case T_SLASH:
      return (A_DIVIDE);
    default:
      fprintf(stderr, "unknown token in arithop() on line %d\n", Line);
      exit(1);
  }
}
```

`switch` 里的 `default` 分支会在我们无法把给定 token
转换成 AST 节点类型时触发。
它将成为解析器语法检查的一部分。

我们还需要一个函数，用来检查下一个 token 是否为整数字面量，
并构建一个保存该字面量值的 AST 节点。代码如下：

```c
// Parse a primary factor and return an
// AST node representing it.
static struct ASTnode *primary(void) {
  struct ASTnode *n;

  // For an INTLIT token, make a leaf AST node for it
  // and scan in the next token. Otherwise, a syntax error
  // for any other token type.
  switch (Token.token) {
    case T_INTLIT:
      n = mkastleaf(A_INTLIT, Token.intvalue);
      scan(&Token);
      return (n);
    default:
      fprintf(stderr, "syntax error on line %d\n", Line);
      exit(1);
  }
}
```

这里假设存在一个全局变量 `Token`，
并且它已经保存了从输入中扫描出的最新 token。
定义在 `data.h` 中：

```c
extern_ struct token    Token;
```

而在 `main()` 中：

```c
  scan(&Token);                 // Get the first token from the input
  n = binexpr();                // Parse the expression in the file
```

现在我们就可以写出解析器本体了：

```c
// Return an AST tree whose root is a binary operator
struct ASTnode *binexpr(void) {
  struct ASTnode *n, *left, *right;
  int nodetype;

  // Get the integer literal on the left.
  // Fetch the next token at the same time.
  left = primary();

  // If no tokens left, return just the left node
  if (Token.token == T_EOF)
    return (left);

  // Convert the token into a node type
  nodetype = arithop(Token.token);

  // Get the next token in
  scan(&Token);

  // Recursively get the right-hand tree
  right = binexpr();

  // Now build a tree with both sub-trees
  n = mkastnode(nodetype, left, right, 0);
  return (n);
}
```

注意，在这份天真的解析器代码里，完全没有处理不同运算符优先级的逻辑。
就目前而言，这段代码把所有运算符都当成具有相同优先级。
如果你跟着代码去解析表达式 `2 * 3 + 4 * 5`，
就会发现它构建出的 AST 是这样的：

```
     *
    / \
   2   +
      / \
     3   *
        / \
       4   5
```

这显然不正确。它会先计算 `4*5` 得到 20，
再算 `3+20` 得到 23，而不是先算 `2*3` 得到 6。

那我为什么还要这么写？
因为我想让你看到：写一个简单的解析器很容易，
但想让它同时做对语义分析就没那么简单了。

## 解释这棵树

现在我们已经有了一棵（不正确的）AST，
接下来写一点代码来解释它。
同样地，我们会写递归代码来遍历这棵树。
伪代码如下：

```
interpretTree:
  First, interpret the left-hand sub-tree and get its value
  Then, interpret the right-hand sub-tree and get its value
  Perform the operation in the node at the root of our tree
  on the two sub-tree values, and return this value
```

回到那棵正确的 AST：

```
          +
         / \
        /   \
       /     \
      *       *
     / \     / \
    2   3   4   5
```

调用结构大致如下：

```
interpretTree0(tree with +):
  Call interpretTree1(left tree with *):
     Call interpretTree2(tree with 2):
       No maths operation, just return 2
     Call interpretTree3(tree with 3):
       No maths operation, just return 3
     Perform 2 * 3, return 6

  Call interpretTree1(right tree with *):
     Call interpretTree2(tree with 4):
       No maths operation, just return 4
     Call interpretTree3(tree with 5):
       No maths operation, just return 5
     Perform 4 * 5, return 20

  Perform 6 + 20, return 26
```

## 解释 AST 的代码

这部分代码在 `interp.c` 中，与上面的伪代码一致：

```c
// Given an AST, interpret the
// operators in it and return
// a final value.
int interpretAST(struct ASTnode *n) {
  int leftval, rightval;

  // Get the left and right sub-tree values
  if (n->left)
    leftval = interpretAST(n->left);
  if (n->right)
    rightval = interpretAST(n->right);

  switch (n->op) {
    case A_ADD:
      return (leftval + rightval);
    case A_SUBTRACT:
      return (leftval - rightval);
    case A_MULTIPLY:
      return (leftval * rightval);
    case A_DIVIDE:
      return (leftval / rightval);
    case A_INTLIT:
      return (n->intvalue);
    default:
      fprintf(stderr, "Unknown AST operator %d\n", n->op);
      exit(1);
  }
}
```
   
同样地，这里的 `switch` 语句中 `default` 分支会在我们无法解释 AST 节点类型时触发。
它将构成解析器语义检查的一部分。

## 构建解析器

这里还有一些其他代码，比如 `main()` 中对解释器的调用：

```c
  scan(&Token);                 // Get the first token from the input
  n = binexpr();                // Parse the expression in the file
  printf("%d\n", interpretAST(n));      // Calculate the final result
  exit(0);
```

现在你可以通过下面的命令构建解析器：

```
$ make
cc -o parser -g expr.c interp.c main.c scan.c tree.c
```

我已经提供了若干输入文件供你测试这个解析器，
当然你也完全可以自己创建新的输入。
记住，这里算出来的结果是错误的，
但解析器应该能检测出像连续数字、连续运算符，
以及输入结尾缺少数字之类的错误。
我还给解释器加了一些调试代码，
这样你就能看到 AST 各个节点是按什么顺序被求值的：

```
$ cat input01
2 + 3 * 5 - 8 / 3

$ ./parser input01
int 2
int 3
int 5
int 8
int 3
8 / 3
5 - 2
3 * 3
2 + 9
11

$ cat input02
13 -6+  4*
5
       +
08 / 3

$ ./parser input02
int 13
int 6
int 4
int 5
int 8
int 3
8 / 3
5 + 2
4 * 7
6 + 28
13 - 34
-21

$ cat input03
12 34 + -56 * / - - 8 + * 2

$ ./parser input03
unknown token in arithop() on line 1

$ cat input04
23 +
18 -
45.6 * 2
/ 18

$ ./parser input04
Unrecognised character . on line 3

$ cat input05
23 * 456abcdefg

$ ./parser input05
Unrecognised character a on line 1
```

## 总结与下一步

解析器负责识别这门语言的语法，并检查编译器输入是否符合这套语法。
如果不符合，解析器就应该打印错误信息。
由于我们的表达式语法是递归的，因此我们选择使用递归下降解析器来识别这些表达式。

目前这个解析器已经能工作了，上面的输出就是证明，
但它还没能正确处理输入的语义。
换句话说，它还不能算出表达式的正确值。

在编译器编写之旅的下一部分中，我们会修改解析器，
让它在解析表达式时也完成语义分析，
从而得到正确的数学计算结果。 [下一步](../03_Precedence/Readme.md)
