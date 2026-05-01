# 第 3 部分：运算符优先级

在上一部分的编译器编写之旅中，我们看到了解析器并不一定会强制执行语言的语义。
它只负责落实语法的句法和结构规则。

于是我们得到了一段会把 `2 * 3 + 4 * 5` 这类表达式算错的代码，
因为它构造出的 AST 是这样的：

```
     *
    / \
   2   +
      / \
     3   *
        / \
       4   5
```

而不是：


```
          +
         / \
        /   \
       /     \
      *       *
     / \     / \
    2   3   4   5
```

为了解决这个问题，我们必须在解析器中加入运算符优先级处理。
至少有两种办法可以做到：

 + 在语言语法里显式表达运算符优先级
 + 用一张运算符优先级表来影响现有解析器

## 在语法中显式表达运算符优先级

下面是我们在上一部分里使用的语法：


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

注意，这里并没有区分这四个数学运算符。
下面我们把语法稍微改造一下，让它们之间出现差别：


```
expression: additive_expression
    ;

additive_expression:
      multiplicative_expression
    | additive_expression '+' multiplicative_expression
    | additive_expression '-' multiplicative_expression
    ;

multiplicative_expression:
      number
    | number '*' multiplicative_expression
    | number '/' multiplicative_expression
    ;

number:  T_INTLIT
         ;
```

现在我们有了两类表达式：*加法表达式（additive expressions）* 和
*乘法表达式（multiplicative expressions）*。
请注意，这个语法现在强制数字只能先成为乘法表达式的一部分。
这样一来，`*` 和 `/` 就会更紧密地绑定在它们两侧的数字上，
于是自然拥有更高的优先级。

任何加法表达式，其实要么本身就是一个乘法表达式，
要么是一个加法表达式（也就是说由乘法表达式构成的更大表达式），
后面跟着一个 `+` 或 `-` 运算符，再跟另一个乘法表达式。
这样一来，加法表达式的优先级就明显低于乘法表达式。

## 在递归下降解析器中实现上面的语法

那么，如何把上面这套语法实现进递归下降解析器里呢？
我已经在 `expr2.c` 中完成了这件事，下面会逐步讲解。

答案是：写一个 `multiplicative_expr()` 函数来处理
`*` 和 `/` 运算符，再写一个 `additive_expr()` 函数来处理
优先级更低的 `+` 和 `-` 运算符。

这两个函数都会读取一部分输入和一个运算符。
然后，只要后续仍然出现处于同一优先级层次的运算符，
函数就继续解析更多输入，并把左右两部分与第一个运算符组合起来。

不过，`additive_expr()` 必须把更高优先级的工作交给
`multiplicative_expr()`。下面来看它是怎么做到的。

## `additive_expr()`

```c
// Return an AST tree whose root is a '+' or '-' binary operator
struct ASTnode *additive_expr(void) {
  struct ASTnode *left, *right;
  int tokentype;

  // Get the left sub-tree at a higher precedence than us
  left = multiplicative_expr();

  // If no tokens left, return just the left node
  tokentype = Token.token;
  if (tokentype == T_EOF)
    return (left);

  // Loop working on token at our level of precedence
  while (1) {
    // Fetch in the next integer literal
    scan(&Token);

    // Get the right sub-tree at a higher precedence than us
    right = multiplicative_expr();

    // Join the two sub-trees with our low-precedence operator
    left = mkastnode(arithop(tokentype), left, right, 0);

    // And get the next token at our precedence
    tokentype = Token.token;
    if (tokentype == T_EOF)
      break;
  }

  // Return whatever tree we have created
  return (left);
}
```

一开始我们就立刻调用 `multiplicative_expr()`，
因为第一个运算符有可能是高优先级的 `*` 或 `/`。
这个函数只有在遇到低优先级的 `+` 或 `-` 时才会返回。

因此，当程序进入 `while` 循环时，
我们已经知道当前拿到的是 `+` 或 `-`。
循环会持续到输入中没有更多 token 为止，
也就是遇到 `T_EOF` token。

在循环内部，我们再次调用 `multiplicative_expr()`，
因为后面仍然有可能出现比当前更高优先级的运算符。
同样地，只有当后续不再属于更高优先级时，它才会返回。

一旦我们有了左右子树，就可以用上一轮循环得到的运算符把它们拼起来。
这个过程会不断重复，所以如果表达式是 `2 + 4 + 6`，
最终我们就会得到这样一棵 AST：

