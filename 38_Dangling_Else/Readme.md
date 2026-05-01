# 第 38 部分：悬空 else（dangling else）以及更多内容

我一开始进入编译器编写之旅这一部分时，
本来是想修掉
[悬空 else（dangling else）问题](https:en.wikipedia.org/wiki/Dangling_else)。
结果后来发现，
我真正不得不做的，
是把几处解析方式重新整理一遍，
因为我最初的解析思路本身就有问题。

这大概是因为我当时太急着往编译器里继续加功能，
却没有足够停下来回头看看：
我们到底已经搭出了一个什么东西。

所以，
先来看看编译器里有哪些错误需要修。

## 修正 `for` 的语法

先从 `for` 循环结构下手。
没错，
它现在能工作，
但还不够通用。

到目前为止，
我们的 `for` 循环 BNF 语法一直是：

```
for_statement: 'for' '(' preop_statement ';'
                         true_false_expression ';'
                         postop_statement ')' compound_statement  ;
```

不过，
那份
[C 的 BNF 语法](https://www.lysator.liu.se/c/ANSI-C-grammar-y.html)
其实是这么写的：

```
for_statement:
        | FOR '(' expression_statement expression_statement ')' statement
        | FOR '(' expression_statement expression_statement expression ')' statement
        ;

expression_statement
        : ';'
        | expression ';'
        ;
```

而一个 `expression`
其实本身就是一个“由逗号分隔的表达式列表”。

这意味着，
`for` 循环的三个子句，
理论上都可以是表达式列表。
如果我们是在写一个“完整”的 C 编译器，
这件事最后会变得很麻烦。
不过我们现在写的只是一个 *C 子集* 编译器，
所以没必要把完整的 C 语法全部吃下来。

因此，
我把 `for` 循环的解析器改成识别下面这种形式：

```
for_statement: 'for' '(' expression_list ';'
                         true_false_expression ';'
                         expression_list ')' compound_statement  ;
```

中间那个子句仍然是单个表达式，
它必须给出真或假的判断结果。
而第一和第三个子句则可以是表达式列表。
这样一来，
现在 `tests/input80.c`
里这样的 `for` 循环就能被支持了：

```c
    for (x=0, y=1; x < 6; x++, y=y+2)
```

## 对 `expression_list()` 的修改

为了做到上面这一点，
我需要修改 `for_statement()` 的解析逻辑，
让它调用 `expression_list()`
去解析第一和第三子句里的表达式列表。

但现有编译器中的 `expression_list()`
只允许遇到 `')'` token 时才结束表达式列表。
因此我修改了 `expr.c` 里的 `expression_list()`，
让“结束 token”作为参数传入。
于是 `stmt.c` 中的 `for_statement()`
现在会变成这样：

```c
// Parse a FOR statement and return its AST
static struct ASTnode *for_statement(void) {
  ...
  // Get the pre_op expression and the ';'
  preopAST = expression_list(T_SEMI);
  semi();
  ...
  // Get the condition and the ';'.
  condAST = binexpr(0);
  semi();
  ...
  // Get the post_op expression and the ')'
  postopAST = expression_list(T_RPAREN);
  rparen();
}
```

而 `expression_list()` 的代码现在看起来是这样的：

```c
struct ASTnode *expression_list(int endtoken) {
  ...
  // Loop until the end token
  while (Token.token != endtoken) {

    // Parse the next expression
    child = binexpr(0);

    // Build an A_GLUE AST node ...
    tree = mkastnode(A_GLUE, P_NONE, tree, NULL, child, NULL, exprcount);

    // Stop when we reach the end token
    if (Token.token == endtoken) break;

    // Must have a ',' at this point
    match(T_COMMA, ",");
  }

  // Return the tree of expressions
  return (tree);
}
```

## 单条语句与复合语句

到目前为止，
我一直强迫使用我们编译器的人
在下面这些位置都必须写上 `'{ ... }'`：

 + `if` 语句的真分支
 + `if` 语句的假分支
 + `while` 语句的循环体
 + `for` 语句的循环体
 + `case` 子句之后的语句体
 + `default` 子句之后的语句体

对前四类语句来说，
如果语句体里只有一条语句，
那我们其实并不需要花括号，
例如：

```c
  if (x>5)
    x= x - 16;
  else
    x++;
```

但如果语句体里有多条语句，
那就 *确实* 需要复合语句，
也就是一组被花括号包起来的单条语句，
例如：

```c
  if (x>5)
    { x= x - 16; printf("not again!\n"); }
  else
    x++;
```

可奇怪的是，
对于 `switch` 语句中 `case` 或 `default` 后面的代码，
居然可以直接跟一组单条语句，
完全不需要花括号！！
到底是哪位疯狂的人觉得这设计没问题？
来看一个例子：

```c
  switch (x) {
    case 1: printf("statement 1\n");
            printf("statement 2\n");
            break;
    default: ...
  }
```

更离谱的是，
下面这种写法也同样合法：

```c
  switch (x) {
    case 1: {
      printf("statement 1\n");
      printf("statement 2\n");
      break;
    }
    default: ...
  }
```

因此，
我们需要能够解析下面这几种情况：

 + 单条语句
 + 一组被花括号包起来的语句
 + 一组虽然不是以 `'{'` 开头，但会在 `case`、`default` 或 `'}'` 处结束的语句

为此，
我修改了 `stmt.c` 中的 `compound_statement()`，
让它接收一个参数：

```c
// Parse a compound statement
// and return its AST. If inswitch is true,
// we look for a '}', 'case' or 'default' token
// to end the parsing. Otherwise, look for
// just a '}' to end the parsing.
struct ASTnode *compound_statement(int inswitch) {
  struct ASTnode *left = NULL;
  struct ASTnode *tree;

  while (1) {
    // Parse a single statement
    tree = single_statement();
    ...
    // Leave if we've hit the end token
    if (Token.token == T_RBRACE) return(left);
    if (inswitch && (Token.token == T_CASE || Token.token == T_DEFAULT)) return(left);
  }
}
```

如果调用这个函数时 `inswitch` 被设为 1，
说明它是在解析 `switch` 语句体时被调用的，
因此要把 `case`、`default` 或 `'}'`
都视作复合语句的结束标记。
否则，
我们就是在普通的 `'{ ... }'` 场景里，
那就只盯着 `'}'` 就行。

现在，
我们还需要允许：

 + `if` 语句体中只有一条语句
 + `while` 语句体中只有一条语句
 + `for` 语句体中只有一条语句

这些解析逻辑目前都会调用 `compound_statement(0)`，
但这样会强制要求出现一个结束用的 `'}'`，
而对单条语句来说根本不会有这个符号。

解决办法是：
让 `if`、`while`、`for`
的解析代码都改为调用 `single_statement()`，
只解析一条语句；
同时再让 `single_statement()`
在遇到左花括号时，
自己转去调用 `compound_statement()`。

于是我也在 `stmt.c` 中做了下面这些修改：

```c
// Parse a single statement and return its AST.
static struct ASTnode *single_statement(void) {
  ...
  switch (Token.token) {
    case T_LBRACE:
      // We have a '{', so this is a compound statement
      lbrace();
      stmt = compound_statement(0);
      rbrace();
      return(stmt);
}
...
static struct ASTnode *if_statement(void) {
  ...
  // Get the AST for the statement
  trueAST = single_statement();
  ...
  // If we have an 'else', skip it
  // and get the AST for the statement
  if (Token.token == T_ELSE) {
    scan(&Token);
    falseAST = single_statement();
  }
  ...
}
...
static struct ASTnode *while_statement(void) {
  ...
    // Get the AST for the statement.
  // Update the loop depth in the process
  Looplevel++;
  bodyAST = single_statement();
  Looplevel--;
  ...
}
...
static struct ASTnode *for_statement(void) {
  ...
  // Get the statement which is the body
  // Update the loop depth in the process
  Looplevel++;
  bodyAST = single_statement();
  Looplevel--;
  ...
}
```

这就意味着，
编译器现在可以接受这样的代码了：

```c
  if (x>5)
    x= x - 16;
  else
    x++;
```

## 那么，“悬空 else（dangling else）”呢？

我一开始进入这一部分，
本来就是为了处理 “dangling else” 问题。
但结果发现，
这个问题其实早就已经被我们现有的解析方式顺手解决掉了。

看下面这段程序：

```c
  // Dangling else test.
  // We should not print anything for x<= 5
  for (x=0; x < 12; x++)
    if (x > 5)
      if (x > 10)
        printf("10 < %2d\n", x);
      else
        printf(" 5 < %2d <= 10\n", x);
```

我们希望这里的 `else`
和“离它最近的那个 `if`”配对。
因此，
上面最后那条 `printf`
只应该在 `x` 介于 5 到 10 之间时执行。
这个 `else`
*不应该* 被解释成“对应 `x > 5` 失败”的情况。

幸运的是，
在我们的 `if_statement()` 解析器里，
在解析完 `if` 语句体之后，
会贪婪地继续查看后面是否有 `else` token：

```c
  // Get the AST for the statement
  trueAST = single_statement();

  // If we have an 'else', skip it
  // and get the AST for the statement
  if (Token.token == T_ELSE) {
    scan(&Token);
    falseAST = single_statement();
  }
```

这会强制让 `else`
总是和最近的 `if` 绑定，
从而解决 dangling else 问题。
也就是说，
我之前一直强迫别人写 `'{ ... }'`，
结果我担心的那个问题其实早就已经被解决了！
唉。

## 更友好的调试输出

最后，
我还顺手改了一下扫描器，
来改善调试体验。
更准确地说，
是改善我们打印出来的调试信息。

到目前为止，
错误信息里打印的还是 token 的数值编号，
例如：

 + Unexpected token in parameter list: 23
 + Expecting a primary expression, got token: 19
 + Syntax error, token: 44

对于真正收到这些错误信息的程序员来说，
这基本上是完全没法用的。
所以我在 `scan.c` 中加入了下面这张 token 字符串表：

```c
// List of token strings, for debugging purposes
char *Tstring[] = {
  "EOF", "=", "||", "&&", "|", "^", "&",
  "==", "!=", ",", ">", "<=", ">=", "<<", ">>",
  "+", "-", "*", "/", "++", "--", "~", "!",
  "void", "char", "int", "long",
  "if", "else", "while", "for", "return",
  "struct", "union", "enum", "typedef",
  "extern", "break", "continue", "switch",
  "case", "default",
  "intlit", "strlit", ";", "identifier",
  "{", "}", "(", ")", "[", "]", ",", ".",
  "->", ":"
};
```

在 `defs.h` 中，
我还给 Token 结构新增了一个字段：

```c
// Token structure
struct token {
  int token;                    // Token type, from the enum list above
  char *tokstr;                 // String version of the token
  int intvalue;                 // For T_INTLIT, the integer value
};
```

在 `scan.c` 的 `scan()` 里，
就在返回 token 之前，
我们把它的字符串版本也一起填上：

```c
  t->tokstr = Tstring[t->token];
```

最后，
我再去修改了一批 `fatalXX()` 调用，
让它们改为打印当前 token 的 `tokstr` 字段，
而不是 `intvalue`。
于是现在错误信息会变成：

 + Unexpected token in parameter list: ==
 + Expecting a primary expression, got token: ]
 + Syntax error, token: >>

这就好多了。

## 总结与下一步

我原本是来修编译器里
“dangling else” 这个毛病的，
结果最后修掉的是一批别的毛病。
而在这个过程中，
我才发现：
原来压根就没有 dangling else 这个问题需要我来修。

现在编译器的开发已经走到这样一个阶段：
为了让它能自举编译自己，
我们需要的核心元素基本都已经实现了；
但接下来还得找出并修复一堆零碎小问题。
这就是所谓的 “mop up” 阶段。

这意味着，
从现在开始，
关于“怎样写一个编译器”的内容会越来越少，
而关于“怎样修一个坏掉的编译器”的内容会越来越多。
如果你打算从接下来的旅程中途撤退，
我完全不会失望。
如果你真的到此为止，
也希望前面这些部分对你有所帮助。

在编译器编写之旅的下一部分中，
我会挑一个当前还不能工作、
但为了自举又必须工作的东西，
把它修好。 [下一步](../39_Var_Initialisation_pt1/Readme.md)