``` 
       +
      / \
     +   6
    / \
   2   4
```

而如果 `multiplicative_expr()` 内部碰到了更高优先级的运算符，
那么这里组合的就会是包含多个节点的子树，而不只是单个数字。

## `multiplicative_expr()`

```c
// Return an AST tree whose root is a '*' or '/' binary operator
struct ASTnode *multiplicative_expr(void) {
  struct ASTnode *left, *right;
  int tokentype;

  // Get the integer literal on the left.
  // Fetch the next token at the same time.
  left = primary();

  // If no tokens left, return just the left node
  tokentype = Token.token;
  if (tokentype == T_EOF)
    return (left);

  // While the token is a '*' or '/'
  while ((tokentype == T_STAR) || (tokentype == T_SLASH)) {
    // Fetch in the next integer literal
    scan(&Token);
    right = primary();

    // Join that with the left integer literal
    left = mkastnode(arithop(tokentype), left, right, 0);

    // Update the details of the current token.
    // If no tokens left, return just the left node
    tokentype = Token.token;
    if (tokentype == T_EOF)
      break;
  }

  // Return whatever tree we have created
  return (left);
}
```

这段代码与 `additive_expr()` 很相似，
只是这里可以直接调用 `primary()` 来获取真正的整数字面量。
同时，只有当前运算符属于高优先级层次，也就是 `*` 和 `/` 时，
它才会继续循环。
一旦遇到低优先级运算符，它就会直接返回目前已经构建好的子树，
把后续工作交还给 `additive_expr()`。

## 上述方案的缺点

这种通过显式优先级来构造递归下降解析器的方式，
可能会比较低效，因为为了到达正确的优先级层次，
需要进行很多函数调用。
另外，每一层运算符优先级几乎都要写一个专门函数，
于是代码行数会变得很多。

## 另一种办法：Pratt Parsing

减少代码量的一种方式，是使用
[Pratt parser](https://en.wikipedia.org/wiki/Pratt_parser)。
它不是为每个优先级层次写单独函数，
而是给每种 token 关联一个优先级值表。

这里我强烈建议你阅读 Bob Nystrom 的这篇文章：
[Pratt Parsers: Expression Parsing Made Easy](https://journal.stuffwithstuff.com/2011/03/19/pratt-parsers-expression-parsing-made-easy/)。
Pratt parser 到现在都还会让我有点头大，所以尽量多读一点，
先把它的基本概念读顺。

## `expr.c`：Pratt Parsing

我在 `expr.c` 中实现了 Pratt parsing，它可以直接替换 `expr2.c`。
下面开始逐步讲解。

首先，我们需要一些代码来决定每个 token 的优先级：

```c
// Operator precedence for each token
static int OpPrec[] = { 0, 10, 10, 20, 20,    0 };
//                     EOF  +   -   *   /  INTLIT

// Check that we have a binary operator and
// return its precedence.
static int op_precedence(int tokentype) {
  int prec = OpPrec[tokentype];
  if (prec == 0) {
    fprintf(stderr, "syntax error on line %d, token %d\n", Line, tokentype);
    exit(1);
  }
  return (prec);
}
```

较大的数值（例如 20）表示比更小的数值（例如 10）拥有更高的优先级。

你可能会问：既然已经有 `OpPrec[]` 这个查表数组了，
为什么还要再包一层函数？
答案是：为了捕捉语法错误。

考虑这样的输入：`234 101 + 12`。
我们可以扫描出前两个 token。
但如果只是简单地用 `OpPrec[]` 去读取第二个 `101` token 的优先级，
就不会发现它其实不是一个运算符。
因此，`op_precedence()` 函数本身也承担了语法检查的职责。

现在，我们不再为每一层优先级单独写函数，
而是写一个统一的表达式函数，通过优先级表来工作：

```c
// Return an AST tree whose root is a binary operator.
// Parameter ptp is the previous token's precedence.
struct ASTnode *binexpr(int ptp) {
  struct ASTnode *left, *right;
  int tokentype;

  // Get the integer literal on the left.
  // Fetch the next token at the same time.
  left = primary();

  // If no tokens left, return just the left node
  tokentype = Token.token;
  if (tokentype == T_EOF)
    return (left);

  // While the precedence of this token is
  // more than that of the previous token precedence
  while (op_precedence(tokentype) > ptp) {
    // Fetch in the next integer literal
    scan(&Token);

    // Recursively call binexpr() with the
    // precedence of our token to build a sub-tree
    right = binexpr(OpPrec[tokentype]);

    // Join that sub-tree with ours. Convert the token
    // into an AST operation at the same time.
    left = mkastnode(arithop(tokentype), left, right, 0);

    // Update the details of the current token.
    // If no tokens left, return just the left node
    tokentype = Token.token;
    if (tokentype == T_EOF)
      return (left);
  }

  // Return the tree we have when the precedence
  // is the same or lower
  return (left);
}
```

首先要注意，这个函数和前面的解析函数一样，依旧是递归的。
这一次，我们会接收一个“在进入当前函数之前就已经看到的 token 的优先级”。
`main()` 会以最低优先级 0 来调用它，
而函数内部则会以更高的优先级再次递归调用自己。

你应该也能看出来，这段代码和 `multiplicative_expr()` 非常相似：
读入一个整数字面量，拿到运算符 token 类型，然后在循环里不断构建树。

区别主要在循环条件和循环体：

```c
multiplicative_expr():
  while ((tokentype == T_STAR) || (tokentype == T_SLASH)) {
    scan(&Token); right = primary();

    left = mkastnode(arithop(tokentype), left, right, 0);

    tokentype = Token.token;
    if (tokentype == T_EOF) return (left);
  }

binexpr():
  while (op_precedence(tokentype) > ptp) {
    scan(&Token); right = binexpr(OpPrec[tokentype]);

    left = mkastnode(arithop(tokentype), left, right, 0);

    tokentype = Token.token;
    if (tokentype == T_EOF) return (left);
  }
```

在 Pratt parser 中，
如果下一个运算符的优先级高于当前 token，
我们就不会像以前那样只用 `primary()` 去拿下一个整数字面量，
而是调用 `binexpr(OpPrec[tokentype])`，
通过递归提升运算符优先级。

一旦遇到一个和当前优先级相同或更低的 token，
我们就会直接：

```c
  return (left);
```

此时返回的，要么是一棵包含许多高优先级节点的子树，
要么只是一个单独的整数字面量，
这取决于调用者和当前优先级之间的关系。

现在，我们只需要一个函数就能完成表达式解析。
它借助一个小小的辅助函数来落实运算符优先级，
从而也就实现了语言的语义规则。

## 让两种解析器都跑起来

你可以分别构建使用不同解析器的两个程序：

```
$ make parser                                        # Pratt Parser
cc -o parser -g expr.c interp.c main.c scan.c tree.c

$ make parser2                                       # Precedence Climbing
cc -o parser2 -g expr2.c interp.c main.c scan.c tree.c
```

你也可以用上一部分相同的输入文件来测试这两个解析器：

```
$ make test
(./parser input01; \
 ./parser input02; \
 ./parser input03; \
 ./parser input04; \
 ./parser input05)
15                                       # input01 result
29                                       # input02 result
syntax error on line 1, token 5          # input03 result
Unrecognised character . on line 3       # input04 result
Unrecognised character a on line 1       # input05 result

$ make test2
(./parser2 input01; \
 ./parser2 input02; \
 ./parser2 input03; \
 ./parser2 input04; \
 ./parser2 input05)
15                                       # input01 result
29                                       # input02 result
syntax error on line 1, token 5          # input03 result
Unrecognised character . on line 3       # input04 result
Unrecognised character a on line 1       # input05 result

```

## 总结与下一步

现在也许该稍微退一步，看看我们已经走到了哪里。现在我们已经有了：

 + 一个扫描器，能够识别并返回语言中的 token
 + 一个解析器，能够识别语法、报告语法错误并构建抽象语法树（Abstract Syntax Tree）
 + 一张解析器使用的优先级表，用来实现语言的语义规则
 + 一个解释器，它会深度优先遍历抽象语法树，并计算输入表达式的结果

我们还没有的是一个真正的编译器。
但离写出第一个编译器已经非常接近了。

在编译器编写之旅的下一部分中，我们将替换掉解释器。
取而代之的，是一个会为每个带有数学运算符的 AST 节点生成 x86-64 汇编代码的翻译器。
我们还会生成一些汇编前导（preamble）和后导（postamble）代码，
用来支撑代码生成器输出的汇编程序。 [下一步](../04_Assembly/Readme.md)
